"""Source-level contract for the #777 game-screenshot timeout split.

``editor_screenshot(source="game")`` was the largest opaque failure bucket
fleet-wide: a backgrounded play-in-editor game freezes its main loop, the
game-side capture coroutine parks on ``await tree.process_frame``, no reply is
ever sent, and the editor's 8s timer surfaced a bare INTERNAL_ERROR. The fix
has two halves, both GDScript-side and neither reachable from the live
GDScript test runner end-to-end (the harness editor has no frozen game
subprocess), so this file locks the load-bearing source shapes the same way
``test_editor_not_ready_hint_contract.py`` does for the no-scene branch:

1. ``runtime/game_helper.gd`` commits a synchronous stale-frame capture when
   the main loop is stalled, instead of awaiting frames that will never come.
2. ``debugger/mcp_debugger_plugin.gd::_on_timeout`` mirrors the eval split
   (#518): not-live keeps the attributed ``_explain_not_live`` payload; a
   live-but-unresponsive game gets the new top-level GAME_HELPER_TIMEOUT with
   an actionable hint.

The GAME_HELPER_TIMEOUT GDScript/Python parity itself is enforced by
``test_error_code_parity.py``; behavior of the decision helpers is covered by
the GDScript suites (``test_game_helper.gd``, ``test_editor.gd``).
"""

from __future__ import annotations

from pathlib import Path

from godot_ai.protocol.errors import ErrorCode

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def _debugger_plugin_source() -> str:
    return (PLUGIN_ROOT / "debugger" / "mcp_debugger_plugin.gd").read_text(encoding="utf-8")


def _game_helper_source() -> str:
    return (PLUGIN_ROOT / "runtime" / "game_helper.gd").read_text(encoding="utf-8")


def test_game_helper_timeout_is_a_python_error_code() -> None:
    # Belt to the parity test's suspenders: the code agents/telemetry will
    # match on must exist under the exact expected name.
    assert ErrorCode.GAME_HELPER_TIMEOUT == "GAME_HELPER_TIMEOUT"


def test_screenshot_timeout_live_branch_uses_game_helper_timeout() -> None:
    source = _debugger_plugin_source()
    marker = "func _on_timeout("
    assert marker in source
    body = source[source.index(marker) : source.index(marker) + 1400]
    # Not-live keeps the attributed explanation; the live residual gets the
    # honest top-level code instead of bare INTERNAL_ERROR.
    assert "_explain_not_live" in body
    assert "ErrorCodes.GAME_HELPER_TIMEOUT" in body, (
        "_on_timeout's live branch must reply GAME_HELPER_TIMEOUT, not INTERNAL_ERROR"
    )
    # The hint must name concrete recovery actions so the LLM doesn't guess.
    assert "focus the game window" in body
    assert "game_command" in body


def test_game_helper_screenshot_has_synchronous_stale_fallback() -> None:
    source = _game_helper_source()
    marker = "func _handle_take_screenshot("
    assert marker in source
    body = source[source.index(marker) : source.index(marker) + 2400]
    # The stalled-loop decision must run BEFORE any await: a frozen main loop
    # never fires process_frame, so an await-first structure can never reply.
    sync_gate = body.index("_should_capture_stale_sync")
    first_await = body.index("await tree.process_frame")
    assert sync_gate < first_await, (
        "the synchronous stale-capture gate must precede the first frame await, "
        "or a frozen main loop parks the coroutine and the request times out"
    )


def test_game_helper_reply_carries_staleness_fields() -> None:
    source = _game_helper_source()
    marker = "func _capture_and_reply("
    assert marker in source
    body = source[source.index(marker) : source.index(marker) + 1800]
    assert '"mcp:screenshot_response"' in body
    # Fields 7+8 of the payload: frames_drawn + stale. Older editors read the
    # first six and ignore the rest.
    assert "frames_drawn," in body
    assert "stale," in body


def test_debugger_plugin_surfaces_stale_frame_metadata() -> None:
    source = _debugger_plugin_source()
    marker = "func _on_screenshot_response("
    assert marker in source
    body = source[source.index(marker) : source.index(marker) + 1800]
    assert '"stale_frame"' in body
    assert '"frames_drawn"' in body
    # The stale note must explain the state and the recovery.
    assert "backgrounded" in body


def test_timeout_constants_unchanged() -> None:
    """#777 is a structural fix — the ladder (game 6s first-frame wait <
    editor 8s reply timer < server 35s budget) must not move as a side
    effect. Telemetry keys on the ~8s cluster to verify the fix lands."""
    helper = _game_helper_source()
    plugin = _debugger_plugin_source()
    editor_py = (
        Path(__file__).resolve().parents[2] / "src" / "godot_ai" / "handlers" / "editor.py"
    ).read_text(encoding="utf-8")
    assert "const FIRST_FRAME_WAIT_SEC := 6.0" in helper
    assert "const DEFAULT_TIMEOUT_SEC := 8.0" in plugin
    assert "GAME_SCREENSHOT_TIMEOUT_SEC = 35.0" in editor_py
