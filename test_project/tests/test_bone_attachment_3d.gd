@tool
extends McpTestSuite

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const PropScene := preload("res://tests/fixtures/instance_editing.tscn")
const InheritedScene := preload("res://tests/fixtures/bone_attachment_inherited.tscn")
const HAND := "Hand"

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager
var _history: UndoRedo
var _initial_action: int
var _root: Node
var _fixture: Node3D
var _prop_parent: Node3D
var _prop: Node3D
var _skeleton: Skeleton3D
var _character: Node3D
var _character_path: String


func suite_name() -> String:
	return "bone_attachment_3d"


func suite_setup(ctx: Dictionary) -> void:
	_root = EditorInterface.get_edited_scene_root()
	if _root == null:
		skip_suite("no scene open")
		return
	_undo_redo = ctx.undo_redo
	_handler = NodeHandler.new(_undo_redo)
	_history = _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))


func setup() -> void:
	_initial_action = _history.get_current_action()
	_fixture = Node3D.new()
	_fixture.name = "_McpTestBoneAttachment3D"
	_root.add_child(_fixture)
	_fixture.owner = _root
	_fixture.position = Vector3(1.0, 2.0, -3.0)
	_fixture.rotation_degrees.y = 27.0
	_skeleton = _new_skeleton()
	_fixture.add_child(_skeleton)
	_skeleton.owner = _root
	_prop_parent = Node3D.new()
	_prop_parent.name = "PropStand"
	_fixture.add_child(_prop_parent)
	_prop_parent.owner = _root
	_prop_parent.rotation_degrees.z = 40.0
	_prop_parent.add_child(Node3D.new())
	_prop = PropScene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_prop.name = "Sword"
	_prop_parent.add_child(_prop)
	_prop.owner = _root
	_prop.position = Vector3(4.0, -2.0, 1.0)
	_prop.rotation_degrees = Vector3(15.0, 25.0, 35.0)
	_prop.scale = Vector3(0.75, 1.25, 1.5)
	_prop_parent.add_child(Node3D.new())


func teardown() -> void:
	while _history.get_current_action() > _initial_action:
		if not _history.undo():
			break
	if _root.is_editable_instance(_prop):
		_root.set_editable_instance(_prop, false)
	if is_instance_valid(_character):
		_root.set_editable_instance(_character, false)
		_character = null
	_fixture.free()
	if not _character_path.is_empty():
		DirAccess.remove_absolute(_character_path)
		_character_path = ""


func test_snap_and_one_undo_redo_preserve_linked_prop_ownership() -> void:
	var model_child := _prop.get_node("Mesh")
	var nested_instance := _prop.get_node("Nested")
	var nested_child := nested_instance.get_node("Tip")
	var local_extra := Node3D.new()
	local_extra.name = "LocalExtra"
	_prop.add_child(local_extra)
	local_extra.owner = _root
	var unowned_extra := Node3D.new()
	local_extra.add_child(unowned_extra)
	var owners := {
		_prop: _root,
		model_child: _prop,
		nested_instance: _prop,
		nested_child: nested_instance,
		local_extra: _root,
		unowned_extra: null,
	}
	_assert_owners(owners)
	var old_siblings := _prop_parent.get_children()
	var old_name := _prop.name
	var old_transform := _prop.transform
	var local_scale := _prop.scale
	var old_pose := _skeleton.get_bone_pose(_skeleton.find_bone(HAND))
	var snapped := Transform3D(Basis.from_scale(local_scale), Vector3.ZERO)
	var result := _attach({"scene_file": _root.scene_file_path})
	var attachment := _assert_attachment(result, _skeleton, _skeleton)
	if attachment == null:
		return
	assert_false(attachment.use_external_skeleton)
	assert_eq(_history.get_current_action(), _initial_action + 1)
	assert_eq(_prop.name, old_name)
	assert_true(_prop.transform.is_equal_approx(snapped))
	assert_eq(_skeleton.get_bone_pose(_skeleton.find_bone(HAND)), old_pose)
	_assert_owners(owners)

	assert_true(_history.undo(), "one undo should restore the prop")
	assert_eq(_history.get_current_action(), _initial_action)
	assert_eq(attachment.get_parent(), null)
	assert_eq(_prop.get_parent(), _prop_parent)
	assert_eq(_prop_parent.get_children(), old_siblings)
	assert_eq(_prop.name, old_name)
	assert_eq(_prop.transform, old_transform)
	_assert_owners(owners)

	assert_true(_history.redo(), "one redo should restore the attachment")
	assert_eq(_history.get_current_action(), _initial_action + 1)
	assert_eq(attachment.get_parent(), _skeleton)
	assert_eq(_prop.get_parent(), attachment)
	assert_eq(_path(_prop), result.data.path)
	assert_true(_prop.transform.is_equal_approx(snapped))
	_assert_owners(owners)


func test_repeat_is_noop_and_new_grip_changes_only_prop_transform() -> void:
	var position := Vector3(0.25, -0.5, 0.75)
	var degrees := Vector3(23.0, -34.0, 45.0)
	var local_scale := _prop.scale
	var grip := {
		"position": [position.x, position.y, position.z],
		"rotation_degrees": {"x": degrees.x, "y": degrees.y, "z": degrees.z},
	}
	var first := _attach({"grip_offset": grip})
	var attachment := _assert_attachment(first, _skeleton, _skeleton)
	if attachment == null:
		return
	var initial_grip := Transform3D(Basis.from_euler(degrees * PI / 180.0) * Basis.from_scale(local_scale), position)
	assert_true(_prop.transform.is_equal_approx(initial_grip))
	var attached_path: String = first.data.path
	var attachment_transform := attachment.transform
	var skeleton_children := _skeleton.get_children()
	var version := _history.get_version()
	_assert_same_grip_is_noop(attached_path, first.data.attachment_path, grip)
	assert_eq(_history.get_version(), version)

	var change := _attach({"path": attached_path, "grip_offset": {"position": [1.0, 2.0, 3.0]}})
	assert_eq(_assert_attachment(change, _skeleton, _skeleton), attachment)
	assert_eq(_history.get_current_action(), _initial_action + 2)
	assert_eq(_skeleton.get_children(), skeleton_children)
	assert_eq(attachment.transform, attachment_transform)
	var new_grip := Transform3D(Basis.from_scale(local_scale), Vector3(1.0, 2.0, 3.0))
	assert_true(_prop.transform.is_equal_approx(new_grip))
	assert_true(_history.undo(), "undo should restore only the old grip")
	assert_eq(_prop.get_parent(), attachment)
	assert_true(_prop.transform.is_equal_approx(initial_grip))
	version = _history.get_version()
	_assert_same_grip_is_noop(attached_path, first.data.attachment_path, grip)
	assert_eq(_history.get_version(), version)
	assert_true(_history.redo(), "a repeated grip must preserve the redo action")
	assert_eq(_prop.get_parent(), attachment)
	assert_true(_prop.transform.is_equal_approx(new_grip))


func test_locked_character_external_attachment_follows_two_animation_poses() -> void:
	var skeleton := _add_linked_character()
	if skeleton == null:
		return
	assert_false(_root.is_editable_instance(_character))
	# A locally added rig under a locked source-owned child disappears on save,
	# even when its skeleton has a valid owner inside that rig.
	var local_rig := (load(_character_path) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_character.get_node("Rig").add_child(local_rig)
	local_rig.owner = _root
	var transient_target := local_rig.get_node("Rig/Skeleton")
	var version := _history.get_version()
	assert_is_error(_attach({"skeleton_path": _path(transient_target)}), ErrorCodes.NODE_NOT_FOUND)
	assert_eq(_history.get_version(), version)
	assert_eq(_prop.get_parent(), _prop_parent)
	var skeleton_children := skeleton.get_children()
	var grip := Vector3(0.5, 0.0, -0.25)
	var result := _attach({"skeleton_path": _path(skeleton), "grip_offset": {"position": [grip.x, grip.y, grip.z]}})
	var attachment := _assert_attachment(result, skeleton, _character)
	if attachment == null:
		return
	assert_true(attachment.use_external_skeleton)
	assert_false(attachment.external_skeleton.is_absolute())
	assert_eq(attachment.get_node_or_null(attachment.external_skeleton), skeleton)
	assert_eq(skeleton.get_children(), skeleton_children)
	assert_false(_root.is_editable_instance(_character))
	assert_eq(_history.get_current_action(), _initial_action + 1)

	var player: AnimationPlayer = _character.get_node("AnimationPlayer")
	var hand := skeleton.find_bone(HAND)
	player.play("Swing")
	player.advance(0.0)
	skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	var first_world := _prop.global_transform
	assert_true(skeleton.get_bone_pose_position(hand).is_equal_approx(Vector3(0.0, 1.0, 0.0)))
	_assert_at_bone(skeleton, hand, attachment, grip)
	player.advance(0.5)
	skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	assert_true(skeleton.get_bone_pose_position(hand).is_equal_approx(Vector3(1.5, 2.0, -1.0)))
	assert_false(_prop.global_transform.is_equal_approx(first_world), "the prop must move with the animated hand")
	_assert_at_bone(skeleton, hand, attachment, grip)
	assert_true(_history.undo(), "external follower and reparent must undo together")
	assert_eq(attachment.get_parent(), null)
	assert_eq(_prop.get_parent(), _prop_parent)
	assert_true(_history.redo(), "external follower must rebind on redo")
	player.advance(0.25)
	skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	_assert_at_bone(skeleton, hand, attachment, grip)
	assert_false(_root.is_editable_instance(_character))


func test_editable_character_uses_direct_attachment_and_keeps_editable_state() -> void:
	var skeleton := _add_linked_character()
	if skeleton == null:
		return
	_root.set_editable_instance(_character, true)
	var result := _attach({"skeleton_path": _path(skeleton)})
	var attachment := _assert_attachment(result, skeleton, skeleton)
	if attachment == null:
		return
	assert_false(attachment.use_external_skeleton)
	assert_true(_root.is_editable_instance(_character))
	assert_true(_history.undo())
	assert_eq(_prop.get_parent(), _prop_parent)
	assert_true(_root.is_editable_instance(_character))
	assert_true(_history.redo())
	assert_eq(attachment.get_parent(), skeleton)
	assert_true(_root.is_editable_instance(_character))


func test_inheritance_guard_refuses_base_props_and_allows_local_additions() -> void:
	var inherited_root: Node = track(InheritedScene.instantiate(PackedScene.GEN_EDIT_STATE_MAIN))
	var inherited_prop: Node3D = inherited_root.get_node("Mesh")
	var inherited_instance: Node3D = inherited_root.get_node("Nested")
	var local_prop: Node3D = inherited_prop.get_node("LocalProp")
	var version := _history.get_version()
	var unsaved := EditorInterface.get_unsaved_scenes()
	var inherited_children := inherited_root.get_children()
	var original_transform := inherited_prop.transform
	assert_eq(inherited_root.scene_file_path, InheritedScene.resource_path)
	# Inherited and scene-local props all report the same owner in the editor.
	# An untitled inherited scene still has its live base state.
	for scene_path: String in [InheritedScene.resource_path, ""]:
		inherited_root.scene_file_path = scene_path
		for prop: Node3D in [inherited_prop, inherited_instance]:
			assert_eq(prop.owner, inherited_root)
			assert_is_error(_handler._bone_attachment_inherited_error(prop, inherited_root), ErrorCodes.INVALID_PARAMS)
		assert_eq(local_prop.owner, inherited_root)
		assert_eq(_handler._bone_attachment_inherited_error(local_prop, inherited_root), {})
	assert_eq(inherited_root.get_children(), inherited_children)
	assert_eq(inherited_prop.transform, original_transform)
	assert_eq(local_prop.get_parent(), inherited_prop)
	assert_eq(_history.get_version(), version)
	assert_eq(EditorInterface.get_unsaved_scenes(), unsaved)


func test_invalid_offset_bone_and_topology_leave_scene_and_history_unchanged() -> void:
	var wrong_type := Node2D.new()
	wrong_type.name = "FlatProp"
	_fixture.add_child(wrong_type)
	wrong_type.owner = _root
	var descendant := _new_skeleton()
	_prop.add_child(descendant)
	descendant.owner = _root
	var unowned_parent := Node3D.new()
	unowned_parent.name = "UnownedParent"
	_fixture.add_child(unowned_parent)
	var unsavable := _new_skeleton()
	unowned_parent.add_child(unsavable)
	unsavable.owner = _root
	var foreign_skeleton: Skeleton3D = track(_new_skeleton())
	foreign_skeleton.name = "_McpTestForeignSkeleton"
	_root.get_tree().root.add_child(foreign_skeleton)
	_skeleton.add_bone("LongName".repeat(40))
	for i in range(40):
		_skeleton.add_bone("Extra_%02d" % i)
	_root.set_editable_instance(_prop, true)
	var original_transform := _prop.transform
	var old_fixture_children := _fixture.get_children()
	var old_siblings := _prop_parent.get_children()
	var scene_history_version := _history.get_version()
	var global_history := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	var global_history_version := global_history.get_version()
	var unsaved_before := EditorInterface.get_unsaved_scenes()

	var missing_bone := _attach({"bone_name": "Hnad"})
	assert_is_error(missing_bone, ErrorCodes.VALUE_OUT_OF_RANGE)
	if missing_bone.has("error"):
		var details: Dictionary = missing_bone.error.get("data", {})
		var names: Array = details.get("available_bones", [])
		assert_eq(details.get("bone_count"), _skeleton.get_bone_count())
		assert_contains(names, HAND)
		assert_true(names.size() <= 20, "typo diagnostics must bound the names returned")
		for bone: String in names:
			assert_true(bone.length() <= 121, "typo diagnostics must bound each name")
	for grip in [[], null, {"scale": [1, 1, 1]}, {"position": [1, 2]}, {"position": [1, true, 3]},
			{"rotation_degrees": {"x": 0, "y": 0}}, {"rotation_degrees": {"x": 0, "y": 0, "z": NAN}},
			{"position": [INF, 0, 0]}]:
		assert_is_error(_attach({"grip_offset": grip}), "", "invalid grip should fail: %s" % [grip])
	assert_is_error(_attach({"scene_file": "res://other.tscn"}), ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_is_error(_attach({"path": ""}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_attach({"skeleton_path": ""}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_attach({"bone_name": ""}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_attach({"path": _path(_fixture) + "/Missing"}), ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_attach({"skeleton_path": _path(_fixture) + "/Missing"}), ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_attach({"path": _path(wrong_type)}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_attach({"skeleton_path": _path(_prop_parent)}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_attach({"skeleton_path": str(foreign_skeleton.get_path())}), ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_attach({"path": str(foreign_skeleton.get_path())}), ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_attach({"path": _path(_root)}), ErrorCodes.INVALID_PARAMS)
	assert_is_error(_attach({"path": _path(_skeleton)}), ErrorCodes.INVALID_PARAMS)
	assert_is_error(_attach({"skeleton_path": _path(descendant)}), ErrorCodes.INVALID_PARAMS)
	assert_is_error(_attach({"skeleton_path": _path(unsavable)}), ErrorCodes.NODE_NOT_FOUND, "an unowned ancestor prevents persisting a skeleton link")
	assert_is_error(_attach({"path": _path(unowned_parent)}), ErrorCodes.INVALID_PARAMS, "the prop itself must be scene-owned")
	assert_is_error(_attach({"path": _path(_prop.get_node("Mesh"))}), ErrorCodes.INVALID_PARAMS, "Editable Children cannot grant structural edits to instance-owned nodes")
	_prop.top_level = true
	var top_transform := _prop.transform
	assert_is_error(_attach(), ErrorCodes.INVALID_PARAMS)
	assert_true(_prop.top_level)
	assert_eq(_prop.transform, top_transform)
	_prop.top_level = false

	assert_eq(_prop_parent.get_children(), old_siblings)
	assert_eq(_fixture.get_children(), old_fixture_children)
	assert_eq(_prop.owner, _root)
	assert_eq(_prop.get_node("Mesh").owner, _prop)
	assert_true(_root.is_editable_instance(_prop))
	assert_true(_prop.transform.is_equal_approx(original_transform))
	assert_eq(_skeleton.get_child_count(), 0)
	assert_eq(descendant.get_child_count(), 0)
	assert_eq(unsavable.get_child_count(), 0)
	assert_eq(foreign_skeleton.get_child_count(), 0)
	assert_eq(_history.get_version(), scene_history_version)
	assert_eq(global_history.get_version(), global_history_version)
	assert_eq(EditorInterface.get_unsaved_scenes(), unsaved_before)


func _new_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.position = Vector3(1.0, 0.0, -1.0)
	skeleton.rotation_degrees.z = 30.0
	var torso := skeleton.add_bone("Torso")
	var hand := skeleton.add_bone(HAND)
	skeleton.set_bone_parent(hand, torso)
	skeleton.set_bone_rest(torso, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	skeleton.set_bone_rest(hand, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))
	skeleton.reset_bone_poses()
	return skeleton


func _add_linked_character() -> Skeleton3D:
	var source: Node3D = track(Node3D.new())
	source.name = "Character"
	var rig := Node3D.new()
	rig.name = "Rig"
	rig.position = Vector3(0.0, 2.0, 3.0)
	source.add_child(rig)
	rig.owner = source
	var source_skeleton := _new_skeleton()
	rig.add_child(source_skeleton)
	source_skeleton.owner = source
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	source.add_child(player)
	player.owner = source
	var swing := Animation.new()
	var position_track := swing.add_track(Animation.TYPE_POSITION_3D)
	swing.track_set_path(position_track, NodePath("Rig/Skeleton:Hand"))
	swing.position_track_insert_key(position_track, 0.0, Vector3(0.0, 1.0, 0.0))
	swing.position_track_insert_key(position_track, 0.5, Vector3(1.5, 2.0, -1.0))
	var rotation_track := swing.add_track(Animation.TYPE_ROTATION_3D)
	swing.track_set_path(rotation_track, NodePath("Rig/Skeleton:Hand"))
	swing.rotation_track_insert_key(rotation_track, 0.0, Quaternion.IDENTITY)
	swing.rotation_track_insert_key(rotation_track, 0.5, Quaternion(Vector3.UP, PI / 2.0))
	var library := AnimationLibrary.new()
	library.add_animation("Swing", swing)
	player.add_animation_library("", library)
	var packed := PackedScene.new()
	var packed_err := packed.pack(source)
	assert_eq(packed_err, OK)
	if packed_err != OK:
		return null
	_character_path = "user://_mcp_bone_attachment_character_%s.tscn" % source.get_instance_id()
	var save_err := ResourceSaver.save(packed, _character_path)
	assert_eq(save_err, OK)
	if save_err != OK:
		return null
	var linked := ResourceLoader.load(_character_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_ne(linked, null)
	if linked == null:
		return null
	_character = linked.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_character.position = Vector3(-4.0, 1.0, 2.0)
	_character.rotation_degrees.y = -48.0
	_fixture.add_child(_character)
	_character.owner = _root
	return _character.get_node("Rig/Skeleton") as Skeleton3D


func _path(node: Node) -> String:
	return McpScenePath.from_node(node, _root)


func _attach(overrides: Dictionary = {}) -> Dictionary:
	var params := {"path": _path(_prop), "skeleton_path": _path(_skeleton), "bone_name": HAND}
	params.merge(overrides, true)
	return _handler.attach_to_bone_3d(params)


func _assert_attachment(result: Dictionary, skeleton: Skeleton3D, parent: Node) -> BoneAttachment3D:
	assert_has_key(result, "data", "expected attachment success, got %s" % [result])
	if not result.has("data"):
		return null
	var attachment := _prop.get_parent() as BoneAttachment3D
	assert_ne(attachment, null, "the prop should be parented under a native BoneAttachment3D")
	if attachment == null:
		return null
	assert_eq(attachment.get_parent(), parent)
	assert_eq(attachment.owner, _root)
	assert_eq(attachment.get_skeleton(), skeleton)
	assert_eq(attachment.bone_name, HAND)
	assert_false(attachment.override_pose)
	assert_eq(result.data.get("path"), _path(_prop))
	assert_eq(result.data.get("attachment_path"), _path(attachment))
	assert_eq(result.data.get("skeleton_path"), _path(skeleton))
	assert_eq(result.data.get("bone_name"), HAND)
	assert_eq(result.data.get("changed"), true)
	assert_eq(result.data.get("undoable"), true)
	return attachment


func _assert_same_grip_is_noop(path: String, attachment_path: String, grip: Dictionary) -> void:
	var same := _attach({"path": path, "grip_offset": grip})
	assert_has_key(same, "data", "repeating the same grip should succeed: %s" % [same])
	if same.has("data"):
		assert_eq(same.data.get("path"), path)
		assert_eq(same.data.get("attachment_path"), attachment_path)
		assert_eq(same.data.get("changed"), false)
		assert_eq(same.data.get("undoable"), false)


func _assert_at_bone(skeleton: Skeleton3D, bone: int, attachment: BoneAttachment3D, grip: Vector3) -> void:
	var bone_world := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	assert_true(attachment.global_transform.is_equal_approx(bone_world), "attachment must match the current world-space bone pose")
	assert_true(_prop.global_position.is_equal_approx(bone_world * grip), "grip must move and rotate with the bone")


func _assert_owners(owners: Dictionary) -> void:
	for node: Node in owners:
		assert_eq(node.owner, owners[node], "owner of %s" % node.name)
