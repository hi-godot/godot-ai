@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/visual_shader_handler.gd")
const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")
var _handler := Handler.new()
var _undo: EditorUndoRedoManager
var _paths: Array[String] = []


func suite_name() -> String:
	return "visual_shader"


func suite_setup(ctx: Dictionary) -> void:
	_undo = ctx.get("undo_redo")


func teardown() -> void:
	for path in _paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_paths.clear()


func _request(suffix: String = "graph") -> Dictionary:
	var path := "res://_test_visual_shader_%s.tres" % suffix
	_paths.append(path)
	return {
		"resource_path": path,
		"stages": [{"stage": "fragment", "nodes": [
			{"id": "color", "type": "VisualShaderNodeColorConstant", "params": {"constant": {"r": 1, "g": 0.25, "b": 0.1, "a": 1}}},
		], "connections": [{"from_node": "color", "from_port": 0, "to_node": "output", "to_port": 0}]}],
	}


func test_create_reload_and_deterministic_stage_ids() -> void:
	var request := _request()
	request.stages[0].nodes.append({"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"constant": 0.5}})
	request.stages.append({"stage": "vertex", "nodes": [{"id": "color", "type": "VisualShaderNodeVec3Constant"}], "connections": []})
	var result := _handler.create_graph(request)
	assert_has_key(result, "data", str(result.get("error", {})))
	if not result.has("data"):
		return
	assert_false(result.data.undoable)
	assert_eq(result.data.node_count, 3)
	assert_eq(result.data.connection_count, 1)
	assert_eq(result.data.id_map.fragment, [{"id": "color", "node_id": 3}, {"id": 2, "node_id": 2}])
	assert_eq(result.data.id_map.vertex, [{"id": "color", "node_id": 2}])
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_true(shader != null)
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, 3).get("constant"), Color(1, 0.25, 0.1, 1))
	assert_eq(shader.get_node_connections(VisualShader.TYPE_FRAGMENT).size(), 1)
	request.overwrite = true
	var repeated := _handler.create_graph(request)
	assert_eq(repeated.data.id_map, result.data.id_map)


func test_json_wire_numbers_are_accepted_and_normalized() -> void:
	## connection.gd uses JSON.parse_string, which returns floats for every JSON
	## number. Exercise that exact representation instead of GDScript literals.
	var request: Dictionary = JSON.parse_string(JSON.stringify(_request("json_wire")))
	request.stages[0].nodes.append({"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"constant": 0.5}})
	request.stages[0].connections[0].from_port = 0.0
	request.stages[0].connections[0].to_port = 0.0
	request = JSON.parse_string(JSON.stringify(request))
	var result := _handler.create_graph(request)
	assert_has_key(result, "data", str(result.get("error", {})))
	if not result.has("data"):
		return
	assert_eq(result.data.id_map.fragment, [{"id": "color", "node_id": 3}, {"id": 2, "node_id": 2}])
	assert_eq(result.data.connection_count, 1)
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_true(shader.get_node(VisualShader.TYPE_FRAGMENT, 2) is VisualShaderNodeFloatConstant)

	for bad in [2.5, NAN, INF, 2147483648.0]:
		var invalid := _request("bad_wire_id_%s" % str(bad).validate_filename())
		invalid.stages[0].nodes = [{"id": bad, "type": "VisualShaderNodeFloatConstant"}]
		invalid.stages[0].connections = []
		assert_has_key(_handler.create_graph(invalid), "error", str(bad))


func test_modes_and_explicit_stages() -> void:
	for mode in Handler.MODE_STAGES:
		var request := _request(mode)
		request.shader_type = mode
		request.stages = []
		for stage in Handler.MODE_STAGES[mode]:
			request.stages.append({"stage": stage, "nodes": [{"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"constant": 0.25}}], "connections": []})
		var result := _handler.create_graph(request)
		assert_has_key(result, "data", mode)
		if result.has("data"):
			assert_eq(result.data.node_count, Handler.MODE_STAGES[mode].size())
			var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
			assert_eq(shader.get_mode(), Handler.MODES[mode])
			for stage in Handler.MODE_STAGES[mode]:
				assert_eq(shader.get_node(Handler.STAGES[stage], 2).get("constant"), 0.25)


func test_overwrite_and_late_validation_preserve_existing_bytes() -> void:
	var request := _request()
	assert_has_key(_handler.create_graph(request), "data")
	var before := FileAccess.get_file_as_bytes(request.resource_path)
	var refused := _handler.create_graph(request)
	assert_has_key(refused, "error")
	assert_contains(refused.error.message, "overwrite=true")
	assert_eq(FileAccess.get_file_as_bytes(request.resource_path), before)
	request.overwrite = true
	request.stages.append({"stage": "vertex", "nodes": [{"id": 2, "type": "Node"}], "connections": []})
	assert_has_key(_handler.create_graph(request), "error")
	assert_eq(FileAccess.get_file_as_bytes(request.resource_path), before)


func test_rejects_invalid_request_shapes_and_paths() -> void:
	for changes in [
		{"resource_path": ""}, {"resource_path": "res://../escape.tres"},
		{"resource_path": "user://graph.tres"}, {"resource_path": "res://bad.gdshader"},
		{"stages": null}, {"stages": {}}, {"stages": []},
		{"shader_type": "unknown"}, {"overwrite": "true"},
		{"stages": [{"stage": "sky", "nodes": [], "connections": []}]},
		{"stages": [{"stage": "fragment", "nodes": {}, "connections": []}]},
	]:
		var request := _request()
		request.merge(changes, true)
		assert_has_key(_handler.create_graph(request), "error", str(changes))
		assert_false(FileAccess.file_exists("res://_test_visual_shader_graph.tres"))


func test_rejects_invalid_classes_properties_and_ids() -> void:
	for bad_node in [
		{"id": 2, "type": "Node"}, {"id": 2, "type": "NotAClass"},
		{"id": 2, "type": "VisualShaderNodeExpression"},
		{"id": 0, "type": "VisualShaderNodeFloatConstant"},
		{"id": "", "type": "VisualShaderNodeFloatConstant"},
		{"type": "VisualShaderNodeFloatConstant"},
		{"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"script": "res://bad.gd"}},
		{"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"constant": "bad"}},
		{"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"constant": NAN}},
		{"id": 2, "type": "VisualShaderNodeFloatConstant", "params": {"operator": "add"}},
		{"id": 2, "type": "VisualShaderNodeVec3Constant", "params": {"constant": {"x": "bad", "y": 0, "z": 0}}},
		{"id": 2, "type": "VisualShaderNodeFloatConstant", "position": {"x": 0, "y": "bad"}},
		{"id": 2, "type": "VisualShaderNodeFloatConstant", "position": {"x": INF, "y": 0}},
		{"id": 2, "type": "VisualShaderNodeFloatOp", "params": {"operator": 9999}},
		{"id": 2, "type": "VisualShaderNodeInput", "params": {"input_name": "not_an_input"}},
	]:
		var request := _request()
		request.stages[0].nodes = [bad_node]
		request.stages[0].connections = []
		assert_has_key(_handler.create_graph(request), "error", str(bad_node))
		assert_false(FileAccess.file_exists(request.resource_path))
	var duplicate := _request()
	duplicate.stages[0].nodes.append(duplicate.stages[0].nodes[0].duplicate(true))
	assert_has_key(_handler.create_graph(duplicate), "error")


func test_rejects_bad_connections_cycles_and_duplicate_inputs() -> void:
	for edge in [
		{"from_node": "missing", "from_port": 0, "to_node": 0, "to_port": 0},
		{"from_node": "color", "from_port": 999, "to_node": 0, "to_port": 0},
		{"from_node": "color", "from_port": -1, "to_node": 0, "to_port": 0},
		{"from_node": "color", "from_port": "0", "to_node": 0, "to_port": 0},
		{"from_node": "color", "from_port": 0, "to_node": 0, "to_port": 0, "to_stage": "vertex"},
		{"from_node": "output", "from_port": 0, "to_node": "color", "to_port": 0},
	]:
		var request := _request()
		request.stages[0].connections = [edge]
		assert_has_key(_handler.create_graph(request), "error", str(edge))
		assert_false(FileAccess.file_exists(request.resource_path))
	var duplicate := _request()
	duplicate.stages[0].connections.append(duplicate.stages[0].connections[0].duplicate())
	assert_has_key(_handler.create_graph(duplicate), "error")
	var cycle := _request()
	cycle.stages[0].nodes = [{"id": 2, "type": "VisualShaderNodeFloatOp"}, {"id": 3, "type": "VisualShaderNodeFloatOp"}]
	cycle.stages[0].connections = [
		{"from_node": 2, "from_port": 0, "to_node": 3, "to_port": 0},
		{"from_node": 3, "from_port": 0, "to_node": 2, "to_port": 0},
	]
	assert_has_key(_handler.create_graph(cycle), "error")


func test_limits_before_resource_write() -> void:
	var request := _request("at_node_limit")
	request.stages[0].nodes = []
	request.stages[0].connections = []
	for id in range(2, Handler.MAX_NODES + 2):
		request.stages[0].nodes.append({"id": id, "type": "VisualShaderNodeFloatConstant"})
	var result := _handler.create_graph(request)
	assert_has_key(result, "data", str(result.get("error", {})))
	if result.has("data"):
		assert_eq(result.data.node_count, Handler.MAX_NODES)
	request = _request("over_node_limit")
	request.stages[0].nodes = []
	for id in range(2, Handler.MAX_NODES + 3):
		request.stages[0].nodes.append({"id": id, "type": "VisualShaderNodeFloatConstant"})
	result = _handler.create_graph(request)
	assert_has_key(result, "error")
	assert_contains(result.error.message, "limits")
	request = _request("at_connection_limit")
	request.stages[0].connections = []
	for index in Handler.MAX_CONNECTIONS:
		request.stages[0].connections.append({"from_node": "missing", "from_port": 0, "to_node": "output", "to_port": 0})
	result = _handler.create_graph(request)
	assert_has_key(result, "error")
	assert_false(result.error.message.contains("limits"), "The exact connection limit must pass the size gate")
	request = _request("over_connection_limit")
	request.stages[0].connections.resize(Handler.MAX_CONNECTIONS + 1)
	result = _handler.create_graph(request)
	assert_has_key(result, "error")
	assert_contains(result.error.message, "limits")
	assert_false(FileAccess.file_exists(request.resource_path))


func test_texture_alpha_and_aliases_survive_reload() -> void:
	var texture_path := "res://_test_visual_shader_texture.tres"
	_paths.append(texture_path)
	var texture := GradientTexture2D.new()
	texture.gradient = Gradient.new()
	assert_eq(ResourceSaver.save(texture, texture_path), OK)
	var request := _request()
	request.stages[0].nodes = [
		{"id": "texture", "type": "VisualShaderNodeTexture", "params": {"texture": texture_path}},
		{"id": "time", "type": "VisualShaderNodeTime"},
		{"id": "sin", "type": "VisualShaderNodeSin"},
	]
	request.stages[0].connections = [{"from_node": "texture", "from_port": 1, "to_node": "output", "to_port": 1}]
	var result := _handler.create_graph(request)
	assert_has_key(result, "data", str(result.get("error", {})))
	if not result.has("data"):
		return
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	var texture_node := shader.get_node(VisualShader.TYPE_FRAGMENT, 2)
	assert_true(texture_node.get("texture") is Texture2D)
	assert_eq(texture_node.get("expanded_output_ports"), [0])
	assert_eq(shader.get_node_connections(VisualShader.TYPE_FRAGMENT)[0].from_port, 1)
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, 3).get("input_name"), "time")


func test_rejects_missing_and_wrong_texture_resources() -> void:
	var wrong_path := "res://_test_visual_shader_not_texture.tres"
	_paths.append(wrong_path)
	assert_eq(ResourceSaver.save(Resource.new(), wrong_path), OK)
	for texture_path in ["res://_test_visual_shader_missing_texture.tres", wrong_path]:
		var request := _request("bad_texture_%d" % _paths.size())
		request.stages[0].nodes = [{"id": 2, "type": "VisualShaderNodeTexture", "params": {"texture": texture_path}}]
		request.stages[0].connections = []
		var result := _handler.create_graph(request)
		assert_has_key(result, "error", texture_path)
		assert_false(FileAccess.file_exists(request.resource_path))
	var texture_path := "res://_test_visual_shader_texture_2d.tres"
	_paths.append(texture_path)
	var texture_2d := GradientTexture2D.new()
	texture_2d.gradient = Gradient.new()
	assert_eq(ResourceSaver.save(texture_2d, texture_path), OK)
	var mismatch := _request("texture_dimension_mismatch")
	mismatch.stages[0].nodes = [{"id": 2, "type": "VisualShaderNodeTexture3D", "params": {"texture": texture_path}}]
	mismatch.stages[0].connections = []
	assert_has_key(_handler.create_graph(mismatch), "error")


func test_atomic_replace_failure_preserves_existing_bytes_on_windows() -> void:
	if OS.get_name() != "Windows":
		skip("Windows file locking supplies the deterministic replacement failure")
		return
	var request := _request("locked_destination")
	assert_has_key(_handler.create_graph(request), "data")
	var before := FileAccess.get_file_as_bytes(request.resource_path)
	var held := FileAccess.open(request.resource_path, FileAccess.READ_WRITE)
	assert_true(held != null)
	request.overwrite = true
	request.stages[0].nodes[0].params.constant = {"r": 0, "g": 1, "b": 0, "a": 1}
	var result := _handler.create_graph(request)
	assert_has_key(result, "error", str(result))
	held = null
	assert_eq(FileAccess.get_file_as_bytes(request.resource_path), before)


func test_separate_material_creation_and_undoable_assignment() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var request := _request()
	var graph := _handler.create_graph(request)
	assert_has_key(graph, "data")
	if not graph.has("data"):
		return
	var material_path := "res://_test_visual_shader_material.tres"
	_paths.append(material_path)
	var materials := MaterialHandler.new(_undo)
	var created := materials.create_material({"path": material_path, "type": "shader", "shader_path": request.resource_path})
	assert_has_key(created, "data")
	var mesh := MeshInstance3D.new()
	mesh.name = "VisualShaderAssignment"
	mesh.mesh = SphereMesh.new()
	root.add_child(mesh)
	mesh.owner = root
	var assigned := materials.assign_material({"node_path": McpScenePath.from_node(mesh, root), "resource_path": material_path})
	assert_has_key(assigned, "data")
	assert_true(mesh.material_override is ShaderMaterial)
	assert_true(mesh.material_override.shader is VisualShader)
	assert_true(editor_undo(_undo))
	assert_true(mesh.material_override == null)
	assert_true(FileAccess.file_exists(request.resource_path))
	assert_true(editor_redo(_undo))
	assert_true(mesh.material_override.shader is VisualShader)
	root.remove_child(mesh)
	mesh.free()


# ============================================================================
# visual_shader_get
# ============================================================================

func test_get_graph_reports_structure() -> void:
	var request := _request("get_structure")
	var created := _handler.create_graph(request)
	assert_has_key(created, "data", str(created.get("error", {})))
	var result := _handler.get_graph({"path": request.resource_path})
	assert_has_key(result, "data")
	assert_eq(result.data.shader_type, "spatial")
	assert_eq(result.data.node_count, 1)
	assert_eq(result.data.connection_count, 1)
	assert_eq(result.data.stages.size(), 1)
	var fragment: Dictionary = result.data.stages[0]
	assert_eq(fragment.stage, "fragment")
	assert_eq(fragment.nodes.size(), 1)
	assert_eq(fragment.nodes[0].id, 2)
	assert_eq(fragment.nodes[0].type, "VisualShaderNodeColorConstant")
	assert_eq(fragment.nodes[0].params.constant.r, 1.0)
	assert_true(is_equal_approx(fragment.nodes[0].params.constant.b, 0.1))
	assert_eq(fragment.connections[0].from_node, 2)
	assert_eq(fragment.connections[0].from_port, 0)
	assert_eq(fragment.connections[0].to_node, 0)
	assert_eq(fragment.connections[0].to_port, 0)


func test_get_graph_errors_on_missing_and_wrong_type() -> void:
	assert_has_key(_handler.get_graph({"path": "res://_test_visual_shader_missing_get.tres"}), "error")
	var wrong := "res://_test_visual_shader_wrong_type.tres"
	_paths.append(wrong)
	assert_eq(ResourceSaver.save(Resource.new(), wrong), OK)
	var result := _handler.get_graph({"path": wrong})
	assert_has_key(result, "error")
	assert_eq(result.error.code, "WRONG_TYPE")


# ============================================================================
# varyings
# ============================================================================

func test_create_graph_with_varyings_and_get_reports_them() -> void:
	var request := _request("varyings")
	request["varyings"] = [
		{"name": "tint_var", "mode": "vertex_to_frag_light", "type": "vector4"},
		{"name": "strength_var", "mode": "frag_to_light", "type": "float"},
	]
	var created := _handler.create_graph(request)
	assert_has_key(created, "data", str(created.get("error", {})))
	assert_eq(created.data.varyings, ["tint_var", "strength_var"])
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_true(shader.has_varying("tint_var"))
	assert_true(shader.has_varying("strength_var"))
	var result := _handler.get_graph({"path": request.resource_path})
	assert_has_key(result, "data")
	assert_eq(result.data.varyings.size(), 2)
	for varying in result.data.varyings:
		if varying.name == "tint_var":
			assert_eq(varying.mode, "vertex_to_frag_light")
			assert_eq(varying.type, "vector4")
		elif varying.name == "strength_var":
			assert_eq(varying.mode, "frag_to_light")
			assert_eq(varying.type, "float")


func test_create_graph_rejects_bad_varyings() -> void:
	var cases: Array = [
		[{"name": "bad name", "mode": "vertex_to_frag_light", "type": "float"}],
		[{"name": "x", "mode": "nope", "type": "float"}],
		[{"name": "x", "mode": "frag_to_light", "type": "nope"}],
		[
			{"name": "dup", "mode": "frag_to_light", "type": "float"},
			{"name": "dup", "mode": "frag_to_light", "type": "float"},
		],
	]
	for index in cases.size():
		var request := _request("bad_varying_%d" % index)
		request["varyings"] = cases[index]
		assert_has_key(_handler.create_graph(request), "error", str(cases[index]))
		assert_false(FileAccess.file_exists(request.resource_path))
	var particles := _request("particles_varying")
	particles.shader_type = "particles"
	particles.stages = [{"stage": "process", "nodes": [], "connections": []}]
	particles["varyings"] = [{"name": "x", "mode": "vertex_to_frag_light", "type": "float"}]
	assert_has_key(_handler.create_graph(particles), "error")


# ============================================================================
# visual_shader_node_catalog
# ============================================================================

func test_node_catalog_lists_classes_and_params() -> void:
	var result := _handler.node_catalog({"filter": "FloatConstant"})
	assert_has_key(result, "data")
	assert_gt(result.data.total, 0)
	var found := false
	for entry in result.data.nodes:
		if entry.type == "VisualShaderNodeFloatConstant":
			found = true
			assert_true(entry.params.has("constant"))
	assert_true(found, "catalog should include VisualShaderNodeFloatConstant")
	assert_true(result.data.aliases.has("VisualShaderNodeScalarOp"))
	var paged := _handler.node_catalog({"offset": 1, "limit": 1})
	assert_has_key(paged, "data")
	assert_eq(paged.data.count, 1)
	assert_eq(paged.data.offset, 1)


# ============================================================================
# visual_shader_edit
# ============================================================================

func test_edit_graph_adds_connects_and_reports_mapping() -> void:
	var request := _request("edit_add")
	request.stages[0].nodes = []
	request.stages[0].connections = []
	assert_has_key(_handler.create_graph(request), "data")
	var result := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "add_node", "stage": "fragment", "id": "extra",
			 "type": "VisualShaderNodeFloatConstant", "params": {"constant": 0.75},
			 "position": {"x": 10, "y": 20}},
			{"op": "connect", "stage": "fragment", "from_node": "extra",
			 "from_port": 0, "to_node": "output", "to_port": 0},
		],
	})
	assert_has_key(result, "data", str(result.get("error", {})))
	assert_eq(result.data.operations_applied, 2)
	assert_eq(result.data.added.size(), 1)
	assert_eq(result.data.added[0].id, "extra")
	var node_id: int = result.data.added[0].node_id
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, node_id).get("constant"), 0.75)
	assert_eq(shader.get_node_connections(VisualShader.TYPE_FRAGMENT).size(), 1)
	assert_eq(shader.get_node_position(VisualShader.TYPE_FRAGMENT, node_id), Vector2(10, 20))


func test_edit_graph_replaces_disconnects_and_removes() -> void:
	var request := _request("edit_mutate")
	assert_has_key(_handler.create_graph(request), "data")
	var result := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "set_node_params", "stage": "fragment", "id": 2,
			 "params": {"constant": {"r": 0.1, "g": 0.2, "b": 0.3, "a": 1}}},
			{"op": "replace_node", "stage": "fragment", "id": 2,
			 "type": "VisualShaderNodeVec3Constant",
			 "params": {"constant": {"x": 1, "y": 2, "z": 3}}},
			{"op": "disconnect", "stage": "fragment", "from_node": 2,
			 "from_port": 0, "to_node": "output", "to_port": 0},
			{"op": "remove_node", "stage": "fragment", "id": 2},
		],
	})
	assert_has_key(result, "data", str(result.get("error", {})))
	assert_eq(result.data.node_count, 0)
	assert_eq(result.data.connection_count, 0)
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_true(shader.get_node(VisualShader.TYPE_FRAGMENT, 2) == null)


func test_edit_graph_varyings_round_trip() -> void:
	var request := _request("edit_varyings")
	assert_has_key(_handler.create_graph(request), "data")
	var added := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [{"op": "add_varying", "name": "glow_var", "mode": "frag_to_light", "type": "vector3"}],
	})
	assert_has_key(added, "data", str(added.get("error", {})))
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_true(shader.has_varying("glow_var"))
	var removed := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [{"op": "remove_varying", "name": "glow_var"}],
	})
	assert_has_key(removed, "data", str(removed.get("error", {})))
	shader = ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_false(shader.has_varying("glow_var"))


func test_edit_graph_failures_preserve_file() -> void:
	var request := _request("edit_fail")
	assert_has_key(_handler.create_graph(request), "data")
	var before := FileAccess.get_file_as_bytes(request.resource_path)
	var cases: Array = [
		[{"op": "add_node", "stage": "fragment", "type": "Node"}],
		[{"op": "add_node", "stage": "fragment", "id": 2, "type": "VisualShaderNodeFloatConstant"}],
		[{"op": "connect", "stage": "fragment", "from_node": "missing", "from_port": 0, "to_node": "output", "to_port": 0}],
		[{"op": "connect", "stage": "fragment", "from_node": 2, "from_port": 0, "to_node": "output", "to_port": 0}],
		[{"op": "remove_node", "stage": "fragment", "id": "output"}],
		[{"op": "unknown"}],
	]
	for operations in cases:
		var result := _handler.edit_graph({"resource_path": request.resource_path, "operations": operations})
		assert_has_key(result, "error", str(operations))
		assert_eq(FileAccess.get_file_as_bytes(request.resource_path), before, "failed edit must preserve bytes")
	var missing := _handler.edit_graph({
		"resource_path": "res://_test_visual_shader_missing_edit.tres",
		"operations": [{"op": "remove_node", "stage": "fragment", "id": 2}],
	})
	assert_has_key(missing, "error")


func test_edit_graph_replace_node_applies_implicit_aliases() -> void:
	## replace_node must merge the same IMPLICIT defaults add_node applies, or a
	## Sin/Time alias replacement silently loses function/input_name.
	var request := _request("edit_replace_implicit")
	request.stages[0].connections = []
	assert_has_key(_handler.create_graph(request), "data")
	var replaced := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "replace_node", "stage": "fragment", "id": 2, "type": "VisualShaderNodeSin"},
		],
	})
	assert_has_key(replaced, "data", str(replaced.get("error", {})))
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, 2).get("function"), VisualShaderNodeFloatFunc.FUNC_SIN)
	var time_result := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "replace_node", "stage": "fragment", "id": 2, "type": "VisualShaderNodeTime"},
		],
	})
	assert_has_key(time_result, "data", str(time_result.get("error", {})))
	shader = ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, 2).get("input_name"), "time")
	## Explicit params still win over the implicit default.
	var overridden := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "replace_node", "stage": "fragment", "id": 2, "type": "VisualShaderNodeSin",
			 "params": {"function": "cos"}},
		],
	})
	assert_has_key(overridden, "data", str(overridden.get("error", {})))
	shader = ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, 2).get("function"), VisualShaderNodeFloatFunc.FUNC_COS)


func test_edit_graph_replace_input_node_keeps_connections() -> void:
	## The engine's replace_node leaves a new input node without
	## shader_mode/shader_type, so the handler rebuilds it through add_node.
	## The rebuild must restore the edges the node already owned.
	var request := _request("edit_replace_input")
	request.stages[0].nodes = [{"id": "value", "type": "VisualShaderNodeFloatConstant", "params": {"constant": 0.5}}]
	request.stages[0].connections = [{"from_node": "value", "from_port": 0, "to_node": "output", "to_port": 1}]
	assert_has_key(_handler.create_graph(request), "data")
	var replaced := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "replace_node", "stage": "fragment", "id": 2, "type": "VisualShaderNodeTime"},
		],
	})
	assert_has_key(replaced, "data", str(replaced.get("error", {})))
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	var input_node := shader.get_node(VisualShader.TYPE_FRAGMENT, 2)
	assert_eq(input_node.get("input_name"), "time")
	var connections := shader.get_node_connections(VisualShader.TYPE_FRAGMENT)
	assert_eq(connections.size(), 1, "the rebuilt input node must keep its edge")
	assert_eq(int(connections[0].from_node), 2)
	assert_eq(int(connections[0].to_node), 0)
	assert_eq(int(connections[0].to_port), 1)


func test_edit_graph_scopes_string_ids_by_stage_and_rejects_duplicates() -> void:
	var request := _request("edit_alias_scope")
	request.stages.append({"stage": "vertex", "nodes": [], "connections": []})
	assert_has_key(_handler.create_graph(request), "data")
	var result := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "add_node", "stage": "vertex", "id": "shared", "type": "VisualShaderNodeFloatConstant"},
			{"op": "add_node", "stage": "fragment", "id": "shared", "type": "VisualShaderNodeFloatConstant"},
			{"op": "set_node_params", "stage": "vertex", "id": "shared", "params": {"constant": 0.25}},
			{"op": "set_node_params", "stage": "fragment", "id": "shared", "params": {"constant": 0.75}},
		],
	})
	assert_has_key(result, "data", str(result.get("error", {})))
	assert_eq(result.data.added.size(), 2)
	var shader := ResourceLoader.load(request.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VisualShader
	var vertex_id: int = result.data.added[0].node_id
	var fragment_id: int = result.data.added[1].node_id
	assert_eq(shader.get_node(VisualShader.TYPE_VERTEX, vertex_id).get("constant"), 0.25)
	assert_eq(shader.get_node(VisualShader.TYPE_FRAGMENT, fragment_id).get("constant"), 0.75)
	## A duplicate string id inside one stage is rejected and the file is untouched.
	var before := FileAccess.get_file_as_bytes(request.resource_path)
	var duplicate := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [
			{"op": "add_node", "stage": "vertex", "id": "dup", "type": "VisualShaderNodeFloatConstant"},
			{"op": "add_node", "stage": "vertex", "id": "dup", "type": "VisualShaderNodeFloatConstant"},
		],
	})
	assert_has_key(duplicate, "error")
	assert_contains(str(duplicate.error.message), "already used in this stage")
	assert_eq(FileAccess.get_file_as_bytes(request.resource_path), before, "failed edit must preserve bytes")


func test_edit_graph_rejects_stages_outside_shader_mode() -> void:
	var request := _request("edit_mode_stage")
	assert_has_key(_handler.create_graph(request), "data")
	var before := FileAccess.get_file_as_bytes(request.resource_path)
	var cases: Array = [
		[{"op": "add_node", "stage": "process", "type": "VisualShaderNodeFloatConstant"}],
		[{"op": "set_node_params", "stage": "process", "id": 2, "params": {"constant": 0.5}}],
		[{"op": "connect", "stage": "process", "from_node": 2, "from_port": 0, "to_node": "output", "to_port": 0}],
	]
	for operations in cases:
		var result := _handler.edit_graph({"resource_path": request.resource_path, "operations": operations})
		assert_has_key(result, "error", str(operations))
		assert_contains(str(result.error.message), "not available for spatial")
		assert_eq(FileAccess.get_file_as_bytes(request.resource_path), before, "failed edit must preserve bytes")
	## A stage the mode does support still works.
	var allowed := _handler.edit_graph({
		"resource_path": request.resource_path,
		"operations": [{"op": "add_node", "stage": "vertex", "type": "VisualShaderNodeFloatConstant"}],
	})
	assert_has_key(allowed, "data", str(allowed.get("error", {})))


func test_varying_from_text_matches_the_exact_property_name() -> void:
	## A prefix match let `varyings/glow_bar` answer for `glow` when it was
	## serialized first. Quoted property names must still parse.
	var text := "\"varyings/glow_bar\" = \"1,2\"\nvaryings/glow = \"0,3\"\n"
	assert_eq(Handler._varying_from_text(text, "glow"), "0,3")
	assert_eq(Handler._varying_from_text(text, "glow_bar"), "1,2")
	assert_eq(Handler._varying_from_text('varyings/glow_bar = "1,2"', "glow"), "")
	assert_eq(Handler._varying_from_text('"varyings/glow" = "0,3"', "glow"), "0,3")
