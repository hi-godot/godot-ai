"""MCP resources — read-only ``godot://...`` URIs served alongside tools.

Resources don't count against tool-count caps and are preferred for
active-session reads when the client surfaces them. Each resource module
calls into the same shared handlers as its matching tool form, with one
common ``safe_payload`` wrapper that converts unhandled exceptions into a
``{"error": ..., "connected": False}`` JSON envelope so a disconnected
plugin or transient editor error doesn't surface as a 500.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

__all__ = ["safe_payload", "safe_payload_sync"]


def safe_payload_sync(fn: Callable[[], Any]) -> dict[str, Any]:
    """Sync sibling of :func:`safe_payload` for non-async resource handlers.

    Calls ``fn()`` and returns its dict payload, or the same graceful
    ``{"error": ..., "connected": False}`` envelope on any exception, so
    every ``godot://...`` resource — sync or async — shares one
    error-envelope contract instead of letting some surface a raw 500.
    """
    try:
        return fn()
    except Exception as exc:
        return {"error": str(exc), "connected": False}


async def safe_payload(coro: Awaitable[Any]) -> dict[str, Any]:
    """Await ``coro`` and return its dict payload, or a graceful error envelope.

    Returns the dict directly (not a JSON string) so FastMCP's
    ``ResourceContent`` auto-serializes it as ``application/json`` — the
    pre-stringified path infers ``text/plain`` for resource templates
    because ``ResourceResult.__init__`` doesn't forward the template's
    registered ``mime_type`` when the function returns ``str``. Returning
    ``dict`` sidesteps that path entirely and keeps the MIME consistent
    across static resources and templates.

    The error envelope shape (``{"error": str, "connected": False}``) is
    what existing clients (the dock, integration tests) already pattern-
    match on for "editor not connected" handling.
    """
    try:
        return await coro
    except Exception as exc:
        return {"error": str(exc), "connected": False}
