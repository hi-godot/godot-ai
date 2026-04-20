@tool
extends McpTestSuite

## Tests for NodeHandler — node reads and writes.

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager

const TEST_MATERIAL_PATH := "res://tests/_mcp_test_material.tres"


func suite_name() -> String:
	return "node"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = NodeHandler.new(_undo_redo)
	var mat := StandardMaterial3D.new()
	ResourceSaver.save(mat, TEST_MATERIAL_PATH)


func suite_teardown() -> void:
	if FileAccess.file_exists(TEST_MATERIAL_PATH):
		DirAccess.remove_absolute(TEST_MATERIAL_PATH)


# ----- get_children -----

func test_get_children_of_root() -> void:
	var result := _handler.get_children({"path": "/Main"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "children")
	assert_gt(result.data.count, 0, "Main should have children")
	var names: Array[String] = []
	for child: Dictionary in result.data.children:
		names.append(child.name)
	assert_contains(names, "Camera3D")
	assert_contains(names, "World")


func test_get_children_of_world() -> void:
	var result := _handler.get_children({"path": "/Main/World"})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1, "World should have 1 child")
	assert_eq(result.data.children[0].name, "Ground")


func test_get_children_includes_metadata() -> void:
	var result := _handler.get_children({"path": "/Main"})
	var first: Dictionary = result.data.children[0]
	assert_has_key(first, "name")
	assert_has_key(first, "type")
	assert_has_key(first, "path")
	assert_has_key(first, "children_count")


func test_get_children_invalid_path() -> void:
	var result := _handler.get_children({"path": "/Main/DoesNotExist"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_get_children_missing_path() -> void:
	var result := _handler.get_children({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- get_node_properties -----

func test_get_properties_camera() -> void:
	var result := _handler.get_node_properties({"path": "/Main/Camera3D"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "properties")
	assert_eq(result.data.node_type, "Camera3D")
	## Camera3D should have "fov" among its properties
	var prop_names: Array[String] = []
	for prop: Dictionary in result.data.properties:
		prop_names.append(prop.name)
	assert_contains(prop_names, "fov", "Camera3D should have fov property")


func test_get_properties_has_value_and_type() -> void:
	var result := _handler.get_node_properties({"path": "/Main/Camera3D"})
	var fov_prop: Dictionary
	for prop: Dictionary in result.data.properties:
		if prop.name == "fov":
			fov_prop = prop
			break
	assert_has_key(fov_prop, "value")
	assert_has_key(fov_prop, "type")
	assert_eq(fov_prop.type, "float")
	assert_gt(fov_prop.value, 0, "FOV should be positive")


func test_get_properties_invalid_path() -> void:
	var result := _handler.get_node_properties({"path": "/Main/Nope"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_get_properties_missing_path() -> void:
	var result := _handler.get_node_properties({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- get_groups -----

func test_get_groups_returns_array() -> void:
	var result := _handler.get_groups({"path": "/Main/Camera3D"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "groups")
	assert_true(result.data.groups is Array, "groups should be an Array")


func test_get_groups_invalid_path() -> void:
	var result := _handler.get_groups({"path": "/Main/Missing"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- create_node -----

func test_create_node_basic() -> void:
	var result := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTest",
		"parent_path": "/Main",
	})
	assert_has_key(result, "data")
	assert_true(str(result.data.name).begins_with("_McpTest"), "Name should start with _McpTest")
	assert_eq(result.data.type, "Node3D")
	assert_true(result.data.undoable, "Create should be undoable")
	## Clean up via undo (reverses the create action)
	_undo_redo.undo()


func test_create_node_invalid_type() -> void:
	var result := _handler.create_node({"type": "NotARealNodeType"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_node_missing_type() -> void:
	var result := _handler.create_node({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_node_non_node_type() -> void:
	var result := _handler.create_node({"type": "Resource"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_node_accepts_root_alias_for_parent_path() -> void:
	## Agents reach for /root/Main right after scene creation. Resolve it as
	## an alias for the edited scene root rather than failing.
	var result := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTestRootAlias",
		"parent_path": "/root/Main",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.parent_path, "/Main", "should resolve to scene root")
	_undo_redo.undo()


func test_create_node_parent_not_found_error_names_convention() -> void:
	## The plain "Parent not found: X" error doesn't tell the agent that
	## paths are scene-relative. The upgraded message must spell that out.
	var result := _handler.create_node({
		"type": "Node3D",
		"parent_path": "/SomeBogusPath",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "relative to the edited scene root")
	assert_contains(result.error.message, "Scene root is")


# ----- delete_node -----

func test_delete_node_basic() -> void:
	## Create a node, then delete it
	_handler.create_node({
		"type": "Node3D",
		"name": "_McpTestDelete",
		"parent_path": "/Main",
	})
	var result := _handler.delete_node({"path": "/Main/_McpTestDelete"})
	assert_has_key(result, "data")
	assert_true(result.data.undoable, "Delete should be undoable")


func test_delete_node_scene_root() -> void:
	var result := _handler.delete_node({"path": "/Main"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_delete_node_invalid_path() -> void:
	var result := _handler.delete_node({"path": "/Main/DoesNotExist"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_delete_node_missing_path() -> void:
	var result := _handler.delete_node({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- reparent_node -----

func test_reparent_scene_root() -> void:
	var result := _handler.reparent_node({"path": "/Main", "new_parent": "/Main/World"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_reparent_missing_new_parent() -> void:
	var result := _handler.reparent_node({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_reparent_to_self() -> void:
	var result := _handler.reparent_node({"path": "/Main/Camera3D", "new_parent": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- set_property -----

func test_set_property_float() -> void:
	var result := _handler.set_property({
		"path": "/Main/Camera3D",
		"property": "fov",
		"value": 90.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.property, "fov")
	assert_true(result.data.undoable, "Set property should be undoable")
	## Restore via undo
	_undo_redo.undo()


func test_set_property_missing_property() -> void:
	var result := _handler.set_property({"path": "/Main/Camera3D", "value": 10})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_property_missing_value() -> void:
	var result := _handler.set_property({"path": "/Main/Camera3D", "property": "fov"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_property_resource_path() -> void:
	## Use a fresh MeshInstance3D for a clean material_override slot.
	_handler.create_node({
		"type": "MeshInstance3D",
		"name": "_McpTestMat",
		"parent_path": "/Main",
	})
	var result := _handler.set_property({
		"path": "/Main/_McpTestMat",
		"property": "material_override",
		"value": TEST_MATERIAL_PATH,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.value, TEST_MATERIAL_PATH)
	assert_true(result.data.undoable)
	_undo_redo.undo()  # undo assign
	_undo_redo.undo()  # undo create


func test_set_property_resource_not_found() -> void:
	var result := _handler.set_property({
		"path": "/Main/Camera3D",
		"property": "environment",
		"value": "res://does/not/exist.tres",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_property_resource_null_clears() -> void:
	_handler.create_node({
		"type": "MeshInstance3D",
		"name": "_McpTestClear",
		"parent_path": "/Main",
	})
	_handler.set_property({
		"path": "/Main/_McpTestClear",
		"property": "material_override",
		"value": TEST_MATERIAL_PATH,
	})
	var result := _handler.set_property({
		"path": "/Main/_McpTestClear",
		"property": "material_override",
		"value": null,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.value, null)
	_undo_redo.undo()
	_undo_redo.undo()
	_undo_redo.undo()


func test_set_property_node_path() -> void:
	_handler.create_node({
		"type": "RemoteTransform3D",
		"name": "_McpTestRemote",
		"parent_path": "/Main",
	})
	var result := _handler.set_property({
		"path": "/Main/_McpTestRemote",
		"property": "remote_path",
		"value": "../Camera3D",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.value, "../Camera3D")
	_undo_redo.undo()
	_undo_redo.undo()


func test_set_property_nonexistent_property() -> void:
	var result := _handler.set_property({
		"path": "/Main/Camera3D",
		"property": "nonexistent_xyz",
		"value": 42,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- set_property __class__ shortcut (fresh built-in Resource) -----

func _add_mesh_instance_for_shortcut(node_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = node_name
	scene_root.add_child(mi)
	mi.set_owner(scene_root)
	return mi


func test_set_property_class_dict_instantiates_fresh_resource() -> void:
	var mi := _add_mesh_instance_for_shortcut("TestClassDictBox")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_property({
		"path": "/%s/TestClassDictBox" % mi.get_parent().name,
		"property": "mesh",
		"value": {"__class__": "BoxMesh", "size": {"x": 2, "y": 3, "z": 4}},
	})
	assert_has_key(result, "data")
	# Assert on stored Variant — not just the response — per CLAUDE.md.
	assert_true(mi.mesh is BoxMesh, "mesh should be a BoxMesh instance")
	assert_true(mi.mesh.size is Vector3)
	assert_eq(mi.mesh.size.x, 2.0)
	assert_eq(mi.mesh.size.z, 4.0)
	# Undo should restore null.
	editor_undo(_undo_redo)
	assert_true(mi.mesh == null)
	if mi.get_parent():
		mi.get_parent().remove_child(mi)
	mi.queue_free()


func test_set_property_class_dict_invalid_class() -> void:
	var mi := _add_mesh_instance_for_shortcut("TestClassDictBad")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_property({
		"path": "/%s/TestClassDictBad" % mi.get_parent().name,
		"property": "mesh",
		"value": {"__class__": "NotARealClass"},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	if mi.get_parent():
		mi.get_parent().remove_child(mi)
	mi.queue_free()


func test_set_property_class_dict_abstract_class() -> void:
	var mi := _add_mesh_instance_for_shortcut("TestClassDictAbstract")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	# Shape3D is truly abstract per ClassDB.can_instantiate().
	# PrimitiveMesh is technically instantiable, so it's not a good test target.
	var result := _handler.set_property({
		"path": "/%s/TestClassDictAbstract" % mi.get_parent().name,
		"property": "mesh",
		"value": {"__class__": "Shape3D"},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "abstract")
	if mi.get_parent():
		mi.get_parent().remove_child(mi)
	mi.queue_free()


func test_set_property_resource_path_still_works() -> void:
	# Regression: __class__ shortcut must not break the existing
	# "string value = res:// path" behavior.
	var mi := _add_mesh_instance_for_shortcut("TestResPathRegression")
	if mi == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_property({
		"path": "/%s/TestResPathRegression" % mi.get_parent().name,
		"property": "material_override",
		"value": TEST_MATERIAL_PATH,
	})
	assert_has_key(result, "data")
	assert_true(mi.material_override is StandardMaterial3D)
	editor_undo(_undo_redo)
	if mi.get_parent():
		mi.get_parent().remove_child(mi)
	mi.queue_free()


# ----- _coerce_value / _serialize_value unit coverage -----

func test_coerce_array_passthrough() -> void:
	var coerced = NodeHandler._coerce_value([1, 2, 3], TYPE_ARRAY)
	assert_true(coerced is Array)
	assert_eq(coerced.size(), 3)


func test_coerce_dictionary_passthrough() -> void:
	var coerced = NodeHandler._coerce_value({"a": 1, "b": 2}, TYPE_DICTIONARY)
	assert_true(coerced is Dictionary)
	assert_eq(coerced["a"], 1)


func test_coerce_node_path_from_string() -> void:
	var coerced = NodeHandler._coerce_value("../Sibling", TYPE_NODE_PATH)
	assert_true(coerced is NodePath)
	assert_eq(str(coerced), "../Sibling")


func test_coerce_string_name_from_string() -> void:
	var coerced = NodeHandler._coerce_value("my_name", TYPE_STRING_NAME)
	assert_true(coerced is StringName)


func test_serialize_array_recursive() -> void:
	var result = NodeHandler._serialize_value([Vector2(1, 2), "hello", 3])
	assert_true(result is Array)
	assert_eq(result[0]["x"], 1.0)
	assert_eq(result[1], "hello")


func test_serialize_dictionary_recursive() -> void:
	var result = NodeHandler._serialize_value({"pos": Vector3(1, 2, 3), "name": "x"})
	assert_true(result is Dictionary)
	assert_eq(result["pos"]["z"], 3.0)
	assert_eq(result["name"], "x")


# ----- rename_node -----

func test_rename_node_basic() -> void:
	var suffix := str(Time.get_ticks_usec())
	var created := _handler.create_node({
		"type": "Node3D",
		"name": "_McpRenameSrc%s" % suffix,
		"parent_path": "/Main",
	})
	assert_has_key(created, "data")
	var created_path: String = created.data.path
	var created_name: String = created.data.name
	var target_name := "_McpRenameDst%s" % suffix
	var result := _handler.rename_node({
		"path": created_path,
		"new_name": target_name,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.name, target_name)
	assert_eq(result.data.old_name, created_name)
	assert_true(result.data.undoable)
	_undo_redo.undo()
	_undo_redo.undo()


func test_rename_node_scene_root() -> void:
	# Renaming the scene root is allowed (not the .tscn file path, just the node name).
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var old_name := String(scene_root.name)
	var result := _handler.rename_node({"path": "/" + old_name, "new_name": "RenamedTestRoot"})
	assert_has_key(result, "data")
	assert_eq(result.data.name, "RenamedTestRoot")
	assert_true(result.data.undoable)
	# Restore the original name to avoid polluting other tests.
	var restore := _handler.rename_node({"path": "/RenamedTestRoot", "new_name": old_name})
	assert_has_key(restore, "data")
	assert_eq(String(scene_root.name), old_name)


func test_rename_node_missing_name() -> void:
	var result := _handler.rename_node({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rename_node_invalid_characters() -> void:
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "foo/bar",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rename_node_sibling_collision() -> void:
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "World",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rename_node_unchanged() -> void:
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "Camera3D",
	})
	assert_has_key(result, "data")
	assert_true(result.data.unchanged, "Should flag unchanged rename")
	assert_false(result.data.undoable)


func test_rename_node_invalid_path() -> void:
	var result := _handler.rename_node({
		"path": "/Main/Nope",
		"new_name": "NewName",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- duplicate_node -----

func test_duplicate_node_basic() -> void:
	var result := _handler.duplicate_node({
		"path": "/Main/Camera3D",
		"name": "_McpTestDuplicate",
	})
	assert_has_key(result, "data")
	assert_true(str(result.data.name).begins_with("_McpTestDuplicate"))
	assert_eq(result.data.type, "Camera3D")
	assert_true(result.data.undoable)
	## Clean up via undo
	_undo_redo.undo()


func test_duplicate_scene_root() -> void:
	var result := _handler.duplicate_node({"path": "/Main"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_duplicate_node_invalid_path() -> void:
	var result := _handler.duplicate_node({"path": "/Main/NoSuchNode"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- move_node -----

func test_move_node_scene_root() -> void:
	var result := _handler.move_node({"path": "/Main", "index": 0})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_move_node_missing_index() -> void:
	var result := _handler.move_node({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_move_node_out_of_range() -> void:
	var result := _handler.move_node({"path": "/Main/Camera3D", "index": 999})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- add_to_group / remove_from_group -----

func test_add_to_group() -> void:
	## Ensure clean state: remove from group if left over from a previous run
	var scene_root := EditorInterface.get_edited_scene_root()
	var cam := ScenePath.resolve("/Main/Camera3D", scene_root)
	if cam and cam.is_in_group("_mcp_test_group"):
		cam.remove_from_group("_mcp_test_group")

	var result := _handler.add_to_group({
		"path": "/Main/Camera3D",
		"group": "_mcp_test_group",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.group, "_mcp_test_group")
	assert_true(result.data.undoable)
	## Clean up via undo
	_undo_redo.undo()


func test_add_to_group_missing_group() -> void:
	var result := _handler.add_to_group({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_remove_from_group_not_member() -> void:
	var result := _handler.remove_from_group({
		"path": "/Main/Camera3D",
		"group": "_mcp_nonexistent_group",
	})
	assert_has_key(result, "data")
	assert_true(result.data.not_member, "Should indicate not a member")


func test_remove_from_group_missing_group() -> void:
	var result := _handler.remove_from_group({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- set_selection -----

func test_set_selection_basic() -> void:
	var result := _handler.set_selection({
		"paths": ["/Main/Camera3D", "/Main/World"],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 2)
	assert_contains(result.data.selected, "/Main/Camera3D")
	assert_contains(result.data.selected, "/Main/World")


func test_set_selection_with_invalid_path() -> void:
	var result := _handler.set_selection({
		"paths": ["/Main/Camera3D", "/Main/NotReal"],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1)
	assert_contains(result.data.not_found, "/Main/NotReal")


func test_set_selection_empty_clears() -> void:
	var result := _handler.set_selection({"paths": []})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 0)


# ============================================================================
# Friction fix: scene instancing via node_create
# ============================================================================

func test_create_node_from_scene_path() -> void:
	# Use the test project's own main.tscn as the scene to instance.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var before_count := scene_root.get_child_count()
	var result := _handler.create_node({
		"scene_path": "res://main.tscn",
		"name": "InstancedMain",
	})
	assert_has_key(result, "data")
	assert_has_key(result.data, "scene_path")
	assert_eq(result.data.scene_path, "res://main.tscn")
	assert_true(result.data.undoable)
	# Clean up: remove the instanced node.
	var instanced := scene_root.find_child("InstancedMain", false, false)
	if instanced:
		scene_root.remove_child(instanced)
		instanced.queue_free()
	assert_eq(scene_root.get_child_count(), before_count, "Cleanup should restore child count")


func test_create_node_scene_path_preserves_instance_link() -> void:
	# A scene instanced via GEN_EDIT_STATE_INSTANCE must carry scene_file_path
	# so the editor treats it as a real instance (foldout icon, swappable, the
	# .tscn stores a reference rather than an exploded subtree).
	#
	# We use a throwaway PackedScene to avoid self-instancing main.tscn.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var tmp_root := Node2D.new()
	tmp_root.name = "TmpInstanceRoot"
	var tmp_child := Node2D.new()
	tmp_child.name = "TmpChild"
	tmp_root.add_child(tmp_child)
	tmp_child.owner = tmp_root
	var packed := PackedScene.new()
	packed.pack(tmp_root)
	var tmp_path := "res://tests/_mcp_test_instance.tscn"
	ResourceSaver.save(packed, tmp_path)
	tmp_root.queue_free()

	var result := _handler.create_node({
		"scene_path": tmp_path,
		"name": "InstancedTmp",
	})
	assert_has_key(result, "data")
	var instanced: Node = scene_root.find_child("InstancedTmp", false, false)
	assert_true(instanced != null, "Instanced node exists")
	# The root of an instanced scene carries scene_file_path pointing to the .tscn.
	assert_eq(instanced.scene_file_path, tmp_path, "scene_file_path preserves instance link")
	# Descendants of an instance are NOT owned by our scene_root — they're owned
	# by the sub-scene, which is what makes Godot treat it as an instance.
	var desc: Node = instanced.find_child("TmpChild", false, false)
	assert_true(desc != null, "Descendant exists")
	assert_true(desc.owner != scene_root, "Descendant owner stays with sub-scene, not our scene_root")
	# Cleanup.
	instanced.get_parent().remove_child(instanced)
	instanced.queue_free()
	DirAccess.remove_absolute(tmp_path)


func test_create_node_scene_path_undo_redo() -> void:
	# Undo removes the instance; redo restores it with the same scene link.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var tmp_root := Node2D.new()
	tmp_root.name = "UndoInstanceRoot"
	var packed := PackedScene.new()
	packed.pack(tmp_root)
	var tmp_path := "res://tests/_mcp_test_undo_instance.tscn"
	ResourceSaver.save(packed, tmp_path)
	tmp_root.queue_free()

	var before := scene_root.get_child_count()
	_handler.create_node({"scene_path": tmp_path, "name": "UndoInstance"})
	assert_eq(scene_root.get_child_count(), before + 1, "Instance added")

	_undo_redo.undo()
	assert_eq(scene_root.get_child_count(), before, "Undo removes the instance")
	assert_true(scene_root.find_child("UndoInstance", false, false) == null, "No node after undo")

	_undo_redo.redo()
	assert_eq(scene_root.get_child_count(), before + 1, "Redo restores the instance")
	var restored: Node = scene_root.find_child("UndoInstance", false, false)
	assert_true(restored != null, "Instance back after redo")
	assert_eq(restored.scene_file_path, tmp_path, "scene_file_path preserved through redo")
	# Cleanup.
	restored.get_parent().remove_child(restored)
	restored.queue_free()
	DirAccess.remove_absolute(tmp_path)


func test_create_node_scene_path_not_found() -> void:
	var result := _handler.create_node({
		"scene_path": "res://nonexistent_scene.tscn",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not found")


func test_create_node_scene_path_not_res() -> void:
	var result := _handler.create_node({
		"scene_path": "/tmp/scene.tscn",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "res://")


func test_create_node_requires_type_or_scene_path() -> void:
	var result := _handler.create_node({"parent_path": ""})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "type")


# ----- scene_file guard (issue #74) -----
# Every mutating node_handler entry point routes through either create_node
# (which reads scene_file directly) or _resolve_node (which reads it via
# params). Covering one of each is enough to show the wiring is live; the
# helper's own behavior is covered in test_scene_path.

func test_create_node_scene_file_mismatch_blocks_mutation() -> void:
	var result := _handler.create_node({
		"type": "Node",
		"scene_file": "res://does/not/match.tscn",
	})
	assert_is_error(result, McpErrorCodes.EDITED_SCENE_MISMATCH)


func test_resolve_node_scene_file_mismatch_blocks_mutation() -> void:
	## rename_node routes through _resolve_node. If the guard fires early, the
	## rename never reaches the node and no sibling-name validation happens.
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "ShouldNotRename",
		"scene_file": "res://does/not/match.tscn",
	})
	assert_is_error(result, McpErrorCodes.EDITED_SCENE_MISMATCH)
	## And it did NOT actually rename — the original node stays put.
	var cam := EditorInterface.get_edited_scene_root().get_node_or_null("Camera3D")
	assert_ne(cam, null, "Camera3D must still exist under the original name")


func test_create_node_scene_file_matching_active_scene_passes() -> void:
	var active := EditorInterface.get_edited_scene_root().scene_file_path
	var result := _handler.create_node({
		"type": "Node",
		"name": "SceneFileGuardOK",
		"scene_file": active,
	})
	assert_has_key(result, "data")
	## Undo so we don't leak test state into downstream tests.
	_undo_redo.undo()


