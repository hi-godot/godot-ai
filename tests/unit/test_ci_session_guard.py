"""Regression coverage for the shell CI session/project guard (#885)."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "script" / "_ci_session_guard.py"


def _load_helper() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ci_session_guard", HELPER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = _load_helper()


def _payload(*sessions: tuple[str, str]) -> dict:
    return {
        "count": len(sessions),
        "sessions": [
            {"session_id": session_id, "project_path": project_path}
            for session_id, project_path in sessions
        ],
    }


def test_selects_lone_matching_project_with_normalized_path(tmp_path: Path) -> None:
    expected = tmp_path / "repo" / "test_project"
    expected.mkdir(parents=True)
    reported = str(expected).replace("/", "\\") + "\\"

    selected = guard._select_session(
        _payload(("godot-ai@a1b2", reported)),
        expected_project=str(expected),
        explicit_pin="",
    )

    assert selected == "godot-ai@a1b2"


def test_rejects_lone_foreign_project(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    expected = tmp_path / "repo" / "test_project"
    foreign = tmp_path / "other" / "test_project"
    expected.mkdir(parents=True)
    foreign.mkdir(parents=True)

    with pytest.raises(SystemExit):
        guard._select_session(
            _payload(("other@ffff", str(foreign))),
            expected_project=str(expected),
            explicit_pin="",
        )

    error = capsys.readouterr().err
    assert "different project" in error
    assert "MCP_SERVER_URL" in error
    assert "GODOT_AI_SESSION_ID" in error


def test_explicit_pin_bypasses_project_check_and_selects_among_many(tmp_path: Path) -> None:
    selected = guard._select_session(
        _payload(
            ("one@1111", str(tmp_path / "one")),
            ("two@2222", str(tmp_path / "two")),
        ),
        expected_project=str(tmp_path / "expected"),
        explicit_pin="two@2222",
    )

    assert selected == "two@2222"


def test_rejects_ambiguous_sessions_without_pin(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit):
        guard._select_session(
            _payload(
                ("one@1111", str(tmp_path / "one")),
                ("two@2222", str(tmp_path / "two")),
            ),
            expected_project=str(tmp_path / "expected"),
            explicit_pin="",
        )

    error = capsys.readouterr().err
    assert "refusing to guess" in error
    assert "one@1111" in error
    assert "two@2222" in error


def test_rejects_zero_sessions_without_pin(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit):
        guard._select_session(
            _payload(),
            expected_project=str(tmp_path / "expected"),
            explicit_pin="",
        )

    assert "no Godot session is connected" in capsys.readouterr().err


def test_rejects_explicit_pin_that_is_not_connected(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit):
        guard._select_session(
            _payload(("one@1111", str(tmp_path / "one"))),
            expected_project=str(tmp_path / "expected"),
            explicit_pin="missing@9999",
        )

    assert "is not connected" in capsys.readouterr().err


def test_pin_args_adds_selected_session_without_mutating_input() -> None:
    original = {"op": "quit", "params": {}}

    pinned = guard._pin_args(dict(original), session_id="godot-ai@a1b2")

    assert pinned == {
        "op": "quit",
        "params": {},
        "session_id": "godot-ai@a1b2",
    }
    assert "session_id" not in original


def test_pin_args_rejects_conflicting_existing_target() -> None:
    with pytest.raises(ValueError, match="already target"):
        guard._pin_args(
            {"op": "quit", "session_id": "other@ffff"},
            session_id="godot-ai@a1b2",
        )


@pytest.mark.parametrize(
    ("script_name", "first_mutation"),
    [
        ("ci-godot-tests", "SCENE_ARGS="),
        ("ci-quit-test", "QUIT_RESULT="),
        ("ci-reload-test", "CREATE_RESULT="),
        ("ci-slow-suite-smoke", 'cp "$FIXTURE_SRC"'),
    ],
)
def test_every_shell_runner_selects_a_session_before_mutation(
    script_name: str, first_mutation: str
) -> None:
    source = (ROOT / "script" / script_name).read_text(encoding="utf-8")

    assert 'source "$SCRIPT_DIR/_ci_session_guard.sh"' in source
    assert source.index("ci_select_godot_session") < source.index(first_mutation)


@pytest.mark.parametrize(
    "script_name",
    ["ci-quit-test", "ci-reload-test", "ci-slow-suite-smoke"],
)
def test_shared_mcp_call_runners_pin_non_session_tools(script_name: str) -> None:
    source = (ROOT / "script" / script_name).read_text(encoding="utf-8")

    assert 'if [ "$tool" != "session_manage" ]' in source or (
        script_name == "ci-slow-suite-smoke" and 'if [ "$2" != "session_manage" ]' in source
    )
    assert "ci_pin_tool_args" in source


def test_main_runner_pins_scene_and_test_calls() -> None:
    source = (ROOT / "script" / "ci-godot-tests").read_text(encoding="utf-8")

    assert "PIN_SESSION=$(ci_select_godot_session" in source
    assert "args['session_id'] = pin" in source


def test_quit_runner_fails_closed_when_session_status_query_fails() -> None:
    source = (ROOT / "script" / "ci-quit-test").read_text(encoding="utf-8")

    assert "TARGET_PRESENT=1" in source
    assert "if ! SESSIONS=$(mcp_call session_manage" in source
    assert "A failed registry query is not proof" in source
    assert "|| echo '{\"sessions\":[]}'" not in source
