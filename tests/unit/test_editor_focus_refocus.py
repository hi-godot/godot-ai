"""Regression tests for editor focus/refocus behavior."""

from __future__ import annotations

import re
from pathlib import Path

from tests.unit._gdscript_text import get_func_block

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
    assert "ClientConfigurator.check_status" in source
    assert 'call_deferred("_apply_client_status_refresh_results' in source


def test_client_status_refresh_coalesces_and_manual_refresh_bypasses_cooldown() -> None:
    """Duplicate automatic refreshes should coalesce; manual actions stay explicit."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()

    assert "if ClientRefreshStateScript.has_worker_alive(_refresh_state):" in source
    assert "_client_status_refresh_pending = true" in source
    assert "if not force and _is_client_status_refresh_in_cooldown()" in source
    assert "_request_client_status_refresh(true)" in source


def test_clients_window_open_requests_nonblocking_refresh() -> None:
    """Opening Clients & Tools should not schedule a deferred synchronous sweep."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    block = get_func_block(source, "func _on_open_clients_window() -> void:")

    assert "_request_client_status_refresh(" in block
    assert "_refresh_all_client_statuses.call_deferred" not in block


def test_initial_paint_warms_worker_call_graph_before_threading() -> None:
    """Cold editor open pre-warms strategy bytecode on main, then hands every probe to the worker.

    Deterministic replacement for the prior 1.5s settle timer (#234), with
    every per-client status probe (JSON / TOML / CLI alike) routed through
    the existing worker so cold-start dock paint isn't blocked behind ~16
    sync `FileAccess.open` + `JSON.parse_string` calls.

    The race: Godot's lazy GDScript hot-reload of overwritten plugin files
    swaps bytecode on first dereference. A worker spawned from a fresh
    `_build_ui` walks straight into `_json_strategy.*` / `_cli_strategy.*` /
    `client_configurator.*` mid-swap → SIGABRT (#233).

    The fix: dereference every script the worker will touch on the main
    thread *before* the worker starts. After this helper, bytecode is
    stable everywhere the worker reaches → no race possible.

      • A single explicit `_warm_strategy_bytecode()` call invokes a
        pure-memory helper (no disk, no `OS.execute`) on each strategy
        script — `_json_strategy.gd`, `_toml_strategy.gd`, `_cli_strategy.gd`
        — plus `client_configurator.gd` via `client_ids()` / `get_by_id`.
      • `client_status_probe_snapshot` (called per client on main) builds
        the per-row probe envelope with the `installed` flag and (for CLI
        clients) the cached CLI path.
      • Every probe — JSON, TOML and CLI — is then handed to the same
        worker thread that already handles CLI probes. Disk reads + JSON
        parses for the ~17 non-CLI clients now happen off the main thread.

    The structural assertions below lock in this contract: a future "make
    startup snappier" refactor can't drop the explicit warming step
    (re-introducing #233's race), and a future "be more conservative"
    refactor can't move the per-client status reads back on-thread
    (regressing #228's responsiveness fix and re-blocking the cold paint).
    """

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    build_block = get_func_block(source, "func _build_ui() -> void:")
    assert "_perform_initial_client_status_refresh()" in build_block, (
        "_build_ui must call the initial-refresh helper"
    )

    helper_block = get_func_block(source, "func _perform_initial_client_status_refresh() -> void:")
    assert "_warm_strategy_bytecode()" in helper_block, (
        "Helper must call _warm_strategy_bytecode() before spawning the "
        "worker — that's the single explicit dereference of every strategy "
        "script the worker will reach into. Removing it re-introduces #233's "
        "lazy hot-reload SIGABRT race."
    )
    assert "client_status_probe_snapshot(" in helper_block, (
        "Helper must call client_status_probe_snapshot per client on main "
        "to build each row's probe envelope (installed flag + cached CLI "
        "path). See #235."
    )
    assert "check_status_for_url_with_cli_path(" not in helper_block, (
        "Helper must not run sync per-client status probes on main — that "
        "blocks the dock's cold paint behind ~16 FileAccess + JSON.parse "
        "calls. The worker handles JSON/TOML/CLI alike via "
        "_run_client_status_refresh_worker."
    )
    assert "all_probes" in helper_block, (
        "Helper must batch every probe (JSON + TOML + CLI) into one list "
        "for the worker thread. Splitting them would partially regress the "
        "cold-paint win or re-introduce the SIGABRT race for the moved-"
        "back-on-main clients."
    )
    assert "deferred_cli_probes" not in helper_block, (
        "The CLI-only batch is gone — the worker now handles every config "
        "type, so a CLI-specific staging list is dead code."
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

    warm_block = get_func_block(source, "func _warm_strategy_bytecode() -> void:")
    assert "JsonStrategy." in warm_block, (
        "_warm_strategy_bytecode must dereference JsonStrategy so the "
        "worker can't race the JSON strategy's lazy bytecode swap."
    )
    assert "TomlStrategy." in warm_block, (
        "_warm_strategy_bytecode must dereference TomlStrategy."
    )
    assert "CliStrategy." in warm_block, (
        "_warm_strategy_bytecode must dereference CliStrategy."
    )
    assert "FileAccess" not in warm_block and "OS.execute" not in warm_block, (
        "_warm_strategy_bytecode must stay pure-memory — no disk, no "
        "subprocess. The point is to dereference scripts cheaply, not to "
        "re-introduce the per-client disk reads we just moved to the worker."
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

    # PR 6 (#297) collapsed the deferred-* boolean cluster into the
    # McpClientRefreshState enum's DEFERRED_FOR_FILESYSTEM value, plus
    # a pair of pending request flags (force / initial) that survive
    # the wait window.
    assert "var _refresh_state: int = ClientRefreshStateScript.IDLE" in source
    assert "var _client_status_refresh_pending_force: bool = false" in source
    assert "var _client_status_refresh_pending_initial: bool = false" in source

    process_block = get_func_block(source, "func _process(_delta: float) -> void:")
    assert "_retry_deferred_client_status_refresh()" in process_block

    init_block = get_func_block(source, "func _perform_initial_client_status_refresh() -> void:")
    request_block = get_func_block(
        source, "func _request_client_status_refresh(force: bool = false) -> bool:"
    )
    assert "_is_editor_filesystem_busy()" in init_block
    assert "_defer_initial_client_status_refresh_until_filesystem_ready()" in init_block

    assert "_is_editor_filesystem_busy()" in request_block
    busy_request_block = request_block.split("if _is_editor_filesystem_busy():", 1)[1].split(
        "\n\n", 1
    )[0]
    assert "if force:" in busy_request_block
    assert "_defer_client_status_refresh_until_filesystem_ready(force)" in busy_request_block
    assert busy_request_block.index("if force:") < busy_request_block.index("return false")

    initial_defer_block = get_func_block(
        source, "func _defer_initial_client_status_refresh_until_filesystem_ready() -> void:"
    )
    deferred_marker = "_refresh_state = ClientRefreshStateScript.DEFERRED_FOR_FILESYSTEM"
    assert deferred_marker in initial_defer_block
    assert "_client_status_refresh_pending_initial = true" in initial_defer_block


def test_focus_refresh_is_opportunistic_while_editor_filesystem_is_busy() -> None:
    """Focus-in status refresh should never be treated as important editor work."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    focus_block = _focus_in_block(source)
    request_block = get_func_block(
        source, "func _request_client_status_refresh(force: bool = false) -> bool:"
    )
    busy_request_block = request_block.split("if _is_editor_filesystem_busy():", 1)[1].split(
        "\n\n", 1
    )[0]

    assert "_request_client_status_refresh(false)" in focus_block
    assert "_defer_client_status_refresh_until_filesystem_ready(force)" in busy_request_block
    assert "if force:" in busy_request_block
    assert "_refresh_all_client_statuses" not in focus_block
    assert "client_status_probe_snapshot(" not in focus_block
    assert "check_status" not in focus_block


def test_deferred_manual_refresh_replays_through_async_request_path_only() -> None:
    """Queued manual refreshes should not reintroduce PR #228's sync sweep."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    retry_block = get_func_block(source, "func _retry_deferred_client_status_refresh() -> void:")

    for block in (retry_block,):
        assert "_is_editor_filesystem_busy()" in block
        assert "_request_client_status_refresh(force)" in block
        assert "_refresh_all_client_statuses" not in block
        assert "client_status_probe_snapshot(" not in block
        assert "check_status" not in block

    assert "_client_status_refresh_pending_initial = false" in retry_block
    assert "else:" in retry_block
    assert "_request_client_status_refresh(force)" in retry_block

    busy_block = get_func_block(source, "func _is_editor_filesystem_busy() -> bool:")
    assert "EditorInterface.get_resource_filesystem()" in busy_block
    assert "fs.is_scanning()" in busy_block


def test_deferred_initial_refresh_replays_warmup_path() -> None:
    """Scan-delayed initial paint must preserve #235's main-thread warm-up."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    retry_block = get_func_block(source, "func _retry_deferred_client_status_refresh() -> void:")

    assert "var initial := _client_status_refresh_pending_initial" in retry_block
    assert "if initial:" in retry_block
    assert "_perform_initial_client_status_refresh()" in retry_block
    assert retry_block.index("if initial:") < retry_block.index(
        "_request_client_status_refresh(force)"
    )


def test_install_update_drains_workers_and_blocks_spawning_before_extract() -> None:
    """Self-update must drain in-flight workers + block new ones before any file write.

    Race B regression: focus-in landing in the extract→reload window of
    the install path previously spawned a fresh worker that walked into a
    half-overwritten plugin script and SIGABRT'd inside
    `GDScriptFunction::call` (observed in `Godot-2026-04-27-134236.ips`).
    Workers ALREADY running when install starts hit the same crash because
    the script being mid-`callp` gets its bytecode swapped under it.

    The fix has two parts that must both be present, both in the right order
    (before the write loop, after the symlink-safety early-return):

      1. `_install_in_flight = true`  — gates `_request_client_status_refresh`
         and `_perform_initial_client_status_refresh` so focus-in / cooldown /
         manual-button paths cannot spawn a new worker during the window.
      2. `_drain_dock_workers()` — synchronously joins the currently-running
         workers BEFORE we touch any plugin file on disk. The dock exposes
         `_drain_client_status_refresh_workers()` and
         `_drain_client_action_workers()`; the manager calls both.

    The install pipeline lives on `McpUpdateManager::_install_zip`, so
    this test reads the manager. The dock's gate is
    `_is_self_update_in_progress()` which consults the manager's flag.
    """

    manager_source = (PLUGIN_ROOT / "utils" / "update_manager.gd").read_text()
    install_block = get_func_block(manager_source, "func _install_zip() -> void:")

    flag_set_idx = install_block.find("_install_in_flight = true")
    drain_idx = install_block.find("_drain_dock_workers()")
    handoff_idx = install_block.find("install_downloaded_update")
    symlink_return_idx = install_block.find("addons_dir_is_symlink()")

    inline_block = get_func_block(
        manager_source, "func _install_zip_inline(version: Dictionary) -> void:"
    )
    first_write_idx = inline_block.find("f.store_buffer(content)")

    assert flag_set_idx > 0, (
        "_install_zip must set `_install_in_flight = true` before "
        "extracting plugin files. Without this, focus-in during extract "
        "spawns a worker that crashes on the half-overwritten scripts."
    )
    assert drain_idx > 0, (
        "_install_zip must call `_drain_dock_workers()` before extracting "
        "plugin files. Already-running workers crash on the same overwrite "
        "if not joined first."
    )
    assert first_write_idx > 0, (
        "Test fixture broken: could not locate the extract-write site "
        "(`f.store_buffer(content)`) inside `_install_zip_inline`."
    )
    assert symlink_return_idx > 0, "Test fixture broken: could not locate the symlink-safety check."

    assert symlink_return_idx < flag_set_idx, (
        "Order: symlink-safety check → set _install_in_flight flag. Setting "
        "the flag before the symlink check would leave it stuck on the "
        "dev-checkout path."
    )
    assert drain_idx < handoff_idx, (
        "The Godot 4.4+ runner-based path must hand off to the runner after "
        "the worker drain. The runner disables the old plugin before "
        "extraction so plugin-owned instances do not hot-reload in place."
    )

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    request_block = get_func_block(
        dock_source, "func _request_client_status_refresh(force: bool = false) -> bool:"
    )
    assert "if _is_self_update_in_progress():" in request_block, (
        "_request_client_status_refresh must short-circuit when self-update "
        "is in progress. This is the funnel for focus-in, manual-button, "
        "and cooldown-timer spawn paths — gating here covers every caller. "
        "The flag lives on McpUpdateManager; the dock consults it via "
        "`_is_self_update_in_progress()`."
    )

    init_block = get_func_block(
        dock_source, "func _perform_initial_client_status_refresh() -> void:"
    )
    assert "if _is_self_update_in_progress():" in init_block, (
        "_perform_initial_client_status_refresh must also short-circuit on "
        "the self-update flag — defensive even though the new dock instance "
        "wouldn't normally see this flag set."
    )


def test_self_update_runner_disables_old_plugin_before_extract_and_scan() -> None:
    """The in-process update path must never expose a half-written addon tree."""

    plugin_source = (PLUGIN_ROOT / "plugin.gd").read_text()
    runner_source = (PLUGIN_ROOT / "update_reload_runner.gd").read_text()

    assert "UPDATE_RELOAD_RUNNER_SCRIPT" in plugin_source
    handoff_block = get_func_block(plugin_source, "func install_downloaded_update(")
    assert "prepare_for_update_reload()" in handoff_block
    assert "remove_control_from_docks(_dock)" in handoff_block
    assert "remove_control_from_docks(source_dock)" in handoff_block
    assert "_dock = null" in handoff_block
    assert "runner.start(zip_path, temp_dir, detached_dock)" in handoff_block

    assert '_wait_frames(PRE_DISABLE_DRAIN_FRAMES, "_disable_old_plugin")' in runner_source

    disable_block = get_func_block(runner_source, "func _disable_old_plugin() -> void:")
    assert "set_plugin_enabled(PLUGIN_CFG_PATH, false)" in disable_block
    assert '_wait_frames(POST_DISABLE_DRAIN_FRAMES, "_extract_and_scan")' in disable_block

    extract_block = get_func_block(runner_source, "func _extract_and_scan() -> void:")
    assert "_read_update_manifest()" in extract_block
    assert "_install_zip_paths(_new_file_paths)" in extract_block
    assert '_start_filesystem_scan("_install_existing_files_and_scan")' in extract_block
    assert "_install_existing_files_and_scan.call_deferred()" in extract_block

    assert "INSTALL_BASE_PATH" in runner_source
    assert "TEMP_FILE_SUFFIX" in runner_source
    assert "ZIP_ADDON_PREFIX" in runner_source
    assert "STAGING_DIR_NAME" not in runner_source
    assert "rename_absolute(live_path, backup_path)" not in runner_source

    scan_block = get_func_block(runner_source, "func _start_filesystem_scan")
    assert (
        'var deferred_step := next_step if not next_step.is_empty() else "_enable_new_plugin"'
        in scan_block
    )
    assert "call_deferred(deferred_step)" in scan_block
    assert "fs.filesystem_changed.connect(_on_filesystem_changed, CONNECT_ONE_SHOT)" in scan_block
    assert "fs.scan()" in scan_block
    assert "FILESYSTEM_SCAN_TIMEOUT" not in runner_source
    assert "_scan_timeout" not in runner_source
    process_block = get_func_block(runner_source, "func _process(_delta: float) -> void:")
    assert "_finish_scan_wait()" not in process_block, (
        "Do not treat a frame-count timeout as filesystem-scan completion. "
        "Re-enabling before `filesystem_changed` can parse plugin.gd before "
        "Godot has registered newly extracted class_name scripts."
    )

    finish_block = get_func_block(runner_source, "func _finish_scan_wait() -> void:")
    assert 'next_step = "_enable_new_plugin"' in finish_block
    assert "call_deferred(next_step)" in finish_block

    enable_block = get_func_block(runner_source, "func _enable_new_plugin() -> void:")
    assert "set_plugin_enabled(PLUGIN_CFG_PATH, true)" in enable_block
    assert '_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")' in enable_block

    cleanup_block = get_func_block(runner_source, "func _cleanup_and_finish() -> void:")
    assert "_cleanup_detached_dock()" in cleanup_block
    assert "queue_free()" in cleanup_block

    manifest_block = get_func_block(runner_source, "func _read_update_manifest() -> bool:")
    assert "_is_safe_zip_addon_file(file_path)" in manifest_block
    assert "unsafe zip path" in manifest_block
    assert "_new_file_paths.clear()" in manifest_block
    assert "_existing_file_paths.clear()" in manifest_block
    assert "_new_file_paths.append(file_path)" in manifest_block
    assert "_existing_file_paths.append(file_path)" in manifest_block
    assert "FileAccess.file_exists(target_path)" in manifest_block
    assert "zip is missing plugin.cfg" in manifest_block
    assert "zip is missing plugin.gd" in manifest_block
    dir_skip = 'rel_path.is_empty() or file_path.ends_with("/")'
    assert dir_skip in manifest_block
    assert manifest_block.index(dir_skip) < manifest_block.index(
        "_is_safe_zip_addon_file(file_path)"
    ), (
        "Skip zero-byte directory entries (rel_path empty or trailing slash) "
        "BEFORE the _is_safe_zip_addon_file check. Zips without `zip -D` "
        "(older release artifacts, AssetLib uploads, hand-built archives) "
        "include a bare `addons/godot_ai/` directory entry; the safety "
        "guard treats its empty rel_path as unsafe and aborts the extract, "
        "breaking self-update for any user whose installed runner sees one."
    )

    existing_block = get_func_block(
        runner_source, "func _install_existing_files_and_scan() -> void:"
    )
    assert "_install_zip_paths(_existing_file_paths)" in existing_block
    assert "_cleanup_update_temp()" in existing_block
    assert '_start_filesystem_scan("_enable_new_plugin")' in existing_block

    safe_path_block = get_func_block(runner_source, "func _is_safe_zip_addon_file(")
    assert "file_path.is_absolute_path()" in safe_path_block
    assert 'file_path.contains("\\\\")' in safe_path_block
    assert 'segment == ".."' in safe_path_block
    assert "segment.is_empty()" in safe_path_block

    install_file_block = get_func_block(runner_source, "func _install_zip_file(")
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
    worker_block = get_func_block(dock_source, "func _run_client_status_refresh_worker")

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


def test_check_uv_version_caches_for_session() -> None:
    """`uvx --version` must run at most once per editor session.

    The dock's `_refresh_setup_status` calls `McpClientConfigurator.check_uv_version()`
    on the main thread (via `call_deferred` from `_build_ui`) in user mode.
    Each cold call costs an `OS.execute("uvx", ["--version"])` round-trip
    (~80 ms on Linux, more on Windows) — multiplied by every focus-in
    refresh and every manual Refresh click that's a real cost on the
    dock's first paint and on every responsiveness gate after.

    Cache it the same way `_cached_venv_python` already works
    (`_venv_python_cache` + `_venv_python_searched` pair). Invalidate
    only when the user installs / reinstalls uv via the dock — the
    `McpCliFinder.invalidate("uvx")` site is the natural sibling, so
    a single explicit `invalidate_uv_version_cache()` call clears both.
    """

    source = (PLUGIN_ROOT / "client_configurator.gd").read_text()

    assert "static var _uv_version_cache: String" in source, (
        "Cached `uvx --version` string must be a class-level static so it "
        "survives across plugin reloads and dock rebuilds."
    )
    assert "static var _uv_version_searched: bool" in source, (
        "Companion 'have we searched yet?' flag must be a class-level "
        "static — empty cache is ambiguous (means both 'never asked' and "
        "'asked, uv not installed') without it."
    )

    helper_block = get_func_block(source, "static func check_uv_version() -> String:")
    assert "if _uv_version_searched:" in helper_block, (
        "First line of check_uv_version must short-circuit on the cached "
        "result. Otherwise the cache is doing nothing."
    )
    assert "return _uv_version_cache" in helper_block, (
        "The short-circuit must return the cached string, not re-derive it."
    )
    assert "_uv_version_searched = true" in helper_block, (
        "Every code path that calls OS.execute or short-circuits 'uv not "
        "found' must set _uv_version_searched = true. Otherwise the next "
        "call re-runs OS.execute, defeating the cache."
    )

    assert "static func invalidate_uv_version_cache() -> void:" in source, (
        "An explicit invalidator must exist so the dock's _on_install_uv "
        "can drop the cached 'uv not found' result after a successful "
        "install."
    )

    invalidator_block = get_func_block(source, "static func invalidate_uv_version_cache() -> void:")
    assert "_uv_version_searched = false" in invalidator_block, (
        "Invalidator must reset _uv_version_searched, otherwise the next "
        "call short-circuits on the stale cached value."
    )
    assert "_uv_version_cache = " in invalidator_block, (
        "Invalidator must clear the cached string too — leaving stale data "
        "would surface in any path that reads the cache without going "
        "through check_uv_version (e.g. future inspectors / debug helpers)."
    )

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    install_block = get_func_block(dock_source, "func _on_install_uv() -> void:")
    assert "ClientConfigurator.invalidate_uvx_cli_cache()" in install_block, (
        "_on_install_uv must invalidate the CLI-path cache via the "
        "configurator helper (which knows the OS-specific binary name). "
        'A direct `CliFinder.invalidate("uvx")` would leave the '
        "Windows cache stale — Windows caches under `uvx.exe`."
    )
    assert "ClientConfigurator.invalidate_uv_version_cache()" in install_block, (
        "_on_install_uv must invalidate the version cache too — without "
        "this, the dock's setup status keeps showing 'uv: not found' "
        "after a successful install."
    )

    cli_invalidator_block = get_func_block(
        source, "static func invalidate_uvx_cli_cache() -> void:"
    )
    assert "_uvx_cli_names()" in cli_invalidator_block, (
        "invalidate_uvx_cli_cache must route through the same "
        "_uvx_cli_names() helper that find_uvx() uses, so the OS-"
        "specific binary name (uvx vs uvx.exe) stays in lockstep "
        "between the populator and the invalidator."
    )


def test_force_refresh_invalidates_cli_finder_cache() -> None:
    """Force-refresh (manual button, popup open, any explicit-user callsite)
    flushes CliFinder so a freshly-installed CLI is re-detected without an
    editor restart. Focus-in (`force=false`) keeps the cache.
    """

    configurator_source = (PLUGIN_ROOT / "client_configurator.gd").read_text()
    invalidator_block = get_func_block(
        configurator_source, "static func invalidate_cli_cache() -> void:"
    )
    assert "CliFinder.invalidate()" in invalidator_block, (
        "Facade must call no-arg CliFinder.invalidate() to drop every "
        "cached entry (positive and negative)."
    )

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    request_block = get_func_block(
        dock_source,
        "func _request_client_status_refresh(force: bool = false) -> bool:",
    )
    assert re.search(
        r"if force:\s+ClientConfigurator\.invalidate_cli_cache\(\)",
        request_block,
    ), (
        "_request_client_status_refresh must flush CliFinder when "
        "force=true so manual refresh, popup-open, and every other "
        "explicit-user-action callsite re-detects newly-installed CLIs."
    )

    focus_in_block = _focus_in_block(dock_source)
    assert "invalidate_cli_cache" not in focus_in_block, (
        "Focus-in must NOT flush — focus fires dozens of times per "
        "session and would re-fork `which` / `bash -lc` every time."
    )


def test_cli_finder_cache_is_mutex_guarded() -> None:
    """`CliFinder.find()` runs on action-worker threads
    (`_run_client_action_worker` in `mcp_dock.gd`) and `invalidate()` runs on
    the main thread (force-refresh path). Godot `Dictionary` is not safe for
    concurrent mutation, so `_cache` / `_searched` access must be guarded by
    a `Mutex`. The mutex must NOT be held across `_resolve()` (which forks
    `bash -lc` / `which` and can take 100ms-1s) — otherwise a main-thread
    `invalidate()` blocks the editor on a worker's subprocess, defeating
    the off-main-thread CLI-lookup design.
    """

    source = (PLUGIN_ROOT / "clients" / "_cli_finder.gd").read_text()

    assert re.search(r"static var _mutex: Mutex = Mutex\.new\(\)", source), (
        "CliFinder must declare `static var _mutex: Mutex = Mutex.new()` so "
        "concurrent find()/invalidate() calls don't race the shared "
        "_cache / _searched dictionaries."
    )

    invalidate_block = get_func_block(
        source, "static func invalidate(exe_name: String = \"\") -> void:"
    )
    assert "_mutex.lock()" in invalidate_block and "_mutex.unlock()" in invalidate_block, (
        "invalidate() must hold _mutex around the dict clear/erase so it "
        "can race safely against worker-thread find() calls."
    )

    find_one_block = get_func_block(source, "static func _find_one(exe_name: String) -> String:")
    # Lock + unlock pattern must appear at least twice: once around the
    # cache read, once around the cache writeback. _resolve() must run
    # outside any lock — the lock/unlock count therefore tells us the
    # critical sections aren't accidentally fused into a single span that
    # encloses the subprocess fork.
    assert find_one_block.count("_mutex.lock()") >= 2, (
        "_find_one() must lock _mutex separately around the read and the "
        "writeback so _resolve() (which forks bash) runs unlocked."
    )
    assert find_one_block.count("_mutex.unlock()") >= 2, (
        "_find_one() must release _mutex before calling _resolve(), "
        "otherwise a main-thread invalidate() blocks on the subprocess."
    )
    # Hard guarantee: no `_resolve(` call sandwiched between a lock and the
    # next unlock. Search for the resolve call and check the surrounding
    # context.
    resolve_idx = find_one_block.index("_resolve(")
    preceding = find_one_block[:resolve_idx]
    last_lock = preceding.rfind("_mutex.lock()")
    last_unlock = preceding.rfind("_mutex.unlock()")
    assert last_unlock > last_lock, (
        "_resolve() must be called with _mutex unlocked. Holding the lock "
        "across the subprocess fork would let invalidate() freeze the main "
        "thread for the duration of `bash -lc` / `which` — exactly the "
        "main-thread blocking the off-thread design exists to avoid."
    )


def test_configure_all_uses_cached_status_not_dot_color() -> None:
    """Configure-all must not make correctness decisions from stale UI colors."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    block = get_func_block(source, "func _on_configure_all_clients() -> void:")

    assert 'get("status", Client.Status.NOT_CONFIGURED)' in block
    assert "dot.color" not in block


def _focus_in_block(source: str) -> str:
    marker = "NOTIFICATION_APPLICATION_FOCUS_IN"
    start = source.index(marker)
    return source[start : source.index("\n\n", start)]
