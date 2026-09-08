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

    def fake_tool_call(session_id, name, args, request_id, timeout=30.0):
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
    assert "Godot session connected after 4.0s (3 polls): test-project@abc" in out
    ## The editor's boot lines were streamed with an elapsed stamp.
    assert "[session-wait +0.0s] [editor-log] Godot Engine v4.7" in out
    assert "[editor-log] Metal 4.0 - Forward+" in out
    assert any("[editor-log] Godot Engine v4.7" in line for line in history)


def test_wait_streams_lines_as_they_land_and_only_once(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    ## The log does not exist on the first poll (the editor is started by a
    ## separate step), then grows across polls, including a partial line.
    state = {"n": 0}

    def fake_tool_call(session_id, name, args, request_id, timeout=30.0):
        state["n"] += 1
        if state["n"] == 2:
            editor_log.write_bytes(b"Godot Engine v4.7\nMCP startup trace | phase=set")
        if state["n"] == 3:
            with editor_log.open("ab") as fh:
                fh.write(b"tings_registered total_ms=10\nMCP | plugin loaded\n")
        if state["n"] == 4:
            return {"count": 1, "active_session_id": "s"}
        return {"count": 0}

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
    sequence = [{"count": 0}] * 8 + [{"count": 1, "active_session_id": "s"}]
    _replies(module, monkeypatch, sequence)

    module._wait_for_godot_session("sid", timeout=60.0)

    progress = [
        line for line in capsys.readouterr().out.splitlines() if "no editor session yet" in line
    ]
    assert [line.split("]")[0] for line in progress] == [
        "[session-wait +6.0s",
        "[session-wait +12.0s",
    ]
    assert "server reply: count=0; transport error: None" in progress[0]


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
        "Godot session never registered within 10s (6 polls; server reply: count=0)"
    )
    assert "every poll got a reply with no sessions" in message
    assert "editor never connected" in message
    ## Polls stop at the deadline: 0, 2, 4, 6, 8, 10 seconds.
    assert clock.slept == [2.0] * 5
    out = capsys.readouterr().out
    assert "giving up after 6 polls; last 40 editor-log lines:" in out
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
    assert 'unexpected reply {"error": {"code": "UNAUTHORIZED"' in message
    assert "last transport error: URLError" in message
    assert "every poll got a reply" not in message


def test_timeout_without_an_editor_log_still_explains_itself(
    smoke, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module, clock, editor_log = smoke
    _replies(module, monkeypatch, [{"count": 0}])

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
    assert seen[-1] == "[editor-log] (+10 more lines)"
    assert tail.tail(3) == ["line 47", "line 48", "line 49"]


def test_session_wait_budget_covers_the_measured_macos_boot() -> None:
    ## 2026-09-08: launch→registered on the macOS runner peaked at 90s over
    ## 41 runs and two runs exceeded the old 120s budget. Keep the ceiling
    ## comfortably above the observed maximum and documented where it lives.
    module = _load_smoke()
    assert module.SESSION_WAIT_SEC >= 240.0
    assert module.SESSION_WAIT_SEC + 180.0 + 120.0 <= 12 * 60
    workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    smoke_step = workflow[workflow.index("- name: Run capture smoke test") :]
    smoke_step = smoke_step[: smoke_step.index("run: python script/ci-game-capture-smoke")]
    assert "timeout-minutes: 12" in smoke_step
