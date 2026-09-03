"""GodotWebSocketServer.start() keepalive (ping/pong) configuration.

The editor answers server pings only from `McpConnection._process` →
`WebSocketPeer.poll()` on the Godot main thread. Any stall longer than the
pong deadline — a long synchronous editor operation, or a CPU-starved CI
runner where the editor and the game subprocess both software-render under
lavapipe (#958) — makes `websockets` close the session with 1011
"keepalive ping timeout". These tests pin the deadline the server hands to
`websockets.serve` so it cannot silently fall back to the library default.
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Any
from unittest.mock import patch

from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport import websocket as websocket_module
from godot_ai.transport.websocket import (
    DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS,
    DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS,
    GodotWebSocketServer,
)


async def _capture_serve_kwargs() -> dict[str, Any]:
    """Run start() against a fake `websockets.serve` and return its kwargs."""
    captured: dict[str, Any] = {}
    entered = asyncio.Event()

    @asynccontextmanager
    async def _fake_serve(*_args: Any, **kwargs: Any):
        captured.update(kwargs)
        entered.set()
        yield object()
        ## Let start() reach `await asyncio.Future()`; the caller cancels it.

    server = GodotWebSocketServer(SessionRegistry(), port=19998)
    with patch("godot_ai.transport.websocket.websockets.serve", _fake_serve):
        task = asyncio.create_task(server.start())
        ## v3's server has no wait_until_ready(); the fake serve signals
        ## the moment start() has handed it the kwargs.
        await asyncio.wait_for(entered.wait(), timeout=5.0)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
    return captured


async def test_start_passes_explicit_keepalive_settings() -> None:
    kwargs = await _capture_serve_kwargs()
    assert kwargs["ping_interval"] == DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS
    assert kwargs["ping_timeout"] == DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS


def test_keepalive_deadline_tolerates_a_long_editor_stall() -> None:
    ## #958: the CI editor missed a pong for >20s while the game subprocess
    ## booted under lavapipe, and the smoke's 45s session-loss grace could
    ## not save a session the server had already reaped. The pong deadline
    ## must comfortably exceed that grace so a bounded stall is survivable;
    ## a stall past this budget is a genuinely hung editor.
    assert DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS >= 60.0
    ## Pings stay frequent so `last_seen` / latency observations keep their
    ## cadence — only the tolerance for a late pong is widened.
    assert DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS <= 20.0
    ## Sanity: the constants are what serve() actually receives, not shadows.
    assert websocket_module.DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS > (
        websocket_module.DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS
    )
