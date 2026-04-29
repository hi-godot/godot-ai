"""Regression tests for editor focus/refocus behavior."""

from __future__ import annotations

import re
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


def test_client_status_refresh_defers_while_editor_filesystem_is_busy() -> None:
    """Refresh workers must not race Godot's script reload/documentation pass."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    assert "var _client_status_refresh_deferred_until_filesystem_ready := false" in source
    assert "var _client_status_refresh_deferred_force := false" in source
    assert "var _client_status_refresh_deferred_initial := false" in source

    process_block = source.split("func _process(_delta: float) -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "_retry_deferred_client_status_refresh()" in process_block

    init_block = source.split(
        "func _perform_initial_client_status_refresh() -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]
    request_block = source.split(
        "func _request_client_status_refresh(force: bool = false) -> bool:", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "_is_editor_filesystem_busy()" in init_block
    assert "_defer_initial_client_status_refresh_until_filesystem_ready()" in init_block

    assert "_is_editor_filesystem_busy()" in request_block
    busy_request_block = request_block.split("if _is_editor_filesystem_busy():", 1)[
        1
    ].split("\n\n", 1)[0]
    assert "if force:" in busy_request_block
    assert "_defer_client_status_refresh_until_filesystem_ready(force)" in busy_request_block
    assert busy_request_block.index("if force:") < busy_request_block.index("return false")

    initial_defer_block = source.split(
        "func _defer_initial_client_status_refresh_until_filesystem_ready() -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "_client_status_refresh_deferred_until_filesystem_ready = true" in initial_defer_block
    assert "_client_status_refresh_deferred_initial = true" in initial_defer_block


def test_focus_refresh_is_opportunistic_while_editor_filesystem_is_busy() -> None:
    """Focus-in status refresh should never be treated as important editor work."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    focus_block = _focus_in_block(source)
    request_block = source.split(
        "func _request_client_status_refresh(force: bool = false) -> bool:", 1
    )[1].split("\n\nfunc ", 1)[0]
    busy_request_block = request_block.split("if _is_editor_filesystem_busy():", 1)[
        1
    ].split("\n\n", 1)[0]

    assert "_request_client_status_refresh(false)" in focus_block
    assert "_defer_client_status_refresh_until_filesystem_ready(force)" in busy_request_block
    assert "if force:" in busy_request_block
    assert "_refresh_all_client_statuses" not in focus_block
    assert "client_status_probe_snapshot(" not in focus_block
    assert "check_status" not in focus_block


def test_deferred_manual_refresh_replays_through_async_request_path_only() -> None:
    """Queued manual refreshes should not reintroduce PR #228's sync sweep."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    retry_block = source.split("func _retry_deferred_client_status_refresh() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]

    for block in (retry_block,):
        assert "_is_editor_filesystem_busy()" in block
        assert "_request_client_status_refresh(force)" in block
        assert "_refresh_all_client_statuses" not in block
        assert "client_status_probe_snapshot(" not in block
        assert "check_status" not in block

    assert "_client_status_refresh_deferred_initial = false" in retry_block
    assert "else:" in retry_block
    assert "_request_client_status_refresh(force)" in retry_block

    busy_block = source.split("func _is_editor_filesystem_busy() -> bool:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "EditorInterface.get_resource_filesystem()" in busy_block
    assert "fs.is_scanning()" in busy_block


def test_deferred_initial_refresh_replays_warmup_path() -> None:
    """Scan-delayed initial paint must preserve #235's main-thread warm-up."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    retry_block = source.split("func _retry_deferred_client_status_refresh() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]

    assert "var initial := _client_status_refresh_deferred_initial" in retry_block
    assert "if initial:" in retry_block
    assert "_perform_initial_client_status_refresh()" in retry_block
    assert retry_block.index("if initial:") < retry_block.index(
        "_request_client_status_refresh(force)"
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
    handoff_idx = install_block.find("install_downloaded_update")
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
        "(`f.store_buffer(content)`) inside `_install_update`'s legacy path."
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
    assert drain_idx < handoff_idx < first_write_idx, (
        "The normal Godot 4.4+ path must hand off to the update runner after "
        "the worker drain but before the legacy in-dock extract loop. The "
        "runner disables the old plugin before extraction so plugin-owned "
        "instances do not hot-reload in place."
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


def test_self_update_runner_disables_old_plugin_before_extract_and_scan() -> None:
    """The in-process update path must never expose a half-written addon tree."""

    plugin_source = (PLUGIN_ROOT / "plugin.gd").read_text()
    runner_source = (PLUGIN_ROOT / "update_reload_runner.gd").read_text()

    assert "UPDATE_RELOAD_RUNNER_SCRIPT" in plugin_source
    handoff_block = plugin_source.split(
        "func install_downloaded_update(", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "prepare_for_update_reload()" in handoff_block
    assert "remove_control_from_docks(_dock)" in handoff_block
    assert "remove_control_from_docks(source_dock)" in handoff_block
    assert "_dock = null" in handoff_block
    assert "runner.start(zip_path, temp_dir, detached_dock)" in handoff_block

    assert '_wait_frames(PRE_DISABLE_DRAIN_FRAMES, "_disable_old_plugin")' in runner_source

    disable_block = runner_source.split("func _disable_old_plugin() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert 'set_plugin_enabled(PLUGIN_CFG_PATH, false)' in disable_block
    assert '_wait_frames(POST_DISABLE_DRAIN_FRAMES, "_extract_and_scan")' in disable_block

    extract_block = runner_source.split("func _extract_and_scan() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "_read_update_manifest()" in extract_block
    assert "_install_zip_paths(_new_file_paths)" in extract_block
    assert '_start_filesystem_scan("_install_existing_files_and_scan")' in extract_block
    assert "_install_existing_files_and_scan.call_deferred()" in extract_block

    assert "INSTALL_BASE_PATH" in runner_source
    assert "TEMP_FILE_SUFFIX" in runner_source
    assert "ZIP_ADDON_PREFIX" in runner_source
    assert "STAGING_DIR_NAME" not in runner_source
    assert "rename_absolute(live_path, backup_path)" not in runner_source

    scan_block = runner_source.split("func _start_filesystem_scan", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert (
        'var deferred_step := next_step if not next_step.is_empty() else "_enable_new_plugin"'
        in scan_block
    )
    assert "call_deferred(deferred_step)" in scan_block
    assert "fs.filesystem_changed.connect(_on_filesystem_changed, CONNECT_ONE_SHOT)" in scan_block
    assert "fs.scan()" in scan_block
    assert "FILESYSTEM_SCAN_TIMEOUT" not in runner_source
    assert "_scan_timeout" not in runner_source
    process_block = runner_source.split("func _process(_delta: float) -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "_finish_scan_wait()" not in process_block, (
        "Do not treat a frame-count timeout as filesystem-scan completion. "
        "Re-enabling before `filesystem_changed` can parse plugin.gd before "
        "Godot has registered newly extracted class_name scripts."
    )

    finish_block = runner_source.split("func _finish_scan_wait() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert 'next_step = "_enable_new_plugin"' in finish_block
    assert "call_deferred(next_step)" in finish_block

    enable_block = runner_source.split("func _enable_new_plugin() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert 'set_plugin_enabled(PLUGIN_CFG_PATH, true)' in enable_block
    assert '_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")' in enable_block

    cleanup_block = runner_source.split("func _cleanup_and_finish() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "_cleanup_detached_dock()" in cleanup_block
    assert "queue_free()" in cleanup_block

    manifest_block = runner_source.split("func _read_update_manifest() -> bool:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "_is_safe_zip_addon_file(file_path)" in manifest_block
    assert "unsafe zip path" in manifest_block
    assert "_new_file_paths.clear()" in manifest_block
    assert "_existing_file_paths.clear()" in manifest_block
    assert "_new_file_paths.append(file_path)" in manifest_block
    assert "_existing_file_paths.append(file_path)" in manifest_block
    assert "FileAccess.file_exists(target_path)" in manifest_block
    assert "zip is missing plugin.cfg" in manifest_block
    assert "zip is missing plugin.gd" in manifest_block

    existing_block = runner_source.split("func _install_existing_files_and_scan() -> void:", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "_install_zip_paths(_existing_file_paths)" in existing_block
    assert "_cleanup_update_temp()" in existing_block
    assert '_start_filesystem_scan("_enable_new_plugin")' in existing_block

    safe_path_block = runner_source.split("func _is_safe_zip_addon_file(", 1)[
        1
    ].split("\n\nfunc ", 1)[0]
    assert "file_path.is_absolute_path()" in safe_path_block
    assert 'file_path.contains("\\\\")' in safe_path_block
    assert 'segment == ".."' in safe_path_block
    assert "segment.is_empty()" in safe_path_block

    install_file_block = runner_source.split("func _install_zip_file(", 1)[1].split(
        "\n\nfunc ", 1
    )[0]
    assert "var temp_path := target_path + TEMP_FILE_SUFFIX" in install_file_block
    assert "FileAccess.open(temp_path, FileAccess.WRITE)" in install_file_block
    assert "DirAccess.rename_absolute(temp_path, target_path)" in install_file_block
    assert "FileAccess.open(target_path, FileAccess.WRITE)" not in install_file_block
    assert "DirAccess.remove_absolute(target_path)" in install_file_block

    assert "OS.create_process" not in runner_source
    assert "get_tree().quit" not in runner_source
    assert "await " not in runner_source, (
        "The runner script is itself under addons/godot_ai, so fs.scan() can "
        "hot-reload it. It must not suspend with await across that reload; "
        "use _process/signal callbacks instead."
    )


def test_self_update_runner_does_not_introduce_typed_variant_storage_hazards() -> None:
    """The runner is the only plugin-owned script instance expected to survive scan."""

    runner_source = (PLUGIN_ROOT / "update_reload_runner.gd").read_text()
    risky_field = re.compile(r"^\s*var\s+\w+\s*:\s*(?:Dictionary|Array)(?:\[|[\s=])", re.M)

    assert risky_field.search(runner_source) is None, (
        "Do not add typed Dictionary/Array fields to update_reload_runner.gd. "
        "That instance intentionally survives fs.scan() and would recreate "
        "the #245 NIL-storage crash class."
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
