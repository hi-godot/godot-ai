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

## Loop modes the continuous presets (pulse/orbit/sweep/drift) accept.
const _LOOP_MODES := {
	"none": Animation.LOOP_NONE,
	"linear": Animation.LOOP_LINEAR,
	"pingpong": Animation.LOOP_PINGPONG,
}

## Angular segments per orbit turn. Linear interpolation between keys is
## straight, so this is the circle approximation density.
const _ORBIT_SEGMENTS := 16


var _handler_weak: WeakRef


func _init(handler) -> void:
	_handler_weak = weakref(handler)


func _h():
	return _handler_weak.get_ref()


## Resolve the existing animation a preset would replace. Returns
## `{old_anim: Animation|null}` when the name is free or `overwrite` is set,
## or `{error: <error dict>}` when the name is taken and overwrite is off.
## One site for the duplicate-detection error keeps every preset consistent.
static func _existing_animation(library: AnimationLibrary, anim_name: String, overwrite: bool) -> Dictionary:
	if not library.has_animation(anim_name):
		return {"old_anim": null}
	if not overwrite:
		return {"error": ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)}
	return {"old_anim": library.get_animation(anim_name)}


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
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

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
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

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
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

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
	var property: String = params.get("property", "scale")
	var from_scale: float = float(params.get("from_scale", 1.0))
	var to_scale: float = float(params.get("to_scale", 1.1))
	var duration: float = float(params.get("duration", 0.4))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if property.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: property")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	var loop_result := _resolve_loop_mode(params)
	if loop_result.has("error"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, loop_result.error)
	var loop_mode: int = loop_result.ok

	var handler = _h()
	if handler == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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
	var track_path := "%s:%s" % [track_target, property]

	## Two shapes: the original scale shortcut (from_scale/to_scale floats) and
	## the general form (property + from_value/to_value coerced against the
	## property's real type, so modulate:a breathes as floats and position
	## jitters as vectors).
	var from_vec: Variant
	var to_vec: Variant
	var used_scale_shortcut := false
	if property == "scale" and not params.has("from_value") and not params.has("to_value"):
		used_scale_shortcut = true
		if from_scale <= 0.0:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'from_scale' must be > 0")
		if to_scale <= 0.0:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'to_scale' must be > 0")
		if kind == "3d":
			from_vec = Vector3(from_scale, from_scale, from_scale)
			to_vec = Vector3(to_scale, to_scale, to_scale)
		else:
			from_vec = Vector2(from_scale, from_scale)
			to_vec = Vector2(to_scale, to_scale)
	else:
		if not (params.has("from_value") and params.has("to_value")):
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
				"'from_value' and 'to_value' are required when 'property' is not 'scale' (got '%s')" % property)
		var from_result := AnimationValues.coerce_value_for_track(params.get("from_value"), track_path, player)
		if from_result.has("error"):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, from_result.error)
		from_vec = from_result.ok
		var to_result := AnimationValues.coerce_value_for_track(params.get("to_value"), track_path, player)
		if to_result.has("error"):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, to_result.error)
		to_vec = to_result.ok

	if anim_name.is_empty():
		anim_name = "pulse"

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = loop_mode

	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": from_vec, "transition": "linear"},
		{"time": duration * 0.5, "value": to_vec, "transition": "linear"},
		{"time": duration, "value": from_vec, "transition": "linear"},
	])

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	var data := {
		"player_path": player_path,
		"animation_name": anim_name,
		"property": property,
		"length": duration,
		"loop_mode": AnimationValues.loop_mode_to_string(loop_mode),
		"track_count": anim.get_track_count(),
		"library_created": created_library,
		"overwritten": old_anim != null,
		"undoable": true,
	}
	if used_scale_shortcut:
		data["from_scale"] = from_scale
		data["to_scale"] = to_scale
	else:
		data["from_value"] = AnimationValues.serialize_value(from_vec)
		data["to_value"] = AnimationValues.serialize_value(to_vec)
	return {"data": data}


# ============================================================================
# animation_preset_bounce
# ============================================================================

## Center-pivot scale overshoot with a settle-back — UI press feedback.
## Controls get `pivot_offset` recentered in the same undo action so the pop
## originates from the middle of the widget, not its top-left corner.
func preset_bounce(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var intensity: float = float(params.get("intensity", 0.15))
	var duration: float = float(params.get("duration", 0.4))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	if intensity <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'intensity' must be > 0")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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
	## Untyped: `scale` lives on Control/Node2D/Node3D, not on the Node base.
	var target = target_resolved.node
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	if anim_name.is_empty():
		anim_name = "bounce"

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

	var peak := 1.0 + intensity
	var dip := 1.0 - intensity * 0.25
	## Pop from the target's current scale, not identity: a widget that is
	## already scaled must not snap to 1.0 when the animation starts.
	var at_rest: Variant = target.scale
	var at_peak: Variant
	var at_dip: Variant
	if kind == "3d":
		at_peak = at_rest * Vector3(peak, peak, peak)
		at_dip = at_rest * Vector3(dip, dip, dip)
	else:
		at_peak = at_rest * Vector2(peak, peak)
		at_dip = at_rest * Vector2(dip, dip)

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:scale" % track_target
	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": at_rest, "transition": "linear"},
		{"time": duration * 0.35, "value": at_peak, "transition": "ease_out"},
		{"time": duration * 0.65, "value": at_dip, "transition": "ease_in_out"},
		{"time": duration, "value": at_rest, "transition": "linear"},
	])

	var extra_props := _control_pivot_props(target)
	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
		false, null, extra_props,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"intensity": intensity,
			"length": duration,
			"keyframe_count": 4,
			"pivot_recentered": not extra_props.is_empty(),
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_preset_orbit
# ============================================================================

## Position traversing a circle around the target's current position —
## orbiting markers and HUD satellites. 3D orbits in the XZ plane; 2D and
## Controls orbit in screen space. The clip is seamless (last key == first),
## so loop_mode="linear" keeps it going.
func preset_orbit(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var clockwise: bool = params.get("clockwise", true)
	var duration: float = float(params.get("duration", 2.0))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	var loop_result := _resolve_loop_mode(params)
	if loop_result.has("error"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, loop_result.error)
	var loop_mode: int = loop_result.ok

	var handler = _h()
	if handler == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	var default_radius: float = 1.0 if kind == "3d" else 100.0
	var radius: float = float(params.get("radius", default_radius))
	if radius <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'radius' must be > 0")

	if anim_name.is_empty():
		anim_name = "orbit"

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

	var center: Variant = target.position
	var direction := 1.0 if clockwise else -1.0
	## Linear interpolation between keyframes is straight, so four quarter-turn
	## keys trace a diamond. Sixteen segments keep the chord error under ~2% of
	## the radius while staying cheap to evaluate.
	var keyframes: Array = []
	for step in range(_ORBIT_SEGMENTS + 1):
		var angle := direction * TAU * float(step) / float(_ORBIT_SEGMENTS)
		var offset: Variant
		if kind == "3d":
			offset = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		else:
			offset = Vector2(cos(angle) * radius, sin(angle) * radius)
		keyframes.append({
			"time": duration * float(step) / float(_ORBIT_SEGMENTS),
			"value": center + offset,
			"transition": "linear",
		})

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = loop_mode

	var track_path := "%s:position" % track_target
	handler._do_add_property_track(anim, track_path, "linear", keyframes)

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"radius": radius,
			"clockwise": clockwise,
			"length": duration,
			"loop_mode": AnimationValues.loop_mode_to_string(loop_mode),
			"keyframe_count": keyframes.size(),
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_preset_sweep
# ============================================================================

## A full-turn rotation sweep — radar scans, cooldown-ring accents. Controls
## get `pivot_offset` recentered in the same undo action so the sweep rotates
## around the widget's middle. The clip is seamless, so loop_mode="linear"
## turns it into a continuous sweep.
func preset_sweep(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var clockwise: bool = params.get("clockwise", true)
	var turns: float = float(params.get("turns", 1.0))
	var duration: float = float(params.get("duration", 1.0))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	if turns <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'turns' must be > 0")
	var loop_result := _resolve_loop_mode(params)
	if loop_result.has("error"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, loop_result.error)
	var loop_mode: int = loop_result.ok

	var handler = _h()
	if handler == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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
	## Untyped: `rotation` lives on Control/Node2D/Node3D, not on the Node base.
	var target = target_resolved.node
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	if anim_name.is_empty():
		anim_name = "sweep"

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

	var direction := 1.0 if clockwise else -1.0
	var total_radians := direction * TAU * turns
	## Sweep from the target's current orientation instead of snapping it to 0.
	var start_rotation: float = float(target.rotation.y) if kind == "3d" else float(target.rotation)

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = loop_mode

	## 3D nodes rotate around their local Y axis; Control/Node2D have a single
	## `rotation` property.
	var track_path := "%s:rotation:y" % track_target if kind == "3d" else "%s:rotation" % track_target
	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": start_rotation, "transition": "linear"},
		{"time": duration, "value": start_rotation + total_radians, "transition": "linear"},
	])

	var extra_props := _control_pivot_props(target)
	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
		false, null, extra_props,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"clockwise": clockwise,
			"turns": turns,
			"start_rotation": start_rotation,
			"length": duration,
			"loop_mode": AnimationValues.loop_mode_to_string(loop_mode),
			"pivot_recentered": not extra_props.is_empty(),
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_preset_drift
# ============================================================================

## A one-axis position offset over the clip — scanlines, marquee text,
## conveyor motion. The clip ends at a net offset from its start, so
## loop_mode="linear" would snap the target back each cycle; use "pingpong"
## (back and forth) or "none" (play once).
func preset_drift(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var target_path: String = params.get("target_path", "")
	var axis: String = params.get("axis", "x")
	var duration: float = float(params.get("duration", 1.0))
	var anim_name: String = params.get("animation_name", "")
	var overwrite: bool = params.get("overwrite", false)

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_path")
	if duration <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'duration' must be > 0")
	var loop_result := _resolve_loop_mode(params)
	if loop_result.has("error"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, loop_result.error)
	var loop_mode: int = loop_result.ok
	if loop_mode == Animation.LOOP_LINEAR:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			(
				"preset_drift ends at a net offset from its start, so loop_mode 'linear' "
				+ "would snap the target back each cycle — use 'pingpong' or 'none'"
			),
		)

	var handler = _h()
	if handler == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"AnimationHandler not available", false)
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
	var kind: String = target_resolved.kind
	var track_target: String = target_resolved.track_path_root

	var default_distance: float = 1.0 if kind == "3d" else 100.0
	var distance: float = float(params.get("distance", default_distance))
	if distance == 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "'distance' must be non-zero")

	var offset: Variant
	if kind == "3d":
		match axis:
			"x": offset = Vector3(distance, 0.0, 0.0)
			"y": offset = Vector3(0.0, distance, 0.0)
			"z": offset = Vector3(0.0, 0.0, distance)
			_: return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid axis '%s' for a 3D target. Valid: x, y, z" % axis)
	else:
		match axis:
			"x": offset = Vector2(distance, 0.0)
			"y": offset = Vector2(0.0, distance)
			_: return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid axis '%s' for a 2D target. Valid: x, y" % axis)

	if anim_name.is_empty():
		anim_name = "drift"

	var existing := _existing_animation(library, anim_name, overwrite)
	if existing.has("error"):
		return existing.error
	var old_anim: Animation = existing.old_anim

	var start_pos: Variant = target.position
	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = loop_mode

	var track_path := "%s:position" % track_target
	handler._do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": start_pos, "transition": "linear"},
		{"time": duration, "value": start_pos + offset, "transition": "linear"},
	])

	handler._commit_animation_add(
		"MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim,
	)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"axis": axis,
			"distance": distance,
			"length": duration,
			"loop_mode": AnimationValues.loop_mode_to_string(loop_mode),
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


## Validate the optional `loop_mode` param the continuous presets accept.
## Returns `{ok: <Animation.LOOP_* int>}` or `{error: msg}`.
static func _resolve_loop_mode(params: Dictionary) -> Dictionary:
	var mode: String = params.get("loop_mode", "none")
	if not _LOOP_MODES.has(mode):
		return {"error": "Invalid loop_mode '%s'. Valid: %s" % [mode, ", ".join(_LOOP_MODES.keys())]}
	return {"ok": _LOOP_MODES[mode]}


## Bundle a Control's `pivot_offset` recenter into the preset's undo action so
## a scale/rotation pop originates from the widget's middle. Non-Controls and
## already-centered pivots return an empty list.
static func _control_pivot_props(target: Node) -> Array:
	if not target is Control:
		return []
	var control := target as Control
	var desired := control.size * 0.5
	if control.pivot_offset.is_equal_approx(desired):
		return []
	return [{"object": control, "property": "pivot_offset", "value": desired, "old": control.pivot_offset}]
