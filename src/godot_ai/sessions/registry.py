"""Session registry — tracks connected Godot editor instances."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from functools import cached_property
from threading import RLock

from godot_ai import __version__ as _SERVER_VERSION

logger = logging.getLogger(__name__)


@dataclass
class Session:
    """A connected Godot editor session."""

    session_id: str
    godot_version: str
    project_path: str
    plugin_version: str
    protocol_version: int = 1
    current_scene: str = ""
    play_state: str = "stopped"
    readiness: str = "ready"
    editor_pid: int = 0
    ## Which launcher tier the plugin resolved the Python server from —
    ## "dev_venv" | "uvx" | "system" | "unknown". Lets agents notice when a
    ## plugin-level update left an older server running, or when a stray
    ## dev `.venv` is silently overriding the published install. Older
    ## plugins omit this in the handshake; default is "unknown".
    server_launch_mode: str = "unknown"
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    last_seen: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    @cached_property
    def name(self) -> str:
        """Short human-readable name derived from project_path.

        E.g. '/Users/x/Documents/godot-ai/test_project/' -> 'test_project'.
        Falls back to the first 8 chars of session_id if the path is empty.
        """
        path = self.project_path.rstrip("/\\")
        if not path:
            return self.session_id[:8]
        for sep in ("/", "\\"):
            if sep in path:
                return path.rsplit(sep, 1)[-1]
        return path

    def touch(self) -> None:
        """Update last_seen to now. Called on every inbound message."""
        self.last_seen = datetime.now(timezone.utc)

    def to_dict(self) -> dict:
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


class SessionRegistry:
    """Tracks all connected Godot editor sessions."""

    def __init__(self):
        self._sessions: dict[str, Session] = {}
        self._active_session_id: str | None = None
        self._session_waiters: list[
            tuple[asyncio.Future[Session], str | None, frozenset[str], str | None]
        ] = []
        self._lock = RLock()

    def register(self, session: Session) -> None:
        to_notify: list[asyncio.Future[Session]] = []
        with self._lock:
            self._sessions[session.session_id] = session
            if self._active_session_id is None:
                self._active_session_id = session.session_id
            # Notify any waiters blocked on wait_for_session()
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
                to_notify.append(future)
            self._session_waiters = remaining

        for future in to_notify:
            if not future.done():
                future.set_result(session)

    def unregister(self, session_id: str) -> None:
        ## Do NOT silently promote another session to active when the active
        ## one disconnects. Promoting by insertion order means a crash or
        ## editor_quit on the user's working editor would route subsequent
        ## commands to whichever editor happened to connect first — the
        ## "routing by registration order" bug. Clear active instead; the
        ## next register() or an explicit session_activate will set it.
        should_log = False
        with self._lock:
            self._sessions.pop(session_id, None)
            if self._active_session_id == session_id:
                self._active_session_id = None
                should_log = True
        if should_log:
            logger.info(
                "Active session %s disconnected; no active session until next register/activate",
                session_id[:8],
            )

    def get(self, session_id: str) -> Session | None:
        with self._lock:
            return self._sessions.get(session_id)

    def get_active(self) -> Session | None:
        with self._lock:
            if self._active_session_id:
                return self._sessions.get(self._active_session_id)
            return None

    def set_active(self, session_id: str) -> None:
        with self._lock:
            if session_id not in self._sessions:
                raise KeyError(f"Session {session_id} not found")
            self._active_session_id = session_id

    def list_all(self) -> list[Session]:
        with self._lock:
            return list(self._sessions.values())

    @property
    def active_session_id(self) -> str | None:
        with self._lock:
            return self._active_session_id

    async def wait_for_session(
        self,
        exclude_id: str | None = None,
        timeout: float = 15.0,
        *,
        known_ids: set[str] | frozenset[str] | None = None,
        project_path: str | None = None,
    ) -> Session:
        """Block until a new session registers (optionally excluding one ID).

        If ``known_ids`` is provided, sessions registered after that snapshot but
        before this waiter is installed are returned under the same registry lock.
        Raises TimeoutError if no matching session appears within timeout.
        """
        loop = asyncio.get_running_loop()
        with self._lock:
            known_ids_frozen = (
                frozenset(self._sessions) if known_ids is None else frozenset(known_ids)
            )
            existing = self._find_matching_session_locked(
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
            with self._lock:
                self._session_waiters = [w for w in self._session_waiters if w is not entry]
            if not future.done():
                future.cancel()

    def _find_matching_session_locked(
        self,
        *,
        exclude_id: str | None,
        known_ids: frozenset[str],
        project_path: str | None,
    ) -> Session | None:
        for session in self._sessions.values():
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
        if project_path is not None and session.project_path != project_path:
            return False
        return True

    def __len__(self) -> int:
        with self._lock:
            return len(self._sessions)
