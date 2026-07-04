"""Source-pin: game_helper.gd must disable idle throttling in _ready().

game_helper.gd is the _mcp_game_helper autoload that runs inside the game
process. When the game window sits behind the focused editor, Godot's idle
throttle slows the frame loop, so MCP game_eval awaits that depend on the frame
loop advancing (create_timer, process_frame) stall or hit the reply deadline.
_ready() sets OS.low_processor_usage_mode = false and Engine.max_fps = 0 so the
game keeps ticking at full speed regardless of window focus. These checks pin
that behavior so a later edit does not reintroduce the throttle.
"""

from __future__ import annotations

import re
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
GAME_HELPER = PLUGIN_ROOT / "runtime" / "game_helper.gd"


def _ready_body(source: str) -> str:
    """Return the source of game_helper.gd from `func _ready()` up to the next
    top-level `func ` declaration, so assertions target _ready() only.
    """
    lines = source.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if line.startswith("func _ready(")),
        None,
    )
    assert start is not None, "game_helper.gd has no func _ready()"
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("func "):
            end = i
            break
    return "\n".join(lines[start:end])


def test_game_helper_disables_low_processor_usage_mode() -> None:
    """_ready() must turn off idle throttling so a backgrounded game keeps ticking."""
    body = _ready_body(GAME_HELPER.read_text(encoding="utf-8"))
    assert re.search(r"OS\.low_processor_usage_mode\s*=\s*false", body), (
        "game_helper.gd _ready() must set OS.low_processor_usage_mode = false so "
        "the game does not idle-throttle when its window is backgrounded behind "
        "the editor, which would stall MCP game_eval awaits."
    )


def test_game_helper_uncaps_max_fps() -> None:
    """_ready() must uncap the frame rate for the same reason."""
    body = _ready_body(GAME_HELPER.read_text(encoding="utf-8"))
    assert re.search(r"Engine\.max_fps\s*=\s*0", body), (
        "game_helper.gd _ready() must set Engine.max_fps = 0 so the game runs at "
        "full speed when backgrounded, keeping MCP game_eval awaits responsive."
    )
