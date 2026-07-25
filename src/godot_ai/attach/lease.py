"""Backend lease registry and attach-bridge lease client."""

from __future__ import annotations

import asyncio
import heapq
import logging
import secrets
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

import httpx

DEFAULT_LEASE_TTL_SECONDS = 30.0
DEFAULT_HEARTBEAT_AFTER_SECONDS = 10.0

## Ceiling on simultaneously-registered leases. One attach bridge holds
## exactly one lease, so this is far above any legitimate multi-client
## setup; it exists because the lease routes are reachable by any local
## process (they are loopback-guarded, not authenticated, and the
## ``instance_id`` they require is published by the unauthenticated
## ``/godot-ai/status`` probe). Without a ceiling, a local peer could grow
## the registry without bound — and, because a live lease defers both the
## owner-PID watchdog and the idle backstop (see ``orphan_reaper``), pin a
## plugin-spawned backend alive indefinitely rather than for one lease TTL.
DEFAULT_MAX_ACTIVE_LEASES = 64

logger = logging.getLogger(__name__)


class LeaseInstanceMismatch(ValueError):
    """The caller addressed a backend instance that is no longer running."""


class LeaseNotFound(KeyError):
    """The requested lease does not exist or has already expired."""


class LeaseLimitExceeded(RuntimeError):
    """The backend already holds the maximum number of concurrent leases."""


@dataclass(frozen=True)
class LeaseRegistration:
    instance_id: str
    lease_id: str
    lease_ttl_seconds: float
    heartbeat_after_seconds: float

    def to_dict(self) -> dict[str, str | float]:
        return {
            "instance_id": self.instance_id,
            "lease_id": self.lease_id,
            "lease_ttl_seconds": self.lease_ttl_seconds,
            "heartbeat_after_seconds": self.heartbeat_after_seconds,
        }


class LeaseRegistry:
    """In-memory, instance-bound leases measured exclusively by monotonic time."""

    def __init__(
        self,
        instance_id: str,
        *,
        ttl_seconds: float = DEFAULT_LEASE_TTL_SECONDS,
        heartbeat_after_seconds: float = DEFAULT_HEARTBEAT_AFTER_SECONDS,
        max_active_leases: int = DEFAULT_MAX_ACTIVE_LEASES,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if ttl_seconds <= 0:
            raise ValueError("lease ttl must be positive")
        if heartbeat_after_seconds <= 0 or heartbeat_after_seconds >= ttl_seconds:
            raise ValueError("heartbeat interval must be positive and shorter than the lease ttl")
        if max_active_leases <= 0:
            raise ValueError("max active leases must be positive")
        self.instance_id = instance_id
        self.ttl_seconds = float(ttl_seconds)
        self.heartbeat_after_seconds = float(heartbeat_after_seconds)
        self.max_active_leases = int(max_active_leases)
        self._clock = clock
        self._expiries: dict[str, float] = {}
        ## Min-heap of (expiry, lease_id) mirroring ``_expiries`` so ``prune``
        ## touches only entries that have actually expired. The dict remains
        ## the source of truth: a heartbeat pushes a fresh entry and leaves the
        ## superseded one to be discarded lazily, and a release deletes from
        ## the dict only. ``prune`` reconciles both cases when it pops.
        ##
        ## Load-bearing: the previous full-dict scan ran on every register,
        ## heartbeat, release, and active_count, making N registrations cost
        ## O(N^2) CPU *on the event loop serving all MCP traffic*. Any rewrite
        ## must keep pruning proportional to what expired, not to what is live.
        self._expiry_heap: list[tuple[float, str]] = []

    def clear(self) -> None:
        self._expiries.clear()
        self._expiry_heap.clear()

    def register(self, expected_instance_id: str) -> LeaseRegistration:
        self._require_instance(expected_instance_id)
        self.prune()
        if len(self._expiries) >= self.max_active_leases:
            raise LeaseLimitExceeded(
                f"backend already holds the maximum of {self.max_active_leases} concurrent leases"
            )
        lease_id = secrets.token_urlsafe(24)
        self._track(lease_id, self._clock() + self.ttl_seconds)
        return LeaseRegistration(
            instance_id=self.instance_id,
            lease_id=lease_id,
            lease_ttl_seconds=self.ttl_seconds,
            heartbeat_after_seconds=self.heartbeat_after_seconds,
        )

    def heartbeat(self, expected_instance_id: str, lease_id: str) -> LeaseRegistration:
        self._require_instance(expected_instance_id)
        self.prune()
        if lease_id not in self._expiries:
            raise LeaseNotFound(lease_id)
        ## Renewal cannot grow ``_expiries`` (the key already exists), so it is
        ## deliberately not subject to the registration ceiling.
        self._track(lease_id, self._clock() + self.ttl_seconds)
        return LeaseRegistration(
            instance_id=self.instance_id,
            lease_id=lease_id,
            lease_ttl_seconds=self.ttl_seconds,
            heartbeat_after_seconds=self.heartbeat_after_seconds,
        )

    def release(self, expected_instance_id: str, lease_id: str) -> bool:
        self._require_instance(expected_instance_id)
        self.prune()
        ## Heap entries for this lease stay until they surface in ``prune``,
        ## which drops them once the dict no longer knows the id.
        return self._expiries.pop(lease_id, None) is not None

    def active_count(self) -> int:
        self.prune()
        return len(self._expiries)

    def prune(self) -> None:
        now = self._clock()
        heap = self._expiry_heap
        while heap and heap[0][0] <= now:
            _expiry, lease_id = heapq.heappop(heap)
            current = self._expiries.get(lease_id)
            if current is None:
                ## Released already; the heap entry is the last reference.
                continue
            if current <= now:
                del self._expiries[lease_id]
            ## Otherwise this is a superseded entry from before a heartbeat —
            ## the live expiry is further up the heap, so drop this one only.

    def _track(self, lease_id: str, expiry: float) -> None:
        self._expiries[lease_id] = expiry
        heapq.heappush(self._expiry_heap, (expiry, lease_id))

    def _require_instance(self, expected_instance_id: str) -> None:
        if expected_instance_id != self.instance_id:
            raise LeaseInstanceMismatch(
                f"backend instance changed: expected {expected_instance_id!r}, "
                f"running {self.instance_id!r}"
            )


EnsureBackend = Callable[[], Awaitable[Any]]
HttpTransport = httpx.AsyncBaseTransport | httpx.AsyncHTTPTransport | None


class LeaseClient:
    """Maintain one bridge lease and re-register after backend replacement."""

    def __init__(
        self,
        base_url: str,
        ensure_backend: EnsureBackend,
        *,
        request_timeout: float = 5.0,
        transport: HttpTransport = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._ensure_backend = ensure_backend
        self._request_timeout = request_timeout
        self._transport = transport
        self._instance_id: str | None = None
        self._lease_id: str | None = None
        self._heartbeat_after = DEFAULT_HEARTBEAT_AFTER_SECONDS
        self._heartbeat_task: asyncio.Task[None] | None = None
        self._lock = asyncio.Lock()

    @property
    def instance_id(self) -> str | None:
        return self._instance_id

    async def start(self, status: Any) -> None:
        try:
            await self.sync(status)
        except (httpx.HTTPError, KeyError, ValueError):
            # The backend can restart between ensure() and lease registration.
            # Resolve the current instance once and register against that nonce.
            await self._invalidate()
            await self.sync(await self._ensure_backend())
        if self._heartbeat_task is None:
            self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())

    async def sync(self, status: Any) -> None:
        instance_id = str(status.instance_id)
        async with self._lock:
            if self._instance_id == instance_id and self._lease_id:
                return
            await self._register(instance_id)

    async def close(self) -> None:
        task = self._heartbeat_task
        self._heartbeat_task = None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        async with self._lock:
            if not self._instance_id or not self._lease_id:
                return
            try:
                async with self._client() as client:
                    await client.post(
                        f"{self._base_url}/godot-ai/lease/release",
                        json={"instance_id": self._instance_id, "lease_id": self._lease_id},
                    )
            except httpx.HTTPError:
                pass
            self._instance_id = None
            self._lease_id = None

    async def _register(self, instance_id: str) -> None:
        async with self._client() as client:
            response = await client.post(
                f"{self._base_url}/godot-ai/lease/register",
                json={"instance_id": instance_id},
            )
        response.raise_for_status()
        payload = response.json()
        registered_instance = str(payload["instance_id"])
        if registered_instance != instance_id:
            raise ValueError(
                "lease registration returned a different backend instance: "
                f"expected {instance_id!r}, got {registered_instance!r}"
            )
        self._instance_id = registered_instance
        self._lease_id = str(payload["lease_id"])
        self._heartbeat_after = float(payload["heartbeat_after_seconds"])

    async def _heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(self._heartbeat_after)
            try:
                await self._heartbeat_once()
            except (httpx.HTTPError, KeyError, ValueError):
                await self._invalidate()
                try:
                    status = await self._ensure_backend()
                    await self.sync(status)
                except Exception:  # noqa: BLE001 - keep the lease task alive for later recovery
                    logger.warning(
                        "Attach lease recovery failed; retrying after the heartbeat interval",
                        exc_info=True,
                    )

    async def _heartbeat_once(self) -> None:
        async with self._lock:
            if not self._instance_id or not self._lease_id:
                raise LeaseNotFound("bridge has no registered lease")
            async with self._client() as client:
                response = await client.post(
                    f"{self._base_url}/godot-ai/lease/heartbeat",
                    json={"instance_id": self._instance_id, "lease_id": self._lease_id},
                )
            response.raise_for_status()
            payload = response.json()
            if str(payload["instance_id"]) != self._instance_id:
                raise ValueError("lease heartbeat returned a different backend instance")
            self._heartbeat_after = float(payload["heartbeat_after_seconds"])

    async def _invalidate(self) -> None:
        async with self._lock:
            self._instance_id = None
            self._lease_id = None

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=self._request_timeout,
            transport=self._transport,
            trust_env=False,
        )
