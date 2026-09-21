"""The capture smoke's editor-registration wait (script/ci-game-capture-smoke).

Locks the behaviour added after the 2026-09-08 macOS flake: the wait streams
the editor's log with elapsed stamps, reports how long registration took, and
a timeout names what the server said plus the editor-log tail instead of the
bare "never registered; last err: None".
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "ci-game-capture-smoke"


def _load_smoke() -> ModuleType:
    loader = importlib.machinery.SourceFileLoader("ci_game_capture_smoke", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class _FakeClock:
    """monotonic()/sleep() stand-in so the wait runs without real delays."""

    def __init__(self) -> None:
        self.now = 1000.0
        self.slept: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


@pytest.fixture
def smoke(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> tuple[ModuleType, _FakeClock, Path]:
    module = _load_smoke()
    clock = _FakeClock()
    monkeypatch.setattr(module.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(module.time, "sleep", clock.sleep)
    monkeypatch.setattr(module, "_godot_process_snapshot", lambda: ["12345 godot --editor"])
    editor_log = tmp_path / "godot-editor.log"
    monkeypatch.setattr(module, "EDITOR_LOG", str(editor_log))
    return module, clock, editor_log


def _replies(module: ModuleType, monkeypatch: pytest.MonkeyPatch, sequence: list) -> list[int]:
    """Feed session_manage replies in order; the last one repeats forever."""
    calls: list[int] = []

    def fake_tool_call(session_id, name, args, request_id, timeout=30.0, **kwargs):
        assert name == "session_manage" and args == {"op": "list"}
        calls.append(request_id)
        item = sequence[min(len(calls) - 1, len(sequence) - 1)]
        if isinstance(item, Exception):
            raise item
        return item

    monkeypatch.setattr(module, "_tool_call", fake_tool_call)
    return calls


def test_wait_returns_elapsed_and_streams_editor_log(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    editor_log.write_text("Godot Engine v4.7\nMetal 4.0 - Forward+\n", encoding="utf-8")
    calls = _replies(
        module,
        monkeypatch,
        [
            {"count": 0, "sessions": []},
            {"count": 0, "sessions": []},
            {"count": 1, "sessions": [{}], "active_session_id": "test-project@abc"},
        ],
    )
    history: list[str] = []

    elapsed = module._wait_for_godot_session("sid", timeout=60.0, history=history)

    assert len(calls) == 3
    assert elapsed == pytest.approx(2 * module.SESSION_POLL_DELAY_SEC)
    out = capsys.readouterr().out
    assert "Godot session connected after 4.0s (3 polls):" in out
    assert "test-project@abc" in out
    ## The editor's boot lines were streamed with an elapsed stamp.
    assert "[+0.0s] [editor-log] Godot Engine v4.7" in out
    assert "[editor-log] Metal 4.0 - Forward+" in out
    assert any("[editor-log] Godot Engine v4.7" in line for line in history)


def test_wait_streams_lines_as_they_land_and_only_once(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    ## The log does not exist on the first poll (the editor is started by a
    ## separate step), then grows across polls, including a partial line.
    state = {"n": 0}

    def fake_tool_call(session_id, name, args, request_id, timeout=30.0, **kwargs):
        state["n"] += 1
        if state["n"] == 2:
            editor_log.write_bytes(b"Godot Engine v4.7\nMCP startup trace | phase=set")
        if state["n"] == 3:
            with editor_log.open("ab") as fh:
                fh.write(b"tings_registered total_ms=10\nMCP | plugin loaded\n")
        if state["n"] == 4:
            return {"count": 1, "sessions": [{}]}
        return {"count": 0, "sessions": []}

    monkeypatch.setattr(module, "_tool_call", fake_tool_call)

    module._wait_for_godot_session("sid", timeout=60.0)

    out = capsys.readouterr().out
    assert out.count("[editor-log] Godot Engine v4.7") == 1
    ## The partial line was held back until its newline arrived, then
    ## printed whole.
    assert "[editor-log] MCP startup trace | phase=settings_registered total_ms=10" in out
    assert out.count("[editor-log] MCP | plugin loaded") == 1
    assert "phase=set\n" not in out


def test_wait_reports_progress_at_the_configured_cadence(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    monkeypatch.setattr(module, "SESSION_WAIT_PROGRESS_SEC", 6.0)
    ## Polls land at 0, 2, 4, ... seconds; registration on the ninth poll
    ## (16s) leaves two progress ticks, at +6s and +12s.
    sequence = [{"count": 0, "sessions": []}] * 8 + [{"count": 1, "sessions": [{}]}]
    _replies(module, monkeypatch, sequence)

    module._wait_for_godot_session("sid", timeout=60.0)

    progress = [
        line for line in capsys.readouterr().out.splitlines() if "no editor session yet" in line
    ]
    assert [line.split("]")[0] for line in progress] == [
        "[session-wait +6.0s",
        "[session-wait +12.0s",
    ]
    assert "latest reply contained no sessions (count=0)" in progress[0]


def test_timeout_names_the_server_reply_and_tails_the_editor_log(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    editor_log.write_text(
        "Godot Engine v4.7.stable.official\nMetal 4.0 - Forward+ - Apple Paravirtual device\n",
        encoding="utf-8",
    )
    _replies(module, monkeypatch, [{"count": 0, "sessions": []}])
    history: list[str] = []

    with pytest.raises(RuntimeError) as excinfo:
        module._wait_for_godot_session("sid", timeout=10.0, history=history)

    message = str(excinfo.value)
    assert message.startswith(
        "Godot session never registered within 10s (5 polls);"
    )
    assert "latest reply contained no sessions" in message
    ## No new request starts at the deadline.
    assert clock.slept == [2.0] * 5
    out = capsys.readouterr().out
    assert "giving up after 5 polls; last 40 editor-log lines:" in out
    assert "    Metal 4.0 - Forward+ - Apple Paravirtual device" in out
    assert "godot processes:" in out
    assert "    12345 godot --editor" in out
    ## The same timeline reached the diag history for the uploaded artifact.
    assert any("Apple Paravirtual device" in line for line in history)
    assert any("12345 godot --editor" in line for line in history)


def test_timeout_reports_transport_errors_and_unexpected_replies(
    smoke, monkeypatch: pytest.MonkeyPatch
) -> None:
    module, clock, editor_log = smoke
    _replies(
        module,
        monkeypatch,
        [
            {"error": {"code": "UNAUTHORIZED", "message": "bad bearer"}},
            module.urllib.error.URLError("connection refused"),
        ],
    )

    with pytest.raises(RuntimeError) as excinfo:
        module._wait_for_godot_session("sid", timeout=4.0)

    message = str(excinfo.value)
    ## A reply without `count` is surfaced verbatim rather than read as
    ## "no sessions", and a transport error replaces the boot verdict.
    assert "UNAUTHORIZED" not in message
    assert "last transport error: URLError" in message
    assert "every poll got a reply" not in message


def test_timeout_without_an_editor_log_still_explains_itself(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    _replies(module, monkeypatch, [{"count": 0, "sessions": []}])

    with pytest.raises(RuntimeError, match="never registered within 2s"):
        module._wait_for_godot_session("sid", timeout=2.0)

    out = capsys.readouterr().out
    assert "unreadable" in out


def test_editor_log_tail_caps_lines_per_flush(smoke) -> None:
    module, clock, editor_log = smoke
    editor_log.write_text("".join(f"line {i}\n" for i in range(50)), encoding="utf-8")
    seen: list[str] = []
    tail = module._EditorLogTail(str(editor_log), seen.append)

    tail.flush()

    assert tail.lines_seen == 50
    assert seen[0] == "[editor-log] line 0"
    assert seen[-2] == "[editor-log] line 39"
    assert seen[-1] == "[editor-log] (+10 more lines; output truncated)"
    assert tail.tail(3) == ["line 47", "line 48", "line 49"]


def test_session_wait_budget_covers_the_measured_macos_boot() -> None:
    ## 2026-09-08: launch→registered on the macOS runner peaked at 90s over
    ## 41 runs and two runs exceeded the old 120s budget. Keep the ceiling
    ## comfortably above the observed maximum and documented where it lives.
    module = _load_smoke()
    assert module.SESSION_WAIT_SEC >= 240.0
    assert (module.SESSION_WAIT_SEC + module.GAME_READY_WAIT_SEC + module.CAPTURE_BUDGET_SEC
            + 111 + 2 * module.DIAGNOSTICS_BUDGET_SEC + 10 + 140) <= 16 * 60
    workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    smoke_step = workflow[workflow.index("- name: Run capture smoke test") :]
    smoke_step = smoke_step[: smoke_step.index("run: python script/ci-game-capture-smoke")]
    assert "timeout-minutes: 16" in smoke_step


@pytest.mark.parametrize("reply", [{"count": 0, "sessions": []}, {"count": 1, "sessions": [{}]}])
def test_registration_caps_rpc_and_rejects_late_reply(smoke, monkeypatch, reply):
    module, clock, _ = smoke
    calls = []

    def slow_call(*args, timeout=30, **kwargs):
        calls.append((timeout, kwargs.get("deadline")))
        clock.now += timeout + 0.1
        return reply

    monkeypatch.setattr(module, "_tool_call", slow_call)
    with pytest.raises(RuntimeError, match="never registered"):
        module._wait_for_godot_session("sid", timeout=1)
    assert calls == [(1, 1001)]
    assert clock.now == pytest.approx(1001.1)


def test_registration_latest_empty_reply_replaces_transport_error(smoke, monkeypatch):
    module, _, _ = smoke
    _replies(module, monkeypatch, [OSError("earlier refusal"), {"count": 0, "sessions": []}])
    with pytest.raises(RuntimeError) as exc:
        module._wait_for_godot_session("sid", timeout=3)
    assert "latest reply contained no sessions" in str(exc.value)
    assert "last transport error" not in str(exc.value)
    assert "every poll" not in str(exc.value)


@pytest.mark.parametrize("reply", [
    {"error": {"code": "UNAUTHORIZED", "message": "denied"}},
    {"count": True, "sessions": [{}]},
    {"count": 1, "sessions": []},
    {"count": 0},
])
def test_registration_invalid_reply_is_not_empty_or_ready(smoke, monkeypatch, reply):
    module, _, _ = smoke
    _replies(module, monkeypatch, [reply])
    with pytest.raises(RuntimeError) as exc:
        module._wait_for_godot_session("sid", timeout=1)
    assert "unexpected reply" in str(exc.value) or "tool error" in str(exc.value)
    assert "no sessions" not in str(exc.value)


def test_ready_rejects_success_after_deadline(smoke, monkeypatch):
    module, clock, _ = smoke
    calls = []

    def slow_call(*args, timeout=30, **kwargs):
        calls.append(timeout)
        clock.now += timeout + 0.1
        return {"is_playing": True, "game_capture_ready": True}

    monkeypatch.setattr(module, "_tool_call", slow_call)
    with pytest.raises(RuntimeError, match="never registered"):
        module._wait_for_game_capture_ready("sid", timeout=1)
    assert calls == [1]


@pytest.mark.parametrize("newline", [b"", b"\n"])
def test_log_bytes_are_bounded_and_next_line_survives(smoke, newline):
    module, _, path = smoke
    path.write_bytes(b"x" * (1024 * 1024) + newline + b"\nnext normal line\n")
    seen = []
    tail = module._EditorLogTail(str(path), seen.append)
    while tail._offset < path.stat().st_size:
        before = len(seen)
        tail.flush()
        assert sum(len(x.encode("utf-8")) for x in seen[before:]) <= 20000
        assert len(tail._partial) <= 4096
    assert any("next normal line" in x for x in seen)
    assert any("truncated" in x for x in seen)
    assert sum(len(x.encode("utf-8")) for x in tail.tail()) <= 20000


def test_log_truncation_resets_offset_and_partial(smoke):
    module, _, path = smoke
    path.write_bytes(b"old incomplete line")
    seen = []
    tail = module._EditorLogTail(str(path), seen.append)
    tail.flush()
    path.write_bytes(b"new\n")
    tail.flush()
    assert any(x == "[editor-log] new" for x in seen)
    assert not any("old" in x for x in seen)


@pytest.mark.parametrize("late", [False, True])
def test_post_uses_remaining_socket_allowance_and_rejects_late_body(smoke, monkeypatch, late):
    module, clock, _ = smoke
    observed = []

    class Response:
        headers = {}

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            clock.now += 1.1 if late else 0.2
            return b'{"jsonrpc":"2.0","result":{}}'

    monkeypatch.setattr(module, "authorization_header", lambda url: "fixture")

    def open_request(request, timeout):
        observed.append(timeout)
        return Response()

    monkeypatch.setattr(module.urllib.request, "urlopen", open_request)
    if late:
        with pytest.raises(TimeoutError, match="deadline"):
            module._post("sid", {}, timeout=40, deadline=1001)
    else:
        assert module._post("sid", {}, timeout=40, deadline=1001)["result"] == {}
    assert observed == [1]
    clock.now = 1001
    with pytest.raises(TimeoutError, match="deadline"):
        module._post("sid", {}, deadline=1001)
    assert observed == [1], "an expired phase must not send an HTTP request"


def test_capture_metadata_and_image_share_one_allowance(smoke, monkeypatch):
    module, clock, _ = smoke
    calls = []

    def metadata(*args, timeout, deadline):
        calls.append(("metadata", timeout, deadline))
        clock.now += 0.75
        return {"source": "game"}

    def image(*args, timeout, deadline):
        calls.append(("image", timeout, deadline))
        return {"_raw": ""}

    monkeypatch.setattr(module, "_tool_call", metadata)
    monkeypatch.setattr(module, "_post", image)
    failures, _ = module._capture_attempt("sid", 12, deadline=1001)
    assert failures == ["no image block in response; raw: "]
    assert calls == [("metadata", 1, 1001), ("image", 0.25, 1001)]


def test_diagnostics_have_one_shared_budget(smoke, monkeypatch):
    module, clock, _ = smoke
    timeouts = []

    class Response:
        headers = {}
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False
        def read(self):
            clock.now += module.DIAGNOSTICS_BUDGET_SEC
            return b'{}'

    monkeypatch.setattr(module, "authorization_header", lambda url: "fixture")

    def open_request(request, timeout):
        timeouts.append(timeout)
        return Response()

    monkeypatch.setattr(module.urllib.request, "urlopen", open_request)
    module._dump_diagnostics("sid")
    assert timeouts == [module.DIAGNOSTICS_BUDGET_SEC]


@pytest.mark.parametrize("phase", ["initialize", "scene_open", "project_run", "capture"])
def test_main_preserves_failure_artifacts_and_never_replays_writes(smoke, monkeypatch, phase):
    module, clock, _ = smoke
    calls = []
    artifacts = []

    def initialize():
        if phase == "initialize":
            raise TimeoutError("initialization expired")
        return "sid"

    def tool(session, name, args, request_id, **kwargs):
        calls.append(name)
        if name == phase:
            raise TimeoutError(f"{name} expired")
        return {}

    def capture(*args, **kwargs):
        clock.now = kwargs["deadline"] + 0.1
        return [], b"late image"

    monkeypatch.setattr(module, "_initialize_session", initialize)
    monkeypatch.setattr(module, "_tool_call", tool)
    monkeypatch.setattr(module, "_wait_for_godot_session", lambda *a, **k: 0)
    monkeypatch.setattr(module, "_wait_for_game_capture_ready", lambda *a, **k: None)
    monkeypatch.setattr(module, "_dump_diagnostics", lambda *a: None)
    monkeypatch.setattr(module, "_capture_attempt", capture)
    monkeypatch.setattr(
        module, "_write_diag_artifacts", lambda history, png: artifacts.append(history[:])
    )
    if phase == "capture":
        assert module.main() == 1
    else:
        with pytest.raises(TimeoutError):
            module.main()
    assert len(artifacts) == 1 and artifacts[0]
    assert calls.count("scene_open") <= 1
    assert calls.count("project_run") <= 1
    assert calls.count("project_manage") == (phase in {"project_run", "capture"})


def test_invalid_utf8_log_output_counts_encoded_bytes(smoke):
    module, _, path = smoke
    path.write_bytes((b"\xff" * 4096 + b"\n") * 30)
    seen = []
    tail = module._EditorLogTail(str(path), seen.append)
    tail.flush()
    assert sum(len(line.encode("utf-8")) for line in seen) <= 20000
    assert sum(len(line.encode("utf-8")) for line in tail.tail()) <= 20000
    assert any("truncated" in line for line in seen)


@pytest.mark.parametrize("envelope", [
    {"error": {"code": -32001, "message": "UNAUTHORIZED"}},
    {"result": {"structuredContent": {"error": {"code": "UNAUTHORIZED"}}, "isError": True}},
    {"result": {"content": [{"type": "text", "text": '{"error":{"code":"UNAUTHORIZED"}}'}]}},
])
def test_registration_preserves_actual_error_envelopes(smoke, monkeypatch, envelope):
    module, _, _ = smoke
    monkeypatch.setattr(module, "_post", lambda *args, **kwargs: envelope)
    with pytest.raises(RuntimeError) as exc:
        module._wait_for_godot_session("sid", timeout=1)
    assert "tool error" in str(exc.value)
    assert "UNAUTHORIZED" in str(exc.value)
    assert "no sessions" not in str(exc.value)


@pytest.mark.parametrize("result", [
    {"isError": True, "content": [{"type": "text", "text": "UNAUTHORIZED: bad bearer"}]},
    {"isError": True, "structuredContent": {"count": 1, "sessions": [{}]}},
    {"isError": True, "structuredContent": {"error": {}}},
])
def test_tool_error_flag_never_becomes_ready_or_malformed(smoke, monkeypatch, result):
    module, _, _ = smoke
    monkeypatch.setattr(module, "_post", lambda *args, **kwargs: {"result": result})
    response = module._tool_call("sid", "session_manage", {"op": "list"}, 2)
    outcome = module._session_outcome(response)
    assert outcome["kind"] == "tool_error"
    structured = result.get("structuredContent")
    expected = structured["error"] if isinstance(structured, dict) and "error" in structured else (
        structured or result
    )
    if result.get("content"):
        expected = {"_text": "UNAUTHORIZED: bad bearer"}
    assert response["error"] == expected
    with pytest.raises(RuntimeError, match="tool error"):
        module._wait_for_godot_session("sid", timeout=1)


@pytest.mark.parametrize("structured", [True, False])
def test_existing_structured_error_code_stays_at_the_same_path(smoke, monkeypatch, structured):
    module, _, _ = smoke
    payload = {"error": {
        "code": "EVAL_GAME_NOT_READY", "message": "liveness pending",
        "data": {"retryable": True, "sub_code": "liveness_pending"},
    }}
    import json
    result = {"isError": True}
    if structured:
        result["structuredContent"] = payload
    else:
        result["content"] = [{"type": "text", "text": json.dumps(payload)}]
    monkeypatch.setattr(module, "_post", lambda *a, **k: {"result": result})
    assert module._tool_call("sid", "editor_manage", {}, 12) == payload
