@tool
extends McpTestSuite

const VariantSerializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")

## Tests for McpVariantSerializer's JSON-safety contract, in particular the
## #688 non-finite-float clamp: NaN/INF must serialize as null, never reach
## JSON.stringify as bare `inf`/`nan` tokens (invalid JSON — the server drops
## the whole frame and the request times out).


func suite_name() -> String:
	return "variant_serializer"


func test_finite_float_passes_through() -> void:
	assert_eq(VariantSerializer.serialize(1.5), 1.5)
	assert_eq(VariantSerializer.serialize(-0.25), -0.25)
	assert_eq(VariantSerializer.serialize(0.0), 0.0)


func test_nan_serializes_as_null() -> void:
	assert_eq(VariantSerializer.serialize(NAN), null,
		"NaN has no JSON representation and must clamp to null (#688)")


func test_inf_serializes_as_null() -> void:
	assert_eq(VariantSerializer.serialize(INF), null)
	assert_eq(VariantSerializer.serialize(-INF), null)


func test_vector2_with_nan_component_clamps_component() -> void:
	var out: Dictionary = VariantSerializer.serialize(Vector2(NAN, 2.0))
	assert_eq(out.x, null, "NaN component must clamp to null, not leak into JSON")
	assert_eq(out.y, 2.0)


func test_vector3_with_inf_component_clamps_component() -> void:
	var out: Dictionary = VariantSerializer.serialize(Vector3(1.0, INF, 3.0))
	assert_eq(out.x, 1.0)
	assert_eq(out.y, null)
	assert_eq(out.z, 3.0)


func test_vector2i_components_stay_ints() -> void:
	var out: Dictionary = VariantSerializer.serialize(Vector2i(3, -7))
	assert_true(out.x is int, "int vector components must not be coerced to float")
	assert_eq(out.x, 3)
	assert_eq(out.y, -7)


func test_quaternion_with_nan_component_clamps_component() -> void:
	var out: Dictionary = VariantSerializer.serialize(Quaternion(NAN, 0.0, 0.0, 1.0))
	assert_eq(out.x, null)
	assert_eq(out.w, 1.0)


func test_color_with_nan_channel_clamps_channel() -> void:
	var out: Dictionary = VariantSerializer.serialize(Color(NAN, 0.5, 0.25, 1.0))
	assert_eq(out.r, null)
	assert_eq(out.g, 0.5)


func test_plane_with_inf_d_clamps_d() -> void:
	var out: Dictionary = VariantSerializer.serialize(Plane(Vector3.UP, 0.0))
	assert_eq(out.d, 0.0)
	var bad := Plane(Vector3(0, 1, 0), INF)
	var bad_out: Dictionary = VariantSerializer.serialize(bad)
	assert_eq(bad_out.d, null)


func test_nested_dict_with_nan_clamps() -> void:
	var out: Dictionary = VariantSerializer.serialize({"speed": NAN, "name": "x"})
	assert_eq(out.speed, null)
	assert_eq(out.name, "x")


func test_array_with_inf_clamps_element() -> void:
	var out: Array = VariantSerializer.serialize([1.0, INF, 3.0])
	assert_eq(out[0], 1.0)
	assert_eq(out[1], null)
	assert_eq(out[2], 3.0)


func test_packed_float_array_with_nan_clamps_element() -> void:
	var out: Array = VariantSerializer.serialize(PackedFloat64Array([1.0, NAN]))
	assert_eq(out[0], 1.0)
	assert_eq(out[1], null)


func test_serialized_nan_payload_survives_json_roundtrip() -> void:
	## End-to-end shape of the #688 failure: a node property dict containing
	## NaN must stringify to VALID json (parse_string returns non-null).
	## Pre-clamp, JSON.stringify emitted a bare `nan` token and the server
	## dropped the frame.
	var payload: Variant = VariantSerializer.serialize({
		"position": Vector2(NAN, INF),
		"health": NAN,
		"scale": 1.0,
	})
	var text := JSON.stringify(payload)
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed != null, "serialized payload must be valid JSON (got: %s)" % text)
	assert_eq(parsed.health, null)
	assert_eq(parsed.scale, 1.0)
	assert_eq(parsed.position.x, null)
	assert_eq(parsed.position.y, null)
