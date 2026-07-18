"""Property-based tests for the tileset_get_atlas_tiles Python handler.

# Feature: tileset-atlas-knowledge, Property 2/3

These tests exercise universal properties of the handler using hypothesis,
running >= 100 examples per property.  They are pure unit tests and run
offline — no Godot editor connection required.

**Validates: Requirements 2.2, 2.3, 8.2**
"""

from __future__ import annotations

import asyncio
from unittest.mock import patch

from hypothesis import given, settings
from hypothesis import strategies as st

from godot_ai.handlers import tileset as tileset_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import SessionRegistry

# ---------------------------------------------------------------------------
# Shared stub client
# ---------------------------------------------------------------------------


class _FixedReturnClient:
    """Minimal stub that records send_command calls and returns a fixed dict."""

    def __init__(self, return_value: dict) -> None:
        self._return_value = return_value
        self.calls: list[dict] = []

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
        hint_policy=None,
    ) -> dict:
        self.calls.append({"command": command, "params": params or {}})
        return self._return_value


def _make_runtime(return_value: dict) -> tuple[DirectRuntime, _FixedReturnClient]:
    client = _FixedReturnClient(return_value)
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    return runtime, client


# ---------------------------------------------------------------------------
# Property 2: Python handler pass-through — command and params
#
# For any tileset_path string and source_id integer, tileset_get_atlas_tiles
# SHALL call runtime.send_command with:
#   - command name "tileset_get_atlas_tiles"
#   - a params dict containing EXACTLY the keys "tileset_path" and
#     "source_id" with the supplied values
# AND SHALL return the result of send_command unchanged.
#
# Feature: tileset-atlas-knowledge, Property 2
# Validates: Requirement 2.2
# ---------------------------------------------------------------------------

_FIXED_RESPONSE = {"data": {"tiles": [{"col": 0, "row": 0}], "count": 1}}


@given(st.text(), st.integers())
@settings(max_examples=100)
def test_property_2_handler_pass_through(tileset_path: str, source_id: int) -> None:
    """**Validates: Requirements 2.2**

    For every (tileset_path, source_id) pair:
    - send_command is called exactly once
    - with command "tileset_get_atlas_tiles"
    - with params dict having exactly keys "tileset_path" and "source_id"
      mapping to the supplied values
    - the return value is the send_command result unchanged
    """

    async def _run() -> tuple[dict, list[dict]]:
        runtime, client = _make_runtime(_FIXED_RESPONSE)
        result = await tileset_handlers.tileset_get_atlas_tiles(
            runtime, tileset_path=tileset_path, source_id=source_id
        )
        return result, client.calls

    result, calls = asyncio.run(_run())

    # exactly one send_command call
    assert len(calls) == 1, f"expected 1 send_command call, got {len(calls)}"

    call = calls[0]

    # correct command name
    assert call["command"] == "tileset_get_atlas_tiles", (
        f"expected command 'tileset_get_atlas_tiles', got {call['command']!r}"
    )

    params = call["params"]

    # params dict has exactly the two expected keys
    assert set(params.keys()) == {"tileset_path", "source_id"}, (
        f"expected params keys {{'tileset_path', 'source_id'}}, got {set(params.keys())}"
    )

    # values match the supplied arguments
    assert params["tileset_path"] == tileset_path, (
        f"tileset_path mismatch: expected {tileset_path!r}, got {params['tileset_path']!r}"
    )
    assert params["source_id"] == source_id, (
        f"source_id mismatch: expected {source_id!r}, got {params['source_id']!r}"
    )

    # return value is the send_command result unchanged (identity, not a copy)
    assert result is _FIXED_RESPONSE, (
        "tileset_get_atlas_tiles must return send_command result unchanged (no re-wrapping)"
    )


# ---------------------------------------------------------------------------
# Property 3: No write-readiness gate for read-only operation
#
# For any call to tileset_get_atlas_tiles, require_writable_async SHALL
# never be invoked — the function proceeds regardless of editor state.
#
# Feature: tileset-atlas-knowledge, Property 3
# Validates: Requirements 2.3, 8.2
# ---------------------------------------------------------------------------


@given(st.text(), st.integers())
@settings(max_examples=100)
def test_property_3_no_write_readiness_gate(tileset_path: str, source_id: int) -> None:
    """**Validates: Requirements 2.3, 8.2**

    For every (tileset_path, source_id) pair, require_writable_async is
    never called/awaited — tileset_get_atlas_tiles is read-only and must
    not gate on editor write-readiness.
    """
    call_count = 0

    async def _spy_require_writable(rt: DirectRuntime) -> None:
        nonlocal call_count
        call_count += 1

    async def _run() -> None:
        runtime, _ = _make_runtime({"ok": True})
        with patch(
            "godot_ai.handlers.tileset.require_writable_async",
            side_effect=_spy_require_writable,
            create=True,
        ):
            await tileset_handlers.tileset_get_atlas_tiles(
                runtime, tileset_path=tileset_path, source_id=source_id
            )

    asyncio.run(_run())

    assert call_count == 0, (
        f"require_writable_async was called {call_count} time(s) — "
        "tileset_get_atlas_tiles must not gate on write-readiness"
    )
