"""Authoritative table of connected Godot editor instances."""

from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from types import MappingProxyType
from typing import Any, Literal

from godot_ai import __version__ as _SERVER_VERSION
from godot_ai.protocol.envelope import KNOWN_READINESS, WS_PROTOCOL_VERSION
from godot_ai.protocol.errors import EditorTransportError, EditorTransportSubCode
from godot_ai.telemetry import (
    MilestoneType,
    RecordType,
    record_milestone,
    record_telemetry,
)

logger = logging.getLogger(__name__)

## Authenticated peer metadata is still untrusted telemetry input. Replace
## malformed values wholesale so the collector can count the anomaly without
## retaining attacker-controlled text.
_VERSION_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+()-]{0,63}$")

## Watermark components whose baseline resets each game run. The server may
## never observe their zero between stop/start, so on an advanced run_seq the
## current value is counted in full rather than diffed against a stale baseline.
_PER_RUN_WATERMARK_KEYS = frozenset({"game_error_warn", "game_warn"})
_WARN_WATERMARK_KEYS = frozenset({"editor_ring_warn", "game_warn"})


def _safe_version_token(value: str) -> str:
    if isinstance(value, str) and _VERSION_TOKEN_RE.match(value):
        return value
    return "invalid"


def _frozen_int_map(value: Mapping[str, int]) -> Mapping[str, int]:
    """Own one immutable copy, then reuse it across dataclass replacements."""

    return value if isinstance(value, MappingProxyType) else MappingProxyType(dict(value))


@dataclass(frozen=True, slots=True)
class Session:
    """Immutable public snapshot; the table replaces it on each transition."""

    session_id: str
    godot_version: str
    project_path: str
    plugin_version: str
    protocol_version: int = WS_PROTOCOL_VERSION
    current_scene: str = ""
    play_state: str = "stopped"
    readiness: str = "ready"
    error_watermark: Mapping[str, int] = field(default_factory=dict)
    pending_new_errors: int = 0
    pending_new_warnings: int = 0
    editor_pid: int = 0
    server_launch_mode: str = "unknown"
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    last_seen: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def __post_init__(self) -> None:
        object.__setattr__(self, "error_watermark", _frozen_int_map(self.error_watermark))

    @property
    def name(self) -> str:
        """Short human-readable name derived from project_path."""

        path = self.project_path.rstrip("/\\")
        if not path:
            return self.session_id[:8]
        for sep in ("/", "\\"):
            if sep in path:
                return path.rsplit(sep, 1)[-1]
        return path

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "name": self.name,
            "godot_version": self.godot_version,
            "project_path": self.project_path,
            "plugin_version": self.plugin_version,
            "server_version": _SERVER_VERSION,
            "protocol_version": self.protocol_version,
            "current_scene": self.current_scene,
            "play_state": self.play_state,
            "readiness": self.readiness,
            "editor_pid": self.editor_pid,
            "server_launch_mode": self.server_launch_mode,
            "connected_at": self.connected_at.isoformat(),
            "last_seen": self.last_seen.isoformat(),
        }


@dataclass
class _EditorConnection:
    phase: Literal["pending", "active"]
    session: Session
    peer: Any | None
    pending: dict[str, asyncio.Future[Any]] = field(default_factory=dict)


class PendingCommandLimitError(RuntimeError):
    """A per-peer or aggregate pending-command budget is full."""

    def __init__(
        self,
        *,
        scope: Literal["peer", "aggregate"],
        count: int,
        limit: int,
        session_id: str,
    ) -> None:
        self.scope = scope
        self.count = count
        self.limit = limit
        self.session_id = session_id
        label = "per-peer" if scope == "peer" else "aggregate"
        owner = f"Session {session_id}" if scope == "peer" else "Editor bridge"
        super().__init__(f"{owner} has {count} pending commands ({label} limit {limit})")


class SessionRegistry:
    """One table owns membership, snapshots, peers, and pending responses."""

    def __init__(
        self,
        *,
        max_pending_per_peer: int = 32,
        max_pending_total: int = 128,
    ):
        self._validate_limits(max_pending_per_peer, max_pending_total)
        self._entries: dict[str, _EditorConnection] = {}
        self._active_session_id: str | None = None
        self._pending_count = 0
        self._max_pending_per_peer = int(max_pending_per_peer)
        self._max_pending_total = int(max_pending_total)
        self._session_waiters: list[
            tuple[asyncio.Future[Session], str | None, frozenset[str], str | None]
        ] = []

    @staticmethod
    def _validate_limits(per_peer: int, total: int) -> None:
        if per_peer <= 0 or total <= 0:
            raise ValueError("pending-command limits must be positive")
        if per_peer > total:
            raise ValueError("per-peer pending-command limit cannot exceed aggregate limit")

    def reserve_connection(self, session: Session, peer: Any) -> bool:
        """Reserve an ID without making it visible or routable."""

        if session.session_id in self._entries:
            return False
        self._entries[session.session_id] = _EditorConnection(
            phase="pending",
            session=session,
            peer=peer,
        )
        return True

    def publish_connection(self, session_id: str, peer: Any) -> Session:
        """Publish a matching reservation as an active routable editor."""

        entry = self._entries.get(session_id)
        if entry is None or entry.phase != "pending" or entry.peer is not peer:
            raise KeyError(f"No matching pending connection for session {session_id}")
        entry.phase = "active"
        self._on_published(entry.session)
        return entry.session

    def register(self, session: Session) -> None:
        """Compatibility path for in-process tests without a socket peer."""

        if not self.reserve_connection(session, None):
            raise KeyError(f"Session {session.session_id} already registered")
        self.publish_connection(session.session_id, None)

    def remove_connection(
        self,
        session_id: str,
        *,
        peer: Any | None = None,
        close_code: int | None = None,
    ) -> bool:
        """Atomically remove one matching entry and fail all of its work."""

        entry = self._entries.get(session_id)
        if entry is None or (peer is not None and entry.peer is not peer):
            return False
        self._entries.pop(session_id)
        self._pending_count -= len(entry.pending)
        for request_id, future in entry.pending.items():
            if not future.done():
                future.set_exception(
                    EditorTransportError(
                        EditorTransportSubCode.EDITOR_DISCONNECTED,
                        f"Session {session_id} disconnected while request "
                        f"{request_id} was in flight"
                    )
                )
        entry.pending.clear()
        if entry.phase == "active":
            self._on_removed(session_id, close_code)
        return True

    def unregister(self, session_id: str, close_code: int | None = None) -> None:
        """Compatibility alias for metadata-only in-process registrations."""

        self.remove_connection(session_id, close_code=close_code)

    def get(self, session_id: str) -> Session | None:
        entry = self._active_entry(session_id)
        return entry.session if entry is not None else None

    def get_active(self) -> Session | None:
        return self.get(self._active_session_id) if self._active_session_id else None

    def set_active(self, session_id: str) -> None:
        if self._active_entry(session_id) is None:
            raise KeyError(f"Session {session_id} not found")
        self._active_session_id = session_id

    def list_all(self) -> list[Session]:
        return [entry.session for entry in self._entries.values() if entry.phase == "active"]

    @property
    def active_session_id(self) -> str | None:
        return self._active_session_id

    @property
    def pending_count(self) -> int:
        return self._pending_count

    def note_peer_activity(self, session_id: str) -> bool:
        return self._replace_session(
            session_id,
            last_seen=datetime.now(timezone.utc),
        )

    def record_scene_changed(self, session_id: str, current_scene: str) -> bool:
        return self._replace_session(session_id, current_scene=current_scene)

    def record_play_state_changed(self, session_id: str, play_state: str) -> bool:
        return self._replace_session(session_id, play_state=play_state)

    def record_readiness(self, session_id: str, readiness: object) -> bool:
        entry = self._active_entry(session_id)
        if entry is None or readiness not in KNOWN_READINESS:
            return False
        if entry.session.readiness == readiness:
            return False
        entry.session = replace(entry.session, readiness=readiness)
        return True

    def record_error_watermark(self, session_id: str, value: Mapping[str, int]) -> bool:
        entry = self._active_entry(session_id)
        if entry is None:
            return False
        watermark, new_errors, new_warnings = _fold_error_watermark(entry.session, value)
        entry.session = replace(
            entry.session,
            error_watermark=watermark,
            pending_new_errors=entry.session.pending_new_errors + new_errors,
            pending_new_warnings=entry.session.pending_new_warnings + new_warnings,
        )
        return True

    def consume_diagnostic_counts(self, session_id: str) -> tuple[int, int]:
        """Return and atomically clear both diagnostic hint counters."""

        entry = self._active_entry(session_id)
        if entry is None:
            return (0, 0)
        counts = (entry.session.pending_new_errors, entry.session.pending_new_warnings)
        if counts != (0, 0):
            entry.session = replace(
                entry.session,
                pending_new_errors=0,
                pending_new_warnings=0,
            )
        return counts

    def open_request(
        self,
        session_id: str,
        request_id: str,
    ) -> tuple[Any, asyncio.Future[Any]]:
        entry = self._active_entry(session_id)
        if entry is None or entry.peer is None:
            raise ConnectionError(f"No connection for session {session_id}")
        local_count = len(entry.pending)
        if local_count >= self._max_pending_per_peer:
            raise PendingCommandLimitError(
                scope="peer",
                count=local_count,
                limit=self._max_pending_per_peer,
                session_id=session_id,
            )
        if self._pending_count >= self._max_pending_total:
            raise PendingCommandLimitError(
                scope="aggregate",
                count=self._pending_count,
                limit=self._max_pending_total,
                session_id=session_id,
            )
        if request_id in entry.pending:
            raise RuntimeError(f"Duplicate request id {request_id} for session {session_id}")
        future = asyncio.get_running_loop().create_future()
        entry.pending[request_id] = future
        self._pending_count += 1
        return entry.peer, future

    def claim_pending_response(
        self,
        session_id: str,
        request_id: str,
        *,
        peer: Any,
    ) -> asyncio.Future[Any] | None:
        """Claim a response only when its source session owns the request."""

        future = self._pop_request(session_id, request_id, peer=peer)
        return future if future is not None and not future.done() else None

    def cancel_request(
        self,
        session_id: str,
        request_id: str,
        *,
        peer: Any | None = None,
    ) -> bool:
        future = self._pop_request(session_id, request_id, peer=peer)
        if future is None:
            return False
        if not future.done():
            future.cancel()
        return True

    async def wait_for_session(
        self,
        exclude_id: str | None = None,
        timeout: float = 15.0,
        *,
        known_ids: set[str] | frozenset[str] | None = None,
        project_path: str | None = None,
    ) -> Session:
        """Block until a matching active session is published."""

        loop = asyncio.get_running_loop()
        known_ids_frozen = (
            frozenset(session.session_id for session in self.list_all())
            if known_ids is None
            else frozenset(known_ids)
        )
        existing = self._find_matching_session(
            exclude_id=exclude_id,
            known_ids=known_ids_frozen,
            project_path=project_path,
        )
        if existing is not None:
            return existing
        future: asyncio.Future[Session] = loop.create_future()
        entry = (future, exclude_id, known_ids_frozen, project_path)
        self._session_waiters.append(entry)
        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            raise TimeoutError("Timed out waiting for new session") from None
        finally:
            self._session_waiters = [
                waiter for waiter in self._session_waiters if waiter is not entry
            ]
            if not future.done():
                future.cancel()

    def _find_matching_session(
        self,
        *,
        exclude_id: str | None,
        known_ids: frozenset[str],
        project_path: str | None,
    ) -> Session | None:
        for session in self.list_all():
            if self._matches_wait_criteria(
                session,
                exclude_id=exclude_id,
                known_ids=known_ids,
                project_path=project_path,
            ):
                return session
        return None

    @staticmethod
    def _matches_wait_criteria(
        session: Session,
        *,
        exclude_id: str | None,
        known_ids: frozenset[str],
        project_path: str | None,
    ) -> bool:
        if exclude_id is not None and session.session_id == exclude_id:
            return False
        if session.session_id in known_ids:
            return False
        return project_path is None or session.project_path == project_path

    def _active_entry(self, session_id: str | None) -> _EditorConnection | None:
        if session_id is None:
            return None
        entry = self._entries.get(session_id)
        return entry if entry is not None and entry.phase == "active" else None

    def _replace_session(self, session_id: str, **changes: Any) -> bool:
        entry = self._active_entry(session_id)
        if entry is None:
            return False
        entry.session = replace(entry.session, **changes)
        return True

    def _pop_request(
        self,
        session_id: str,
        request_id: str,
        *,
        peer: Any | None = None,
    ) -> asyncio.Future[Any] | None:
        entry = self._active_entry(session_id)
        if entry is None or (peer is not None and entry.peer is not peer):
            return None
        future = entry.pending.pop(request_id, None)
        if future is not None:
            self._pending_count -= 1
        return future

    def _on_published(self, session: Session) -> None:
        if self._active_session_id is None:
            self._active_session_id = session.session_id
        try:
            record_telemetry(
                RecordType.GODOT_CONNECTION,
                {
                    "event": "connected",
                    "godot_version": _safe_version_token(session.godot_version),
                    "plugin_version": _safe_version_token(session.plugin_version),
                    "protocol_version": _safe_version_token(str(session.protocol_version)),
                    "server_launch_mode": _safe_version_token(session.server_launch_mode),
                    "session_count": len(self),
                },
                session_id=session.session_id,
            )
            if len(self) >= 2:
                record_milestone(MilestoneType.MULTIPLE_SESSIONS)
        except Exception:  # noqa: BLE001
            logger.debug("session connect telemetry failed", exc_info=True)

        remaining = []
        for future, exclude_id, known_ids, project_path in self._session_waiters:
            if future.done():
                continue
            if not self._matches_wait_criteria(
                session,
                exclude_id=exclude_id,
                known_ids=known_ids,
                project_path=project_path,
            ):
                remaining.append((future, exclude_id, known_ids, project_path))
                continue
            future.set_result(session)
        self._session_waiters = remaining

    def _on_removed(self, session_id: str, close_code: int | None) -> None:
        try:
            record_telemetry(
                RecordType.GODOT_CONNECTION,
                {
                    "event": "disconnected",
                    "session_count": len(self),
                    "close_code": close_code,
                },
                session_id=session_id,
            )
        except Exception:  # noqa: BLE001
            logger.debug("session disconnect telemetry failed", exc_info=True)
        if self._active_session_id != session_id:
            return
        self._active_session_id = None
        survivors = self.list_all()
        if len(survivors) == 1:
            survivor_id = survivors[0].session_id
            self._active_session_id = survivor_id
            logger.warning(
                "Active session %s disconnected; auto-promoting sole survivor %s",
                session_id[:8],
                survivor_id[:8],
            )
        else:
            logger.info(
                "Active session %s disconnected; no active session until next register/activate",
                session_id[:8],
            )

    def __len__(self) -> int:
        return sum(entry.phase == "active" for entry in self._entries.values())


def _fold_error_watermark(
    session: Session,
    value: Mapping[str, int],
) -> tuple[Mapping[str, int], int, int]:
    """Return the updated watermark plus newly observed errors and warnings."""

    updates: dict[str, int] = {}
    deltas: dict[str, int] = {}
    incoming_run_seq = value.get("run_seq")
    previous_run_seq = session.error_watermark.get("run_seq", 0)
    run_advanced = (
        incoming_run_seq is not None
        and previous_run_seq > 0
        and incoming_run_seq > previous_run_seq
    )
    for key, current in value.items():
        updates[key] = current
        if key == "run_seq":
            continue
        previous = session.error_watermark.get(key)
        if previous is not None:
            if run_advanced and key in _PER_RUN_WATERMARK_KEYS:
                deltas[key] = current
            elif current >= previous:
                deltas[key] = current - previous
            else:
                deltas[key] = current
        elif run_advanced and key in _PER_RUN_WATERMARK_KEYS:
            deltas[key] = current

    new_warnings = sum(deltas.pop(key, 0) for key in _WARN_WATERMARK_KEYS)
    overlap = max(deltas.pop("debugger_promoted", 0), deltas.pop("game_error_warn", 0))
    merged = dict(session.error_watermark)
    merged.update(updates)
    return MappingProxyType(merged), overlap + sum(deltas.values()), new_warnings
