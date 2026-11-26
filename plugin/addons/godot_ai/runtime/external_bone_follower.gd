@tool
extends BoneAttachment3D

## The attachment tool embeds this script in the scene for locked rigs.
## BoneAttachment3D already updates on pose changes. Refresh it here when
## the external rig or the attachment's transform parent moves separately.

var _skeleton: Skeleton3D
var _sampled_bone := -1
var _bone_pose := Transform3D.IDENTITY
var _skeleton_transform := Transform3D.IDENTITY
var _parent_transform := Transform3D.IDENTITY
var _expected_transform := Transform3D.IDENTITY


func _enter_tree() -> void:
	_start_following()


func _exit_tree() -> void:
	_stop_following()


func _start_following(adopt_native_pose: bool = false) -> void:
	property_list_changed.connect(_sync_skeleton)
	_sync_skeleton()
	if adopt_native_pose and _can_follow():
		_adopt_native_pose()


func _stop_following() -> void:
	property_list_changed.disconnect(_sync_skeleton)
	_disconnect_skeleton()


func _sync_skeleton() -> void:
	var skeleton := get_skeleton() if use_external_skeleton and not override_pose else null
	if _skeleton == skeleton:
		return
	_disconnect_skeleton()
	_skeleton = skeleton
	if _skeleton != null:
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _disconnect_skeleton() -> void:
	if is_instance_valid(_skeleton):
		_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
	_skeleton = null
	_sampled_bone = -1


func _adopt_native_pose() -> void:
	# An in-tree attachment can already display an evaluated pose before we
	# connect. Keep that pose on upgrade when an active modifier can supply it.
	for child in _skeleton.get_children(true):
		if child is SkeletonModifier3D and child.active:
			var skeleton_transform := _skeleton.global_transform
			if skeleton_transform.basis.determinant() != 0.0:
				_sampled_bone = bone_idx
				_bone_pose = skeleton_transform.affine_inverse() * global_transform
				_skeleton_transform = skeleton_transform
				_parent_transform = _get_parent_transform()
				_expected_transform = transform
			return


func _on_skeleton_updated() -> void:
	if not _can_follow():
		return
	# Godot restores the unmodified bone pose after this signal. Keep the
	# same evaluated pose the native attachment and the skin receive.
	_sample_pose()
	_update_expected_transform(_skeleton.global_transform, _get_parent_transform())


func _process(_delta: float) -> void:
	_sync_skeleton()
	if not _can_follow():
		return
	var skeleton_transform := _skeleton.global_transform
	var parent_transform := _get_parent_transform()
	if _sampled_bone != bone_idx:
		# Seed the follower before the first pose update for this bone.
		_sample_pose()
		_update_expected_transform(skeleton_transform, parent_transform)
	elif skeleton_transform != _skeleton_transform or parent_transform != _parent_transform:
		_update_expected_transform(skeleton_transform, parent_transform)
	if transform != _expected_transform:
		transform = _expected_transform


func _can_follow() -> bool:
	return is_instance_valid(_skeleton) and _skeleton.is_inside_tree() and bone_idx >= 0 and bone_idx < _skeleton.get_bone_count()


func _sample_pose() -> void:
	_sampled_bone = bone_idx
	_bone_pose = _skeleton.get_bone_global_pose(bone_idx)


func _get_parent_transform() -> Transform3D:
	var parent := get_parent_node_3d()
	return parent.global_transform if parent != null else Transform3D.IDENTITY


func _update_expected_transform(skeleton_transform: Transform3D, parent_transform: Transform3D) -> void:
	_skeleton_transform = skeleton_transform
	_parent_transform = parent_transform
	_expected_transform = parent_transform.affine_inverse() * (skeleton_transform * _bone_pose)
