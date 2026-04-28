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


def test_install_update_drains_workers_and_blocks_spawning_before_extract() -> None:
    """Self-update must drain in-flight workers + block new ones before any file write.

    Race B regression: focus-in landing in the extract→reload window of
    `_install_update` previously spawned a fresh worker that walked into a
    half-overwritten plugin script and SIGABRT'd inside `GDScriptFunction::call`
    (observed in `Godot-2026-04-27-134236.ips`). Workers ALREADY running when
    install starts hit the same crash because the script being mid-`callp` gets
    its bytecode swapped under it.

    The fix has two parts that must both be present, both in the right order
    (before the write loop, after the symlink-safety early-return):

      1. `_self_update_in_progress = true`  — gates `_request_client_status_refresh`
         and `_perform_initial_client_status_refresh` so focus-in / cooldown /
         manual-button paths cannot spawn a new worker during the window.
      2. `_drain_client_status_refresh_workers()` — synchronously joins the
         currently-running worker (if any) BEFORE we touch any plugin file
         on disk.

    Both gates funnel through `_request_client_status_refresh`, so a single
    flag check there covers every spawn path. Asserting the textual order
    here locks in "drain happens before the first file write", which is what
    actually prevents the crash.
    """

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    install_block = source.split("func _install_update() -> void:", 1)[1].split(
        "\n\nfunc ", 1
    )[0]

    flag_set_idx = install_block.find("_self_update_in_progress = true")
    drain_idx = install_block.find("_drain_client_status_refresh_workers()")
    first_write_idx = install_block.find("f.store_buffer(content)")
    symlink_return_idx = install_block.find("addons_dir_is_symlink()")

    assert flag_set_idx > 0, (
        "_install_update must set `_self_update_in_progress = true` before "
        "extracting plugin files. Without this, focus-in during extract "
        "spawns a worker that crashes on the half-overwritten scripts."
    )
    assert drain_idx > 0, (
        "_install_update must call `_drain_client_status_refresh_workers()` "
        "before extracting plugin files. Already-running workers crash on "
        "the same overwrite if not joined first."
    )
    assert first_write_idx > 0, (
        "Test fixture broken: could not locate the extract-write site "
        "(`f.store_buffer(content)`) inside `_install_update`."
    )
    assert symlink_return_idx > 0, (
        "Test fixture broken: could not locate the symlink-safety check."
    )

    assert symlink_return_idx < flag_set_idx < first_write_idx, (
        "Order: symlink-safety check → set self_update_in_progress flag → "
        "extract write loop. Setting the flag before the symlink check "
        "would leave it stuck on the dev-checkout path; setting it after "
        "the write loop defeats the purpose."
    )
    assert drain_idx < first_write_idx, (
        "Drain must complete before any file write. Otherwise an in-flight "
        "worker can race the overwrite of the script it's mid-call into."
    )

    request_block = source.split(
        "func _request_client_status_refresh(force: bool = false) -> bool:", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "if _self_update_in_progress:" in request_block, (
        "_request_client_status_refresh must short-circuit when self-update "
        "is in progress. This is the funnel for focus-in, manual-button, "
        "and cooldown-timer spawn paths — gating here covers every caller."
    )

    init_block = source.split(
        "func _perform_initial_client_status_refresh() -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "if _self_update_in_progress:" in init_block, (
        "_perform_initial_client_status_refresh must also short-circuit on "
        "the self-update flag — defensive even though the new dock instance "
        "wouldn't normally see this flag set."
    )


def test_plugin_gd_avoids_typed_class_name_for_log_buffers() -> None:
    """plugin.gd's `_game_log_buffer` / `_editor_log_buffer` must be untyped (#242).

    Hot-reload during self-update parses the new release's plugin.gd before
    its dependent class_name'd files are guaranteed to be in the global class
    table. A typed declaration like `var _editor_log_buffer: EditorLogBuffer`
    fails to resolve when `EditorLogBuffer` is a class_name added in this
    release (and similarly for `GameLogBuffer` when its `extends` chain
    changes to reference a new class_name).

    Failed plugin.gd parse → degraded plugin state → set_plugin_enabled(false)
    fires _exit_tree on a half-broken dock → SIGABRT in the user's wild
    (issue #242, observed on v2.1.1 → v2.1.2).

    Lock the untyped pattern so a future contributor doesn't "fix" the
    apparent oversight by re-typing the field. The runtime parameter checks
    on EditorHandler / GameLogger callees still enforce the type fence —
    the typing just moves from plugin.gd's parse to the call site's runtime
    check, breaking the chicken-and-egg with class_name registration order.

    Same lesson as the existing untyped `_editor_logger` pattern.
    """

    plugin_source = (PLUGIN_ROOT / "plugin.gd").read_text()

    # Find the var declarations. Allow whitespace around `var`.
    forbidden_decls = (
        "var _game_log_buffer: GameLogBuffer",
        "var _editor_log_buffer: EditorLogBuffer",
    )
    for forbidden in forbidden_decls:
        assert forbidden not in plugin_source, (
            f"plugin.gd must not declare `{forbidden}` — typed-var declarations "
            "against class_names that may be added or refactored in future "
            "releases break self-update hot-reload (#242). Use untyped + "
            "`preload()` instead, like the existing `_editor_logger` field."
        )

    # And confirm the corresponding preload sites exist (preload-resolved
    # construction doesn't require the global class_name registry to be
    # ahead of plugin.gd's parse).
    assert 'preload("res://addons/godot_ai/utils/game_log_buffer.gd").new()' in plugin_source, (
        "plugin.gd must construct `_game_log_buffer` via "
        "`preload(...).new()` — the path-based load resolves at "
        "script-load time without needing GameLogBuffer's class_name "
        "registered first."
    )
    assert 'preload("res://addons/godot_ai/utils/editor_log_buffer.gd").new()' in plugin_source, (
        "plugin.gd must construct `_editor_log_buffer` via "
        "`preload(...).new()` — same reason as above for EditorLogBuffer."
    )


def test_install_update_falls_back_on_plugin_parse_failure() -> None:
    """`_on_filesystem_scanned_for_update` must verify plugin.gd parses before reload (#242).

    Even with the untyped-log-buffer fix, future releases could introduce
    other parse hazards (renamed `class_name`s, removed inheritance bases,
    refactored cross-class references). The install flow's belt-and-suspenders
    is to load the new plugin.gd via `ResourceLoader.load` after `fs.scan()`
    completes; `null` return = parse error = bail out of the in-place reload
    and fall back to the same "Restart editor to apply" message the
    pre-Godot-4.4 path uses.

    This avoids exercising `set_plugin_enabled(false/true)`'s _exit_tree
    cascade against a degraded plugin instance — the observed crash mode
    in #242.
    """

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    block = source.split(
        "func _on_filesystem_scanned_for_update() -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]

    assert 'ResourceLoader.load("res://addons/godot_ai/plugin.gd")' in block, (
        "_on_filesystem_scanned_for_update must verify the new plugin.gd "
        "parses (via ResourceLoader.load) before triggering "
        "_reload_after_update. Without this gate, a parse error in the new "
        "release leaves the v2.1.x plugin in a degraded state when "
        "set_plugin_enabled(false) fires its _exit_tree cascade. See #242."
    )
    assert "_self_update_in_progress = false" in block, (
        "On parse failure, the install flag must be cleared so the dock "
        "instance can resume normal refresh once the user restarts the "
        "editor manually (matching the pre-Godot-4.4 fallback path)."
    )
    assert "Restart the editor" in block, (
        "On parse failure, surface the same 'Restart the editor to apply' "
        "user-facing message that the pre-Godot-4.4 path already uses. "
        "That message is a known-good fallback path."
    )

    # Also confirm the bail-out happens BEFORE _reload_after_update is queued.
    parse_check_idx = block.find('ResourceLoader.load("res://addons/godot_ai/plugin.gd")')
    reload_call_idx = block.find("_reload_after_update.call_deferred()")
    assert parse_check_idx > 0 and reload_call_idx > 0, (
        "Test fixture broken: expected both ResourceLoader.load and "
        "_reload_after_update.call_deferred in the function body."
    )
    assert parse_check_idx < reload_call_idx, (
        "Parse check must run BEFORE the deferred reload call — a parse "
        "failure must short-circuit and not fall through into the in-place "
        "set_plugin_enabled cycle."
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
    # Worker uses the details variant so probe timeouts (issue #238) can
    # surface as "probe timed out" on the row instead of being silently
    # conflated with NOT_CONFIGURED.
    assert "check_status_details_for_url_with_cli_path" in worker_block
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
