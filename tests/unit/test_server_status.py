import asyncio
from pathlib import Path
from types import SimpleNamespace

from starlette.testclient import TestClient

import godot_ai as _godot_ai_pkg
from godot_ai import __version__
from godot_ai import server as server_module
from godot_ai.protocol.attach import (
    ATTACH_SPAWNED_ENV,
    PLUGIN_SPAWNED_ENV,
    SERVER_INSTANCE_ID,
    owner_type_from_env,
)
from godot_ai.telemetry import TelemetryConfig, latch_runtime_opt_out
from tests.conftest import (
    TEST_HTTP_AUTH_HEADERS,
    TEST_TRANSPORT_CAPABILITIES,
    TEST_WS_CAPABILITY,
    isolate_capability_directory,
)
from tests.conftest import (
    create_test_server as create_server,
)


def test_every_http_route_requires_the_distinct_http_capability() -> None:
    server = create_server(ws_port=9554)
    client = TestClient(
        server.http_app(transport="streamable-http"),
        base_url="http://127.0.0.1",
    )

    for method, path in (
        ("GET", "/godot-ai/status"),
        ("POST", "/godot-ai/lease/register"),
        ("POST", "/mcp"),
    ):
        response = client.request(method, path)
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "TRANSPORT_AUTH_REQUIRED"

        crossed = client.request(
            method,
            path,
            headers={"Authorization": f"Bearer {TEST_WS_CAPABILITY}"},
        )
        assert crossed.status_code == 401

    assert client.get("/godot-ai/status", headers=TEST_HTTP_AUTH_HEADERS).status_code == 200


def test_status_route_reports_live_server_version():
    server = create_server(ws_port=9555, exclude_domains={"audio", "theme"})
    assert server.version == __version__
    app = server.http_app(transport="streamable-http")
    ## ``base_url`` overrides Starlette TestClient's default ``testserver``
    ## Host header. The DNS-rebinding guard (origin_guard.py) rejects any
    ## non-loopback Host, so without this the request 403s before
    ## reaching the status route. See audit-v2 finding #1 (#345).
    client = TestClient(
        app,
        base_url="http://127.0.0.1",
        headers=TEST_HTTP_AUTH_HEADERS,
    )

    response = client.get("/godot-ai/status")

    assert response.status_code == 200
    payload = response.json()
    instance_id = payload.pop("instance_id")
    catalog_hash = payload.pop("tool_catalog_hash")
    telemetry_enabled = payload.pop("telemetry_enabled")
    assert payload == {
        "name": "godot-ai",
        "server_version": __version__,
        "ws_port": 9555,
        "tool_surface": "rollup",
        "exclude_domains": ["audio", "theme"],
        "package_path": str(Path(_godot_ai_pkg.__file__).resolve().parent),
        "owner_type": "external",
        "attach_protocol_version": 1,
        "active_lease_count": 0,
    }
    assert telemetry_enabled is (not TelemetryConfig._is_disabled_via_env())
    assert len(instance_id) == 32
    assert len(catalog_hash) == 64
    assert set(catalog_hash) <= set("0123456789abcdef")


def test_status_route_telemetry_enabled_rereads_env(monkeypatch) -> None:
    ## Prove a live env re-read on an already-constructed server, not a
    ## construction-time snapshot (#913).
    monkeypatch.delenv("GODOT_AI_DISABLE_TELEMETRY", raising=False)
    monkeypatch.delenv("DISABLE_TELEMETRY", raising=False)
    monkeypatch.setenv("GODOT_AI_ENABLE_TELEMETRY", "true")
    server = create_server(ws_port=9557)
    app = server.http_app(transport="streamable-http")
    client = TestClient(
        app,
        base_url="http://127.0.0.1",
        headers=TEST_HTTP_AUTH_HEADERS,
    )

    before = client.get("/godot-ai/status")
    assert before.status_code == 200
    assert before.json()["telemetry_enabled"] is True

    monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")
    response = client.get("/godot-ai/status")

    assert response.status_code == 200
    assert response.json()["telemetry_enabled"] is False


def test_status_route_telemetry_enabled_reflects_the_runtime_latch(isolated_data_dir) -> None:
    ## #913: the dock renders its privacy claim from this field, so it must
    ## account for a latched opt-out and not just the env vars — otherwise it
    ## reports "on" for a server that already stopped sending.
    ## ``isolated_data_dir`` clears the env vars and resets the latch after,
    ## which a one-way latch needs or every later test loses telemetry.
    server = create_server(ws_port=9558)
    app = server.http_app(transport="streamable-http")
    client = TestClient(
        app,
        base_url="http://127.0.0.1",
        headers=TEST_HTTP_AUTH_HEADERS,
    )

    assert client.get("/godot-ai/status").json()["telemetry_enabled"] is True

    latch_runtime_opt_out()

    response = client.get("/godot-ai/status")
    assert response.status_code == 200
    assert response.json()["telemetry_enabled"] is False
    ## Reporting an opt-out is not accepting one: the route still 200s
    ## and serves the same payload.
    assert response.json()["name"] == "godot-ai"


def test_status_route_package_path_points_at_loaded_package_dir():
    ## #416: the editor's "Incompatible server" banner consumes
    ## `package_path` so the user can tell which `src/godot_ai/` is
    ## actually serving the port — critical in a multi-worktree setup
    ## where the root .venv may resolve to a different branch than the
    ## worktree the user is editing. Pin that the field is an absolute,
    ## resolved path to a real directory containing `__init__.py`.
    server = create_server(ws_port=9556)
    app = server.http_app(transport="streamable-http")
    client = TestClient(
        app,
        base_url="http://127.0.0.1",
        headers=TEST_HTTP_AUTH_HEADERS,
    )

    response = client.get("/godot-ai/status")

    assert response.status_code == 200
    payload = response.json()
    package_path = Path(payload["package_path"])
    assert package_path.is_absolute(), (
        "package_path must be absolute so the user can match it against ps/Get-Process output"
    )
    assert (package_path / "__init__.py").exists(), (
        "package_path must point at the actual loaded godot_ai package dir"
    )


def test_owner_type_uses_spawn_markers_with_plugin_precedence(monkeypatch) -> None:
    monkeypatch.delenv(PLUGIN_SPAWNED_ENV, raising=False)
    monkeypatch.delenv(ATTACH_SPAWNED_ENV, raising=False)
    assert owner_type_from_env() == "external"

    monkeypatch.setenv(ATTACH_SPAWNED_ENV, "true")
    assert owner_type_from_env() == "attach"

    monkeypatch.setenv(PLUGIN_SPAWNED_ENV, "1")
    assert owner_type_from_env() == "plugin"


async def test_attach_owned_lifespan_wires_lease_count_into_idle_reaper(
    monkeypatch,
    tmp_path,
) -> None:
    started = asyncio.Event()
    captured: dict[str, object] = {}

    class FakeWebSocketServer:
        def __init__(self, _registry, *, port: int, auth_token) -> None:
            self.port = port

        async def start(self) -> None:
            await asyncio.Event().wait()

        async def wait_until_ready(self) -> None:
            return None

    async def fake_watch_idle(session_count, *, lease_count, **_kwargs) -> None:
        captured["sessions"] = session_count()
        captured["leases"] = lease_count()
        started.set()
        await asyncio.Event().wait()

    monkeypatch.setattr(server_module, "GodotWebSocketServer", FakeWebSocketServer)
    monkeypatch.setattr(
        server_module,
        "GodotClient",
        lambda *_args: SimpleNamespace(default_hint_policy="preserve"),
    )
    monkeypatch.setattr(server_module, "should_arm_reaper", lambda _owner_pid: False)
    monkeypatch.setattr(server_module, "should_arm_idle_exit", lambda _owner_pid: False)
    monkeypatch.setattr(server_module, "should_arm_attach_idle_exit", lambda: True)
    monkeypatch.setattr(server_module, "watch_idle", fake_watch_idle)
    monkeypatch.setattr(server_module, "shutdown_if_initialized", lambda: None)
    isolate_capability_directory(monkeypatch, tmp_path)

    server = create_server(ws_port=9561)
    async with server._lifespan(server):
        await asyncio.wait_for(started.wait(), timeout=1)
        assert captured == {"sessions": 0, "leases": 0}


async def test_lifespan_publishes_after_ws_ready_and_cleans_only_its_record(
    monkeypatch,
) -> None:
    order: list[object] = []
    started = asyncio.Event()

    class FakeClaim:
        def release(self) -> None:
            order.append("release")

    class FakeWebSocketServer:
        def __init__(self, _registry, *, port: int, auth_token: str) -> None:
            self.port = port
            assert auth_token == TEST_TRANSPORT_CAPABILITIES.websocket

        async def start(self) -> None:
            order.append("ws-start")
            started.set()
            await asyncio.Event().wait()

        async def wait_until_ready(self) -> None:
            await started.wait()
            order.append("ws-ready")

    def write(http_port, http, websocket, *, instance_nonce) -> None:
        order.append(("publish", http_port, http, websocket, instance_nonce))

    def remove(http_port, instance_nonce) -> bool:
        order.append(("remove", http_port, instance_nonce))
        return True

    monkeypatch.setattr(server_module, "GodotWebSocketServer", FakeWebSocketServer)
    monkeypatch.setattr(
        server_module,
        "GodotClient",
        lambda *_args: SimpleNamespace(default_hint_policy="preserve"),
    )
    monkeypatch.setattr(server_module, "acquire_port_claim", lambda port: FakeClaim())
    monkeypatch.setattr(server_module, "write_capabilities", write)
    monkeypatch.setattr(server_module, "remove_capabilities", remove)
    monkeypatch.setattr(server_module, "should_arm_reaper", lambda _owner_pid: False)
    monkeypatch.setattr(server_module, "should_arm_idle_exit", lambda _owner_pid: False)
    monkeypatch.setattr(server_module, "should_arm_attach_idle_exit", lambda: False)
    monkeypatch.setattr(server_module, "shutdown_if_initialized", lambda: None)

    server = create_server(ws_port=9563, http_port=8123)
    async with server._lifespan(server):
        publish_index = next(i for i, event in enumerate(order) if event[0] == "publish")
        assert order.index("ws-ready") < publish_index

    assert order[-2:] == [
        ("remove", 8123, SERVER_INSTANCE_ID),
        "release",
    ]


async def test_plugin_owned_lifespan_wires_lease_count_into_both_reapers(
    monkeypatch,
    tmp_path,
) -> None:
    started = asyncio.Event()
    captured: dict[str, int] = {}

    class FakeWebSocketServer:
        def __init__(self, _registry, *, port: int, auth_token) -> None:
            self.port = port

        async def start(self) -> None:
            await asyncio.Event().wait()

        async def wait_until_ready(self) -> None:
            return None

    async def fake_watch_owner(_owner_pid, session_count, *, lease_count, **_kwargs) -> None:
        captured["owner_sessions"] = session_count()
        captured["owner_leases"] = lease_count()
        if len(captured) == 4:
            started.set()
        await asyncio.Event().wait()

    async def fake_watch_idle(session_count, *, lease_count, **_kwargs) -> None:
        captured["idle_sessions"] = session_count()
        captured["idle_leases"] = lease_count()
        if len(captured) == 4:
            started.set()
        await asyncio.Event().wait()

    monkeypatch.setattr(server_module, "GodotWebSocketServer", FakeWebSocketServer)
    monkeypatch.setattr(
        server_module,
        "GodotClient",
        lambda *_args: SimpleNamespace(default_hint_policy="preserve"),
    )
    monkeypatch.setattr(server_module, "should_arm_reaper", lambda _owner_pid: True)
    monkeypatch.setattr(server_module, "should_arm_idle_exit", lambda _owner_pid: True)
    monkeypatch.setattr(server_module, "watch_owner", fake_watch_owner)
    monkeypatch.setattr(server_module, "watch_idle", fake_watch_idle)
    monkeypatch.setattr(server_module, "shutdown_if_initialized", lambda: None)
    isolate_capability_directory(monkeypatch, tmp_path)

    server = create_server(ws_port=9562, owner_pid=4242)
    async with server._lifespan(server):
        await asyncio.wait_for(started.wait(), timeout=1)
        assert captured == {
            "owner_sessions": 0,
            "owner_leases": 0,
            "idle_sessions": 0,
            "idle_leases": 0,
        }


def test_status_route_reports_active_attach_lease_count():
    """#824: the plugin reads this at editor exit to decide detach vs kill."""
    server = create_server(ws_port=9556)
    app = server.http_app(transport="streamable-http")
    client = TestClient(
        app,
        base_url="http://127.0.0.1",
        headers=TEST_HTTP_AUTH_HEADERS,
    )

    instance_id = client.get("/godot-ai/status").json()["instance_id"]
    assert client.get("/godot-ai/status").json()["active_lease_count"] == 0

    registered = client.post("/godot-ai/lease/register", json={"instance_id": instance_id})
    assert registered.status_code == 200
    lease_id = registered.json()["lease_id"]

    ## A held lease is what tells a closing editor to hand the backend over
    ## instead of killing it out from under the bridge that registered.
    assert client.get("/godot-ai/status").json()["active_lease_count"] == 1

    released = client.post(
        "/godot-ai/lease/release",
        json={"instance_id": instance_id, "lease_id": lease_id},
    )
    assert released.status_code == 200

    ## ...and once the last bridge lets go, the editor's normal stop applies
    ## again on the next teardown.
    assert client.get("/godot-ai/status").json()["active_lease_count"] == 0


def test_status_lease_count_tracks_multiple_bridges():
    """#824: releasing one of several bridges must not free the backend."""
    server = create_server(ws_port=9557)
    app = server.http_app(transport="streamable-http")
    client = TestClient(
        app,
        base_url="http://127.0.0.1",
        headers=TEST_HTTP_AUTH_HEADERS,
    )

    instance_id = client.get("/godot-ai/status").json()["instance_id"]

    def count() -> int:
        return client.get("/godot-ai/status").json()["active_lease_count"]

    first = client.post("/godot-ai/lease/register", json={"instance_id": instance_id}).json()[
        "lease_id"
    ]
    second = client.post("/godot-ai/lease/register", json={"instance_id": instance_id}).json()[
        "lease_id"
    ]
    assert count() == 2

    ## One bridge exits; the other still holds the backend, so the editor's
    ## teardown must still see a non-zero count and decline to kill.
    client.post(
        "/godot-ai/lease/release",
        json={"instance_id": instance_id, "lease_id": first},
    )
    assert count() == 1

    ## Only the last release returns it to the reapable state.
    client.post(
        "/godot-ai/lease/release",
        json={"instance_id": instance_id, "lease_id": second},
    )
    assert count() == 0
