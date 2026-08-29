@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")

## Tests for NodeHandler — node reads and writes.

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager

const TEST_MATERIAL_PATH := "res://tests/_mcp_test_material.tres"
const TEST_NODE_SCRIPT_PATH := "res://tests/_mcp_test_node_script.gd"


func suite_name() -> String:
	return "node"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = NodeHandler.new(_undo_redo)
	var mat := StandardMaterial3D.new()
	ResourceSaver.save(mat, TEST_MATERIAL_PATH)
	# Fixture script for the attached-script serialization test.
	var file := FileAccess.open(TEST_NODE_SCRIPT_PATH, FileAccess.WRITE)
	if file:
		file.store_string("extends Node3D\n")
		file.close()


func suite_teardown() -> void:
	if FileAccess.file_exists(TEST_MATERIAL_PATH):
		DirAccess.remove_absolute(TEST_MATERIAL_PATH)
	if FileAccess.file_exists(TEST_NODE_SCRIPT_PATH):
		DirAccess.remove_absolute(TEST_NODE_SCRIPT_PATH)
	if FileAccess.file_exists(TEST_NODE_SCRIPT_PATH + ".uid"):
		DirAccess.remove_absolute(TEST_NODE_SCRIPT_PATH + ".uid")


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
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_get_children_missing_path() -> void:
	var result := _handler.get_children({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


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


func test_get_properties_reports_total_count() -> void:
	var result := _handler.get_node_properties({"path": "/Main/Camera3D"})
	assert_has_key(result.data, "total_count")
	## An unfiltered call returns every editor-visible property — null-valued
	## ones included (#771) — so count and total_count agree exactly. Only the
	## `fields` filter can make count < total_count.
	assert_eq(
		result.data.count,
		result.data.total_count,
		"unfiltered call returns every editor-visible property",
	)
	assert_gt(result.data.total_count, 0, "Camera3D has editor-visible properties")


func test_get_properties_fields_filter_returns_only_requested() -> void:
	var full := _handler.get_node_properties({"path": "/Main/Camera3D"})
	var filtered := _handler.get_node_properties({
		"path": "/Main/Camera3D",
		"fields": ["fov", "current"],
	})
	var names: Array[String] = []
	for prop: Dictionary in filtered.data.properties:
		names.append(prop.name)
	names.sort()
	assert_eq(names, ["current", "fov"], "Only requested fields returned")
	assert_eq(filtered.data.count, 2)
	## total_count is unaffected by the filter — it reflects the full set so a
	## caller knows how much was withheld.
	assert_eq(
		filtered.data.total_count,
		full.data.total_count,
		"total_count reflects the full property set regardless of fields",
	)
	assert_true(filtered.data.count < full.data.count, "fields cuts the response")


func test_get_properties_fields_unknown_name_is_reported() -> void:
	## Unknown names are no longer silently skipped (#771): known fields come
	## back (even null-valued ones like `script`), unknown ones are listed in
	## unknown_fields so callers can tell "doesn't exist" from "is null".
	var result := _handler.get_node_properties({
		"path": "/Main/Camera3D",
		"fields": ["script", "no_such_prop"],
	})
	var names: Array[String] = []
	for prop: Dictionary in result.data.properties:
		names.append(prop.name)
	assert_eq(names, ["script"], "known field names are returned, unknown ones are not")
	assert_has_key(result.data, "unknown_fields")
	assert_eq(
		result.data.unknown_fields,
		["no_such_prop"],
		"requested names matching no editor-visible property are reported",
	)


func test_get_properties_null_script_returned_as_null() -> void:
	## Camera3D in the test scene has no script attached. `script` is
	## editor-visible with a null value and must be returned as value: null
	## with its declared type, not dropped from the response (#771).
	var result := _handler.get_node_properties({
		"path": "/Main/Camera3D",
		"fields": ["script"],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1, "script property should be returned")
	var prop: Dictionary = result.data.properties[0]
	assert_eq(prop.name, "script")
	assert_eq(prop.value, null, "unscripted node reports script as null")
	assert_eq(result.data.unknown_fields, [], "script is a real property, not unknown")


func test_get_properties_attached_script_returns_res_path() -> void:
	var created := _handler.create_node({
		"type": "Node3D",
		"name": "_McpScriptProbe",
		"parent_path": "/Main",
	})
	assert_has_key(created, "data")
	var scene_root := EditorInterface.get_edited_scene_root()
	var node: Node = scene_root.get_node_or_null(NodePath(String(created.data.name)))
	assert_true(node != null, "created probe node should be resolvable")
	var script: Script = load(TEST_NODE_SCRIPT_PATH)
	assert_true(script != null, "fixture script should load")
	node.set_script(script)

	var result := _handler.get_node_properties({
		"path": String(created.data.path),
		"fields": ["script"],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1, "script property should be returned")
	assert_eq(result.data.properties[0].name, "script")
	assert_eq(
		result.data.properties[0].value,
		TEST_NODE_SCRIPT_PATH,
		"attached script serializes to its res:// path",
	)

	## Detach before undoing the create so the fixture script isn't referenced
	## by the undo stack when suite_teardown deletes the file.
	node.set_script(null)
	assert_true(editor_undo(_undo_redo), "undo should remove the probe node")


func test_get_properties_fields_non_array_is_rejected() -> void:
	## The MCP tool types `fields` as a list, but batch_execute / raw callers
	## bypass that, so a malformed value must be rejected, not crash the loop.
	var result := _handler.get_node_properties({
		"path": "/Main/Camera3D",
		"fields": "fov",
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)


func test_get_properties_fields_non_string_element_is_rejected() -> void:
	## Elements must be property-name strings — [123] silently stringified
	## would become a filter that matches nothing and look like an empty node.
	var result := _handler.get_node_properties({
		"path": "/Main/Camera3D",
		"fields": ["fov", 123],
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)


func test_get_properties_invalid_path() -> void:
	var result := _handler.get_node_properties({"path": "/Main/Nope"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_get_properties_missing_path() -> void:
	var result := _handler.get_node_properties({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


# ----- get_groups -----

func test_get_groups_returns_array() -> void:
	var result := _handler.get_groups({"path": "/Main/Camera3D"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "groups")
	assert_true(result.data.groups is Array, "groups should be an Array")


func test_get_groups_invalid_path() -> void:
	var result := _handler.get_groups({"path": "/Main/Missing"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_create_node_invalid_type() -> void:
	var result := _handler.create_node({"type": "NotARealNodeType"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_create_node_missing_type() -> void:
	var result := _handler.create_node({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_create_node_non_node_type() -> void:
	var result := _handler.create_node({"type": "Resource"})
	assert_is_error(result)


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_create_node_parent_not_found_error_names_convention() -> void:
	## The plain "Parent not found: X" error doesn't tell the agent that
	## paths are scene-relative. The upgraded message must spell that out.
	var result := _handler.create_node({
		"type": "Node3D",
		"parent_path": "/SomeBogusPath",
	})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)
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
	## Read back from the scene: the response alone can't prove the commit
	## actually removed the node.
	var scene_root := EditorInterface.get_edited_scene_root()
	var survivor := scene_root.find_child("_McpTestDelete", true, false)
	assert_true(survivor == null, "Node should actually be gone from the scene tree")


func test_delete_node_scene_root() -> void:
	var result := _handler.delete_node({"path": "/Main"})
	assert_is_error(result)


func test_delete_node_invalid_path() -> void:
	var result := _handler.delete_node({"path": "/Main/DoesNotExist"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_delete_node_missing_path() -> void:
	var result := _handler.delete_node({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


# ----- reparent_node -----

func test_reparent_scene_root() -> void:
	var result := _handler.reparent_node({"path": "/Main", "new_parent": "/Main/World"})
	assert_is_error(result)


func test_reparent_missing_new_parent() -> void:
	var result := _handler.reparent_node({"path": "/Main/Camera3D"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_reparent_to_self() -> void:
	var result := _handler.reparent_node({"path": "/Main/Camera3D", "new_parent": "/Main/Camera3D"})
	assert_is_error(result)


func test_reparent_to_own_descendant_errors_without_destroying_subtree() -> void:
	## Issue #121 regression test. Before the fix, reparenting a node into one
	## of its own descendants would silently succeed, destroying the entire
	## subtree (both the node and the descendant disappeared from the scene).
	## The cycle-check `new_parent.is_ancestor_of(node)` was inverted — it
	## caught "reparent to own ancestor" (a valid operation) rather than
	## "reparent to own descendant" (the one that creates a cycle).
	##
	## Build a throwaway _McpTestReparent/_McpTestChild subtree so the test
	## can't pollute the shared scene fixture regardless of the outcome.
	var chain := _build_temp_chain(["_McpTestReparent", "_McpTestChild"] as Array[String])
	var scene_root := EditorInterface.get_edited_scene_root()
	var parent_before := scene_root.get_node_or_null("_McpTestReparent")
	var child_before := scene_root.get_node_or_null("_McpTestReparent/_McpTestChild")
	assert_ne(parent_before, null, "precondition: parent subtree created")
	assert_ne(child_before, null, "precondition: child under parent created")

	var result := _handler.reparent_node({
		"path": "/Main/_McpTestReparent",
		"new_parent": chain.leaf_path,
	})
	assert_is_error(result)

	## Subtree must be unchanged — no accidental remove_child() should have run.
	assert_eq(scene_root.get_node_or_null("_McpTestReparent"), parent_before, "parent must still exist")
	assert_eq(scene_root.get_node_or_null("_McpTestReparent/_McpTestChild"), child_before, "child must still exist under parent")

	chain.teardown.call()


func test_reparent_to_ancestor_is_allowed() -> void:
	## Coverage for the other half of the inverted cycle check: reparenting a
	## node UP to one of its own ancestors is a perfectly valid operation and
	## must succeed. Before the #121 fix this path would have been rejected
	## by the inverted check.
	##
	## Build a throwaway _McpTestUpParent/_McpTestUpChild/_McpTestUpGrand
	## subtree and reparent the grandchild up to the parent. Previous
	## revisions of this test mutated shared scene nodes (/Main/World/Ground)
	## and relied on _undo_redo.undo() to restore the scene for downstream
	## suites — that teardown was flaky in CI and polluted scene_* tests.
	var chain := _build_temp_chain(
		["_McpTestUpParent", "_McpTestUpChild", "_McpTestUpGrand"] as Array[String]
	)
	var scene_root := EditorInterface.get_edited_scene_root()

	var result := _handler.reparent_node({
		"path": chain.leaf_path,
		"new_parent": "/Main/_McpTestUpParent",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable, "reparent-up should be undoable")
	assert_ne(scene_root.get_node_or_null("_McpTestUpParent/_McpTestUpGrand"), null,
		"Grand should now be a direct child of _McpTestUpParent")

	## Unwind: undo reparent first, then unwind each create via the helper.
	## editor_undo walks both scene and global histories so actions registered
	## against different targets unwind reliably across the chain.
	editor_undo(_undo_redo)  # reparent
	chain.teardown.call()


func test_reparent_preserves_descendant_owner_on_undo() -> void:
	## Issue #904: descendant ownership was applied after commit_action, so
	## undo of reparent left children with a null owner (Godot's remove_child
	## clears owner on the pruned subtree).
	var chain := _build_temp_chain(
		["_McpTestOwnerParent", "_McpTestOwnerChild"] as Array[String]
	)
	var dest := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTestOwnerDest",
		"parent_path": "/Main",
	})
	assert_has_key(dest, "data")
	assert_eq(dest.data.name, "_McpTestOwnerDest")

	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.reparent_node({
		"path": "/Main/_McpTestOwnerParent",
		"new_parent": "/Main/_McpTestOwnerDest",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable, "reparent should be undoable")

	var child_after := scene_root.get_node_or_null(
		"_McpTestOwnerDest/_McpTestOwnerParent/_McpTestOwnerChild"
	)
	assert_ne(child_after, null, "child must exist under the new parent")
	assert_eq(child_after.owner, scene_root, "child owner should be scene root after reparent")

	assert_true(editor_undo(_undo_redo), "undo reparent should succeed")
	var child := scene_root.get_node_or_null("_McpTestOwnerParent/_McpTestOwnerChild")
	assert_ne(child, null, "child must exist under original parent after undo")
	assert_ne(child.owner, null, "child owner must not be null after undo")
	assert_eq(child.owner, scene_root, "child owner must still be the scene root after undo")

	assert_true(editor_undo(_undo_redo), "undo dest create should succeed")
	chain.teardown.call()


func test_reparent_restores_owned_and_unowned_descendants_on_undo_redo() -> void:
	## #904 review: undo must restore a null owner unchanged rather than
	## substituting scene_root. One subtree with both a scene-owned and an
	## unowned child, covering do / undo / redo.
	var parent_res := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTestMixParent",
		"parent_path": "/Main",
	})
	assert_has_key(parent_res, "data")
	assert_eq(parent_res.data.name, "_McpTestMixParent")
	var owned_res := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTestMixOwned",
		"parent_path": "/Main/_McpTestMixParent",
	})
	assert_has_key(owned_res, "data")
	assert_eq(owned_res.data.name, "_McpTestMixOwned")
	var unowned_res := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTestMixUnowned",
		"parent_path": "/Main/_McpTestMixParent",
	})
	assert_has_key(unowned_res, "data")
	assert_eq(unowned_res.data.name, "_McpTestMixUnowned")

	var scene_root := EditorInterface.get_edited_scene_root()
	var owned := scene_root.get_node_or_null("_McpTestMixParent/_McpTestMixOwned")
	var unowned := scene_root.get_node_or_null("_McpTestMixParent/_McpTestMixUnowned")
	assert_ne(owned, null, "precondition: owned child exists")
	assert_ne(unowned, null, "precondition: unowned child exists")
	assert_eq(owned.owner, scene_root, "precondition: owned child is scene-owned")
	unowned.owner = null
	assert_eq(unowned.owner, null, "precondition: unowned child has a null owner")

	var dest := _handler.create_node({
		"type": "Node3D",
		"name": "_McpTestMixDest",
		"parent_path": "/Main",
	})
	assert_has_key(dest, "data")
	assert_eq(dest.data.name, "_McpTestMixDest")

	var result := _handler.reparent_node({
		"path": "/Main/_McpTestMixParent",
		"new_parent": "/Main/_McpTestMixDest",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable, "reparent should be undoable")
	assert_eq(owned.owner, scene_root, "owned child is scene-owned after reparent")
	assert_eq(unowned.owner, scene_root, "unowned child is scene-owned after reparent")

	assert_true(editor_undo(_undo_redo), "undo reparent should succeed")
	assert_eq(owned.owner, scene_root, "owned child owner restored to scene root on undo")
	assert_eq(unowned.owner, null, "unowned child owner restored to null on undo")

	assert_true(editor_redo(_undo_redo), "redo reparent should succeed")
	assert_eq(owned.owner, scene_root, "owned child is scene-owned after redo")
	assert_eq(unowned.owner, scene_root, "unowned child is scene-owned after redo")

	assert_true(editor_undo(_undo_redo), "undo reparent after redo should succeed")
	assert_eq(owned.owner, scene_root, "owned child owner restored after second undo")
	assert_eq(unowned.owner, null, "unowned child owner restored to null after second undo")

	assert_true(editor_undo(_undo_redo), "undo dest create should succeed")
	assert_true(editor_undo(_undo_redo), "undo unowned create should succeed")
	assert_true(editor_undo(_undo_redo), "undo owned create should succeed")
	assert_true(editor_undo(_undo_redo), "undo parent create should succeed")


## Build a nested chain of throwaway Node3D test nodes under /Main, returning
## the deepest path and a teardown closure that unwinds each create via undo.
func _build_temp_chain(names: Array[String]) -> Dictionary:
	var parent_path := "/Main"
	for name in names:
		_handler.create_node({"type": "Node3D", "name": name, "parent_path": parent_path})
		parent_path += "/" + name
	var teardown := func() -> void:
		for _i in names.size():
			editor_undo(_undo_redo)
	return {"leaf_path": parent_path, "teardown": teardown}


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_set_property_missing_property() -> void:
	var result := _handler.set_property({"path": "/Main/Camera3D", "value": 10})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_set_property_missing_value() -> void:
	var result := _handler.set_property({"path": "/Main/Camera3D", "property": "fov"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_set_property_vector3_accepts_valid_dict() -> void:
	## Positive guard for the #123 fix: a right-shape Vector3 dict must
	## still coerce and land correctly. Prevents over-correcting the strict
	## key check from breaking the happy path.
	_handler.create_node({"type": "Node3D", "name": "_McpTestV3", "parent_path": "/Main"})
	var result := _handler.set_property({
		"path": "/Main/_McpTestV3",
		"property": "position",
		"value": {"x": 1.0, "y": 2.0, "z": 3.0},
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestV3") as Node3D
	assert_eq(node.position, Vector3(1, 2, 3))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_vector3_rejects_color_shaped_dict() -> void:
	## Issue #123 regression: passing a Color-shaped dict {r,g,b,a} to a
	## Vector3 slot used to silently zero-fill x/y/z and store (0,0,0)
	## with status=ok. Must now return INVALID_PARAMS and leave the
	## property unchanged.
	_handler.create_node({"type": "Node3D", "name": "_McpTestBadV3", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestBadV3") as Node3D
	var original := node.position

	var result := _handler.set_property({
		"path": "/Main/_McpTestBadV3",
		"property": "position",
		"value": {"r": 1, "g": 0, "b": 0, "a": 1},
	})
	assert_is_error(result)
	assert_contains(result.error.message, "Vector3")

	assert_eq(node.position, original, "Position must be unchanged after a rejected coerce")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_vector3_rejects_partial_dict() -> void:
	## Second half of #123: a dict with some but not all required keys
	## used to get the missing axes zero-filled (e.g. {x:1} → (1,0,0)).
	## Must now reject.
	_handler.create_node({"type": "Node3D", "name": "_McpTestPartial", "parent_path": "/Main"})
	var result := _handler.set_property({
		"path": "/Main/_McpTestPartial",
		"property": "position",
		"value": {"x": 1},  # missing y, z
	})
	assert_is_error(result)
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_color_rejects_vector3_shaped_dict() -> void:
	## Symmetric check for Color coercion. Before the fix, passing
	## {x,y,z} to a Color slot would stuff Color(0,0,0,1) silently.
	## Exercises _coerce_value directly — the mismatch is detectable at
	## the coercer boundary, no scene node needed.
	var coerced = NodeHandler._coerce_value({"x": 1, "y": 0, "z": 0}, TYPE_COLOR)
	assert_true(coerced is Dictionary, "Wrong-shape dict must flow through unchanged so caller's type check fires")


func test_coerce_value_color_rejects_unparseable_string() -> void:
	## "Color(1,1,1,1)" isn't a named or hex color; Color(String) would silently
	## return black. It must flow through unchanged so the caller's type check
	## fires instead of writing black — while valid named/hex strings still coerce.
	var bad = NodeHandler._coerce_value("Color(1, 1, 1, 1)", TYPE_COLOR)
	assert_true(bad is String, "Unparseable color string must flow through unchanged, not become black")
	var hex = NodeHandler._coerce_value("#ff4400", TYPE_COLOR)
	assert_true(hex is Color, "hex string must still coerce")
	assert_ne(hex, Color(0, 0, 0, 1), "valid hex must parse to its color, not black")
	assert_true(NodeHandler._coerce_value("red", TYPE_COLOR) is Color, "named color must still coerce")


# ----- #191 — non-dict inputs to compound targets must error loudly -----

func test_set_property_vector3_accepts_exact_array_input() -> void:
	## #714 canonical shapes: [x,y,z] is now a valid Vector3 spelling (the
	## superset decision) — the #191 silent-zero hazard is covered by the
	## STRICT variant below (wrong length still rejects, never zero-fills).
	_handler.create_node({"type": "Node3D", "name": "_McpTestArrV3", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestArrV3") as Node3D

	var result := _handler.set_property({
		"path": "/Main/_McpTestArrV3",
		"property": "position",
		"value": [5, 6, 7],
	})
	assert_has_key(result, "data")
	assert_eq(node.position, Vector3(5, 6, 7), "array shape must store the supplied components")
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_vector3_rejects_wrong_length_array() -> void:
	## The #191 guard, restated for the array shape: a wrong-length array
	## must reject loudly and leave the property untouched — never
	## zero-fill.
	_handler.create_node({"type": "Node3D", "name": "_McpTestArrV3b", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestArrV3b") as Node3D
	var original := node.position

	var result := _handler.set_property({
		"path": "/Main/_McpTestArrV3b",
		"property": "position",
		"value": [5, 5],
	})
	assert_is_error(result)
	assert_contains(result.error.message, "Vector3")
	assert_eq(node.position, original, "Position must be unchanged after rejected array coerce")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_vector3_rejects_json_string_input() -> void:
	## Issue #191: a JSON string like "{\"x\":1,...}" used to fall through
	## to add_do_property and store Vector3.ZERO.
	_handler.create_node({"type": "Node3D", "name": "_McpTestStrV3", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestStrV3") as Node3D
	var original := node.position

	var result := _handler.set_property({
		"path": "/Main/_McpTestStrV3",
		"property": "position",
		"value": "{\"x\":1,\"y\":2,\"z\":3}",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "Vector3")
	assert_eq(node.position, original, "Position must be unchanged after rejected string coerce")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_vector2_accepts_exact_array_input() -> void:
	## #714 canonical shapes: [x,y] is a valid Vector2 spelling now.
	_handler.create_node({"type": "Sprite2D", "name": "_McpTestArrV2", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestArrV2") as Sprite2D

	var result := _handler.set_property({
		"path": "/Main/_McpTestArrV2",
		"property": "position",
		"value": [1, 2],
	})
	assert_has_key(result, "data")
	assert_eq(node.position, Vector2(1, 2))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_color_accepts_exact_array_input() -> void:
	## #714 canonical shapes: [r,g,b(,a)] is a valid Color spelling now;
	## a wrong-length array still rejects (see the strict vector variant).
	_handler.create_node({"type": "Sprite2D", "name": "_McpTestArrColor", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestArrColor") as Sprite2D

	var result := _handler.set_property({
		"path": "/Main/_McpTestArrColor",
		"property": "modulate",
		"value": [1, 0, 0, 1],
	})
	assert_has_key(result, "data")
	assert_eq(node.modulate, Color(1, 0, 0, 1))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


# ----- #429 — Packed*Array dict-coercion (silent zero-fill bug) -----

func test_set_property_polygon2d_polygon_round_trip() -> void:
	## Bug repro: setting a PackedVector2Array property (Polygon2D.polygon)
	## with [{x,y}, ...] used to fall through _coerce_value unchanged.
	## Godot's implicit Array → PackedVector2Array then per-element failed
	## Dictionary → Vector2 and silently produced 6 × Vector2.ZERO. Must
	## now coerce each dict and store the supplied vertices.
	_handler.create_node({"type": "Polygon2D", "name": "_McpTestPoly", "parent_path": "/Main"})
	var result := _handler.set_property({
		"path": "/Main/_McpTestPoly",
		"property": "polygon",
		"value": [
			{"x": -104, "y": -40},
			{"x":  -32, "y": -16},
			{"x":    0, "y": -72},
			{"x":   32, "y": -16},
			{"x":  112, "y": -40},
			{"x":    0, "y":  64},
		],
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)

	## Assert on the stored Variant — count-only checks would silently pass
	## against the zero-fill failure mode.
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestPoly") as Polygon2D
	assert_eq(node.polygon.size(), 6)
	assert_true(node.polygon is PackedVector2Array, "stored value must be PackedVector2Array")
	assert_eq(node.polygon[0], Vector2(-104, -40))
	assert_eq(node.polygon[2], Vector2(0, -72))
	assert_eq(node.polygon[5], Vector2(0, 64))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_polygon2d_uv_round_trip() -> void:
	## Same coercion path, different PackedVector2Array slot.
	_handler.create_node({"type": "Polygon2D", "name": "_McpTestUv", "parent_path": "/Main"})
	var result := _handler.set_property({
		"path": "/Main/_McpTestUv",
		"property": "uv",
		"value": [
			{"x": 0, "y": 0},
			{"x": 1, "y": 0},
			{"x": 1, "y": 1},
			{"x": 0, "y": 1},
		],
	})
	assert_has_key(result, "data")
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestUv") as Polygon2D
	assert_eq(node.uv.size(), 4)
	assert_true(node.uv is PackedVector2Array)
	assert_eq(node.uv[2], Vector2(1, 1))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_packed_color_array_round_trip_dict_shape() -> void:
	## PackedColorArray accepts both [{r,g,b,a}, ...] and ["#rrggbb", ...].
	_handler.create_node({"type": "Polygon2D", "name": "_McpTestVColDict", "parent_path": "/Main"})
	var result := _handler.set_property({
		"path": "/Main/_McpTestVColDict",
		"property": "vertex_colors",
		"value": [
			{"r": 1, "g": 0, "b": 0, "a": 1},
			{"r": 0, "g": 1, "b": 0, "a": 0.5},
			{"r": 0, "g": 0, "b": 1},
		],
	})
	assert_has_key(result, "data")
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestVColDict") as Polygon2D
	assert_eq(node.vertex_colors.size(), 3)
	assert_true(node.vertex_colors is PackedColorArray)
	assert_eq(node.vertex_colors[0], Color(1, 0, 0, 1))
	assert_eq(node.vertex_colors[1], Color(0, 1, 0, 0.5))
	# Alpha defaults to 1 when omitted.
	assert_eq(node.vertex_colors[2], Color(0, 0, 1, 1))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_packed_color_array_round_trip_hex_string() -> void:
	_handler.create_node({"type": "Polygon2D", "name": "_McpTestVColStr", "parent_path": "/Main"})
	var result := _handler.set_property({
		"path": "/Main/_McpTestVColStr",
		"property": "vertex_colors",
		"value": ["#ff0000", "#00ff00", "#0000ff"],
	})
	assert_has_key(result, "data")
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestVColStr") as Polygon2D
	assert_eq(node.vertex_colors.size(), 3)
	assert_true(node.vertex_colors is PackedColorArray)
	assert_eq(node.vertex_colors[0], Color(1, 0, 0, 1))
	assert_eq(node.vertex_colors[2], Color(0, 0, 1, 1))
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_packed_vector2_array_rejects_flat_list() -> void:
	## A flat [x, y, x, y, ...] list is an easy mistake; must error rather
	## than silently zero-fill every element.
	_handler.create_node({"type": "Polygon2D", "name": "_McpTestFlat", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestFlat") as Polygon2D
	var original := node.polygon

	var result := _handler.set_property({
		"path": "/Main/_McpTestFlat",
		"property": "polygon",
		"value": [-104, -40, 0, -72, 32, -16],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "PackedVector2Array")
	## Property must be untouched on rejection.
	assert_eq(node.polygon, original, "polygon must be unchanged after rejected coerce")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_packed_vector2_array_rejects_mixed_shapes() -> void:
	## Mixing dict items with non-dict items must also fail rather than
	## partial-zero-fill the unrecognized elements.
	_handler.create_node({"type": "Polygon2D", "name": "_McpTestMixed", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestMixed") as Polygon2D
	var original := node.polygon

	var result := _handler.set_property({
		"path": "/Main/_McpTestMixed",
		"property": "polygon",
		"value": [{"x": 1, "y": 2}, "garbage", {"x": 3, "y": 4}],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_eq(node.polygon, original, "polygon must be unchanged after rejected coerce")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_coerce_packed_vector2_array_from_dict_list() -> void:
	## Unit-level coverage on the static helper.
	var coerced = NodeHandler._coerce_value(
		[{"x": 1, "y": 2}, {"x": 3, "y": 4}],
		TYPE_PACKED_VECTOR2_ARRAY,
	)
	assert_true(coerced is PackedVector2Array)
	assert_eq(coerced.size(), 2)
	assert_eq(coerced[0], Vector2(1, 2))
	assert_eq(coerced[1], Vector2(3, 4))


func test_coerce_packed_vector2_array_accepts_vector2_items() -> void:
	## Internal callers may already have Vector2 values — passing through
	## should not double-construct.
	var coerced = NodeHandler._coerce_value(
		[Vector2(1, 2), Vector2(3, 4)],
		TYPE_PACKED_VECTOR2_ARRAY,
	)
	assert_true(coerced is PackedVector2Array)
	assert_eq(coerced[1], Vector2(3, 4))


func test_coerce_packed_vector3_array_from_dict_list() -> void:
	var coerced = NodeHandler._coerce_value(
		[{"x": 1, "y": 2, "z": 3}],
		TYPE_PACKED_VECTOR3_ARRAY,
	)
	assert_true(coerced is PackedVector3Array)
	assert_eq(coerced[0], Vector3(1, 2, 3))


func test_coerce_packed_vector4_array_from_dict_list() -> void:
	var coerced = NodeHandler._coerce_value(
		[{"x": 1, "y": 2, "z": 3, "w": 4}],
		TYPE_PACKED_VECTOR4_ARRAY,
	)
	assert_true(coerced is PackedVector4Array)
	assert_eq(coerced[0], Vector4(1, 2, 3, 4))


func test_coerce_packed_color_array_from_string() -> void:
	var coerced = NodeHandler._coerce_value(["#ff0000", "#00ff00"], TYPE_PACKED_COLOR_ARRAY)
	assert_true(coerced is PackedColorArray)
	assert_eq(coerced[0], Color(1, 0, 0, 1))


func test_coerce_packed_int32_array_from_numeric_list() -> void:
	var coerced = NodeHandler._coerce_value([1, 2.0, 3], TYPE_PACKED_INT32_ARRAY)
	assert_true(coerced is PackedInt32Array)
	assert_eq(coerced.size(), 3)
	assert_eq(coerced[1], 2)


func test_coerce_packed_int64_array_from_numeric_list() -> void:
	var coerced = NodeHandler._coerce_value([10, 20], TYPE_PACKED_INT64_ARRAY)
	assert_true(coerced is PackedInt64Array)
	assert_eq(coerced[0], 10)


func test_coerce_packed_float32_array_from_numeric_list() -> void:
	var coerced = NodeHandler._coerce_value([1, 2.5, 3], TYPE_PACKED_FLOAT32_ARRAY)
	assert_true(coerced is PackedFloat32Array)
	assert_eq(coerced.size(), 3)
	assert_true(is_equal_approx(coerced[1], 2.5))


func test_coerce_packed_float64_array_from_numeric_list() -> void:
	var coerced = NodeHandler._coerce_value([1.5, 2.5], TYPE_PACKED_FLOAT64_ARRAY)
	assert_true(coerced is PackedFloat64Array)


func test_coerce_packed_string_array_from_string_list() -> void:
	var coerced = NodeHandler._coerce_value(["a", "bb", "ccc"], TYPE_PACKED_STRING_ARRAY)
	assert_true(coerced is PackedStringArray)
	assert_eq(coerced[1], "bb")


func test_coerce_packed_vector2_array_passes_through_on_bad_item() -> void:
	## Contract: _coerce_value returns input unchanged on shape failure so
	## the typed error comes from _check_coerced. A flat numeric list is a
	## non-coercible Array.
	var coerced = NodeHandler._coerce_value([-1, -2, 0, -3], TYPE_PACKED_VECTOR2_ARRAY)
	assert_true(coerced is Array, "Bad-shape input must pass through unchanged")
	assert_false(coerced is PackedVector2Array)


func test_check_coerced_array_packed_vector2_returns_wrong_type() -> void:
	## When _coerce_value passes through a bad Array, _check_coerced must
	## flag it as WRONG_TYPE rather than letting it reach Godot's setter.
	var coerce_err: Variant = NodeHandler._check_coerced([1, 2, 3], TYPE_PACKED_VECTOR2_ARRAY)
	assert_true(coerce_err is Dictionary)
	assert_eq(coerce_err.error.code, ErrorCodes.WRONG_TYPE)
	assert_contains(coerce_err.error.message, "PackedVector2Array")
	assert_contains(coerce_err.error.message, "Array")


func test_check_coerced_array_packed_vector4_returns_wrong_type() -> void:
	## A bad Array passed through _coerce_value must get the shape-hint
	## WRONG_TYPE, same as the other packed types — not the generic
	## "no coercion for that type" default.
	var coerce_err: Variant = NodeHandler._check_coerced([1, 2, 3], TYPE_PACKED_VECTOR4_ARRAY)
	assert_true(coerce_err is Dictionary)
	assert_eq(coerce_err.error.code, ErrorCodes.WRONG_TYPE)
	assert_contains(coerce_err.error.message, "PackedVector4Array")
	assert_contains(coerce_err.error.message, "expected")


func test_check_coerced_passes_correct_packed_arrays() -> void:
	## Right-typed packed arrays must pass through (return null).
	assert_eq(NodeHandler._check_coerced(PackedVector2Array(), TYPE_PACKED_VECTOR2_ARRAY), null)
	assert_eq(NodeHandler._check_coerced(PackedVector3Array(), TYPE_PACKED_VECTOR3_ARRAY), null)
	assert_eq(NodeHandler._check_coerced(PackedVector4Array(), TYPE_PACKED_VECTOR4_ARRAY), null)
	assert_eq(NodeHandler._check_coerced(PackedColorArray(), TYPE_PACKED_COLOR_ARRAY), null)
	assert_eq(NodeHandler._check_coerced(PackedInt32Array(), TYPE_PACKED_INT32_ARRAY), null)
	assert_eq(NodeHandler._check_coerced(PackedFloat32Array(), TYPE_PACKED_FLOAT32_ARRAY), null)
	assert_eq(NodeHandler._check_coerced(PackedStringArray(), TYPE_PACKED_STRING_ARRAY), null)


func test_shape_hint_packed_arrays() -> void:
	## The hint string is what agents read after a WRONG_TYPE — make sure
	## each new packed type returns a list-shaped hint, not a dict.
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_VECTOR2_ARRAY), "[{\"x\":0,\"y\":0}, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_VECTOR3_ARRAY), "[{\"x\":0,\"y\":0,\"z\":0}, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_VECTOR4_ARRAY), "[{\"x\":0,\"y\":0,\"z\":0,\"w\":0}, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_COLOR_ARRAY), "[{\"r\":0,\"g\":0,\"b\":0,\"a\":1}, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_INT32_ARRAY), "[int, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_INT64_ARRAY), "[int, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_FLOAT32_ARRAY), "[float, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_FLOAT64_ARRAY), "[float, ...]")
	assert_eq(NodeHandler._shape_hint(TYPE_PACKED_STRING_ARRAY), "[\"...\", ...]")


func test_check_coerced_array_vector3_returns_wrong_type() -> void:
	## Direct unit check on the helper — no scene needed. Pins the
	## error shape so the message format change in #191 stays bisect-friendly.
	## Code is WRONG_TYPE post-audit-v2 #21 (#365): a value that fails to
	## coerce to a typed Variant slot is a type mismatch.
	var coerce_err: Variant = NodeHandler._check_coerced([1, 2, 3], TYPE_VECTOR3)
	assert_true(coerce_err is Dictionary, "Non-coerced Array input must produce an error dict")
	assert_eq(coerce_err.error.code, ErrorCodes.WRONG_TYPE)
	assert_contains(coerce_err.error.message, "Vector3")
	assert_contains(coerce_err.error.message, "Array")  # names the received type
	## PR #424 follow-up: the message used to read "expected a dict like %s",
	## which was self-contradictory once `_shape_hint` learned to return
	## list-shaped hints for Packed*Array targets. Pin the new wording so a
	## future revert can't reintroduce the inconsistency unnoticed.
	assert_false(
		String(coerce_err.error.message).contains("a dict like"),
		"Message must drop the 'a dict like' phrasing — _shape_hint already encodes shape",
	)


func test_check_coerced_noop_for_non_compound_target() -> void:
	## TYPE_INT / TYPE_FLOAT / TYPE_BOOL are not handled by _coerce_value
	## as compound targets; the strict check must return null so Godot's
	## setter handles them. Otherwise every non-Vector property mutation
	## would false-fail.
	assert_eq(NodeHandler._check_coerced(42, TYPE_INT), null)
	assert_eq(NodeHandler._check_coerced(true, TYPE_BOOL), null)
	assert_eq(NodeHandler._check_coerced("hello", TYPE_STRING), null)
	assert_eq(NodeHandler._check_coerced(null, TYPE_OBJECT), null)


func test_check_coerced_passes_correct_compound_value() -> void:
	## Right-typed compound values must pass through (return null) so the
	## strict check doesn't false-fail the happy path.
	assert_eq(NodeHandler._check_coerced(Vector3(1, 2, 3), TYPE_VECTOR3), null)
	assert_eq(NodeHandler._check_coerced(Vector2(1, 2), TYPE_VECTOR2), null)
	assert_eq(NodeHandler._check_coerced(Color(1, 0, 0), TYPE_COLOR), null)


func test_coerce_value_passes_right_shape_color() -> void:
	var coerced = NodeHandler._coerce_value({"r": 1.0, "g": 0.5, "b": 0.0, "a": 1.0}, TYPE_COLOR)
	assert_true(coerced is Color)
	assert_eq(coerced.r, 1.0)
	assert_eq(coerced.g, 0.5)


func test_coerce_value_accepts_color_without_alpha() -> void:
	## Alpha is optional and defaults to 1.0 — {r,g,b} without 'a' is a
	## valid shape. The strict check should only require r/g/b.
	var coerced = NodeHandler._coerce_value({"r": 1.0, "g": 0.0, "b": 0.0}, TYPE_COLOR)
	assert_true(coerced is Color)
	assert_eq(coerced.a, 1.0)


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
	assert_true(editor_undo(_undo_redo), "undo assign should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_resource_not_found() -> void:
	var result := _handler.set_property({
		"path": "/Main/Camera3D",
		"property": "environment",
		"value": "res://does/not/exist.tres",
	})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(editor_undo(_undo_redo), "undo should succeed")


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_set_property_nonexistent_property() -> void:
	var result := _handler.set_property({
		"path": "/Main/Camera3D",
		"property": "nonexistent_xyz",
		"value": 42,
	})
	assert_is_error(result)


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
	assert_true(editor_undo(_undo_redo), "mesh undo should succeed")
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
	assert_is_error(result)
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
	assert_is_error(result)
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


func test_shared_key_constants_match_coercer_requirements() -> void:
	## The shared key-list constants (#131) must stay aligned with what
	## _coerce_value / _check_dict_coerce_failed actually require. If
	## someone adds a new axis (e.g. Vector4) they should bump both.
	assert_eq(NodeHandler.VECTOR2_KEYS, ["x", "y"])
	assert_eq(NodeHandler.VECTOR3_KEYS, ["x", "y", "z"])
	assert_eq(NodeHandler.COLOR_KEYS, ["r", "g", "b"])
	# Dropping any required key must flip coercion off.
	var missing_y = NodeHandler._coerce_value({"x": 1}, TYPE_VECTOR2)
	assert_true(missing_y is Dictionary)
	var missing_z = NodeHandler._coerce_value({"x": 1, "y": 2}, TYPE_VECTOR3)
	assert_true(missing_z is Dictionary)
	var missing_b = NodeHandler._coerce_value({"r": 1, "g": 0}, TYPE_COLOR)
	assert_true(missing_b is Dictionary)


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


# Issue #214: AABB / Rect2 / Transform / Packed* used to come back as Godot's
# debug-print strings (e.g. "[P: (0,0,0), S: (0,0,0)]" or "[]"), so agents
# couldn't programmatically inspect or round-trip them. Each test below
# asserts a specific structured shape — count-only / `is Dictionary` checks
# would silently pass against the old broken behavior on most of these.

func test_serialize_aabb_returns_position_and_size() -> void:
	var result = NodeHandler._serialize_value(AABB(Vector3(1, 2, 3), Vector3(4, 5, 6)))
	assert_true(result is Dictionary)
	assert_has_key(result, "position")
	assert_has_key(result, "size")
	assert_eq(result["position"]["x"], 1.0)
	assert_eq(result["position"]["y"], 2.0)
	assert_eq(result["position"]["z"], 3.0)
	assert_eq(result["size"]["x"], 4.0)
	assert_eq(result["size"]["y"], 5.0)
	assert_eq(result["size"]["z"], 6.0)


func test_serialize_rect2_returns_position_and_size() -> void:
	var result = NodeHandler._serialize_value(Rect2(1, 2, 3, 4))
	assert_true(result is Dictionary)
	assert_eq(result["position"]["x"], 1.0)
	assert_eq(result["position"]["y"], 2.0)
	assert_eq(result["size"]["x"], 3.0)
	assert_eq(result["size"]["y"], 4.0)


func test_serialize_rect2i_returns_position_and_size() -> void:
	var result = NodeHandler._serialize_value(Rect2i(1, 2, 3, 4))
	assert_true(result is Dictionary)
	assert_eq(result["position"]["x"], 1)
	assert_eq(result["size"]["y"], 4)


func test_serialize_vector2i_returns_xy_dict() -> void:
	var result = NodeHandler._serialize_value(Vector2i(7, 8))
	assert_true(result is Dictionary)
	assert_eq(result["x"], 7)
	assert_eq(result["y"], 8)


func test_serialize_vector3i_returns_xyz_dict() -> void:
	var result = NodeHandler._serialize_value(Vector3i(7, 8, 9))
	assert_true(result is Dictionary)
	assert_eq(result["x"], 7)
	assert_eq(result["y"], 8)
	assert_eq(result["z"], 9)


func test_serialize_vector4_returns_xyzw_dict() -> void:
	var result = NodeHandler._serialize_value(Vector4(1, 2, 3, 4))
	assert_true(result is Dictionary)
	assert_eq(result["x"], 1.0)
	assert_eq(result["y"], 2.0)
	assert_eq(result["z"], 3.0)
	assert_eq(result["w"], 4.0)


func test_serialize_quaternion_returns_xyzw_dict() -> void:
	var result = NodeHandler._serialize_value(Quaternion(0.1, 0.2, 0.3, 1.0))
	assert_true(result is Dictionary)
	assert_eq(result["w"], 1.0)


func test_serialize_plane_returns_normal_and_d() -> void:
	var result = NodeHandler._serialize_value(Plane(Vector3(0, 1, 0), 5))
	assert_true(result is Dictionary)
	assert_has_key(result, "normal")
	assert_eq(result["normal"]["y"], 1.0)
	assert_eq(result["d"], 5.0)


func test_serialize_basis_returns_three_column_vectors() -> void:
	var result = NodeHandler._serialize_value(Basis.IDENTITY)
	assert_true(result is Dictionary)
	# Identity basis: x=(1,0,0), y=(0,1,0), z=(0,0,1).
	assert_eq(result["x"]["x"], 1.0)
	assert_eq(result["y"]["y"], 1.0)
	assert_eq(result["z"]["z"], 1.0)


func test_serialize_transform2d_returns_basis_cols_and_origin() -> void:
	var result = NodeHandler._serialize_value(Transform2D(0.0, Vector2(7, 8)))
	assert_true(result is Dictionary)
	assert_has_key(result, "x")
	assert_has_key(result, "y")
	assert_has_key(result, "origin")
	assert_eq(result["origin"]["x"], 7.0)
	assert_eq(result["origin"]["y"], 8.0)


func test_serialize_transform3d_returns_basis_and_origin() -> void:
	var result = NodeHandler._serialize_value(Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)))
	assert_true(result is Dictionary)
	assert_has_key(result, "basis")
	assert_has_key(result, "origin")
	# Basis serializes recursively, so origin should be a {x,y,z} dict.
	assert_eq(result["origin"]["x"], 1.0)
	assert_eq(result["basis"]["x"]["x"], 1.0)


func test_serialize_projection_returns_four_column_vectors() -> void:
	var result = NodeHandler._serialize_value(Projection.IDENTITY)
	assert_true(result is Dictionary)
	for axis in ["x", "y", "z", "w"]:
		assert_has_key(result, axis)
		assert_has_key(result[axis], "w")  # column vectors are Vector4


func test_serialize_packed_float32_array_returns_array_of_floats() -> void:
	var packed := PackedFloat32Array([1.5, 2.5, 3.5])
	var result = NodeHandler._serialize_value(packed)
	assert_true(result is Array)
	assert_eq(result.size(), 3)
	assert_eq(result[0], 1.5)
	assert_true(result[2] is float)


func test_serialize_packed_float32_empty_returns_empty_array() -> void:
	# Issue #214 repro: Label.tab_stops used to come back as the string "[]".
	var result = NodeHandler._serialize_value(PackedFloat32Array())
	assert_true(result is Array)
	assert_eq(result.size(), 0)


func test_serialize_packed_int32_array_returns_array_of_ints() -> void:
	var result = NodeHandler._serialize_value(PackedInt32Array([10, 20, 30]))
	assert_true(result is Array)
	assert_eq(result[1], 20)


func test_serialize_packed_byte_array_returns_array_of_ints() -> void:
	var result = NodeHandler._serialize_value(PackedByteArray([0, 128, 255]))
	assert_true(result is Array)
	assert_eq(result[2], 255)


func test_serialize_packed_string_array_returns_array_of_strings() -> void:
	var result = NodeHandler._serialize_value(PackedStringArray(["a", "bb", "ccc"]))
	assert_true(result is Array)
	assert_eq(result[1], "bb")
	assert_true(result[0] is String)


func test_serialize_packed_vector2_array_returns_xy_dicts() -> void:
	var packed := PackedVector2Array([Vector2(1, 2), Vector2(3, 4)])
	var result = NodeHandler._serialize_value(packed)
	assert_true(result is Array)
	assert_eq(result.size(), 2)
	assert_eq(result[0]["x"], 1.0)
	assert_eq(result[1]["y"], 4.0)


func test_serialize_packed_vector3_array_returns_xyz_dicts() -> void:
	var result = NodeHandler._serialize_value(PackedVector3Array([Vector3(1, 2, 3)]))
	assert_true(result is Array)
	assert_eq(result[0]["z"], 3.0)


func test_serialize_packed_vector4_array_returns_xyzw_dicts() -> void:
	var result = NodeHandler._serialize_value(PackedVector4Array([Vector4(1, 2, 3, 4)]))
	assert_true(result is Array)
	assert_eq(result[0]["x"], 1.0)
	assert_eq(result[0]["w"], 4.0)


func test_serialize_packed_color_array_returns_rgba_dicts() -> void:
	var result = NodeHandler._serialize_value(PackedColorArray([Color(1, 0, 0, 0.5)]))
	assert_true(result is Array)
	assert_eq(result[0]["r"], 1.0)
	assert_eq(result[0]["a"], 0.5)


func test_get_node_properties_aabb_value_is_structured() -> void:
	# End-to-end: a MeshInstance3D has `custom_aabb: AABB`. The repro in
	# issue #214 was getting `"[P: (0.0, 0.0, 0.0), S: (0.0, 0.0, 0.0)]"`
	# back as a string from this exact path.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var mi := MeshInstance3D.new()
	mi.name = "_McpAabbProbe%s" % str(Time.get_ticks_usec())
	mi.custom_aabb = AABB(Vector3(1, 2, 3), Vector3(4, 5, 6))
	scene_root.add_child(mi)
	mi.owner = scene_root
	var node_path := "/%s/%s" % [scene_root.name, mi.name]
	var result := _handler.get_node_properties({"path": node_path})
	mi.queue_free()
	assert_has_key(result, "data")
	var found_aabb := false
	for prop in result.data.properties:
		if prop.name == "custom_aabb":
			found_aabb = true
			assert_eq(prop.type, "AABB")
			assert_true(prop.value is Dictionary, "custom_aabb value must be structured, got: %s" % str(prop.value))
			assert_has_key(prop.value, "position")
			assert_has_key(prop.value, "size")
			assert_eq(prop.value.position.x, 1.0)
			assert_eq(prop.value.size.z, 6.0)
			break
	assert_true(found_aabb, "custom_aabb property not found on MeshInstance3D")


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_rename_node_scene_root_rejected() -> void:
	## Issue #122 regression test. The tool docstring has always said
	## "Cannot rename the scene root," but the handler silently allowed it
	## until 1.2.3. The prior version of this test asserted the buggy
	## behaviour (rename succeeds) — flipped to match the docstring.
	##
	## Renaming the scene root must be rejected because its name is baked
	## into the .tscn serialization and into every NodePath that references
	## `/<root>` (AnimationPlayer tracks, RemoteTransform3D targets,
	## exported NodePath @vars, etc.). Silently renaming it breaks those
	## references with no warning.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var old_name := String(scene_root.name)

	var result := _handler.rename_node({"path": "/" + old_name, "new_name": "RenamedTestRoot"})
	assert_is_error(result)
	assert_contains(result.error.message, "scene root")

	## Scene root must be unchanged.
	assert_eq(String(scene_root.name), old_name, "scene root name must not have changed")


func test_rename_node_missing_name() -> void:
	var result := _handler.rename_node({"path": "/Main/Camera3D"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_rename_node_invalid_characters() -> void:
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "foo/bar",
	})
	assert_is_error(result)


func test_rename_node_sibling_collision() -> void:
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "World",
	})
	assert_is_error(result)


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
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_duplicate_scene_root() -> void:
	var result := _handler.duplicate_node({"path": "/Main"})
	assert_is_error(result)


func test_duplicate_node_invalid_path() -> void:
	var result := _handler.duplicate_node({"path": "/Main/NoSuchNode"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_duplicate_restores_descendant_owner_on_redo() -> void:
	## Issue #904: descendant ownership was applied after commit_action, so
	## redo of duplicate restored the copy without setting child owners.
	var chain := _build_temp_chain(
		["_McpTestDupSrc", "_McpTestDupChild"] as Array[String]
	)
	var scene_root := EditorInterface.get_edited_scene_root()

	var result := _handler.duplicate_node({
		"path": "/Main/_McpTestDupSrc",
		"name": "_McpTestDupCopy",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable, "duplicate should be undoable")
	assert_true(str(result.data.name).begins_with("_McpTestDupCopy"))

	var copy_child := scene_root.get_node_or_null("_McpTestDupCopy/_McpTestDupChild")
	assert_ne(copy_child, null, "duplicate child must exist")
	assert_eq(copy_child.owner, scene_root, "duplicate child owner should be scene root")

	assert_true(editor_undo(_undo_redo), "undo duplicate should succeed")
	assert_eq(scene_root.get_node_or_null("_McpTestDupCopy"), null, "copy should be gone after undo")

	assert_true(editor_redo(_undo_redo), "redo duplicate should succeed")
	var copy_child_redo := scene_root.get_node_or_null("_McpTestDupCopy/_McpTestDupChild")
	assert_ne(copy_child_redo, null, "duplicate child must exist after redo")
	assert_ne(copy_child_redo.owner, null, "copy child's owner must not be null after redo")
	assert_eq(copy_child_redo.owner, scene_root, "copy child's owner must be the scene root after redo")

	assert_true(editor_undo(_undo_redo), "undo duplicate after redo should succeed")
	chain.teardown.call()


# ----- move_node -----

func test_move_node_scene_root() -> void:
	var result := _handler.move_node({"path": "/Main", "index": 0})
	assert_is_error(result)


func test_move_node_missing_index() -> void:
	var result := _handler.move_node({"path": "/Main/Camera3D"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_move_node_out_of_range() -> void:
	var result := _handler.move_node({"path": "/Main/Camera3D", "index": 999})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


# ----- add_to_group / remove_from_group -----

func test_add_to_group() -> void:
	## Ensure clean state: remove from group if left over from a previous run
	var scene_root := EditorInterface.get_edited_scene_root()
	var cam := McpScenePath.resolve("/Main/Camera3D", scene_root)
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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_add_to_group_missing_group() -> void:
	var result := _handler.add_to_group({"path": "/Main/Camera3D"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_remove_from_group_not_member() -> void:
	var result := _handler.remove_from_group({
		"path": "/Main/Camera3D",
		"group": "_mcp_nonexistent_group",
	})
	assert_has_key(result, "data")
	assert_true(result.data.not_member, "Should indicate not a member")


func test_remove_from_group_missing_group() -> void:
	var result := _handler.remove_from_group({"path": "/Main/Camera3D"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_add_to_group_rejects_array_value() -> void:
	## Repro for #210: the meta-tool layer JSON-decodes string-shaped values
	## like `"[\"a\",\"b\"]"` into an Array before the handler sees them.
	## Without input validation the typed assignment `var group: String =
	## ...` would runtime-error and the dispatcher would only surface an
	## opaque INTERNAL_ERROR. With validation, the agent gets an actionable
	## INVALID_PARAMS instead.
	var result := _handler.add_to_group({
		"path": "/Main/Camera3D",
		"group": ["a", "b"],
	})
	assert_is_error(result)
	assert_contains(result.error.message, "group")
	assert_contains(result.error.message, "Array")


func test_remove_from_group_rejects_array_value() -> void:
	var result := _handler.remove_from_group({
		"path": "/Main/Camera3D",
		"group": ["a", "b"],
	})
	assert_is_error(result)
	assert_contains(result.error.message, "group")
	assert_contains(result.error.message, "Array")


func test_add_to_group_accepts_string_name_value() -> void:
	## JSON only carries TYPE_STRING, but internal callers may pass a
	## StringName. The validator accepts both; the handler converts via
	## String() before the typed local so the assignment can't trip a
	## StringName→String type-mismatch at runtime.
	var scene_root := EditorInterface.get_edited_scene_root()
	var cam := McpScenePath.resolve("/Main/Camera3D", scene_root)
	if cam and cam.is_in_group("_mcp_test_sn_group"):
		cam.remove_from_group("_mcp_test_sn_group")

	var result := _handler.add_to_group({
		"path": "/Main/Camera3D",
		"group": &"_mcp_test_sn_group",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.group, "_mcp_test_sn_group")
	assert_true(result.data.undoable)
	assert_true(editor_undo(_undo_redo), "undo should succeed")


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
		skip("No scene root — is a scene open?")
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
		skip("No scene root — is a scene open?")
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

	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_eq(scene_root.get_child_count(), before, "Undo removes the instance")
	assert_true(scene_root.find_child("UndoInstance", false, false) == null, "No node after undo")

	assert_true(editor_redo(_undo_redo), "redo should succeed")
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
	assert_is_error(result)
	assert_contains(result.error.message, "not found")


func test_create_node_scene_path_not_res() -> void:
	var result := _handler.create_node({
		"scene_path": "/tmp/scene.tscn",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "res://")


func test_create_node_requires_type_or_scene_path() -> void:
	var result := _handler.create_node({"parent_path": ""})
	assert_is_error(result)
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
	assert_is_error(result, ErrorCodes.EDITED_SCENE_MISMATCH)


func test_resolve_node_scene_file_mismatch_blocks_mutation() -> void:
	## rename_node routes through _resolve_node. If the guard fires early, the
	## rename never reaches the node and no sibling-name validation happens.
	var result := _handler.rename_node({
		"path": "/Main/Camera3D",
		"new_name": "ShouldNotRename",
		"scene_file": "res://does/not/match.tscn",
	})
	assert_is_error(result, ErrorCodes.EDITED_SCENE_MISMATCH)
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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


# ----- honest failure for un-coercible writes -----

func test_check_coerced_rejects_unsupported_struct() -> void:
	# PackedByteArray is intentionally never coerced (base64-vs-int design gap),
	# so it is a durable stand-in for "a type with no coercion branch".
	var result: Variant = NodeHandler._check_coerced([1, 2, 3], TYPE_PACKED_BYTE_ARRAY)
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


func test_check_coerced_allows_null_clear() -> void:
	# Clearing an Object/NodePath property to null must still pass (no regression).
	assert_eq(NodeHandler._check_coerced(null, TYPE_OBJECT), null)


func test_check_coerced_allows_untyped_property() -> void:
	# Dynamic @export vars report a TYPE_NIL target; must stay permissive.
	assert_eq(NodeHandler._check_coerced(42, TYPE_NIL), null)


func test_check_coerced_allows_matching_scalar() -> void:
	assert_eq(NodeHandler._check_coerced(50.0, TYPE_FLOAT), null)


# ----- struct coercion (pure, no scene node) -----

func test_coerce_vector2i() -> void:
	# assert the TYPE strictly: a raw dict compares == to a struct under GDScript's
	# permissive cross-type !=, so assert_eq alone would false-pass an un-coerced dict.
	var result: Variant = NodeHandler._coerce_value({"x": 3, "y": 4}, TYPE_VECTOR2I)
	assert_true(result is Vector2i, "should coerce to Vector2i")
	assert_eq(result, Vector2i(3, 4))


func test_coerce_vector4() -> void:
	var result: Variant = NodeHandler._coerce_value({"x": 1, "y": 2, "z": 3, "w": 4}, TYPE_VECTOR4)
	assert_true(result is Vector4, "should coerce to Vector4")
	assert_eq(result, Vector4(1, 2, 3, 4))


func test_coerce_rect2() -> void:
	var shape := {"position": {"x": 0, "y": 0}, "size": {"x": 6, "y": 6}}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_RECT2)
	assert_true(result is Rect2, "should coerce to Rect2")
	assert_eq(result, Rect2(0, 0, 6, 6))


func test_coerce_transform2d() -> void:
	var shape := {"x": {"x": 1, "y": 0}, "y": {"x": 0, "y": 1}, "origin": {"x": 5, "y": 7}}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_TRANSFORM2D)
	assert_true(result is Transform2D, "should coerce to Transform2D")
	assert_eq(result, Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(5, 7)))


func test_coerce_transform3d_nested() -> void:
	# Compound-of-compound: Transform3D -> Basis -> Vector3, all via recursion.
	var basis_shape := {
		"x": {"x": 1, "y": 0, "z": 0},
		"y": {"x": 0, "y": 1, "z": 0},
		"z": {"x": 0, "y": 0, "z": 1},
	}
	var shape := {"basis": basis_shape, "origin": {"x": 2, "y": 3, "z": 4}}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_TRANSFORM3D)
	assert_true(result is Transform3D, "should coerce to Transform3D")
	assert_eq((result as Transform3D).origin, Vector3(2, 3, 4))


func test_coerce_vector3i() -> void:
	var result: Variant = NodeHandler._coerce_value({"x": 5, "y": 6, "z": 7}, TYPE_VECTOR3I)
	assert_true(result is Vector3i, "should coerce to Vector3i")
	assert_eq(result, Vector3i(5, 6, 7))


func test_coerce_vector4i() -> void:
	var result: Variant = NodeHandler._coerce_value({"x": 1, "y": 2, "z": 3, "w": 4}, TYPE_VECTOR4I)
	assert_true(result is Vector4i, "should coerce to Vector4i")
	assert_eq(result, Vector4i(1, 2, 3, 4))


func test_coerce_quaternion() -> void:
	var result: Variant = NodeHandler._coerce_value({"x": 0, "y": 0, "z": 0, "w": 1}, TYPE_QUATERNION)
	assert_true(result is Quaternion, "should coerce to Quaternion")
	assert_eq(result, Quaternion(0, 0, 0, 1))


func test_coerce_rect2i() -> void:
	var shape := {"position": {"x": 0, "y": 0}, "size": {"x": 6, "y": 6}}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_RECT2I)
	assert_true(result is Rect2i, "should coerce to Rect2i")
	assert_eq(result, Rect2i(0, 0, 6, 6))


func test_coerce_aabb() -> void:
	var shape := {"position": {"x": 0, "y": 0, "z": 0}, "size": {"x": 1, "y": 2, "z": 3}}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_AABB)
	assert_true(result is AABB, "should coerce to AABB")
	assert_eq(result, AABB(Vector3(0, 0, 0), Vector3(1, 2, 3)))


func test_coerce_plane() -> void:
	var shape := {"normal": {"x": 0, "y": 1, "z": 0}, "d": 5}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_PLANE)
	assert_true(result is Plane, "should coerce to Plane")
	assert_eq(result, Plane(Vector3(0, 1, 0), 5))


func test_coerce_basis() -> void:
	var shape := {
		"x": {"x": 1, "y": 0, "z": 0},
		"y": {"x": 0, "y": 1, "z": 0},
		"z": {"x": 0, "y": 0, "z": 1},
	}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_BASIS)
	assert_true(result is Basis, "should coerce to Basis")
	assert_eq(result, Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)))


func test_coerce_projection_nested() -> void:
	# Compound-of-compound: Projection -> Vector4 columns, all via recursion.
	var shape := {
		"x": {"x": 1, "y": 0, "z": 0, "w": 0},
		"y": {"x": 0, "y": 1, "z": 0, "w": 0},
		"z": {"x": 0, "y": 0, "z": 1, "w": 0},
		"w": {"x": 0, "y": 0, "z": 0, "w": 1},
	}
	var result: Variant = NodeHandler._coerce_value(shape, TYPE_PROJECTION)
	assert_true(result is Projection, "should coerce to Projection")
	assert_eq((result as Projection).w, Vector4(0, 0, 0, 1))


func test_coerce_rect2_wrong_shape_flows_through() -> void:
	# Missing "size" -> not coerced -> stays a Dictionary so _check_coerced flags it.
	var bad := {"position": {"x": 0, "y": 0}}
	var coerced: Variant = NodeHandler._coerce_value(bad, TYPE_RECT2)
	assert_true(coerced is Dictionary, "wrong-shape dict must flow through unchanged")
	assert_is_error(NodeHandler._check_coerced(coerced, TYPE_RECT2), ErrorCodes.WRONG_TYPE)


# ----- end-to-end set_property lands on the node -----

func test_set_property_rect2_lands() -> void:
	_handler.create_node({"type": "Sprite2D", "name": "_McpTestRect2", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestRect2") as Sprite2D
	var result := _handler.set_property({
		"path": "/Main/_McpTestRect2",
		"property": "region_rect",
		"value": {"position": {"x": 0, "y": 0}, "size": {"x": 6, "y": 6}},
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	assert_eq(node.region_rect, Rect2(0, 0, 6, 6), "Rect2 must land on the node, not just echo")
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_rect2_can_be_verified_by_readback() -> void:
	_handler.create_node({"type": "Sprite2D", "name": "_McpTestRect2Readback", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestRect2Readback") as Sprite2D
	node.region_enabled = true
	var result := _handler.set_property({
		"path": "/Main/_McpTestRect2Readback",
		"property": "region_rect",
		"value": {"position": {"x": 2, "y": 3}, "size": {"x": 8, "y": 13}},
	})
	assert_has_key(result, "data")
	assert_eq(node.region_rect, Rect2(2, 3, 8, 13), "Rect2 must land before read-back")

	var readback := _handler.get_node_properties({"path": "/Main/_McpTestRect2Readback"})
	assert_has_key(readback, "data")
	var found := false
	for prop in readback.data.properties:
		if prop.name == "region_rect":
			found = true
			assert_eq(prop.type, "Rect2")
			assert_true(prop.value is Dictionary, "region_rect read-back must be structured")
			assert_eq(prop.value.position.x, 2.0)
			assert_eq(prop.value.position.y, 3.0)
			assert_eq(prop.value.size.x, 8.0)
			assert_eq(prop.value.size.y, 13.0)
			break
	assert_true(found, "region_rect property must be present in read-back")
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_transform2d_lands() -> void:
	_handler.create_node({"type": "Node2D", "name": "_McpTestXform2D", "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node("_McpTestXform2D") as Node2D
	var expected := Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(5, 7))
	var result := _handler.set_property({
		"path": "/Main/_McpTestXform2D",
		"property": "transform",
		"value": {"x": {"x": 1, "y": 0}, "y": {"x": 0, "y": 1}, "origin": {"x": 5, "y": 7}},
	})
	assert_has_key(result, "data")
	assert_eq(node.transform, expected, "Transform2D must land on the node")
	assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")



# ----- set_property: typed Array[T] slots (#612 stage 1) -----

## Attach a @tool script with typed-array exports to a fresh probe node
## created through the handler (so undo cleanup mirrors the other
## set_property tests). Returns the live node.
func _make_typed_array_probe(probe_name: String) -> Node:
	_handler.create_node({"type": "Node", "name": probe_name, "parent_path": "/Main"})
	var node := EditorInterface.get_edited_scene_root().get_node(probe_name)
	var script := GDScript.new()
	script.source_code = "\n".join([
		"@tool",
		"extends Node",
		"@export var ints: Array[int] = []",
		"@export var strings: Array[String] = []",
		"@export var vectors: Array[Vector3] = []",
		"@export var colors: Array[Color] = []",
		"@export var nested: Array[Array] = []",
		"@export var textures: Array[Texture2D] = []",
		"@export var meshes: Array[Mesh] = []",
		"@export var scores: Dictionary[String, int] = {}",
		"@export var by_id: Dictionary[int, String] = {}",
		"@export var mesh_map: Dictionary[String, Mesh] = {}",
	])
	script.reload()
	node.set_script(script)
	return node


## Undo the probe's create action (set_property failures commit nothing, so
## error-path tests only need this single undo).
func _free_typed_array_probe(sets_to_undo: int) -> void:
	for i in sets_to_undo:
		assert_true(editor_undo(_undo_redo), "undo set should succeed")
	assert_true(editor_undo(_undo_redo), "undo create should succeed")


func test_set_property_typed_int_array_roundtrip() -> void:
	## The #612 headline case: a JSON list into an Array[int] slot used to be
	## silently dropped (slot stayed []) while the call reported success.
	var node := _make_typed_array_probe("_McpTypedInts")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedInts",
		"property": "ints",
		"value": [1, 2, 3],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("ints")
	assert_true(stored is Array, "ints must read back as an Array")
	assert_eq((stored as Array).size(), 3, "all elements must land — no silent drop")
	assert_eq(stored[0], 1)
	assert_eq(stored[2], 3)
	assert_true((stored as Array).is_typed(), "the slot must keep its typing")
	_free_typed_array_probe(1)


func test_set_property_typed_int_array_coerces_json_floats() -> void:
	## JSON numbers arrive as floats; whole floats must land as ints.
	var node := _make_typed_array_probe("_McpTypedIntFloats")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedIntFloats",
		"property": "ints",
		"value": [1.0, 2.0],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("ints")
	assert_eq((stored as Array).size(), 2)
	assert_true(stored[0] is int, "JSON float must coerce to the int element type")
	assert_eq(stored[1], 2)
	_free_typed_array_probe(1)


func test_set_property_typed_vector3_array_coerces_dicts() -> void:
	## Struct elements go through the same dict->Variant coercion as scalar
	## slots; assert on the stored Variant, not the count (AGENTS.md).
	var node := _make_typed_array_probe("_McpTypedVecs")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedVecs",
		"property": "vectors",
		"value": [{"x": 1, "y": 2, "z": 3}, {"x": 4, "y": 5, "z": 6}],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("vectors")
	assert_eq((stored as Array).size(), 2)
	assert_true(stored[0] is Vector3, "dict element must land as Vector3, not Dictionary")
	assert_eq(stored[1], Vector3(4, 5, 6))
	_free_typed_array_probe(1)


func test_set_property_typed_color_array_accepts_dicts_and_names() -> void:
	var node := _make_typed_array_probe("_McpTypedColors")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedColors",
		"property": "colors",
		"value": [{"r": 1, "g": 0, "b": 0}, "#00ff00"],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("colors")
	assert_eq((stored as Array).size(), 2)
	assert_true(stored[0] is Color, "dict element must land as Color")
	assert_eq(stored[1], Color("#00ff00"))
	_free_typed_array_probe(1)


func test_set_property_typed_color_array_rejects_bogus_color_string() -> void:
	## Color("zznothex") silently returns black on the scalar path history
	## (#612 rider) — the typed-array path must clean-error instead.
	var node := _make_typed_array_probe("_McpTypedBadColor")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedBadColor",
		"property": "colors",
		"value": ["#ff0000", "zznothex"],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "element 1",
		"the error must name the offending element index")
	assert_eq((node.get("colors") as Array).size(), 0, "nothing may be written on error")
	_free_typed_array_probe(0)


func test_set_property_typed_nested_array_roundtrip() -> void:
	var node := _make_typed_array_probe("_McpTypedNested")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedNested",
		"property": "nested",
		"value": [[1, 2], [3]],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("nested")
	assert_eq((stored as Array).size(), 2)
	assert_true(stored[0] is Array)
	assert_eq(stored[0][1], 2)
	_free_typed_array_probe(1)


func test_set_property_typed_array_mixed_elements_error_names_index() -> void:
	## Wrong/mixed elements clean-error naming the index — never a partial
	## or silent write (#612 maintainer decision).
	var node := _make_typed_array_probe("_McpTypedMixed")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedMixed",
		"property": "ints",
		"value": [1, "two", 3],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "element 1",
		"the error must name the offending element index")
	assert_eq((node.get("ints") as Array).size(), 0, "slot must stay untouched on error")
	_free_typed_array_probe(0)


func test_set_property_typed_array_non_list_value_errors() -> void:
	var node := _make_typed_array_probe("_McpTypedNonList")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedNonList",
		"property": "ints",
		"value": 5,
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "Array[int]",
		"the error must name the typed slot")
	assert_eq((node.get("ints") as Array).size(), 0)
	_free_typed_array_probe(0)


func test_set_property_typed_object_array_clears_with_empty_list() -> void:
	## An empty list carries no elements to coerce, so it must be allowed to
	## CLEAR an Object-element typed array even while writing elements is
	## stage-2 (#682 review finding).
	var node := _make_typed_array_probe("_McpTypedObjClear")
	var live: Array = node.get("textures")
	live.append(ImageTexture.new())
	assert_eq((node.get("textures") as Array).size(), 1, "seed texture must be present")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjClear",
		"property": "textures",
		"value": [],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("textures")
	assert_eq((stored as Array).size(), 0, "empty list must clear the slot")
	assert_true((stored as Array).is_typed(), "the slot must keep its typing")
	assert_true(editor_undo(_undo_redo), "undo clear should succeed")
	assert_eq((node.get("textures") as Array).size(), 1, "undo must restore the seeded element")
	_free_typed_array_probe(0)


# ----- set_property: object-element typed arrays (#612 stage 2) -----

const _STAGE2_TEX_PATH := "res://tests/_mcp_stage2_texture.tres"


## The test project ships no image assets, so stage-2 path-element tests
## save (and afterwards remove) a real Texture2D .tres to load from.
func _stage2_texture_path() -> String:
	if not FileAccess.file_exists(_STAGE2_TEX_PATH):
		var tex := GradientTexture2D.new()
		assert_eq(ResourceSaver.save(tex, _STAGE2_TEX_PATH), OK,
			"seed texture must save")
	return _STAGE2_TEX_PATH


func _cleanup_stage2_texture() -> void:
	if FileAccess.file_exists(_STAGE2_TEX_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_STAGE2_TEX_PATH))
		var efs := EditorInterface.get_resource_filesystem()
		if efs != null:
			efs.update_file(_STAGE2_TEX_PATH)


func test_set_property_typed_object_array_loads_resource_paths() -> void:
	## Stage 2 headline: res:// path elements load into Array[Texture2D] —
	## previously refused loudly, before that silently dropped.
	var node := _make_typed_array_probe("_McpTypedObjects")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjects",
		"property": "textures",
		"value": [_stage2_texture_path()],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("textures")
	assert_eq((stored as Array).size(), 1, "the loaded element must land")
	assert_true(stored[0] is Texture2D, "res:// element must load as Texture2D")
	assert_true((stored as Array).is_typed(), "the slot must keep its typing")
	_free_typed_array_probe(1)
	_cleanup_stage2_texture()


func test_set_property_typed_object_array_instantiates_class_dicts() -> void:
	## {"__class__": ...} elements instantiate + apply remaining keys, the
	## same shortcut single Object slots support.
	var node := _make_typed_array_probe("_McpTypedObjMeshes")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjMeshes",
		"property": "meshes",
		"value": [
			{"__class__": "BoxMesh", "size": {"x": 2, "y": 2, "z": 2}},
			{"__class__": "SphereMesh"},
		],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("meshes")
	assert_eq((stored as Array).size(), 2)
	assert_true(stored[0] is BoxMesh, "__class__ element must instantiate")
	assert_eq((stored[0] as BoxMesh).size, Vector3(2, 2, 2),
		"remaining __class__ keys must apply as properties")
	assert_true(stored[1] is SphereMesh)
	_free_typed_array_probe(1)


func test_set_property_typed_object_array_wrong_class_errors_names_index() -> void:
	## A BoxMesh is a Resource but not a Texture2D — the conformance check
	## must error naming the element index, not let assign() reject the
	## whole write with a generic message (or worse, partially land it).
	var node := _make_typed_array_probe("_McpTypedObjWrongClass")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjWrongClass",
		"property": "textures",
		"value": [{"__class__": "BoxMesh"}],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "element 0",
		"the error must name the offending element index")
	assert_contains(result.error.message, "Texture2D",
		"the error must name the expected element class")
	assert_eq((node.get("textures") as Array).size(), 0, "slot must stay untouched on error")
	_free_typed_array_probe(0)


func test_set_property_typed_object_array_allows_null_entries() -> void:
	## Godot's object-typed arrays store null entries; null and "" elements
	## mirror the single-slot clear semantics instead of erroring.
	var node := _make_typed_array_probe("_McpTypedObjNulls")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjNulls",
		"property": "textures",
		"value": [null, _stage2_texture_path(), ""],
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("textures")
	assert_eq((stored as Array).size(), 3)
	assert_eq(stored[0], null)
	assert_true(stored[1] is Texture2D)
	assert_eq(stored[2], null)
	_free_typed_array_probe(1)
	_cleanup_stage2_texture()


func test_set_property_typed_object_array_missing_path_errors_names_index() -> void:
	var node := _make_typed_array_probe("_McpTypedObjMissing")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjMissing",
		"property": "textures",
		"value": [_stage2_texture_path(), "res://does_not_exist.png"],
	})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)
	assert_contains(result.error.message, "element 1",
		"the error must name the offending element index")
	assert_eq((node.get("textures") as Array).size(), 0, "slot must stay untouched on error")
	_free_typed_array_probe(0)
	_cleanup_stage2_texture()


func test_set_property_typed_object_array_unconvertible_element_errors() -> void:
	var node := _make_typed_array_probe("_McpTypedObjBad")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedObjBad",
		"property": "textures",
		"value": [42],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "element 0",
		"the error must name the offending element index")
	assert_eq((node.get("textures") as Array).size(), 0)
	_free_typed_array_probe(0)


# ----- set_property: typed Dictionary[K, V] slots (#612 stage 3) -----

func test_set_property_typed_dictionary_roundtrip() -> void:
	## The Dictionary half of the #612 repro: {"a": 1} into a
	## Dictionary[String, int] slot used to be silently dropped.
	var node := _make_typed_array_probe("_McpTypedDict")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDict",
		"property": "scores",
		"value": {"a": 1, "b": 2},
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("scores")
	assert_true(stored is Dictionary, "scores must read back as a Dictionary")
	assert_eq((stored as Dictionary).size(), 2, "all entries must land — no silent drop")
	assert_eq(stored["a"], 1)
	assert_eq(stored["b"], 2)
	assert_true((stored as Dictionary).is_typed(), "the slot must keep its typing")
	_free_typed_array_probe(1)


func test_set_property_typed_dictionary_coerces_int_keys() -> void:
	## JSON object keys are always strings; a Dictionary[int, V] slot must
	## parse exact int strings and store real int keys.
	var node := _make_typed_array_probe("_McpTypedDictIntKeys")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictIntKeys",
		"property": "by_id",
		"value": {"3": "three", "7": "seven"},
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("by_id")
	assert_eq((stored as Dictionary).size(), 2)
	assert_true((stored as Dictionary).has(3), "key must land as int 3, not String")
	assert_eq(stored[7], "seven")
	_free_typed_array_probe(1)


func test_set_property_typed_dictionary_bad_int_key_errors() -> void:
	var node := _make_typed_array_probe("_McpTypedDictBadKey")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictBadKey",
		"property": "by_id",
		"value": {"3": "ok", "abc": "nope"},
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, 'key "abc"',
		"the error must name the offending key")
	assert_eq((node.get("by_id") as Dictionary).size(), 0, "nothing may be written on error")
	_free_typed_array_probe(0)


func test_set_property_typed_dictionary_colliding_keys_error() -> void:
	## "1" and "01" both coerce to int 1 — landing one of them silently
	## would be the exact data-loss shape this issue exists to kill.
	var node := _make_typed_array_probe("_McpTypedDictCollide")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictCollide",
		"property": "by_id",
		"value": {"1": "a", "01": "b"},
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "collide",
		"key collisions after coercion must refuse, not drop an entry")
	assert_eq((node.get("by_id") as Dictionary).size(), 0)
	_free_typed_array_probe(0)


func test_set_property_typed_dictionary_wrong_value_errors_names_key() -> void:
	var node := _make_typed_array_probe("_McpTypedDictBadValue")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictBadValue",
		"property": "scores",
		"value": {"a": 1, "b": "two"},
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, 'key "b"',
		"the error must name the offending key")
	assert_eq((node.get("scores") as Dictionary).size(), 0, "slot must stay untouched on error")
	_free_typed_array_probe(0)


func test_set_property_typed_dictionary_object_values() -> void:
	## Object values take the stage-2 element coercion: __class__ dicts
	## instantiate, and wrong-class values error naming the key.
	var node := _make_typed_array_probe("_McpTypedDictObjVals")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictObjVals",
		"property": "mesh_map",
		"value": {"box": {"__class__": "BoxMesh", "size": {"x": 2, "y": 2, "z": 2}}},
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("mesh_map")
	assert_eq((stored as Dictionary).size(), 1)
	assert_true(stored["box"] is BoxMesh, "__class__ value must instantiate")
	assert_eq((stored["box"] as BoxMesh).size, Vector3(2, 2, 2))
	_free_typed_array_probe(1)


func test_set_property_typed_dictionary_wrong_class_value_errors() -> void:
	var node := _make_typed_array_probe("_McpTypedDictWrongClass")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictWrongClass",
		"property": "mesh_map",
		"value": {"tex": {"__class__": "GradientTexture2D"}},
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, 'key "tex"',
		"the error must name the offending key")
	assert_contains(result.error.message, "Mesh",
		"the error must name the expected value class")
	assert_eq((node.get("mesh_map") as Dictionary).size(), 0)
	_free_typed_array_probe(0)


func test_set_property_typed_dictionary_null_object_value_allowed() -> void:
	var node := _make_typed_array_probe("_McpTypedDictNullObj")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictNullObj",
		"property": "mesh_map",
		"value": {"empty": null},
	})
	assert_has_key(result, "data")
	var stored: Variant = node.get("mesh_map")
	assert_eq((stored as Dictionary).size(), 1)
	assert_eq(stored["empty"], null)
	_free_typed_array_probe(1)


func test_set_property_typed_dictionary_null_scalar_value_errors() -> void:
	var node := _make_typed_array_probe("_McpTypedDictNullScalar")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictNullScalar",
		"property": "scores",
		"value": {"a": null},
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, 'key "a"',
		"the error must name the offending key")
	assert_eq((node.get("scores") as Dictionary).size(), 0)
	_free_typed_array_probe(0)


func test_set_property_typed_dictionary_non_object_value_errors() -> void:
	var node := _make_typed_array_probe("_McpTypedDictNonObj")
	var result := _handler.set_property({
		"path": "/Main/_McpTypedDictNonObj",
		"property": "scores",
		"value": [1, 2],
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "Dictionary[String, int]",
		"the error must name the typed slot")
	assert_eq((node.get("scores") as Dictionary).size(), 0)
	_free_typed_array_probe(0)


func test_set_property_typed_dictionary_undo_restores_previous_value() -> void:
	var node := _make_typed_array_probe("_McpTypedDictUndo")
	var first := _handler.set_property({
		"path": "/Main/_McpTypedDictUndo", "property": "scores", "value": {"a": 7},
	})
	assert_has_key(first, "data")
	var second := _handler.set_property({
		"path": "/Main/_McpTypedDictUndo", "property": "scores", "value": {"b": 8},
	})
	assert_has_key(second, "data")
	assert_true(editor_undo(_undo_redo), "undo second set should succeed")
	var stored: Variant = node.get("scores")
	assert_eq((stored as Dictionary).size(), 1, "undo must restore the previous dictionary")
	assert_eq(stored["a"], 7)
	_free_typed_array_probe(1)


func test_set_property_typed_array_undo_restores_previous_value() -> void:
	var node := _make_typed_array_probe("_McpTypedUndo")
	var first := _handler.set_property({
		"path": "/Main/_McpTypedUndo", "property": "ints", "value": [7],
	})
	assert_has_key(first, "data")
	var second := _handler.set_property({
		"path": "/Main/_McpTypedUndo", "property": "ints", "value": [8, 9],
	})
	assert_has_key(second, "data")
	assert_true(editor_undo(_undo_redo), "undo second set should succeed")
	var stored: Variant = node.get("ints")
	assert_eq((stored as Array).size(), 1, "undo must restore the previous array")
	assert_eq(stored[0], 7)
	_free_typed_array_probe(1)
