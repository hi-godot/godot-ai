from __future__ import annotations

from functools import partial
from pathlib import Path

import fastmcp
import pytest

import godot_ai
from godot_ai import asgi
from godot_ai.transport.capability import HTTP_CAPABILITY_ENV, WS_CAPABILITY_ENV
from tests.conftest import (
    TEST_HTTP_CAPABILITY,
    TEST_TRANSPORT_CAPABILITIES,
    TEST_WS_CAPABILITY,
)


@pytest.fixture(autouse=True)
def _transport_capabilities(monkeypatch):
    monkeypatch.setenv(HTTP_CAPABILITY_ENV, TEST_HTTP_CAPABILITY)
    monkeypatch.setenv(WS_CAPABILITY_ENV, TEST_WS_CAPABILITY)
    monkeypatch.setattr(godot_ai, "preflight_check_port", lambda *_args, **_kwargs: None)


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
    calls: dict[str, object] = {}

    def fake_create_server(**kwargs):
        calls.update(kwargs)
        return server

    monkeypatch.setenv(asgi.DEV_TRANSPORT_ENV, "streamable-http")
    monkeypatch.setenv(asgi.DEV_HTTP_PORT_ENV, "8123")
    monkeypatch.setenv(asgi.DEV_WS_PORT_ENV, "9555")
    monkeypatch.setenv(asgi.DEV_EXCLUDE_DOMAINS_ENV, "audio,theme")
    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    result = asgi.create_app()

    assert result is app
    assert calls["ws_port"] == 9555
    assert calls["http_port"] == 8123
    assert calls["exclude_domains"] == {"audio", "theme"}
    assert calls["capabilities"] == TEST_TRANSPORT_CAPABILITIES
    assert server.http_calls == [{"transport": "streamable-http"}]


def test_run_with_reload_uses_uvicorn_factory(monkeypatch):
    calls: dict[str, object] = {}

    def fake_run(app, **kwargs):
        calls["app"] = app
        calls["kwargs"] = kwargs

    ## Seed via setenv (not delenv): run_with_reload writes these three vars
    ## straight into os.environ as a side effect, and pytest's delenv on an
    ## absent key registers no undo — so the written values would leak into
    ## the process env for later tests. setenv records an undo that restores
    ## (deletes) them at teardown regardless of what the call writes.
    monkeypatch.setenv(asgi.DEV_TRANSPORT_ENV, "")
    monkeypatch.setenv(asgi.DEV_WS_PORT_ENV, "")
    monkeypatch.setenv(asgi.DEV_EXCLUDE_DOMAINS_ENV, "")
    monkeypatch.delenv(asgi.HTTP_ACCESS_LOG_ENV, raising=False)
    monkeypatch.setattr(asgi.uvicorn, "run", fake_run)

    asgi.run_with_reload(
        transport="streamable-http",
        port=8123,
        ws_port=9555,
        exclude_domains={"audio", "theme"},
        capabilities=TEST_TRANSPORT_CAPABILITIES,
    )

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
        **asgi.hardened_uvicorn_config(access_log=False),
    }
    assert asgi._get_dev_transport() == "streamable-http"
    assert asgi._get_dev_ws_port() == 9555
    assert asgi._get_dev_http_port() == 8123
    ## Canonicalized comma-separated list — set order isn't guaranteed, so
    ## `run_with_reload` sorts before writing the env var.
    import os

    assert os.environ[asgi.DEV_EXCLUDE_DOMAINS_ENV] == "audio,theme"


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
        "exclude_domains": set(),
        "allow_host_networks": [],
        "capabilities": TEST_TRANSPORT_CAPABILITIES,
    }


def test_main_runs_server_directly_without_reload(monkeypatch):
    server = StubServer(app=None)
    calls: dict[str, object] = {}

    def fake_create_server(**kwargs):
        calls.update(kwargs)
        return server

    monkeypatch.delenv("GODOT_AI_OWNER_PID", raising=False)
    monkeypatch.delenv(asgi.HTTP_ACCESS_LOG_ENV, raising=False)
    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    godot_ai.main(["--transport", "streamable-http", "--port", "8123", "--ws-port", "9555"])

    assert calls["ws_port"] == 9555
    assert calls["exclude_domains"] == set()
    assert calls["owner_pid"] is None
    assert calls["http_port"] == 8123
    assert calls["capabilities"] == TEST_TRANSPORT_CAPABILITIES
    ## Access-log lines default off (uvicorn spams one INFO line per MCP
    ## call / status probe / lease heartbeat otherwise).
    assert server.run_calls == [
        {
            "transport": "streamable-http",
            "port": 8123,
            "uvicorn_config": asgi.hardened_uvicorn_config(access_log=False),
        }
    ]


def test_main_enables_access_log_when_env_truthy(monkeypatch):
    server = StubServer(app=None)

    monkeypatch.delenv("GODOT_AI_OWNER_PID", raising=False)
    monkeypatch.setenv(asgi.HTTP_ACCESS_LOG_ENV, "1")
    monkeypatch.setattr(
        "godot_ai.server.create_server",
        lambda **_kwargs: server,
    )

    godot_ai.main(["--transport", "streamable-http", "--port", "8123", "--ws-port", "9555"])

    assert server.run_calls == [
        {
            "transport": "streamable-http",
            "port": 8123,
            "uvicorn_config": asgi.hardened_uvicorn_config(access_log=True),
        }
    ]


def test_run_with_reload_enables_access_log_when_env_truthy(monkeypatch):
    calls: dict[str, object] = {}

    monkeypatch.setenv(asgi.DEV_TRANSPORT_ENV, "")
    monkeypatch.setenv(asgi.DEV_WS_PORT_ENV, "")
    monkeypatch.setenv(asgi.DEV_EXCLUDE_DOMAINS_ENV, "")
    monkeypatch.setenv(asgi.HTTP_ACCESS_LOG_ENV, "true")
    monkeypatch.setattr(asgi.uvicorn, "run", lambda app, **kwargs: calls.update(kwargs))

    asgi.run_with_reload(
        transport="streamable-http",
        port=8123,
        ws_port=9555,
        capabilities=TEST_TRANSPORT_CAPABILITIES,
    )

    assert calls["access_log"] is True


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("", False),
        ("0", False),
        ("false", False),
        ("off", False),
        ("1", True),
        ("true", True),
        (" YES ", True),
        ("On", True),
    ],
)
def test_http_access_log_enabled_truthiness(monkeypatch, value, expected):
    monkeypatch.setenv(asgi.HTTP_ACCESS_LOG_ENV, value)
    assert asgi.http_access_log_enabled() is expected


def test_http_access_log_disabled_when_env_absent(monkeypatch):
    monkeypatch.delenv(asgi.HTTP_ACCESS_LOG_ENV, raising=False)
    assert asgi.http_access_log_enabled() is False


def test_default_stdio_forwards_backend_options_to_attach(monkeypatch):
    calls: list[list[str]] = []
    monkeypatch.setattr("godot_ai.attach.main.main", lambda argv: calls.append(argv))

    godot_ai.main(
        [
            "--transport",
            "stdio",
            "--exclude-domains",
            "audio, particle ,theme",
        ]
    )

    ## Whitespace is stripped and duplicates collapsed; the set has no order.
    assert calls == [
        [
            "--port",
            "8000",
            "--ws-port",
            "9500",
            "--exclude-domains",
            "audio,particle,theme",
        ]
    ]


def test_main_plumbs_allow_host_into_create_server(monkeypatch):
    """--allow-host CIDRs reach create_server as parsed networks (#421)."""
    server = StubServer(app=None)
    calls: dict[str, object] = {}

    def fake_create_server(**kwargs):
        calls.update(kwargs)
        return server

    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    http_port, ws_port = 8123, 9555
    godot_ai.main(
        [
            "--transport",
            "streamable-http",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
            "--allow-host",
            "192.168.1.0/24",
            "--allow-host",
            "10.0.0.5",
        ]
    )

    assert [str(n) for n in calls["allow_host_networks"]] == ["192.168.1.0/24", "10.0.0.5/32"]


def test_main_widens_http_bind_only_when_allow_host_set(monkeypatch):
    """The HTTP bind widens to 0.0.0.0 only with --allow-host on an HTTP
    transport; the guard (rebuilt with the same CIDRs) still gates requests."""
    import fastmcp

    monkeypatch.setattr("godot_ai.server.create_server", lambda **kw: StubServer(app=None))
    monkeypatch.setattr(fastmcp.settings, "host", "127.0.0.1")

    ## Explicit free ports: main()'s preflight probes both binds, so a live
    ## process holding the default WS 9500 (or the HTTP port) exits 98.
    http_port, ws_port = 8123, 9555
    godot_ai.main(
        [
            "--transport",
            "streamable-http",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
            "--allow-host",
            "192.168.1.0/24",
        ]
    )
    assert fastmcp.settings.host == "0.0.0.0"


def test_main_does_not_widen_bind_without_allow_host(monkeypatch):
    import fastmcp

    monkeypatch.setattr("godot_ai.server.create_server", lambda **kw: StubServer(app=None))
    monkeypatch.setattr(fastmcp.settings, "host", "127.0.0.1")

    http_port, ws_port = 8123, 9555
    godot_ai.main(
        ["--transport", "streamable-http", "--port", str(http_port), "--ws-port", str(ws_port)]
    )
    assert fastmcp.settings.host == "127.0.0.1"


def test_main_rejects_invalid_allow_host(monkeypatch):
    monkeypatch.setattr("godot_ai.server.create_server", lambda **kw: StubServer(app=None))
    with pytest.raises(SystemExit):
        godot_ai.main(["--transport", "stdio", "--allow-host", "not-a-cidr"])


def test_run_with_reload_plumbs_allow_host_env_and_widens_bind(monkeypatch):
    """Reload path passes CIDRs to the factory subprocess via env and binds
    0.0.0.0 (#421)."""
    import os

    captured: dict[str, object] = {}

    def fake_run(app, **kwargs):
        captured["host"] = kwargs.get("host")

    monkeypatch.setattr(asgi.uvicorn, "run", fake_run)
    # setenv (not direct write) so pytest restores it for later tests.
    monkeypatch.setenv(asgi.DEV_ALLOW_HOST_ENV, "")
    from godot_ai.transport.origin_guard import parse_allow_hosts

    asgi.run_with_reload(
        transport="streamable-http",
        port=8000,
        ws_port=9500,
        allow_host_networks=parse_allow_hosts(["192.168.1.0/24"]),
        capabilities=TEST_TRANSPORT_CAPABILITIES,
    )

    assert os.environ[asgi.DEV_ALLOW_HOST_ENV] == "192.168.1.0/24"
    assert captured["host"] == "0.0.0.0"


def test_main_plumbs_owner_pid_from_flag(monkeypatch):
    server = StubServer(app=None)
    calls: dict[str, object] = {}

    def fake_create_server(**kwargs):
        calls.update(kwargs)
        return server

    monkeypatch.delenv("GODOT_AI_OWNER_PID", raising=False)
    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    http_port, ws_port = 8123, 9555
    godot_ai.main(
        [
            "--transport",
            "streamable-http",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
            "--owner-pid",
            "4242",
        ]
    )

    assert calls["owner_pid"] == 4242


def test_main_plumbs_owner_pid_from_env(monkeypatch):
    server = StubServer(app=None)
    calls: dict[str, object] = {}

    def fake_create_server(**kwargs):
        calls.update(kwargs)
        return server

    monkeypatch.setenv("GODOT_AI_OWNER_PID", "777")
    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    http_port, ws_port = 8123, 9555
    godot_ai.main(
        [
            "--transport",
            "streamable-http",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
        ]
    )

    assert calls["owner_pid"] == 777


def test_main_ignores_malformed_owner_pid_env(monkeypatch):
    server = StubServer(app=None)
    calls: dict[str, object] = {}

    def fake_create_server(**kwargs):
        calls.update(kwargs)
        return server

    monkeypatch.setenv("GODOT_AI_OWNER_PID", "not-a-pid")
    monkeypatch.setattr("godot_ai.server.create_server", fake_create_server)

    http_port, ws_port = 8123, 9555
    godot_ai.main(
        [
            "--transport",
            "streamable-http",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
        ]
    )

    assert calls["owner_pid"] is None


def test_main_rejects_unknown_exclude_domain(monkeypatch, capsys):
    monkeypatch.setattr(
        "godot_ai.server.create_server",
        lambda ws_port, *, exclude_domains=None: pytest.fail("should not reach create_server"),
    )
    with pytest.raises(SystemExit) as excinfo:
        godot_ai.main(["--transport", "stdio", "--exclude-domains", "bogus,audio"])
    assert excinfo.value.code != 0
    captured = capsys.readouterr()
    assert "Unknown or non-excludable" in captured.err
    assert "bogus" in captured.err


def test_main_rejects_non_excludable_core_domain(monkeypatch):
    monkeypatch.setattr(
        "godot_ai.server.create_server",
        lambda ws_port, *, exclude_domains=None: pytest.fail("should not reach create_server"),
    )
    ## `session` has only core tools, so excluding it would be a silent no-op.
    ## The parser rejects it up front rather than letting the user think they
    ## trimmed something.
    with pytest.raises(SystemExit):
        godot_ai.main(["--transport", "stdio", "--exclude-domains", "session"])


def test_main_version_flag(capsys):
    with pytest.raises(SystemExit) as excinfo:
        godot_ai.main(["--version"])
    assert excinfo.value.code == 0
    captured = capsys.readouterr()
    assert f"godot-ai {godot_ai.__version__}" in captured.out


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
        asgi.run_with_reload(
            transport="stdio",
            port=8000,
            ws_port=9500,
            capabilities=TEST_TRANSPORT_CAPABILITIES,
        )


@pytest.mark.parametrize("transport", ["sse", "streamable-http"])
@pytest.mark.parametrize("reload", [False, True])
def test_windows_ipv6_rejection_reaches_startup_report(monkeypatch, transport, reload):
    from godot_ai import runtime_info
    from godot_ai.transport import origin_guard

    reported = []
    monkeypatch.setattr(
        origin_guard, "bind_host_for_networks",
        partial(origin_guard.bind_host_for_networks, platform="win32"),
    )
    monkeypatch.setattr(runtime_info, "install_startup_report", lambda _path: None)
    monkeypatch.setattr(runtime_info, "report_startup_failure", reported.append)
    args = ["--transport", transport, "--allow-host", "fd00::/8"]
    if reload:
        args.append("--reload")
    with pytest.raises(ValueError, match="Use an IPv4 allowlist or disable remote access"):
        godot_ai.main(args)
    assert len(reported) == 1
    assert isinstance(reported[0], ValueError)
    assert "#1072" in str(reported[0])
