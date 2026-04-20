@tool
extends McpTestSuite

## Tests for ScenePath — the path resolver/formatter shared by every
## scene-mutating handler. Uses a freestanding Node tree (no dependency
## on the edited scene) so behavior is deterministic.


func suite_name() -> String:
	return "scene_path"


# ----- helpers -----

func _make_tree() -> Node:
	## Returns: scene_root("Main") with /Main/Camera3D and /Main/World/Ground.
	var main := Node.new()
	main.name = "Main"
	var cam := Node.new()
	cam.name = "Camera3D"
	main.add_child(cam)
	var world := Node.new()
	world.name = "World"
	main.add_child(world)
	var ground := Node.new()
	ground.name = "Ground"
	world.add_child(ground)
	return main


# ----- resolve: existing canonical forms -----

func test_resolve_root_prefix_returns_scene_root() -> void:
	var root := _make_tree()
	assert_eq(ScenePath.resolve("/Main", root), root)
	root.queue_free()


func test_resolve_descendant_via_root_prefix() -> void:
	var root := _make_tree()
	var cam := ScenePath.resolve("/Main/Camera3D", root)
	assert_ne(cam, null, "should find Camera3D")
	assert_eq(cam.name, "Camera3D")
	root.queue_free()


func test_resolve_nested_descendant() -> void:
	var root := _make_tree()
	var ground := ScenePath.resolve("/Main/World/Ground", root)
	assert_ne(ground, null)
	assert_eq(ground.name, "Ground")
	root.queue_free()


# ----- resolve: /root/<scene_root_name> alias (issue #71) -----

func test_resolve_root_alias_with_scene_name_returns_scene_root() -> void:
	## /root/Main → scene root. This is the agent's most common mistake;
	## resolving it (instead of erroring) saves a round trip.
	var root := _make_tree()
	assert_eq(ScenePath.resolve("/root/Main", root), root)
	root.queue_free()


func test_resolve_root_alias_with_descendant() -> void:
	var root := _make_tree()
	var cam := ScenePath.resolve("/root/Main/Camera3D", root)
	assert_ne(cam, null)
	assert_eq(cam.name, "Camera3D")
	root.queue_free()


func test_resolve_root_alias_nested_descendant() -> void:
	var root := _make_tree()
	var ground := ScenePath.resolve("/root/Main/World/Ground", root)
	assert_ne(ground, null)
	assert_eq(ground.name, "Ground")
	root.queue_free()


func test_resolve_does_not_hijack_editor_internal_root_paths() -> void:
	## Node.get_path() inside the editor returns paths like
	## /root/@EditorNode@.../Main/X. Those legitimately live under /root but
	## the segment after /root is NOT the scene_root's name — the alias must
	## not swallow them, or absolute-path lookups break for every handler
	## that resolves a node by its real SceneTree path.
	var root := _make_tree()
	## Path doesn't match alias prefix "/root/Main" → falls through to the
	## absolute-path fallback (which returns null here because root isn't
	## actually in any SceneTree, but the key behavior is "don't strip /root").
	assert_eq(ScenePath.resolve("/root/@EditorNode@1/Main/Camera3D", root), null)
	root.queue_free()


# ----- resolve: failure cases -----

func test_resolve_unknown_path_returns_null() -> void:
	var root := _make_tree()
	assert_eq(ScenePath.resolve("/Main/DoesNotExist", root), null)
	root.queue_free()


func test_resolve_null_scene_root_returns_null() -> void:
	assert_eq(ScenePath.resolve("/Main", null), null)


# ----- format_parent_error: agent-readable message -----

func test_format_parent_error_names_scene_root() -> void:
	var root := _make_tree()
	var msg := ScenePath.format_parent_error("/SomeBogusPath", root)
	assert_contains(msg, "/SomeBogusPath")
	assert_contains(msg, "/Main")
	assert_contains(msg, "relative to the edited scene root")
	assert_contains(msg, "not the SceneTree")
	root.queue_free()


func test_format_parent_error_uses_generic_paths_wording() -> void:
	## Helper is shared across param names (parent_path, new_parent, …); the
	## message must not hardcode any specific param name.
	var root := _make_tree()
	var msg := ScenePath.format_parent_error("/X", root)
	assert_false(msg.contains("parent_path"), "should not name a specific param")
	assert_contains(msg, "Paths are relative")
	root.queue_free()


func test_format_parent_error_null_root_returns_actionable_message() -> void:
	## When no scene is open there's no scene_root to suggest. Return a
	## message that points at the real problem instead of "/<no scene>".
	var msg := ScenePath.format_parent_error("/Foo", null)
	assert_contains(msg, "/Foo")
	assert_contains(msg, "No edited scene is open")
	assert_false(msg.contains("<no scene>"), "should not leak placeholder")


# ----- require_edited_scene: multi-call scene-drift guard (issue #74) -----

func test_require_edited_scene_empty_expected_returns_current_root() -> void:
	## Empty string = "target whatever is active"; matches pre-guard behavior
	## so callers that don't opt in see no change.
	var result := ScenePath.require_edited_scene("")
	assert_has_key(result, "node")
	assert_eq(result.node, EditorInterface.get_edited_scene_root())


func test_require_edited_scene_matching_path_returns_root() -> void:
	## Non-empty expected that matches current edited scene passes through.
	var root := EditorInterface.get_edited_scene_root()
	assert_ne(root, null, "test harness must have a scene open")
	var result := ScenePath.require_edited_scene(root.scene_file_path)
	assert_has_key(result, "node")
	assert_eq(result.node, root)


func test_require_edited_scene_mismatch_returns_structured_error() -> void:
	## A non-empty expected that doesn't match the active scene must fail with
	## EDITED_SCENE_MISMATCH, not silently target the wrong scene.
	var result := ScenePath.require_edited_scene("res://this/does/not/match.tscn")
	assert_is_error(result, McpErrorCodes.EDITED_SCENE_MISMATCH)
	## Message must name both the expected and the active scene so the caller
	## can diagnose drift without another call.
	var active := EditorInterface.get_edited_scene_root().scene_file_path
	assert_contains(result.error.message, "res://this/does/not/match.tscn")
	assert_contains(result.error.message, active)
	## And name the recovery tool so the caller isn't guessing.
	assert_contains(result.error.message, "scene_open")
