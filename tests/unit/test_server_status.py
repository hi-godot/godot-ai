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
    owner_type_from_env,
)
from godot_ai.server import create_server


def test_status_route_reports_live_server_version():
    server = create_server(ws_port=9555, exclude_domains={"audio", "theme"})
    app = server.http_app(transport="streamable-http")
    ## ``base_url`` overrides Starlette TestClient's default ``testserver``
    ## Host header. The DNS-rebinding guard (origin_guard.py) rejects any
    ## non-loopback Host, so without this the request 403s before
    ## reaching the status route. See audit-v2 finding #1 (#345).
    client = TestClient(app, base_url="http://127.0.0.1")

    response = client.get("/godot-ai/status")

    assert response.status_code == 200
    payload = response.json()
    instance_id = payload.pop("instance_id")
    catalog_hash = payload.pop("tool_catalog_hash")
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
    assert len(instance_id) == 32
    assert len(catalog_hash) == 64
    assert set(catalog_hash) <= set("0123456789abcdef")


def test_status_route_package_path_points_at_loaded_package_dir():
    ## #416: the editor's "Incompatible server" banner consumes
    ## `package_path` so the user can tell which `src/godot_ai/` is
    ## actually serving the port — critical in a multi-worktree setup
    ## where the root .venv may resolve to a different branch than the
    ## worktree the user is editing. Pin that the field is an absolute,
    ## resolved path to a real directory containing `__init__.py`.
    server = create_server(ws_port=9556)
    app = server.http_app(transport="streamable-http")
    client = TestClient(app, base_url="http://127.0.0.1")

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


async def test_attach_owned_lifespan_wires_lease_count_into_idle_reaper(monkeypatch) -> None:
    started = asyncio.Event()
    captured: dict[str, object] = {}

    class FakeWebSocketServer:
        def __init__(self, _registry, *, port: int, auth_token) -> None:
            self.port = port

        async def start(self) -> None:
            await asyncio.Event().wait()

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

    server = create_server(ws_port=9561)
    async with server._lifespan(server):
        await asyncio.wait_for(started.wait(), timeout=1)
        assert captured == {"sessions": 0, "leases": 0}


async def test_plugin_owned_lifespan_wires_lease_count_into_both_reapers(monkeypatch) -> None:
    started = asyncio.Event()
    captured: dict[str, int] = {}

    class FakeWebSocketServer:
        def __init__(self, _registry, *, port: int, auth_token) -> None:
            self.port = port

        async def start(self) -> None:
            await asyncio.Event().wait()

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
    client = TestClient(app, base_url="http://127.0.0.1")

    instance_id = client.get("/godot-ai/status").json()["instance_id"]
    assert client.get("/godot-ai/status").json()["active_lease_count"] == 0

    registered = client.post(
        "/godot-ai/lease/register", json={"instance_id": instance_id}
    )
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
