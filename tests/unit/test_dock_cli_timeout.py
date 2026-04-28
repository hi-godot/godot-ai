"""Source-structure regression tests for the wall-clock-bounded CLI fix.

Issues #238 / #239: a hung `claude mcp list` was wedging the dock's
status refresh worker for 6+ minutes; the Configure / Remove buttons hit
the same root cause on the editor main thread. The fix is layered:

1. `McpCliExec.run` wraps every shell-out in an `OS.execute_with_pipe` +
   poll/`OS.kill` loop with a hard wall-clock budget.
2. `McpCliStrategy` uses the helper from configure / remove / status —
   no direct `OS.execute(..., true)` call survives.
3. The dock dispatches Configure / Remove to a per-row worker thread
   instead of running on main, with the existing in-flight UI pattern
   already used by status refresh.

These tests lock the structure in so a future "simplify" pass can't
silently regress either issue.
"""

from __future__ import annotations

from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def test_cli_strategy_routes_every_shell_out_through_mcpcliexec() -> None:
    """No bare OS.execute survives in _cli_strategy.gd."""

    cli_source = (PLUGIN_ROOT / "clients" / "_cli_strategy.gd").read_text()

    # The whole point of the refactor: every CLI invocation must go
    # through the bounded helper. A bare OS.execute slipping back in
    # would re-introduce the hang.
    assert "OS.execute(" not in cli_source, (
        "OS.execute(...) must not appear in _cli_strategy.gd — every "
        "shell-out should go through McpCliExec.run for the wall-clock "
        "timeout. See issues #238 / #239."
    )
    # The replacement should be present in all three call sites
    # (configure, remove, status check) at minimum.
    assert cli_source.count("McpCliExec.run(") >= 3, (
        "Configure, Remove, and check_status_details must each call "
        "McpCliExec.run — fewer call sites means at least one CLI path "
        "is still synchronous."
    )


def test_cli_exec_helper_uses_pipe_spawn_and_poll_kill() -> None:
    """The helper must spawn detached and kill on timeout — not a blocking OS.execute."""

    helper_source = (PLUGIN_ROOT / "clients" / "_cli_exec.gd").read_text()

    # Pipe-based spawn returns a PID we can poll on. A blocking
    # OS.execute(..., true) here would just relocate the original hang.
    assert "OS.execute_with_pipe(" in helper_source
    assert "OS.is_process_running(" in helper_source
    assert "OS.kill(" in helper_source
    # Sanity-check the return shape so callers can rely on the four keys.
    for key in ("exit_code", "stdout", "timed_out", "spawn_failed"):
        assert f'"{key}"' in helper_source, (
            f"Helper must populate the '{key}' key — callers in "
            "_cli_strategy.gd dispatch on it."
        )


def test_cli_strategy_surfaces_timeout_in_configure_and_remove_messages() -> None:
    """A timeout must produce a user-actionable error, not a cryptic exit code."""

    cli_source = (PLUGIN_ROOT / "clients" / "_cli_strategy.gd").read_text()

    # The dock surfaces these strings in its row-error label and "Run
    # this manually" panel. Drift here means the user sees "exit code
    # -1" instead of "timed out — retry by hand."
    assert "Configure" in cli_source and "timed out" in cli_source
    assert "Remove" in cli_source
    # The probe path uses a different label ("probe timed out") because
    # the worker plumbs it into the row's error_msg slot, not into a
    # configure result. Guarding this prevents an over-eager unifier
    # from collapsing the two phrasings and breaking the row UI.
    assert "probe timed out" in cli_source


def test_dock_dispatches_configure_and_remove_to_worker_thread() -> None:
    """Issue #239: the Configure / Remove buttons must not block main."""

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    # The dispatch funnel must exist and route the click into a worker.
    assert "func _dispatch_client_action(" in dock_source
    assert "Thread.new()" in dock_source
    # The deferred apply lives on main; the worker only does the
    # blocking call and a call_deferred handoff.
    assert "call_deferred(\"_apply_client_action_result\"" in dock_source
    assert "func _run_client_action_worker(" in dock_source
    # The two button handlers should NOT call McpClientConfigurator
    # directly — that would re-introduce the main-thread block. They
    # forward to the dispatcher.
    on_configure = dock_source.split(
        "func _on_configure_client(client_id: String) -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]
    on_remove = dock_source.split(
        "func _on_remove_client(client_id: String) -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "_dispatch_client_action(" in on_configure
    assert "_dispatch_client_action(" in on_remove
    assert "McpClientConfigurator.configure(" not in on_configure, (
        "Configure handler must dispatch to a worker, not call the "
        "configurator inline (issue #239)."
    )
    assert "McpClientConfigurator.remove(" not in on_remove, (
        "Remove handler must dispatch to a worker, not call the "
        "configurator inline (issue #239)."
    )


def test_dock_drains_action_workers_during_install_update_and_exit_tree() -> None:
    """Worker drain must cover both shutdown paths — same reason as the refresh worker."""

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    # Both `_exit_tree` and `_install_update` must drain or we hit
    # `~Thread … destroyed without its completion having been realized`
    # → VM corruption, same as #232.
    exit_block = dock_source.split("func _exit_tree() -> void:", 1)[1].split(
        "\n\nfunc ", 1
    )[0]
    install_block = dock_source.split("func _install_update() -> void:", 1)[1].split(
        "\n\nfunc ", 1
    )[0]
    assert "_drain_client_action_workers()" in exit_block
    assert "_drain_client_action_workers()" in install_block


def test_dock_action_dispatch_gates_on_self_update_in_progress() -> None:
    """The same gate the refresh worker honors must protect Configure / Remove."""

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    block = dock_source.split("func _dispatch_client_action(", 1)[1].split(
        "\n\nfunc ", 1
    )[0]
    assert "_self_update_in_progress" in block, (
        "Configure / Remove dispatch must short-circuit during the "
        "install-update window — a worker mid-call into a half-overwritten "
        "_cli_strategy.gd SIGABRTs (same root cause as the refresh-worker "
        "gate in #235)."
    )


def test_status_refresh_apply_skips_rows_with_in_flight_action() -> None:
    """A concurrent refresh result must not stomp the 'Configuring…' badge."""

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    apply_block = dock_source.split(
        "func _apply_client_status_refresh_results(", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "_client_action_threads.has(" in apply_block, (
        "Refresh-result apply must skip rows whose action worker is "
        "still running — otherwise focus-in lands a stale snapshot on "
        "top of the in-flight badge."
    )
