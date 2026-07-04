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


# ----- input_mouse position resolution (#635) -----

func test_input_mouse_position_dict() -> void:
	var r: Dictionary = _helper.call("_resolve_mouse_position", {"x": 12.0, "y": 34.0})
	assert_false(r.has("error"), "valid dict must not error")
	assert_eq(r.position, Vector2(12, 34))


func test_input_mouse_position_array_coerces() -> void:
	## Arrays [x, y] are accepted as a coercion, matching the dict-or-array
	## flexibility elsewhere in the tool surface.
	var r: Dictionary = _helper.call("_resolve_mouse_position", [56.0, 78.0])
	assert_false(r.has("error"), "2-element array must not error")
	assert_eq(r.position, Vector2(56, 78))


func test_input_mouse_position_absent_falls_back() -> void:
	## Omitting position (null) is a deliberate default: use the live cursor.
	var r: Dictionary = _helper.call("_resolve_mouse_position", null)
	assert_false(r.has("error"), "absent position must fall back, not error")
	assert_true(r.has("position"))


func test_input_mouse_position_malformed_array_rejected() -> void:
	var r: Dictionary = _helper.call("_resolve_mouse_position", [1.0, 2.0, 3.0])
	assert_true(r.has("error"), "3-element array must be rejected, not silently substituted")
	## A rejection must NOT also hand back a fallback position — otherwise a
	## regression could silently substitute cursor coords despite the error.
	assert_false(r.has("position"), "rejected input must not carry a fallback position")


func test_input_mouse_position_wrong_type_rejected() -> void:
	## #635: a present but wrong-shaped position (here a bare number) must be
	## rejected instead of silently falling back to the cursor, which hid
	## caller bugs.
	var r: Dictionary = _helper.call("_resolve_mouse_position", 42.0)
	assert_true(r.has("error"), "scalar position must be rejected")
	assert_false(r.has("position"), "rejected input must not carry a fallback position")


func test_input_mouse_position_empty_dict_falls_back() -> void:
	## An empty {} is treated as "unspecified" (like absent) and falls back.
	var r: Dictionary = _helper.call("_resolve_mouse_position", {})
	assert_false(r.has("error"), "empty dict must fall back, not error")
	assert_true(r.has("position"))


func test_input_mouse_position_dict_without_xy_rejected() -> void:
	## Copilot review: a NON-empty dict carrying neither coordinate (e.g.
	## {"foo": 1}) is a caller mistake, not a request for the default — reject
	## it instead of silently substituting the cursor.
	var r: Dictionary = _helper.call("_resolve_mouse_position", {"foo": 1})
	assert_true(r.has("error"), "non-empty dict without x/y must be rejected")
	assert_false(r.has("position"))


func test_input_mouse_position_non_numeric_rejected() -> void:
	## Copilot review: non-numeric coordinates must be rejected rather than
	## coerced through float() (which would silently produce 0.0).
	var r_dict: Dictionary = _helper.call("_resolve_mouse_position", {"x": "left", "y": 5})
	assert_true(r_dict.has("error"), "non-numeric dict x must be rejected")
	assert_false(r_dict.has("position"))
	var r_arr: Dictionary = _helper.call("_resolve_mouse_position", ["a", "b"])
	assert_true(r_arr.has("error"), "non-numeric array elements must be rejected")
	assert_false(r_arr.has("position"))


func test_input_mouse_position_partial_dict_uses_number() -> void:
	## A partial dict with one numeric coordinate is still valid — the missing
	## axis defaults to the current cursor. (x present and numeric here.)
	var r: Dictionary = _helper.call("_resolve_mouse_position", {"x": 7})
	assert_false(r.has("error"), "partial numeric dict must not error")
	assert_eq(r.position.x, 7.0)
