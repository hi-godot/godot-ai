"""Tests for Bézier keyframe forwarding to the editor."""

from unittest.mock import create_autospec

from godot_ai.handlers.animation import animation_add_bezier_track
from godot_ai.runtime.direct import DirectRuntime


async def test_animation_add_bezier_track_handler():
    runtime = create_autospec(DirectRuntime, instance=True)
    runtime.get_active_session.return_value = None
    params = {
        "player_path": "/Main/AP",
        "animation_name": "slide",
        "track_path": "Icon:position:x",
        "keyframes": [
            {"time": 0.0, "value": 0, "out_handle": [0.25, 10]},
            {"time": 1.0, "value": 120, "in_handle": [-0.25, -10]},
        ],
    }
    receipt = {"track_type": "bezier", "keyframe_count": 2, "undoable": True}
    runtime.send_command.return_value = receipt

    assert await animation_add_bezier_track(runtime, **params) == receipt
    runtime.send_command.assert_awaited_once_with("animation_add_bezier_track", params)
