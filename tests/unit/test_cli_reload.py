from __future__ import annotations

from pathlib import Path

import fastmcp
import pytest

import godot_ai
from godot_ai import asgi


class StubServer:
    def __init__(self, app):
        self.app = app
        self.http_calls: list[dict] = []
        self.run_calls: list[dict] = []

    def http_app(self, *, transport: str):
        self.http_calls.append({"transport": transport})
        return self.app

    def run(self, **kwargs) -> None:
        self.run_calls.append(kwargs)


def test_create_app_uses_env_config(monkeypatch):
    app = object()
    server = StubServer(app)
    calls: dict[str, int] = {}

    def fake_create_server(ws_port: int):
        calls["ws_port"] = ws_port
        return server

    monkeypatch.setenv(asgi.DEV_TRANSPORT_ENV, "streamable-http")
    monkeypatch.setenv(asgi.DEV_WS_PORT_ENV, "9555")
    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    result = asgi.create_app()

    assert result is app
    assert calls["ws_port"] == 9555
    assert server.http_calls == [{"transport": "streamable-http"}]


def test_run_with_reload_uses_uvicorn_factory(monkeypatch):
    calls: dict[str, object] = {}

    def fake_run(app, **kwargs):
        calls["app"] = app
        calls["kwargs"] = kwargs

    monkeypatch.delenv(asgi.DEV_TRANSPORT_ENV, raising=False)
    monkeypatch.delenv(asgi.DEV_WS_PORT_ENV, raising=False)
    monkeypatch.setattr(asgi.uvicorn, "run", fake_run)

    asgi.run_with_reload(transport="streamable-http", port=8123, ws_port=9555)

    assert calls["app"] == "godot_ai.asgi:create_app"
    assert calls["kwargs"] == {
        "factory": True,
        "host": fastmcp.settings.host,
        "port": 8123,
        "log_level": fastmcp.settings.log_level.lower(),
        "timeout_graceful_shutdown": 2,
        "lifespan": "on",
        "ws": "websockets-sansio",
        "reload": True,
        "reload_dirs": [str(Path(asgi.__file__).resolve().parent.parent)],
    }
    assert asgi._get_dev_transport() == "streamable-http"
    assert asgi._get_dev_ws_port() == 9555


def test_main_uses_reloadable_runner_for_http_reload(monkeypatch):
    calls: dict[str, object] = {}

    monkeypatch.setattr(
        "godot_ai.asgi.run_with_reload",
        lambda **kwargs: calls.setdefault("kwargs", kwargs),
    )

    godot_ai.main(
        ["--transport", "streamable-http", "--port", "8123", "--ws-port", "9555", "--reload"]
    )

    assert calls["kwargs"] == {
        "transport": "streamable-http",
        "port": 8123,
        "ws_port": 9555,
    }


def test_main_runs_server_directly_without_reload(monkeypatch):
    server = StubServer(app=None)
    calls: dict[str, int] = {}

    def fake_create_server(ws_port: int):
        calls["ws_port"] = ws_port
        return server

    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    godot_ai.main(["--transport", "streamable-http", "--port", "8123", "--ws-port", "9555"])

    assert calls["ws_port"] == 9555
    assert server.run_calls == [{"transport": "streamable-http", "port": 8123}]


def test_get_dev_transport_rejects_unsupported(monkeypatch):
    monkeypatch.setenv(asgi.DEV_TRANSPORT_ENV, "stdio")
    with pytest.raises(ValueError, match="Unsupported dev transport"):
        asgi._get_dev_transport()


def test_get_dev_ws_port_rejects_non_integer(monkeypatch):
    monkeypatch.setenv(asgi.DEV_WS_PORT_ENV, "abc")
    with pytest.raises(ValueError, match="Invalid"):
        asgi._get_dev_ws_port()


def test_run_with_reload_rejects_non_http_transport():
    with pytest.raises(ValueError, match="Reload is only supported for HTTP"):
        asgi.run_with_reload(transport="stdio", port=8000, ws_port=9500)
