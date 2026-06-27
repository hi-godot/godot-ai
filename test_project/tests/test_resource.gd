@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")

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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_load_resource_invalid_prefix() -> void:
	var result := _handler.load_resource({"path": "/tmp/bad.tres"})
	assert_is_error(result)


func test_load_resource_not_found() -> void:
	var result := _handler.load_resource({"path": "res://nonexistent.tres"})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


func test_load_resource_scene() -> void:
	var result := _handler.load_resource({"path": "res://main.tscn"})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "PackedScene")
	assert_has_key(result.data, "properties")
	assert_has_key(result.data, "property_count")


# ----- assign_resource -----

func test_assign_resource_missing_path() -> void:
	var result := _handler.assign_resource({"property": "mesh", "resource_path": "res://foo.tres"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_assign_resource_missing_property() -> void:
	var result := _handler.assign_resource({"path": "/Main/Camera3D", "resource_path": "res://foo.tres"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_assign_resource_missing_resource_path() -> void:
	var result := _handler.assign_resource({"path": "/Main/Camera3D", "property": "mesh"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_assign_resource_node_not_found() -> void:
	var result := _handler.assign_resource({
		"path": "/Main/DoesNotExist",
		"property": "mesh",
		"resource_path": "res://main.tscn",
	})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_assign_resource_property_not_found() -> void:
	var result := _handler.assign_resource({
		"path": "/Main/Camera3D",
		"property": "nonexistent_property_xyz",
		"resource_path": "res://main.tscn",
	})
	assert_is_error(result)
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
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_contains(result.error.message, "type")


func test_create_resource_no_home_errors() -> void:
	var result := _handler.create_resource({"type": "BoxMesh"})
	assert_is_error(result)
	assert_contains(result.error.message, "path")


func test_create_resource_both_homes_errors() -> void:
	var result := _handler.create_resource({
		"type": "BoxMesh",
		"path": "/Main/Foo",
		"property": "mesh",
		"resource_path": "res://foo.tres",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "not both")


func test_create_resource_unknown_class() -> void:
	var result := _handler.create_resource({
		"type": "NotARealClass",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "Unknown")


func test_create_resource_node_class_redirects_to_create_node() -> void:
	var result := _handler.create_resource({
		"type": "Node3D",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "node_create")


func test_create_resource_non_resource_class() -> void:
	# RefCounted is neither Node nor Resource — should error.
	var result := _handler.create_resource({
		"type": "RefCounted",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "not a Resource")


func test_create_resource_abstract_class() -> void:
	# Shape3D is the abstract base of BoxShape3D/SphereShape3D/etc., and
	# ClassDB.can_instantiate("Shape3D") returns false.
	var result := _handler.create_resource({
		"type": "Shape3D",
		"path": "/Main/Foo",
		"property": "mesh",
	})
	assert_is_error(result)
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
	assert_is_error(result)
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
	assert_is_error(result, ErrorCodes.PROPERTY_NOT_ON_CLASS)
	# Error should enrich with valid_properties so the caller can recover without a round-trip.
	assert_has_key(result.error, "data")
	assert_has_key(result.error.data, "valid_properties")
	var valid: Array = result.error.data.valid_properties
	assert_contains(valid, "size", "BoxMesh's real 'size' property should appear in valid_properties")
	# The error message must point at a LITERALLY-CALLABLE discovery verb: the MCP
	# manage tool takes only op/params/session_id, so per-op args nest in params=.
	# A flat type= kwarg is non-callable (-> MISSING_REQUIRED_PARAM).
	assert_contains(result.error.message, "resource_manage(op=\"get_info\", params={\"type\":")
	assert_false(result.error.message.contains("get_info\", type="),
		"hint must not use the non-callable flat type= kwarg")
	_remove_node(mi)


# ----- get_resource_info -----

func test_get_resource_info_missing_type() -> void:
	var result := _handler.get_resource_info({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_get_resource_info_unknown_type() -> void:
	var result := _handler.get_resource_info({"type": "DefinitelyNotAClass_xyz"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "Unknown resource type")


func test_get_resource_info_non_resource_type() -> void:
	# RefCounted is not a Resource — the error should redirect cleanly.
	var result := _handler.get_resource_info({"type": "RefCounted"})
	assert_is_error(result)
	assert_contains(result.error.message, "not a Resource")


func test_get_resource_info_node_type_redirects() -> void:
	var result := _handler.get_resource_info({"type": "Node3D"})
	assert_is_error(result)
	assert_contains(result.error.message, "node_")


func test_get_resource_info_concrete_type_box_mesh() -> void:
	var result := _handler.get_resource_info({"type": "BoxMesh"})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "BoxMesh")
	assert_true(result.data.can_instantiate, "BoxMesh should be instantiable")
	assert_false(result.data.is_abstract)
	assert_gt(result.data.property_count, 0)
	var prop_names: Array = []
	var size_prop: Dictionary = {}
	for p in result.data.properties:
		prop_names.append(p.name)
		if p.name == "size":
			size_prop = p
	assert_contains(prop_names, "size", "BoxMesh.size must appear in properties")
	assert_has_key(size_prop, "default")
	assert_eq(size_prop.default.x, 1.0)
	assert_eq(size_prop.default.y, 1.0)
	assert_eq(size_prop.default.z, 1.0)


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


func test_get_resource_info_includes_hint_string() -> void:
	var result := _handler.get_resource_info({"type": "BaseMaterial3D"})
	assert_has_key(result, "data")
	var shading_mode: Dictionary = {}
	for prop in result.data.properties:
		if prop.name == "shading_mode":
			shading_mode = prop
			break
	assert_false(shading_mode.is_empty(), "shading_mode property should be present")
	assert_contains(shading_mode.hint_string, "Unshaded")


# ----- get_resource_info for project class_name Resources -----

func test_get_resource_info_custom_class_name_lists_script_and_inherited_props() -> void:
	# Consistency: resource_create can make custom class_name Resources, so
	# get_info must answer for them too — surfacing both the script's exported
	# properties and the inherited native (Resource) properties.
	var result := _handler.get_resource_info({"type": "MyTestResource"})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "MyTestResource")
	assert_eq(result.data.parent_class, "Resource", "native base resolved via get_instance_base_type")
	assert_true(result.data.can_instantiate, "@tool custom Resource is instantiable")
	var prop_names: Array = []
	for p in result.data.properties:
		prop_names.append(p.name)
	assert_contains(prop_names, "label", "script export 'label' must be listed")
	assert_contains(prop_names, "sub", "script export 'sub' must be listed")
	assert_contains(prop_names, "resource_name", "inherited Resource property must be listed")


func test_get_resource_info_custom_class_is_side_effect_free() -> void:
	# A read-only introspection tool must NOT run _init(): resolve metadata from
	# the script + its native base, never scr.new().
	MyTestResource.init_count = 0
	var result := _handler.get_resource_info({"type": "MyTestResource"})
	assert_has_key(result, "data")
	assert_eq(MyTestResource.init_count, 0, "get_info must not construct the resource")


func test_get_resource_info_custom_class_non_resource_is_wrong_type() -> void:
	# A class_name whose native base is not a Resource (here @tool extends Node)
	# must be rejected as WRONG_TYPE — and, like the create path, without
	# constructing it (no orphan).
	McpToolNodeFixture.init_count = 0
	var result := _handler.get_resource_info({"type": "McpToolNodeFixture"})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "not a Resource type",
		"custom get_info Node-base rejection must name the type mismatch, not just the code")
	assert_eq(McpToolNodeFixture.init_count, 0,
		"non-Resource class must be rejected before construction")


func test_property_error_on_custom_resource_points_at_working_get_info() -> void:
	# Closes the loop: a bad property on a custom Resource must name the script
	# class (not the native base) and point at the real MCP discovery verb, which
	# now answers for custom class_name Resources.
	var res := MyTestResource.new()
	var err: Variant = ResourceHandler._apply_resource_properties(res, {"no_such_prop": 1})
	assert_true(err is Dictionary, "expected an error dict; got: %s" % str(err))
	if err is Dictionary:
		assert_contains(err.error.message, "MyTestResource",
			"hint should name the script class, not the native base 'Resource'")
		assert_contains(err.error.message, "resource_manage(op=\"get_info\", params={\"type\": \"MyTestResource\"})",
			"hint must be a literally-callable resource_manage(op, params={...}) form")


func test_get_resource_info_custom_props_have_uniform_default_key() -> void:
	# F3: every property entry (native inherited AND script export) must carry a
	# "default" key, so a consumer using prop["default"] (learned from a native
	# type) doesn't KeyError on the script-defined exports. Script exports carry
	# an explicit null — the resource is never constructed to read a real default.
	var result := _handler.get_resource_info({"type": "MyTestResource"})
	assert_has_key(result, "data")
	for p in result.data.properties:
		assert_has_key(p, "default", "property '%s' must carry a default key" % str(p.get("name", "?")))
	for p in result.data.properties:
		if p.name == "label":
			assert_eq(p.default, null, "script export default is null (resource is never constructed)")


func test_get_resource_info_non_tool_custom_class_not_mislabeled_abstract() -> void:
	# F4: a non-@tool concrete custom Resource is NOT abstract — it just isn't
	# instantiable in the editor. is_abstract must reflect real abstractness
	# (scr.is_abstract()), not editor-instantiability.
	var nontool := load("res://tests/mcp_non_tool_resource_fixture.gd") as Script
	assert_false(nontool.can_instantiate(),
		"fixture precondition: non-@tool script is non-instantiable in editor context")
	var result := _handler.get_resource_info({"type": "McpNonToolResource"})
	assert_has_key(result, "data")
	assert_false(result.data.is_abstract,
		"a concrete non-@tool Resource must not be reported abstract")
	assert_false(result.data.can_instantiate,
		"editor-instantiability is reported separately and is false here")


func test_get_resource_info_custom_class_reports_immediate_script_parent() -> void:
	# F5: parent_class must be the immediate SCRIPT parent for a multi-level custom
	# hierarchy (McpDerivedResource -> MyTestResource -> Resource), not the
	# collapsed native base. Inherited script exports must still surface.
	var result := _handler.get_resource_info({"type": "McpDerivedResource"})
	assert_has_key(result, "data")
	assert_eq(result.data.parent_class, "MyTestResource",
		"immediate script parent, not the native base")
	var names: Array = []
	for p in result.data.properties:
		names.append(p.name)
	assert_contains(names, "extra", "own script export must be listed")
	assert_contains(names, "label", "inherited script export (from MyTestResource) must be listed")


func test_script_base_type_or_error_reports_compile_failure_not_wrong_type() -> void:
	# F2: a registered class_name whose script fails to compile resolves to an
	# EMPTY base type; report a compile/load failure (INTERNAL_ERROR), not a
	# misleading WRONG_TYPE "(extends )". An empty GDScript reproduces the empty
	# base type (is Script, base == "") WITHOUT pushing a parse error that the
	# harness would flag as a test abort — and avoids a committed broken fixture
	# that would trip the parse gate.
	var empty := GDScript.new()
	# Dynamic dispatch on the loaded script (a Variant) — the typed const can't
	# call() directly, and this keeps the not-yet-existing helper from
	# static-parse-erroring the suite in the RED state.
	var rh: Variant = load("res://addons/godot_ai/handlers/resource_handler.gd")
	var result: Variant = rh.call("_script_base_type_or_error", empty, "McpEmptyProbe", "res://empty_probe.gd")
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	if result is Dictionary:
		assert_contains(result.error.message, "compile",
			"empty base type must be reported as a compile/parse failure")


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
	assert_is_error(second)
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
	assert_is_error(result)
	_remove_node(tr)


# ----- custom class_name Resource instantiation -----

func test_instantiate_resource_builtin_still_works() -> void:
	# Regression: engine built-ins must still resolve via ClassDB.
	assert_true(ResourceHandler._instantiate_resource("BoxMesh") is BoxMesh)


func test_instantiate_resource_custom_class_name() -> void:
	var made: Variant = ResourceHandler._instantiate_resource("MyTestResource")
	assert_true(made is MyTestResource, "should instantiate a project class_name Resource")


func test_instantiate_resource_unknown_type_errors() -> void:
	assert_is_error(ResourceHandler._instantiate_resource("NotARealType_xyz"),
		ErrorCodes.VALUE_OUT_OF_RANGE)


func test_create_resource_custom_class_to_file() -> void:
	var out_path := "res://tests/_mcp_test_custom_resource.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var result := _handler.create_resource({
		"type": "MyTestResource",
		"resource_path": out_path,
		"properties": {"label": "hi"},
	})
	assert_has_key(result, "data")
	var loaded := load(out_path)
	assert_true(loaded is MyTestResource, "saved resource should load as MyTestResource")
	assert_eq(loaded.label, "hi")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))


# ----- regression: nested __class__ shortcut must resolve project class_name -----

func test_apply_properties_nested_custom_class_name_instantiates_sub_resource() -> void:
	# The nested {"__class__": ...} shortcut must resolve project class_name
	# Resources (not just engine built-ins), mirroring the top-level
	# _instantiate_resource path. A custom MyTestResource nested in a sub-resource
	# slot must instantiate rather than failing "Unknown resource type".
	var host := MyTestResource.new()
	var err: Variant = ResourceHandler._apply_resource_properties(host, {
		"sub": {"__class__": "MyTestResource", "label": "child"},
	})
	assert_true(err == null, "nested custom class_name should apply cleanly; got: %s" % str(err))
	assert_true(host.sub is MyTestResource, "nested __class__ must instantiate the custom Resource; got: %s" % str(host.sub))
	if host.sub is MyTestResource:
		assert_eq((host.sub as MyTestResource).label, "child")


func test_instantiate_resource_non_instantiable_project_class_is_wrong_type() -> void:
	# A project class_name whose can_instantiate() is false (here a non-@tool
	# script, non-instantiable in the editor) must return WRONG_TYPE — mirroring
	# the built-in abstract path — not INTERNAL_ERROR.
	# Precondition: pin the load-bearing assumption that the non-@tool fixture is
	# non-instantiable in this (editor) context — so a future scripting-enabled
	# runner surfaces a clear precondition failure rather than a confusing
	# "expected error, got success" on the assertion below.
	var nontool := load("res://tests/mcp_non_tool_resource_fixture.gd") as Script
	assert_false(nontool.can_instantiate(),
		"fixture precondition: non-@tool script must be non-instantiable in editor context")
	var result: Variant = ResourceHandler._instantiate_resource("McpNonToolResource")
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result["error"]["message"], "@tool",
		"non-@tool rejection must point at the actionable @tool remediation")


func test_instantiate_resource_tool_node_class_rejected_before_construction() -> void:
	# Regression for the orphan-Node leak: a project class_name whose native base
	# is NOT a Resource (here @tool extends Node) must be rejected BEFORE
	# scr.new(). Because it is @tool, can_instantiate() is true, so the old
	# construct-then-reject path ran _init() and leaked the orphan Node it never
	# frees (Node is not ref-counted). The base-type gate
	# (get_instance_base_type + is_parent_class) must reject it pre-construction.
	# Precondition: the fixture IS instantiable here, so a WRONG_TYPE can only
	# come from the pre-construction base-type gate, not from can_instantiate().
	var tool_node := load("res://tests/mcp_tool_node_fixture.gd") as Script
	assert_true(tool_node.can_instantiate(),
		"fixture precondition: @tool script must be instantiable, so rejection must be pre-construction")
	McpToolNodeFixture.init_count = 0
	var result: Variant = ResourceHandler._instantiate_resource("McpToolNodeFixture")
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result["error"]["message"], "not a Resource type",
		"Node-base rejection must name the type mismatch, not just the code")
	assert_eq(McpToolNodeFixture.init_count, 0,
		"_init must NOT run: the script must be rejected before scr.new()")


func test_instantiate_resource_custom_class_with_required_init_arg_rejected() -> void:
	# A concrete @tool custom Resource whose _init() REQUIRES an argument:
	# can_instantiate() is true, so without a pre-construction guard scr.new()
	# (called with no args) raises mid-handler and aborts — the call null-cascades
	# into a generic "malformed result" error instead of a clean rejection.
	# _instantiate_resource must reject it as WRONG_TYPE BEFORE scr.new(), and
	# without running _init (no side-effect), mirroring the abstract / non-Resource
	# guards. Covers only the statically-detectable required-arg case; a _init that
	# runs but throws still falls through to the dispatcher's generic catch.
	# Precondition: the fixture IS instantiable, so the WRONG_TYPE can only come
	# from the arg-count guard, not from can_instantiate().
	var scr := load("res://tests/mcp_init_arg_fixture.gd") as Script
	assert_true(scr.can_instantiate(),
		"fixture precondition: @tool script is instantiable, so rejection must be the arg-count guard")
	McpInitArgResource.init_count = 0
	var result: Variant = ResourceHandler._instantiate_resource("McpInitArgResource")
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_eq(McpInitArgResource.init_count, 0,
		"_init must NOT run: the script must be rejected before scr.new()")
	if result is Dictionary:
		assert_contains(result.error.message, "_init",
			"message should name the _init-requires-arguments cause")


func test_apply_properties_nested_failure_names_the_property() -> void:
	# Routing the nested __class__ shortcut through _instantiate_resource must
	# still name the offending property slot in the error, preserving the
	# diagnostic context the inline path used to provide.
	var host := MyTestResource.new()
	var err: Variant = ResourceHandler._apply_resource_properties(host, {
		"sub": {"__class__": "NotARealType_xyz"},
	})
	assert_true(err is Dictionary, "expected an error dict; got: %s" % str(err))
	if err is Dictionary:
		assert_contains(err["error"]["message"], "for property 'sub'")
