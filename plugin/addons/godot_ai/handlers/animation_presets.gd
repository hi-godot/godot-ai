@tool
extends RefCounted

## Curated motion presets for the AnimationPlayer surface.
##
## Each preset_* method:
##   1. Validates params + resolves the player (auto-creating its default lib).
##   2. Resolves the target node + classifies it as control / 2d / 3d.
##   3. Builds a single-track Animation with shape-appropriate keyframes.
##   4. Commits the add through the handler's shared `_commit_animation_add`
##      so a single Ctrl-Z rolls back any auto-created library + the animation.
##
## Holds a WeakRef back to the AnimationHandler instance so the handler can
## continue to own this module strongly via `_presets` without forming a
## RefCounted cycle. Resolution / undo helpers live on the handler — keeping
## the `_undo_redo` member single-source there avoids drift.


const AnimationValues := preload("res://addons/godot_ai/handlers/animation_values.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScenePath := preload("res://addons/godot_ai/utils/scene_path.gd")


var _handler_weak: WeakRef


func _init(handler) -> void:
	_handler_weak = weakref(handler)


func _h():
	return _handler_weak.get_ref()


# ============================================================================
# animation_preset_fade
# ============================================================================

func preset_fade(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var mode: String = params.get("mode", "in")
	var duration: float = float(params.get("duration", 0.5))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if mode != "in" and mode != "out":
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid mode '%s'. Valid: 'in', 'out'" % mode)
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var target_resolved := _resolve_preset_target(player, target_path)
	if target_resolved.has("error"):
		return target_resolved
	var target: Node = target_resolved.node
	var track_target: String = target_resolved.track_path_root

	# Fade requires a `modulate` property (CanvasItem/Control/Node2D/Sprite3D/etc).
	var has_modulate := false
	for p in target.get_property_list():
		if p.name == "modulate":
			has_modulate = true
			break
	if not has_modulate:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Target '%s' (class %s) has no 'modulate' property — fade requires a CanvasItem, Control, Node2D, or Sprite3D"
			% [target_path, target.get_class()])

	if anim_name.is_empty():
		anim_name = "fade_%s" % mode

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var start_a: float = 0.0 if mode == "in" else 1.0
	var end_a: float = 1.0 if mode == "in" else 0.0

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:modulate:a" % track_target
	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": start_a, "transition": "linear"},
		{"time": duration, "value": end_a, "transition": "linear"},
	])

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"mode": mode,
			"length": duration,
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_preset_slide
# ============================================================================

func preset_slide(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var direction: String = params.get("direction", "left")
	var mode: String = params.get("mode", "in")
	var duration: float = float(params.get("duration", 0.4))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if not ["left", "right", "up", "down"].has(direction):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid direction '%s'. Valid: 'left', 'right', 'up', 'down'" % direction)
	if mode != "in" and mode != "out":
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid mode '%s'. Valid: 'in', 'out'" % mode)
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var target_resolved := _resolve_preset_target(player, target_path)
	if target_resolved.has("error"):
		return target_resolved
	var target = target_resolved.node
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	# Default distance picks 3D units vs screen pixels based on target kind.
	var default_distance: float = 1.0 if kind == "3d" else 100.0
	var distance: float = float(params.get("distance", default_distance))
	if distance == 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'distance' must be non-zero")

	var offset: Variant = _direction_offset(kind, direction, distance)
	var current_pos: Variant = target.position
	var start_pos: Variant
	var end_pos: Variant
	if mode == "in":
		start_pos = current_pos + offset
		end_pos = current_pos
	else:
		start_pos = current_pos
		end_pos = current_pos + offset

	if anim_name.is_empty():
		anim_name = "slide_%s_%s" % [mode, direction]

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:position" % track_target
	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": start_pos, "transition": "linear"},
		{"time": duration, "value": end_pos, "transition": "linear"},
	])

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"direction": direction,
			"mode": mode,
			"distance": distance,
			"length": duration,
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_preset_shake
# ============================================================================

func preset_shake(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var duration: float = float(params.get("duration", 0.3))
	var frequency: float = float(params.get("frequency", 30.0))
	var rng_seed: int = int(params.get("seed", 0))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	if frequency <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'frequency' must be > 0")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var target_resolved := _resolve_preset_target(player, target_path)
	if target_resolved.has("error"):
		return target_resolved
	var target = target_resolved.node
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	var default_intensity: float = 0.1 if kind == "3d" else 10.0
	var intensity: float = float(params.get("intensity", default_intensity))
	if intensity <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'intensity' must be > 0")

	if anim_name.is_empty():
		anim_name = "shake"

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var rng := RandomNumberGenerator.new()
	if rng_seed != 0:
		rng.seed = rng_seed
	else:
		rng.randomize()

	# Samples between t=0 and t=duration (exclusive); bookended by at-rest keys.
	var sample_count: int = int(ceil(frequency * duration))
	if sample_count < 2:
		sample_count = 2

	var current_pos: Variant = target.position
	var kfs: Array = []
	kfs.append({"time": 0.0, "value": current_pos, "transition": "linear"})
	for i in range(1, sample_count):
		var t: float = (float(i) / float(sample_count)) * duration
		var jx: float = rng.randf_range(-intensity, intensity)
		var jy: float = rng.randf_range(-intensity, intensity)
		var jittered: Variant
		if kind == "3d":
			var jz: float = rng.randf_range(-intensity, intensity)
			jittered = current_pos + Vector3(jx, jy, jz)
		else:
			jittered = current_pos + Vector2(jx, jy)
		kfs.append({"time": t, "value": jittered, "transition": "linear"})
	kfs.append({"time": duration, "value": current_pos, "transition": "linear"})

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:position" % track_target
	handler._do_add_property_track(anim, track_path, "linear", kfs)

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"length": duration,
			"frequency": frequency,
			"intensity": intensity,
			"keyframe_count": kfs.size(),
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_preset_pulse
# ============================================================================

func preset_pulse(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var from_scale: float = float(params.get("from_scale", 1.0))
	var to_scale: float = float(params.get("to_scale", 1.1))
	var duration: float = float(params.get("duration", 0.4))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	if from_scale <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'from_scale' must be > 0")
	if to_scale <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'to_scale' must be > 0")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var target_resolved := _resolve_preset_target(player, target_path)
	if target_resolved.has("error"):
		return target_resolved
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	if anim_name.is_empty():
		anim_name = "pulse"

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var from_vec: Variant
	var to_vec: Variant
	if kind == "3d":
		from_vec = Vector3(from_scale, from_scale, from_scale)
		to_vec = Vector3(to_scale, to_scale, to_scale)
	else:
		from_vec = Vector2(from_scale, from_scale)
		to_vec = Vector2(to_scale, to_scale)

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:scale" % track_target
	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": from_vec, "transition": "linear"},
		{"time": duration * 0.5, "value": to_vec, "transition": "linear"},
		{"time": duration, "value": from_vec, "transition": "linear"},
	])

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"from_scale": from_scale,
			"to_scale": to_scale,
			"length": duration,
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# Helpers — preset resolution
# ============================================================================

## Resolve a preset target node and classify its transform kind.
##
## Accepts two `target_path` shapes:
##   * Scene-absolute (starts with "/") — resolved through `ScenePath.resolve`,
##     matching the convention used by every other scene-mutating tool. Targets
##     outside the player's `root_node` subtree are converted to `..`-prefixed
##     paths via `root_node.get_path_to(target)`, mirroring what the relative
##     form accepts and how Godot stores track paths.
##   * Relative — used as-is against the player's `root_node`, matching how
##     animation tracks themselves are stored.
##
## Returns `{node, kind, track_path_root}` where `track_path_root` is the path
## (relative to `root_node`) that callers should embed in the track path. For
## scene-absolute inputs this is the converted relative path; for relative
## inputs it equals the input. `kind` ∈ {"control", "2d", "3d"}.
##
## Mirrors the same root-node fallback that
## `AnimationValues.resolve_track_prop_context` uses so tool inputs match how
## the track path will resolve at playback.
func _resolve_preset_target(player: AnimationPlayer, target_path: String) -> Dictionary:
	var root_node := AnimationValues.player_root_node(player)
	if root_node == null:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"AnimationPlayer at %s has no resolvable root_node (is the scene open?)" % str(player.get_path()))

	var target: Node = null
	var track_path_root: String = target_path
	if target_path.begins_with("/"):
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Cannot resolve scene-absolute target_path '%s': no scene open" % target_path)
		target = ScenePath.resolve(target_path, scene_root)
		if target == null:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				ScenePath.format_node_error(target_path, scene_root))
		# Convert to a root_node-relative path. For targets outside the
		# subtree this yields a `..`-prefixed path, matching what the
		# relative form already accepts (root_node.get_node_or_null
		# resolves `..` segments) and what Godot's animation engine
		# stores natively.
		track_path_root = str(root_node.get_path_to(target))
	else:
		target = root_node.get_node_or_null(target_path)
		if target == null:
			# root_node.get_path() leaks the editor's SubViewport-wrapped
			# path; use the clean scene-relative form so the hint is
			# actionable.
			var scene_root := EditorInterface.get_edited_scene_root()
			var root_hint := ScenePath.from_node(root_node, scene_root) if scene_root != null else str(root_node.name)
			var abs_example := "/%s/path/to/target" % scene_root.name if scene_root != null else "/SceneRoot/path/to/target"
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				("Target node not found at '%s' (resolved relative to AnimationPlayer's root_node '%s'). "
				+ "Pass a path relative to root_node (e.g. \"path/to/target\") or a scene-absolute path (e.g. \"%s\").")
				% [target_path, root_hint, abs_example])

	var kind: String
	if target is Control:
		kind = "control"
	elif target is Node2D:
		kind = "2d"
	elif target is Node3D:
		kind = "3d"
	else:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Target '%s' must be a Control, Node2D, or Node3D (got %s)" % [target_path, target.get_class()])
	return {"node": target, "kind": kind, "track_path_root": track_path_root}


## Build a directional offset for slide presets.
## Axis conventions:
##   Control + Node2D (screen-space, y-down): left/right = ∓x, up = -y, down = +y
##   Node3D (world-up): left/right = ∓x, up = +y, down = -y
static func _direction_offset(kind: String, direction: String, distance: float) -> Variant:
	if kind == "3d":
		match direction:
			"left": return Vector3(-distance, 0.0, 0.0)
			"right": return Vector3(distance, 0.0, 0.0)
			"up": return Vector3(0.0, distance, 0.0)
			"down": return Vector3(0.0, -distance, 0.0)
	else:
		match direction:
			"left": return Vector2(-distance, 0.0)
			"right": return Vector2(distance, 0.0)
			"up": return Vector2(0.0, -distance)
			"down": return Vector2(0.0, distance)
	return null
