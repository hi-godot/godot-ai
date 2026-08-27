"""Source-structure pins for the post-self-update stale-server handling.

Three cooperating pieces keep a self-update from dead-ending on a
previous-version backend that attach bridges keep alive (the "Port 8000 is
occupied by godot-ai server vOLD" loop that used to require a manual plugin
toggle):

1. `update_manager.gd` pre-warms the uv cache for the NEW server version
   while the plugin zip downloads, so the post-update spawn wins the port
   bind race against bridges respawning the cached OLD version.
2. `plugin.gd` peeks the runner's pending self-update marker BEFORE the
   startup walk and arms the lifecycle's bounded weak-proof recovery
   (`authorize_stale_recovery`), then notifies the dock to auto-repin
   stale client configs after the telemetry drain.
3. `server_lifecycle.gd` keeps the retry loop bounded: automatic triggers
   only SPEND budget; only user actions (Update click, dock Restart click)
   arm it.

These are cross-file ordering contracts the GDScript unit suites cannot see
end-to-end, so they are pinned at the source level here. Behavior coverage
lives in test_server_lifecycle.gd / test_plugin_lifecycle.gd /
test_dock.gd.
"""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = REPO_ROOT / "plugin" / "addons" / "godot_ai"


def _read(rel: str) -> str:
    return (PLUGIN_ROOT / rel).read_text(encoding="utf-8")


def test_update_install_prewarms_new_server_before_download_starts() -> None:
    """`start_install` must fire the pre-warm before creating the download
    request, so the uv build overlaps the zip download instead of starting
    after the reload (when the race is already being lost)."""
    source = _read("utils/update_manager.gd")
    block = get_func_block(source, "func start_install() -> void:")

    assert "ClientConfigurator.prewarm_server_package(_latest_remote_version)" in block
    assert block.index("prewarm_server_package") < block.index(
        "_download_request = HTTPRequest.new()"
    ), "pre-warm must start before the zip download so the two overlap"


def test_prewarm_pins_exact_version_and_exits_via_version_flag() -> None:
    """The warmed env must be the exact release being installed, and the
    spawned process must exit on its own (`--version`) rather than starting
    a server. The argv builder also constrains the version to the PEP 440
    alphabet — the value can originate from a GitHub release tag (#890)."""
    source = _read("client_configurator.gd")
    spawn_block = get_func_block(
        source, "static func prewarm_server_package(version: String) -> int:"
    )
    assert "prewarm_server_package_argv(version)" in spawn_block
    assert "find_uvx()" in spawn_block, "must no-op cleanly when uvx is absent"

    argv_block = get_func_block(
        source, "static func prewarm_server_package_argv(version: String) -> Array[String]:"
    )
    assert '"--from", "godot-ai==%s" % pinned' in argv_block
    assert '"--version"' in argv_block
    assert "RegEx" in argv_block, "the tag-originated version must be charset-constrained"


def test_recovery_kill_workers_prewarm_the_current_version() -> None:
    """#890 review P1 (transition release): the upgrade INTO the release that
    ships this code runs the OLD updater, so no click-time pre-warm happens.
    Both weak-kill flows must therefore warm the current server env inside
    their kill worker (overlapping the kill + port drain), via the host seam
    so tests never spawn a real uvx."""
    lifecycle = _read("utils/server_lifecycle.gd")

    stale_block = get_func_block(
        lifecycle, "func recover_stale_port_occupant(port: int, wait_s: float) -> bool:"
    )
    assert "_host._prewarm_server_package(expected_version)" in stale_block

    recover_block = get_func_block(
        lifecycle, "func recover_incompatible_server() -> bool:"
    )
    assert "_host._prewarm_server_package(recovery_expected_version)" in recover_block

    plugin = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")
    seam = get_func_block(plugin, "func _prewarm_server_package(version: String) -> int:")
    assert "ClientConfigurator.prewarm_server_package(version)" in seam


def test_stale_recovery_reverifies_version_inside_the_worker() -> None:
    """#890 CodeRabbit: the caller's staleness gate ran on an earlier probe.
    The recovery worker must re-probe and abort on a same-version (or
    unverifiable) occupant before evaluating any kill proof."""
    lifecycle = _read("utils/server_lifecycle.gd")
    block = get_func_block(
        lifecycle, "func recover_stale_port_occupant(port: int, wait_s: float) -> bool:"
    )
    assert "_verified_status_version(live)" in block
    assert "live_version.is_empty() or live_version == expected_version" in block
    reprobe_at = block.index("_verified_status_version")
    proof_at = block.index("_evaluate_recovery_port_occupant_proof")
    assert reprobe_at < proof_at, "the version re-check must precede the kill proof"


def test_pid_file_publication_does_not_cancel_the_stale_budget() -> None:
    """#890 review P1: the Python server writes its pid-file during import,
    BEFORE binding HTTP/WS — publication is not proof the new server owns
    either port, so it must not zero the remaining recovery rounds."""
    lifecycle = _read("utils/server_lifecycle.gd")
    block = get_func_block(lifecycle, "func check_server_health() -> void:")
    ## Assignment forms only: the slice legitimately includes the following
    ## function's doc comment, which may mention the field by name.
    assert "_stale_recovery_budget = 0" not in block, (
        "zeroing the budget at pid-file publication strands a post-pid-file "
        "bind failure with no recovery round"
    )
    assert "_stale_recovery_budget -=" not in block


def test_repin_gate_never_shells_out_on_the_main_thread() -> None:
    """#890 review P2: the gate runs on the main thread from the dock's
    sweep-completion callback; cli-descriptor probe paths run subprocesses
    with multi-second timeouts and must fail closed instead."""
    source = _read("client_configurator.gd")
    block = get_func_block(
        source, "static func entry_drift_is_version_pin_only("
    )
    assert 'client.config_type == "cli"' in block
    assert "_scope_diverges_from_json_fallback(client)" in block
    assert "has_json_fallback()" in block


def test_plugin_arms_stale_recovery_before_the_startup_walk() -> None:
    """The marker peek + `authorize_stale_recovery()` must run BEFORE
    `_start_server()` in `_enter_tree` — arming after the walk starts would
    race the walk's incompatible arm and the WS handshake verdict."""
    source = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")
    block = get_func_block(source, "func _enter_tree() -> void:")

    assert "_pending_self_update_succeeded()" in block
    assert "_lifecycle.authorize_stale_recovery()" in block
    assert block.index("authorize_stale_recovery") < block.index("_start_server()")

    peek = get_func_block(source, "func _pending_self_update_succeeded() -> bool:")
    assert "has_setting" in peek
    assert "set_setting" not in peek, (
        "the pre-walk read must PEEK, not drain — "
        "_flush_pending_self_update_telemetry owns the read-and-clear"
    )
    assert '"success"' in peek, "only a successful install may authorize recovery"


def test_flush_notifies_dock_repin_only_on_success() -> None:
    source = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")
    block = get_func_block(
        source, "func _flush_pending_self_update_telemetry() -> void:"
    )

    assert 'status == "success"' in block
    assert 'has_method("notify_self_update_success")' in block, (
        "the dock reference must stay untyped/guarded across the update "
        "boundary (the dock script was just overwritten on disk)"
    )
    assert "notify_self_update_success(from_version)" in block, (
        "the repin gate renders entries against the replaced version — the "
        "dock cannot fire without it"
    )
    assert "_telemetry.record_self_update(status, from_version, to_version, error)" in block


def test_runner_marker_carries_from_and_to_versions() -> None:
    """The success marker must carry both versions: telemetry reports the
    transition, and the dock's pin-only repin gate cannot render the
    old-version comparison without `from_version`."""
    source = _read("update_reload_runner.gd")

    start_block = get_func_block(
        source, "func start(zip_path: String, temp_dir: String, detached_dock) -> void:"
    )
    assert "_from_version = _read_plugin_cfg_version()" in start_block, (
        "the OLD version must be read from disk before the extract replaces "
        "plugin.cfg"
    )

    finalize_block = get_func_block(source, "func _finalize_install_success() -> void:")
    assert '"from_version": _from_version' in finalize_block
    assert '"to_version": _read_plugin_cfg_version()' in finalize_block

    reader_block = get_func_block(
        source, "static func _read_plugin_cfg_version() -> String:"
    )
    assert "FileAccess.open(PLUGIN_CFG_PATH" in reader_block, (
        "the runner must read the version via pure file IO — calling into "
        "plugin scripts during the disable window is the parse-hazard class "
        "the runner exists to avoid"
    )


def test_dock_repin_is_gated_to_version_pin_only_drift() -> None:
    """Blast-radius pin (observed live during the self-update smoke: a
    fixture editor on port 18000 rewrote 21 real client configs to its own
    ports). The auto-repin may only touch entries whose SOLE drift is the
    old version pin, and the gate must fail closed without a from_version."""
    dock = _read("mcp_dock.gd")
    repin_block = get_func_block(dock, "func _maybe_auto_repin_after_update() -> void:")
    assert "_entry_drift_is_version_pin_only(" in repin_block
    assert "_on_reconfigure_mismatched()" not in repin_block, (
        "the ungated banner fan-out must not be reachable from the automatic "
        "path — it rewrites every mismatched entry, ports and all"
    )

    notify_block = get_func_block(
        dock, 'func notify_self_update_success(from_version: String = "") -> void:'
    )
    assert "is_empty()" in notify_block and "return" in notify_block, (
        "an empty from_version (pre-gate runner marker) must arm nothing"
    )

    configurator = _read("client_configurator.gd")
    gate_block = get_func_block(
        configurator,
        "static func entry_drift_is_version_pin_only(",
    )
    assert 'old_context["plugin_version"] = pinned_from' in gate_block
    assert "Client.Status.CONFIGURED" in gate_block, (
        "pin-only drift means the entry verifies EXACTLY as what Configure "
        "wrote at the old version — same ports, flags, and shape"
    )


def test_dock_repin_runs_after_summary_rebuilds_mismatch_cache() -> None:
    """`_maybe_auto_repin_after_update` consumes `_last_mismatched_ids`, so
    `_finalize_completed_refresh` must call it AFTER
    `_refresh_clients_summary()` rebuilt that cache from the sweep that just
    landed."""
    source = _read("mcp_dock.gd")
    block = get_func_block(source, "func _finalize_completed_refresh() -> void:")

    assert "_maybe_auto_repin_after_update()" in block
    assert block.index("_refresh_clients_summary()") < block.index(
        "_maybe_auto_repin_after_update()"
    )


def test_auto_triggers_spend_but_never_arm_the_stale_budget() -> None:
    """Loop-safety pin: only user actions arm. The manager's recovery flow
    (reused by the automatic handshake trigger) must not call
    `authorize_stale_recovery`, and the handshake trigger must dispatch the
    plugin wrapper with `false`."""
    lifecycle = _read("utils/server_lifecycle.gd")

    manager_recover = get_func_block(
        lifecycle, "func recover_incompatible_server() -> bool:"
    )
    assert "authorize_stale_recovery" not in manager_recover, (
        "arming inside the manager flow would let the automatic trigger "
        "re-arm itself into an unbounded kill/respawn loop"
    )

    verified = get_func_block(
        lifecycle,
        "func handle_server_version_verified(expected_version: String, version: String) -> void:",
    )
    assert "_host.recover_incompatible_server(false)" in verified
    assert "_stale_recovery_budget -= 1" in verified

    plugin = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")
    wrapper = get_func_block(
        plugin, "func recover_incompatible_server(user_initiated: bool = true) -> bool:"
    )
    assert "if user_initiated:" in wrapper
    assert "_lifecycle.authorize_stale_recovery()" in wrapper
