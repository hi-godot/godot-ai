"""Source-pins for project_handler's deferred-finisher statics (#712).

The run/stop deferred finishers are coroutines that await across frames;
`static` is load-bearing there (the same "class instance is gone" failure
mode test_script_create_import_settle.py pins for script_create): a plugin
reload frees the RefCounted handler mid-await, and resuming an instance
coroutine on a freed object errors and drops the deferred response. These
checks prevent a silent revert to instance methods.
"""

from __future__ import annotations

from pathlib import Path

PROJECT_HANDLER = (
    Path(__file__).resolve().parents[2]
    / "plugin"
    / "addons"
    / "godot_ai"
    / "handlers"
    / "project_handler.gd"
)


def test_run_project_deferred_finisher_is_static() -> None:
    source = PROJECT_HANDLER.read_text(encoding="utf-8")
    assert "static func _finish_run_project_deferred(" in source, (
        "_finish_run_project_deferred must be `static` so the multi-frame "
        "liveness-poll coroutine doesn't capture self — a handler freed "
        "mid-await produces 'class instance is gone' and drops the response."
    )
    # Dependencies must be threaded explicitly, not pulled from self.
    assert (
        "_finish_run_project_deferred(request_id, base_data, _connection, _debugger_plugin)"
        in source
    ), (
        "run_project must pass _connection and _debugger_plugin explicitly "
        "to the static finisher — reading them from self would re-introduce "
        "the implicit self capture the static refactor removes."
    )


def test_stop_project_deferred_finisher_is_static() -> None:
    source = PROJECT_HANDLER.read_text(encoding="utf-8")
    assert "static func _finish_stop_project_deferred(" in source
    assert "_finish_stop_project_deferred(request_id, _connection)" in source, (
        "stop_project must pass _connection explicitly to the static finisher."
    )


def test_run_finisher_revalidates_dependencies_after_await() -> None:
    """The finisher's poll loop must re-check BOTH parameterized objects
    after each await — either can be freed while the coroutine sleeps."""
    source = PROJECT_HANDLER.read_text(encoding="utf-8")
    assert (
        "if not is_instance_valid(connection) or not is_instance_valid(debugger_plugin):" in source
    ), (
        "_finish_run_project_deferred must drop the response when either "
        "the connection or the debugger plugin died during an await."
    )
