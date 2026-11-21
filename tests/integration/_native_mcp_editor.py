"""Helpers for a real, isolated Godot editor connected to an authenticated MCP backend."""

from __future__ import annotations

import asyncio
import socket
import subprocess
import sys
from contextlib import asynccontextmanager, suppress
from pathlib import Path

import httpx2
import psutil
import pytest
import uvicorn
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.asgi import hardened_uvicorn_config
from godot_ai.server import create_server
from godot_ai.transport.capability import generate_capabilities
from tests.conftest import isolate_capability_directory


def _loopback_client(**kwargs):
    return httpx2.AsyncClient(trust_env=False, **kwargs)


@asynccontextmanager
async def _backend():
    capabilities = generate_capabilities()
    with socket.socket() as http, socket.socket() as ws:
        http.bind(("127.0.0.1", 0))
        ws.bind(("127.0.0.1", 0))
        http_port, ws_port = http.getsockname()[1], ws.getsockname()[1]
        app = create_server(
            capabilities=capabilities, http_port=http_port, ws_port=ws_port, ws_socket=ws
        )
        server = uvicorn.Server(
            uvicorn.Config(
                app.http_app(json_response=True),
                log_level="warning",
                **hardened_uvicorn_config(access_log=False),
            )
        )
        task = asyncio.create_task(server.serve(sockets=[http]))
        try:
            async with asyncio.timeout(15):
                while not server.started:
                    assert not task.done(), "MCP backend exited during startup"
                    await asyncio.sleep(0.05)
            transport = StreamableHttpTransport(
                f"http://127.0.0.1:{http_port}/mcp",
                headers={"Authorization": f"Bearer {capabilities.http}"},
                httpx_client_factory=_loopback_client,
            )
            async with Client(transport, timeout=330) as client:
                yield client, http_port, ws_port
        finally:
            server.should_exit = True
            await asyncio.wait_for(task, 15)


def _isolate_editor(monkeypatch, root: Path, godot: str) -> None:
    binary_dir = Path(godot).resolve().parent
    possible_portable_dirs = [binary_dir]
    if sys.platform == "darwin" and binary_dir.name == "MacOS":
        possible_portable_dirs.append(binary_dir.parents[2])
    if any(
        (directory / marker).exists()
        for directory in possible_portable_dirs
        for marker in ("_sc_", "._sc_")
    ):
        pytest.skip("Portable Godot overrides editor profile isolation")
    for key in (
        "APPDATA",
        "HOME",
        "USERPROFILE",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
    ):
        directory = root / key.lower()
        directory.mkdir(parents=True)
        monkeypatch.setenv(key, str(directory))
    isolate_capability_directory(monkeypatch, root / "local")
    monkeypatch.setenv("GODOT_AI_ALLOW_HEADLESS", "1")
    monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")
    monkeypatch.setenv("GODOT_AI_MODE", "dev")


def _stop_owned_processes(owned) -> None:
    for process in owned:
        if process.is_running():
            try:
                process.terminate()
            except psutil.NoSuchProcess:
                continue
    _, survivors = psutil.wait_procs(owned, timeout=5)
    for process in survivors:
        try:
            process.kill()
        except psutil.NoSuchProcess:
            continue
    _, survivors = psutil.wait_procs(survivors, timeout=5)
    assert not survivors, survivors


@asynccontextmanager
async def _editor(client, godot: str, project: Path, log: Path):
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(
            [godot, "--headless", "--editor", "--path", str(project)],
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        launcher = psutil.Process(process.pid)
        owned = {launcher}
        try:
            try:
                async with asyncio.timeout(60):
                    while True:
                        assert process.poll() is None, "Godot exited before connecting"
                        with suppress(psutil.NoSuchProcess):
                            owned.update(launcher.children(recursive=True))
                        sessions = (await client.call_tool("session_manage", {"op": "list"})).data
                        if sessions["sessions"]:
                            (session,) = sessions["sessions"]
                            assert Path(session["project_path"]).resolve() == project.resolve(), (
                                session
                            )
                            identity = psutil.Process(session["editor_pid"])
                            assert identity in owned or launcher in identity.parents(), session
                            owned.add(identity)
                            if session["readiness"] in {"ready", "no_scene"}:
                                break
                        await asyncio.sleep(0.2)
            except (AssertionError, TimeoutError) as exc:
                raise AssertionError(log.read_text(encoding="utf-8", errors="replace")) from exc

            async def tool(name, /, **arguments):
                assert process.poll() is None and identity.is_running(), log
                result = await client.call_tool(
                    name, {**arguments, "session_id": session["session_id"]}
                )
                return result.data

            yield tool, session
            assert (await tool("editor_manage", op="quit"))["status"] == "quitting"
            assert await asyncio.to_thread(process.wait, 15) == 0
        finally:
            with suppress(psutil.NoSuchProcess):
                owned.update(launcher.children(recursive=True))
            await asyncio.to_thread(_stop_owned_processes, owned)
            await asyncio.to_thread(process.wait, 5)
