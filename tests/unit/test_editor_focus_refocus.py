"""Regression tests for editor focus/refocus behavior."""

from __future__ import annotations

from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def test_focus_in_uses_async_cooled_down_refresh_instead_of_blocking_sweep() -> None:
    """Focus-in should keep automatic refresh without blocking the editor thread."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    assert "NOTIFICATION_APPLICATION_FOCUS_IN" in source
    assert "CLIENT_STATUS_REFRESH_COOLDOWN_MSEC := 15 * 1000" in source
    assert "_request_client_status_refresh(false)" in source
    assert "_refresh_all_client_statuses()" not in _focus_in_block(source)


def test_client_status_refresh_runs_on_background_thread_and_applies_deferred() -> None:
    """Blocking client probes should run off-thread; UI updates should apply deferred."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    assert "var _client_status_refresh_thread: Thread" in source
    assert "_client_status_refresh_thread.start" in source
    assert "McpClientConfigurator.check_status" in source
    assert 'call_deferred("_apply_client_status_refresh_results' in source


def test_client_status_refresh_coalesces_and_manual_refresh_bypasses_cooldown() -> None:
    """Duplicate automatic refreshes should coalesce; manual actions stay explicit."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    assert "if _client_status_refresh_in_flight:" in source
    assert "_client_status_refresh_pending = true" in source
    assert "if not force and _is_client_status_refresh_in_cooldown()" in source
    assert "_request_client_status_refresh(true)" in source


def test_clients_window_open_requests_nonblocking_refresh() -> None:
    """Opening Clients & Tools should not schedule a deferred synchronous sweep."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    block = source.split("func _on_open_clients_window() -> void:", 1)[1].split("\nfunc ", 1)[0]

    assert "_request_client_status_refresh(" in block
    assert "_refresh_all_client_statuses.call_deferred" not in block


def test_initial_paint_warms_worker_call_graph_before_threading() -> None:
    """Cold editor open pre-warms strategy bytecode on main, then defers CLI to worker (#235).

    Deterministic replacement for the prior 1.5s settle timer (#234), with the
    cold-start hitch minimized so #228's responsiveness win for focus-in /
    refocus paths is not regressed.

    The race: Godot's lazy GDScript hot-reload of overwritten plugin files
    swaps bytecode on first dereference. A worker spawned from a fresh
    `_build_ui` walks straight into `_json_strategy.*` / `_cli_strategy.*` /
    `client_configurator.*` mid-swap → SIGABRT (#233).

    The fix: dereference every script the worker will touch on the main
    thread *before* the worker starts. After this helper, bytecode is
    stable everywhere the worker reaches → no race possible.

      • `client_status_probe_snapshot` (called per client on main) warms
        `_cli_strategy.gd` / `_cli_finder.gd` for CLI clients via
        `resolve_cli_path`.
      • Sync `check_status_for_url_with_cli_path` on JSON/TOML clients
        (file-read + parse, ~5–20ms each) warms `_json_strategy.gd` /
        `_toml_strategy.gd` and the configurator dispatch.
      • CLI clients are bundled into a deferred batch and probed by the
        worker — slow `OS.execute` calls stay off-thread, preserving #228.

    The structural assertions below lock in this hybrid: a future "make
    startup snappier" refactor can't drop the warming step (re-introducing
    the race), and a future "be more conservative" refactor can't move the
    CLI probes back on-thread (regressing #228's responsiveness fix).
    """

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    build_block = source.split("func _build_ui() -> void:", 1)[1].split("\n\nfunc ", 1)[0]
    assert "_perform_initial_client_status_refresh()" in build_block, (
        "_build_ui must call the initial-refresh helper"
    )

    helper_block = source.split("func _perform_initial_client_status_refresh() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "client_status_probe_snapshot(" in helper_block, (
        "Helper must call client_status_probe_snapshot per client on main — "
        "this is what dereferences `_cli_strategy.gd` / `_cli_finder.gd` for "
        "CLI clients before the worker spawns. See #235."
    )
    assert "check_status_for_url_with_cli_path(" in helper_block, (
        "Helper must run a sync check_status_for_url_with_cli_path for "
        "JSON/TOML clients on main — that warms `_json_strategy.gd` / "
        "`_toml_strategy.gd` so the worker (if it spawns) can't race the "
        "lazy hot-reload bytecode swap. See #235."
    )
    assert "deferred_cli_probes" in helper_block, (
        "Helper must batch CLI probes for the deferred (worker) phase. "
        "Without this split, the cold-start path either (a) runs CLI probes "
        "on main and re-introduces #228's per-focus editor freezes, or "
        "(b) skips warming and races GDScript hot-reload (#233)."
    )
    assert "await " not in helper_block, (
        "Helper must be a single straight-line block — no timer awaits, no "
        "signal awaits. Suspending mid-helper would let GDScript reload the "
        "very scripts we're trying to dereference, voiding the warming."
    )
    assert "create_timer" not in helper_block, (
        "Helper must not gate on a wall-clock timer (the heuristic stopgap "
        "from #234 that #235 replaces)."
    )

    constants_block = source.split("class_name McpDock", 1)[1].split("\nvar ", 1)[0]
    assert "CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC" not in constants_block, (
        "The settle-timer constant from #234 must be removed — keeping it "
        "alongside the sync-warming helper would falsely imply a residual "
        "timer-based gate. See #235."
    )


def test_worker_uses_main_thread_probe_snapshot_for_cli_paths() -> None:
    """CLI path discovery caches should not be mutated from the refresh worker."""

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    configurator_source = (PLUGIN_ROOT / "client_configurator.gd").read_text()
    cli_source = (PLUGIN_ROOT / "clients" / "_cli_strategy.gd").read_text()
    worker_block = dock_source.split("func _run_client_status_refresh_worker", 1)[1].split(
        "\n\nfunc ", 1
    )[0]

    assert "client_status_probe_snapshot" in dock_source
    assert "check_status_for_url_with_cli_path" in worker_block
    assert "McpClientConfigurator.is_installed" not in worker_block
    assert "resolve_cli_path" in configurator_source
    assert "check_status_with_cli_path" in cli_source


def test_refresh_timeout_can_abandon_stale_worker_results() -> None:
    """A hung CLI probe should not permanently own the refresh slot."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    assert "CLIENT_STATUS_REFRESH_TIMEOUT_MSEC := 30 * 1000" in source
    assert "_client_status_refresh_generation" in source
    assert "_abandon_client_status_refresh_thread" in source
    assert "generation != _client_status_refresh_generation" in source


def test_configure_all_uses_cached_status_not_dot_color() -> None:
    """Configure-all must not make correctness decisions from stale UI colors."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    block = source.split("func _on_configure_all_clients() -> void:", 1)[1].split("\n\nfunc ", 1)[0]

    assert 'get("status", McpClient.Status.NOT_CONFIGURED)' in block
    assert "dot.color" not in block


def _focus_in_block(source: str) -> str:
    marker = "NOTIFICATION_APPLICATION_FOCUS_IN"
    start = source.index(marker)
    return source[start : source.index("\n\n", start)]
