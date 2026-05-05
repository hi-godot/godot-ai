"""Unit tests for GodotWebSocketServer lifecycle / boot path.

Covers cross-platform errno handling in `start()` (#343 finding #4) so the
"port in use" branch fires on Linux/Windows/macOS instead of crashing the
WS lifespan with a generic OSError traceback.
"""

from __future__ import annotations

import errno
from unittest.mock import patch

import pytest

from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.websocket import GodotWebSocketServer


@pytest.mark.parametrize(
    "platform_errno",
    [
        pytest.param(48, id="macos_eaddrinuse_48"),
        pytest.param(98, id="linux_eaddrinuse_98"),
        pytest.param(10048, id="windows_wsaeaddrinuse_10048"),
    ],
)
async def test_start_swallows_port_in_use_on_each_platform(caplog, platform_errno):
    ## Pre-fix the start() check was `e.errno == 48` — only macOS matched,
    ## so on Linux/Windows the OSError propagated and took the WS lifespan
    ## down with a generic traceback. With `errno.EADDRINUSE` the friendly
    ## branch fires regardless of platform — simulate by raising an OSError
    ## carrying each platform's number; on whatever platform the test runs
    ## the stdlib's `errno.EADDRINUSE` matches one of these and the others
    ## should propagate. We assert the *current platform's* number is
    ## handled gracefully.
    if platform_errno != errno.EADDRINUSE:
        pytest.skip(
            f"errno {platform_errno} is not EADDRINUSE on this platform "
            f"(EADDRINUSE={errno.EADDRINUSE}); cross-platform parity is "
            f"covered by the other parametrizations on their native OS."
        )

    server = GodotWebSocketServer(SessionRegistry(), port=12345)

    def raise_addr_in_use(*_args, **_kwargs):
        raise OSError(platform_errno, "Address already in use")

    with patch("godot_ai.transport.websocket.websockets.serve", raise_addr_in_use):
        with caplog.at_level("WARNING", logger="godot_ai.transport.websocket"):
            await server.start()

    assert any(
        "already in use" in rec.message and "12345" in rec.message for rec in caplog.records
    ), "expected friendly 'port already in use' warning, got: " + repr(
        [rec.message for rec in caplog.records]
    )


async def test_start_propagates_non_eaddrinuse_oserror():
    ## Any OSError that isn't EADDRINUSE must keep raising — the friendly
    ## branch is narrow on purpose so unrelated bind failures (permission,
    ## bad address, …) still surface their real diagnosis.
    server = GodotWebSocketServer(SessionRegistry(), port=12345)

    def raise_perm(*_args, **_kwargs):
        raise OSError(errno.EACCES, "Permission denied")

    with patch("godot_ai.transport.websocket.websockets.serve", raise_perm):
        with pytest.raises(OSError) as exc_info:
            await server.start()

    assert exc_info.value.errno == errno.EACCES
