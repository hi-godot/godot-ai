"""Contracts for attach bridge leases and backend lease routes."""

from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace

import httpx
import pytest
from starlette.testclient import TestClient

from godot_ai.attach import lease as lease_module
from godot_ai.attach.lease import (
    LeaseClient,
    LeaseInstanceMismatch,
    LeaseNotFound,
    LeaseRegistry,
)
from godot_ai.protocol.attach import SERVER_INSTANCE_ID, tool_catalog_hash
from godot_ai.server import create_server


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


@pytest.mark.parametrize(
    ("ttl", "heartbeat", "message"),
    [
        (0, 1, "ttl must be positive"),
        (10, 0, "heartbeat interval"),
        (10, 10, "heartbeat interval"),
    ],
)
def test_registry_rejects_invalid_durations(ttl: float, heartbeat: float, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        LeaseRegistry(
            "instance-a",
            ttl_seconds=ttl,
            heartbeat_after_seconds=heartbeat,
        )


def test_registry_register_heartbeat_release_and_expiry() -> None:
    clock = FakeClock()
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=12,
        heartbeat_after_seconds=4,
        clock=clock,
    )

    registration = registry.register("instance-a")
    assert registry.active_count() == 1
    assert registration.lease_ttl_seconds == 12
    assert registration.heartbeat_after_seconds == 4

    clock.now = 8
    registry.heartbeat("instance-a", registration.lease_id)
    clock.now = 13
    assert registry.active_count() == 1
    assert registry.release("instance-a", registration.lease_id) is True
    assert registry.active_count() == 0

    expired = registry.register("instance-a")
    clock.now = 26
    with pytest.raises(LeaseNotFound):
        registry.heartbeat("instance-a", expired.lease_id)
    registry.clear()
    assert registry.active_count() == 0


def test_registry_rejects_instance_change() -> None:
    registry = LeaseRegistry("new-instance")
    with pytest.raises(LeaseInstanceMismatch, match="backend instance changed"):
        registry.register("old-instance")


def test_lease_routes_are_instance_bound() -> None:
    server = create_server(ws_port=9558)
    client = TestClient(
        server.http_app(transport="streamable-http"),
        base_url="http://127.0.0.1",
    )

    wrong = client.post(
        "/godot-ai/lease/register",
        json={"instance_id": "stale"},
    )
    assert wrong.status_code == 409
    assert wrong.json()["error"]["code"] == "BACKEND_INSTANCE_CHANGED"

    registered = client.post(
        "/godot-ai/lease/register",
        json={"instance_id": SERVER_INSTANCE_ID},
    )
    assert registered.status_code == 200
    lease = registered.json()
    assert lease["instance_id"] == SERVER_INSTANCE_ID
    assert lease["lease_ttl_seconds"] > lease["heartbeat_after_seconds"] > 0

    heartbeat = client.post(
        "/godot-ai/lease/heartbeat",
        json={"instance_id": SERVER_INSTANCE_ID, "lease_id": lease["lease_id"]},
    )
    assert heartbeat.status_code == 200

    released = client.post(
        "/godot-ai/lease/release",
        json={"instance_id": SERVER_INSTANCE_ID, "lease_id": lease["lease_id"]},
    )
    assert released.json() == {"released": True, "instance_id": SERVER_INSTANCE_ID}

    missing = client.post(
        "/godot-ai/lease/heartbeat",
        json={"instance_id": SERVER_INSTANCE_ID, "lease_id": lease["lease_id"]},
    )
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "LEASE_NOT_FOUND"


def test_lease_routes_validate_bodies_and_release_errors() -> None:
    server = create_server(ws_port=9560)
    client = TestClient(
        server.http_app(transport="streamable-http"),
        base_url="http://127.0.0.1",
    )

    invalid_json = client.post(
        "/godot-ai/lease/register",
        content=b"{",
        headers={"content-type": "application/json"},
    )
    assert invalid_json.status_code == 400
    assert invalid_json.json()["error"]["message"] == "Expected JSON body."

    non_object = client.post("/godot-ai/lease/register", json=[])
    assert non_object.status_code == 400
    assert non_object.json()["error"]["message"] == "Expected JSON object."

    missing_field = client.post("/godot-ai/lease/register", json={"instance_id": ""})
    assert missing_field.status_code == 400
    assert "instance_id" in missing_field.json()["error"]["message"]

    invalid_heartbeat = client.post(
        "/godot-ai/lease/heartbeat",
        json={"instance_id": SERVER_INSTANCE_ID},
    )
    assert invalid_heartbeat.status_code == 400

    invalid_release = client.post(
        "/godot-ai/lease/release",
        json={"instance_id": SERVER_INSTANCE_ID},
    )
    assert invalid_release.status_code == 400

    wrong_instance = client.post(
        "/godot-ai/lease/release",
        json={"instance_id": "stale", "lease_id": "lease-a"},
    )
    assert wrong_instance.status_code == 409
    assert wrong_instance.json()["error"]["code"] == "BACKEND_INSTANCE_CHANGED"

    missing_lease = client.post(
        "/godot-ai/lease/release",
        json={"instance_id": SERVER_INSTANCE_ID, "lease_id": "missing"},
    )
    assert missing_lease.status_code == 404
    assert missing_lease.json()["error"]["code"] == "LEASE_NOT_FOUND"


def test_lease_routes_are_behind_loopback_guard() -> None:
    server = create_server(ws_port=9559)
    client = TestClient(server.http_app(transport="streamable-http"))

    response = client.post(
        "/godot-ai/lease/register",
        json={"instance_id": SERVER_INSTANCE_ID},
    )

    assert response.status_code == 403


def test_catalog_hash_is_stable_and_tracks_exclusions() -> None:
    first = asyncio.run(tool_catalog_hash(create_server(exclude_domains={"audio"})))
    second = asyncio.run(tool_catalog_hash(create_server(exclude_domains={"audio"})))
    full = asyncio.run(tool_catalog_hash(create_server()))

    assert first == second
    assert first != full


async def test_lease_client_reregisters_after_backend_instance_change() -> None:
    current_instance = "instance-a"
    registrations: list[str] = []
    reregistered = asyncio.Event()

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        if request.url.path.endswith("/register"):
            requested = payload["instance_id"]
            if requested != current_instance:
                return httpx.Response(409, json={"error": "instance changed"})
            registrations.append(requested)
            if requested == "instance-b":
                reregistered.set()
            return httpx.Response(
                200,
                json={
                    "instance_id": requested,
                    "lease_id": f"lease-{requested}",
                    "lease_ttl_seconds": 1.0,
                    "heartbeat_after_seconds": 0.01,
                },
            )
        if request.url.path.endswith("/heartbeat"):
            if payload["instance_id"] != current_instance:
                return httpx.Response(409, json={"error": "instance changed"})
            return httpx.Response(
                200,
                json={
                    "instance_id": current_instance,
                    "lease_id": payload["lease_id"],
                    "lease_ttl_seconds": 1.0,
                    "heartbeat_after_seconds": 0.01,
                },
            )
        return httpx.Response(200, json={"released": True})

    async def ensure_backend() -> SimpleNamespace:
        return SimpleNamespace(instance_id=current_instance)

    lease = LeaseClient(
        "http://127.0.0.1:8000",
        ensure_backend,
        transport=httpx.MockTransport(handler),
    )
    await lease.start(SimpleNamespace(instance_id="instance-a"))
    current_instance = "instance-b"
    try:
        await asyncio.wait_for(reregistered.wait(), timeout=1.0)
        assert lease.instance_id == "instance-b"
        assert registrations == ["instance-a", "instance-b"]
    finally:
        await lease.close()


async def test_lease_start_recovers_registration_race_and_sync_is_idempotent() -> None:
    registrations: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        if request.url.path.endswith("/register"):
            registrations.append(payload["instance_id"])
            if payload["instance_id"] == "instance-a":
                return httpx.Response(409, json={"error": "instance changed"})
            return httpx.Response(
                200,
                json={
                    "instance_id": "instance-b",
                    "lease_id": "lease-b",
                    "lease_ttl_seconds": 30,
                    "heartbeat_after_seconds": 10,
                },
            )
        return httpx.Response(200, json={"released": True})

    async def ensure_backend() -> SimpleNamespace:
        return SimpleNamespace(instance_id="instance-b")

    lease = LeaseClient(
        "http://127.0.0.1:8000",
        ensure_backend,
        transport=httpx.MockTransport(handler),
    )
    await lease.start(SimpleNamespace(instance_id="instance-a"))
    await lease.sync(SimpleNamespace(instance_id="instance-b"))
    try:
        assert lease.instance_id == "instance-b"
        assert registrations == ["instance-a", "instance-b"]
    finally:
        await lease.close()


async def test_lease_close_handles_empty_state_and_release_transport_failure() -> None:
    async def ensure_backend() -> SimpleNamespace:
        return SimpleNamespace(instance_id="instance-a")

    empty = LeaseClient("http://127.0.0.1:8000", ensure_backend)
    await empty.close()

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/register"):
            return httpx.Response(
                200,
                json={
                    "instance_id": "instance-a",
                    "lease_id": "lease-a",
                    "lease_ttl_seconds": 30,
                    "heartbeat_after_seconds": 10,
                },
            )
        raise httpx.ConnectError("release refused", request=request)

    lease = LeaseClient(
        "http://127.0.0.1:8000",
        ensure_backend,
        transport=httpx.MockTransport(handler),
    )
    await lease.start(SimpleNamespace(instance_id="instance-a"))
    await lease.close()
    assert lease.instance_id is None


async def test_lease_client_rejects_mismatched_registration_and_heartbeat() -> None:
    mode = "register"

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        if request.url.path.endswith("/register"):
            instance_id = "other" if mode == "register" else payload["instance_id"]
            return httpx.Response(
                200,
                json={
                    "instance_id": instance_id,
                    "lease_id": "lease-a",
                    "lease_ttl_seconds": 30,
                    "heartbeat_after_seconds": 10,
                },
            )
        heartbeat_instance = payload["instance_id"] if mode == "healthy" else "other"
        return httpx.Response(
            200,
            json={
                "instance_id": heartbeat_instance,
                "lease_id": "lease-a",
                "lease_ttl_seconds": 30,
                "heartbeat_after_seconds": 10,
            },
        )

    async def ensure_backend() -> SimpleNamespace:
        return SimpleNamespace(instance_id="instance-a")

    lease = LeaseClient(
        "http://127.0.0.1:8000",
        ensure_backend,
        transport=httpx.MockTransport(handler),
    )
    with pytest.raises(ValueError, match="different backend instance"):
        await lease._register("instance-a")

    mode = "heartbeat"
    await lease._register("instance-a")
    with pytest.raises(ValueError, match="heartbeat returned"):
        await lease._heartbeat_once()

    mode = "healthy"
    await lease._heartbeat_once()
    assert lease._heartbeat_after == 10


async def test_heartbeat_requires_a_registered_lease() -> None:
    async def ensure_backend() -> SimpleNamespace:
        return SimpleNamespace(instance_id="instance-a")

    lease = LeaseClient("http://127.0.0.1:8000", ensure_backend)
    with pytest.raises(LeaseNotFound, match="no registered lease"):
        await lease._heartbeat_once()


async def test_heartbeat_loop_survives_failed_recovery(monkeypatch: pytest.MonkeyPatch) -> None:
    warning = asyncio.Event()

    async def ensure_backend() -> SimpleNamespace:
        raise RuntimeError("backend unavailable")

    async def fail_heartbeat() -> None:
        request = httpx.Request("POST", "http://127.0.0.1/heartbeat")
        raise httpx.ConnectError("heartbeat refused", request=request)

    lease = LeaseClient("http://127.0.0.1:8000", ensure_backend)
    lease._heartbeat_after = 0.001
    monkeypatch.setattr(lease, "_heartbeat_once", fail_heartbeat)
    monkeypatch.setattr(
        lease_module.logger,
        "warning",
        lambda *_args, **_kwargs: warning.set(),
    )

    task = asyncio.create_task(lease._heartbeat_loop())
    try:
        await asyncio.wait_for(warning.wait(), timeout=1)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
