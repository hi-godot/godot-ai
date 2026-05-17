"""Tests for the game_eval handler."""

import pytest

from godot_ai.handlers import editor as editor_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import SessionRegistry


class _StubGameEvalClient:
    """Records send() calls and returns canned game_eval responses."""

    def __init__(self, *, eval_result: dict | None = None):
        self.calls: list[dict] = []
        self._eval_result = eval_result or {"data": {"result": "42", "source": "game"}}

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict:
        self.calls.append(
            {
                "command": command,
                "params": params,
                "session_id": session_id,
                "timeout": timeout,
            }
        )
        if command == "game_eval":
            return self._eval_result
        return {"data": {}}


@pytest.mark.asyncio
async def test_game_eval_dispatches_command():
    client = _StubGameEvalClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.game_eval(runtime, code="return 42")
    assert client.calls[-1]["command"] == "game_eval"
    assert client.calls[-1]["params"] == {"code": "return 42"}
    assert result["data"]["result"] == "42"
    assert result["data"]["source"] == "game"


@pytest.mark.asyncio
async def test_game_eval_uses_custom_timeout():
    client = _StubGameEvalClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await editor_handlers.game_eval(runtime, code="return 1")
    assert client.calls[-1]["timeout"] == 15.0


@pytest.mark.asyncio
async def test_game_eval_passes_code_verbatim():
    client = _StubGameEvalClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await editor_handlers.game_eval(runtime, code="return get_tree().root.name")
    assert client.calls[-1]["params"]["code"] == "return get_tree().root.name"
