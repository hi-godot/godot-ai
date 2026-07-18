"""Tests for the game_eval handler."""

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import editor as editor_handlers
from godot_ai.protocol.errors import ErrorCode
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
        hint_policy=None,
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


# --- #490: fast compile / runtime error codes ---


def test_eval_error_codes_exist():
    """The codes the plugin emits for fast game_eval failures."""
    assert ErrorCode.EVAL_COMPILE_ERROR == "EVAL_COMPILE_ERROR"
    assert ErrorCode.EVAL_RUNTIME_ERROR == "EVAL_RUNTIME_ERROR"
    # #518: the play-session-up-but-capture-not-ready race, carved out of
    # INTERNAL_ERROR so it stops being counted as a genuine eval hang.
    assert ErrorCode.EVAL_GAME_NOT_READY == "EVAL_GAME_NOT_READY"
    # #518: the eval code itself never finished (hung await / infinite loop),
    # aborted by the game's 8s deadline or the editor's 10s backstop.
    assert ErrorCode.EVAL_HUNG == "EVAL_HUNG"
    # #518: the eval finished but its serialized result exceeds what the
    # debugger channel can deliver; failed fast instead of a phantom hang.
    assert ErrorCode.EVAL_RESULT_TOO_LARGE == "EVAL_RESULT_TOO_LARGE"


class _RaisingGameEvalClient:
    """Simulates the real client raising on an error response from the plugin."""

    def __init__(self, code: str, message: str):
        self._code = code
        self._message = message

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
        hint_policy=None,
    ) -> dict:
        raise GodotCommandError(code=self._code, message=self._message)


@pytest.mark.asyncio
async def test_game_eval_propagates_compile_error_code():
    client = _RaisingGameEvalClient(ErrorCode.EVAL_COMPILE_ERROR, "Game eval failed to compile")
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    with pytest.raises(GodotCommandError) as exc:
        await editor_handlers.game_eval(runtime, code="return 1 +")
    assert exc.value.code == ErrorCode.EVAL_COMPILE_ERROR


@pytest.mark.asyncio
async def test_game_eval_propagates_hung_error_code():
    client = _RaisingGameEvalClient(
        ErrorCode.EVAL_HUNG,
        "Eval exceeded 8s and was aborted — the code likely awaits something that never completes",
    )
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    with pytest.raises(GodotCommandError) as exc:
        await editor_handlers.game_eval(runtime, code="await get_tree().create_timer(999).timeout")
    assert exc.value.code == ErrorCode.EVAL_HUNG


@pytest.mark.asyncio
async def test_game_eval_propagates_result_too_large_code():
    client = _RaisingGameEvalClient(
        ErrorCode.EVAL_RESULT_TOO_LARGE,
        "Eval result too large to return (10000213 bytes serialized, limit 6291456).",
    )
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    with pytest.raises(GodotCommandError) as exc:
        await editor_handlers.game_eval(runtime, code="return 'x'.repeat(10_000_000)")
    assert exc.value.code == ErrorCode.EVAL_RESULT_TOO_LARGE


@pytest.mark.asyncio
async def test_game_eval_propagates_runtime_error_code_and_text():
    client = _RaisingGameEvalClient(
        ErrorCode.EVAL_RUNTIME_ERROR,
        "Game eval raised a runtime error: Invalid call. Nonexistent function 'foo' in base 'Nil'.",
    )
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    with pytest.raises(GodotCommandError) as exc:
        await editor_handlers.game_eval(runtime, code="var x = null\nreturn x.foo()")
    assert exc.value.code == ErrorCode.EVAL_RUNTIME_ERROR
    assert "Invalid call" in exc.value.message
