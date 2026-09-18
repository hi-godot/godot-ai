@tool
extends SpringArm3D

## Runtime helper attached by camera_follow_3d. Two jobs:
##
## - Damping. SpringArm3D alone is rigid: it inherits its parent's transform, so
##   the arm follows the target exactly (and handles collision pushback).
##   Damping is what Camera3D has no native property for — the handler sets
##   top_level = true and attaches this script, which interpolates the rig's
##   global transform toward the target every frame. Position is smoothed with a
##   frame-rate independent exponential; rotation follows the target rigidly
##   plus a fixed pitch, matching Camera2D's position-smoothing-only model.
## - Target exclusion. add_excluded_object() takes a runtime RID that does not
##   survive scene serialization, so a reloaded or instantiated scene would let
##   the arm collide with the target's own body. The helper reapplies the
##   exclusion from the persisted metadata on _ready and on every processed
##   step, so a clear_excluded_objects() call or a target that re-entered the
##   tree self-heals.
##
## Config lives in node metadata so the handler can set it inside the same undo
## action that creates the rig:
##   _camera_follow_target          NodePath from the rig to the follow target
##   _camera_follow_offset          Vector3 pivot offset in the target's local space
##   _camera_follow_speed           float smoothing speed (higher = snappier)
##   _camera_follow_pitch           float pitch in radians applied to the target basis
##   _camera_follow_exclude_target  bool: keep the target's own body out of the cast

const META_TARGET := "_camera_follow_target"
const META_OFFSET := "_camera_follow_offset"
const META_SPEED := "_camera_follow_speed"
const META_PITCH := "_camera_follow_pitch"
const META_EXCLUDE := "_camera_follow_exclude_target"


## The rig transform a rigid follow would have: target transform with the pivot
## offset and pitch applied in the target's local space. Shared with the handler
## so the damped rig starts exactly where the rigid rig would sit.
static func desired_transform(target: Node3D, offset: Vector3, pitch: float) -> Transform3D:
	var local := Transform3D(Basis.from_euler(Vector3(pitch, 0.0, 0.0)), offset)
	return target.global_transform * local


func _ready() -> void:
	## Process when damping needs per-frame steps, and also for an
	## exclusion-only rig: the exclusion is a runtime RID that must be kept in
	## place (see _ensure_target_excluded).
	set_process(
		float(get_meta(META_SPEED, 0.0)) > 0.0 or bool(get_meta(META_EXCLUDE, false))
	)
	_ensure_target_excluded(_resolve_target())


## One follow step. Public so tests can drive it with a fixed delta instead of
## waiting on frames.
func apply_step(delta: float) -> void:
	var target := _resolve_target()
	_ensure_target_excluded(target)
	if target == null:
		return
	var speed := float(get_meta(META_SPEED, 0.0))
	if speed <= 0.0:
		return
	var offset: Vector3 = get_meta(META_OFFSET, Vector3.ZERO)
	var pitch := float(get_meta(META_PITCH, 0.0))

	var desired := desired_transform(target, offset, pitch)
	var weight := 1.0 - exp(-speed * maxf(delta, 0.0))
	global_transform = Transform3D(desired.basis, global_position.lerp(desired.origin, weight))


## Keep the target's body RID in the excluded set when the exclusion was
## requested. The set is HashSet-backed, so re-adding is idempotent; re-adding
## unconditionally means no cached RID can go stale after
## clear_excluded_objects() or a target re-entering the tree.
func _ensure_target_excluded(target: Node3D) -> void:
	if not bool(get_meta(META_EXCLUDE, false)):
		return
	var body := target as CollisionObject3D
	if body == null:
		return
	var rid := body.get_rid()
	if rid.is_valid():
		add_excluded_object(rid)


func _resolve_target() -> Node3D:
	if not has_meta(META_TARGET):
		return null
	var path: NodePath = get_meta(META_TARGET)
	var target := get_node_or_null(path)
	return target as Node3D
