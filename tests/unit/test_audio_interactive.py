"""Focused tests for optional arguments on adaptive music handlers."""

from unittest.mock import AsyncMock, Mock

from godot_ai.handlers.audio import audio_interactive_create
from godot_ai.runtime.direct import DirectRuntime


async def test_audio_interactive_create_defaults_allow_no_explicit_transitions():
    runtime = Mock(spec=DirectRuntime, get_active_session=Mock(return_value=None))
    runtime.send_command = AsyncMock(return_value={"initial_clip": "exploration"})
    path = "res://adaptive.tres"
    clips = [{"name": "exploration", "stream_path": "res://exploration.ogg"}]

    assert await audio_interactive_create(runtime, path, clips) == {"initial_clip": "exploration"}
    runtime.send_command.assert_awaited_once_with(
        "audio_interactive_create", {"path": path, "clips": clips, "transitions": []}
    )
