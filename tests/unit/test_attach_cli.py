"""CLI dispatch and stdio startup-diagnostic contracts."""

from __future__ import annotations

from types import SimpleNamespace

import httpx
import pytest

import godot_ai
from godot_ai.attach import main as attach_main_module
from godot_ai.attach.ensure import AttachStartupError


def test_root_main_dispatches_attach_before_legacy_parser(monkeypatch) -> None:
    received: list[list[str]] = []
    monkeypatch.setattr(attach_main_module, "main", lambda argv: received.append(list(argv)))

    godot_ai.main(["attach", "--port", "8123"])

    assert received == [["--port", "8123"]]


def test_root_help_discovers_attach(capsys) -> None:
    with pytest.raises(SystemExit) as exc_info:
        godot_ai.main(["--help"])

    assert exc_info.value.code == 0
    assert "godot-ai attach" in capsys.readouterr().out


def test_attach_version_is_available(capsys) -> None:
    with pytest.raises(SystemExit) as exc_info:
        attach_main_module.main(["--version"])

    assert exc_info.value.code == 0
    assert f"godot-ai attach {godot_ai.__version__}" in capsys.readouterr().out


def test_preinitialize_failure_uses_stderr_only(monkeypatch, capsys) -> None:
    async def fail(*_args):
        raise AttachStartupError(
            "NEW_CLIENT_SESSION_REQUIRED",
            "version mismatch",
            hint="reconfigure and start a new session",
        )

    monkeypatch.setattr(attach_main_module, "run_attach", fail)

    with pytest.raises(SystemExit) as exc_info:
        attach_main_module.main([])

    captured = capsys.readouterr()
    assert exc_info.value.code == 1
    assert captured.out == ""
    assert "NEW_CLIENT_SESSION_REQUIRED" in captured.err
    assert "reconfigure and start a new session" in captured.err


async def test_run_attach_wires_ensure_observer_proxy_and_lease(monkeypatch) -> None:
    events: list[object] = []
    backend_status = SimpleNamespace(instance_id="instance-a")

    class FakeEnsurer:
        def __init__(self, port: int, ws_port: int, domains: tuple[str, ...]) -> None:
            events.append(("ensurer", port, ws_port, domains))
            self.base_url = f"http://127.0.0.1:{port}"
            self.mcp_url = f"{self.base_url}/mcp"

        async def ensure(self):
            events.append("ensure")
            return backend_status

    class FakeLease:
        def __init__(self, base_url: str, ensure_backend) -> None:
            events.append(("lease", base_url))
            self.ensure_backend = ensure_backend

        async def start(self, status) -> None:
            events.append(("start", status.instance_id))

        async def sync(self, status) -> None:
            events.append(("sync", status.instance_id))

        async def close(self) -> None:
            events.append("close")

    class FakeProxy:
        async def run_async(self, *, transport: str, show_banner: bool) -> None:
            events.append(("run", transport, show_banner))
            assert (await ready()).instance_id == "instance-a"
            assert (await observe()).instance_id == "instance-a"

    async def fake_probe(port: int, *, timeout: float):
        events.append(("observe", port, timeout))
        return backend_status

    def fake_create_proxy(mcp_url: str, ensure_ready, observe_backend):
        nonlocal ready, observe
        events.append(("proxy", mcp_url))
        ready = ensure_ready
        observe = observe_backend
        return FakeProxy()

    ready = None
    observe = None
    monkeypatch.setattr(attach_main_module, "BackendEnsurer", FakeEnsurer)
    monkeypatch.setattr(attach_main_module, "LeaseClient", FakeLease)
    monkeypatch.setattr(attach_main_module, "probe_backend", fake_probe)
    monkeypatch.setattr(attach_main_module, "create_attach_proxy", fake_create_proxy)

    await attach_main_module.run_attach(8123, 9567, ("audio",))

    assert ("ensurer", 8123, 9567, ("audio",)) in events
    assert ("proxy", "http://127.0.0.1:8123/mcp") in events
    assert ("run", "stdio", False) in events
    assert events[-1] == "close"


def test_invalid_exclude_domains_use_parser_error(monkeypatch, capsys) -> None:
    monkeypatch.setattr(
        attach_main_module,
        "parse_exclude_list",
        lambda _raw: (_ for _ in ()).throw(ValueError("bad domain")),
    )

    with pytest.raises(SystemExit) as exc_info:
        attach_main_module.main(["--exclude-domains", "bad"])

    assert exc_info.value.code == 2
    assert "bad domain" in capsys.readouterr().err


def test_http_lease_failure_uses_stderr_only(monkeypatch, capsys) -> None:
    async def fail(*_args):
        raise httpx.ConnectError("lease refused")

    monkeypatch.setattr(attach_main_module, "run_attach", fail)

    with pytest.raises(SystemExit) as exc_info:
        attach_main_module.main([])

    captured = capsys.readouterr()
    assert exc_info.value.code == 1
    assert captured.out == ""
    assert "ATTACH_START_FAILED" in captured.err
    assert "lease refused" in captured.err
