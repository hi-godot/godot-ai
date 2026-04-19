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


# ----- resolve: /root/ alias (issue #71) -----

func test_resolve_root_alias_returns_scene_root() -> void:
	## /root is a SceneTree-style alias for the edited scene root.
	var root := _make_tree()
	assert_eq(ScenePath.resolve("/root", root), root)
	root.queue_free()


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
	var msg := ScenePath.format_parent_error("/root/Main", root)
	assert_contains(msg, "/root/Main")
	assert_contains(msg, "/Main")
	assert_contains(msg, "relative to the edited scene root")
	assert_contains(msg, "not the SceneTree")
	root.queue_free()


func test_format_parent_error_handles_null_root() -> void:
	## Defensive: format_parent_error shouldn't crash if scene_root is null
	## (which can happen if a check is misordered in a handler).
	var msg := ScenePath.format_parent_error("/Foo", null)
	assert_contains(msg, "/Foo")
