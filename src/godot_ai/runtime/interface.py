"""Runtime interface consumed by shared handlers."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any, Protocol

from godot_ai.sessions.registry import Session


class Runtime(Protocol):
    """Minimal runtime surface shared handlers rely on."""

    async def send_command(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict[str, Any]: ...

    def list_sessions(self) -> Sequence[Session]: ...

    def get_active_session(self) -> Session | None: ...

    @property
    def active_session_id(self) -> str | None: ...

    def set_active_session(self, session_id: str) -> None: ...

    async def wait_for_session(
        self, exclude_id: str | None = None, timeout: float = 15.0
    ) -> Session: ...

