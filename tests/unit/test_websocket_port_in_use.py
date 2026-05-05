"""Regression: GodotWebSocketServer.start() handles EADDRINUSE on every OS.

Audit v2 #348 — `errno == 48` only matched macOS. Linux uses 98, Windows
uses 10048. On Linux/Windows the friendly branch never fired and the WS
server lifespan died with a generic traceback.
"""

from __future__ import annotations

import asyncio
import errno
import logging
from unittest.mock import patch

import pytest

from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.websocket import GodotWebSocketServer


def _make_server() -> GodotWebSocketServer:
    return GodotWebSocketServer(SessionRegistry(), port=19999)


class _FakeServeRaisingOSError:
    """Stand-in for `websockets.serve(...)` that raises OSError on enter."""

    def __init__(self, errno_value: int):
        self._errno_value = errno_value

    async def __aenter__(self):
        raise OSError(self._errno_value, "fake bind failure")

    async def __aexit__(self, *_exc):
        return False


@pytest.mark.parametrize(
    "errno_value,platform_name",
    [
        (48, "macOS"),
        (98, "Linux"),
        (10048, "Windows"),
        (errno.EADDRINUSE, "host-native"),
    ],
)
async def test_start_swallows_address_in_use_on_every_platform(
    errno_value: int, platform_name: str, caplog: pytest.LogCaptureFixture
) -> None:
    """The friendly branch must fire for EADDRINUSE regardless of host OS.

    `errno.EADDRINUSE` resolves to a different int on each platform; the
    fix in #348 swaps the hardcoded `48` for the symbolic constant. This
    test forces all three concrete values plus the host-native one to
    catch any future regression that re-hardcodes a single value.
    """
    server = _make_server()
    caplog.set_level(logging.WARNING)

    with patch(
        "godot_ai.transport.websocket.websockets.serve",
        return_value=_FakeServeRaisingOSError(errno_value),
    ):
        with patch(
            "godot_ai.transport.websocket.errno.EADDRINUSE",
            errno_value,
        ):
            ## start() should return cleanly (no raise) and log the warning.
            await asyncio.wait_for(server.start(), timeout=1.0)

    assert any("already in use" in record.getMessage() for record in caplog.records), (
        f"expected friendly warning for {platform_name} errno={errno_value}"
    )


async def test_start_propagates_other_oserrors() -> None:
    """A non-EADDRINUSE OSError must surface — don't swallow real bind bugs."""
    server = _make_server()

    with patch(
        "godot_ai.transport.websocket.websockets.serve",
        return_value=_FakeServeRaisingOSError(errno.EACCES),
    ):
        with pytest.raises(OSError) as exc_info:
            await asyncio.wait_for(server.start(), timeout=1.0)

    assert exc_info.value.errno == errno.EACCES


async def test_start_uses_symbolic_eaddrinuse_not_hardcoded_int() -> None:
    """Guard against re-introducing `errno == 48`.

    If somebody re-hardcodes the macOS value, this test fails on
    Linux/Windows runners where errno.EADDRINUSE != 48.
    """
    server = _make_server()

    with patch(
        "godot_ai.transport.websocket.websockets.serve",
        return_value=_FakeServeRaisingOSError(errno.EADDRINUSE),
    ):
        ## Must not raise — irrespective of what int EADDRINUSE happens to
        ## be on the runner.
        await asyncio.wait_for(server.start(), timeout=1.0)
