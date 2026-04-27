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
    assert "call_deferred(\"_apply_client_status_refresh_results" in source


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


def test_initial_paint_requests_async_status_refresh() -> None:
    """Cold editor open populates client dots via the deferred helper (#233).

    Asserts the call chain end-to-end so a future refactor can't accidentally
    drop the auto-spawn or remove the hot-reload settle delay.
    """

    source = (PLUGIN_ROOT / "mcp_dock.gd").read_text()
    build_block = source.split("func _build_ui() -> void:", 1)[1].split("\n\nfunc ", 1)[0]
    assert "_schedule_initial_client_status_refresh()" in build_block, (
        "_build_ui must schedule the initial refresh"
    )

    helper_block = source.split(
        "func _schedule_initial_client_status_refresh() -> void:", 1
    )[1].split("\n\nfunc ", 1)[0]
    assert "_request_client_status_refresh(true)" in helper_block, (
        "Helper must ultimately call the force-refresh path"
    )
    assert "CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC" in helper_block, (
        "Helper must defer past hot-reload settle window"
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
