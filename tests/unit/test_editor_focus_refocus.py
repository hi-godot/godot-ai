"""Regression tests for editor focus/refocus behavior."""

from __future__ import annotations

import re
from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def _get_call_expression(source: str, function_name: str) -> str:
    """Return one balanced call expression, including its argument list."""

    start = source.index(f"{function_name}(")
    open_paren = source.index("(", start)
    depth = 0
    for index in range(open_paren, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"Unbalanced {function_name} call")


def test_focus_in_uses_async_cooled_down_refresh_instead_of_blocking_sweep() -> None:
    """Focus-in should keep automatic refresh without blocking the editor thread."""

    dock = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")

    assert "NOTIFICATION_APPLICATION_FOCUS_IN" in dock
    assert "STATUS_COOLDOWN_MSEC := 15 * 1000" in owner
    assert "_request_client_status_refresh(false)" in dock
    assert "_refresh_all_client_statuses()" not in _focus_in_block(dock)


def test_client_status_refresh_runs_on_background_thread_and_reaps_on_main() -> None:
    """Blocking client probes should run off-thread; UI updates should be reaped on main."""

    dock = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")

    assert "var _refresh_thread: Thread" in owner
    assert "_refresh_thread.start" in owner
    assert "ClientConfigurator.check_status" in owner
    assert "_poll_refresh()" in get_func_block(owner, "func _process(_delta: float) -> void:")
    assert "Thread" not in get_func_block(dock, "func _process(_delta: float) -> void:")
    assert "func present_client_status_refresh_results(" in dock


def test_client_status_refresh_coalesces_and_manual_refresh_bypasses_cooldown() -> None:
    """Duplicate automatic refreshes should coalesce; manual actions stay explicit."""

    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")
    dock = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")

    assert "if RefreshState.has_worker_alive(_refresh_state):" in owner
    assert "_refresh_pending = true" in owner
    assert "if not force and _refresh_completed_msec > 0:" in owner
    assert "_request_client_status_refresh(true)" in dock


def test_clients_window_open_requests_nonblocking_refresh() -> None:
    """Opening Clients & Tools should not schedule a deferred synchronous sweep."""

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    block = get_func_block(source, "func _on_open_clients_window() -> void:")

    assert "_request_client_status_refresh(" in block
    assert "_refresh_all_client_statuses.call_deferred" not in block


def test_initial_paint_warms_worker_call_graph_before_threading() -> None:
    """The owner warms every worker dependency before starting its thread."""

    dock = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")
    build = get_func_block(dock, "func _build_ui() -> void:")
    request = get_func_block(owner, "func request_status_refresh(")
    warm = get_func_block(owner, "func _warm_worker_bytecode() -> void:")

    assert "_perform_initial_client_status_refresh()" in build
    assert request.index("_warm_worker_bytecode()") < request.index("_refresh_thread.start")
    assert "client_status_probe_snapshot(" in request
    assert "JsonStrategy." in warm and "TomlStrategy." in warm and "CliStrategy." in warm
    assert "FileAccess" not in warm and "OS.execute" not in warm
    assert "await " not in request and "create_timer" not in request


def test_client_status_refresh_defers_while_editor_filesystem_is_busy() -> None:
    """Refresh workers must not race Godot's script reload/documentation pass."""

    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")
    request = get_func_block(owner, "func request_status_refresh(")
    retry = get_func_block(owner, "func _retry_deferred_refresh() -> void:")

    assert "_filesystem_busy()" in request
    assert "_refresh_state = RefreshState.DEFERRED_FOR_FILESYSTEM" in request
    assert "_refresh_pending_force = _refresh_pending_force or force" in request
    assert "_filesystem_busy()" in retry
    assert "request_status_refresh(_client_ids, force)" in retry
    assert "_refresh_pending_initial" not in owner


def test_focus_refresh_is_opportunistic_while_editor_filesystem_is_busy() -> None:
    """Focus-in status refresh should never be treated as important editor work."""

    dock = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")
    focus = _focus_in_block(dock)
    request = get_func_block(owner, "func request_status_refresh(")

    assert "_request_client_status_refresh(false)" in focus
    assert "_filesystem_busy()" in request
    assert "_refresh_all_client_statuses" not in focus
    assert "client_status_probe_snapshot(" not in focus
    assert "check_status" not in focus


def test_deferred_manual_refresh_replays_through_async_request_path_only() -> None:
    """Queued manual refreshes should not reintroduce PR #228's sync sweep."""

    owner = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")
    retry = get_func_block(owner, "func _retry_deferred_refresh() -> void:")
    filesystem = get_func_block(owner, "func _filesystem_busy() -> bool:")

    assert "_filesystem_busy()" in retry
    assert "request_status_refresh(_client_ids, force)" in retry
    assert "client_status_probe_snapshot(" not in retry
    assert "check_status" not in retry
    assert "EditorInterface.get_resource_filesystem()" in filesystem
    assert "filesystem.is_scanning()" in filesystem


def test_worker_uses_main_thread_probe_snapshot_for_cli_paths() -> None:
    """CLI path discovery caches should not be mutated from the refresh worker."""

    owner_source = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(
        encoding="utf-8"
    )
    configurator_source = (PLUGIN_ROOT / "client_configurator.gd").read_text(encoding="utf-8")
    cli_source = (PLUGIN_ROOT / "clients" / "_cli_strategy.gd").read_text(encoding="utf-8")
    request_block = get_func_block(owner_source, "func request_status_refresh(")
    worker_block = get_func_block(owner_source, "func _run_status_refresh(")

    assert "client_status_probe_snapshot" in request_block
    # Worker uses the details variant so probe timeouts (issue #238) can
    # surface as "probe timed out" on the row instead of being silently
    # conflated with NOT_CONFIGURED.
    assert "check_status_details_for_url_with_cli_path" in worker_block
    assert "McpClientConfigurator.is_installed" not in worker_block
    assert "resolve_cli_path" in configurator_source
    assert "check_status_with_cli_path" in cli_source


def test_status_aggregates_resolve_shared_attach_launch_once() -> None:
    """Claude Desktop and Codex must not each pay cold launch discovery."""

    owner_source = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(
        encoding="utf-8"
    )
    worker_block = get_func_block(owner_source, "func _run_status_refresh(")

    assert worker_block.count("resolve_attach_launch(") == 1
    call = _get_call_expression(
        worker_block, "check_status_details_for_url_with_cli_path"
    )
    assert "resolved_launch" in call


def test_handler_client_status_sweep_is_deferred_to_worker() -> None:
    """WebSocket dispatch delegates to the one plugin-lifetime worker owner."""

    source = (PLUGIN_ROOT / "handlers" / "client_handler.gd").read_text(
        encoding="utf-8"
    )
    owner_source = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(
        encoding="utf-8"
    )
    handler_block = get_func_block(source, "func check_client_status")
    worker_block = get_func_block(owner_source, "func _run_status_refresh(")

    assert "McpDispatcher.DEFERRED_RESPONSE" in handler_block
    assert "_client_jobs.request_mcp_status(request_id)" in handler_block
    assert "capture_launch_context" not in handler_block
    assert "check_status_details_for_url_with_cli_path" not in handler_block
    assert "check_status_details_for_url_with_cli_path" in worker_block
    assert "Thread.new()" not in source


def test_client_status_worker_has_one_owner_and_is_joined_before_script_swap() -> None:
    """Aggregate errors stay actionable and the sole owner joins its Thread."""

    handler_source = (PLUGIN_ROOT / "handlers" / "client_handler.gd").read_text(
        encoding="utf-8"
    )
    owner_source = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(
        encoding="utf-8"
    )
    configurator_source = (PLUGIN_ROOT / "client_configurator.gd").read_text(
        encoding="utf-8"
    )
    plugin_source = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")

    entry_block = get_func_block(
        configurator_source, "static func _client_status_sweep_entry"
    )
    teardown_block = get_func_block(owner_source, "func quiesce(")
    finish_block = get_func_block(owner_source, "func _poll_refresh()")

    assert 'entry["error"] = error_msg' in entry_block
    assert "_refresh_thread.wait_to_finish()" in teardown_block
    assert "_mcp_status_waiters.clear()" in teardown_block
    assert "_refresh_thread.wait_to_finish()" in finish_block
    assert "Thread" not in handler_source
    assert "_status_workers" not in handler_source
    assert "mcp_status_completed.connect(_on_mcp_client_status_completed)" in plugin_source
    assert "_client_jobs.quiesce(" in plugin_source


def test_refresh_timeout_retains_one_worker_and_coalesces_one_retry() -> None:
    """Repeated force requests must not create unbounded live status workers."""

    source = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(encoding="utf-8")
    request = get_func_block(source, "func request_status_refresh(")

    assert "STATUS_TIMEOUT_MSEC := 30 * 1000" in source
    assert "_refresh_pending = true" in request
    assert "_refresh_pending_force = _refresh_pending_force or force" in request
    assert "_abandon_refresh" not in source
    assert "_refresh_orphans" not in source


def test_vision_workers_cannot_queue_old_script_callbacks_across_swap() -> None:
    vision_source = (PLUGIN_ROOT / "vision_routing.gd").read_text(encoding="utf-8")
    plugin_source = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")
    route_worker = get_func_block(vision_source, "func _route_worker(")
    ping_worker = get_func_block(vision_source, "func _ping_worker(")
    shutdown = get_func_block(vision_source, "func shutdown() -> void:")
    process = get_func_block(plugin_source, "func _process(_delta: float) -> void:")

    assert "call_deferred" not in route_worker
    assert "call_deferred" not in ping_worker
    assert 'return {"kind": "route"' in route_worker
    assert 'return {"kind": "ping"' in ping_worker
    assert "_set_active(false)" in shutdown
    assert "thread.wait_to_finish()" in shutdown
    assert "_vision_routing.poll_completed()" in process


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

    source = (PLUGIN_ROOT / "client_configurator.gd").read_text(encoding="utf-8")

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

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    install_block = get_func_block(dock_source, "func _on_install_uv() -> void:")
    assert "ClientConfigurator.invalidate_uv_detection()" in install_block, (
        "_on_install_uv must invalidate uv detection via the configurator "
        "helper (which knows the OS-specific binary name). A direct "
        '`CliFinder.invalidate("uvx")` would leave the Windows cache '
        "stale — Windows caches under `uvx.exe`."
    )

    # #739: the combined invalidator must clear BOTH caches — the resolved
    # uvx path and the cached `uvx --version` output. Dropping only one
    # leaves the dock pinned on the stale half (path cache alone -> the old
    # "not found" version string survives; version cache alone -> the old
    # empty path survives).
    detection_block = get_func_block(source, "static func invalidate_uv_detection() -> void:")
    assert "invalidate_uvx_cli_cache()" in detection_block, (
        "invalidate_uv_detection must drop the CLI-path cache via the "
        "OS-aware helper so the uvx binary is re-resolved."
    )
    assert "invalidate_uv_version_cache()" in detection_block, (
        "invalidate_uv_detection must drop the version cache too — without "
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

    configurator_source = (PLUGIN_ROOT / "client_configurator.gd").read_text(encoding="utf-8")
    invalidator_block = get_func_block(
        configurator_source, "static func invalidate_cli_cache() -> void:"
    )
    assert "CliFinder.invalidate()" in invalidator_block, (
        "Facade must call no-arg CliFinder.invalidate() to drop every "
        "cached entry (positive and negative)."
    )

    owner_source = (PLUGIN_ROOT / "utils" / "client_job_owner.gd").read_text(
        encoding="utf-8"
    )
    request_block = get_func_block(
        owner_source,
        "func request_status_refresh(",
    )
    assert re.search(
        r"if force:\s+ClientConfigurator\.invalidate_cli_cache\(\)",
        request_block,
    ), (
        "_request_client_status_refresh must flush CliFinder when "
        "force=true so manual refresh, popup-open, and every other "
        "explicit-user-action callsite re-detects newly-installed CLIs."
    )

    dock_source = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
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

    source = (PLUGIN_ROOT / "clients" / "_cli_finder.gd").read_text(encoding="utf-8")

    assert re.search(r"static var _mutex: Mutex = Mutex\.new\(\)", source), (
        "CliFinder must declare `static var _mutex: Mutex = Mutex.new()` so "
        "concurrent find()/invalidate() calls don't race the shared "
        "_cache / _searched dictionaries."
    )

    invalidate_block = get_func_block(
        source, 'static func invalidate(exe_name: String = "") -> void:'
    )
    assert "_mutex.lock()" in invalidate_block and "_mutex.unlock()" in invalidate_block, (
        "invalidate() must hold _mutex around the dict clear/erase so it "
        "can race safely against worker-thread find() calls."
    )

    find_one_block = get_func_block(source, "static func _find_one(")
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

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text(encoding="utf-8")
    block = get_func_block(source, "func _on_configure_all_clients() -> void:")

    assert 'get("status", Client.Status.NOT_CONFIGURED)' in block
    assert "dot.color" not in block


def _focus_in_block(source: str) -> str:
    marker = "NOTIFICATION_APPLICATION_FOCUS_IN"
    start = source.index(marker)
    return source[start : source.index("\n\n", start)]
