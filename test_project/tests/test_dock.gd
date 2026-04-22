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


func test_drift_banner_hidden_when_no_drift() -> void:
	_dock._build_ui()
	# Fresh dock with everything NOT_CONFIGURED by default → banner stays hidden.
	_dock._refresh_drift_banner(0)
	assert_false(_dock._drift_banner.visible, "Banner must stay hidden when no clients drifted")


func test_drift_banner_visible_with_count_and_port() -> void:
	_dock._build_ui()
	_dock._refresh_drift_banner(3)
	assert_true(_dock._drift_banner.visible, "Banner must surface when any client drifted")
	# Label cites the drifted count and the current port so the user knows
	# which server the reconfigure will point at. Prevents head-scratching
	# about "3 clients drifted but drifted from what?".
	var text: String = _dock._drift_label.text
	assert_contains(text, "3")
	assert_contains(text, str(McpClientConfigurator.http_port()))


func test_drift_banner_singular_vs_plural() -> void:
	_dock._build_ui()
	_dock._refresh_drift_banner(1)
	assert_contains(_dock._drift_label.text, "1 client ", "Singular count must not pluralize")
	_dock._refresh_drift_banner(2)
	assert_contains(_dock._drift_label.text, "2 clients", "Plural count must pluralize")


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
