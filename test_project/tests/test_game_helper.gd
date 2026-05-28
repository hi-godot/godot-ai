@tool
extends McpTestSuite

const GameHelper := preload("res://addons/godot_ai/runtime/game_helper.gd")

const ROOT_NAME := "McpUiElementsRoot"


class PropertyProbe:
	extends Object

	static var property_list_calls := 0

	func _get_property_list() -> Array[Dictionary]:
		property_list_calls += 1
		return [{
			"name": "probe_value",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
		}]


class AlphaProbe:
	extends Object

	func _get_property_list() -> Array[Dictionary]:
		return [{
			"name": "alpha_value",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
		}]


class BetaProbe:
	extends Object

	func _get_property_list() -> Array[Dictionary]:
		return [{
			"name": "beta_value",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
		}]


var _helper: Node
var _root: Node


func suite_name() -> String:
	return "game_helper"


func suite_setup(_ctx: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		fail_setup("current_scene required")
		return
	_helper = GameHelper.new()
	scene_root.add_child(_helper)
	_root = CanvasLayer.new()
	_root.name = ROOT_NAME
	scene_root.add_child(_root)


func suite_teardown() -> void:
	if _root != null:
		_root.queue_free()
		_root = null
	if _helper != null:
		_helper.queue_free()
		_helper = null


func setup() -> void:
	if _root == null:
		return
	for child in _root.get_children():
		_root.remove_child(child)
		child.free()


func test_object_has_property_caches_property_lists_by_script() -> void:
	_helper._property_name_cache.clear()
	PropertyProbe.property_list_calls = 0
	var probe := PropertyProbe.new()

	assert_true(_helper.call("_object_has_property", probe, "probe_value"))
	assert_true(_helper.call("_object_has_property", probe, "probe_value"))
	assert_eq(PropertyProbe.property_list_calls, 1)

	assert_true(_helper.call("_object_has_property", AlphaProbe.new(), "alpha_value"))
	assert_false(_helper.call("_object_has_property", AlphaProbe.new(), "beta_value"))
	assert_true(_helper.call("_object_has_property", BetaProbe.new(), "beta_value"))
	assert_false(_helper.call("_object_has_property", BetaProbe.new(), "alpha_value"))


func test_get_ui_elements_returns_controls_with_text_and_rects() -> void:
	assert_true(_helper.has_method("_game_get_ui_elements"),
		"game helper should expose get_ui_elements")
	var container := Node.new()
	container.name = "Container"
	_root.add_child(container)

	var title := Label.new()
	title.name = "Title"
	title.text = "Score: 10"
	title.position = Vector2(10, 20)
	title.size = Vector2(120, 30)
	container.add_child(title)

	var button := Button.new()
	button.name = "StartButton"
	button.text = "Start"
	button.disabled = true
	button.position = Vector2(20, 60)
	button.size = Vector2(90, 40)
	container.add_child(button)

	var result = _helper.call("_game_get_ui_elements", {
		"root_path": "/Main/%s" % ROOT_NAME,
		"include_hidden": true,
		"max_depth": 4,
	})

	assert_true(result is Dictionary, "get_ui_elements should return a Dictionary")
	assert_eq(result.root, "/Main/%s" % ROOT_NAME)
	assert_eq(result.total_count, 2)
	assert_eq(result.elements[0].name, "Title")
	assert_eq(result.elements[0].type, "Label")
	assert_eq(result.elements[0].text, "Score: 10")
	assert_has_key(result.elements[0], "visible")
	assert_eq(result.elements[0].disabled, false)
	assert_eq(result.elements[0].rect.position.x, 10.0)
	assert_eq(result.elements[0].rect.size.y, 30.0)
	assert_eq(result.elements[1].name, "StartButton")
	assert_eq(result.elements[1].disabled, true)
	assert_eq(result.elements[1].text, "Start")


func test_get_ui_elements_can_filter_disabled_and_include_hidden() -> void:
	assert_true(_helper.has_method("_game_get_ui_elements"),
		"game helper should expose get_ui_elements")
	var visible_enabled := LineEdit.new()
	visible_enabled.name = "NameInput"
	visible_enabled.text = "Ada"
	_root.add_child(visible_enabled)

	var disabled_button := Button.new()
	disabled_button.name = "DisabledButton"
	disabled_button.disabled = true
	_root.add_child(disabled_button)

	var hidden_label := Label.new()
	hidden_label.name = "HiddenButIncluded"
	hidden_label.text = "Hidden"
	hidden_label.visible = false
	_root.add_child(hidden_label)

	var result = _helper.call("_game_get_ui_elements", {
		"root_path": "/Main/%s" % ROOT_NAME,
		"include_hidden": true,
		"include_disabled": false,
		"max_depth": 1,
	})

	assert_true(result is Dictionary, "get_ui_elements should return a Dictionary")
	assert_eq(result.total_count, 2)
	var names := [result.elements[0].name, result.elements[1].name]
	assert_true(names.has("NameInput"), "enabled control should be included")
	assert_true(names.has("HiddenButIncluded"), "hidden control should be included when requested")
	assert_false(names.has("DisabledButton"), "disabled control should be filtered when requested")
