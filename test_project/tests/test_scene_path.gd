@tool
extends McpTestSuite

## Tests for McpScenePath — the path resolver/formatter shared by every
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


# ----- from_node: clean path formatting -----

func test_from_node_scene_root_returns_root_prefix() -> void:
	var root := _make_tree()
	assert_eq(McpScenePath.from_node(root, root), "/Main")
	root.queue_free()


func test_from_node_direct_child_returns_root_prefixed_path() -> void:
	var root := _make_tree()
	var cam := root.get_node("Camera3D")
	assert_eq(McpScenePath.from_node(cam, root), "/Main/Camera3D")
	root.queue_free()


func test_from_node_nested_descendant_returns_full_path() -> void:
	var root := _make_tree()
	var ground := root.get_node("World/Ground")
	assert_eq(McpScenePath.from_node(ground, root), "/Main/World/Ground")
	root.queue_free()


func test_from_node_null_node_returns_empty_string() -> void:
	var root := _make_tree()
	assert_eq(McpScenePath.from_node(null, root), "")
	root.queue_free()


func test_from_node_null_scene_root_returns_empty_string() -> void:
	var n := Node.new()
	assert_eq(McpScenePath.from_node(n, null), "")
	n.free()


func test_from_node_orphan_node_returns_empty_string() -> void:
	## A node not parented anywhere is not an ancestor of scene_root. Without
	## the is_ancestor_of guard, get_path_to() returns an empty NodePath and
	## from_node would produce "/Main/" — a plausible-looking string that
	## resolves to nothing. Issue #297 audit finding #4.
	var root := _make_tree()
	var orphan := Node.new()
	orphan.name = "Orphan"
	assert_eq(McpScenePath.from_node(orphan, root), "")
	orphan.free()
	root.queue_free()


func test_from_node_foreign_tree_returns_empty_string() -> void:
	## Node lives in a sibling tree to scene_root. Same hazard as the orphan
	## case but more representative of the real-world bug: handlers passing
	## nodes from instanced sub-scenes or foreign trees.
	var root := _make_tree()
	var other_root := Node.new()
	other_root.name = "OtherRoot"
	var foreign := Node.new()
	foreign.name = "Foreign"
	other_root.add_child(foreign)
	assert_eq(McpScenePath.from_node(foreign, root), "")
	other_root.queue_free()
	root.queue_free()


func test_from_node_ancestor_of_scene_root_returns_empty_string() -> void:
	## scene_root's parent is not a descendant of scene_root. is_ancestor_of
	## must reject upward lookups too, not just sideways/foreign ones.
	var root := _make_tree()
	var parent := Node.new()
	parent.name = "Parent"
	parent.add_child(root)
	assert_eq(McpScenePath.from_node(parent, root), "")
	parent.queue_free()


# ----- resolve: existing canonical forms -----

func test_resolve_root_prefix_returns_scene_root() -> void:
	var root := _make_tree()
	assert_eq(McpScenePath.resolve("/Main", root), root)
	root.queue_free()


func test_resolve_descendant_via_root_prefix() -> void:
	var root := _make_tree()
	var cam := McpScenePath.resolve("/Main/Camera3D", root)
	assert_ne(cam, null, "should find Camera3D")
	assert_eq(cam.name, "Camera3D")
	root.queue_free()


func test_resolve_nested_descendant() -> void:
	var root := _make_tree()
	var ground := McpScenePath.resolve("/Main/World/Ground", root)
	assert_ne(ground, null)
	assert_eq(ground.name, "Ground")
	root.queue_free()


# ----- resolve: /root/<scene_root_name> alias (issue #71) -----

func test_resolve_root_alias_with_scene_name_returns_scene_root() -> void:
	## /root/Main → scene root. This is the agent's most common mistake;
	## resolving it (instead of erroring) saves a round trip.
	var root := _make_tree()
	assert_eq(McpScenePath.resolve("/root/Main", root), root)
	root.queue_free()


func test_resolve_root_alias_with_descendant() -> void:
	var root := _make_tree()
	var cam := McpScenePath.resolve("/root/Main/Camera3D", root)
	assert_ne(cam, null)
	assert_eq(cam.name, "Camera3D")
	root.queue_free()


func test_resolve_root_alias_nested_descendant() -> void:
	var root := _make_tree()
	var ground := McpScenePath.resolve("/root/Main/World/Ground", root)
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
	assert_eq(McpScenePath.resolve("/root/@EditorNode@1/Main/Camera3D", root), null)
	root.queue_free()


# ----- resolve: failure cases -----

func test_resolve_unknown_path_returns_null() -> void:
	var root := _make_tree()
	assert_eq(McpScenePath.resolve("/Main/DoesNotExist", root), null)
	root.queue_free()


func test_resolve_null_scene_root_returns_null() -> void:
	assert_eq(McpScenePath.resolve("/Main", null), null)


# ----- format_parent_error: agent-readable message -----

func test_format_parent_error_names_scene_root() -> void:
	var root := _make_tree()
	var msg := McpScenePath.format_parent_error("/SomeBogusPath", root)
	assert_contains(msg, "/SomeBogusPath")
	assert_contains(msg, "/Main")
	assert_contains(msg, "relative to the edited scene root")
	assert_contains(msg, "not the SceneTree")
	root.queue_free()


func test_format_parent_error_uses_generic_paths_wording() -> void:
	## Helper is shared across param names (parent_path, new_parent, …); the
	## message must not hardcode any specific param name.
	var root := _make_tree()
	var msg := McpScenePath.format_parent_error("/X", root)
	assert_false(msg.contains("parent_path"), "should not name a specific param")
	assert_contains(msg, "Paths are relative")
	root.queue_free()


func test_format_parent_error_null_root_returns_actionable_message() -> void:
	## When no scene is open there's no scene_root to suggest. Return a
	## message that points at the real problem instead of "/<no scene>".
	var msg := McpScenePath.format_parent_error("/Foo", null)
	assert_contains(msg, "/Foo")
	assert_contains(msg, "No edited scene is open")
	assert_false(msg.contains("<no scene>"), "should not leak placeholder")


# ----- format_node_error: agent-readable message with "did you mean" -----

func test_format_node_error_root_prefix_suggests_scene_relative_path() -> void:
	## The signature mistake (Cline's failure mode): /root/<NotSceneRoot>/...
	## We can rewrite that to /<sceneRoot>/<rest> with high confidence.
	var root := _make_tree()
	var msg := McpScenePath.format_node_error("/root/Cube0", root)
	assert_contains(msg, "/root/Cube0")
	assert_contains(msg, "Did you mean")
	assert_contains(msg, "/Main/Cube0")
	assert_contains(msg, "/Main")
	root.queue_free()


func test_format_node_error_root_prefix_with_descendant_suggests_full_rewrite() -> void:
	var root := _make_tree()
	var msg := McpScenePath.format_node_error("/root/Foo/Bar/Baz", root)
	assert_contains(msg, "Did you mean")
	assert_contains(msg, "/Main/Foo/Bar/Baz")
	root.queue_free()


func test_format_node_error_root_prefix_matching_scene_root_no_suggestion() -> void:
	## /root/Main/... is already aliased by resolve(), so a failure with that
	## prefix means a deeper segment is wrong — there's no clean rewrite to
	## suggest. Fall back to the convention reminder.
	var root := _make_tree()
	var msg := McpScenePath.format_node_error("/root/Main/Nope", root)
	assert_false(msg.contains("Did you mean"), "no clean rewrite available")
	assert_contains(msg, "relative to the edited scene root")
	root.queue_free()


func test_format_node_error_unprefixed_path_suggests_scene_relative() -> void:
	## Bare "Cube0" with no leading slash → suggest "/Main/Cube0".
	var root := _make_tree()
	var msg := McpScenePath.format_node_error("Cube0", root)
	assert_contains(msg, "Did you mean")
	assert_contains(msg, "/Main/Cube0")
	root.queue_free()


func test_format_node_error_already_relative_path_no_suggestion() -> void:
	## /Main/Nope is correctly formatted but doesn't resolve — no rewrite
	## possible, just remind about the convention so the agent can re-check
	## the actual node names via scene_get_hierarchy.
	var root := _make_tree()
	var msg := McpScenePath.format_node_error("/Main/Nope", root)
	assert_false(msg.contains("Did you mean"))
	assert_contains(msg, "Node not found: /Main/Nope")
	assert_contains(msg, "/Main")
	root.queue_free()


func test_format_node_error_null_root_returns_actionable_message() -> void:
	var msg := McpScenePath.format_node_error("/root/Foo", null)
	assert_contains(msg, "/root/Foo")
	assert_contains(msg, "No edited scene is open")
	assert_false(msg.contains("<no scene>"), "should not leak placeholder")


func test_format_node_error_mentions_runtime_root_anti_pattern() -> void:
	## The message must explicitly call out that /root/... is wrong, not just
	## that "paths are relative". Agents need the antipattern named to
	## connect their mistake to the fix.
	var root := _make_tree()
	var msg := McpScenePath.format_node_error("/root/X", root)
	assert_contains(msg, "/root/")
	root.queue_free()


# ----- require_edited_scene: multi-call scene-drift guard (issue #74) -----

func test_require_edited_scene_empty_expected_returns_current_root() -> void:
	## Empty string = "target whatever is active"; matches pre-guard behavior
	## so callers that don't opt in see no change.
	var result := McpScenePath.require_edited_scene("")
	assert_has_key(result, "node")
	assert_eq(result.node, EditorInterface.get_edited_scene_root())


func test_require_edited_scene_matching_path_returns_root() -> void:
	## Non-empty expected that matches current edited scene passes through.
	var root := EditorInterface.get_edited_scene_root()
	assert_ne(root, null, "test harness must have a scene open")
	var result := McpScenePath.require_edited_scene(root.scene_file_path)
	assert_has_key(result, "node")
	assert_eq(result.node, root)


func test_require_edited_scene_mismatch_returns_structured_error() -> void:
	## A non-empty expected that doesn't match the active scene must fail with
	## EDITED_SCENE_MISMATCH, not silently target the wrong scene.
	var result := McpScenePath.require_edited_scene("res://this/does/not/match.tscn")
	assert_is_error(result, McpErrorCodes.EDITED_SCENE_MISMATCH)
	## Message must name both the expected and the active scene so the caller
	## can diagnose drift without another call.
	var active := EditorInterface.get_edited_scene_root().scene_file_path
	assert_contains(result.error.message, "res://this/does/not/match.tscn")
	assert_contains(result.error.message, active)
	## And name the recovery tool so the caller isn't guessing.
	assert_contains(result.error.message, "scene_open")
