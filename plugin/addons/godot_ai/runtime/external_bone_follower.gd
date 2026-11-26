@tool
extends BoneAttachment3D

## The attachment tool embeds this script in the scene for locked rigs.
## BoneAttachment3D already updates on pose changes. Refresh it here when
## the external rig or the attachment's transform parent moves separately.

var _skeleton_id := 0
var _skeleton_transform := Transform3D.IDENTITY
var _parent_transform := Transform3D.IDENTITY


func _enter_tree() -> void:
	_skeleton_id = 0


func _process(_delta: float) -> void:
	if not use_external_skeleton or override_pose:
		_skeleton_id = 0
		return
	var skeleton := get_skeleton()
	if skeleton == null or not skeleton.is_inside_tree():
		_skeleton_id = 0
		return
	var parent := get_parent_node_3d()
	var parent_transform := parent.global_transform if parent != null else Transform3D.IDENTITY
	var skeleton_transform := skeleton.global_transform
	var skeleton_id := skeleton.get_instance_id()
	if skeleton_id == _skeleton_id and skeleton_transform == _skeleton_transform and parent_transform == _parent_transform:
		return
	if bone_idx < 0 or bone_idx >= skeleton.get_bone_count():
		return
	_skeleton_id = skeleton_id
	_skeleton_transform = skeleton_transform
	_parent_transform = parent_transform
	on_skeleton_update()
