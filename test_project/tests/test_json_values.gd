@tool
extends McpTestSuite

## Tests for McpJsonValues — the canonical JSON→Variant parsers behind the
## five formerly-drifted per-handler copies (#714). The canonical color set
## is the maintainer decision on that issue: hex/named strings, {r,g,b[,a]}
## dicts, and [r,g,b(,a)] arrays, strict within each shape.


func suite_name() -> String:
	return "json_values"


# ----- parse_color -----

func test_color_passthrough() -> void:
	assert_eq(McpJsonValues.parse_color(Color.RED), Color.RED)


func test_color_hex_and_named_strings() -> void:
	assert_eq(McpJsonValues.parse_color("#ff0000"), Color(1, 0, 0, 1))
	assert_eq(McpJsonValues.parse_color("#ff000080"), Color("#ff000080"))
	assert_eq(McpJsonValues.parse_color("red"), Color.RED)


func test_color_rejects_unparseable_string() -> void:
	assert_eq(McpJsonValues.parse_color("Color(1,1,1,1)"), null)
	assert_eq(McpJsonValues.parse_color("not-a-color"), null)


func test_color_dict_with_and_without_alpha() -> void:
	assert_eq(McpJsonValues.parse_color({"r": 0.25, "g": 0.5, "b": 0.75}), Color(0.25, 0.5, 0.75, 1.0))
	assert_eq(McpJsonValues.parse_color({"r": 1, "g": 0, "b": 0, "a": 0.5}), Color(1, 0, 0, 0.5))


func test_color_dict_rejects_wrong_keys_and_non_numeric() -> void:
	assert_eq(McpJsonValues.parse_color({"red": 1, "green": 0, "blue": 0}), null)
	assert_eq(McpJsonValues.parse_color({"r": 1, "g": 0}), null)
	assert_eq(McpJsonValues.parse_color({"r": "1", "g": 0, "b": 0}), null)


func test_color_array_with_and_without_alpha() -> void:
	assert_eq(McpJsonValues.parse_color([1, 0, 0]), Color(1, 0, 0, 1))
	assert_eq(McpJsonValues.parse_color([0.1, 0.2, 0.3, 0.4]), Color(0.1, 0.2, 0.3, 0.4))


func test_color_array_rejects_wrong_length_and_non_numeric() -> void:
	assert_eq(McpJsonValues.parse_color([1, 0]), null)
	assert_eq(McpJsonValues.parse_color([1, 0, 0, 1, 9]), null)
	assert_eq(McpJsonValues.parse_color(["1", 0, 0]), null)


# ----- parse_vector2 / parse_vector3 -----

func test_vector2_shapes() -> void:
	assert_eq(McpJsonValues.parse_vector2(Vector2(1, 2)), Vector2(1, 2))
	assert_eq(McpJsonValues.parse_vector2({"x": 1, "y": 2}), Vector2(1, 2))
	assert_eq(McpJsonValues.parse_vector2([1.5, 2.5]), Vector2(1.5, 2.5))


func test_vector2_rejects_wrong_shapes() -> void:
	## Missing keys must not become zeros (#123/#126 strict contract).
	assert_eq(McpJsonValues.parse_vector2({"x": 1}), null)
	assert_eq(McpJsonValues.parse_vector2({"x": 1, "z": 2}), null)
	assert_eq(McpJsonValues.parse_vector2([1]), null)
	assert_eq(McpJsonValues.parse_vector2([1, 2, 3]), null)
	assert_eq(McpJsonValues.parse_vector2({"x": "1", "y": 2}), null)
	assert_eq(McpJsonValues.parse_vector2("1,2"), null)


func test_vector3_shapes() -> void:
	assert_eq(McpJsonValues.parse_vector3(Vector3(1, 2, 3)), Vector3(1, 2, 3))
	assert_eq(McpJsonValues.parse_vector3({"x": 1, "y": 2, "z": 3}), Vector3(1, 2, 3))
	assert_eq(McpJsonValues.parse_vector3([1, 2, 3]), Vector3(1, 2, 3))


func test_vector3_rejects_wrong_shapes() -> void:
	assert_eq(McpJsonValues.parse_vector3({"x": 1, "y": 2}), null)
	assert_eq(McpJsonValues.parse_vector3([1, 2]), null)
	assert_eq(McpJsonValues.parse_vector3([1, 2, 3, 4]), null)
	assert_eq(McpJsonValues.parse_vector3({"x": 1, "y": 2, "z": "3"}), null)


# ----- delegation spot checks: the handler copies now share one parser -----

func test_material_theme_parsers_accept_arrays() -> void:
	## Pre-#714 drift: material accepted [r,g,b] arrays while theme rejected
	## them. Both now share the canonical parser.
	var mat_script := preload("res://addons/godot_ai/handlers/material_values.gd")
	assert_eq(mat_script.parse_color([1, 0, 0]), Color(1, 0, 0, 1))
	var theme_script := preload("res://addons/godot_ai/handlers/theme_handler.gd")
	assert_eq(theme_script._parse_color([0, 1, 0]), Color(0, 1, 0, 1))


func test_camera_vector2_keeps_uniform_zoom_splat() -> void:
	var cam_script := preload("res://addons/godot_ai/handlers/camera_values.gd")
	assert_eq(cam_script.parse_vector2(2.0), Vector2(2, 2))
	assert_eq(cam_script.parse_vector2({"x": 1, "y": 2}), Vector2(1, 2))
	assert_eq(cam_script.parse_vector2({"x": 1}), null, "strict dict contract applies to camera too")


func test_animation_serialize_value_round_trips_quaternion() -> void:
	## Pre-#714 drift: the private serialize_value copy stringified
	## rotation_3d keyframe Quaternions into opaque text. The shared
	## serializer emits the {x,y,z,w} dict callers can round-trip.
	var anim_script := preload("res://addons/godot_ai/handlers/animation_values.gd")
	var q := Quaternion(0.1, 0.2, 0.3, 0.9273618)
	var serialized: Variant = anim_script.serialize_value(q)
	assert_true(serialized is Dictionary, "Quaternion must serialize to a dict, not str()")
	assert_true(abs(float(serialized.x) - 0.1) < 0.0001)
	assert_true(abs(float(serialized.w) - 0.9273618) < 0.0001)
