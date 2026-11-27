"""Unit tests for runtime text input (`game_input_key` unicode + `game_type_text`)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import game as game_handlers
from godot_ai.handlers.game import MAX_TYPE_TEXT_LENGTH
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.tools._meta_tool import (
    MANAGE_TOOL_HANDLERS,
    MANAGE_TOOL_OPS,
    MANAGE_TOOL_RESOURCE_FORMS,
    dispatch_manage_op,
)
from tests.conftest import create_test_server as create_server

# Codepoint fixtures are data pairs for the (character, codepoint) mapping tables;
# values come from the Unicode standard, source https://www.unicode.org/glossary/
CP_LOWER_A = 97
CP_UPPER_A = 65
CP_CJK_YOU = 0x4F60
CP_EMOJI = 0x1F600
CP_BEYOND_MAX = 0x110000  # first codepoint beyond the scalar space
CP_SURROGATE = 0xD800  # surrogate block start
CP_NOT_INT = 65.5  # non-integer, rejected

REPO_ROOT = Path(__file__).resolve().parents[2]
GAME_HELPER_GD = REPO_ROOT / "plugin" / "addons" / "godot_ai" / "runtime" / "game_helper.gd"


class _StubClient:
    def __init__(self, result: dict | None = None):
        self.calls: list[dict] = []
        self._result = result or {"sent": True, "source": "game"}

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


# ----- game_input_key with unicode -----


@pytest.mark.asyncio
async def test_input_key_without_unicode_omits_unicode_field():
    client = _StubClient()
    await game_handlers.game_input_key(_runtime(client), key="A", pressed=True, echo=False)
    assert client.calls[-1]["command"] == "game_command"
    assert client.calls[-1]["params"] == {
        "op": "input_key",
        "params": {"key": "A", "pressed": True, "echo": False},
    }


@pytest.mark.asyncio
async def test_input_key_with_int_unicode_forwards_codepoint():
    client = _StubClient()
    await game_handlers.game_input_key(_runtime(client), key="A", pressed=True, unicode=CP_LOWER_A)
    assert client.calls[-1]["params"] == {
        "op": "input_key",
        "params": {"key": "A", "pressed": True, "echo": False, "unicode": CP_LOWER_A},
    }


@pytest.mark.asyncio
@pytest.mark.parametrize("char,expected_cp", [("a", CP_LOWER_A), ("A", CP_UPPER_A), ("你", CP_CJK_YOU), ("😀", CP_EMOJI)])
async def test_input_key_with_single_char_unicode_normalizes_to_codepoint(char: str, expected_cp: int):
    client = _StubClient()
    await game_handlers.game_input_key(_runtime(client), unicode=char)
    assert client.calls[-1]["params"] == {
        "op": "input_key",
        "params": {"key": "", "pressed": True, "echo": False, "unicode": expected_cp},
    }


@pytest.mark.asyncio
async def test_input_key_allows_zero_unicode_when_key_present():
    client = _StubClient()
    await game_handlers.game_input_key(_runtime(client), key="Enter", unicode=0)
    assert client.calls[-1]["params"]["params"]["unicode"] == 0


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "kwargs",
    [
        {"key": ""},
        {"key": "", "unicode": 0},
        {"key": "A", "unicode": ""},
        {"key": "A", "unicode": "ab"},
        {"key": "A", "unicode": -1},
        {"key": "A", "unicode": CP_BEYOND_MAX},
        {"key": "A", "unicode": CP_SURROGATE},
        {"key": "A", "unicode": True},
        {"key": "A", "unicode": CP_NOT_INT},
    ],
)
async def test_input_key_rejects_invalid_key_or_unicode(kwargs: dict):
    client = _StubClient()
    with pytest.raises(GodotCommandError) as exc:
        await game_handlers.game_input_key(_runtime(client), **kwargs)
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert client.calls == []


# ----- game_type_text -----


@pytest.mark.asyncio
async def test_type_text_forwards_text_and_default_submit():
    client = _StubClient()
    await game_handlers.game_type_text(_runtime(client), text="Hello, 世界!\n\t123")
    call = client.calls[-1]
    assert call["command"] == "game_command"
    assert call["timeout"] == game_handlers.GAME_COMMAND_TIMEOUT_SEC
    assert call["params"] == {
        "op": "type_text",
        "params": {"text": "Hello, 世界!\n\t123", "submit": False},
    }


@pytest.mark.asyncio
async def test_type_text_forwards_submit_true():
    client = _StubClient()
    await game_handlers.game_type_text(_runtime(client), text="/say hi", submit=True)
    assert client.calls[-1]["params"] == {
        "op": "type_text",
        "params": {"text": "/say hi", "submit": True},
    }


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "text,submit,match",
    [
        ("", False, "non-empty"),
        ("x" * (MAX_TYPE_TEXT_LENGTH + 1), False, "cap"),
        ("hello\x00world", False, "control character"),
        ("bell\x07", False, "control character"),
        ("del\x7f", False, "control character"),
        ("ok", "true", "boolean"),
    ],
)
async def test_type_text_rejects_invalid_params(text, submit, match: str):
    client = _StubClient()
    with pytest.raises(GodotCommandError, match=match) as exc:
        await game_handlers.game_type_text(_runtime(client), text=text, submit=submit)
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert client.calls == []


# ----- game_manage rollup wiring -----


@pytest.mark.asyncio
async def test_game_manage_registers_and_dispatches_type_text_and_unicode_input_key():
    create_server(ws_port=0)
    assert "type_text" in MANAGE_TOOL_OPS["game_manage"]
    assert MANAGE_TOOL_RESOURCE_FORMS["game_manage"]["type_text"] is None

    client = _StubClient()
    rt = _runtime(client)

    await dispatch_manage_op(
        ops=MANAGE_TOOL_HANDLERS["game_manage"],
        tool_name="game_manage",
        runtime=rt,
        op="type_text",
        params={"text": "測試聊天", "submit": True},
    )
    assert client.calls[-1]["params"] == {
        "op": "type_text",
        "params": {"text": "測試聊天", "submit": True},
    }

    await dispatch_manage_op(
        ops=MANAGE_TOOL_HANDLERS["game_manage"],
        tool_name="game_manage",
        runtime=rt,
        op="input_key",
        params={"unicode": "中"},
    )
    assert client.calls[-1]["params"] == {
        "op": "input_key",
        "params": {"key": "", "pressed": True, "echo": False, "unicode": ord("中")},
    }

    # Scalar type pin rejects bool for unicode and string for submit before handler runs
    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops=MANAGE_TOOL_HANDLERS["game_manage"],
            tool_name="game_manage",
            runtime=rt,
            op="input_key",
            params={"key": "A", "unicode": True},
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS


# ----- GDScript / Python contract parity -----


def test_game_helper_gd_defines_type_text_and_matching_cap():
    source = GAME_HELPER_GD.read_text(encoding="utf-8")
    assert '"type_text":' in source
    assert "func _game_type_text(" in source
    assert "func _build_type_text_events(" in source
    assert "func _build_key_event(" in source
    cap_match = re.search(r"const MAX_TYPE_TEXT_LENGTH\s*:=\s*(\d+)", source)
    assert cap_match is not None, "MAX_TYPE_TEXT_LENGTH missing from game_helper.gd"
    assert int(cap_match.group(1)) == MAX_TYPE_TEXT_LENGTH
