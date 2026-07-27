"""Tests for the game_input_sequence handler and its server-side validation."""

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import game as game_handlers
from godot_ai.handlers.game import (
    INPUT_SEQUENCE_TIMEOUT_SEC,
    MAX_SEQUENCE_FRAMES,
    MAX_SEQUENCE_STEPS,
    _validate_input_sequence,
)
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import SessionRegistry


class _StubClient:
    """Records send() calls and returns a canned input_sequence response."""

    def __init__(self, *, result: dict | None = None):
        self.calls: list[dict] = []
        self._result = result or {"data": {"completed": True, "steps_applied": 2, "source": "game"}}

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
        hint_policy=None,
    ) -> dict:
        self.calls.append({"command": command, "params": params, "timeout": timeout})
        return self._result


def _runtime(client: _StubClient) -> DirectRuntime:
    return DirectRuntime(registry=SessionRegistry(), client=client)


# ----- _validate_input_sequence: accepts -----


def test_validate_normalizes_defaults():
    steps = _validate_input_sequence([{"at_frame": 0, "action": "jump"}], 0)
    assert steps == [{"at_frame": 0, "action": "jump", "pressed": True, "strength": 1.0}]


def test_validate_preserves_order_and_fields():
    raw = [
        {"at_frame": 0, "action": "jump", "pressed": True},
        {"at_frame": 6, "action": "jump", "pressed": False},
        {"at_frame": 6, "action": "move_right", "pressed": True, "strength": 0.5},
    ]
    steps = _validate_input_sequence(raw, 5)
    assert [s["at_frame"] for s in steps] == [0, 6, 6]
    assert steps[2]["strength"] == 0.5


def test_validate_allows_equal_frames():
    # non-decreasing is fine; two steps on the same frame is a valid combo
    _validate_input_sequence([{"at_frame": 3, "action": "a"}, {"at_frame": 3, "action": "b"}], 0)


def test_validate_span_at_cap_is_ok():
    _validate_input_sequence([{"at_frame": MAX_SEQUENCE_FRAMES, "action": "a"}], 0)


def test_validate_clamps_strength():
    steps = _validate_input_sequence(
        [
            {"at_frame": 0, "action": "a", "strength": 5.0},
            {"at_frame": 0, "action": "b", "strength": -1.0},
        ],
        0,
    )
    assert steps[0]["strength"] == 1.0
    assert steps[1]["strength"] == 0.0


# ----- _validate_input_sequence: rejects -----


@pytest.mark.parametrize("bad", [[], None, "nope", {}])
def test_validate_rejects_non_list_or_empty(bad):
    with pytest.raises(GodotCommandError) as exc:
        _validate_input_sequence(bad, 0)
    assert exc.value.code == ErrorCode.INVALID_PARAMS


def test_validate_rejects_over_step_cap():
    steps = [{"at_frame": 0, "action": "a"}] * (MAX_SEQUENCE_STEPS + 1)
    with pytest.raises(GodotCommandError, match="step cap"):
        _validate_input_sequence(steps, 0)


def test_validate_rejects_negative_at_frame():
    with pytest.raises(GodotCommandError, match="at_frame"):
        _validate_input_sequence([{"at_frame": -1, "action": "a"}], 0)


def test_validate_rejects_out_of_order():
    raw = [{"at_frame": 10, "action": "a"}, {"at_frame": 5, "action": "b"}]
    with pytest.raises(GodotCommandError, match="ordered by at_frame"):
        _validate_input_sequence(raw, 0)


def test_validate_rejects_missing_action():
    with pytest.raises(GodotCommandError, match="action"):
        _validate_input_sequence([{"at_frame": 0, "action": ""}], 0)


def test_validate_rejects_negative_settle():
    with pytest.raises(GodotCommandError, match="settle_frames"):
        _validate_input_sequence([{"at_frame": 0, "action": "a"}], -1)


def test_validate_rejects_over_frame_cap():
    raw = [{"at_frame": MAX_SEQUENCE_FRAMES, "action": "a"}]
    with pytest.raises(GodotCommandError, match="frame cap"):
        _validate_input_sequence(raw, 1)  # span = cap + 1


def test_validate_rejects_bool_at_frame():
    # bool is an int subclass in Python — must not sneak through as at_frame
    with pytest.raises(GodotCommandError, match="at_frame"):
        _validate_input_sequence([{"at_frame": True, "action": "a"}], 0)


def test_validate_rejects_bool_settle_frames():
    with pytest.raises(GodotCommandError, match="settle_frames"):
        _validate_input_sequence([{"at_frame": 0, "action": "a"}], True)


def test_validate_rejects_non_bool_pressed():
    # "false" must not silently coerce to True
    with pytest.raises(GodotCommandError, match="pressed"):
        _validate_input_sequence([{"at_frame": 0, "action": "a", "pressed": "false"}], 0)


def test_validate_rejects_non_numeric_strength():
    # a bad strength must be a clean INVALID_PARAMS, not an internal error
    with pytest.raises(GodotCommandError, match="strength"):
        _validate_input_sequence([{"at_frame": 0, "action": "a", "strength": "hard"}], 0)


def test_validate_rejects_bool_strength():
    with pytest.raises(GodotCommandError, match="strength"):
        _validate_input_sequence([{"at_frame": 0, "action": "a", "strength": True}], 0)


# ----- game_input_sequence dispatch -----


@pytest.mark.asyncio
async def test_dispatch_forwards_normalized_steps():
    client = _StubClient()
    result = await game_handlers.game_input_sequence(
        _runtime(client),
        steps=[
            {"at_frame": 0, "action": "jump"},
            {"at_frame": 6, "action": "jump", "pressed": False},
        ],
        settle_frames=5,
    )
    call = client.calls[-1]
    assert call["command"] == "game_command"
    assert call["params"]["op"] == "input_sequence"
    assert call["params"]["params"]["settle_frames"] == 5
    forwarded = call["params"]["params"]["steps"]
    assert forwarded[0] == {"at_frame": 0, "action": "jump", "pressed": True, "strength": 1.0}
    assert forwarded[1]["pressed"] is False
    assert result["data"]["completed"] is True


@pytest.mark.asyncio
async def test_dispatch_uses_wide_timeout():
    client = _StubClient()
    await game_handlers.game_input_sequence(
        _runtime(client), steps=[{"at_frame": 0, "action": "jump"}]
    )
    assert client.calls[-1]["timeout"] == INPUT_SEQUENCE_TIMEOUT_SEC


@pytest.mark.asyncio
async def test_dispatch_rejects_before_sending():
    client = _StubClient()
    with pytest.raises(GodotCommandError):
        await game_handlers.game_input_sequence(
            _runtime(client), steps=[{"at_frame": -1, "action": "a"}]
        )
    assert client.calls == []  # validation fails fast, nothing hits the wire
