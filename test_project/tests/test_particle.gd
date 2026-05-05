@tool
extends McpTestSuite

const ParticleHandler := preload("res://addons/godot_ai/handlers/particle_handler.gd")

## Tests for ParticleHandler — GPUParticles3D/2D, CPUParticles3D/2D,
## ParticleProcessMaterial authoring.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: ParticleHandler
var _undo_redo: EditorUndoRedoManager
var _created_paths: Array[String] = []


func suite_name() -> String:
	return "particle"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = ParticleHandler.new(_undo_redo)


func suite_teardown() -> void:
	for path in _created_paths:
		_remove_by_path(path)
	_created_paths.clear()


func _remove_by_path(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := McpScenePath.resolve(path, scene_root)
	if node != null and node.get_parent() != null:
		node.get_parent().remove_child(node)
		node.queue_free()


func _create(node_name: String, type_str: String = "gpu_3d") -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var result := _handler.create_particle({
		"parent_path": "/" + scene_root.name,
		"name": node_name,
		"type": type_str,
	})
	if result.has("data"):
		_created_paths.append(result.data.path)
	return result


# ============================================================================
# particle_create
# ============================================================================

func test_create_gpu_3d() -> void:
	var result := _create("TestGPU3D", "gpu_3d")
	if result.is_empty():
		skip("No scene root — is a scene open?")
		return
	assert_has_key(result, "data")
	assert_eq(result.data.class, "GPUParticles3D")
	assert_eq(result.data.process_material_created, true)
	assert_eq(result.data.draw_pass_mesh_created, true)
	assert_true(result.data.undoable)


func test_create_gpu_2d() -> void:
	var result := _create("TestGPU2D", "gpu_2d")
	if result.is_empty():
		skip("No scene root — is a scene open?")
		return
	assert_eq(result.data.class, "GPUParticles2D")
	assert_eq(result.data.process_material_created, true)
	assert_eq(result.data.draw_pass_mesh_created, false)


func test_create_cpu_3d() -> void:
	var result := _create("TestCPU3D", "cpu_3d")
	if result.is_empty():
		skip("No scene root — is a scene open?")
		return
	assert_eq(result.data.class, "CPUParticles3D")
	assert_eq(result.data.process_material_created, false)
	assert_eq(result.data.draw_pass_mesh_created, false)


func test_create_cpu_2d() -> void:
	var result := _create("TestCPU2D", "cpu_2d")
	if result.is_empty():
		skip("No scene root — is a scene open?")
		return
	assert_eq(result.data.class, "CPUParticles2D")


func test_create_invalid_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.create_particle({
		"parent_path": "/" + scene_root.name,
		"name": "BadType",
		"type": "nonsense",
	})
	assert_is_error(result)


func test_create_attaches_process_material_to_gpu() -> void:
	var result := _create("TestGPUHasProcess", "gpu_3d")
	if result.is_empty():
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(result.data.path, scene_root) as GPUParticles3D
	assert_true(node != null)
	assert_true(node.process_material is ParticleProcessMaterial)
	assert_true(node.draw_pass_1 is Mesh)


# ============================================================================
# particle_set_main
# ============================================================================

func test_set_main_basic_props() -> void:
	var r := _create("TestSetMain", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_main({
		"node_path": r.data.path,
		"properties": {
			"amount": 200,
			"lifetime": 2.5,
			"one_shot": true,
			"explosiveness": 0.5,
		},
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	assert_eq(int(node.amount), 200)
	assert_true(abs(node.lifetime - 2.5) < 0.01)
	assert_eq(node.one_shot, true)


func test_set_main_unknown_property() -> void:
	var r := _create("TestMainUnknown", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_main({
		"node_path": r.data.path,
		"properties": {"nonsense_prop": 1},
	})
	assert_is_error(result)


func test_set_main_empty_dict() -> void:
	var r := _create("TestMainEmpty", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_main({
		"node_path": r.data.path,
		"properties": {},
	})
	assert_is_error(result)


# ============================================================================
# particle_set_process
# ============================================================================

func test_set_process_gpu_emission_shape_enum() -> void:
	var r := _create("TestProcessShape", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {
			"emission_shape": "sphere",
			"emission_sphere_radius": 0.5,
		},
	})
	assert_has_key(result, "data")
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	var mat := node.process_material as ParticleProcessMaterial
	assert_eq(int(mat.emission_shape), ParticleProcessMaterial.EMISSION_SHAPE_SPHERE)
	assert_true(abs(mat.emission_sphere_radius - 0.5) < 0.01)


func test_set_process_color_ramp_coerces_to_texture() -> void:
	var r := _create("TestProcessRamp", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {
			"color_ramp": {
				"stops": [
					{"time": 0.0, "color": [1.0, 1.0, 1.0, 1.0]},
					{"time": 1.0, "color": [1.0, 0.0, 0.0, 0.0]},
				]
			}
		},
	})
	assert_has_key(result, "data")
	# Critical: read back the stored value — must be a GradientTexture1D, not a Dict.
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	var mat := node.process_material as ParticleProcessMaterial
	assert_true(mat.color_ramp is GradientTexture1D,
		"color_ramp must be a GradientTexture1D (got %s)" % type_string(typeof(mat.color_ramp)))


func test_set_process_vector3_gravity() -> void:
	var r := _create("TestProcessGravity", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {"gravity": {"x": 0.0, "y": -12.0, "z": 0.0}},
	})
	assert_has_key(result, "data")
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	var mat := node.process_material as ParticleProcessMaterial
	assert_true(mat.gravity is Vector3)
	assert_true(abs(mat.gravity.y - (-12.0)) < 0.01)


func test_set_process_auto_creates_process_material() -> void:
	var r := _create("TestProcessAuto", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	# Strip the auto-created process material, then set_process should re-create.
	node.process_material = null
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {"emission_shape": "box"},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.process_material_created, true)
	assert_true(node.process_material is ParticleProcessMaterial)


func test_set_process_cpu_direct_on_node() -> void:
	var r := _create("TestProcessCPU", "cpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {
			"emission_shape": "sphere",
			"emission_sphere_radius": 0.5,
		},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.process_material_created, false)
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as CPUParticles3D
	assert_eq(int(node.emission_shape), CPUParticles3D.EMISSION_SHAPE_SPHERE)


func test_set_process_invalid_shape_string() -> void:
	var r := _create("TestProcessBadShape", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {"emission_shape": "quantum"},
	})
	assert_is_error(result)


func test_set_process_invalid_color_ramp() -> void:
	var r := _create("TestProcessBadRamp", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_process({
		"node_path": r.data.path,
		"properties": {"color_ramp": {"no_stops_key": []}},
	})
	assert_is_error(result)


# ============================================================================
# particle_set_draw_pass
# ============================================================================

func test_set_draw_pass_requires_valid_pass_number() -> void:
	var r := _create("TestDrawPass", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_draw_pass({
		"node_path": r.data.path,
		"pass": 99,
	})
	assert_is_error(result)


func test_set_draw_pass_creates_default_mesh_when_empty() -> void:
	var r := _create("TestDrawPassDefault", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	# draw_passes defaults to 1 so draw_pass_2 isn't even a live property yet;
	# the handler must grow draw_passes first and create a default mesh.
	var result := _handler.set_draw_pass({
		"node_path": r.data.path,
		"pass": 2,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.draw_pass_mesh_created, true)
	assert_true(int(node.draw_passes) >= 2, "draw_passes should have grown to >= 2")
	assert_true(node.draw_pass_2 is Mesh, "draw_pass_2 should be a Mesh after growth")


# ============================================================================
# particle_restart
# ============================================================================

func test_restart_returns_non_undoable() -> void:
	var r := _create("TestRestart", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	var result := _handler.restart_particle({"node_path": r.data.path})
	assert_has_key(result, "data")
	assert_eq(result.data.undoable, false)


# ============================================================================
# particle_get
# ============================================================================

func test_get_returns_structured_snapshot() -> void:
	var r := _create("TestGet", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	_handler.set_main({
		"node_path": r.data.path,
		"properties": {"amount": 42, "lifetime": 1.5},
	})
	var result := _handler.get_particle({"node_path": r.data.path})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "gpu_3d")
	assert_eq(result.data.class, "GPUParticles3D")
	assert_eq(int(result.data.main.amount), 42)
	assert_has_key(result.data, "process")
	assert_has_key(result.data, "draw_passes")


func test_get_non_particle_node_errors() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var mi := MeshInstance3D.new()
	mi.name = "NotAParticle"
	scene_root.add_child(mi)
	mi.owner = scene_root
	var result := _handler.get_particle({"node_path": McpScenePath.from_node(mi, scene_root)})
	assert_is_error(result)
	mi.get_parent().remove_child(mi)
	mi.queue_free()


# ============================================================================
# particle_apply_preset
# ============================================================================

func test_apply_preset_fire() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestFire",
		"preset": "fire",
		"type": "gpu_3d",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "fire")
	assert_eq(result.data.process_material_created, true)
	assert_eq(result.data.draw_pass_mesh_created, true)
	assert_contains(result.data.applied_process, "emission_shape")
	assert_contains(result.data.applied_process, "color_ramp")
	_created_paths.append(result.data.path)


func test_apply_preset_smoke_on_cpu() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestSmokeCPU",
		"preset": "smoke",
		"type": "cpu_3d",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.process_material_created, false)
	_created_paths.append(result.data.path)


func test_apply_preset_spark_burst_is_one_shot() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestSpark",
		"preset": "spark_burst",
	})
	assert_has_key(result, "data")
	var node := McpScenePath.resolve(result.data.path, scene_root) as GPUParticles3D
	assert_eq(node.one_shot, true)
	assert_true(abs(node.explosiveness - 1.0) < 0.01)
	_created_paths.append(result.data.path)


func test_apply_preset_with_overrides() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestFireOverrides",
		"preset": "fire",
		"overrides": {"amount": 999, "emission_sphere_radius": 2.0},
	})
	assert_has_key(result, "data")
	var node := McpScenePath.resolve(result.data.path, scene_root) as GPUParticles3D
	assert_eq(int(node.amount), 999)
	var mat := node.process_material as ParticleProcessMaterial
	assert_true(abs(mat.emission_sphere_radius - 2.0) < 0.01)
	_created_paths.append(result.data.path)


func test_apply_preset_attaches_draw_material() -> void:
	# Without a draw material, color_ramp silently gets ignored by the renderer.
	# The preset must auto-attach a StandardMaterial3D with vertex colour on.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestFireDrawMat",
		"preset": "fire",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.draw_material_created, true)
	var node := McpScenePath.resolve(result.data.path, scene_root) as GPUParticles3D
	var quad := node.draw_pass_1 as QuadMesh
	assert_true(quad != null, "draw_pass_1 should be a QuadMesh")
	var mat := quad.material as StandardMaterial3D
	assert_true(mat != null, "QuadMesh should have a StandardMaterial3D attached")
	assert_true(mat.vertex_color_use_as_albedo, "vertex_color_use_as_albedo must be on for color_ramp to render")
	assert_eq(int(mat.billboard_mode), BaseMaterial3D.BILLBOARD_PARTICLES)
	assert_eq(int(mat.transparency), BaseMaterial3D.TRANSPARENCY_ALPHA)
	# Fire preset requests additive blend for the glow.
	assert_eq(int(mat.blend_mode), BaseMaterial3D.BLEND_MODE_ADD)
	_created_paths.append(result.data.path)


func test_apply_preset_lightning() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestLightning",
		"preset": "lightning",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "lightning")
	var node := McpScenePath.resolve(result.data.path, scene_root) as GPUParticles3D
	assert_eq(node.one_shot, true)
	assert_true(abs(node.explosiveness - 1.0) < 0.01)
	var mat := (node.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	assert_true(mat.emission_enabled, "Lightning should be emissive")
	assert_eq(int(mat.blend_mode), BaseMaterial3D.BLEND_MODE_ADD)
	_created_paths.append(result.data.path)


func test_create_attaches_default_draw_material() -> void:
	# Bare particle_create (no preset) must also get the billboard-particles
	# default material, otherwise color_ramp won't render.
	var r := _create("TestDefaultDrawMat", "gpu_3d")
	if r.is_empty():
		skip("No scene root — is a scene open?")
		return
	assert_eq(r.data.draw_material_created, true)
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as GPUParticles3D
	var mat := (node.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	assert_true(mat != null, "Default QuadMesh should have a material")
	assert_true(mat.vertex_color_use_as_albedo)


func test_apply_preset_unknown() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestUnknown",
		"preset": "not_a_real_preset",
	})
	assert_is_error(result)


func test_apply_preset_invalid_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "TestBadType",
		"preset": "fire",
		"type": "gpu_5d",
	})
	assert_is_error(result)
