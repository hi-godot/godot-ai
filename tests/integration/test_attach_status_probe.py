"""Exercise the authenticated loopback probe through a real HTTP client."""

import asyncio
import json
import ssl

import pytest

from godot_ai import __version__
from godot_ai.attach.ensure import AttachStartupError, probe_backend
from godot_ai.protocol.attach import ATTACH_PROTOCOL_VERSION
from godot_ai.transport.capability import generate_capabilities, write_capabilities
from tests.conftest import isolate_capability_directory


@pytest.mark.parametrize("reply", ["status", "drip", "redirect"])
async def test_loopback_probe_needs_no_ca_bundle(tmp_path, monkeypatch, reply: str) -> None:
    directory = isolate_capability_directory(monkeypatch, tmp_path / "private")
    capabilities = generate_capabilities()
    instance_id = "a" * 32
    body = json.dumps({
        "name": "godot-ai", "instance_id": instance_id,
        "server_version": __version__, "attach_protocol_version": ATTACH_PROTOCOL_VERSION,
        "ws_port": 9500, "exclude_domains": [], "owner_type": "external",
        "tool_catalog_hash": "b" * 64, "package_path": "fixture",
    }).encode()
    requests: list[bytes] = []
    handlers: set[asyncio.Task] = set()

    async def respond(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.current_task()
        handlers.add(task)
        try:
            requests.append(await reader.readuntil(b"\r\n\r\n"))
            if reply == "redirect":
                writer.write((
                    "HTTP/1.1 307 Temporary Redirect\r\n"
                    f"Location: https://127.0.0.1:{port}/must-not-follow\r\n"
                    "Content-Length: 0\r\n\r\n"
                ).encode())
            else:
                writer.write((
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    f"Content-Length: {len(body)}\r\n\r\n"
                ).encode() + (b"" if reply == "drip" else body))
            await writer.drain()
            if reply == "drip":
                for byte in body:
                    writer.write(bytes([byte]))
                    await writer.drain()
                    try:
                        await asyncio.wait_for(reader.read(1), timeout=0.02)
                        break
                    except TimeoutError:
                        continue
        finally:
            writer.close()
            await writer.wait_closed()
            handlers.discard(task)

    def load_ca_bundle(*_args, **_kwargs):
        raise AssertionError("A plain HTTP status probe must not load TLS trust roots")

    monkeypatch.setattr(ssl.SSLContext, "load_verify_locations", load_ca_bundle)
    monkeypatch.setattr(ssl.SSLContext, "load_default_certs", load_ca_bundle)
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:1")
    monkeypatch.setenv("ALL_PROXY", "http://127.0.0.1:1")
    monkeypatch.setenv("NO_PROXY", "")
    server = await asyncio.start_server(respond, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    write_capabilities(
        port, capabilities.http, capabilities.websocket,
        instance_nonce=instance_id, directory=directory,
    )
    try:
        async with server, asyncio.timeout(2):
            if reply == "redirect":
                with pytest.raises(AttachStartupError, match="HTTP 307"):
                    await probe_backend(port)
            else:
                result = await probe_backend(port, timeout=0.1 if reply == "drip" else 1.0)
                if reply == "drip":
                    assert result is None
                else:
                    assert result is not None
                    assert result.instance_id == instance_id
                    assert result.server_version == __version__
    finally:
        if handlers:
            await asyncio.wait_for(asyncio.gather(*handlers), timeout=2)
    assert len(requests) == 1
    assert requests[0].startswith(b"GET /godot-ai/status HTTP/1.1\r\n")
    headers = dict(
        (name.lower(), value.strip())
        for name, value in (line.split(b":", 1) for line in requests[0].split(b"\r\n")[1:-2])
    )
    assert headers[b"authorization"] == f"Bearer {capabilities.http}".encode()
