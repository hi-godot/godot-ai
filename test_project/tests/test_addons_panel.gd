@tool
extends McpTestSuite

const AddonsPanel := preload("res://addons/godot_ai/dock_panels/addons_panel.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")

var _panel: ScrollContainer
var _dock: Node
var _saved_registry: McpToolRegistry


func suite_name() -> String:
	return "addons_panel"


func suite_setup(_ctx: Dictionary) -> void:
	_saved_registry = McpToolRegistry.get_instance()


func suite_teardown() -> void:
	McpToolRegistry._instance = _saved_registry
	if _panel != null:
		_panel.free()
	if _dock != null:
		_dock.free()


func _make_panel() -> void:
	if _panel != null:
		_panel.free()
	_panel = AddonsPanel.new()
	_panel.setup(Color.GRAY)


func test_catalog_displays_available_addons_without_a_tool_registry() -> void:
	McpToolRegistry._instance = null
	_make_panel()
	McpToolRegistry._instance = _saved_registry
	var terrain := _panel.get_node("Catalog/terrain_tools/Margin/Details")
	var animation := _panel.get_node("Catalog/animation_toolkit/Margin/Details")
	assert_eq(terrain.get_node("Title").text, "Godot AI Terrain Tools")
	assert_eq(animation.get_node("Title").text, "Godot AI Animation Toolkit")
	assert_eq(terrain.get_node("Author").text, "By michaltomczykowski")
	assert_contains(terrain.get_node("Description").text, "terrain")
	assert_contains(animation.get_node("Description").text, "animation")
	assert_eq(terrain.get_node("Requirements").text, "Godot 4.7+ · Godot AI 4.1+")
	assert_eq(animation.get_node("Requirements").text, "Godot 4.7 · Godot AI 4.1+")


func test_catalog_links_emit_the_correct_browser_destinations() -> void:
	_make_panel()
	var opened: Array[String] = []
	_panel.link_requested.connect(func(url: String): opened.append(url))
	for id in ["terrain_tools", "animation_toolkit"]:
		var links := _panel.get_node("Catalog/" + id + "/Margin/Details/Links")
		for button in links.get_children():
			button.pressed.emit()
	_panel.get_node("Catalog/CommunityDirectory").pressed.emit()
	var expected: Array[String] = [
		"https://github.com/michaltomczykowski/godot-ai-terrain-tools",
		"https://github.com/michaltomczykowski/godot-ai-terrain-tools/releases",
		"https://github.com/michaltomczykowski/godot-ai-terrain-tools#installation",
		"https://github.com/michaltomczykowski/godot-ai-animation-toolkit",
		"https://github.com/michaltomczykowski/godot-ai-animation-toolkit/releases",
		"https://github.com/michaltomczykowski/godot-ai-animation-toolkit#install",
		"https://github.com/hi-godot/godot-ai/blob/main/docs/community-addons.md",
	]
	assert_eq(opened, expected, "Clicks should open instructions and release pages, not install addons")


func test_catalog_wraps_and_scrolls_at_small_window_sizes() -> void:
	_make_panel()
	assert_eq(_panel.horizontal_scroll_mode, ScrollContainer.SCROLL_MODE_DISABLED)
	assert_eq(_panel.size_flags_vertical, Control.SIZE_EXPAND_FILL)
	var details := _panel.get_node("Catalog/animation_toolkit/Margin/Details")
	assert_eq(details.get_node("Description").autowrap_mode, TextServer.AUTOWRAP_WORD_SMART)
	assert_true(details.get_node("Links") is HFlowContainer, "Browser buttons should wrap with the window")


func test_browse_from_empty_tools_selects_addons_and_preserves_existing_tabs() -> void:
	McpToolRegistry._instance = null
	_dock = Dock.new()
	_dock.hide()
	EditorInterface.get_base_control().add_child(_dock)
	McpToolRegistry._instance = _saved_registry
	var tabs := _dock._clients_window.get_child(0) as TabContainer
	assert_eq(tabs.get_tab_count(), 4)
	assert_eq(tabs.get_tab_title(0), "Clients")
	assert_eq(tabs.get_tab_title(1), "Tools")
	assert_eq(tabs.get_tab_title(2), "Settings")
	assert_eq(tabs.get_tab_title(3), "Addons")
	assert_contains(_dock._custom_tools_list.get_child(0).text, "No custom tools registered")
	tabs.current_tab = 1
	assert_eq(tabs.current_tab, 1, "precondition: the live tab container selects Tools")
	_dock._browse_addons_btn.pressed.emit()
	assert_eq(tabs.current_tab, 3, "Browse should navigate even before any addon is installed")
