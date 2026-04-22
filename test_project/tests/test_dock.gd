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


func test_drift_banner_surfaces_mismatched_clients_with_url() -> void:
	## The banner copy must name the active server URL and the affected
	## clients so the user can immediately see what's stale. The amber
	## colour ties it visually to the per-row dot for the same clients.
	_dock._build_ui()
	_dock._refresh_drift_banner(["claude_code"] as Array[String])
	assert_true(_dock._drift_banner.visible, "Non-empty mismatched list must show banner")
	assert_contains(_dock._drift_label.text, McpClientConfigurator.http_url(),
		"Banner should mention the active server URL so the user knows what 'mismatched' means against")
	assert_contains(_dock._drift_label.text, "Claude Code",
		"Banner should list the display names of mismatched clients")


func test_drift_banner_no_op_when_mismatched_set_unchanged() -> void:
	## The banner caches the last mismatched set so that focus-in sweeps
	## that find the same drift don't repaint identical text. The cache
	## also powers `_on_reconfigure_mismatched`, so verifying it's
	## populated locks the contract in. See #166.
	_dock._build_ui()
	_dock._refresh_drift_banner(["claude_code"] as Array[String])
	assert_eq(_dock._last_mismatched_ids, ["claude_code"] as Array[String],
		"Cache must reflect the most recent sweep so the Reconfigure button can iterate it")
	var first_text := _dock._drift_label.text

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
