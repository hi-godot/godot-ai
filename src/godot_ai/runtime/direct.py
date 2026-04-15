"""Direct, in-process runtime adapter."""

from __future__ import annotations

from typing import Any, Protocol

from fastmcp import Context

from godot_ai.godot_client.client import GodotClient
from godot_ai.sessions.registry import Session, SessionRegistry


class SupportsDirectRuntime(Protocol):
    registry: SessionRegistry
    client: GodotClient


class DirectRuntime:
    """In-process runtime used by the current single-process server."""

    def __init__(
        self,
        registry: SessionRegistry,
        client: GodotClient,
        session_id: str | None = None,
    ):
        self._registry = registry
        self._client = client
        self._bound_session_id = session_id

    @classmethod
    def from_context(cls, ctx: Context, session_id: str | None = None) -> DirectRuntime:
        app = ctx.fastmcp._lifespan_result
        if app is None:
            raise RuntimeError("FastMCP lifespan context is not available")
        return cls.from_app_context(app, session_id=session_id)

    @classmethod
    def from_app_context(
        cls, app: SupportsDirectRuntime, session_id: str | None = None
    ) -> DirectRuntime:
        return cls(registry=app.registry, client=app.client, session_id=session_id)

    async def send_command(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict[str, Any]:
        return await self._client.send(
            command=command,
            params=params,
            session_id=session_id if session_id is not None else self._bound_session_id,
            timeout=timeout,
        )

    def list_sessions(self) -> list[Session]:
        return self._registry.list_all()

    def get_active_session(self) -> Session | None:
        if self._bound_session_id is not None:
            return self._registry.get(self._bound_session_id)
        return self._registry.get_active()

    @property
    def active_session_id(self) -> str | None:
        return self._bound_session_id or self._registry.active_session_id

    def set_active_session(self, session_id: str) -> None:
        self._registry.set_active(session_id)

    async def wait_for_session(
        self, exclude_id: str | None = None, timeout: float = 15.0
    ) -> Session:
        return await self._registry.wait_for_session(exclude_id=exclude_id, timeout=timeout)
