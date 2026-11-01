@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/animation_tree_handler.gd")
var _handler: Handler
var _undo: EditorUndoRedoManager
var _root: Node
var _tree: AnimationTree
var _path: String


func suite_name() -> String:
	return "animation_tree"


func suite_setup(ctx: Dictionary) -> void:
	_undo = ctx.undo_redo
	_handler = Handler.new(_undo)


func setup() -> void:
	_root = EditorInterface.get_edited_scene_root()
	_tree = AnimationTree.new()
	_tree.name = "GraphTest"
	_tree.active = false
	_tree.tree_root = AnimationNodeStateMachine.new()
	_root.add_child(_tree)
	_tree.owner = _root
	_path = McpScenePath.from_node(_tree, _root)


func teardown() -> void:
	_root.remove_child(_tree)
	_tree.queue_free()


func _call(op: String, params := {}) -> Dictionary:
	params.tree_path = _path
	return _handler.call(op, params)


func _ok(result: Dictionary) -> void:
	assert_false(result.has("error"), str(result))


func test_state_nodes_transitions_identity_and_order_undo() -> void:
	_ok(_call("tree_node_add", {"name": "Idle", "properties": {"animation": "idle"}, "position": {"x": 120, "y": 40}}))
	_ok(_call("tree_node_add", {"name": "Run", "properties": {"animation": "run"}}))
	var graph := _tree.tree_root as AnimationNodeStateMachine
	var idle := graph.get_node("Idle") as AnimationNodeAnimation
	assert_eq(String(idle.animation), "idle")
	assert_eq(graph.get_node_position("Idle"), Vector2(120, 40))
	_ok(_call("tree_transition_add", {"from_state": "Start", "to_state": "Idle"}))
	_ok(_call("tree_transition_add", {"from_state": "Idle", "to_state": "Run", "properties": {"xfade_time": 0.25, "advance_mode": 2, "advance_condition": "running"}}))
	_ok(_call("tree_transition_add", {"from_state": "Run", "to_state": "End"}))
	var transitions := [graph.get_transition(0), graph.get_transition(1), graph.get_transition(2)]
	assert_eq(transitions[1].xfade_time, 0.25)
	assert_eq(String(transitions[1].advance_condition), "running")
	_tree.set("parameters/conditions/running", true)
	assert_eq(_tree.get("parameters/conditions/running"), true, "condition is available immediately after add")
	_ok(_call("tree_node_remove", {"name": "Idle"}))
	assert_false(graph.has_node("Idle"))
	assert_eq(graph.get_transition(0), transitions[2])
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_node("Idle"), idle)
	assert_eq(graph.get_node_position("Idle"), Vector2(120, 40))
	for i in 3:
		assert_eq(graph.get_transition(i), transitions[i])
	assert_eq(_tree.get("parameters/conditions/running"), true)
	assert_true(editor_redo(_undo))
	assert_false(graph.has_node("Idle"))
	assert_true(editor_undo(_undo))
	_ok(_call("tree_transition_remove", {"from_state": "Idle", "to_state": "Run"}))
	assert_eq(graph.get_transition(1), transitions[2])
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_transition(1), transitions[1])
	_ok(_call("tree_transition_set", {"from_state": "Idle", "to_state": "Run", "properties": {"xfade_time": 0.75}}))
	assert_eq(transitions[1].xfade_time, 0.75)
	assert_true(editor_undo(_undo))
	assert_eq(transitions[1].xfade_time, 0.25)
	assert_eq(graph.get_transition(1), transitions[1])


func test_nested_blend_connections_and_parameter_restoration() -> void:
	_ok(_call("tree_node_add", {"name": "Locomotion", "node_type": "AnimationNodeBlendTree"}))
	var graph := (_tree.tree_root as AnimationNodeStateMachine).get_node("Locomotion") as AnimationNodeBlendTree
	for name in ["Idle", "Run"]:
		_ok(_call("tree_node_add", {"graph_path": "Locomotion", "name": name, "properties": {"animation": name.to_lower()}}))
	_ok(_call("tree_node_add", {"graph_path": "Locomotion", "name": "Mix", "node_type": "AnimationNodeBlend2"}))
	_ok(_call("tree_connect", {"graph_path": "Locomotion", "input_node": "Mix", "input_index": 0, "output_node": "Idle"}))
	_ok(_call("tree_connect", {"graph_path": "Locomotion", "input_node": "Mix", "input_index": 1, "output_node": "Run"}))
	_ok(_call("tree_connect", {"graph_path": "Locomotion", "input_node": "output", "input_index": 0, "output_node": "Mix"}))
	var connections: Array = graph.get("node_connections")
	var mix := graph.get_node("Mix")
	_tree.set("parameters/Locomotion/Mix/blend_amount", 0.6)
	var read := _call("tree_get", {"graph_path": "Locomotion"})
	_ok(read)
	assert_eq(read.data.graph.connections.size(), 3)
	assert_true(is_equal_approx(read.data.parameters["parameters/Locomotion/Mix/blend_amount"], 0.6))
	_ok(_call("tree_node_remove", {"graph_path": "Locomotion", "name": "Mix"}))
	assert_eq(graph.get("node_connections"), [])
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_node("Mix"), mix)
	assert_eq(graph.get("node_connections"), connections)
	assert_true(is_equal_approx(_tree.get("parameters/Locomotion/Mix/blend_amount"), 0.6))
	_ok(_call("tree_disconnect", {"graph_path": "Locomotion", "input_node": "Mix", "input_index": 1}))
	assert_eq(graph.get("node_connections").size(), 6)
	assert_true(editor_undo(_undo))
	assert_eq(graph.get("node_connections"), connections)
	_ok(_call("tree_node_set", {"graph_path": "Locomotion/Idle", "properties": {"animation": "rest"}}))
	assert_eq(String(graph.get_node("Idle").animation), "rest")
	assert_true(editor_undo(_undo))
	assert_eq(String(graph.get_node("Idle").animation), "idle")


func test_invalid_requests_leave_state_and_history_unchanged() -> void:
	_ok(_call("tree_node_add", {"name": "Idle"}))
	var graph := _tree.tree_root as AnimationNodeStateMachine
	var idle := graph.get_node("Idle")
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_call("tree_node_add", {"name": "Idle"}))
	assert_is_error(_call("tree_node_add", {"name": "bad/name"}))
	assert_is_error(_call("tree_node_add", {"name": "Bad", "node_type": "AnimationNodeBlend2"}))
	assert_is_error(_call("tree_node_add", {"name": "Bad", "properties": {"missing": 1}}))
	assert_is_error(_call("tree_node_add", {"name": "Bad", "position": {"x": INF, "y": 0}}))
	assert_is_error(_call("tree_node_remove", {"name": "Start"}))
	assert_is_error(_call("tree_node_remove", {"name": "End"}))
	assert_is_error(_call("tree_transition_add", {"from_state": "End", "to_state": "Idle"}))
	assert_is_error(_call("tree_transition_add", {"from_state": "Idle", "to_state": "Start"}))
	assert_is_error(_call("tree_transition_add", {"from_state": "Idle", "to_state": "Idle"}))
	assert_is_error(_call("tree_transition_add", {"from_state": "Start", "to_state": "Idle", "properties": {"xfade_time": INF}}))
	assert_is_error(_call("tree_node_set", {"graph_path": "Idle", "properties": {"script": "res://anything.gd"}}))
	assert_is_error(_call("tree_node_set", {"properties": {"states/Injected/node": {"__class__": "AnimationNodeAnimation"}}}))
	assert_eq(graph.get_node("Idle"), idle)
	assert_eq(graph.get_transition_count(), 0)
	assert_eq(history.get_version(), version)


func test_blend_refusals_cycles_topology_and_boolean_types() -> void:
	_tree.tree_root = AnimationNodeBlendTree.new()
	for name in ["A", "B", "C"]:
		_ok(_call("tree_node_add", {"name": name, "node_type": "AnimationNodeBlend2"}))
	_ok(_call("tree_connect", {"input_node": "B", "input_index": 0, "output_node": "A"}))
	_ok(_call("tree_connect", {"input_node": "C", "input_index": 0, "output_node": "B"}))
	var graph := _tree.tree_root as AnimationNodeBlendTree
	var connections: Array = graph.get("node_connections")
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_call("tree_connect", {"input_node": "A", "input_index": 0, "output_node": "C"}))
	assert_is_error(_call("tree_connect", {"input_node": "C", "input_index": 1, "output_node": "A"}))
	assert_is_error(_call("tree_connect", {"input_node": "B", "input_index": 0, "output_node": "C"}))
	assert_is_error(_call("tree_connect", {"input_node": "A", "input_index": 0.5, "output_node": "C"}))
	assert_is_error(_call("tree_connect", {"input_node": "A", "input_index": true, "output_node": "C"}))
	assert_is_error(_call("tree_connect", {"input_node": "A", "input_index": 5, "output_node": "C"}))
	assert_is_error(_call("tree_connect", {"input_node": "A", "input_index": 0, "output_node": "output"}))
	assert_is_error(_call("tree_node_remove", {"name": "output"}))
	assert_is_error(_call("tree_node_set", {"graph_path": "A", "properties": {"sync": "false"}}))
	assert_eq(graph.get("node_connections"), connections)
	assert_eq(history.get_version(), version)
	_ok(_call("tree_node_add", {"name": "Switch", "node_type": "AnimationNodeTransition", "properties": {"input_count": 2}}))
	assert_eq(graph.get_node("Switch").get_input_count(), 2)
	assert_is_error(_call("tree_node_set", {"graph_path": "Switch", "properties": {"input_count": 1}}))
	assert_eq(graph.get_node("Switch").get_input_count(), 2)


func test_create_undo_readback_and_scene_reopen() -> void:
	var player := AnimationPlayer.new()
	player.name = "GraphPlayer"
	_root.add_child(player)
	player.owner = _root
	var result := _handler.tree_create({"parent_path": McpScenePath.from_node(_root, _root), "player_path": McpScenePath.from_node(player, _root), "name": "CreatedGraph", "root_type": "blend_tree"})
	_ok(result)
	var created := _root.get_node("CreatedGraph") as AnimationTree
	assert_false(created.active)
	assert_eq(created.owner, _root)
	assert_eq(created.get_node(created.anim_player), player)
	var graph := created.tree_root
	assert_true(editor_undo(_undo))
	assert_eq(created.get_parent(), null)
	assert_true(editor_redo(_undo))
	assert_eq(created.tree_root, graph)
	assert_eq(created.get_node(created.anim_player), player)
	var created_path := McpScenePath.from_node(created, _root)
	_ok(_handler.tree_node_add({"tree_path": created_path, "name": "Clip", "properties": {"animation": "idle"}}))
	_ok(_handler.tree_connect({"tree_path": created_path, "input_node": "output", "input_index": 0, "output_node": "Clip"}))
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root), OK)
	var saved := "user://animation_graph_roundtrip.tscn"
	assert_eq(ResourceSaver.save(packed, saved), OK)
	var reopened := ResourceLoader.load(saved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := reopened.instantiate()
	var saved_tree := instance.get_node("CreatedGraph") as AnimationTree
	assert_true(saved_tree.tree_root is AnimationNodeBlendTree)
	assert_eq(String(saved_tree.tree_root.get_node("Clip").animation), "idle")
	assert_eq(saved_tree.tree_root.get("node_connections"), [StringName("output"), 0, StringName("Clip")])
	assert_eq(saved_tree.anim_player, created.anim_player)
	instance.free()
	DirAccess.remove_absolute(saved)
	_root.remove_child(created)
	created.queue_free()
	_root.remove_child(player)
	player.queue_free()


func test_shared_graph_identity_and_transition_refusals() -> void:
	var second := AnimationTree.new()
	second.active = false
	second.tree_root = _tree.tree_root
	_root.add_child(second)
	second.owner = _root
	_ok(_call("tree_node_add", {"name": "Idle"}))
	assert_eq(second.tree_root, _tree.tree_root)
	assert_eq(second.tree_root.get_node("Idle"), _tree.tree_root.get_node("Idle"))
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	for properties in [{"xfade_time": -1}, {"switch_mode": 99}, {"advance_mode": -1}, {"advance_condition": "bad/name"}, {"advance_condition": "bad:name"}, {"xfade_time": 1e300}]:
		assert_is_error(_call("tree_transition_add", {"from_state": "Start", "to_state": "Idle", "properties": properties}))
	assert_eq(history.get_version(), version)
	assert_eq(_tree.tree_root.get_transition_count(), 0)
	assert_true(editor_undo(_undo))
	assert_false(second.tree_root.has_node("Idle"))
	_root.remove_child(second)
	second.queue_free()


func test_instance_ownership_refuses_graph_mutation() -> void:
	var local := Node.new()
	local.name = "GraphInstance"
	var child := AnimationTree.new()
	child.name = "Tree"
	child.active = false
	child.tree_root = AnimationNodeStateMachine.new()
	local.add_child(child)
	child.owner = local
	var packed := PackedScene.new()
	assert_eq(packed.pack(local), OK)
	var fixture := "user://animation_graph_instance.tscn"
	assert_eq(ResourceSaver.save(packed, fixture), OK)
	local.free()
	var instance := (load(fixture) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_root.add_child(instance)
	instance.owner = _root
	var tree := instance.get_node("Tree") as AnimationTree
	var path := McpScenePath.from_node(tree, _root)
	assert_is_error(_handler.tree_node_add({"tree_path": path, "name": "Idle"}))
	assert_false(tree.tree_root.has_node("Idle"))
	_ok(_handler.tree_get({"tree_path": path}))
	_root.set_editable_instance(instance, true)
	_ok(_handler.tree_node_add({"tree_path": path, "name": "Idle"}))
	assert_eq(tree.tree_root.get_node("Idle").get_class(), "AnimationNodeAnimation")
	assert_true(editor_undo(_undo))
	assert_false(tree.tree_root.has_node("Idle"))
	_root.remove_child(instance)
	instance.queue_free()
	DirAccess.remove_absolute(fixture)


func test_shared_blend_removal_undo_restores_each_trees_parameters() -> void:
	_tree.tree_root = AnimationNodeBlendTree.new()
	_ok(_call("tree_node_add", {"name": "Mix", "node_type": "AnimationNodeBlend2"}))
	var second := AnimationTree.new()
	second.active = false
	second.tree_root = _tree.tree_root
	_root.add_child(second)
	second.owner = _root
	_tree.set("parameters/Mix/blend_amount", 0.2)
	second.set("parameters/Mix/blend_amount", 0.8)
	_ok(_call("tree_node_remove", {"name": "Mix"}))
	# Read the second tree as a real inspector would, materializing the removed schema.
	second.get_property_list()
	assert_true(editor_undo(_undo))
	assert_true(is_equal_approx(_tree.get("parameters/Mix/blend_amount"), 0.2))
	assert_true(is_equal_approx(second.get("parameters/Mix/blend_amount"), 0.8), "undo restores the other tree's distinct parameter value")
	_root.remove_child(second)
	second.queue_free()


func test_hidden_graph_properties_refused_before_mutation() -> void:
	_tree.tree_root = AnimationNodeBlendTree.new()
	var graph := _tree.tree_root as AnimationNodeBlendTree
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_call("tree_node_set", {"properties": {"graph_offset": {"x": INF, "y": 4}}}), "PROPERTY_NOT_ON_CLASS")
	assert_eq(graph.graph_offset, Vector2.ZERO)
	assert_eq(history.get_version(), version)


func test_transition_input_allocation_and_native_names_are_guarded() -> void:
	_tree.tree_root = AnimationNodeBlendTree.new()
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	for count in [-1, 0.5, 257, 1e300, INF, true]:
		assert_is_error(_call("tree_node_add", {"name": "Switch", "node_type": "AnimationNodeTransition", "properties": {"input_count": count}}))
	for name in ["bad/name", "bad.name"]:
		assert_is_error(_call("tree_node_add", {"name": "Switch", "node_type": "AnimationNodeTransition", "properties": {"input_count": 2, "input_0/name": name}}))
	assert_false(_tree.tree_root.has_node("Switch"))
	assert_eq(history.get_version(), version)
	_ok(_call("tree_node_add", {"name": "Switch", "node_type": "AnimationNodeTransition", "properties": {"input_count": 256, "input_0/name": "Idle", "input_255/name": "Last"}}))
	var node := _tree.tree_root.get_node("Switch") as AnimationNodeTransition
	assert_eq(node.get_input_count(), 256)
	assert_eq(node.get_input_name(0), "Idle")
	assert_eq(node.get_input_name(255), "Last")
	assert_true(editor_undo(_undo))
	assert_false(_tree.tree_root.has_node("Switch"))


func test_dotted_native_graph_names_resolve_and_persist() -> void:
	_ok(_call("tree_node_add", {"name": "Move.State", "node_type": "AnimationNodeBlendTree"}))
	_ok(_call("tree_node_add", {"graph_path": "Move.State", "name": "Walk.Fast", "properties": {"animation": "walk"}}))
	_ok(_call("tree_connect", {"graph_path": "Move.State", "input_node": "output", "input_index": 0, "output_node": "Walk.Fast"}))
	_ok(_call("tree_node_set", {"graph_path": "Move.State/Walk.Fast", "properties": {"animation": "run"}}))
	_ok(_call("tree_transition_add", {"from_state": "Start", "to_state": "Move.State"}))
	var machine := _tree.tree_root as AnimationNodeStateMachine
	var blend := machine.get_node("Move.State") as AnimationNodeBlendTree
	assert_eq(String(machine.get_transition_to(0)), "Move.State")
	assert_eq(String(blend.get_node("Walk.Fast").animation), "run")
	assert_eq(blend.get("node_connections"), [StringName("output"), 0, StringName("Walk.Fast")])
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root), OK)
	var path := "user://dotted_graph_roundtrip.tscn"
	assert_eq(ResourceSaver.save(packed, path), OK)
	var reopened := (ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var tree := reopened.get_node("GraphTest") as AnimationTree
	assert_eq(String(tree.tree_root.get_node("Move.State").get_node("Walk.Fast").animation), "run")
	assert_eq(String(tree.tree_root.get_transition_to(0)), "Move.State")
	reopened.free()
	DirAccess.remove_absolute(path)


func test_scripted_graph_ancestor_and_transition_refused_before_setters() -> void:
	var graph_script := load("res://tests/fixtures/animation_scripted_graph.gd")
	var graph: AnimationNodeBlendTree = graph_script.new()
	graph.add_node("Clip", AnimationNodeAnimation.new())
	_tree.tree_root = graph
	graph_script.setter_calls = 0
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_call("tree_node_set", {"properties": {"custom_value": 2.0}}), "WRONG_TYPE")
	assert_is_error(_call("tree_node_set", {"graph_path": "Clip", "properties": {"animation": "run"}}), "WRONG_TYPE")
	assert_eq(graph_script.setter_calls, 0)
	assert_eq(String(graph.get_node("Clip").animation), "")
	assert_eq(history.get_version(), version)
	var machine := AnimationNodeStateMachine.new()
	machine.add_node("Idle", AnimationNodeAnimation.new())
	var transition_script := load("res://tests/fixtures/animation_scripted_transition.gd")
	var transition: AnimationNodeStateMachineTransition = transition_script.new()
	machine.add_transition("Start", "Idle", transition)
	_tree.tree_root = machine
	transition_script.setter_calls = 0
	assert_is_error(_call("tree_transition_set", {"from_state": "Start", "to_state": "Idle", "properties": {"custom_value": 2.0}}), "WRONG_TYPE")
	assert_eq(transition_script.setter_calls, 0)
	assert_eq(transition.custom_value, 1.0)
	assert_eq(machine.get_transition(0), transition)
	assert_eq(history.get_version(), version)
