"""MCP resources — read-only ``godot://...`` URIs served alongside tools.

Resources don't count against tool-count caps and are preferred for
active-session reads when the client surfaces them. Each resource module
calls into the same shared handlers as its matching tool form, with one
common ``safe_json`` wrapper that converts unhandled exceptions into a
``{"error": ..., "connected": False}`` JSON envelope so a disconnected
plugin or transient editor error doesn't surface as a 500.
"""

from __future__ import annotations

import json
from collections.abc import Awaitable
from typing import Any

__all__ = ["safe_json"]


async def safe_json(coro: Awaitable[Any]) -> str:
    """Await ``coro``, JSON-dump the result, or return a graceful error envelope.

    Used by every resource registration to avoid duplicating the same
    try/except wrapper. The error envelope shape (``{"error": str, "connected":
    False}``) is what existing clients (the dock, integration tests) already
    pattern-match on for "editor not connected" handling.
    """
    try:
        return json.dumps(await coro)
    except Exception as exc:
        return json.dumps({"error": str(exc), "connected": False})
