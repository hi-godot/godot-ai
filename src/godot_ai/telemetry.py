"""Anonymous, privacy-focused telemetry for Godot AI.

Ported from CoplayDev/unity-mcp's ``core/telemetry.py`` + ``core/telemetry_decorator.py``
and simplified:

* Single combined sync/async decorator (`telemetry_tool` / `telemetry_resource`).
* ``httpx`` only — no urllib fallback (httpx is a fastmcp transitive dep).
* No pyproject.toml walk — ``godot_ai.__version__`` is canonical.
* Single opt-out env (``GODOT_AI_DISABLE_TELEMETRY``) plus the shared
  ``DISABLE_TELEMETRY``.
* Session-id slugs are hashed before leaving the process (privacy: project
  directory names can be identifying — only the 4-hex twin suffix is sent
  verbatim).
* Endpoint is opt-in via ``GODOT_AI_TELEMETRY_ENDPOINT``. Empty default
  means: collector still runs and persists ``customer_uuid``, but nothing
  goes over the wire. Zero stray traffic before a backend is connected.

Fire-and-forget: a single background daemon thread drains a bounded
``queue.Queue`` and POSTs records. Telemetry never blocks the caller and
never raises out of a tool path.
"""

from __future__ import annotations

import contextlib
import functools
import hashlib
import inspect
import json
import logging
import os
import platform
import queue
import sys
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

from godot_ai import __version__ as _PACKAGE_VERSION

logger = logging.getLogger("godot-ai-telemetry")

## Public surface: anything importable from this module that callers may
## reach for. Kept small on purpose — we want a single choke point.
__all__ = [
    "MilestoneType",
    "RecordType",
    "TelemetryCollector",
    "TelemetryConfig",
    "TelemetryRecord",
    "get_telemetry",
    "hash_session_id",
    "is_telemetry_enabled",
    "record_failure",
    "record_latency",
    "record_milestone",
    "record_resource_usage",
    "record_telemetry",
    "record_tool_usage",
    "reset_telemetry",
    "shutdown_if_initialized",
    "telemetry_resource",
    "telemetry_tool",
]


class RecordType(str, Enum):
    """Top-level telemetry record categories."""

    STARTUP = "startup"
    USAGE = "usage"
    LATENCY = "latency"
    FAILURE = "failure"
    RESOURCE_RETRIEVAL = "resource_retrieval"
    TOOL_EXECUTION = "tool_execution"
    GODOT_CONNECTION = "godot_connection"
    CLIENT_CONNECTION = "client_connection"
    PLUGIN_EVENT = "plugin_event"


class MilestoneType(str, Enum):
    """One-time, first-occurrence milestones."""

    FIRST_STARTUP = "first_startup"
    FIRST_TOOL_USAGE = "first_tool_usage"
    FIRST_SCRIPT_CREATION = "first_script_creation"
    FIRST_SCENE_MODIFICATION = "first_scene_modification"
    MULTIPLE_SESSIONS = "multiple_sessions"


@dataclass
class TelemetryRecord:
    """Single record enqueued for transmission."""

    record_type: RecordType
    timestamp: float
    customer_uuid: str
    session_id: str
    data: dict[str, Any]
    milestone: MilestoneType | None = None


def hash_session_id(session_id: str | None) -> str:
    """Make a session id safe to ship: hash the slug, keep the twin suffix.

    Godot-AI session ids look like ``<slug>@<4hex>`` where ``<slug>`` is
    derived from the project directory name (potentially identifying:
    ``secret-game-prototype@a3f2``). We sha256 the slug and keep the first
    8 hex chars, preserving per-project stability without leaking the
    name. Sessions without an ``@`` (legacy or absent) hash as a whole.
    Empty / ``None`` returns ``""`` so callers can pass through raw values.
    """
    if not session_id:
        return ""
    if "@" in session_id:
        slug, _, suffix = session_id.rpartition("@")
        digest = hashlib.sha256(slug.encode("utf-8", errors="replace")).hexdigest()[:8]
        return f"{digest}@{suffix}"
    return hashlib.sha256(session_id.encode("utf-8", errors="replace")).hexdigest()[:8]


class TelemetryConfig:
    """Telemetry configuration resolved from env vars at construction time.

    Telemetry is **on by default**: a fresh install posts anonymous
    usage events to ``DEFAULT_ENDPOINT`` until the user sets
    ``GODOT_AI_DISABLE_TELEMETRY=true`` (or the cross-tool
    ``DISABLE_TELEMETRY=true``). ``GODOT_AI_TELEMETRY_ENDPOINT``
    overrides the default for self-hosters and during smoke testing.

    Privacy posture matches the docs in ``docs/TELEMETRY.md``: only
    anonymous, slug-hashed identifiers leave the process, and the
    collector is fully side-effect-free when disabled (no UUID
    generated, no worker thread, no data directory created).
    """

    ## Production telemetry endpoint baked in so installs without an
    ## env-var override actually report. Maintainers can repoint by
    ## setting ``GODOT_AI_TELEMETRY_ENDPOINT`` (e.g. self-hosters, the
    ## test backend, the local-sink smoke flow). Validated through
    ## ``_is_valid_endpoint`` like any other URL — wrong scheme /
    ## loopback / missing netloc fall back to "no sends".
    DEFAULT_ENDPOINT = "https://godot-ai-telemetry-pudmurzsnq-uw.a.run.app/events"
    DEFAULT_TIMEOUT = 1.5

    def __init__(self) -> None:
        self.enabled = not self._is_disabled_via_env()
        ## allow_loopback must be resolved before _resolve_endpoint(), which
        ## reads it to decide whether to accept http://127.0.0.1 endpoints.
        self.allow_loopback = self._env_truthy("GODOT_AI_TELEMETRY_ALLOW_LOOPBACK")
        self.endpoint = self._resolve_endpoint()
        self.timeout = self._resolve_timeout()

        ## On-disk artifacts are deferred until telemetry is actually
        ## enabled: opt-out must not create the data directory or
        ## generate a customer_uuid (see docs/TELEMETRY.md). The
        ## collector won't call _load_persistent_data when disabled,
        ## so leaving these as None is safe.
        self.data_dir: Path | None = None
        self.uuid_file: Path | None = None
        self.milestones_file: Path | None = None
        if self.enabled:
            self.data_dir = self._get_data_directory()
            self.uuid_file = self.data_dir / "customer_uuid.txt"
            self.milestones_file = self.data_dir / "milestones.json"

        self.session_id = str(uuid.uuid4())

    # --- env helpers -----------------------------------------------------

    @staticmethod
    def _env_truthy(name: str) -> bool:
        return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")

    @classmethod
    def _is_disabled_via_env(cls) -> bool:
        return cls._env_truthy("GODOT_AI_DISABLE_TELEMETRY") or cls._env_truthy("DISABLE_TELEMETRY")

    def _resolve_endpoint(self) -> str:
        ## Resolution order: env override -> baked-in default. Both go
        ## through the same scheme / loopback / netloc validation so an
        ## invalid override doesn't silently fall back to production —
        ## it stays empty and we surface a warning instead. (Falling
        ## back would mask a misconfigured self-host trying to send to
        ## the wrong place.)
        raw = os.environ.get("GODOT_AI_TELEMETRY_ENDPOINT", "").strip()
        if not raw:
            raw = self.DEFAULT_ENDPOINT
        if self._is_valid_endpoint(raw):
            return raw
        logger.warning("Telemetry endpoint %r is invalid; sends will be skipped", raw)
        return ""

    def _resolve_timeout(self) -> float:
        raw = os.environ.get("GODOT_AI_TELEMETRY_TIMEOUT")
        if not raw:
            return self.DEFAULT_TIMEOUT
        try:
            return float(raw)
        except ValueError:
            return self.DEFAULT_TIMEOUT

    def _is_valid_endpoint(self, candidate: str) -> bool:
        try:
            parsed = urlparse(candidate)
        except ValueError:
            return False
        if parsed.scheme not in ("https", "http"):
            return False
        if not parsed.netloc:
            return False
        host = (parsed.hostname or "").lower()
        if host in ("localhost", "127.0.0.1", "::1") and not self.allow_loopback:
            ## Loopback is rejected unless the operator explicitly opts in.
            ## Self-hosters and the local-sink smoke flow set
            ## GODOT_AI_TELEMETRY_ALLOW_LOOPBACK=1.
            return False
        return True

    @staticmethod
    def _get_data_directory() -> Path:
        if os.name == "nt":  # Windows
            base = Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming")))
        elif sys.platform == "darwin":
            base = Path.home() / "Library" / "Application Support"
        else:
            base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share")))
        data_dir = base / "godot-ai"
        try:
            data_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            logger.debug("Telemetry data dir %s unwritable: %s", data_dir, exc)
        return data_dir


class TelemetryCollector:
    """Queues telemetry records and drains them on a background worker."""

    QUEUE_MAXSIZE = 1000
    SHUTDOWN_TIMEOUT = 2.0

    def __init__(self, config: TelemetryConfig | None = None) -> None:
        self.config = config or TelemetryConfig()
        self._customer_uuid: str | None = None
        self._milestones: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()
        self._queue: queue.Queue[TelemetryRecord] = queue.Queue(maxsize=self.QUEUE_MAXSIZE)
        self._shutdown = False
        ## One-shot guard for the "endpoint unset" debug log in _send so a
        ## flood of dequeued records doesn't flood logs at debug level.
        self._endpoint_unset_logged = False
        ## When disabled (env opt-out), make construction fully
        ## side-effect-free: no UUID generated, no milestones loaded,
        ## no worker thread. ``record`` / ``record_milestone`` already
        ## short-circuit on ``config.enabled``, so the empty queue and
        ## dormant worker are harmless. This is the contract documented
        ## in docs/TELEMETRY.md.
        self._worker: threading.Thread | None = None
        ## Reusable httpx client. Built lazily on first send so a never-
        ## sending session (empty endpoint) doesn't pay the setup cost,
        ## and torn down in shutdown(). Reusing the client keeps the
        ## TLS handshake + connection pool warm across records — a real
        ## win on busy sessions that fire dozens of events.
        self._client: httpx.Client | None = None
        if not self.config.enabled:
            return

        self._load_persistent_data()
        self._worker = threading.Thread(
            target=self._worker_loop, name="godot-ai-telemetry", daemon=True
        )
        self._worker.start()

    # --- persistence -----------------------------------------------------

    def _load_persistent_data(self) -> None:
        try:
            if self.config.uuid_file.exists():
                self._customer_uuid = self.config.uuid_file.read_text(
                    encoding="utf-8"
                ).strip() or str(uuid.uuid4())
            else:
                self._customer_uuid = str(uuid.uuid4())
                try:
                    self.config.uuid_file.write_text(self._customer_uuid, encoding="utf-8")
                    if os.name == "posix":
                        os.chmod(self.config.uuid_file, 0o600)
                except OSError as exc:
                    logger.debug("Could not persist customer uuid: %s", exc)
        except OSError as exc:
            logger.debug("Could not load customer uuid: %s", exc)
            self._customer_uuid = str(uuid.uuid4())

        try:
            if self.config.milestones_file.exists():
                content = self.config.milestones_file.read_text(encoding="utf-8")
                parsed = json.loads(content) if content else {}
                if isinstance(parsed, dict):
                    self._milestones = parsed
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            logger.debug("Could not load milestones: %s", exc)
            self._milestones = {}

    def _save_milestones(self) -> None:
        ## Caller must hold self._lock.
        try:
            self.config.milestones_file.write_text(
                json.dumps(self._milestones, indent=2), encoding="utf-8"
            )
        except OSError as exc:
            logger.debug("Could not persist milestones: %s", exc)

    # --- public api ------------------------------------------------------

    def record(
        self,
        record_type: RecordType,
        data: dict[str, Any],
        milestone: MilestoneType | None = None,
        *,
        session_id: str | None = None,
    ) -> None:
        """Enqueue an event. Non-blocking; drops on queue full."""
        if not self.config.enabled:
            return

        record = TelemetryRecord(
            record_type=record_type,
            timestamp=time.time(),
            customer_uuid=self._customer_uuid or "unknown",
            session_id=hash_session_id(session_id) if session_id else "",
            data=data,
            milestone=milestone,
        )
        try:
            self._queue.put_nowait(record)
        except queue.Full:
            logger.debug("Telemetry queue full; dropping %s", record.record_type)

    def record_milestone(
        self, milestone: MilestoneType, data: dict[str, Any] | None = None
    ) -> bool:
        """Record a one-shot milestone. Returns ``True`` only on first call."""
        if not self.config.enabled:
            return False
        key = milestone.value
        with self._lock:
            if key in self._milestones:
                return False
            self._milestones[key] = {"timestamp": time.time(), "data": data or {}}
            self._save_milestones()

        self.record(
            RecordType.USAGE,
            {"milestone": key, **(data or {})},
            milestone=milestone,
        )
        return True

    def shutdown(self) -> None:
        self._shutdown = True
        ## Worker is None when telemetry was disabled at construction.
        if self._worker is not None and self._worker.is_alive():
            self._worker.join(timeout=self.SHUTDOWN_TIMEOUT)

        ## ``_send`` is single-consumer by design (only the worker
        ## thread calls it), so the in-method lazy-create of
        ## ``self._client`` is safe against double-construct. The
        ## race we *do* have to avoid is closing ``self._client``
        ## while the worker is mid-``post(...)``: closing an
        ## ``httpx.Client`` from another thread while a request is
        ## in flight is not an invariant httpx documents, and with
        ## ``GODOT_AI_TELEMETRY_TIMEOUT`` allowed to exceed
        ## ``SHUTDOWN_TIMEOUT`` the worker can still be inside
        ## ``post()`` when the join times out. So: only close when
        ## the worker is actually gone; otherwise leave it for
        ## process exit to clean up. This preserves the non-blocking
        ## teardown contract without closing the client mid-call.
        if self._worker is not None and self._worker.is_alive():
            logger.debug("Telemetry worker still alive at shutdown; leaving client open")
            return
        if self._client is not None:
            with contextlib.suppress(Exception):
                self._client.close()
            self._client = None

    # --- worker ----------------------------------------------------------

    def _worker_loop(self) -> None:
        while not self._shutdown:
            try:
                rec = self._queue.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self._send(rec)
            except Exception:  # noqa: BLE001  ## telemetry must never raise out
                logger.debug("Telemetry send failed", exc_info=True)
            finally:
                with contextlib.suppress(Exception):
                    self._queue.task_done()

    def _send(self, record: TelemetryRecord) -> None:
        endpoint = self.config.endpoint
        if not endpoint:
            ## Pre-backend phase: log exactly once at debug level so an
            ## operator tailing logs can confirm telemetry is alive, then
            ## drop every subsequent record silently. Without the
            ## one-shot flag, a busy session would flood debug logs.
            if not self._endpoint_unset_logged:
                logger.debug(
                    "Telemetry endpoint unset; dropping records (logged once)"
                )
                self._endpoint_unset_logged = True
            return

        enriched = dict(record.data)
        enriched.setdefault(
            "platform_detail",
            f"{platform.system()} {platform.release()} ({platform.machine()})",
        )
        enriched.setdefault("python_version", platform.python_version())

        payload: dict[str, Any] = {
            "record": record.record_type.value,
            "timestamp": record.timestamp,
            "customer_uuid": record.customer_uuid,
            "session_id": record.session_id,
            "data": enriched,
            "version": _PACKAGE_VERSION,
            "platform": platform.system(),
            "source": sys.platform,
        }
        if record.milestone is not None:
            payload["milestone"] = record.milestone.value

        try:
            if self._client is None:
                self._client = httpx.Client(timeout=self.config.timeout)
            response = self._client.post(endpoint, json=payload)
            if not 200 <= response.status_code < 300:
                logger.debug("Telemetry endpoint returned HTTP %s", response.status_code)
        except httpx.HTTPError as exc:
            logger.debug("Telemetry POST failed: %s", exc)


# --- module-level singleton + convenience helpers -----------------------

_collector: TelemetryCollector | None = None
_collector_lock = threading.Lock()


def get_telemetry() -> TelemetryCollector:
    """Return the process-wide ``TelemetryCollector``, creating on demand."""
    global _collector
    if _collector is None:
        with _collector_lock:
            if _collector is None:
                _collector = TelemetryCollector()
    return _collector


def reset_telemetry() -> None:
    """Tear down and forget the global collector. Test-only entry point."""
    global _collector
    with _collector_lock:
        if _collector is not None:
            _collector.shutdown()
            _collector = None


def shutdown_if_initialized() -> None:
    """Shut down the collector iff it was already created, and forget it.

    Lifespan teardown should call this instead of ``get_telemetry().shutdown()``
    so an opted-out server never instantiates the collector just to shut it
    down. The module-level singleton is checked under the construction lock
    so a concurrent ``get_telemetry()`` can't race us into instantiating
    a fresh collector after we've decided not to.

    Crucially: after shutting the collector down we also clear the
    module-level reference. Otherwise a subsequent lifespan start in the
    same process (uvicorn ``--reload``, repeated test runs) would call
    ``get_telemetry()`` and silently reuse the dead collector — whose
    worker has exited — and every record would enqueue into a queue
    that nothing drains.
    """
    global _collector
    with _collector_lock:
        if _collector is None:
            return
        _collector.shutdown()
        _collector = None


def record_telemetry(
    record_type: RecordType,
    data: dict[str, Any],
    milestone: MilestoneType | None = None,
    *,
    session_id: str | None = None,
) -> None:
    get_telemetry().record(record_type, data, milestone, session_id=session_id)


def record_milestone(milestone: MilestoneType, data: dict[str, Any] | None = None) -> bool:
    return get_telemetry().record_milestone(milestone, data)


def is_telemetry_enabled() -> bool:
    """Pure env check — never instantiates the collector.

    Callers may want to check the opt-out flag without paying for
    collector construction (which generates a UUID and creates the data
    directory). Reading the env vars directly preserves the
    side-effect-free contract of opt-out.
    """
    return not TelemetryConfig._is_disabled_via_env()


def _truncate(value: Any, limit: int) -> str:
    text = str(value)
    return text if len(text) <= limit else text[:limit]


def record_tool_usage(
    tool_name: str,
    success: bool,
    duration_ms: float,
    error: str | None = None,
    *,
    sub_action: str | None = None,
    session_id: str | None = None,
) -> None:
    data: dict[str, Any] = {
        "tool_name": tool_name,
        "success": success,
        "duration_ms": round(duration_ms, 2),
    }
    if sub_action is not None:
        data["sub_action"] = _truncate(sub_action, 64)
    if error:
        data["error"] = _truncate(error, 200)
    record_telemetry(RecordType.TOOL_EXECUTION, data, session_id=session_id)


def record_resource_usage(
    resource_name: str,
    success: bool,
    duration_ms: float,
    error: str | None = None,
    *,
    session_id: str | None = None,
) -> None:
    data: dict[str, Any] = {
        "resource_name": resource_name,
        "success": success,
        "duration_ms": round(duration_ms, 2),
    }
    if error:
        data["error"] = _truncate(error, 200)
    record_telemetry(RecordType.RESOURCE_RETRIEVAL, data, session_id=session_id)


def record_latency(
    operation: str,
    duration_ms: float,
    metadata: dict[str, Any] | None = None,
) -> None:
    data: dict[str, Any] = {
        "operation": operation,
        "duration_ms": round(duration_ms, 2),
    }
    if metadata:
        data.update(metadata)
    record_telemetry(RecordType.LATENCY, data)


def record_failure(
    component: str,
    error: str,
    metadata: dict[str, Any] | None = None,
) -> None:
    data: dict[str, Any] = {
        "component": component,
        "error": _truncate(error, 500),
    }
    if metadata:
        data.update(metadata)
    record_telemetry(RecordType.FAILURE, data)


# --- decorators ---------------------------------------------------------

## unity-mcp's decorator string-matches a few tool names to emit
## milestones inside the wrapper. We keep the decorator generic: handlers
## emit their own milestones explicitly via ``record_milestone``. The
## decorator only captures execution shape (success, duration, sub_action,
## error). See ``handlers/script.py`` and ``handlers/scene.py`` for the
## FIRST_SCRIPT_CREATION / FIRST_SCENE_MODIFICATION emit points.
_SUB_ACTION_KEYS = ("op", "action", "sub_action")


def _build_sub_action_extractor(func: Callable[..., Any]) -> Callable[..., str | None]:
    """Build a per-decoration closure that maps (args, kwargs) -> sub-action.

    ``inspect.signature`` is ~10us per call on a non-trivial signature;
    factoring it out of the per-invocation hot path saves that on every
    tool call. The signature can't change after decoration — we'd have
    to redecorate to see a new one — so we resolve it exactly once.

    Returns a small closure that either:
    * Looks up the positional index of the first matching sub-action
      param (resolved at decoration time), or
    * Falls back to a kwargs-only lookup if no positional binding
      is possible (TypeError / ValueError from ``inspect.signature``).
    """
    try:
        params = list(inspect.signature(func).parameters.keys())
    except (TypeError, ValueError):
        params = []
    ## Per-param: (kwarg-name, positional-index-or-None).
    candidates: list[tuple[str, int | None]] = []
    for key in _SUB_ACTION_KEYS:
        idx = params.index(key) if key in params else None
        candidates.append((key, idx))

    def extract(args: tuple[Any, ...], kwargs: dict[str, Any]) -> str | None:
        for key, idx in candidates:
            value: Any = None
            if key in kwargs:
                value = kwargs[key]
            elif idx is not None and idx < len(args):
                value = args[idx]
            if value is None:
                continue
            return str(value)
        return None

    return extract


def _extract_session_id(args: tuple[Any, ...], kwargs: dict[str, Any]) -> str | None:
    """Tools often take ``session_id``; surface it on the telemetry record."""
    if "session_id" in kwargs and kwargs["session_id"]:
        return str(kwargs["session_id"])
    return None


def _instrument(
    func: Callable[..., Any],
    *,
    name: str,
    kind: str,
) -> Callable[..., Any]:
    """Wrap ``func`` with timing + telemetry. Handles sync and async."""
    is_async = inspect.iscoroutinefunction(func)
    record = record_tool_usage if kind == "tool" else record_resource_usage
    extract_sub_action = _build_sub_action_extractor(func)

    def _emit(
        start: float, success: bool, sub: str | None, sid: str | None, err: str | None
    ) -> None:
        duration_ms = (time.perf_counter() - start) * 1000.0
        try:
            if kind == "tool":
                record(name, success, duration_ms, err, sub_action=sub, session_id=sid)
            else:
                record(name, success, duration_ms, err, session_id=sid)
        except Exception:  # noqa: BLE001  ## never let telemetry break the caller
            logger.debug("telemetry decorator emit failed", exc_info=True)

    if is_async:

        @functools.wraps(func)
        async def _async_wrapper(*args: Any, **kwargs: Any) -> Any:
            start = time.perf_counter()
            sub = extract_sub_action(args, kwargs)
            sid = _extract_session_id(args, kwargs)
            err: str | None = None
            try:
                result = await func(*args, **kwargs)
                _emit(start, True, sub, sid, None)
                return result
            except Exception as exc:
                err = str(exc)
                _emit(start, False, sub, sid, err)
                raise

        return _async_wrapper

    @functools.wraps(func)
    def _sync_wrapper(*args: Any, **kwargs: Any) -> Any:
        start = time.perf_counter()
        sub = extract_sub_action(args, kwargs)
        sid = _extract_session_id(args, kwargs)
        err: str | None = None
        try:
            result = func(*args, **kwargs)
            _emit(start, True, sub, sid, None)
            return result
        except Exception as exc:
            err = str(exc)
            _emit(start, False, sub, sid, err)
            raise

    return _sync_wrapper


def telemetry_tool(tool_name: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Decorator: record one ``tool_execution`` per call to ``func``."""

    def decorator(func: Callable[..., Any]) -> Callable[..., Any]:
        return _instrument(func, name=tool_name, kind="tool")

    return decorator


def telemetry_resource(
    resource_name: str,
) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Decorator: record one ``resource_retrieval`` per call to ``func``."""

    def decorator(func: Callable[..., Any]) -> Callable[..., Any]:
        return _instrument(func, name=resource_name, kind="resource")

    return decorator


# --- helpers used by server wiring --------------------------------------


def install_fastmcp_wraps(mcp: Any) -> None:
    """Make every subsequent ``@mcp.tool`` / ``@mcp.resource`` self-instrumenting.

    Wraps ``mcp.tool`` and ``mcp.resource`` on the given FastMCP instance
    so each registered tool/resource is automatically routed through
    ``telemetry_tool`` / ``telemetry_resource``. The wrapped function's
    ``__name__`` is used when the decorator didn't receive an explicit
    ``name=`` kwarg (FastMCP's own default behavior).

    Call this exactly once, right after constructing the FastMCP
    instance and before any ``register_<domain>_tools(mcp)`` runs. After
    that, individual tool registrations need no awareness of telemetry.
    """
    original_tool = mcp.tool
    original_resource = mcp.resource

    def _wrap_factory(original: Callable[..., Any], kind: str) -> Callable[..., Any]:
        @functools.wraps(original)
        def wrapped(*decorator_args: Any, **decorator_kwargs: Any) -> Any:
            ## FastMCP supports both `@mcp.tool` (no parens) and
            ## `@mcp.tool(name=..., ...)`. Detect bare-callable form
            ## by a single positional callable arg.
            if (
                len(decorator_args) == 1
                and not decorator_kwargs
                and callable(decorator_args[0])
                and not isinstance(decorator_args[0], type)
            ):
                func = decorator_args[0]
                inst = _instrument(func, name=func.__name__, kind=kind)
                return original(inst)

            def _apply(func: Callable[..., Any]) -> Any:
                name = decorator_kwargs.get("name") or func.__name__
                inst = _instrument(func, name=name, kind=kind)
                return original(*decorator_args, **decorator_kwargs)(inst)

            return _apply

        return wrapped

    mcp.tool = _wrap_factory(original_tool, "tool")  # type: ignore[method-assign]
    mcp.resource = _wrap_factory(original_resource, "resource")  # type: ignore[method-assign]
