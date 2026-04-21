@tool
extends McpTestSuite

## Tests for ResourceHandler — resource search, load, and assign.

var _handler: ResourceHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "resource"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = ResourceHandler.new(_undo_redo)


# ----- search_resources -----

func test_search_resources_missing_filters() -> void:
	var result := _handler.search_resources({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_search_resources_by_path() -> void:
	var result := _handler.search_resources({"path": "main"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "resources")
	assert_has_key(result.data, "count")
	## Should find at least main.tscn
	assert_gt(result.data.count, 0, "Should find at least one resource matching 'main'")


func test_search_resources_by_type() -> void:
	var result := _handler.search_resources({"type": "PackedScene"})
	assert_has_key(result, "data")
	assert_gt(result.data.count, 0, "Should find at least one PackedScene")
	for res: Dictionary in result.data.resources:
		assert_eq(res.type, "PackedScene")


# ----- load_resource -----

func test_load_resource_missing_path() -> void:
	var result := _handler.load_resource({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_load_resource_invalid_prefix() -> void:
	var result := _handler.load_resource({"path": "/tmp/bad.tres"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_load_resource_not_found() -> void:
	var result := _handler.load_resource({"path": "res://nonexistent.tres"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_load_resource_scene() -> void:
	var result := _handler.load_resource({"path": "res://main.tscn"})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "PackedScene")
	assert_has_key(result.data, "properties")
	assert_has_key(result.data, "property_count")


# ----- assign_resource -----

func test_assign_resource_missing_path() -> void:
	var result := _handler.assign_resource({"property": "mesh", "resource_path": "res://foo.tres"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_assign_resource_missing_property() -> void:
	var result := _handler.assign_resource({"path": "/Main/Camera3D", "resource_path": "res://foo.tres"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_assign_resource_missing_resource_path() -> void:
	var result := _handler.assign_resource({"path": "/Main/Camera3D", "property": "mesh"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_assign_resource_node_not_found() -> void:
	var result := _handler.assign_resource({
		"path": "/Main/DoesNotExist",
		"property": "mesh",
		"resource_path": "res://main.tscn",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_assign_resource_property_not_found() -> void:
	var result := _handler.assign_resource({
		"path": "/Main/Camera3D",
		"property": "nonexistent_property_xyz",
		"resource_path": "res://main.tscn",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	# Issue #47: surface available property names + suggestions so the agent
	# doesn't need a round-trip to discover valid names.
	var msg: String = result.error.get("message", "")
	assert_contains(msg, "available:", "Error must list available property names")


# ----- _property_errors helper (issue #47) -----

func test_property_errors_suggests_top_radius_for_radius_on_cylinder_mesh() -> void:
	## Repro from issue #47: agent sends {"radius": 0.5} on a CylinderMesh.
	## Godot's property is split into `top_radius` and `bottom_radius`; the
	## error must surface both as suggestions.
	var mesh := CylinderMesh.new()
	var msg := McpPropertyErrors.build_message(mesh, "radius")
	assert_contains(msg, "top_radius", "Did-you-mean should surface top_radius")
	assert_contains(msg, "bottom_radius", "Did-you-mean should surface bottom_radius")
	assert_contains(msg, "Did you mean", "Message must mark suggestions explicitly")
	assert_contains(msg, "available:", "Message must list available properties")


func test_property_errors_no_suggestions_for_totally_unknown_name() -> void:
	## No close match means no "did you mean" segment — but the available-list
	## tail still gives the agent enough to pick the right property.
	var mesh := CylinderMesh.new()
	var msg := McpPropertyErrors.build_message(mesh, "asdfqwerty")
	assert_contains(msg, "asdfqwerty", "Bad name must appear verbatim")
	assert_contains(msg, "available:", "Available-list tail must appear")


func test_property_errors_includes_engine_class_label() -> void:
	var mesh := CylinderMesh.new()
	var msg := McpPropertyErrors.build_message(mesh, "radius")
	assert_contains(msg, "CylinderMesh", "Error must identify the target class")


func test_assign_resource_resource_not_found() -> void:
	var result := _handler.assign_resource({
		"path": "/Main/Camera3D",
		"property": "environment",
		"resource_path": "res://nonexistent.tres",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- create_resource -----

func _add_mesh_instance(node_name: String = "TestMesh") -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = node_name
	scene_root.add_child(mi)
	mi.set_owner(scene_root)
	return mi


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


func test_create_resource_missing_type() -> void:
	var result := _handler.create_resource({"path": "/Main/Foo", "property": "mesh"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "type")


func test_create_resource_no_home_errors() -> void:
	var result := _handler.create_resource({"type": "BoxMesh"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "path")


func test_create_resource_both_homes_errors() -> void:
	var result := _handler.create_resource({
		"type": "BoxMesh",
		"path": "/Main/Foo",
		"property": "mesh",
		"resource_path": "res://foo.tres",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not both")


func test_create_resource_unknown_class() -> void:
	var result := _handler.create_resource({
		"type": "NotARealClass",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Unknown")


func test_create_resource_node_class_redirects_to_create_node() -> void:
	var result := _handler.create_resource({
		"type": "Node3D",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "node_create")


func test_create_resource_non_resource_class() -> void:
	# RefCounted is neither Node nor Resource — should error.
	var result := _handler.create_resource({
		"type": "RefCounted",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not a Resource")


func test_create_resource_abstract_class() -> void:
	# Shape3D is the abstract base of BoxShape3D/SphereShape3D/etc., and
	# ClassDB.can_instantiate("Shape3D") returns false.
	var result := _handler.create_resource({
		"type": "Shape3D",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "abstract")


func test_create_resource_assigns_box_mesh_typed() -> void:
	var mi := _add_mesh_instance("TestBoxMesh")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.create_resource({
		"type": "BoxMesh",
		"path": "/%s/TestBoxMesh" % mi.get_parent().name,
		"property": "mesh",
		"properties": {"size": {"x": 2, "y": 3, "z": 4}},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.resource_class, "BoxMesh")
	assert_true(result.data.undoable)
	# Assert on the stored Variant, not just the response — per CLAUDE.md
	# "assert on stored Variant, not counts".
	assert_true(mi.mesh is BoxMesh, "mesh should be a BoxMesh instance")
	assert_true(mi.mesh.size is Vector3, "size should be coerced to Vector3")
	assert_eq(mi.mesh.size.x, 2.0)
	assert_eq(mi.mesh.size.y, 3.0)
	assert_eq(mi.mesh.size.z, 4.0)
	_remove_node(mi)


func test_create_resource_undo_restores_previous_value() -> void:
	var mi := _add_mesh_instance("TestUndo")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var old_mesh: Mesh = mi.mesh  # likely null
	var result := _handler.create_resource({
		"type": "SphereMesh",
		"path": "/%s/TestUndo" % mi.get_parent().name,
		"property": "mesh",
	})
	assert_has_key(result, "data")
	assert_true(mi.mesh is SphereMesh)
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_eq(mi.mesh, old_mesh, "Undo should restore the previous mesh value")
	assert_true(editor_redo(_undo_redo), "redo should succeed")
	assert_true(mi.mesh is SphereMesh, "Redo should re-apply the SphereMesh")
	_remove_node(mi)


func test_create_resource_property_not_on_node() -> void:
	var mi := _add_mesh_instance("TestBadProp")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.create_resource({
		"type": "BoxMesh",
		"path": "/%s/TestBadProp" % mi.get_parent().name,
		"property": "not_a_real_property",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(mi)


func test_create_resource_unknown_property_in_properties_dict() -> void:
	var mi := _add_mesh_instance("TestBadPropKey")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.create_resource({
		"type": "BoxMesh",
		"path": "/%s/TestBadPropKey" % mi.get_parent().name,
		"property": "mesh",
		"properties": {"not_a_real_field": 42},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	# Error should enrich with valid_properties so the caller can recover without a round-trip.
	assert_has_key(result.error, "data")
	assert_has_key(result.error.data, "valid_properties")
	var valid: Array = result.error.data.valid_properties
	assert_contains(valid, "size", "BoxMesh's real 'size' property should appear in valid_properties")
	# The error message should also point at resource_get_info for full discovery.
	assert_contains(result.error.message, "resource_get_info")
	_remove_node(mi)


# ----- get_resource_info -----

func test_get_resource_info_missing_type() -> void:
	var result := _handler.get_resource_info({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_get_resource_info_unknown_type() -> void:
	var result := _handler.get_resource_info({"type": "DefinitelyNotAClass_xyz"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Unknown resource type")


func test_get_resource_info_non_resource_type() -> void:
	# RefCounted is not a Resource — the error should redirect cleanly.
	var result := _handler.get_resource_info({"type": "RefCounted"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not a Resource")


func test_get_resource_info_node_type_redirects() -> void:
	var result := _handler.get_resource_info({"type": "Node3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "node_")


func test_get_resource_info_concrete_type_box_mesh() -> void:
	var result := _handler.get_resource_info({"type": "BoxMesh"})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "BoxMesh")
	assert_true(result.data.can_instantiate, "BoxMesh should be instantiable")
	assert_false(result.data.is_abstract)
	assert_gt(result.data.property_count, 0)
	var prop_names: Array = []
	for p in result.data.properties:
		prop_names.append(p.name)
	assert_contains(prop_names, "size", "BoxMesh.size must appear in properties")


func test_get_resource_info_concrete_type_cylinder_mesh() -> void:
	# The exact friction from the Night Market log: CylinderMesh uses
	# top_radius/bottom_radius, not `radius`. Tool must surface these.
	var result := _handler.get_resource_info({"type": "CylinderMesh"})
	assert_has_key(result, "data")
	var prop_names: Array = []
	for p in result.data.properties:
		prop_names.append(p.name)
	assert_contains(prop_names, "top_radius")
	assert_contains(prop_names, "bottom_radius")
	assert_contains(prop_names, "height")


func test_get_resource_info_abstract_type_shape3d() -> void:
	var result := _handler.get_resource_info({"type": "Shape3D"})
	assert_has_key(result, "data")
	assert_true(result.data.is_abstract, "Shape3D is abstract")
	assert_false(result.data.can_instantiate)
	assert_has_key(result.data, "concrete_subclasses")
	var subs: Array = result.data.concrete_subclasses
	assert_contains(subs, "BoxShape3D")
	assert_contains(subs, "SphereShape3D")


func test_get_resource_info_properties_sorted() -> void:
	var result := _handler.get_resource_info({"type": "BoxMesh"})
	assert_has_key(result, "data")
	var names: Array = []
	for p in result.data.properties:
		names.append(p.name)
	var sorted_names := names.duplicate()
	sorted_names.sort()
	assert_eq(names, sorted_names, "properties should be sorted alphabetically by name")


func test_create_resource_saves_to_disk() -> void:
	var out_path := "res://test_tmp_box.tres"
	# Clean up any prior test artifact.
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var result := _handler.create_resource({
		"type": "BoxShape3D",
		"resource_path": out_path,
		"properties": {"size": {"x": 1, "y": 2, "z": 3}},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.resource_class, "BoxShape3D")
	assert_false(result.data.undoable)
	assert_true(FileAccess.file_exists(out_path), "File should exist at %s" % out_path)
	# Cleanup hint lists the freshly-written .tres (issue #82).
	assert_has_key(result.data, "cleanup")
	assert_eq(result.data.cleanup.rm, [out_path])
	# Round-trip through ResourceLoader to verify the saved .tres is valid.
	var loaded := ResourceLoader.load(out_path)
	assert_true(loaded is BoxShape3D)
	assert_true(loaded.size is Vector3)
	assert_eq(loaded.size.x, 1.0)
	# Clean up.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))


func test_create_resource_save_refuses_overwrite_without_flag() -> void:
	var out_path := "res://test_tmp_overwrite.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var first := _handler.create_resource({
		"type": "BoxShape3D",
		"resource_path": out_path,
	})
	assert_has_key(first, "data")
	var second := _handler.create_resource({
		"type": "BoxShape3D",
		"resource_path": out_path,
	})
	assert_is_error(second, McpErrorCodes.INVALID_PARAMS)
	assert_contains(second.error.message, "overwrite")
	var third := _handler.create_resource({
		"type": "BoxShape3D",
		"resource_path": out_path,
		"overwrite": true,
	})
	assert_has_key(third, "data")
	assert_true(third.data.overwritten)
	# Overwrite must not emit a cleanup hint — the caller already had the file.
	assert_false(third.data.has("cleanup"), "Overwrite must not emit a cleanup hint")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))


func test_create_resource_undo_survives_interleaving() -> void:
	# Per CLAUDE.md "Auto-generated indices: look up at undo time" — ensure
	# undo of a resource_create survives an unrelated mutation in between.
	var mi := _add_mesh_instance("TestInterleave")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.create_resource({
		"type": "BoxMesh",
		"path": "/%s/TestInterleave" % mi.get_parent().name,
		"property": "mesh",
	})
	assert_has_key(result, "data")
	var assigned_mesh = mi.mesh
	assert_true(assigned_mesh is BoxMesh)
	# Interleave: rename the node through a separate undo action.
	_undo_redo.create_action("MCP: interleaved rename")
	_undo_redo.add_do_property(mi, "name", "Renamed")
	_undo_redo.add_undo_property(mi, "name", "TestInterleave")
	_undo_redo.commit_action()
	# Undo the interleaved action first, then the original — mesh should
	# still revert cleanly.
	assert_true(editor_undo(_undo_redo), "undo rename should succeed")
	assert_true(editor_undo(_undo_redo), "undo mesh assign should succeed")
	assert_true(mi.mesh == null or not (mi.mesh is BoxMesh), "Undo should have removed the BoxMesh")
	_remove_node(mi)


# ----- regression: properties dict __class__ shortcut for nested Resource slots -----

func test_create_resource_nested_class_dict_instantiates_sub_resource() -> void:
	# resource_create type=GradientTexture2D properties={gradient: {__class__: Gradient}}
	# should land a real Gradient in .gradient, not leave the slot empty while
	# reporting properties_applied: 1.
	var s := _add_mesh_instance("TestNestedClass")
	if s == null:
		skip("No scene root — is a scene open?")
		return
	# Use GradientTexture2D → Gradient sub-resource as the test case (flat,
	# no shader dependencies required).
	s.mesh = PlaneMesh.new()
	s.material_override = StandardMaterial3D.new()
	# Assign a GradientTexture2D via resource_create with a nested Gradient.
	var result := _handler.create_resource({
		"type": "GradientTexture2D",
		"path": "/%s/TestNestedClass" % s.get_parent().name,
		"property": "material_override",  # material_override accepts any Material, so this will fail
	})
	# Actually reposition this test: use a 2D host so we can target a
	# texture property on a TextureRect, which accepts Texture2D (GradientTexture2D).
	_remove_node(s)

	var scene_root := EditorInterface.get_edited_scene_root()
	var tr := TextureRect.new()
	tr.name = "TestNestedClassTR"
	scene_root.add_child(tr)
	tr.set_owner(scene_root)
	var r2 := _handler.create_resource({
		"type": "GradientTexture2D",
		"path": tr.get_path(),
		"property": "texture",
		"properties": {
			"gradient": {
				"__class__": "Gradient",
			},
		},
	})
	assert_has_key(r2, "data", "Expected data response; got: %s" % str(r2))
	assert_true(tr.texture is GradientTexture2D)
	# Regression: .gradient must be a real Gradient, not null and not a Dictionary.
	assert_true(tr.texture.gradient is Gradient, "Nested __class__ must instantiate sub-resource")
	_remove_node(tr)


func test_create_resource_nested_class_dict_invalid_class() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var tr := TextureRect.new()
	tr.name = "TestNestedBadClass"
	scene_root.add_child(tr)
	tr.set_owner(scene_root)
	var result := _handler.create_resource({
		"type": "GradientTexture2D",
		"path": tr.get_path(),
		"property": "texture",
		"properties": {
			"gradient": {"__class__": "NotARealClass"},
		},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(tr)
