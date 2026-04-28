@tool
extends McpTestSuite

## Tests for McpDock's install-mode surfacing (see #144). Cannot mock the
## static McpClientConfigurator calls, so we just assert the text tracks
## whatever mode the current test environment is actually running in.

const McpDockScript = preload("res://addons/godot_ai/mcp_dock.gd")

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
	_dock._refresh_drift_banner([])
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
	## Race B regression: while `_install_update` is overwriting plugin scripts
	## on disk, every refresh-spawn path (focus-in, manual button, cooldown
	## timer, deferred initial refresh) must short-circuit. Spawning a worker
	## that walks into a half-overwritten script crashes inside
	## `GDScriptFunction::call` (confirmed by SIGABRT in
	## `VBoxContainer(McpDock)::_run_client_status_refresh_worker`).
	##
	## `_request_client_status_refresh` is the funnel for every spawn path,
	## so gating here covers focus-in (`_notification` → handler) without
	## needing a separate gate at each call site.
	_dock._self_update_in_progress = true
	var ok: bool = _dock._request_client_status_refresh(false)
	assert_false(ok, "Refresh must not spawn a worker while self-update is in progress")
	assert_eq(_dock._client_status_refresh_thread, null, "No worker thread should have been started while self-update is in progress")
	assert_false(_dock._client_status_refresh_in_flight, "In-flight flag should not flip on while self-update is in progress")
	_dock._self_update_in_progress = false


func test_drain_helper_does_not_poison_shutdown_flag() -> void:
	## `_install_update` calls `_drain_client_status_refresh_workers` to clear
	## any in-flight refresh worker before extracting plugin scripts. The
	## install can fail (e.g. zip open error) — when it does, the dock stays
	## alive and refreshes must resume on the OLD instance. So unlike
	## `_exit_tree`'s drain, the install-time drain must NOT set
	## `_client_status_refresh_shutdown_requested` (which is one-way and
	## permanently disables refreshes for the dock instance).
	_dock._drain_client_status_refresh_workers()
	assert_false(_dock._client_status_refresh_shutdown_requested, "drain must not set shutdown_requested — only _exit_tree does")


## Shared fixture for the three version-label tests. Inject a Label + Button
## + Connection onto the dock so the pure refresh logic can be exercised
## without depending on whether the test environment resolves as user mode
## or dev checkout (the user-mode Server row is what owns these handles in
## production — see `_refresh_setup_status`).
func _seed_server_row(server_ver: String) -> Connection:
	var conn := Connection.new()
	_dock._connection = conn
	_dock._setup_server_label = Label.new()
	_dock._version_restart_btn = Button.new()
	_dock._version_restart_btn.visible = false
	_dock._last_rendered_server_text = ""
	conn.server_version = server_ver
	return conn


func _cleanup_server_row(conn: Connection) -> void:
	_dock._setup_server_label.free()
	_dock._setup_server_label = null
	_dock._version_restart_btn.free()
	_dock._version_restart_btn = null
	conn.free()


func test_server_version_label_muted_when_ack_not_received() -> void:
	## Pre-ack (connection just opened, or older server that doesn't send
	## handshake_ack): show the plugin's expected version muted. Nothing to
	## flag yet and no Restart button — we don't know what's actually running.
	var conn := _seed_server_row("")
	_dock._refresh_server_version_label()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	assert_eq(_dock._setup_server_label.text, "godot-ai == %s" % plugin_ver)
	assert_false(_dock._version_restart_btn.visible, "Restart button stays hidden pre-ack")
	_cleanup_server_row(conn)


func test_server_version_label_green_when_server_matches_plugin() -> void:
	## Post-ack + match: the happy path. Green label, no Restart button.
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	var conn := _seed_server_row(plugin_ver)
	_dock._refresh_server_version_label()
	assert_eq(_dock._setup_server_label.text, "godot-ai == %s" % plugin_ver,
		"Match: label omits the '(plugin X)' suffix since there's no drift to flag")
	var color: Color = _dock._setup_server_label.get_theme_color_override("font_color")
	assert_true(color == Color.GREEN,
		"Matched version must render green, got %s" % str(color))
	assert_false(_dock._version_restart_btn.visible,
		"Restart button stays hidden when versions match")
	_cleanup_server_row(conn)


func test_server_version_label_amber_with_restart_on_mismatch() -> void:
	## The money test: the bug scenario. Plugin is v1.4.2 but connected to
	## a v1.3.3 server (common after self-update when a foreign-adopted
	## server outlives the plugin upgrade). Label must expose both versions
	## and the Restart button must surface. Regression guard — without
	## this, the dock silently masks the drift and the user has no signal.
	var conn := _seed_server_row("1.2.3-stale-for-test")
	_dock._refresh_server_version_label()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	assert_contains(_dock._setup_server_label.text, "1.2.3-stale-for-test",
		"Mismatch must show the actual server version, not the plugin's")
	assert_contains(_dock._setup_server_label.text, plugin_ver,
		"Mismatch must show the plugin version alongside so the drift is visible at a glance")
	assert_eq(
		_dock._setup_server_label.get_theme_color_override("font_color"),
		McpDockScript.COLOR_AMBER,
		"Mismatch must render amber, matching the drift banner's color"
	)
	assert_true(_dock._version_restart_btn.visible, "Restart button must surface on mismatch")
	_cleanup_server_row(conn)


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
	var body := McpDockScript._crash_body_for_state(McpSpawnState.CRASHED)
	assert_false(body.is_empty(), "CRASHED body must not be empty")
	if McpClientConfigurator.get_server_launch_mode() == "uvx":
		assert_contains(body, "PyPI", "uvx-tier body should name PyPI as the likely cause")
		assert_contains(body, "Reload Plugin", "uvx-tier body should direct the user to the retry action")
	else:
		assert_contains(body, "output log", "Non-uvx body should still point at Godot's traceback")
