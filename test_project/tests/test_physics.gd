@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const PhysicsHandler := preload("res://addons/godot_ai/handlers/physics_handler.gd")

## Tests for PhysicsHandler — body/area physics configuration and project
## collision layer names.
##
## Layer-name writes touch ProjectSettings, so tests save and restore every
## name they change in suite_teardown (same pattern as test_project.gd's
## settings roundtrip tests).
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: PhysicsHandler
var _undo_redo: EditorUndoRedoManager

## dimension -> {layer_index: name} captured before a test changes it.
var _saved_layer_names: Dictionary = {}
var _fixture_path: String = ""


func suite_name() -> String:
	return "physics"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = PhysicsHandler.new(_undo_redo)
	_fixture_path = _make_material_fixture()


func suite_teardown() -> void:
	_restore_layer_names()
	if not _fixture_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_path))
		_fixture_path = ""


# ----- helpers -----

## Save the current names of `indexes` for one dimension so the suite can put
## project.godot back exactly as it found it. Merges into any earlier capture
## for the dimension and keeps the earliest value, so a later test in the same
## suite cannot overwrite the restore record of an earlier one.
func _save_layer_names(dimension: String, indexes: Array) -> void:
	var saved: Dictionary = _saved_layer_names.get(dimension, {})
	for index in indexes:
		if saved.has(index):
			continue
		saved[index] = str(
			ProjectSettings.get_setting("layer_names/%s_physics/layer_%d" % [dimension, index], "")
		)
	_saved_layer_names[dimension] = saved


func _restore_layer_names() -> void:
	if _saved_layer_names.is_empty():
		return
	for dimension in _saved_layer_names:
		var saved: Dictionary = _saved_layer_names[dimension]
		for index in saved:
			ProjectSettings.set_setting(
				"layer_names/%s_physics/layer_%d" % [dimension, index], saved[index]
			)
	ProjectSettings.save()
	_saved_layer_names.clear()


func _make_material_fixture() -> String:
	var material := PhysicsMaterial.new()
	material.friction = 0.7
	material.bounce = 0.3
	var path := "user://test_physics_material.tres"
	if ResourceSaver.save(material, path) != OK:
		return ""
	return path


func _add_node(node: Node, node_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	node.name = node_name
	scene_root.add_child(node)
	node.owner = scene_root
	return node


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


# ----- body_get -----

func test_body_get_reports_config_and_layer_names() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(StaticBody3D.new(), "GetBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	body.collision_layer = 3
	body.collision_mask = 5
	var result := _handler.body_get({"path": "/" + scene_root.name + "/GetBody"})
	assert_has_key(result, "data")
	assert_eq(result.data.dimension, "3d")
	assert_eq(result.data.config.collision_layer, 3)
	assert_eq(result.data.config.collision_mask, 5)
	assert_eq(result.data.collision_layer_names.size(), 2)
	assert_eq(result.data.collision_mask_names.size(), 2)
	_remove_node(body)


func test_body_get_2d_rigidbody() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(RigidBody2D.new(), "GetBody2D") as RigidBody2D
	if body == null:
		skip("Scene not ready")
		return
	body.mass = 3.0
	var result := _handler.body_get({"path": "/" + scene_root.name + "/GetBody2D"})
	assert_has_key(result, "data")
	assert_eq(result.data.dimension, "2d")
	assert_eq(result.data.config.mass, 3.0)
	_remove_node(body)


func test_body_get_rejects_non_body() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var node := _add_node(Node3D.new(), "GetNotBody")
	var result := _handler.body_get({"path": "/" + scene_root.name + "/GetNotBody"})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "CollisionObject")
	_remove_node(node)


# ----- body_configure -----

func test_body_configure_sets_bitmask_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(RigidBody3D.new(), "ConfigBody") as RigidBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/ConfigBody",
		"collision_layer": 4,
		"collision_mask": 6,
		"mass": 2.5,
		"gravity_scale": 0.5,
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	assert_eq(body.collision_layer, 4)
	assert_eq(body.collision_mask, 6)
	assert_eq(body.mass, 2.5)
	assert_eq(body.gravity_scale, 0.5)
	assert_eq(result.data.previous.collision_layer, 1)
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(body.collision_layer, 1, "undo must restore the layer bitmask")
	assert_eq(body.mass, 1.0, "undo must restore the mass")
	_remove_node(body)


func test_body_configure_accepts_layer_names() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	_save_layer_names("3d", [1, 2])
	var named := _handler.layers_set({
		"dimension": "3d",
		"layers": {"1": "physics_probe_player", "2": "physics_probe_enemy"},
	})
	assert_has_key(named, "data")
	var body := _add_node(StaticBody3D.new(), "NamedBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/NamedBody",
		"collision_layer": ["physics_probe_player", "physics_probe_enemy"],
		"collision_mask": ["physics_probe_enemy"],
	})
	assert_has_key(result, "data")
	assert_eq(body.collision_layer, 3, "two names must resolve to bits 1|2")
	assert_eq(body.collision_mask, 2, "one name must resolve to bit 2")
	assert_eq(result.data.applied.collision_layer, 3)
	_remove_node(body)


func test_body_configure_unknown_layer_name_is_actionable() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(StaticBody3D.new(), "BadLayerBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/BadLayerBody",
		"collision_layer": ["physics_probe_missing"],
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "physics_probe_missing")
	assert_contains(result.error.message, "layers_set")
	assert_eq(body.collision_layer, 1, "a refused name must not change the body")
	_remove_node(body)


func test_body_configure_rejects_class_inapplicable_property() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(StaticBody3D.new(), "NoMassBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/NoMassBody",
		"mass": 5.0,
	})
	assert_is_error(result, ErrorCodes.PROPERTY_NOT_ON_CLASS)
	assert_contains(result.error.message, "mass")
	_remove_node(body)


func test_body_configure_rejects_unknown_property() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(StaticBody3D.new(), "UnknownPropBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/UnknownPropBody",
		"wobble": 1.0,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "wobble")
	_remove_node(body)


func test_body_configure_requires_a_property() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := _add_node(StaticBody3D.new(), "EmptyConfigBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({"path": "/" + scene_root.name + "/EmptyConfigBody"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
	_remove_node(body)


func test_body_configure_2d_area_properties() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var area := _add_node(Area2D.new(), "ConfigArea2D") as Area2D
	if area == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/ConfigArea2D",
		"monitoring": false,
		"monitorable": false,
		"priority": 3,
		"gravity": 500.0,
	})
	assert_has_key(result, "data")
	assert_false(area.monitoring)
	assert_false(area.monitorable)
	assert_eq(area.priority, 3)
	assert_eq(area.gravity, 500.0)
	_remove_node(area)


func test_body_configure_physics_material_roundtrip() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	if _fixture_path.is_empty():
		skip("PhysicsMaterial fixture could not be created")
		return
	var body := _add_node(StaticBody3D.new(), "MaterialBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/MaterialBody",
		"physics_material_override": _fixture_path,
	})
	assert_has_key(result, "data")
	assert_true(body.physics_material_override is PhysicsMaterial)
	assert_true(
		absf(body.physics_material_override.friction - 0.7) < 0.001,
		"friction must round-trip, got %s" % str(body.physics_material_override.friction)
	)
	var cleared := _handler.body_configure({
		"path": "/" + scene_root.name + "/MaterialBody",
		"physics_material_override": "",
	})
	assert_has_key(cleared, "data")
	assert_true(body.physics_material_override == null, "an empty path must clear the override")
	_remove_node(body)


# ----- layers_get / layers_set -----

func test_layers_set_and_get_roundtrip() -> void:
	_save_layer_names("2d", [5, 6])
	var set_result := _handler.layers_set({
		"dimension": "2d",
		"layers": {"5": "physics_probe_a", "6": "physics_probe_b"},
	})
	assert_has_key(set_result, "data")
	assert_false(set_result.data.undoable)
	assert_contains(set_result.data.reason, "disk")
	assert_eq(set_result.data.updated.size(), 2)
	assert_eq(set_result.data.updated[0].bit, 16, "layer 5 must map to bit 16")
	var get_result := _handler.layers_get({"dimension": "2d"})
	assert_has_key(get_result, "data")
	var names := {}
	for entry in get_result.data.layers:
		names[entry.index] = entry.name
	assert_eq(names.get(5, ""), "physics_probe_a")
	assert_eq(names.get(6, ""), "physics_probe_b")


func test_layers_set_rejects_bad_index_and_shape() -> void:
	var bad_index := _handler.layers_set({"dimension": "3d", "layers": {"33": "nope"}})
	assert_is_error(bad_index, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_index.error.message, "33")
	var zero_index := _handler.layers_set({"dimension": "3d", "layers": {"0": "nope"}})
	assert_is_error(zero_index, ErrorCodes.VALUE_OUT_OF_RANGE)
	var bad_shape := _handler.layers_set({"dimension": "3d", "layers": ["player"]})
	assert_is_error(bad_shape, ErrorCodes.WRONG_TYPE)
	var bad_dimension := _handler.layers_get({"dimension": "4d"})
	assert_is_error(bad_dimension, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_dimension.error.message, "4d")


func test_layers_set_rejects_non_string_name() -> void:
	_save_layer_names("3d", [11])
	var result := _handler.layers_set({"dimension": "3d", "layers": {"11": 42}})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "string")
	assert_eq(_handler.layers_get({"dimension": "3d"}).data.layers.filter(
		func(entry): return entry.index == 11
	).size(), 0, "a refused name must not be written")


func test_layers_set_rejects_duplicate_names() -> void:
	_save_layer_names("3d", [12, 13, 14])
	var same_call := _handler.layers_set({
		"dimension": "3d",
		"layers": {"12": "physics_probe_dup", "13": "physics_probe_dup"},
	})
	assert_is_error(same_call, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(same_call.error.message, "physics_probe_dup")
	assert_contains(same_call.error.message, "12")
	assert_contains(same_call.error.message, "13")
	## Neither index may have been written.
	for entry in _handler.layers_get({"dimension": "3d"}).data.layers:
		assert_false(entry.name == "physics_probe_dup", "a refused batch must not be written")

	var first := _handler.layers_set({"dimension": "3d", "layers": {"12": "physics_probe_taken"}})
	assert_has_key(first, "data")
	var collides := _handler.layers_set({"dimension": "3d", "layers": {"13": "physics_probe_taken"}})
	assert_is_error(collides, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(collides.error.message, "physics_probe_taken")
	## Moving the name between indices in one call is allowed: the post-update
	## state has the name exactly once.
	var moved := _handler.layers_set({
		"dimension": "3d",
		"layers": {"12": "physics_probe_moved", "13": "physics_probe_taken"},
	})
	assert_has_key(moved, "data")
	var names := {}
	for entry in _handler.layers_get({"dimension": "3d"}).data.layers:
		names[entry.index] = entry.name
	assert_eq(names.get(12, ""), "physics_probe_moved")
	assert_eq(names.get(13, ""), "physics_probe_taken")


func test_body_configure_rejects_ambiguous_layer_name() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	## Write duplicates directly (layers_set refuses them) to model a
	## project.godot edited by hand.
	_save_layer_names("3d", [15, 16])
	ProjectSettings.set_setting("layer_names/3d_physics/layer_15", "physics_probe_ambiguous")
	ProjectSettings.set_setting("layer_names/3d_physics/layer_16", "physics_probe_ambiguous")
	ProjectSettings.save()
	var body := _add_node(StaticBody3D.new(), "AmbiguousLayerBody") as StaticBody3D
	if body == null:
		skip("Scene not ready")
		return
	var result := _handler.body_configure({
		"path": "/" + scene_root.name + "/AmbiguousLayerBody",
		"collision_layer": ["physics_probe_ambiguous"],
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "ambiguous")
	assert_contains(result.error.message, "15")
	assert_contains(result.error.message, "16")
	assert_eq(body.collision_layer, 1, "an ambiguous name must not change the body")
	_remove_node(body)
