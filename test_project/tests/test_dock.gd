@tool
extends McpTestSuite

## Tests for McpDock's install-mode surfacing (see #144). Cannot mock the
## static McpClientConfigurator calls, so we just assert the text tracks
## whatever mode the current test environment is actually running in.

const McpDockScript = preload("res://addons/godot_ai/mcp_dock.gd")
const ClientJobOwnerScript = preload("res://addons/godot_ai/utils/client_job_owner.gd")
const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")
const PortPickerPanelScript = preload("res://addons/godot_ai/dock_panels/port_picker_panel.gd")
const LogViewerScript = preload("res://addons/godot_ai/dock_panels/log_viewer.gd")

class _IntentRecorder:
	var force_restart_calls := 0
	var recover_calls := 0
	var primary_calls := 0
	var stop_calls := 0

	func on_lifecycle_action(action: int) -> void:
		if action == McpDockScript.LifecycleAction.RECOVER_INCOMPATIBLE:
			recover_calls += 1
		elif action == McpDockScript.LifecycleAction.RESTART_SERVER:
			force_restart_calls += 1

	func on_dev_server_action(action: int) -> void:
		if action == McpDockScript.DevServerAction.START_OR_RESTART:
			primary_calls += 1
		elif action == McpDockScript.DevServerAction.STOP:
			stop_calls += 1


class _RefreshCountingOwner extends ClientJobOwnerScript:
	var refresh_requests := 0

	func request_status_refresh(_ids: Array[String], _force := false) -> bool:
		refresh_requests += 1
		return false


static func _finished_thread_noop() -> void:
	pass


static func _finished_thread_payload(payload: Dictionary) -> Dictionary:
	return payload


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


func test_clients_header_and_actions_use_narrow_layout() -> void:
	## The dock's minimum width is the max of the direct VBox children. Keep
	## the Clients section split so the header/count and action buttons do not
	## add their minimum widths into one wide HBox row.
	_dock._build_ui()
	var clients_header_row := _dock._clients_summary_label.get_parent() as HBoxContainer
	assert_true(clients_header_row != null, "Clients header row should exist")
	var has_clients_header := false
	for row_child in clients_header_row.get_children():
		if row_child is Label:
			var label := row_child as Label
			if label.text == "Clients":
				has_clients_header = true
				break
	assert_true(has_clients_header, "Summary count should stay with the Clients header")
	assert_true(_dock._clients_summary_label.clip_text,
		"Summary count should ellipsize instead of expanding the dock")
	assert_eq(
		_dock._clients_summary_label.text_overrun_behavior,
		TextServer.OVERRUN_TRIM_ELLIPSIS,
		"Summary count should use ellipsis overrun")

	var body := clients_header_row.get_parent() as VBoxContainer
	assert_true(body != null,
		"Dock body should own regular rows while status/install stay pinned")
	assert_eq(body.name, "DockBody",
		"Clients header row should live inside the scrollable dock body")
	var body_scroll := body.get_parent() as ScrollContainer
	assert_true(body_scroll != null,
		"Scrollable body should keep lower dock rows from forcing minimum height")
	assert_eq(body_scroll.horizontal_scroll_mode, ScrollContainer.SCROLL_MODE_DISABLED,
		"Dock body should wrap horizontally instead of showing a sideways scrollbar")

	var header_idx := body.get_children().find(clients_header_row)
	assert_gt(header_idx, -1, "Clients header row should be a scroll-body child")
	assert_true(header_idx + 1 < body.get_child_count(),
		"Clients actions row should follow the header row")
	var clients_actions := body.get_child(header_idx + 1)
	assert_true(clients_actions is HFlowContainer,
		"Client actions should wrap in an HFlowContainer")
	var actions_flow := clients_actions as HFlowContainer
	var button_texts: Array[String] = []
	for action_child in actions_flow.get_children():
		var button := action_child as Button
		if button != null:
			button_texts.append(button.text)
	var expected: Array[String] = ["Refresh", "Clients & Tools"]
	assert_eq(button_texts, expected,
		"Client action buttons should stay compact and keep their handlers")
	assert_eq(_dock._clients_window.title, "Godot AI Settings",
		"Clients & Tools window should title the settings surface with product context")
	var tabs := _dock._clients_window.get_child(0) as TabContainer
	assert_true(tabs != null, "Clients & Tools window should contain a tab container")
	assert_eq(tabs.get_tab_title(0), "Clients")
	assert_eq(tabs.get_tab_title(1), "Tools")


func test_connected_status_stays_compact_across_client_readiness() -> void:
	_dock._build_ui()
	_dock.present_transport_snapshot({"connected": true, "status": {"phase": "connected"}})
	_dock.present_client_work_snapshot({"refresh_completed": false})

	_dock._refresh_clients_summary()
	assert_eq(
		_dock._status_label.text,
		"Server connected",
		"Connected status should stay compact before the initial status sweep completes",
	)

	_dock.present_client_work_snapshot({"refresh_completed": true})
	_dock._refresh_clients_summary()
	assert_eq(
		_dock._status_label.text,
		"Server connected",
		"Connected status should stay compact when no AI clients are configured",
	)

	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._apply_row_status(any_id, McpClient.Status.CONFIGURED)
	_dock._refresh_clients_summary()
	assert_eq(
		_dock._status_label.text,
		"Server connected",
		"Connected status should stay compact once setup has started",
	)

	var ids := McpClientConfigurator.client_ids()
	if ids.size() < 2:
		skip("Need at least two clients registered")
		return
	_dock._apply_row_status(ids[1], McpClient.Status.CONFIGURED)
	_dock._refresh_clients_summary()
	assert_eq(
		_dock._status_label.text,
		"Server connected",
		"Connected status should stay compact with multiple configured AI clients",
	)


func test_transport_status_text_distinguishes_each_reconnect_phase() -> void:
	assert_eq(
		McpDockScript._transport_status_text({"phase": "connecting", "attempt": 3}),
		"Connecting — attempt 3",
	)
	assert_eq(
		McpDockScript._transport_status_text(
			{"phase": "retrying", "attempt": 4, "retry_in_sec": 2.1}
		),
		"Retrying in 3s — attempt 4",
	)
	assert_eq(
		McpDockScript._transport_status_text({"phase": "closing", "attempt": 4}),
		"Disconnecting…",
	)
	assert_eq(
		McpDockScript._transport_status_text({"phase": "blocked", "attempt": 4}),
		"Connection blocked",
	)


func test_update_status_renders_transport_phase_and_transient_reason() -> void:
	_dock._build_ui()
	_dock.present_transport_snapshot({
		"connected": false,
		"status": {
		"phase": "connecting",
		"attempt": 2,
		"state_elapsed_sec": 10.0,
		"reason": "Server rejected the editor auth token.",
		},
	})
	_dock._startup_grace_until_msec = 0

	_dock._update_status()

	assert_eq(_dock._status_label.text, "Connecting — attempt 2")
	assert_eq(
		_dock._status_label.tooltip_text,
		"Server rejected the editor auth token.",
		"the compact primary label should keep transient detail in its tooltip",
	)


func test_update_status_hides_stale_transient_reason_while_connected() -> void:
	_dock._build_ui()
	_dock.present_transport_snapshot({
		"connected": true,
		"status": {
		"phase": "connected",
		"attempt": 0,
		"state_elapsed_sec": 0.0,
		"reason": "Previous peer rejected the editor auth token.",
		},
	})
	_dock._startup_grace_until_msec = 0

	_dock._update_status()

	assert_eq(_dock._status_label.text, "Server connected")
	assert_eq(
		_dock._status_label.tooltip_text,
		"",
		"an OPEN connection must not show the previous peer's transient reason",
	)


func test_empty_client_cta_visible_only_until_a_client_is_configured() -> void:
	_dock._build_ui()
	_dock.present_client_work_snapshot({"refresh_completed": false})
	_dock._refresh_clients_summary()
	assert_false(
		_dock._client_empty_cta_btn.visible,
		"CTA should stay hidden until the initial client status sweep proves there are no configured clients",
	)

	_dock.present_client_work_snapshot({"refresh_completed": true})
	_dock._refresh_clients_summary()
	assert_true(
		_dock._client_empty_cta_btn.visible,
		"First-run dock should surface a direct configure-client CTA",
	)

	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock._apply_row_status(any_id, McpClient.Status.CONFIGURED)
	_dock._refresh_clients_summary()
	assert_false(
		_dock._client_empty_cta_btn.visible,
		"CTA should collapse once at least one AI client is configured",
	)

	_dock._apply_row_status(any_id, McpClient.Status.NOT_CONFIGURED)
	_dock._refresh_clients_summary()
	assert_true(
		_dock._client_empty_cta_btn.visible,
		"CTA should reappear when the last configured AI client is removed",
	)


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


func test_apply_row_status_mismatch_prefers_probe_message() -> void:
	## A `{scope}` client can drift by being registered in a scope the user
	## did not select (#872). "URL out of date" is a wrong description of
	## that, so a probe-supplied message wins the label.
	_dock._build_ui()
	var any_id := McpClientConfigurator.client_ids()[0]
	_dock._apply_row_status(
		any_id, McpClient.Status.CONFIGURED_MISMATCH, "registered at user scope, not project"
	)
	var row: Dictionary = _dock._client_rows[any_id]
	assert_eq((row["dot"] as ColorRect).color, McpDockScript.COLOR_AMBER,
		"a scope mismatch is still drift, so it stays amber")
	var label := (row["name_label"] as Label).text
	assert_contains(label, "registered at user scope, not project",
		"the probe's own words must reach the row")
	assert_false(label.contains("URL out of date"),
		"a scope mismatch is not a stale URL — that label would misdescribe it")


func test_client_rows_show_config_file_buttons_only_for_file_clients() -> void:
	_dock._build_ui()
	var file_id := "cursor"
	if not _dock._client_rows.has(file_id):
		skip("Cursor client not registered")
		return
	var file_row: Dictionary = _dock._client_rows[file_id]
	var file_path := McpClientConfigurator.config_path(file_id)
	assert_false(file_path.is_empty(), "Cursor should expose a config path")
	assert_eq(String(file_row.get("config_path", "")), file_path)
	assert_true((file_row["open_config_btn"] as Button).visible,
		"File-based clients must show Open config file")
	assert_true((file_row["reveal_btn"] as Button).visible,
		"File-based clients must show Reveal in folder")
	assert_contains((file_row["open_config_btn"] as Button).tooltip_text, file_path,
		"Open tooltip should carry the full path without widening the row")

	## #kimi-mcp-json: kimi_code used to be the only "pure CLI" (no JSON
	## fallback) client in the registry, so this branch hardcoded its id.
	## It moved to config_type "json" (see test_kimi_code_client_json_descriptor
	## in test_clients.gd) because Kimi Code has no `mcp` CLI subcommand.
	## Discover a pure-CLI example dynamically instead of re-pinning to a
	## specific id, so this assertion degrades to a clear skip — not a false
	## pass or an unrelated failure — if the registry currently has none.
	var cli_id := ""
	for id in McpClientConfigurator.client_ids():
		var c := McpClientRegistry.get_by_id(String(id))
		if c != null and c.config_type == "cli" and not c.has_json_fallback():
			cli_id = String(id)
			break
	if cli_id.is_empty() or not _dock._client_rows.has(cli_id):
		skip("No pure CLI client (config_type \"cli\" with no JSON fallback) currently registered")
		return
	var cli_row: Dictionary = _dock._client_rows[cli_id]
	assert_eq(String(cli_row.get("config_path", "")), "")
	assert_false((cli_row["open_config_btn"] as Button).visible,
		"Pure CLI clients should not show a dead Open config file button")
	assert_false((cli_row["reveal_btn"] as Button).visible,
		"Pure CLI clients should not show a dead Reveal in folder button")


func test_incompatible_server_does_not_paint_client_rows_error() -> void:
	## INCOMPATIBLE skips health interpretation so Configure / Configure all
	## can still write pins (#916). Rows must not be painted ERROR/red with
	## the blocked-server paragraph — that made Configure all unusable.
	_dock.present_lifecycle_snapshot({
		"state": McpServerState.INCOMPATIBLE,
		"message": "Port 8000 is occupied by godot-ai server v1.2.10; plugin expects v2.2.0.",
		"connection_blocked": true,
	})
	_dock._build_ui()

	var any_id := McpClientConfigurator.client_ids()[0]
	var row: Dictionary = _dock._client_rows[any_id]
	var dot: ColorRect = row["dot"]
	var name_label := row["name_label"] as Label
	var display_name := McpClientConfigurator.client_display_name(any_id)
	_dock._refresh_all_client_statuses()
	assert_ne(dot.color, Color.RED, "INCOMPATIBLE must not paint client rows ERROR/red")
	assert_eq(dot.color, McpDockScript.COLOR_MUTED,
		"skipped interpretation leaves the initial muted dot")
	assert_false(
		name_label.text.contains("Port 8000 is occupied by godot-ai server v1.2.10"),
		"blocked-server message must not be stamped onto every client row"
	)
	assert_eq(name_label.text, display_name,
		"row caption stays the display name so Configure all remains usable")


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


class _ClientActionRecordingDock extends McpDockScript:
	var configured_ids: Array[String] = []

	func _on_configure_client(client_id: String) -> void:
		configured_ids.append(client_id)


## Replaces the worker body so post-update owner tests never touch real client
## files or build a uvx environment.
class _RepinRecordingOwner extends ClientJobOwnerScript:
	var calls: Array[Dictionary] = []
	var probe_ids: Array[String] = []
	var delay_msec := 0

	func _run_post_update_repin(
		_probes: Array[Dictionary],
		_context: Dictionary,
		from_version: String,
		to_version: String,
		replace_owned_mismatches: bool,
		generation: int,
	) -> Dictionary:
		if delay_msec > 0:
			OS.delay_msec(delay_msec)
		for probe in _probes:
			probe_ids.append(str(probe.get("id", "")))
		calls.append({
			"from": from_version,
			"to": to_version,
			"replace_owned_mismatches": replace_owned_mismatches,
		})
		return {
			"ok": true,
			"generation": generation,
			"configured_ids": ["claude_code"],
			"repinned_ids": ["claude_code"],
			"error": "",
			"prewarm": {"skipped": true},
		}


func test_configure_all_dispatches_while_incompatible() -> void:
	## The write path must run while INCOMPATIBLE — Configure writes an
	## explicit url + live plugin version and does not need a healthy occupant.
	var blocked := {
		"state": McpServerState.INCOMPATIBLE,
		"message": "Port 8000 is occupied by godot-ai server v1.2.10; plugin expects v2.2.0.",
	}
	var dock := _ClientActionRecordingDock.new()
	dock.present_lifecycle_snapshot(blocked)
	dock._client_rows["claude_code"] = {"status": McpClient.Status.NOT_CONFIGURED}
	dock._client_rows["cursor"] = {"status": McpClient.Status.CONFIGURED}

	dock._on_configure_all_clients()
	var configured := dock.configured_ids.duplicate()
	dock.free()

	assert_eq(configured, ["claude_code"] as Array[String],
		"Configure all must dispatch writes for unconfigured rows while INCOMPATIBLE")


func test_configure_all_dispatches_while_incompatible_refresh_running() -> void:
	## `_set_incompatible_server()` can flip INCOMPATIBLE without clearing
	## `_refresh_state`. Per-row Configure already ignores RUNNING; Configure
	## all must too, or the button stays dead until the sweep finishes.
	var blocked := {
		"state": McpServerState.INCOMPATIBLE,
		"message": "Port 8000 is occupied by godot-ai server v1.2.10; plugin expects v2.2.0.",
	}
	var dock := _ClientActionRecordingDock.new()
	dock.present_lifecycle_snapshot(blocked)
	dock.present_client_work_snapshot({"refresh_state": McpClientRefreshState.RUNNING})
	dock._client_rows["claude_code"] = {"status": McpClient.Status.NOT_CONFIGURED}

	dock._on_configure_all_clients()
	var configured := dock.configured_ids.duplicate()
	dock.free()

	assert_eq(configured, ["claude_code"] as Array[String],
		"Configure all must dispatch while INCOMPATIBLE even if a refresh is RUNNING")


func test_post_update_repin_is_one_restricted_owned_worker() -> void:
	var owner := _RepinRecordingOwner.new()
	var completions: Array[Dictionary] = []
	owner.post_update_repin_completed.connect(func(result: Dictionary) -> void:
		completions.append(result)
	)
	var target := McpClientConfigurator.get_plugin_version()
	var started := owner.begin_post_update_repin("3.1.2", target)
	assert_true(bool(started.get("ok", false)))
	assert_false(owner._accepting_work, "ordinary client work remains closed during migration")
	assert_false(owner.request_action("claude_code", "configure"))
	assert_false(owner.request_mcp_status("blocked-mcp"))
	while owner._post_update_thread != null and owner._post_update_thread.is_alive():
		OS.delay_msec(1)
	owner._poll_post_update_repin()
	assert_eq(owner.calls, [{
		"from": "3.1.2",
		"to": target,
		"replace_owned_mismatches": false,
	}])
	assert_eq(completions.size(), 1)
	assert_eq(completions[0].repinned_ids, ["claude_code"])
	assert_false(owner.probe_ids.has("zed"),
		"manual-only JSONC clients must not enter the hard automatic M6 barrier")
	owner.free()


func test_manual_major_repin_marks_owned_mismatches_replaceable() -> void:
	var owner := _RepinRecordingOwner.new()
	var target := McpClientConfigurator.get_plugin_version()
	var started := owner.begin_post_update_repin("3.2.4", target, true)
	assert_true(bool(started.get("ok", false)))
	while owner._post_update_thread != null and owner._post_update_thread.is_alive():
		OS.delay_msec(1)
	owner._poll_post_update_repin()
	assert_eq(owner.calls, [{
		"from": "3.2.4",
		"to": target,
		"replace_owned_mismatches": true,
	}])
	owner.free()


func test_post_update_repin_rejects_a_missing_or_wrong_target() -> void:
	var owner := _RepinRecordingOwner.new()
	assert_false(bool(owner.begin_post_update_repin("3.1.2", "").get("ok", true)))
	assert_false(bool(owner.begin_post_update_repin("3.1.2", "99.0.0").get("ok", true)))
	assert_eq(owner._post_update_thread, null)
	owner.free()


## The closed-editor installer records no previous version when it installs
## into a project without an add-on; that first start still repins.
func test_fresh_install_repins_without_a_previous_version() -> void:
	var owner := _RepinRecordingOwner.new()
	var target := McpClientConfigurator.get_plugin_version()
	var started := owner.begin_post_update_repin("", target, true)
	assert_true(bool(started.get("ok", false)), str(started.get("error", "")))
	while owner._post_update_thread != null and owner._post_update_thread.is_alive():
		OS.delay_msec(1)
	owner._poll_post_update_repin()
	assert_eq(owner.calls, [{
		"from": "",
		"to": target,
		"replace_owned_mismatches": true,
	}])
	owner.free()


func test_unproven_post_update_prewarm_blocks_retry_and_quiescence() -> void:
	Engine.remove_meta(ClientJobOwnerScript.POST_UPDATE_UNPROVEN_META)
	var owner := ClientJobOwnerScript.new()
	owner._record_unproven_post_update_result({
		"termination_failed": true,
		"unsafe_client_id": "",
	})
	var retried := owner.begin_post_update_repin(
		"3.1.2", McpClientConfigurator.get_plugin_version()
	)
	assert_false(bool(retried.get("ok", true)))
	assert_contains(str(retried.get("error", "")), "explicitly remove")
	var quiesced := owner.quiesce()
	assert_false(bool(quiesced.get("ok", true)))
	assert_true(bool(quiesced.get("termination_unproven", false)))
	owner.free()
	Engine.remove_meta(ClientJobOwnerScript.POST_UPDATE_UNPROVEN_META)


func test_post_update_repin_worker_is_joined_by_quiescence() -> void:
	var owner := _RepinRecordingOwner.new()
	owner.delay_msec = 75
	var started := owner.begin_post_update_repin(
		"3.1.2", McpClientConfigurator.get_plugin_version()
	)
	assert_true(bool(started.get("ok", false)))
	var result := owner.quiesce()
	assert_true(bool(result.get("ok", false)))
	assert_eq(owner._post_update_thread, null)
	assert_true(owner._is_post_update_cancelled())
	owner.free()


func test_post_update_retry_button_emits_barrier_action_instead_of_a_second_update() -> void:
	var dock := McpDockScript.new()
	var update_calls := [0]
	var actions: Array[String] = []
	dock.update_requested.connect(func() -> void: update_calls[0] += 1)
	dock.post_update_action_requested.connect(func(action: String) -> void: actions.append(action))
	dock._post_update_action = "retry"
	dock._on_update_pressed()
	assert_eq(actions, ["retry"])
	assert_eq(update_calls[0], 0)
	dock._post_update_action = ""
	dock._on_update_pressed()
	assert_eq(update_calls[0], 1)
	dock.free()


func test_update_asks_before_saving_and_relaunching() -> void:
	## A dock outside a scene tree has no dialog to show and proceeds directly
	## (the test above); the confirmation itself is what a click really does.
	var text := McpDockScript.update_confirm_text("4.1.0")
	assert_true(text.contains("save your project"), text)
	assert_true(text.contains("relaunch the editor"), text)
	assert_true(text.contains("Godot AI v4.1.0"), text)
	assert_true(text.contains("AI clients connected right now must be restarted"), text)
	assert_true(McpDockScript.update_confirm_text("").contains("the new Godot AI"))
	var dock := McpDockScript.new()
	var update_calls := [0]
	dock.update_requested.connect(func() -> void: update_calls[0] += 1)
	dock._on_update_confirmed()
	assert_eq(update_calls[0], 1, "confirming is what requests the update")
	dock.free()


func test_successful_configure_discloses_the_scope_sweep_on_the_row() -> void:
	## #877: `_show_manual_command_for` — the only thing that reveals the panel
	## listing the pre-cleanup removes — is called just once, on the Configure
	## FAILURE branch. So a successful Configure cleared `godot-ai` out of every
	## scope, including a .mcp.json in whatever directory the editor happened to
	## be launched from, and told the user nothing. The green row carries that.
	_dock._build_ui()
	assert_true(_dock._client_rows.has("claude_code"),
		"claude_code is a static registry entry and must have a row")
	if not _dock._client_rows.has("claude_code"):
		return
	var row: Dictionary = _dock._client_rows["claude_code"]
	var note := McpClientConfigurator.configure_sweep_note("claude_code")
	assert_false(note.is_empty(), "claude_code is the scope-sweeping descriptor")

	_dock._apply_row_status("claude_code", McpClient.Status.CONFIGURED, note)
	var label := (row["name_label"] as Label).text
	assert_contains(label, note,
		"a successful configure must disclose the sweep it just performed")
	assert_contains(label, "project",
		"the destructive pass is the project one — the row has to name it")
	assert_eq((row["dot"] as ColorRect).color, Color.GREEN,
		"the note is a disclosure on a healthy row, not a warning state")

	## Transient by design: the next status refresh re-applies CONFIGURED with
	## no detail, so the row settles back to its plain name rather than pinning
	## a note that no longer describes anything that just happened.
	_dock._apply_row_status("claude_code", McpClient.Status.CONFIGURED)
	assert_eq(
		(row["name_label"] as Label).text,
		McpClientConfigurator.client_display_name("claude_code"),
		"the note must not survive an ordinary status refresh",
	)


func test_focus_in_auto_refresh_is_enabled_with_async_cooldown() -> void:
	## Focus-in should still refresh client status, but the refresh path must be
	## async/cooldown-protected so it does not run blocking CLI checks on the
	## editor thread during OS/window refocus.
	assert_true(_dock._should_refresh_client_statuses_on_focus_in(),
		"Editor focus-in should request the async client-status refresh")
	assert_eq(ClientJobOwnerScript.STATUS_COOLDOWN_MSEC, 15 * 1000,
		"Focus-in refresh cooldown is intentionally short and explicit")


func test_refresh_cooldown_helper_only_blocks_automatic_refreshes() -> void:
	var owner := ClientJobOwnerScript.new()
	owner._accepting_work = true
	owner._refresh_completed_msec = Time.get_ticks_msec()
	assert_false(owner.request_status_refresh(["missing"], false),
		"Recent automatic refresh should be rejected inside cooldown")
	assert_eq(owner._refresh_state, McpClientRefreshState.IDLE,
		"Cooldown rejection must not allocate a worker")
	owner.free()


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
	var script: GDScript = ClientJobOwnerScript
	var has_constant := false
	for entry in script.get_script_constant_map():
		if String(entry) == "CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC":
			has_constant = true
			break
	assert_false(has_constant, "CLIENT_STATUS_REFRESH_INITIAL_DELAY_MSEC must be removed — #235 replaces #234's timer with a deterministic gate")


func test_quiesce_realizes_the_single_refresh_worker() -> void:
	var t := Thread.new()
	var err := t.start(func() -> int: return 42)
	assert_eq(err, OK, "Test fixture failed to start thread")
	var owner := ClientJobOwnerScript.new()
	owner._refresh_thread = t
	owner._refresh_state = McpClientRefreshState.RUNNING
	owner.quiesce()
	assert_eq(owner._refresh_thread, null,
		"quiesce must realize the sole refresh worker before script reload")
	owner.free()


func test_repeated_forced_refreshes_coalesce_behind_one_timed_out_worker() -> void:
	var owner := ClientJobOwnerScript.new()
	owner._accepting_work = true
	owner._refresh_generation = 7
	owner._refresh_state = McpClientRefreshState.RUNNING_TIMED_OUT
	var worker := Thread.new()
	var error := worker.start(func() -> Dictionary:
		OS.delay_msec(100)
		return {"results": {}, "generation": 7}
	)
	assert_eq(error, OK)
	owner._refresh_thread = worker
	for _index in range(5):
		assert_false(owner.request_status_refresh([], true))
		assert_eq(owner._refresh_thread, worker,
			"force refresh must retain the one live worker")
	assert_true(owner._refresh_pending)
	assert_true(owner._refresh_pending_force)
	while worker.is_alive():
		OS.delay_msec(1)
	owner._poll_refresh()
	assert_eq(owner._refresh_thread, null)
	assert_eq(owner._refresh_state, McpClientRefreshState.IDLE)
	assert_false(owner._refresh_pending)
	owner.free()


func test_mcp_status_requests_share_the_one_refresh_worker_and_quiesce_owner() -> void:
	var owner := ClientJobOwnerScript.new()
	owner._accepting_work = true
	owner._refresh_generation = 7
	owner._refresh_state = McpClientRefreshState.RUNNING
	var worker := Thread.new()
	var error := worker.start(func() -> Dictionary:
		OS.delay_msec(100)
		return {"results": {}, "generation": 7}
	)
	assert_eq(error, OK)
	owner._refresh_thread = worker
	for index in range(5):
		assert_true(owner.request_mcp_status("mcp-%d" % index))
		assert_eq(owner._refresh_thread, worker, "MCP requests must not allocate a second worker")
	assert_eq(owner._mcp_status_waiters.size(), 5)
	assert_true(owner._refresh_pending, "one all-client retry should be coalesced")
	owner.quiesce()
	assert_eq(owner._refresh_thread, null)
	assert_true(owner._mcp_status_waiters.is_empty())
	owner.free()


func test_mcp_status_waiters_complete_only_for_their_refresh_generation() -> void:
	var owner := ClientJobOwnerScript.new()
	var emissions: Array[Dictionary] = []
	owner.mcp_status_completed.connect(func(ids: Array[String], payload: Dictionary) -> void:
		emissions.append({"ids": ids, "payload": payload})
	)
	owner._mcp_status_waiters = {"first": 3, "later": 4}
	owner._complete_mcp_status_waiters({}, 3, "")
	assert_eq(emissions.size(), 1)
	assert_eq(emissions[0].ids, ["first"])
	assert_has_key(emissions[0].payload, "data")
	assert_true(owner._mcp_status_waiters.has("later"))
	owner._complete_mcp_status_waiters({}, 4, "probe failed")
	assert_eq(emissions.size(), 2)
	assert_has_key(emissions[1].payload, "error")
	assert_true(owner._mcp_status_waiters.is_empty())
	owner.free()


func test_self_update_in_progress_blocks_request_refresh() -> void:
	## Race B regression: while `McpUpdateManager._install_zip` is overwriting
	## plugin scripts on disk, every refresh-spawn path (focus-in, manual
	## button, cooldown timer, deferred initial refresh) must short-circuit.
	## Spawning a worker that walks into a half-overwritten script crashes
	## inside `GDScriptFunction::call` (confirmed by SIGABRT in
	## `VBoxContainer(McpDock)::_run_client_status_refresh_worker`).
	##
	## The Dock receives install state as a value; it has no manager reference.
	_dock._build_ui()
	var intents: Array = []
	_dock.client_status_refresh_requested.connect(
		func(ids: Array[String], force: bool) -> void: intents.append([ids, force])
	)
	_dock.present_update_state({"install_in_flight": true})
	var ok: bool = _dock._request_client_status_refresh(false)
	assert_false(ok, "Refresh must not emit work while self-update is in progress")
	assert_true(intents.is_empty(), "No refresh intent should escape during activation")
	_dock.present_update_state({"install_in_flight": false})


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
	var owner := ClientJobOwnerScript.new()
	owner.activate()
	owner.quiesce()
	owner.resume_after_quiesce()
	assert_eq(
		owner._refresh_state,
		McpClientRefreshState.IDLE,
		"a failed update handoff must restore the old owner's refresh state"
	)
	assert_true(bool(owner.snapshot().get("accepting_work", false)),
		"resume must reopen the intent gate after a failed handoff")
	owner.quiesce()
	owner.free()


## Shared fixture for the version-label tests. Inject copied values plus a
## Label + Button so the pure refresh logic can be exercised
## without depending on whether the test environment resolves as user mode
## or dev checkout (the user-mode Server row is what owns these handles in
## production — see `_refresh_setup_status`).
func _seed_server_row(server_ver: String) -> void:
	_dock._server_restart_in_progress = false
	_dock._crash_restart_btn = null
	_dock.present_transport_snapshot({"server_version": server_ver})
	_dock.present_lifecycle_snapshot({})
	_dock._setup_server_label = Label.new()
	_dock._version_restart_btn = Button.new()
	_dock._version_restart_btn.visible = false
	_dock._last_rendered_server_text = ""


func _cleanup_server_row() -> void:
	_dock._setup_server_label.free()
	_dock._setup_server_label = null
	_dock._version_restart_btn.free()
	_dock._version_restart_btn = null
	_dock.present_transport_snapshot({})
	_dock.present_lifecycle_snapshot({})


func test_server_version_label_muted_when_ack_not_received() -> void:
	## Pre-ack: show the expected version only as an unverified target.
	## The row must not state "godot-ai == <plugin>" as a fact until the
	## live server has reported that exact version.
	_seed_server_row("")
	_dock._refresh_server_version_label()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	assert_eq(
		_dock._setup_server_label.text,
		"checking live version (expected godot-ai == %s)" % plugin_ver
	)
	assert_false(_dock._version_restart_btn.visible, "Restart button stays hidden pre-ack")
	_cleanup_server_row()


func test_server_version_label_green_when_server_matches_plugin() -> void:
	## Post-ack + match: the happy path. Green label, no Restart button.
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	_seed_server_row(plugin_ver)
	_dock._refresh_server_version_label()
	assert_eq(_dock._setup_server_label.text, "godot-ai == %s" % plugin_ver,
		"Match: label omits the '(plugin X)' suffix since there's no drift to flag")
	assert_true(_dock._setup_server_label.has_theme_color_override("font_color"))
	var color: Color = _dock._setup_server_label.get_theme_color("font_color")
	assert_true(color == Color.GREEN,
		"Matched version must render green, got %s" % str(color))
	assert_false(_dock._version_restart_btn.visible,
		"Restart button stays hidden when versions match")
	_cleanup_server_row()


func test_server_version_label_amber_without_restart_when_ownership_unproven() -> void:
	## The money test: the bug scenario. Plugin is v1.4.2 but connected to
	## a v1.3.3 server (common after self-update when a foreign-adopted
	## server outlives the plugin upgrade). Label must expose both versions.
	## The Restart button stays hidden without plugin-provided ownership proof
	## so the dock does not offer to kill an arbitrary foreign process.
	_seed_server_row("1.2.3-stale-for-test")
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
	_cleanup_server_row()


func test_server_version_label_repaints_color_when_state_changes_without_text_change() -> void:
	## The label text for "server vX, expected vY" is identical before and
	## after the plugin marks the server incompatible; the color must still
	## repaint from amber to red so the blocked state is visible.
	_seed_server_row("1.2.3-stale-for-test")
	_dock.present_lifecycle_snapshot({
		"state": McpServerState.READY,
		"actual_version": "1.2.3-stale-for-test",
		"expected_version": "2.2.0",
	})

	_dock._refresh_server_version_label()
	assert_eq(
		_dock._setup_server_label.get_theme_color("font_color"),
		McpDockScript.COLOR_AMBER,
		"precondition: mismatch starts amber while not blocked"
	)

	_dock.present_lifecycle_snapshot({
		"state": McpServerState.INCOMPATIBLE,
		"actual_version": "1.2.3-stale-for-test",
		"expected_version": "2.2.0",
	})
	_dock._refresh_server_version_label()
	assert_eq(
		_dock._setup_server_label.get_theme_color("font_color"),
		Color.RED,
		"same label text must repaint red when state becomes incompatible"
	)
	assert_false(_dock._version_restart_btn.visible, "incompatible state must hide Restart")

	_cleanup_server_row()


func test_server_version_label_shows_restart_for_recoverable_incompatible_server() -> void:
	_seed_server_row("1.2.3-stale-for-test")
	_dock.present_lifecycle_snapshot({
		"state": McpServerState.INCOMPATIBLE,
		"actual_version": "1.2.3-stale-for-test",
		"expected_version": "2.2.0",
		"can_recover_incompatible": true,
	})

	_dock._refresh_server_version_label()
	assert_true(
		_dock._version_restart_btn.visible,
		"recoverable incompatible godot-ai server should offer the user-confirmed restart"
	)

	_cleanup_server_row()


func test_restart_dispatches_incompatible_state_to_recovery() -> void:
	var recorder := _IntentRecorder.new()
	_dock.lifecycle_action_requested.connect(recorder.on_lifecycle_action)
	_dock.present_lifecycle_snapshot({"state": McpServerState.INCOMPATIBLE})

	_dock._on_restart_stale_server()
	var recover_calls := recorder.recover_calls
	var restart_calls := recorder.force_restart_calls

	assert_eq(recover_calls, 1)
	assert_eq(restart_calls, 0)
	_dock.lifecycle_action_requested.disconnect(recorder.on_lifecycle_action)
	_dock.present_lifecycle_snapshot({})


func test_restart_dispatches_non_incompatible_state_to_force_restart() -> void:
	var recorder := _IntentRecorder.new()
	_dock.lifecycle_action_requested.connect(recorder.on_lifecycle_action)
	_dock.present_lifecycle_snapshot({
		"state": McpServerState.READY,
		"can_restart_managed": true,
	})

	_dock._on_restart_stale_server()
	var recover_calls := recorder.recover_calls
	var restart_calls := recorder.force_restart_calls

	assert_eq(recover_calls, 0)
	assert_eq(restart_calls, 1)
	_dock.lifecycle_action_requested.disconnect(recorder.on_lifecycle_action)
	_dock.present_lifecycle_snapshot({})


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


func test_crashed_body_prefers_lifecycle_message() -> void:
	## #805: a specific crash diagnosis from the lifecycle (the flapping-
	## occupant latch) must render verbatim instead of the generic
	## launch-mode copy. Generic crash paths clear the message, so this
	## preference can't surface stale text.
	var message := "The spawned server keeps exiting while another godot-ai server answers on port 8000, and re-adoption was already attempted."
	var body := McpDockScript._crash_body_for_state(
		McpServerState.CRASHED, {"message": message}
	)
	assert_eq(body, message)


func test_crashed_body_without_message_keeps_launch_mode_copy() -> void:
	var body := McpDockScript._crash_body_for_state(McpServerState.CRASHED, {"message": ""})
	assert_false(body.is_empty())
	assert_false(body.contains("another godot-ai server"),
		"an empty lifecycle message must fall back to the launch-mode copy")


func test_foreign_port_body_prefers_lifecycle_message() -> void:
	## #647: when the post-crash probe diagnosed which port a foreign
	## process holds, the crash body must render that message verbatim
	## (it names the right port and Editor Setting) instead of the
	## generic HTTP-port fallback.
	var message := "WebSocket port 9500 is in use by another application. Stop it or change the port in Editor Settings (godot_ai/ws_port)."
	var body := McpDockScript._crash_body_for_state(
		McpServerState.FOREIGN_PORT, {"message": message}
	)
	assert_eq(body, message)


func test_foreign_port_body_without_message_keeps_generic_fallback() -> void:
	var body := McpDockScript._crash_body_for_state(McpServerState.FOREIGN_PORT)
	assert_contains(body, "Another process is already bound to port")


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


func test_timed_out_client_refresh_reenables_configure_all() -> void:
	_dock._build_ui()
	_dock.present_client_work_snapshot({
		"refresh_state": McpClientRefreshState.RUNNING_TIMED_OUT,
	})
	assert_contains(_dock._clients_summary_label.text, "client probe still running",
		"Timed-out refreshes should still be visible in the summary")
	assert_false(_dock._client_configure_all_btn.disabled,
		"Timed-out refreshes must not keep client actions disabled")


func test_timed_out_client_action_keeps_one_slot_until_result_is_inspected() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var owner := ClientJobOwnerScript.new()
	owner.action_timed_out.connect(_dock.present_client_action_timeout)
	owner.action_completed.connect(_dock.present_client_action_result)
	owner.snapshot_changed.connect(_dock.present_client_work_snapshot)
	_dock._set_row_action_in_flight(any_id, "configure")
	owner._action_threads[any_id] = null
	owner._action_started_msec[any_id] = 1
	owner._action_names[any_id] = "configure"
	owner._check_action_timeouts(ClientJobOwnerScript.ACTION_TIMEOUT_MSEC + 2)

	var row: Dictionary = _dock._client_rows[any_id]
	assert_true(owner._action_threads.has(any_id),
		"Timed-out action must retain its sole slot until its result is inspected")
	assert_true((row["configure_btn"] as Button).disabled,
		"Configure button must remain disabled while the timed-out slot is retained")
	assert_eq(row.get("status"), McpClient.Status.ERROR,
		"Timed-out action must explain the retained busy state")
	assert_contains((row["name_label"] as Label).text, "waiting to inspect its result",
		"Timeout copy must explain why retry remains unavailable")
	owner._finalize_action(any_id, "configure", {"status": "ok"}, {})
	assert_false(owner._action_threads.has(any_id),
		"Only inspected completion may release the client slot")
	assert_eq(row.get("status"), McpClient.Status.CONFIGURED,
		"The joined worker's real result is authoritative after timeout")
	owner.free()


func test_completed_client_action_clears_timeout_metadata() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var owner := ClientJobOwnerScript.new()
	owner.action_completed.connect(_dock.present_client_action_result)
	_dock._set_row_action_in_flight(any_id, "configure")
	owner._action_threads[any_id] = null
	owner._action_started_msec[any_id] = Time.get_ticks_msec() - ClientJobOwnerScript.ACTION_TIMEOUT_MSEC - 1
	owner._action_names[any_id] = "configure"
	owner._action_timeout_reported[any_id] = true
	owner._finalize_action(any_id, "configure", {"status": "ok"}, {})
	owner._check_action_timeouts()

	var row: Dictionary = _dock._client_rows[any_id]
	assert_false(owner._action_threads.has(any_id),
		"Successful completion must clear the action thread slot")
	assert_false(owner._action_started_msec.has(any_id),
		"Successful completion must clear timeout start metadata")
	assert_false(owner._action_names.has(any_id),
		"Successful completion must clear timeout action metadata")
	assert_false(owner._action_timeout_reported.has(any_id),
		"Successful completion must clear the one-shot timeout marker")
	assert_eq(row.get("status"), McpClient.Status.CONFIGURED,
		"A completed Configure must remain configured after a later watchdog tick")
	owner.free()


func test_client_action_timeout_is_independent_of_transport_snapshot() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var owner := ClientJobOwnerScript.new()
	owner.action_timed_out.connect(_dock.present_client_action_timeout)
	owner.snapshot_changed.connect(_dock.present_client_work_snapshot)
	_dock._set_row_action_in_flight(any_id, "configure")
	owner._action_threads[any_id] = null
	owner._action_started_msec[any_id] = 1
	owner._action_names[any_id] = "configure"
	owner._check_action_timeouts(ClientJobOwnerScript.ACTION_TIMEOUT_MSEC + 2)

	var row: Dictionary = _dock._client_rows[any_id]
	assert_true(owner._action_threads.has(any_id),
		"Action watchdog must retain the slot even without a connection")
	assert_true((row["configure_btn"] as Button).disabled,
		"The row cannot recover until the retained worker result is inspected")
	assert_contains((row["name_label"] as Label).text, "waiting to inspect its result",
		"The row should explain why it remains locked")
	owner._finalize_action(any_id, "configure", {"status": "error"}, {})
	owner.free()


func test_completed_timed_out_action_records_unproven_before_releasing_slot() -> void:
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)
	var client_id := "timed-out-unproven"
	var thread := Thread.new()
	var payload := {
		"client_id": client_id,
		"action": "configure",
		"result": {"status": "error", "termination_failed": true},
		"prewarm": {},
	}
	var err := thread.start(Callable(self, "_finished_thread_payload").bind(payload))
	assert_eq(err, OK, "Finished timed-out fixture thread should start")
	while thread.is_alive():
		OS.delay_msec(1)
	var owner := ClientJobOwnerScript.new()
	owner._action_threads[client_id] = thread
	owner._action_names[client_id] = "configure"
	owner._action_timeout_reported[client_id] = true
	owner._poll_actions()
	assert_true(owner._mutation_termination_unproven.has(client_id),
		"The joined payload must persist safety evidence")
	assert_false(owner._action_threads.has(client_id),
		"The slot releases only after the unsafe payload was inspected")
	owner.free()
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)


func test_dispatch_client_action_short_circuits_during_self_update() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var intents: Array = []
	_dock.client_action_requested.connect(
		func(client_id: String, action: String) -> void: intents.append([client_id, action])
	)
	_dock.present_update_state({"install_in_flight": true})
	_dock._dispatch_client_action(any_id, "configure")
	assert_true(intents.is_empty(), "No client intent may escape while self-update is active")
	_dock.present_update_state({"install_in_flight": false})


func test_dispatch_client_action_noop_when_slot_already_in_flight() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var intents: Array = []
	_dock.client_action_requested.connect(
		func(client_id: String, action: String) -> void: intents.append([client_id, action])
	)
	_dock.present_client_work_snapshot({"busy_actions": [any_id]})
	_dock._dispatch_client_action(any_id, "configure")
	assert_true(intents.is_empty(), "A busy value snapshot must suppress double-dispatch")
	_dock.present_client_work_snapshot({"busy_actions": []})


func test_completed_action_thread_is_polled_and_applied() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var owner := ClientJobOwnerScript.new()
	owner.action_completed.connect(_dock.present_client_action_result)
	_dock._set_row_action_in_flight(any_id, "configure")
	owner._action_started_msec[any_id] = Time.get_ticks_msec()
	owner._action_names[any_id] = "configure"
	var payload := {
		"client_id": any_id,
		"action": "configure",
		"result": {"status": "ok"},
	}
	var thread := Thread.new()
	var err := thread.start(Callable(self, "_finished_thread_payload").bind(payload))
	assert_eq(err, OK, "Completed action fixture thread should start")
	while thread.is_alive():
		OS.delay_msec(1)
	owner._action_threads[any_id] = thread
	owner._poll_actions()

	var row: Dictionary = _dock._client_rows[any_id]
	assert_false(owner._action_threads.has(any_id),
		"Polling must clear the completed action slot")
	assert_eq(row.get("status"), McpClient.Status.CONFIGURED,
		"Completed configure payload must repaint the row as configured")
	assert_contains(_dock._clients_summary_label.text, "1 /",
		"Summary should reconcile as soon as the completed action is reaped")
	owner.free()


func test_unproven_mutation_survives_owner_restart_until_explicit_recovery() -> void:
	var client_id := "unproven-client"
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)
	var owner := ClientJobOwnerScript.new()
	var completions: Array[Dictionary] = []
	owner.action_completed.connect(func(id: String, action: String, result: Dictionary, _prewarm: Dictionary) -> void:
		completions.append({"id": id, "action": action, "result": result})
	)
	owner.activate()
	owner._finalize_action(
		client_id,
		"configure",
		{"status": "error", "termination_failed": true},
		{},
	)
	assert_true(owner._mutation_termination_unproven.has(client_id))
	assert_false(owner.request_action(client_id, "remove"),
		"a possibly-live old mutation must block the next mutation")
	assert_eq(completions.size(), 2)
	assert_contains(str(completions[1].result.get("message", "")), "explicitly remove")

	var quiesced := owner.quiesce()
	assert_false(bool(quiesced.get("ok", true)),
		"self-update must not continue across an unproven client mutation")
	assert_true(bool(quiesced.get("termination_unproven", false)))
	owner.resume_after_quiesce()
	assert_false(owner.request_action(client_id, "configure"),
		"failed-update resume must not erase the durable safety block")
	owner.quiesce()
	owner.free()

	var replacement := ClientJobOwnerScript.new()
	replacement.activate()
	assert_true(replacement._mutation_termination_unproven.has(client_id),
		"plugin reload in the same editor process must retain the deny marker")
	assert_false(replacement.request_action(client_id, "remove"))
	replacement.quiesce()
	replacement.free()
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)


func test_quiesce_records_unproven_prewarm_from_joined_action() -> void:
	var client_id := "unproven-prewarm"
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)
	var owner := ClientJobOwnerScript.new()
	var payload := {
		"client_id": client_id,
		"action": "configure",
		"result": {"status": "ok"},
		"prewarm": {"termination_failed": true},
	}
	var thread := Thread.new()
	var err := thread.start(Callable(self, "_finished_thread_payload").bind(payload))
	assert_eq(err, OK)
	owner._action_threads[client_id] = thread
	var quiesced := owner.quiesce()
	assert_false(bool(quiesced.get("ok", true)),
		"a joined prewarm with possible descendants must block script swap")
	assert_true(owner._mutation_termination_unproven.has(client_id))
	owner.free()
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)


func test_completed_status_refresh_thread_is_polled_and_applied() -> void:
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	var owner := ClientJobOwnerScript.new()
	_dock.present_client_work_snapshot({"busy_actions": []})
	owner.status_refresh_completed.connect(_dock.present_client_status_refresh_results)
	owner.snapshot_changed.connect(_dock.present_client_work_snapshot)
	owner._refresh_generation = 21
	owner._refresh_state = McpClientRefreshState.RUNNING
	var payload := {
		"generation": 21,
		"results": {
			any_id: {
				"status": McpClient.Status.CONFIGURED,
				"installed": true,
				"error_msg": "",
			},
		},
	}
	var thread := Thread.new()
	var err := thread.start(Callable(self, "_finished_thread_payload").bind(payload))
	assert_eq(err, OK, "Completed status fixture thread should start")
	while thread.is_alive():
		OS.delay_msec(1)
	owner._refresh_thread = thread
	owner._poll_refresh()

	var row: Dictionary = _dock._client_rows[any_id]
	assert_eq(owner._refresh_thread, null,
		"Polling must clear the completed status refresh thread")
	assert_eq(owner._refresh_state, McpClientRefreshState.IDLE,
		"Completed status refresh should finalize back to idle")
	assert_eq(row.get("status"), McpClient.Status.CONFIGURED,
		"Status refresh payload must repaint the row")
	assert_false(_dock._clients_summary_label.text.contains("checking"),
		"Summary must drop the checking badge after applying the payload")
	owner.free()


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
	_dock.present_client_work_snapshot({
		"busy_actions": [any_id],
		"action_names": {any_id: "configure"},
	})
	var results := {
		any_id: {
			"status": McpClient.Status.NOT_CONFIGURED,
			"installed": true,
			"error_msg": "",
		}
	}
	_dock.present_client_status_refresh_results(results)
	var row: Dictionary = _dock._client_rows[any_id]
	assert_contains((row["configure_btn"] as Button).text, "Configuring",
		"In-flight Configuring badge on the button must survive a concurrent refresh result")
	assert_eq((row["dot"] as ColorRect).color, McpDockScript.COLOR_AMBER,
		"Dot must stay amber while the action worker hasn't completed")


func test_drain_client_action_workers_clears_the_single_slot_table() -> void:
	var owner := ClientJobOwnerScript.new()
	owner._action_threads["sentinel-id"] = null
	owner.quiesce()
	assert_true(owner._action_threads.is_empty(),
		"Quiesce must empty the action-thread map before scripts are replaced")
	assert_eq(owner._refresh_state, McpClientRefreshState.SHUTTING_DOWN,
		"Quiesce closes the owner against new work")
	owner.free()


func test_drain_cancels_all_active_action_workers_before_join() -> void:
	## A cold uvx prewarm has a deliberate 180s normal budget. Teardown must
	## signal every retained row before waiting for threads or editor close/update
	## can inherit that full delay.
	var active_id := "cancel-active"
	var second_id := "cancel-second"
	var owner := ClientJobOwnerScript.new()
	var active := Thread.new()
	var second := Thread.new()
	var active_err := active.start(func() -> void:
		var deadline := Time.get_ticks_msec() + 2000
		while not owner._is_action_cancelled(active_id) \
			and Time.get_ticks_msec() < deadline:
			OS.delay_msec(10)
	)
	var second_err := second.start(func() -> void:
		var deadline := Time.get_ticks_msec() + 2000
		while not owner._is_action_cancelled(second_id) \
			and Time.get_ticks_msec() < deadline:
			OS.delay_msec(10)
	)
	assert_eq(active_err, OK)
	assert_eq(second_err, OK)
	owner._action_threads[active_id] = active
	owner._action_threads[second_id] = second
	var started_msec := Time.get_ticks_msec()
	owner.quiesce()

	var elapsed_msec := Time.get_ticks_msec() - started_msec
	assert_true(elapsed_msec < 1000,
		"Drain must cancel both workers before joining (elapsed=%dms)" % elapsed_msec)
	assert_true(owner._action_threads.is_empty())
	assert_false(owner._is_action_cancelled(active_id),
		"Drain must clear cancellation state after every worker has joined")
	owner.free()


func test_watchdog_cancels_but_retains_live_worker_until_join() -> void:
	## A worker can cross the base budget just before setting PREWARM. It must
	## carry a cancellation request into that poll loop without releasing its
	## one mutation slot before the result has been joined and inspected.
	var client_id := "cancel-watchdog"
	var owner := ClientJobOwnerScript.new()
	owner._set_action_cancelled(client_id, false)
	var worker := Thread.new()
	var start_err := worker.start(func() -> void:
		var deadline := Time.get_ticks_msec() + 2000
		while not owner._is_action_cancelled(client_id) \
			and Time.get_ticks_msec() < deadline:
			OS.delay_msec(10)
	)
	assert_eq(start_err, OK)
	owner._action_threads[client_id] = worker
	owner._action_started_msec[client_id] = Time.get_ticks_msec() - 100
	owner._action_names[client_id] = "configure"
	owner._report_action_timeout(client_id, 100)

	assert_true(owner._is_action_cancelled(client_id),
		"A live timed-out worker must be cancelled before it can enter prewarm")
	assert_true(owner._action_threads.has(client_id),
		"Cancellation must not release the mutation slot")
	while worker.is_alive():
		OS.delay_msec(1)
	owner._poll_actions()
	assert_false(owner._action_threads.has(client_id),
		"Polling releases the slot only after joining the worker")
	assert_false(owner._is_action_cancelled(client_id))
	owner.free()


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
	var owner := ClientJobOwnerScript.new()
	owner.snapshot_changed.connect(_dock.present_client_work_snapshot)
	owner._action_threads[any_id] = null
	owner._action_names[any_id] = "configure"
	owner._publish_snapshot()
	owner.quiesce()
	var row: Dictionary = _dock._client_rows[any_id]
	assert_false((row["configure_btn"] as Button).disabled,
		"Drain must re-enable the configure button so the user can retry")
	assert_false((row["remove_btn"] as Button).disabled,
		"Drain must re-enable the remove button too")
	assert_false(str((row["configure_btn"] as Button).text).contains("Configuring"),
		"Drain must clear the in-flight badge from the configure button")
	owner.free()


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


func test_foreign_incompatible_body_names_concrete_free_ports() -> void:
	## Issue #607 cheap version: the foreign-occupant crash body should hand
	## the user concrete free ports (reservation-aware on Windows) and point
	## them at Editor Settings + the client reconfigure, instead of leaving
	## them to hunt for a port themselves. Names BOTH http and ws: this branch
	## also fires for an incompatible godot-ai server that commonly holds both
	## ports, so suggesting only http would leave the new server unable to
	## bind ws.
	var http_port := McpClientConfigurator.http_port()
	var free_http := McpClientConfigurator.suggest_free_port(http_port + 1)
	var free_ws := McpClientConfigurator.suggest_free_port(McpClientConfigurator.ws_port() + 1)
	var body := McpDockScript._crash_body_for_state(
		McpServerState.INCOMPATIBLE,
		{"message": "Port %d is occupied by another process." % http_port},
	)
	assert_contains(body, "%d (HTTP)" % free_http,
		"foreign-occupant body must name a concrete free HTTP port")
	assert_contains(body, "%d (WS)" % free_ws,
		"foreign-occupant body must name a concrete free WS port")
	assert_contains(body, "godot_ai/http_port",
		"foreign-occupant body must point at the HTTP Editor Setting to change")
	assert_contains(body, "godot_ai/ws_port",
		"foreign-occupant body must point at the WS Editor Setting too")


func test_recoverable_incompatible_body_keeps_restart_copy() -> void:
	## A recoverable (older godot-ai) occupant must NOT be told to flee to a
	## free port — reclaiming the port via Restart Server is the better path,
	## so the free-port hint stays out of that branch.
	var body := McpDockScript._crash_body_for_state(
		McpServerState.INCOMPATIBLE,
		{"can_recover_incompatible": true, "expected_version": "2.8.0"},
	)
	assert_contains(body, "Restart Server", "recoverable body must keep the restart guidance")
	assert_false(body.contains("is free"), "recoverable body must not push a free-port switch")


func test_foreign_incompatible_shows_docs_link_button() -> void:
	## The "How to change the port" docs link carries the per-client
	## reconfigure steps that don't fit inline. It belongs only to the
	## genuinely-foreign case (no recovery proof).
	_dock._build_ui()
	_dock._update_crash_panel({
		"state": McpServerState.INCOMPATIBLE,
		"message": "Port 8000 is occupied by another process.",
	})
	assert_true(_dock._crash_docs_btn.visible,
		"foreign-occupant case must surface the reconfigure docs link")


func test_port_conflict_docs_url_is_pinned_to_installed_version() -> void:
	## The docs button must open the guide as it shipped, not tip-of-main —
	## so the URL is pinned to the release tag (`v<version>`) matching the
	## installed plugin version. Guards against a regression back to a bare
	## blob/main link that drifts away from older builds' UI.
	var url := McpDockScript._port_conflict_docs_url()
	var version := McpClientConfigurator.get_plugin_version()
	assert_contains(url, "/blob/v%s/" % version,
		"docs URL must pin to the installed plugin version's release tag")
	assert_contains(url, McpDockScript.PORT_CONFLICT_DOCS_PATH,
		"docs URL must point at the port-conflict guide")
	assert_false(url.contains("/blob/main/"),
		"docs URL must not hard-link to tip-of-main")


func test_recoverable_incompatible_hides_docs_link_button() -> void:
	## A recoverable godot-ai occupant gets Restart Server, not the
	## change-the-port docs link.
	_dock._build_ui()
	_dock._update_crash_panel({
		"state": McpServerState.INCOMPATIBLE,
		"can_recover_incompatible": true,
		"message": "Port 8000 is occupied by godot-ai server v1.2.10",
	})
	assert_false(_dock._crash_docs_btn.visible,
		"recoverable case keeps Restart Server, not the docs link")


# --- Signal-emit contracts on the audit-v2 #360 extracted subpanels ---
# These pin the new panel boundary: panels emit; dock owns side effects.

## Spies for the two panels' signals. Inner-class pattern matches the
## `_IntentRecorder` spy at the top of this file — multi-line
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


class _SettingsApplySpy:
	var captured: Array[Dictionary] = []
	func on_apply(changes: Dictionary, reload: bool) -> void:
		captured.append({"changes": changes.duplicate(true), "reload": reload})


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


func test_dock_emits_copied_endpoint_setting_intents_without_persisting() -> void:
	var dock := McpDockScript.new()
	var spy := _SettingsApplySpy.new()
	dock.settings_apply_requested.connect(spy.on_apply)
	dock._on_port_apply_requested(23000)
	dock._tools_pending_excluded = PackedStringArray(["audio"])
	dock._telemetry_pending_enabled = false
	dock._on_tools_apply()
	dock._allow_hosts_edit = LineEdit.new()
	dock.add_child(dock._allow_hosts_edit)
	dock._allow_hosts_edit.text = "10.0.0.5"
	dock._on_allow_hosts_apply()
	assert_eq(spy.captured.size(), 3)
	assert_eq(spy.captured[0], {"changes": {"http_port": 23000}, "reload": true})
	assert_eq(str(spy.captured[1].changes.excluded_domains), "audio")
	assert_false(bool(spy.captured[1].changes.telemetry_enabled))
	assert_eq(str(spy.captured[2].changes.allow_hosts), "10.0.0.5")
	dock.free()


func test_log_viewer_emits_logging_enabled_changed_on_toggle() -> void:
	## The root routes this intent to the dispatcher and log-buffer echo gate.
	## If LogViewer stops emitting, MCP
	## request/response logging silently stays whatever it was — easy to
	## regress, hard to spot.
	## Instantiate in isolation to keep the test focused on the panel's
	## emit contract (and consistent with the port-picker tests above).
	var prev_setting := _save_mcp_logging_setting()
	var panel := LogViewerScript.new()
	panel.setup()
	var spy := _LogToggleSpy.new()
	panel.logging_enabled_changed.connect(spy.on_toggle)
	panel._on_log_toggled(false)
	panel._on_log_toggled(true)
	assert_eq(spy.captured, [false, true] as Array[bool],
		"toggle must emit each state change exactly once, in order")
	panel.free()
	_restore_mcp_logging_setting(prev_setting)


func test_log_viewer_toggle_persists_across_rebuilds() -> void:
	## #626: the toggle was hardcoded `button_pressed = true` on every build,
	## so a disabled log setting reset to enabled on each editor restart. The
	## panel must write the EditorSetting on toggle and read it back on build.
	var prev_setting := _save_mcp_logging_setting()
	var panel := LogViewerScript.new()
	panel.setup()
	panel._on_log_toggled(false)
	var es := EditorInterface.get_editor_settings()
	assert_true(es.has_setting(McpSettings.SETTING_MCP_LOGGING),
		"toggle must persist to EditorSettings")
	assert_eq(bool(es.get_setting(McpSettings.SETTING_MCP_LOGGING)), false,
		"persisted value must track the toggle")

	## A freshly built panel (≈ next editor session) restores the choice.
	var rebuilt := LogViewerScript.new()
	rebuilt.setup()
	assert_eq(rebuilt._log_toggle.button_pressed, false,
		"rebuilt panel must restore the persisted (off) state")
	assert_eq(rebuilt._log_display.visible, false,
		"display visibility must match the restored state")

	panel.free()
	rebuilt.free()
	_restore_mcp_logging_setting(prev_setting)


func test_root_routes_dock_log_toggle_to_dispatcher_and_buffer() -> void:
	## #626: the root must route the Dock intent to `dispatcher.mcp_logging`,
	## which gates [recv]/[send] lines — connection-level [event]/[defer]
	## lines log straight to the buffer and otherwise keep echoing to the console.
	var dock := McpDockScript.new()
	var buffer := McpLogBuffer.new()
	var plugin := GodotAiPlugin.new()
	plugin._log_buffer = buffer
	plugin._dispatcher = McpDispatcher.new(buffer)
	dock.mcp_logging_changed.connect(plugin._on_dock_mcp_logging_changed)
	dock._on_log_logging_enabled_changed(false)
	assert_eq(buffer.enabled, false, "toggle off must mute buffer console echo")
	assert_eq(plugin._dispatcher.mcp_logging, false,
		"toggle off must also gate dispatcher [recv]/[send] logging")
	var prev_echo: bool = McpLogBuffer.console_echo
	McpLogBuffer.console_echo = false
	buffer.log("[event] readiness -> importing")
	McpLogBuffer.console_echo = prev_echo
	assert_eq(buffer.total_logged(), 1,
		"ring must keep recording while console echo is muted")
	dock._on_log_logging_enabled_changed(true)
	assert_eq(buffer.enabled, true, "toggle on must restore buffer console echo")
	assert_eq(plugin._dispatcher.mcp_logging, true,
		"toggle on must restore dispatcher [recv]/[send] logging")
	dock.free()
	plugin.free()


func test_configure_phase_labels_the_package_build_instead_of_hanging_silent() -> void:
	## #851: Configure now pre-builds the pinned uv environment so the first
	## CLIENT spawn is warm. That build can run for tens of seconds on a cold
	## cache, and a motionless "Configuring…" reads as a hang — so the worker
	## reports a phase and the poll promotes the label.
	_dock._build_ui()
	var any_id := _first_client_id()
	if any_id.is_empty():
		skip("No clients registered")
		return
	_dock.present_client_work_snapshot({
		"busy_actions": [any_id],
		"action_names": {any_id: "configure"},
		"action_phases": {},
	})
	var btn := _dock._client_rows[any_id]["configure_btn"] as Button
	assert_contains(btn.text, "Configuring", "label must not move before the warm starts")
	_dock.present_client_work_snapshot({
		"busy_actions": [any_id],
		"action_names": {any_id: "configure"},
		"action_phases": {any_id: "prewarm"},
	})
	assert_eq(btn.text, "Installing…", "a cold package build must be labelled, not silent")
	_dock.present_client_work_snapshot({"busy_actions": []})
	assert_false(btn.text.contains("Installing"), "cleared owner state must restore the row")


func test_finished_but_unjoined_worker_still_blocks_an_overlapping_action() -> void:
	## is_alive() may flip false between frames. The slot itself, not liveness,
	## remains the authority until _poll_actions joins and inspects the payload.
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)
	var owner := ClientJobOwnerScript.new()
	owner._accepting_work = true
	var finished := Thread.new()
	finished.start(func() -> Dictionary:
		return {
			"client_id": "claude_code",
			"action": "configure",
			"result": {"status": "error", "termination_failed": true},
			"prewarm": {},
		}
	)
	while finished.is_alive():
		OS.delay_msec(1)
	owner._action_threads["claude_code"] = finished
	owner._action_names["claude_code"] = "configure"
	var overlapping := owner._start_action("claude_code", "remove", "")
	assert_false(bool(overlapping.get("ok", true)),
		"a finished-but-unjoined slot must reject a second mutation")
	assert_true(owner._action_threads.has("claude_code"))
	owner._poll_actions()
	assert_false(owner._action_threads.has("claude_code"),
		"polling may release the slot after it records the payload")
	owner.free()
	Engine.remove_meta(ClientJobOwnerScript.MUTATION_UNPROVEN_META)


func test_prewarm_phase_widens_the_client_action_watchdog() -> void:
	## Regression (#894 CodeRabbit): the action watchdog abandons a worker after
	## ACTION_TIMEOUT_MSEC, sized above the complete CLI registry call. The
	## Configure pre-warm can legitimately run far longer while uv builds the
	## pinned environment — so a cold build would trip the watchdog, re-enable
	## the row, discard the worker's completion, and report a false Configure
	## timeout for exactly the slow cold start the pre-warm exists to absorb.
	var owner := ClientJobOwnerScript.new()

	assert_eq(
		owner._action_budget("claude_code"),
		ClientJobOwnerScript.ACTION_TIMEOUT_MSEC,
		"a plain config write keeps the short registry budget"
	)

	owner._set_action_phase("claude_code", "prewarm")
	var warmed := owner._action_budget("claude_code")
	assert_true(
		warmed >= McpClientConfigurator.PREWARM_TIMEOUT_MS,
		"the watchdog must outlast the pre-warm's own ceiling, not fire mid-build"
	)
	assert_true(
		warmed > ClientJobOwnerScript.ACTION_TIMEOUT_MSEC,
		"the prewarm phase must widen the budget"
	)

	## A cleared phase must fall back to the short budget, or one slow Configure
	## would leave the row's next action effectively unwatched.
	owner._clear_action_phase("claude_code")
	assert_eq(
		owner._action_budget("claude_code"),
		ClientJobOwnerScript.ACTION_TIMEOUT_MSEC,
		"a cleared phase must restore the short budget"
	)
	owner.free()


func test_configure_phase_is_ignored_for_an_unknown_row() -> void:
	## A row can be rebuilt (status refresh) while its worker is still in
	## flight; the poll must not fault on the vanished row.
	var dock := McpDockScript.new()
	dock.present_client_work_snapshot({
		"busy_actions": ["ghost"],
		"action_names": {"ghost": "configure"},
		"action_phases": {"ghost": "prewarm"},
	})
	assert_true(true, "phase handling must tolerate a missing row")
	dock.free()


## Save/restore helpers so tests that drive the (now persisted) log toggle
## don't clobber the user's actual EditorSetting.
func _save_mcp_logging_setting() -> Dictionary:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting(McpSettings.SETTING_MCP_LOGGING):
		return {"had": true, "value": es.get_setting(McpSettings.SETTING_MCP_LOGGING)}
	return {"had": false}


func _restore_mcp_logging_setting(prev: Dictionary) -> void:
	var es := EditorInterface.get_editor_settings()
	if prev.get("had", false):
		es.set_setting(McpSettings.SETTING_MCP_LOGGING, prev.get("value"))
	else:
		es.erase(McpSettings.SETTING_MCP_LOGGING)


func test_log_viewer_snapshot_recovers_from_buffer_clear() -> void:
	## Regression: McpLogBuffer.clear() resets the monotonic
	## `total_logged()` counter to 0, flipping the sequence backward. The
	## viewer must detect that flip and clear its display — without the
	## reset marker, the view would retain the stale pre-clear presentation.
	var buffer := McpLogBuffer.new()
	buffer.log("before clear 1")
	buffer.log("before clear 2")
	var panel := LogViewerScript.new()
	panel.setup()
	var dock := McpDockScript.new()
	dock._log_viewer = panel
	var plugin := GodotAiPlugin.new()
	plugin._dock = dock
	plugin._log_buffer = buffer
	plugin._on_dock_log_snapshot_requested(panel.sequence())
	## Display contract: at least the two pre-clear lines are visible. Use
	## get_parsed_text() because RichTextLabel.text reflects BBCode source,
	## not what add_text() renders.
	assert_contains(panel._log_display.get_parsed_text(), "before clear 1",
		"precondition: pre-clear lines must paint into the display")
	assert_contains(panel._log_display.get_parsed_text(), "before clear 2")
	assert_eq(panel._last_log_seq, 2,
		"precondition: cursor must track the root's sequence snapshot")

	## The bug: buffer is cleared while the panel is still showing the
	## pre-clear lines. The root marks the backward sequence as a reset so the
	## copied presentation cannot stay stale.
	buffer.clear()
	plugin._on_dock_log_snapshot_requested(panel.sequence())
	assert_eq(panel._log_display.get_parsed_text(), "",
		"display must clear when total_logged() drops below _last_log_seq")
	assert_eq(panel._last_log_seq, 0,
		"cursor must reset to 0 so subsequent snapshots paint from a clean slate")

	## After the recovery branch, new lines must paint normally — i.e. the
	## next round of appends through the same panel doesn't lose lines or
	## duplicate them.
	buffer.log("after clear 1")
	buffer.log("after clear 2")
	plugin._on_dock_log_snapshot_requested(panel.sequence())
	assert_contains(panel._log_display.get_parsed_text(), "after clear 1")
	assert_contains(panel._log_display.get_parsed_text(), "after clear 2")
	assert_false(panel._log_display.get_parsed_text().contains("before clear"),
		"pre-clear lines must not reappear after the recovery + re-paint")
	assert_eq(panel._last_log_seq, 2)
	plugin._dock = null
	dock._log_viewer = null
	plugin.free()
	dock.free()
	panel.free()


func test_log_viewer_snapshot_keeps_painting_after_buffer_caps_at_max_lines() -> void:
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
	panel.setup()
	var dock := McpDockScript.new()
	dock._log_viewer = panel
	var plugin := GodotAiPlugin.new()
	plugin._dock = dock
	plugin._log_buffer = buffer
	plugin._on_dock_log_snapshot_requested(panel.sequence())
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
	plugin._on_dock_log_snapshot_requested(panel.sequence())
	assert_eq(buffer.total_count(), cap, "buffer size stays pinned at cap")
	assert_eq(buffer.total_logged(), cap + 1, "monotonic counter advances past cap")
	assert_contains(panel._log_display.get_parsed_text(), "at-cap canary",
		"new line after the buffer capped must reach the display")
	assert_eq(panel._last_log_seq, cap + 1,
		"viewer cursor must advance with the monotonic counter, not the bounded size")
	plugin._dock = null
	dock._log_viewer = null
	plugin.free()
	dock.free()
	panel.free()


# --- Dev-section primary + stop buttons ---------------------------------

func test_uv_version_display_hides_trailing_build_metadata() -> void:
	var full_version := "uv-tool-uvx 0.5.9 (0652800cb 2024-12-13)"
	assert_eq(
		McpDockScript._compact_uv_version_text(full_version),
		"uv-tool-uvx 0.5.9",
		"Setup's uv row should hide trailing build metadata from the visible value",
	)
	assert_eq(
		McpDockScript._compact_uv_version_text("uvx 0.5.9"),
		"uvx 0.5.9",
		"Setup's uv row should leave already-compact versions unchanged",
	)

	var row: HBoxContainer = _dock._make_status_row(
		"uv",
		McpDockScript._compact_uv_version_text(full_version),
		Color.GREEN,
		full_version
	)
	var value := row.get_child(1) as Label
	assert_eq(value.text, "uv-tool-uvx 0.5.9",
		"Visible uv row value should stay compact")
	assert_eq(value.tooltip_text, full_version,
		"Full uv version details should remain available as tooltip text")
	row.free()


func test_dev_buttons_rendered_in_dev_checkout() -> void:
	## Dev checkout's Setup section gets the primary managed-server
	## button + the small "✕" stop affordance side-by-side. In a non-dev
	## checkout (release install) the branch isn't entered and neither
	## button appears; we skip rather than fake the env.
	if not McpClientConfigurator.is_dev_checkout():
		skip("only meaningful in dev checkout")
		return
	_dock._build_ui()
	_dock._refresh_setup_status()
	assert_true(_dock._dev_primary_btn != null,
		"Dev checkout must render the primary button in the Setup section")
	assert_true(_dock._dev_stop_btn != null,
		"Dev checkout must render the stop button alongside the primary")
	assert_eq(_dock._dev_stop_btn.text, "✕",
		"Stop button uses the compact ✕ glyph")


func test_dev_buttons_visibility_follows_dev_mode_toggle() -> void:
	## Buttons live inside `_setup_section`, whose visibility is driven by
	## `_apply_dev_mode_visibility`. With Developer mode off in a dev
	## checkout the section hides — taking both buttons with it.
	if not McpClientConfigurator.is_dev_checkout():
		skip("only meaningful in dev checkout")
		return
	_dock._build_ui()
	_dock._dev_mode_toggle.button_pressed = true
	_dock._apply_dev_mode_visibility()
	_dock._refresh_setup_status()
	assert_true(_dock._setup_section.visible,
		"precondition: dev toggle on must show the Setup section")
	assert_true(_dock._dev_primary_btn != null,
		"Primary button must be in the Setup section when dev toggle is on")
	assert_true(_dock._dev_stop_btn != null,
		"Stop button must be in the Setup section when dev toggle is on")

	_dock._dev_mode_toggle.button_pressed = false
	_dock._apply_dev_mode_visibility()
	assert_false(_dock._setup_section.visible,
		"dev toggle off must hide the Setup section, hiding both dev buttons")


func test_setup_section_should_show_truth_table() -> void:
	## #744: the Install-uv Setup section must not appear while the server
	## launch is still settling — only dev mode, or uv missing once the
	## launch outcome is known, shows it.
	assert_true(McpDockScript._setup_section_should_show(true, false, false),
		"Dev toggle alone must show the Setup section")
	assert_true(McpDockScript._setup_section_should_show(true, true, true),
		"Dev toggle must win even mid-launch")
	assert_true(McpDockScript._setup_section_should_show(false, true, false),
		"uv missing after the launch settled must show the section")
	assert_false(McpDockScript._setup_section_should_show(false, true, true),
		"uv missing mid-launch must NOT show the section (#744)")
	assert_false(McpDockScript._setup_section_should_show(false, false, false),
		"dev off + uv present must hide the section")


func test_server_launch_pending_tracks_state_connection_and_grace() -> void:
	_dock._last_connected = false
	_dock._startup_grace_until_msec = Time.get_ticks_msec() + 10_000

	_dock.present_lifecycle_snapshot({"state": McpServerState.SPAWNING})
	assert_true(_dock._server_launch_pending(),
		"Spawning inside the grace window is a pending launch")

	_dock.present_lifecycle_snapshot({"state": McpServerState.UNINITIALIZED})
	assert_true(_dock._server_launch_pending(),
		"Uninitialized inside the grace window is a pending launch")

	_dock.present_lifecycle_snapshot({"state": McpServerState.CRASHED})
	assert_false(_dock._server_launch_pending(),
		"A terminal diagnosis settles the launch even inside grace")

	_dock.present_lifecycle_snapshot({"state": McpServerState.NO_COMMAND})
	assert_false(_dock._server_launch_pending(),
		"NO_COMMAND settles the launch — that's exactly when Install uv helps")

	_dock.present_lifecycle_snapshot({"state": McpServerState.SPAWNING})
	_dock._last_connected = true
	assert_false(_dock._server_launch_pending(),
		"A committed connection settles the launch")

	_dock._last_connected = false
	_dock._startup_grace_until_msec = Time.get_ticks_msec() - 1
	assert_false(_dock._server_launch_pending(),
		"Grace expiry settles the launch (the status row shows Disconnected)")

	## Reset shared-suite state so later tests see the defaults.
	_dock._startup_grace_until_msec = 0
	_dock.present_lifecycle_snapshot({})


## Mirrors `_seed_server_row` / `_cleanup_server_row`: stand up just enough
## of the dock for the per-frame button helpers to run without a full
## `_build_ui` pass.
func _seed_dev_buttons(
	managed := false, external := false, normal_start_released := true
) -> void:
	_dock.present_lifecycle_snapshot({
		"server_pid": 4242 if managed else -1,
		"ready_kind": "adopted" if external else ("owned" if managed else ""),
		"state": McpServerState.READY if (managed or external) else McpServerState.STOPPED,
		"normal_start_released": normal_start_released,
	})
	_dock._dev_primary_btn = Button.new()
	_dock._dev_stop_btn = Button.new()


func _cleanup_dev_buttons() -> void:
	_dock._dev_primary_btn.free()
	_dock._dev_primary_btn = null
	_dock._dev_stop_btn.free()
	_dock._dev_stop_btn = null
	_dock.present_lifecycle_snapshot({})


func test_primary_btn_dispatches_to_force_restart_or_start() -> void:
	var recorder := _IntentRecorder.new()
	_dock.dev_server_action_requested.connect(recorder.on_dev_server_action)
	_seed_dev_buttons(true, false)

	_dock._on_dev_primary_pressed()
	var calls: int = recorder.primary_calls

	_cleanup_dev_buttons()
	assert_eq(calls, 1,
		"Click must request managed start/restart exactly once")


func test_stop_btn_dispatches_to_stop_managed_server() -> void:
	var recorder := _IntentRecorder.new()
	_dock.dev_server_action_requested.connect(recorder.on_dev_server_action)
	_seed_dev_buttons(true, false)

	_dock._on_dev_stop_pressed()
	var calls: int = recorder.stop_calls

	_cleanup_dev_buttons()
	assert_eq(calls, 1, "Stop click must request managed stop exactly once")


func test_primary_btn_label_when_nothing_running() -> void:
	## Per-frame refresh must reflect the live plugin state. With nothing
	## running, the primary button is enabled (a click spawns fresh) and
	## reads "Start Managed Server".
	_seed_dev_buttons()

	_dock._update_dev_section_buttons()
	var primary_text: String = _dock._dev_primary_btn.text
	var primary_disabled: bool = _dock._dev_primary_btn.disabled
	var stop_disabled: bool = _dock._dev_stop_btn.disabled

	_cleanup_dev_buttons()
	assert_eq(primary_text, "Start Managed Server")
	assert_false(primary_disabled,
		"Primary stays enabled even with nothing running — click spawns fresh")
	assert_true(stop_disabled,
		"Stop has no target when nothing's running — must be disabled")


func test_primary_btn_label_when_managed_running() -> void:
	_seed_dev_buttons(true, false)

	_dock._update_dev_section_buttons()
	var primary_text: String = _dock._dev_primary_btn.text
	var primary_disabled: bool = _dock._dev_primary_btn.disabled
	var stop_disabled: bool = _dock._dev_stop_btn.disabled

	_cleanup_dev_buttons()
	assert_eq(primary_text, "Restart Managed Server",
		"Managed running means click will kill+respawn — label says Restart")
	assert_false(stop_disabled,
		"Stop is enabled only because the lifecycle owns an exact process grant")


func test_primary_btn_disables_for_external_server() -> void:
	_seed_dev_buttons(false, true)

	_dock._update_dev_section_buttons()
	var primary_text: String = _dock._dev_primary_btn.text
	var primary_disabled: bool = _dock._dev_primary_btn.disabled
	var stop_disabled: bool = _dock._dev_stop_btn.disabled

	_cleanup_dev_buttons()
	assert_eq(primary_text, "External Server Running")
	assert_true(primary_disabled,
		"An adopted external server must remain the launcher's responsibility")
	assert_true(stop_disabled,
		"The plugin has no process authority for an external server")


func test_pending_migration_disables_dev_start_but_keeps_owned_stop() -> void:
	_seed_dev_buttons(true, false, false)

	_dock._update_dev_section_buttons()
	var primary_text: String = _dock._dev_primary_btn.text
	var primary_disabled: bool = _dock._dev_primary_btn.disabled
	var stop_disabled: bool = _dock._dev_stop_btn.disabled

	_cleanup_dev_buttons()
	assert_eq(primary_text, "Server Start Blocked")
	assert_true(primary_disabled,
		"Pending post-update M6 must disable every server-start control")
	assert_false(stop_disabled,
		"The exact owned server can still be stopped while M6 is pending")


func test_primary_btn_shows_restarting_state_during_dispatch() -> void:
	## The flag is set before dispatch and cleared after the lifecycle has had
	## a bounded repaint window.
	_seed_dev_buttons(true, false)
	_dock._dev_primary_btn.text = "Restart Managed Server"

	_dock._server_restart_in_progress = true
	_dock._update_dev_section_buttons()
	var mid_text: String = _dock._dev_primary_btn.text
	var mid_disabled: bool = _dock._dev_primary_btn.disabled
	var stop_disabled_during: bool = _dock._dev_stop_btn.disabled

	_dock._server_restart_in_progress = false
	_dock._update_dev_section_buttons()
	var post_text: String = _dock._dev_primary_btn.text
	var post_disabled: bool = _dock._dev_primary_btn.disabled

	_cleanup_dev_buttons()
	assert_contains(mid_text, "Restarting",
		"In-flight click must replace label with Restarting…")
	assert_true(mid_disabled, "In-flight click must disable the primary button")
	assert_true(stop_disabled_during,
		"Stop must also disable while a restart is in flight")
	assert_eq(post_text, "Restart Managed Server",
		"Once the flag clears, primary label reverts")
	assert_false(post_disabled,
		"Cleared flag with managed server still up must re-enable the primary")


func test_tool_catalog_is_excludable_domain_filters_unknown_names() -> void:
	## The startup path (ClientConfigurator.excluded_domains) drops names
	## McpToolCatalog doesn't know so a stale setting can't reach the
	## server's --exclude-domains, whose parse_exclude_list hard-fails.
	assert_true(McpToolCatalog.is_excludable_domain("audio"),
		"a real domain must be excludable")
	assert_true(McpToolCatalog.is_excludable_domain("tileset"),
		"a recently-added domain must be excludable")
	assert_false(McpToolCatalog.is_excludable_domain("session"),
		"session is core-only and never excludable")
	assert_false(McpToolCatalog.is_excludable_domain("bogus_removed_domain"),
		"a name no longer in the catalog must be rejected")
	assert_false(McpToolCatalog.is_excludable_domain(""),
		"empty is not a domain")


func test_server_ownership_tag_distinguishes_backend_flavor() -> void:
	## #838/#816 step 11: the server line names which backend flavor the
	## editor is riding. Display only — external adoption clears PID
	## authority, so this text is never kill proof (#669).
	assert_eq(McpDockScript._server_ownership_tag(McpServerState.READY, 12345), "plugin-managed backend")
	assert_eq(McpDockScript._server_ownership_tag(McpServerState.READY, -1), "externally adopted backend")
	assert_eq(McpDockScript._server_ownership_tag(McpServerState.UNINITIALIZED, 12345), "",
		"no tag before the lifecycle reaches READY")
	assert_eq(McpDockScript._server_ownership_tag(McpServerState.CRASHED, -1), "",
		"terminal diagnoses keep the plain ports label")


func test_client_transport_tag_tracks_descriptor_shape() -> void:
	## #838: the row tag must always agree with what Configure writes, so it
	## derives from descriptor command_shape — attach for every advertised client.
	assert_eq(McpDockScript._client_transport_tag("cursor"), "attach")
	assert_eq(McpDockScript._client_transport_tag("claude_code"), "attach", "CLI clients register attach too")
	assert_eq(McpDockScript._client_transport_tag("hermes"), "attach", "YAML clients included")
	assert_eq(McpDockScript._client_transport_tag("codex"), "attach",
		"TOML COMMAND_ARRAY clients tag attach too")
	assert_eq(McpDockScript._client_transport_tag("__missing_client__"), "")
