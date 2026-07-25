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
    DEFAULT_MAX_ACTIVE_LEASES,
    LeaseClient,
    LeaseInstanceMismatch,
    LeaseLimitExceeded,
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


def test_registry_caps_concurrent_leases() -> None:
    """An unauthenticated local peer must not be able to grow the registry.

    The lease routes are loopback-guarded but not authenticated, and the
    ``instance_id`` they need is published by ``/godot-ai/status``. Without a
    ceiling a local process could both exhaust memory and — because a live
    lease defers the owner-PID watchdog and the idle backstop — pin a
    plugin-spawned backend alive indefinitely.
    """
    clock = FakeClock()
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=30,
        heartbeat_after_seconds=10,
        max_active_leases=3,
        clock=clock,
    )

    held = [registry.register("instance-a") for _ in range(3)]
    assert registry.active_count() == 3

    with pytest.raises(LeaseLimitExceeded, match="maximum of 3"):
        registry.register("instance-a")

    ## Renewing an existing lease cannot grow the dict, so the ceiling must
    ## not block a legitimate bridge's heartbeat while the registry is full.
    clock.now = 5
    assert registry.heartbeat("instance-a", held[0].lease_id).lease_id == held[0].lease_id

    ## Releasing frees a slot immediately.
    assert registry.release("instance-a", held[1].lease_id) is True
    assert registry.register("instance-a") is not None
    assert registry.active_count() == 3

    ## So does expiry: the ceiling is on *live* leases, not lifetime issuance.
    clock.now = 1_000
    assert registry.active_count() == 0
    assert registry.register("instance-a") is not None


def test_registry_default_cap_is_generous_but_finite() -> None:
    registry = LeaseRegistry("instance-a")
    for _ in range(DEFAULT_MAX_ACTIVE_LEASES):
        registry.register("instance-a")
    with pytest.raises(LeaseLimitExceeded):
        registry.register("instance-a")


def test_registry_rejects_invalid_cap() -> None:
    with pytest.raises(ValueError, match="max active leases must be positive"):
        LeaseRegistry("instance-a", max_active_leases=0)


def test_prune_is_not_quadratic_in_live_leases() -> None:
    """``prune`` must cost what expired, not what is live.

    The original implementation rescanned the whole dict on every register,
    heartbeat, release, and ``active_count``, so N registrations cost O(N^2)
    CPU on the event loop that serves all MCP traffic. This pins the fix by
    counting clock reads: with an expiry heap, a prune over an all-live
    registry touches no entries regardless of how many are held.
    """
    clock = FakeClock()
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=1_000,
        heartbeat_after_seconds=10,
        max_active_leases=10_000,
        clock=clock,
    )
    for _ in range(2_000):
        registry.register("instance-a")

    ## Nothing has expired, so the heap's head is in the future and prune
    ## returns without popping. Verified structurally: the heap still holds
    ## every entry after the prune that active_count() performs.
    assert registry.active_count() == 2_000
    assert len(registry._expiry_heap) == 2_000

    ## Expire everything at once; a single prune drains both structures.
    clock.now = 2_000
    assert registry.active_count() == 0
    assert registry._expiry_heap == []


def test_heap_stays_bounded_under_heartbeat_churn_without_clock_movement() -> None:
    """Capping ``_expiries`` does not by itself bound the expiry heap.

    Every heartbeat pushes an entry dated one TTL in the future, and ``prune``
    can only pop entries that have already expired. Without compaction, an
    unauthenticated loopback caller heartbeating a single valid lease in a
    tight loop grows the heap without limit inside one TTL — reintroducing the
    memory-exhaustion vector the active-lease ceiling exists to close.

    The clock deliberately never advances: that is the attacker's best case,
    and an earlier version of this test moved the clock between heartbeats,
    which hid the growth entirely.
    """
    clock = FakeClock()
    cap = 8
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=30,
        heartbeat_after_seconds=10,
        max_active_leases=cap,
        clock=clock,
    )
    registration = registry.register("instance-a")

    for _ in range(20_000):
        registry.heartbeat("instance-a", registration.lease_id)

    assert registry.active_count() == 1
    assert len(registry._expiry_heap) <= (2 * cap) + 2

    ## The surviving entry must still be the CURRENT expiry, so the lease
    ## neither expires early nor outlives its TTL after a compaction.
    clock.now = 29
    assert registry.active_count() == 1
    clock.now = 31
    assert registry.active_count() == 0


def test_heap_stays_bounded_under_register_release_churn() -> None:
    """Released leases leave heap entries behind; churn must not accumulate."""
    clock = FakeClock()
    cap = 8
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=30,
        heartbeat_after_seconds=10,
        max_active_leases=cap,
        clock=clock,
    )

    for _ in range(20_000):
        registration = registry.register("instance-a")
        assert registry.release("instance-a", registration.lease_id) is True

    assert registry.active_count() == 0
    assert len(registry._expiry_heap) <= (2 * cap) + 2

    ## Churn must not have consumed the ceiling: the registry is empty, so a
    ## legitimate bridge can still register.
    assert registry.register("instance-a") is not None


def test_heap_compaction_preserves_live_expiries() -> None:
    """Compaction rebuilds from ``_expiries``, so no live lease may be lost."""
    clock = FakeClock()
    cap = 4
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=100,
        heartbeat_after_seconds=10,
        max_active_leases=cap,
        clock=clock,
    )
    held = [registry.register("instance-a") for _ in range(cap)]

    ## Renew one lease far past the others, forcing many compactions.
    clock.now = 50
    for _ in range(500):
        registry.heartbeat("instance-a", held[0].lease_id)

    assert registry.active_count() == cap
    assert len(registry._expiry_heap) <= (2 * cap) + 2

    ## The three un-renewed leases expire on the original schedule...
    clock.now = 101
    assert registry.active_count() == 1
    ## ...and the renewed one survives to its own, later deadline.
    clock.now = 151
    assert registry.active_count() == 0


def test_heartbeat_supersedes_heap_entries_without_unbounded_growth() -> None:
    """Superseded heap entries must drain, not accumulate forever."""
    clock = FakeClock()
    registry = LeaseRegistry(
        "instance-a",
        ttl_seconds=30,
        heartbeat_after_seconds=10,
        clock=clock,
    )
    registration = registry.register("instance-a")

    for tick in range(1, 21):
        clock.now = tick * 10
        registry.heartbeat("instance-a", registration.lease_id)

    ## The lease is still live after 200s of renewals...
    assert registry.active_count() == 1
    ## ...and the stale entries pushed by earlier heartbeats have been popped
    ## as their expiries passed, so the heap tracks live state, not history.
    assert len(registry._expiry_heap) <= 4

    clock.now += 31
    assert registry.active_count() == 0
    assert registry._expiry_heap == []


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


def test_lease_register_route_refuses_past_the_cap() -> None:
    """The HTTP surface must surface the ceiling, not grow without bound."""
    server = create_server(ws_port=9562)
    app = server.http_app(transport="streamable-http")
    client = TestClient(app, base_url="http://127.0.0.1")

    ## The instance_id an attacker needs is handed out unauthenticated.
    status = client.get("/godot-ai/status").json()
    assert status["instance_id"] == SERVER_INSTANCE_ID

    accepted = 0
    for _ in range(DEFAULT_MAX_ACTIVE_LEASES + 25):
        response = client.post(
            "/godot-ai/lease/register",
            json={"instance_id": SERVER_INSTANCE_ID},
        )
        if response.status_code == 200:
            accepted += 1
            continue
        assert response.status_code == 429
        body = response.json()["error"]
        assert body["code"] == "LEASE_LIMIT_EXCEEDED"
        assert body["instance_id"] == SERVER_INSTANCE_ID
        break

    assert accepted == DEFAULT_MAX_ACTIVE_LEASES

    ## Every subsequent attempt keeps refusing rather than intermittently
    ## letting one through.
    for _ in range(5):
        refused = client.post(
            "/godot-ai/lease/register",
            json={"instance_id": SERVER_INSTANCE_ID},
        )
        assert refused.status_code == 429


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
