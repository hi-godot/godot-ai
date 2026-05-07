@tool
extends McpTestSuite

## Tests for McpDock's install-mode surfacing (see #144). Cannot mock the
## static McpClientConfigurator calls, so we just assert the text tracks
## whatever mode the current test environment is actually running in.

const McpDockScript = preload("res://addons/godot_ai/mcp_dock.gd")
const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")
const PortPickerPanelScript = preload("res://addons/godot_ai/dock_panels/port_picker_panel.gd")
const LogViewerScript = preload("res://addons/godot_ai/dock_panels/log_viewer.gd")

## Stub for the dock's `_update_manager` slot. Tests that want to fake
## "self-update mid-install" inject one of these so the dock's
## `_is_self_update_in_progress()` gate sees an in-flight manager,
## mirroring how production code consults the seam.
class _StubInstallGate extends Node:
	var in_flight: bool = false

	func is_install_in_flight() -> bool:
		return in_flight

class _RestartDispatchPlugin extends GodotAiPlugin:
	var status: Dictionary = {}
	var can_restart := false
	var force_restart_calls := 0
	var recover_calls := 0
	var preserve_mode_calls := 0
	var has_managed := false
	var dev_running := false

	func get_server_status() -> Dictionary:
		return status.duplicate()

	func can_restart_managed_server() -> bool:
		return can_restart

	func force_restart_server() -> void:
		force_restart_calls += 1

	func recover_incompatible_server() -> bool:
		recover_calls += 1
		return true

	func has_managed_server() -> bool:
		return has_managed

	func is_dev_server_running() -> bool:
		return dev_running

	func force_restart_server_preserving_mode() -> bool:
		preserve_mode_calls += 1
		return has_managed or dev_running


var _dock: Node


func suite_name() -> String:
	return "dock"


func suite_setup(_ctx: Dictionary) -> void:
	_dock = McpDockScript.new()


func suite_teardown() -> void:
	if _dock != null:
		_dock.free()
		_dock = null


func test_install_mode_text_matches_environment() -> void:
	var text: String = _dock._install_mode_text()
	assert_true(text.begins_with("Install: "), "Expected prefix 'Install: ', got: %s" % text)
	if McpClientConfigurator.is_dev_checkout():
		assert_contains(text, "dev checkout", "Dev-checkout env should label as such")
		assert_contains(text, "git pull", "Dev-checkout text should mention git pull")
	else:
		assert_contains(text, "v%s" % McpClientConfigurator.get_plugin_version())


func test_install_mode_tooltip_is_nonempty() -> void:
	var tooltip: String = _dock._install_mode_tooltip()
	assert_false(tooltip.is_empty(), "Tooltip must not be empty")


func test_install_label_mouse_filter_allows_tooltip() -> void:
	# Label.mouse_filter defaults to IGNORE, which silently swallows hover
	# events and prevents tooltip_text from ever firing. Regression guard.
	_dock._build_ui()
	assert_eq(_dock._install_label.mouse_filter, Control.MOUSE_FILTER_STOP)


func test_drift_banner_hidden_when_no_mismatched_clients() -> void:
	## The amber banner should stay hidden until a sweep finds at least one
	## mismatched client — otherwise it'd flash up on every `_build_ui` call
	## and become noise. See #166.
	_dock._build_ui()
	assert_false(_dock._drift_banner.visible, "Banner must default to hidden")
	_dock._refresh_drift_banner([] as Array[String])
	assert_false(_dock._drift_banner.visible, "Empty mismatched list must keep banner hidden")


func test_drift_banner_surfaces_mismatched_client_names() -> void:
	## The banner leads with the affected client display names — that's the
	## only thing the user can act on. The active server URL is shown on
	## the WS:/HTTP: line above and doesn't need to repeat here.
	_dock._build_ui()
	_dock._refresh_drift_banner(["claude_code"] as Array[String])
	assert_true(_dock._drift_banner.visible, "Non-empty mismatched list must show banner")
	assert_contains(_dock._drift_label.text, "Claude Code",
		"Banner should list the display names of mismatched clients")
	assert_contains(_dock._drift_label.text, "needs",
		"Singular form for one mismatched client should read 'needs to be reconfigured'")


func test_drift_banner_no_op_when_mismatched_set_unchanged() -> void:
	## The banner caches the last mismatched set so that focus-in sweeps
	## that find the same drift don't repaint identical text. The cache
	## also powers `_on_reconfigure_mismatched`, so verifying it's
	## populated locks the contract in. See #166.
	_dock._build_ui()
	_dock._refresh_drift_banner(["claude_code"] as Array[String])
	assert_eq(_dock._last_mismatched_ids, ["claude_code"] as Array[String],
		"Cache must reflect the most recent sweep so the Reconfigure button can iterate it")
	var first_text: String = _dock._drift_label.text

	# Mutate the label out-of-band; if the second call early-returns as it
	# should, our text edit survives. If it ignores the cache and rewrites,
	# our edit is overwritten.
	_dock._drift_label.text = "SENTINEL — should survive a no-op refresh"
	_dock._refresh_drift_banner(["claude_code"] as Array[String])
	assert_eq(_dock._drift_label.text, "SENTINEL — should survive a no-op refresh",
		"Identical mismatched set must skip repaint")

	# A different set must repaint.
	_dock._refresh_drift_banner(["codex"] as Array[String])
	assert_true(_dock._drift_label.text != "SENTINEL — should survive a no-op refresh")
	assert_true(_dock._drift_label.text != first_text, "Different set must produce different text")


func test_mixed_state_banner_hidden_in_clean_addons_tree() -> void:
	## The dock builds the mixed-state banner during `_build_ui` and seeds
	## it from `UpdateMixedState.diagnose()`. In test_project's tree the
	## addons dir has no `.update_backup` files, so the banner must default
	## to hidden. Without this guard a future regression that always shows
	## the banner would only surface when a real FAILED_MIXED state landed.
	_dock._build_ui()
	assert_true(_dock._mixed_state_banner != null, "Banner must be constructed by _build_ui")
	assert_false(
		_dock._mixed_state_banner.visible,
		"Clean addons tree must keep the mixed-state banner hidden",
	)


func test_mixed_state_banner_renders_synthetic_diagnostic() -> void:
	## Drive the render seam with a fake diagnostic so the banner contract
	## (visibility + label text + file list) is pinned without polluting
	## the real `addons/godot_ai/` tree with `.update_backup` files. This
	## covers Copilot's "dock banner is untested" finding on PR #382.
	_dock._build_ui()
	var fake_diag := {
		"addon_dir": "res://addons/godot_ai/",
		"backup_files": [
			"res://addons/godot_ai/handlers/scene_handler.gd.update_backup",
			"res://addons/godot_ai/plugin.gd.update_backup",
		],
		"backup_count": 2,
		"truncated": false,
		"message": "Fake diagnostic for test_mixed_state_banner_renders_synthetic_diagnostic",
	}
	_dock._apply_mixed_state_banner_diagnostic(fake_diag)
	assert_true(_dock._mixed_state_banner.visible, "Non-empty diagnostic must show banner")
	assert_contains(
		_dock._mixed_state_label.text,
		"Fake diagnostic for test_mixed_state_banner_renders_synthetic_diagnostic",
		"Banner must surface the diagnostic message verbatim",
	)
	## RichTextLabel.text reflects the BBCode source, not the rendered
	## content added via `add_text()` — assert via `get_parsed_text()`
	## which returns the visible text concatenation.
	assert_contains(
		_dock._mixed_state_files.get_parsed_text(),
		"plugin.gd.update_backup",
		"Banner must list each backup file path so the operator can act on them",
	)


func test_mixed_state_banner_re_hides_when_diagnostic_empties() -> void:
	## The Re-scan button calls `_refresh_mixed_state_banner(true)` which
	## eventually feeds the apply seam an empty Dict when the addons tree
	## has been restored. Pin that the banner correctly hides when applied
	## with `{}` so the button delivers the dismissal it advertises.
	_dock._build_ui()
	_dock._apply_mixed_state_banner_diagnostic({
		"addon_dir": "res://addons/godot_ai/",
		"backup_files": ["res://addons/godot_ai/foo.gd.update_backup"],
		"backup_count": 1,
		"truncated": false,
		"message": "show me",
	})
	assert_true(_dock._mixed_state_banner.visible, "Precondition: banner must be visible")
	_dock._apply_mixed_state_banner_diagnostic({})
	assert_false(
		_dock._mixed_state_banner.visible,
		"Empty diagnostic must hide the banner — the Re-scan dismissal path",
	)


func test_mixed_state_banner_renders_truncated_hint() -> void:
	## When the scanner caps results, the dock must surface that the list
	## isn't exhaustive — otherwise a power user with a runaway tree thinks
	## they only have N backups when there might be more. The truncation
	## hint references the canonical MAX_BACKUP_RESULTS so the message
	## stays accurate if the cap moves.
	_dock._build_ui()
	_dock._apply_mixed_state_banner_diagnostic({
		"addon_dir": "res://addons/godot_ai/",
		"backup_files": ["res://addons/godot_ai/x.gd.update_backup"],
		"backup_count": 200,
		"truncated": true,
		"message": "lots of backups",
	})
	assert_true(_dock._mixed_state_banner.visible)
	assert_contains(
		_dock._mixed_state_files.get_parsed_text(),
		"truncated",
		"truncated=true must produce the cap-hit hint in the file list",
	)


func test_apply_row_status_renders_mismatch_as_amber_with_url_hint() -> void:
	## The row UI is the per-client mirror of the dock-level banner —
	## amber dot + "URL out of date" suffix on the name label so a
	## glance at the row identifies it as drift, not a fresh install.
	_dock._build_ui()
	var any_id := McpClientConfigurator.client_ids()[0]
	_dock._apply_row_status(any_id, McpClient.Status.CONFIGURED_MISMATCH)
	var row: Dictionary = _dock._client_rows[any_id]
	var dot: ColorRect = row["dot"]
	assert_eq(dot.color, McpDockScript.COLOR_AMBER, "Mismatch must use amber dot")
	assert_contains((row["name_label"] as Label).text, "URL out of date",
		"Mismatched row must label itself so the user reads it as drift")
	assert_eq((row["configure_btn"] as Button).text, "Reconfigure",
		"Mismatched rows offer the same Reconfigure action as the banner")


func test_incompatible_server_marks_clients_unhealthy() -> void:
	## URL-only client checks are not enough when the URL points at an old
	## server with an incompatible tool surface. The dock must not show green
	## client rows while the plugin has blocked server adoption.
	_dock._build_ui()
	var plugin := _RestartDispatchPlugin.new()
	plugin.status = {
		"state": McpServerState.INCOMPATIBLE,
		"message": "Port 8000 is occupied by godot-ai server v1.2.10; plugin expects v2.2.0.",
		"connection_blocked": true,
	}
	_dock._plugin = plugin

	var any_id := McpClientConfigurator.client_ids()[0]
	_dock._refresh_all_client_statuses()
	var row: Dictionary = _dock._client_rows[any_id]
	var dot: ColorRect = row["dot"]
	assert_eq(dot.color, Color.RED, "Blocked incompatible server must render client rows red")
	assert_contains(
		(row["name_label"] as Label).text,
		"Port 8000 is occupied by godot-ai server v1.2.10",
		"Client row must explain the live server mismatch instead of looking healthy"
	)
	plugin.free()


func test_drift_banner_clears_after_per_row_reconfigure() -> void:
	## Regression: clicking Reconfigure on a row in the Clients & Tools window
	## updates the row dot, but the dock-level drift banner used to stay stale
	## ("Claude Code needs to be reconfigured") until the next sweep. The fix
	## routes per-row mutations through `_refresh_clients_summary`, which now
	## re-derives the banner from row dots so banner, summary count, and
	## `_last_mismatched_ids` cache all stay in sync.
	_dock._build_ui()
	var any_id := McpClientConfigurator.client_ids()[0]

	# Simulate a sweep finding this client mismatched.
	_dock._apply_row_status(any_id, McpClient.Status.CONFIGURED_MISMATCH)
	_dock._refresh_clients_summary()
	assert_true(_dock._drift_banner.visible,
		"Banner must surface once a row goes amber")
	assert_eq(_dock._last_mismatched_ids, [any_id] as Array[String],
		"Reconfigure-mismatched cache must reflect the amber row")

	# Simulate the user clicking Reconfigure on that row in the full window —
	# `_on_configure_client` flips the dot to green and calls summary refresh.
	_dock._apply_row_status(any_id, McpClient.Status.CONFIGURED)
	_dock._refresh_clients_summary()
	assert_false(_dock._drift_banner.visible,
		"Banner must clear once the last amber row is reconfigured")
	assert_eq(_dock._last_mismatched_ids, [] as Array[String],
		"Cache must drop the now-green client so a follow-up Reconfigure-mismatched click is a no-op")


func test_focus_in_auto_refresh_is_enabled_with_async_cooldown() -> void:
	## Focus-in should still refresh client status, but the refresh path must be
	## async/cooldown-protected so it does not run blocking CLI checks on the
	## editor thread during OS/window refocus.
	assert_true(_dock._should_refresh_client_statuses_on_focus_in(),
		"Editor focus-in should request the async client-status refresh")
	assert_eq(McpDockScript.CLIENT_STATUS_REFRESH_COOLDOWN_MSEC, 15 * 1000,
		"Focus-in refresh cooldown is intentionally short and explicit")


func test_refresh_cooldown_helper_only_blocks_automatic_refreshes() -> void:
	_dock._last_client_status_refresh_completed_msec = Time.get_ticks_msec()
	assert_true(_dock._is_client_status_refresh_in_cooldown(),
		"Recent automatic refresh should be inside cooldown")
	_dock._last_client_status_refresh_completed_msec = 0
	assert_false(_dock._is_client_status_refresh_in_cooldown(),
		"No completed refresh means no cooldown")


func test_initial_refresh_helper_replaces_settle_timer_constant() -> void:
	## #234 shipped a `CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC` heuristic that
	## #235 replaces with a deterministic sync gate. The constant must be gone
	## — keeping it alongside the sync helper would falsely imply a residual
	## timer-based fix.
	##
	## The full structural guard ("the helper has no Thread/await/timer") lives
	## in `tests/unit/test_editor_focus_refocus.py` because GDScript can't
	## introspect its own AST. This GDScript-side test is the script-class
	## guard for the constant itself: if a future merge adds it back (e.g.
	## resurrecting #234's stopgap on top of #235), `get_script_constant_map`
	## will catch it on the next test run.
	var script: GDScript = McpDockScript
	var has_constant := false
	for entry in script.get_script_constant_map():
		if String(entry) == "CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC":
			has_constant = true
			break
	assert_false(has_constant, "CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC must be removed — #235 replaces #234's timer with a deterministic gate")


func test_exit_tree_drains_orphaned_refresh_threads() -> void:
	## Regression for the static-var orphan bug surfaced on the plugin disable
	## path (editor_reload_plugin, Project Settings toggle): the McpDock
	## script class is itself reloaded, which wipes
	## `_orphaned_client_status_refresh_threads` and GCs any Thread still in
	## it mid-execution → `~Thread … destroyed without its completion having
	## been realized` plus GDScript VM corruption (Opcode: 0, IP-bounds
	## errors, intermittent SIGSEGV). `_exit_tree` must drain the orphan list
	## synchronously before returning, so no GDScript work straddles the
	## script-class reload boundary.
	var t := Thread.new()
	var err := t.start(func() -> int: return 42)
	assert_eq(err, OK, "Test fixture failed to start thread")
	McpDockScript._orphaned_client_status_refresh_threads.append(t)
	_dock._exit_tree()
	assert_true(McpDockScript._orphaned_client_status_refresh_threads.is_empty(),
		"_exit_tree must clear the orphan list synchronously after waiting on each thread")


func test_self_update_in_progress_blocks_request_refresh() -> void:
	## Race B regression: while `McpUpdateManager._install_zip` is overwriting
	## plugin scripts on disk, every refresh-spawn path (focus-in, manual
	## button, cooldown timer, deferred initial refresh) must short-circuit.
	## Spawning a worker that walks into a half-overwritten script crashes
	## inside `GDScriptFunction::call` (confirmed by SIGABRT in
	## `VBoxContainer(McpDock)::_run_client_status_refresh_worker`).
	##
	## `_request_client_status_refresh` is the funnel for every spawn path,
	## so gating here covers focus-in (`_notification` → handler) without
	## needing a separate gate at each call site. The seam is
	## `_dock._update_manager.is_install_in_flight()`; inject a stub
	## manager so `_is_self_update_in_progress()` resolves to true.
	var stub := _StubInstallGate.new()
	stub.in_flight = true
	_dock._update_manager = stub
	var ok: bool = _dock._request_client_status_refresh(false)
	assert_false(ok, "Refresh must not spawn a worker while self-update is in progress")
	assert_eq(_dock._client_status_refresh_thread, null, "No worker thread should have been started while self-update is in progress")
	stub.in_flight = false
	_dock._update_manager = null
	stub.free()


func test_drain_helper_does_not_poison_shutdown_flag() -> void:
	## `McpUpdateManager._install_zip` calls `_drain_client_status_refresh_workers`
	## (via `_drain_dock_workers`) to clear any in-flight refresh worker
	## before extracting plugin scripts. The install can fail (e.g. zip
	## open error) — when it does, the dock stays alive and refreshes must
	## resume on the OLD instance. So unlike `_exit_tree`'s drain, the
	## install-time drain must NOT advance `_refresh_state` to SHUTTING_DOWN
	## (which is sticky and permanently disables refreshes for the dock
	## instance). The drain leaves SHUTTING_DOWN intact when `_exit_tree`
	## already set it, but otherwise resets to IDLE.
	_dock._drain_client_status_refresh_workers()
	assert_eq(
		_dock._refresh_state,
		McpClientRefreshState.IDLE,
		"drain must collapse to IDLE when not already shutting down — only _exit_tree sets SHUTTING_DOWN"
	)


## Shared fixture for the three version-label tests. Inject a Label + Button
## + McpConnection onto the dock so the pure refresh logic can be exercised
## without depending on whether the test environment resolves as user mode
## or dev checkout (the user-mode Server row is what owns these handles in
## production — see `_refresh_setup_status`).
func _seed_server_row(server_ver: String) -> McpConnection:
	_dock._plugin = null
	_dock._server_restart_in_progress = false
	_dock._crash_restart_btn = null
	var conn := McpConnection.new()
	_dock._connection = conn
	_dock._setup_server_label = Label.new()
	_dock._version_restart_btn = Button.new()
	_dock._version_restart_btn.visible = false
	_dock._last_rendered_server_text = ""
	conn.server_version = server_ver
	return conn


func _cleanup_server_row(conn: McpConnection) -> void:
	_dock._setup_server_label.free()
	_dock._setup_server_label = null
	_dock._version_restart_btn.free()
	_dock._version_restart_btn = null
	conn.free()


func test_server_version_label_muted_when_ack_not_received() -> void:
	## Pre-ack: show the expected version only as an unverified target.
	## The row must not state "godot-ai == <plugin>" as a fact until the
	## live server has reported that exact version.
	var conn := _seed_server_row("")
	_dock._refresh_server_version_label()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	assert_eq(
		_dock._setup_server_label.text,
		"checking live version (expected godot-ai == %s)" % plugin_ver
	)
	assert_false(_dock._version_restart_btn.visible, "Restart button stays hidden pre-ack")
	_cleanup_server_row(conn)


func test_server_version_label_green_when_server_matches_plugin() -> void:
	## Post-ack + match: the happy path. Green label, no Restart button.
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	var conn := _seed_server_row(plugin_ver)
	_dock._refresh_server_version_label()
	assert_eq(_dock._setup_server_label.text, "godot-ai == %s" % plugin_ver,
		"Match: label omits the '(plugin X)' suffix since there's no drift to flag")
	assert_true(_dock._setup_server_label.has_theme_color_override("font_color"))
	var color: Color = _dock._setup_server_label.get_theme_color("font_color")
	assert_true(color == Color.GREEN,
		"Matched version must render green, got %s" % str(color))
	assert_false(_dock._version_restart_btn.visible,
		"Restart button stays hidden when versions match")
	_cleanup_server_row(conn)


func test_server_version_label_amber_without_restart_when_ownership_unproven() -> void:
	## The money test: the bug scenario. Plugin is v1.4.2 but connected to
	## a v1.3.3 server (common after self-update when a foreign-adopted
	## server outlives the plugin upgrade). Label must expose both versions.
	## The Restart button stays hidden without plugin-provided ownership proof
	## so the dock does not offer to kill an arbitrary foreign process.
	var conn := _seed_server_row("1.2.3-stale-for-test")
	_dock._refresh_server_version_label()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	assert_contains(_dock._setup_server_label.text, "1.2.3-stale-for-test",
		"Mismatch must show the actual server version, not the plugin's")
	assert_contains(_dock._setup_server_label.text, plugin_ver,
		"Mismatch must show the plugin version alongside so the drift is visible at a glance")
	assert_true(_dock._setup_server_label.has_theme_color_override("font_color"))
	assert_eq(
		_dock._setup_server_label.get_theme_color("font_color"),
		McpDockScript.COLOR_AMBER,
		"Mismatch must render amber, matching the drift banner's color"
	)
	assert_false(_dock._version_restart_btn.visible, "Restart button requires ownership proof")
	_cleanup_server_row(conn)


func test_server_version_label_repaints_color_when_state_changes_without_text_change() -> void:
	## The label text for "server vX, expected vY" is identical before and
	## after the plugin marks the server incompatible; the color must still
	## repaint from amber to red so the blocked state is visible.
	var conn := _seed_server_row("1.2.3-stale-for-test")
	var plugin := GodotAiPlugin.new()
	plugin._lifecycle._server_actual_version = "1.2.3-stale-for-test"
	plugin._lifecycle._server_expected_version = "2.2.0"
	plugin._lifecycle._server_state = McpServerState.READY
	_dock._plugin = plugin

	_dock._refresh_server_version_label()
	assert_eq(
		_dock._setup_server_label.get_theme_color("font_color"),
		McpDockScript.COLOR_AMBER,
		"precondition: mismatch starts amber while not blocked"
	)

	plugin._lifecycle._server_state = McpServerState.INCOMPATIBLE
	_dock._refresh_server_version_label()
	assert_eq(
		_dock._setup_server_label.get_theme_color("font_color"),
		Color.RED,
		"same label text must repaint red when state becomes incompatible"
	)
	assert_false(_dock._version_restart_btn.visible, "incompatible state must hide Restart")

	_dock._plugin = null
	plugin.free()
	_cleanup_server_row(conn)


func test_server_version_label_shows_restart_for_recoverable_incompatible_server() -> void:
	var conn := _seed_server_row("1.2.3-stale-for-test")
	var plugin := _RestartDispatchPlugin.new()
	plugin.status = {
		"state": McpServerState.INCOMPATIBLE,
		"actual_version": "1.2.3-stale-for-test",
		"expected_version": "2.2.0",
		"can_recover_incompatible": true,
	}
	_dock._plugin = plugin

	_dock._refresh_server_version_label()
	assert_true(
		_dock._version_restart_btn.visible,
		"recoverable incompatible godot-ai server should offer the user-confirmed restart"
	)

	_dock._plugin = null
	plugin.free()
	_cleanup_server_row(conn)


func test_restart_dispatches_incompatible_state_to_recovery() -> void:
	var plugin := _RestartDispatchPlugin.new()
	plugin.status = {"state": McpServerState.INCOMPATIBLE}
	_dock._plugin = plugin

	_dock._on_restart_stale_server()
	var recover_calls := plugin.recover_calls
	var restart_calls := plugin.force_restart_calls
	_dock._plugin = null
	plugin.free()

	assert_eq(recover_calls, 1)
	assert_eq(restart_calls, 0)


func test_restart_dispatches_non_incompatible_state_to_force_restart() -> void:
	var plugin := _RestartDispatchPlugin.new()
	plugin.status = {"state": McpServerState.READY}
	_dock._plugin = plugin

	_dock._on_restart_stale_server()
	var recover_calls := plugin.recover_calls
	var restart_calls := plugin.force_restart_calls
	_dock._plugin = null
	plugin.free()

	assert_eq(recover_calls, 0)
	assert_eq(restart_calls, 1)


func test_dev_checkout_tooltip_exposes_symlink_target() -> void:
	if not McpClientConfigurator.is_dev_checkout():
		skip("only meaningful in dev checkout")
		return
	var target: String = _dock._resolve_plugin_symlink_target()
	if target.is_empty():
		# e.g. developer without a symlink (flat checkout inside test_project);
		# tooltip must still be readable.
		var tooltip: String = _dock._install_mode_tooltip()
		assert_contains(tooltip, "Reload Plugin")
		return
	assert_true(target.is_absolute_path(), "Resolved symlink target must be absolute: %s" % target)
	assert_contains(target, "godot_ai", "Symlink should point at a godot_ai plugin tree: %s" % target)
	var tooltip: String = _dock._install_mode_tooltip()
	assert_contains(tooltip, target, "Tooltip should embed the resolved target path")


func test_crashed_body_mentions_pypi_propagation_on_uvx_tier() -> void:
	## When both spawn attempts fail on the uvx tier, the dock panel should
	## explain that PyPI propagation is the likely cause — so the user
	## doesn't assume their install is corrupt. Non-uvx tiers keep the
	## original traceback hint. See #172.
	var body := McpDockScript._crash_body_for_state(McpServerState.CRASHED)
	assert_false(body.is_empty(), "CRASHED body must not be empty")
	if McpClientConfigurator.get_server_launch_mode() == "uvx":
		assert_contains(body, "PyPI", "uvx-tier body should name PyPI as the likely cause")
		assert_contains(body, "Reload Plugin", "uvx-tier body should direct the user to the retry action")
	else:
		assert_contains(body, "output log", "Non-uvx body should still point at Godot's traceback")


# --- Configure / Remove run off-thread (issue #239) ----------------------

func _first_client_id() -> String:
	var ids := McpClientConfigurator.client_ids()
	if ids.is_empty():
		return ""
	return ids[0]


func test_set_row_action_in_flight_disables_both_buttons_and_marks_amber() -> void:
	## Issue #239 surface: clicking Configure on a CLI client used to
	## block main on `OS.execute`. The new flow dispatches to a worker;
	## while the worker is in flight the row must look "busy" so the
	## user doesn't assume nothing happened and click again. The verb
	## lands on the button the user clicked — not the name label —
	## otherwise a long row error message would compete with the badge
	## for the same horizontal space.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._set_row_action_in_flight(any_id, "configure")
	var row: Dictionary = _dock._client_rows[any_id]
	assert_true((row["configure_btn"] as Button).disabled,
		"Configure button must be disabled while worker is in flight")
	assert_true((row["remove_btn"] as Button).disabled,
		"Remove button must also be disabled — a click during in-flight could queue stale work")
	assert_eq((row["dot"] as ColorRect).color, McpDockScript.COLOR_AMBER,
		"Dot turns amber so the row reads as 'busy', not green/red")
	assert_contains((row["configure_btn"] as Button).text, "Configuring",
		"Configure-in-flight verb must land on the configure button itself")


func test_set_row_action_in_flight_uses_removing_label_for_remove_action() -> void:
	## The verb must track the action — Configuring/Removing — otherwise a
	## Remove click silently shows "Configuring…" and the user thinks they
	## hit the wrong button. We also verify the configure button's text
	## stays untouched so the two states don't overlap.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._set_row_action_in_flight(any_id, "remove")
	var row: Dictionary = _dock._client_rows[any_id]
	assert_contains((row["remove_btn"] as Button).text, "Removing",
		"Remove action must show 'Removing…' on the remove button itself")
	assert_false(str((row["configure_btn"] as Button).text).contains("Removing"),
		"Configure button must not be tagged with the Remove verb")


func test_finalize_action_buttons_reenables_after_in_flight() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._set_row_action_in_flight(any_id, "configure")
	_dock._finalize_action_buttons(any_id)
	var row: Dictionary = _dock._client_rows[any_id]
	assert_false((row["configure_btn"] as Button).disabled,
		"Configure button must re-enable after the worker resolves")
	assert_false((row["remove_btn"] as Button).disabled,
		"Remove button must re-enable too")


func test_dispatch_client_action_short_circuits_during_self_update() -> void:
	## Same gate the refresh worker honors: while
	## `McpUpdateManager._install_zip` is overwriting plugin scripts on
	## disk, spawning a worker that walks into `_cli_strategy.gd` mid-
	## bytecode-swap SIGABRTs the editor. The flag lives on the manager;
	## `_is_self_update_in_progress()` consults it.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	## `_build_ui` already set up a real manager. Swap it out for the
	## test stub so we can flip the gate without driving a real download.
	var prior_manager = _dock._update_manager
	var stub := _StubInstallGate.new()
	stub.in_flight = true
	_dock._update_manager = stub
	_dock._dispatch_client_action(any_id, "configure")
	assert_false(_dock._client_action_threads.has(any_id),
		"No worker thread must be created while self-update is in progress")
	_dock._update_manager = prior_manager
	stub.free()


func test_dispatch_client_action_noop_when_slot_already_in_flight() -> void:
	## Double-click guard: a second click while the first worker is still
	## running must not start a second thread on the same row. Without
	## this, the row's button/label state would race between the two
	## workers' deferred callbacks.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	## Plant a sentinel in the slot so the dispatch sees it as in-flight
	## without us having to actually spawn (and then drain) a real
	## subprocess. Cleared in teardown so we don't leak the entry.
	var sentinel := Thread.new()
	_dock._client_action_threads[any_id] = sentinel
	_dock._dispatch_client_action(any_id, "configure")
	assert_eq(_dock._client_action_threads[any_id], sentinel,
		"Dispatch must leave the existing slot untouched while in flight")
	_dock._client_action_threads.erase(any_id)


func test_apply_status_refresh_results_skips_rows_with_in_flight_action() -> void:
	## Race scenario: user clicks Configure (worker thread starts), then
	## focus-out/focus-in fires while the worker is still running. The
	## refresh worker returns a stale "NOT_CONFIGURED" snapshot; if we
	## let it through, the in-flight "Configuring…" badge gets clobbered.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._set_row_action_in_flight(any_id, "configure")
	_dock._client_action_threads[any_id] = Thread.new()
	_dock._client_status_refresh_generation = 1
	var results := {
		any_id: {
			"status": McpClient.Status.NOT_CONFIGURED,
			"installed": true,
			"error_msg": "",
		}
	}
	_dock._apply_client_status_refresh_results(results, 1)
	var row: Dictionary = _dock._client_rows[any_id]
	assert_contains((row["configure_btn"] as Button).text, "Configuring",
		"In-flight Configuring badge on the button must survive a concurrent refresh result")
	assert_eq((row["dot"] as ColorRect).color, McpDockScript.COLOR_AMBER,
		"Dot must stay amber while the action worker hasn't completed")
	_dock._client_action_threads.erase(any_id)


func test_drain_client_action_workers_clears_threads_and_bumps_generation() -> void:
	## `McpUpdateManager._install_zip` calls this drain (via
	## `_drain_dock_workers`) before extracting the release zip, same
	## reason as the refresh worker drain — a worker mid-call into a
	## half-overwritten script SIGABRTs the editor. The drain bumps
	## generation per-row so any pending `call_deferred(
	## "_apply_client_action_result")` from a worker that finished after
	## the drain detects the mismatch and short-circuits before touching
	## restored UI state.
	_dock._client_action_threads["sentinel-id"] = null
	_dock._client_action_generations["sentinel-id"] = 7
	_dock._drain_client_action_workers()
	assert_true(_dock._client_action_threads.is_empty(),
		"Drain must empty the action-thread map so a follow-up dispatch starts fresh")
	assert_eq(int(_dock._client_action_generations.get("sentinel-id", 0)), 8,
		"Drain must bump generation so any late call_deferred from the drained worker is rejected as stale")


func test_drain_client_action_workers_restores_in_flight_row_buttons() -> void:
	## Issue #239 follow-up: `McpUpdateManager._install_zip` has a bail-out
	## branch (zip extract failure) that clears `_install_in_flight` on the
	## manager and leaves the dock alive. Without restoring the row UI in
	## the drain, an in-flight Configure / Remove would leave the buttons
	## disabled and the active button stuck on "Configuring…" / "Removing…"
	## forever because `_apply_client_action_result` never runs after we erase
	## the thread slot.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._set_row_action_in_flight(any_id, "configure")
	_dock._client_action_threads[any_id] = null
	_dock._drain_client_action_workers()
	var row: Dictionary = _dock._client_rows[any_id]
	assert_false((row["configure_btn"] as Button).disabled,
		"Drain must re-enable the configure button so the user can retry")
	assert_false((row["remove_btn"] as Button).disabled,
		"Drain must re-enable the remove button too")
	assert_false(str((row["configure_btn"] as Button).text).contains("Configuring"),
		"Drain must clear the in-flight badge from the configure button")


func test_incompatible_server_body_uses_actionable_message() -> void:
	var body := McpDockScript._crash_body_for_state(
		McpServerState.INCOMPATIBLE,
		{"message": "Port 8000 is occupied by godot-ai server v1.2.10; plugin expects v2.2.0. Stop the old server or change both HTTP and WS ports."},
	)
	assert_contains(body, "godot-ai server v1.2.10")
	assert_contains(body, "plugin expects v2.2.0")
	assert_contains(body, "change both HTTP and WS ports")


func test_incompatible_server_hides_http_only_port_picker() -> void:
	## Incompatible godot-ai servers commonly hold both HTTP and WS ports.
	## The quick picker only changes HTTP, so showing it here advertises a
	## partial recovery path that can leave the editor disconnected.
	_dock._build_ui()
	_dock._update_crash_panel({
		"state": McpServerState.INCOMPATIBLE,
		"message": "Port 8000 is occupied by godot-ai server v1.2.10",
	})
	assert_true(_dock._crash_panel.visible, "diagnostic panel still shows")
	assert_false(_dock._port_picker_panel.visible, "HTTP-only picker must stay hidden")


# --- Signal-emit contracts on the audit-v2 #360 extracted subpanels ---
# These pin the new panel boundary: panels emit; dock owns side effects.

## Spies for the two panels' signals. Inner-class pattern matches the
## `_RestartDispatchPlugin` spy at the top of this file — multi-line
## lambdas with closure-captured locals don't reliably evaluate the body
## under the test runner, so a typed receiver is the safe form.
class _PortApplySpy:
	var captured: Array[int] = []
	func on_apply(new_port: int) -> void:
		captured.append(new_port)


class _LogToggleSpy:
	var captured: Array[bool] = []
	func on_toggle(enabled: bool) -> void:
		captured.append(enabled)


func test_port_picker_panel_emits_apply_requested_for_in_range_port() -> void:
	## The panel is the gatekeeper for `EditorInterface.set_setting` — invalid
	## ports must never reach the dock's handler. In-range values must.
	## Instantiate the panel in isolation: going through the dock's wiring
	## would fire the connected `_on_port_apply_requested` handler, which
	## reloads the plugin (`set_plugin_enabled(false/true)`) and tears down
	## the test runner mid-suite.
	var panel := PortPickerPanelScript.new()
	panel.setup()
	var spy := _PortApplySpy.new()
	panel.port_apply_requested.connect(spy.on_apply)
	panel._spinbox.value = 9000
	panel._on_apply_pressed()
	assert_eq(spy.captured.size(), 1, "in-range port must emit exactly once")
	assert_eq(spy.captured[0], 9000, "emitted port must match the spinbox value")
	panel.free()


func test_port_picker_panel_skips_emit_for_out_of_range_port() -> void:
	## SpinBox.value is clamped by min_value/max_value at the UI layer,
	## but the panel re-validates before emitting because programmatic
	## sets (or future re-bindings) can bypass the clamp. The dock relies
	## on this guard, so pin it. Same isolation rationale as the test above.
	var panel := PortPickerPanelScript.new()
	panel.setup()
	var spy := _PortApplySpy.new()
	panel.port_apply_requested.connect(spy.on_apply)
	## Bypass the SpinBox clamp by writing the raw `value` field after
	## relaxing min_value — covers a future regression where the panel's
	## clamp is the only line of defense (e.g. someone replaces SpinBox
	## with a free-form input).
	panel._spinbox.min_value = 0
	panel._spinbox.value = 0
	panel._on_apply_pressed()
	assert_eq(spy.captured.size(), 0, "out-of-range port must not emit")
	panel.free()


func test_log_viewer_emits_logging_enabled_changed_on_toggle() -> void:
	## The dock routes this signal to `_connection.dispatcher.mcp_logging`.
	## If LogViewer stops emitting, MCP request/response logging silently
	## stays whatever it was — easy to regress, hard to spot.
	## Instantiate in isolation to keep the test focused on the panel's
	## emit contract (and consistent with the port-picker tests above).
	var panel := LogViewerScript.new()
	panel.setup(null)  # buffer not exercised — only signal emission is under test
	var spy := _LogToggleSpy.new()
	panel.logging_enabled_changed.connect(spy.on_toggle)
	panel._on_log_toggled(false)
	panel._on_log_toggled(true)
	assert_eq(spy.captured, [false, true] as Array[bool],
		"toggle must emit each state change exactly once, in order")
	panel.free()


func test_log_viewer_tick_recovers_from_buffer_clear() -> void:
	## Regression: McpLogBuffer.clear() resets the monotonic
	## `total_logged()` counter to 0, flipping the sequence backward. The
	## viewer must detect that flip and clear its display — without the
	## shrink branch, tick() would compute `get_recent(seq - _last_log_seq)`
	## with a negative argument, append nothing, and the display would stay
	## stuck on pre-clear lines forever (out of sync with the empty buffer).
	var buffer := McpLogBuffer.new()
	buffer.log("before clear 1")
	buffer.log("before clear 2")
	var panel := LogViewerScript.new()
	panel.setup(buffer)
	panel.tick()
	## Display contract: at least the two pre-clear lines are visible. Use
	## get_parsed_text() because RichTextLabel.text reflects BBCode source,
	## not what add_text() renders.
	assert_contains(panel._log_display.get_parsed_text(), "before clear 1",
		"precondition: pre-clear lines must paint into the display")
	assert_contains(panel._log_display.get_parsed_text(), "before clear 2")
	assert_eq(panel._last_log_seq, 2,
		"precondition: cursor must track total_logged() after tick()")

	## The bug: buffer is cleared while the panel is still showing the
	## pre-clear lines. Without the shrink-recovery branch, tick() computes
	## get_recent(-2), appends nothing, and the display stays stale forever.
	buffer.clear()
	panel.tick()
	assert_eq(panel._log_display.get_parsed_text(), "",
		"display must clear when total_logged() drops below _last_log_seq")
	assert_eq(panel._last_log_seq, 0,
		"cursor must reset to 0 after a buffer shrink so subsequent ticks paint from a clean slate")

	## After the recovery branch, new lines must paint normally — i.e. the
	## next round of appends through the same panel doesn't lose lines or
	## duplicate them.
	buffer.log("after clear 1")
	buffer.log("after clear 2")
	panel.tick()
	assert_contains(panel._log_display.get_parsed_text(), "after clear 1")
	assert_contains(panel._log_display.get_parsed_text(), "after clear 2")
	assert_false(panel._log_display.get_parsed_text().contains("before clear"),
		"pre-clear lines must not reappear after the recovery + re-paint")
	assert_eq(panel._last_log_seq, 2)
	panel.free()


func test_log_viewer_tick_keeps_painting_after_buffer_caps_at_max_lines() -> void:
	## Regression: McpLogBuffer caps `_lines` at MAX_LINES (500) by slicing.
	## Once full, subsequent log() calls keep `_lines.size()` constant. The
	## previous viewer tracked `total_count()` as its cursor — so once the
	## buffer hit the cap, `count == _last_log_count` returned early on
	## every tick and new lines never reached the display. After ~500 MCP
	## events the dev-mode log just appeared to stop, with no error and no
	## indication that anything had filled. The fix tracks the buffer's
	## monotonic `total_logged()` instead, which keeps incrementing past
	## MAX_LINES.
	var buffer := McpLogBuffer.new()
	var cap: int = McpLogBuffer.MAX_LINES
	for i in range(cap):
		buffer.log("filler %d" % i)
	var panel := LogViewerScript.new()
	panel.setup(buffer)
	panel.tick()
	assert_eq(buffer.total_count(), cap,
		"precondition: buffer must be at capacity after %d logs" % cap)
	assert_eq(buffer.total_logged(), cap,
		"precondition: total_logged() should equal cap on first fill")
	assert_eq(panel._last_log_seq, cap,
		"precondition: viewer cursor tracks total_logged() after the priming tick")

	## At-cap append: total_count stays pinned at cap, but total_logged advances
	## to cap+1. Before the fix the viewer's `count == _last_log_count` early-
	## return swallowed this line silently.
	buffer.log("at-cap canary")
	panel.tick()
	assert_eq(buffer.total_count(), cap, "buffer size stays pinned at cap")
	assert_eq(buffer.total_logged(), cap + 1, "monotonic counter advances past cap")
	assert_contains(panel._log_display.get_parsed_text(), "at-cap canary",
		"new line after the buffer capped must reach the display")
	assert_eq(panel._last_log_seq, cap + 1,
		"viewer cursor must advance with the monotonic counter, not the bounded size")
	panel.free()


# --- Restart Server button (dev-mode) -----------------------------------

func test_restart_server_btn_rendered_in_dev_checkout() -> void:
	## The button only makes sense for contributors editing Python source —
	## live in the Setup section's dev branch alongside `_dev_server_btn`.
	## In a non-dev checkout (release install) the branch isn't entered and
	## the button must not appear; we skip rather than fake the env.
	if not McpClientConfigurator.is_dev_checkout():
		skip("only meaningful in dev checkout")
		return
	_dock._build_ui()
	_dock._refresh_setup_status()
	assert_true(_dock._dev_restart_btn != null,
		"Dev checkout must render the Restart Server button in the Setup section")
	assert_eq(_dock._dev_restart_btn.text, "Restart Server")


func test_restart_server_btn_visibility_follows_dev_mode_toggle() -> void:
	## The button lives inside `_setup_section`, whose visibility is driven
	## by `_apply_dev_mode_visibility`. With Developer mode off in a dev
	## checkout the section hides — taking the button with it — which is the
	## "ON + dev checkout" gate the task requires.
	if not McpClientConfigurator.is_dev_checkout():
		skip("only meaningful in dev checkout")
		return
	_dock._build_ui()
	_dock._dev_mode_toggle.button_pressed = true
	_dock._apply_dev_mode_visibility()
	_dock._refresh_setup_status()
	assert_true(_dock._setup_section.visible,
		"precondition: dev toggle on must show the Setup section")
	assert_true(_dock._dev_restart_btn != null,
		"Restart Server button must be in the Setup section when dev toggle is on")

	_dock._dev_mode_toggle.button_pressed = false
	_dock._apply_dev_mode_visibility()
	## In dev checkout with toggle off, the section hides but its children
	## (including the button) remain in the tree — the gate is the section's
	## visibility, not whether the button was constructed.
	assert_false(_dock._setup_section.visible,
		"dev toggle off must hide the Setup section, hiding the Restart Server button")


## Mirrors `_seed_server_row` / `_cleanup_server_row`: stand up just enough
## of the dock for the per-frame restart-button helpers to run without a
## full `_build_ui` pass.
func _seed_dev_restart_btn(plugin: _RestartDispatchPlugin) -> void:
	_dock._plugin = plugin
	_dock._dev_restart_btn = Button.new()


func _cleanup_dev_restart_btn(plugin: _RestartDispatchPlugin) -> void:
	_dock._dev_restart_btn.free()
	_dock._dev_restart_btn = null
	_dock._plugin = null
	plugin.free()


func test_restart_server_btn_dispatches_to_force_restart_preserving_mode() -> void:
	var plugin := _RestartDispatchPlugin.new()
	plugin.has_managed = true
	_seed_dev_restart_btn(plugin)

	_dock._on_dev_restart_pressed()
	var calls: int = plugin.preserve_mode_calls

	_cleanup_dev_restart_btn(plugin)
	assert_eq(calls, 1,
		"Click must call force_restart_server_preserving_mode exactly once")


func test_restart_server_btn_disabled_when_nothing_running() -> void:
	var plugin := _RestartDispatchPlugin.new()
	_seed_dev_restart_btn(plugin)

	_dock._update_dev_restart_btn()
	var disabled: bool = _dock._dev_restart_btn.disabled
	var tooltip: String = _dock._dev_restart_btn.tooltip_text

	_cleanup_dev_restart_btn(plugin)
	assert_true(disabled, "No server running must disable the button")
	assert_contains(tooltip, "No godot-ai server is running")


func test_restart_server_btn_enabled_when_managed_running() -> void:
	var plugin := _RestartDispatchPlugin.new()
	plugin.has_managed = true
	_seed_dev_restart_btn(plugin)

	_dock._update_dev_restart_btn()
	var disabled: bool = _dock._dev_restart_btn.disabled
	var tooltip: String = _dock._dev_restart_btn.tooltip_text

	_cleanup_dev_restart_btn(plugin)
	assert_false(disabled, "Managed server running must enable the button")
	assert_contains(tooltip, "current source",
		"Tooltip must explain the button picks up source changes")
