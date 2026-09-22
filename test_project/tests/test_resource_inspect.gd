@tool
extends McpTestSuite

const Inspector := preload("res://addons/godot_ai/utils/resource_inspector.gd")
const Handler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
var _handler: Handler
var _root: Node


func suite_name() -> String:
	return "resource_inspect"


func suite_setup(ctx: Dictionary) -> void:
	_handler = Handler.new(ctx.get("undo_redo"))
	_root = EditorInterface.get_edited_scene_root()
	if _root == null:
		fail_setup("Resource inspection tests require an edited scene")


func _attach(node: Node) -> String:
	track(node)
	node.name = "InspectFixture"
	_root.add_child(node)
	node.owner = _root
	return McpScenePath.from_node(node, _root)


func _has_reason(result: Dictionary, reason: String) -> bool:
	for entry in result.data.truncations:
		if entry.reason == reason:
			return true
	return false


func test_live_shape_dimensions_and_identity_unchanged() -> void:
	var node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2, 3, 4)
	node.shape = shape
	var path := _attach(node)
	var result := _handler.inspect_resource({"node_path": path, "property": "shape"})
	assert_has_key(result, "data")
	assert_eq(result.data.root, {"ref": "r1"})
	assert_eq(result.data.resources[0].type, "BoxShape3D")
	assert_eq(result.data.resources[0].properties.size, {"x": shape.size.x, "y": shape.size.y, "z": shape.size.z})
	assert_true(node.shape == shape, "Inspection keeps the exact resource reference")
	assert_eq(shape.size, Vector3(2, 3, 4))
	assert_true(shape.resource_path.is_empty(), "Inspection does not save a resource")


func test_native_mesh_and_physics_material_values() -> void:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.5
	mesh.bottom_radius = 1.25
	mesh.height = 3.0
	node.mesh = mesh
	var path := _attach(node)
	var result := _handler.inspect_resource({"node_path": path, "property": "mesh"})
	assert_eq(result.data.resources[0].properties.top_radius, mesh.top_radius)
	assert_eq(result.data.resources[0].properties.bottom_radius, mesh.bottom_radius)
	assert_eq(result.data.resources[0].properties.height, mesh.height)
	var material := PhysicsMaterial.new()
	material.friction = 0.625
	material.bounce = 0.25
	var inspected := Inspector.new().inspect(material, 2)
	assert_eq(inspected.data.resources[0].properties.friction, material.friction)
	assert_eq(inspected.data.resources[0].properties.bounce, material.bounce)


func test_shared_texture_and_nested_gradient_use_local_references() -> void:
	var material := StandardMaterial3D.new()
	var texture := GradientTexture2D.new()
	texture.gradient = Gradient.new()
	texture.width = 128
	material.albedo_texture = texture
	material.normal_texture = texture
	var result := Inspector.new().inspect(material, 3)
	var properties: Dictionary = result.data.resources[0].properties
	assert_eq(properties.albedo_texture, properties.normal_texture)
	assert_eq(properties.albedo_texture, {"ref": "r2"})
	assert_eq(result.data.resources[1].properties.width, texture.width)
	assert_eq(result.data.resources[1].properties.gradient, {"ref": "r3"})
	assert_eq(result.data.resources[2].properties.offsets, [0.0, 1.0])
	assert_eq(result.data.resources.size(), 3)
	assert_true(material.albedo_texture == material.normal_texture)


func test_depth_zero_summarizes_nested_resource() -> void:
	var mesh := BoxMesh.new()
	mesh.material = StandardMaterial3D.new()
	var result := Inspector.new().inspect(mesh, 0)
	assert_eq(result.data.resources[0].properties.material, {"ref": "r2"})
	assert_eq(result.data.resources[1].type, "StandardMaterial3D")
	assert_eq(result.data.resources[1].properties, {})
	assert_true(_has_reason(result, "depth"))


func test_unsupported_nested_resource_keeps_path_and_reason() -> void:
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	material.shader = shader
	shader.resource_path = "res://inspection-only.gdshader"
	var result := Inspector.new().inspect(material, 2)
	assert_eq(result.data.resources[0].properties.shader, {"ref": "r2"})
	assert_eq(result.data.resources[1].path, shader.resource_path)
	assert_eq(result.data.resources[1].type, "Shader")
	assert_true(_has_reason(result, "unsupported_resource"))


func test_scripted_resource_refused_without_getter_execution() -> void:
	var script := GDScript.new()
	script.source_code = "@tool\nextends BoxShape3D\nvar reads := 0\n@export var secret: int:\n\tget:\n\t\treads += 1\n\t\treturn 42\n"
	assert_eq(script.reload(), OK)
	var shape := BoxShape3D.new()
	shape.set_script(script)
	var node := CollisionShape3D.new()
	node.shape = shape
	var path := _attach(node)
	var result := _handler.inspect_resource({"node_path": path, "property": "shape"})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_eq(shape.get("reads"), 0)


func test_script_defined_root_property_never_calls_getter() -> void:
	var script := GDScript.new()
	script.source_code = "@tool\nextends Node3D\nvar reads := 0\n@export var secret: Resource:\n\tget:\n\t\treads += 1\n\t\treturn BoxShape3D.new()\n"
	assert_eq(script.reload(), OK)
	var node := Node3D.new()
	node.set_script(script)
	var path := _attach(node)
	var result := _handler.inspect_resource({"node_path": path, "property": "secret"})
	assert_is_error(result, ErrorCodes.PROPERTY_NOT_ON_CLASS)
	assert_eq(node.get("reads"), 0)


func test_invalid_inputs_and_empty_native_slot() -> void:
	assert_is_error(_handler.inspect_resource({}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_handler.inspect_resource({"node_path": 4, "property": "shape"}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.inspect_resource({"node_path": "/Main", "property": "shape", "depth": true}), ErrorCodes.WRONG_TYPE)
	for depth in [1.5, -1, 4]:
		assert_is_error(_handler.inspect_resource({"node_path": "/Main", "property": "shape", "depth": depth}), ErrorCodes.VALUE_OUT_OF_RANGE)
	var node := CollisionShape3D.new()
	var path := _attach(node)
	assert_is_error(_handler.inspect_resource({"node_path": path, "property": "shape"}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.inspect_resource({"node_path": path, "property": "position"}), ErrorCodes.PROPERTY_NOT_ON_CLASS)
	assert_is_error(_handler.inspect_resource({"node_path": "/AbsentInspector", "property": "shape"}), ErrorCodes.NODE_NOT_FOUND)


func test_unicode_and_escaping_are_bounded_encoded_output() -> void:
	var shape := BoxShape3D.new()
	shape.resource_name = ("雪\"\n\\" + String.chr(1)).repeat(2000)
	var original := shape.resource_name
	var result := Inspector.new().inspect(shape, 2)
	var stored: String = result.data.resources[0].properties.resource_name
	assert_true(JSON.stringify(stored).to_utf8_buffer().size() <= Inspector.MAX_STRING_BYTES)
	assert_true(JSON.stringify(result).to_utf8_buffer().size() <= Inspector.MAX_RESULT_BYTES)
	assert_true(original.begins_with(stored))
	assert_true(_has_reason(result, "string_bytes"))
	assert_eq(shape.resource_name, original)


func test_collection_limits_and_container_cycles() -> void:
	var inspector := Inspector.new()
	var values: Array = []
	for index in 100:
		values.append(index)
	var encoded: Array = inspector._value(values, 0, 0, "test")
	assert_eq(encoded.size(), 64)
	assert_eq(encoded[63], 63)
	var cyclic: Array = []
	cyclic.append(cyclic)
	var bounded: Variant = inspector._value(cyclic, 0, 0, "cycle")
	assert_true(JSON.stringify(bounded).length() < 1024)
	var saw_cycle_limit := false
	for entry in inspector._truncations:
		if entry.reason == "container_depth":
			saw_cycle_limit = true
	assert_true(saw_cycle_limit)
	cyclic.clear()


func test_dictionary_keys_are_bounded_and_not_stringified_objects() -> void:
	var inspector := Inspector.new()
	var dictionary := {"雪".repeat(4000): 7}
	var object := RefCounted.new()
	dictionary[object] = 9
	var result: Dictionary = inspector._value(dictionary, 0, 0, "dictionary")
	assert_eq(result.entries.size(), 1)
	assert_eq(result.entries[0].value, 7)
	assert_true(JSON.stringify(result.entries[0].key).to_utf8_buffer().size() <= Inspector.MAX_STRING_BYTES)
	assert_eq(inspector._truncations.back().reason, "unsupported_key")


func test_value_budget_and_truncation_metadata_are_bounded() -> void:
	var inspector := Inspector.new()
	var wide: Array = []
	for index in 64:
		wide.append(range(64))
	var result: Variant = inspector._value(wide, 0, 0, "wide")
	assert_eq(inspector._values, Inspector.MAX_VALUES)
	assert_true(JSON.stringify(result).to_utf8_buffer().size() < Inspector.MAX_RESULT_BYTES)
	for index in 100:
		inspector._omit("location", "values")
	assert_eq(inspector._truncations.size(), Inspector.MAX_TRUNCATIONS)
	assert_eq(inspector._truncations.back().reason, "truncation_limit")


func test_native_resource_cycle_reuses_root_reference() -> void:
	var first := ArrayMesh.new()
	var second := ArrayMesh.new()
	first.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	second.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	first.shadow_mesh = second
	second.shadow_mesh = first
	var result := Inspector.new().inspect(first, 3)
	assert_eq(result.data.resources.size(), 2)
	assert_eq(result.data.resources[0].properties.shadow_mesh, {"ref": "r2"})
	assert_eq(result.data.resources[1].properties.shadow_mesh, {"ref": "r1"})
	assert_true(first.shadow_mesh == second)
	assert_true(second.shadow_mesh == first)
	first.shadow_mesh = null
	second.shadow_mesh = null


func test_resource_limit_never_emits_a_dangling_reference() -> void:
	var inspector := Inspector.new()
	var retained: Array[Resource] = []
	for index in 33:
		retained.append(BoxShape3D.new())
	var results: Array = inspector._value(retained, 0, 0, "resources")
	assert_eq(inspector._resources.size(), 32)
	assert_eq(results[31], {"ref": "r32"})
	assert_eq(results[32], {"omitted": "resources"})


func test_byte_budget_stops_before_retaining_large_intermediate_output() -> void:
	var inspector := Inspector.new()
	var rows: Array = []
	for index in 64:
		rows.append("x".repeat(256))
	var result: Array = inspector._value([rows, rows, rows, rows], 0, 0, "bytes")
	assert_true(inspector._bytes_left < 64)
	assert_true(JSON.stringify(result).to_utf8_buffer().size() <= Inspector.MAX_RESULT_BYTES)
	assert_eq(inspector._truncations.back().reason, "result_bytes")


class GraphInspector extends "res://addons/godot_ai/utils/resource_inspector.gd":
	var edges: Dictionary = {}

	func _expand(resource: Resource, level: int, reference: String, row: Dictionary) -> void:
		if level > _depth:
			row["omitted"] = _omit(reference, "depth").omitted
			return
		var index := 0
		for child in edges.get(resource, []):
			row.properties[str(index)] = _value(child, level, 0, reference)
			index += 1
		row.properties["name"] = resource.resource_name


func test_shared_resource_uses_shallowest_reachable_depth() -> void:
	var root := BoxMesh.new()
	var branch := BoxMesh.new()
	var middle := BoxMesh.new()
	var shared := BoxMesh.new()
	shared.resource_name = "reachable directly"
	var inspector := GraphInspector.new()
	inspector.edges = {root: [branch, shared], branch: [middle], middle: [shared]}
	var result := inspector.inspect(root, 1)
	var reference: Dictionary = result.data.resources[0].properties["1"]
	var shared_row: Dictionary = {}
	for row in result.data.resources:
		if row.id == reference.ref:
			shared_row = row
	assert_false(shared_row.has("omitted"), "A longer path encountered earlier must not hide a direct resource")
	assert_eq(shared_row.properties.name, shared.resource_name)
	assert_eq(result.data.resources.size(), 4)


func test_native_root_property_does_not_invoke_script_get_override() -> void:
	var script := GDScript.new()
	script.source_code = "@tool\nextends CollisionShape3D\nvar reads := 0\nfunc _get(property: StringName) -> Variant:\n\treads += 1\n\tif property == &'shape':\n\t\treturn SphereShape3D.new()\n\treturn null\n"
	assert_eq(script.reload(), OK)
	var node := CollisionShape3D.new()
	node.set_script(script)
	var shape := BoxShape3D.new()
	shape.size = Vector3(3, 4, 5)
	node.shape = shape
	var path := _attach(node)
	node.set("reads", 0)
	var result := _handler.inspect_resource({"node_path": path, "property": "shape"})
	assert_eq(result.data.resources[0].type, "BoxShape3D")
	assert_eq(result.data.resources[0].properties.size, {"x": 3.0, "y": 4.0, "z": 5.0})
	assert_eq(node.get("reads"), 0, "Native property access must bypass script _get")
