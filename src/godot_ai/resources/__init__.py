"""MCP resources — read-only ``godot://...`` URIs served alongside tools.

Resources don't count against tool-count caps and are preferred for
active-session reads when the client surfaces them. Each resource module
calls into the same shared handlers as its matching tool form, with one
common ``safe_payload`` wrapper for resource errors.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import EditorTransportSubCode, ErrorCode

__all__ = ["safe_payload", "safe_payload_sync"]


def _resource_error(exc: Exception) -> dict[str, Any]:
    if isinstance(exc, GodotCommandError):
        result = {"error": str(exc), "code": exc.code, "data": exc.data}
        if (
            exc.data.get("connected") is False
            or exc.code in {ErrorCode.PLUGIN_DISCONNECTED, ErrorCode.SESSION_NOT_FOUND}
            or exc.data.get("sub_code") == EditorTransportSubCode.EDITOR_DISCONNECTED
        ):
            result["connected"] = False
        return result
    return {"error": str(exc), "connected": False}


def safe_payload_sync(fn: Callable[[], Any]) -> dict[str, Any]:
    """Sync sibling of :func:`safe_payload` for non-async resource handlers.

    Sync and async resources use the same command and disconnection envelopes.
    """
    try:
        return fn()
    except Exception as exc:
        return _resource_error(exc)


async def safe_payload(coro: Awaitable[Any]) -> dict[str, Any]:
    """Await ``coro`` and return its dict payload, or a graceful error envelope.

    Returns the dict directly (not a JSON string) so FastMCP's
    ``ResourceContent`` auto-serializes it as ``application/json`` — the
    pre-stringified path infers ``text/plain`` for resource templates
    because ``ResourceResult.__init__`` doesn't forward the template's
    registered ``mime_type`` when the function returns ``str``. Returning
    ``dict`` sidesteps that path entirely and keeps the MIME consistent
    across static resources and templates.

    Disconnection errors retain the connected flag. Editor errors carry
    the command's code and data, including any retry guidance.
    """
    try:
        return await coro
    except Exception as exc:
        return _resource_error(exc)
