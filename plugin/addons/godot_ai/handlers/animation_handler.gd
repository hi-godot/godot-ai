@tool
class_name AnimationHandler
extends RefCounted

## Handles AnimationPlayer authoring: creating players, animations, tracks,
## keyframes, autoplay, and dev-ergonomics playback.
##
## Animations live inside an AnimationLibrary attached to an AnimationPlayer
## node in the scene. They save with the .tscn — no separate resource file
## needed. Undo callables hold direct Animation references (not paths).

var _undo_redo: EditorUndoRedoManager

const _LOOP_MODES := {
	"none": Animation.LOOP_NONE,
	"linear": Animation.LOOP_LINEAR,
	"pingpong": Animation.LOOP_PINGPONG,
}

const _INTERP_MODES := {
	"nearest": Animation.INTERPOLATION_NEAREST,
	"linear": Animation.INTERPOLATION_LINEAR,
	"cubic": Animation.INTERPOLATION_CUBIC,
}

const _NAMED_TRANSITIONS := {
	"linear": 1.0,
	"ease_in": 2.0,
	"ease_out": 0.5,
	"ease_in_out": -2.0,
}


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# animation_player_create
# ============================================================================

func create_player(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "AnimationPlayer")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var player := AnimationPlayer.new()
	if not node_name.is_empty():
		player.name = node_name

	# Attach the default library before adding to tree — it persists on redo.
	var library := AnimationLibrary.new()
	player.add_animation_library("", library)

	_undo_redo.create_action("MCP: Create AnimationPlayer %s" % player.name)
	_undo_redo.add_do_method(parent, "add_child", player, true)
	_undo_redo.add_do_method(player, "set_owner", scene_root)
	_undo_redo.add_do_reference(player)
	_undo_redo.add_do_reference(library)
	_undo_redo.add_undo_method(parent, "remove_child", player)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": ScenePath.from_node(player, scene_root),
			"parent_path": ScenePath.from_node(parent, scene_root),
			"name": String(player.name),
			"undoable": true,
		}
	}


# ============================================================================
# animation_create
# ============================================================================

func create_animation(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("name", "")
	var length: float = float(params.get("length", 1.0))
	var loop_mode_str: String = params.get("loop_mode", "none")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: name")
	if length <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "length must be > 0 (got %s)" % length)

	if not _LOOP_MODES.has(loop_mode_str):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid loop_mode '%s'. Valid: %s" % [loop_mode_str, ", ".join(_LOOP_MODES.keys())])

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var overwrite: bool = params.get("overwrite", false)
	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = _LOOP_MODES[loop_mode_str]

	_commit_animation_add("MCP: Create animation %s" % anim_name,
		player, library, created_library, anim_name, anim, old_anim)

	return {
		"data": {
			"player_path": player_path,
			"name": anim_name,
			"length": length,
			"loop_mode": loop_mode_str,
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# animation_delete
# ============================================================================

func delete_animation(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: animation_name")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	if not player.has_animation(anim_name):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Animation '%s' not found on player at %s" % [anim_name, player_path])

	var library: AnimationLibrary = resolved.library
	if library == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "No default library found")

	var old_anim: Animation = library.get_animation(anim_name)

	_undo_redo.create_action("MCP: Delete animation %s" % anim_name)
	_undo_redo.add_do_method(library, "remove_animation", anim_name)
	_undo_redo.add_undo_method(library, "add_animation", anim_name, old_anim)
	_undo_redo.add_do_reference(old_anim)  # prevent GC so undo→redo works
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"undoable": true,
		}
	}


# ============================================================================
# animation_add_property_track
# ============================================================================

func add_property_track(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")
	var track_path: String = params.get("track_path", "")
	var keyframes = params.get("keyframes", [])
	var interp_str: String = params.get("interpolation", "linear")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: animation_name")
	if track_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Missing required param: track_path (format: 'NodeName:property', e.g. 'Panel:modulate')")
	if not track_path.contains(":"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"track_path must include ':property' suffix (e.g. 'Panel:modulate', '.:position')")
	if not _INTERP_MODES.has(interp_str):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid interpolation '%s'. Valid: %s" % [interp_str, ", ".join(_INTERP_MODES.keys())])
	if typeof(keyframes) != TYPE_ARRAY or keyframes.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "keyframes must be a non-empty array")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation

	# Validate + pre-coerce keyframes before mutating. Coercion errors
	# surface as INVALID_PARAMS rather than silently inserting garbage keys.
	var coerced_keyframes: Array = []
	for kf in keyframes:
		if typeof(kf) != TYPE_DICTIONARY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must be a dictionary")
		if not "time" in kf:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must have a 'time' field")
		if not "value" in kf:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must have a 'value' field")
		var coerce_result := _coerce_value_for_track(kf.get("value"), track_path, player)
		if coerce_result.has("error"):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, coerce_result.error)
		coerced_keyframes.append({
			"time": kf.get("time"),
			"value": coerce_result.ok,
			"transition": kf.get("transition", "linear"),
		})

	var baseline := anim.get_track_count()

	_undo_redo.create_action("MCP: Add property track %s to %s" % [track_path, anim_name])
	_undo_redo.add_do_method(self, "_do_add_property_track", anim, track_path, interp_str, coerced_keyframes)
	_undo_redo.add_undo_method(anim, "remove_track", baseline)
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"track_path": track_path,
			"interpolation": interp_str,
			"keyframe_count": keyframes.size(),
			"track_index": baseline,
			"undoable": true,
		}
	}


## Insert a pre-coerced track into the animation. Callers must coerce
## values against the target property before calling this (see
## _coerce_value_for_track) — this method runs inside the undo do-method
## path where error propagation isn't possible.
func _do_add_property_track(
	anim: Animation,
	track_path: String,
	interp_str: String,
	keyframes: Array,
) -> void:
	var idx := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(idx, NodePath(track_path))
	anim.track_set_interpolation_type(idx, _INTERP_MODES.get(interp_str, Animation.INTERPOLATION_LINEAR))
	for kf in keyframes:
		var t: float = float(kf.get("time", 0.0))
		var trans: float = _parse_transition(kf.get("transition", "linear"))
		anim.track_insert_key(idx, t, kf.get("value"), trans)


# ============================================================================
# animation_add_method_track
# ============================================================================

func add_method_track(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")
	var target_path: String = params.get("target_node_path", "")
	var keyframes = params.get("keyframes", [])

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: animation_name")
	if target_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: target_node_path")
	if target_path.contains(":"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"target_node_path is a bare NodePath without ':property' (got '%s'). " % target_path +
			"Method name goes in each keyframe's 'method' field, not the path.")
	if typeof(keyframes) != TYPE_ARRAY or keyframes.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "keyframes must be a non-empty array")

	for kf in keyframes:
		if typeof(kf) != TYPE_DICTIONARY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must be a dictionary")
		if not "time" in kf:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must have a 'time' field")
		if not "method" in kf:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must have a 'method' field")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation

	var baseline := anim.get_track_count()

	_undo_redo.create_action("MCP: Add method track %s to %s" % [target_path, anim_name])
	_undo_redo.add_do_method(self, "_do_add_method_track", anim, target_path, keyframes)
	_undo_redo.add_undo_method(anim, "remove_track", baseline)
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"target_node_path": target_path,
			"keyframe_count": keyframes.size(),
			"track_index": baseline,
			"undoable": true,
		}
	}


func _do_add_method_track(anim: Animation, target_path: String, keyframes: Array) -> void:
	var idx := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(idx, NodePath(target_path))
	for kf in keyframes:
		var t: float = float(kf.get("time", 0.0))
		var method_name: String = str(kf.get("method", ""))
		var args: Array = kf.get("args", [])
		anim.track_insert_key(idx, t, {"method": method_name, "args": args})


# ============================================================================
# animation_set_autoplay
# ============================================================================

func set_autoplay(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	# Allow empty string to clear autoplay; otherwise validate the name exists.
	if not anim_name.is_empty() and not player.has_animation(anim_name):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Animation '%s' not found on player at %s" % [anim_name, player_path])

	var old_autoplay: String = player.autoplay

	_undo_redo.create_action("MCP: Set autoplay %s on %s" % [anim_name, player_path])
	_undo_redo.add_do_property(player, "autoplay", anim_name)
	_undo_redo.add_undo_property(player, "autoplay", old_autoplay)
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"previous_autoplay": old_autoplay,
			"cleared": anim_name.is_empty(),
			"undoable": true,
		}
	}


# ============================================================================
# animation_play  (dev ergonomics — not saved with scene)
# ============================================================================

func play(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	if not anim_name.is_empty() and not player.has_animation(anim_name):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Animation '%s' not found on player at %s" % [anim_name, player_path])

	player.play(anim_name)

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"undoable": false,
			"reason": "Runtime playback state — not saved with scene",
		}
	}


# ============================================================================
# animation_stop  (dev ergonomics — not saved with scene)
# ============================================================================

func stop(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	player.stop()

	return {
		"data": {
			"player_path": player_path,
			"undoable": false,
			"reason": "Runtime playback state — not saved with scene",
		}
	}


# ============================================================================
# animation_list  (read)
# ============================================================================

func list_animations(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")

	var resolved := _resolve_player_read(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var animations: Array[Dictionary] = []
	for lib_name in player.get_animation_library_list():
		var lib: AnimationLibrary = player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name)
			var display_name: String = anim_name if lib_name == "" else "%s/%s" % [lib_name, anim_name]
			animations.append({
				"name": display_name,
				"length": anim.length,
				"loop_mode": _loop_mode_to_string(anim.loop_mode),
				"track_count": anim.get_track_count(),
			})

	return {
		"data": {
			"player_path": player_path,
			"animations": animations,
			"count": animations.size(),
		}
	}


# ============================================================================
# animation_get  (read)
# ============================================================================

func get_animation(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: animation_name")

	var resolved := _resolve_player_read(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation

	var tracks: Array[Dictionary] = []
	for i in anim.get_track_count():
		var track_type := anim.track_get_type(i)
		var type_name := _track_type_to_string(track_type)
		var keys: Array[Dictionary] = []
		for k in anim.track_get_key_count(i):
			var key_val = anim.track_get_key_value(i, k)
			keys.append({
				"time": anim.track_get_key_time(i, k),
				"value": _serialize_value(key_val),
				"transition": anim.track_get_key_transition(i, k),
			})
		tracks.append({
			"index": i,
			"type": type_name,
			"path": str(anim.track_get_path(i)),
			"interpolation": _interp_to_string(anim.track_get_interpolation_type(i)),
			"key_count": keys.size(),
			"keys": keys,
		})

	return {
		"data": {
			"player_path": player_path,
			"name": anim_name,
			"length": anim.length,
			"loop_mode": _loop_mode_to_string(anim.loop_mode),
			"track_count": anim.get_track_count(),
			"tracks": tracks,
		}
	}


# ============================================================================
# animation_validate  (read-only)
# ============================================================================

func validate_animation(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: animation_name")

	var resolved := _resolve_player_read(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	if not player.has_animation(anim_name):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Animation '%s' not found on player at %s" % [anim_name, player_path])

	var anim: Animation = player.get_animation(anim_name)

	var root_node: Node = null
	if player.is_inside_tree():
		var rn := player.root_node
		if rn != NodePath():
			root_node = player.get_node_or_null(rn)
		if root_node == null:
			root_node = player.get_parent()

	var broken_tracks: Array[Dictionary] = []
	var valid_count := 0

	for i in anim.get_track_count():
		var track_path_str := str(anim.track_get_path(i))
		var colon := track_path_str.rfind(":")
		var node_part: String
		if colon >= 0:
			node_part = track_path_str.substr(0, colon)
		else:
			node_part = track_path_str

		var target_node: Node = null
		if root_node != null:
			target_node = root_node.get_node_or_null(node_part)

		if target_node == null:
			broken_tracks.append({
				"index": i,
				"path": track_path_str,
				"type": _track_type_to_string(anim.track_get_type(i)),
				"issue": "node_not_found",
				"node_path": node_part,
			})
		else:
			valid_count += 1

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"track_count": anim.get_track_count(),
			"valid_count": valid_count,
			"broken_count": broken_tracks.size(),
			"broken_tracks": broken_tracks,
			"valid": broken_tracks.is_empty(),
		}
	}


# ============================================================================
# animation_create_simple  (composer)
# ============================================================================

func create_simple(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("name", "")
	var tweens = params.get("tweens", [])
	var loop_mode_str: String = params.get("loop_mode", "none")

	if player_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if anim_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: name")
	if typeof(tweens) != TYPE_ARRAY or tweens.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "tweens must be a non-empty array")
	if not _LOOP_MODES.has(loop_mode_str):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid loop_mode '%s'. Valid: %s" % [loop_mode_str, ", ".join(_LOOP_MODES.keys())])

	# Validate all tween specs before touching the scene.
	var seen_paths := {}
	for spec in tweens:
		if typeof(spec) != TYPE_DICTIONARY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each tween spec must be a dictionary")
		for field in ["target", "property", "from", "to", "duration"]:
			if not field in spec:
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
					"Each tween spec must have '%s'" % field)
		if float(spec.get("duration", 0.0)) <= 0.0:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"tween 'duration' must be > 0")
		var dup_key: String = str(spec.target) + ":" + str(spec.property)
		if seen_paths.has(dup_key):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Duplicate tween target '%s' — merge keyframes into a single track " % dup_key +
				"via animation_add_property_track instead of two separate tweens.")
		seen_paths[dup_key] = true

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var overwrite: bool = params.get("overwrite", false)
	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	# Compute auto length only when length is absent or null; reject explicit
	# invalid values instead of silently falling through to auto-compute.
	var has_length: bool = params.has("length") and params.get("length") != null
	var computed_length: float = 0.0
	if has_length:
		computed_length = float(params.get("length"))
		if computed_length <= 0.0:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"'length' must be > 0 when provided (got %s)" % str(params.get("length")))
	else:
		for spec in tweens:
			var end_time: float = float(spec.get("delay", 0.0)) + float(spec.get("duration", 0.0))
			if end_time > computed_length:
				computed_length = end_time
		if computed_length <= 0.0:
			computed_length = 1.0

	# Pre-coerce all tween values before touching the anim — coercion errors
	# surface as INVALID_PARAMS, not silent garbage keyframes.
	var per_track_keyframes: Array = []
	for spec in tweens:
		var target: String = str(spec.get("target", ""))
		var property: String = str(spec.get("property", ""))
		var track_path: String = target + ":" + property
		var duration: float = float(spec.get("duration", 1.0))
		var delay: float = float(spec.get("delay", 0.0))
		var trans_str = spec.get("transition", "linear")
		var from_result := _coerce_value_for_track(spec.get("from"), track_path, player)
		if from_result.has("error"):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "tween '%s': %s" % [track_path, from_result.error])
		var to_result := _coerce_value_for_track(spec.get("to"), track_path, player)
		if to_result.has("error"):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "tween '%s': %s" % [track_path, to_result.error])
		per_track_keyframes.append({
			"track_path": track_path,
			"keyframes": [
				{"time": delay, "value": from_result.ok, "transition": trans_str},
				{"time": delay + duration, "value": to_result.ok, "transition": trans_str},
			],
		})

	# Build the animation fully in memory before touching the undo stack.
	var anim := Animation.new()
	anim.length = computed_length
	anim.loop_mode = _LOOP_MODES[loop_mode_str]

	for entry in per_track_keyframes:
		_do_add_property_track(anim, entry.track_path, "linear", entry.keyframes)

	# One atomic undo action.
	_commit_animation_add("MCP: Create animation %s (%d tracks)" % [anim_name, anim.get_track_count()],
		player, library, created_library, anim_name, anim, old_anim)

	return {
		"data": {
			"player_path": player_path,
			"name": anim_name,
			"length": computed_length,
			"loop_mode": loop_mode_str,
			"track_count": anim.get_track_count(),
			"library_created": created_library,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


# ============================================================================
# Helpers — undo
# ============================================================================

## Shared undo setup for create_animation and create_simple. Handles both
## fresh-create and overwrite cases in a single atomic action.
func _commit_animation_add(
	action_label: String,
	player: AnimationPlayer,
	library: AnimationLibrary,
	created_library: bool,
	anim_name: String,
	anim: Animation,
	old_anim: Animation,  ## null when not overwriting
) -> void:
	_undo_redo.create_action(action_label)
	if created_library:
		_undo_redo.add_do_method(player, "add_animation_library", "", library)
		_undo_redo.add_undo_method(player, "remove_animation_library", "")
		_undo_redo.add_do_reference(library)
	if old_anim != null:
		_undo_redo.add_do_method(library, "remove_animation", anim_name)
	_undo_redo.add_do_method(library, "add_animation", anim_name, anim)
	if old_anim != null:
		_undo_redo.add_undo_method(library, "remove_animation", anim_name)
		_undo_redo.add_undo_method(library, "add_animation", anim_name, old_anim)
		_undo_redo.add_do_reference(old_anim)
	else:
		_undo_redo.add_undo_method(library, "remove_animation", anim_name)
	_undo_redo.add_do_reference(anim)
	_undo_redo.commit_action()


# ============================================================================
# Helpers — resolution
# ============================================================================

## Resolve an AnimationPlayer and its default library for write operations.
## Returns {player, library} on success, or an error dict.
## library is null if the player exists but has no default library yet —
## callers bundle an `add_animation_library` step into their undo action.
func _resolve_player(player_path: String) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	var node := ScenePath.resolve(player_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % player_path)
	if not node is AnimationPlayer:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Node at %s is not an AnimationPlayer (got %s)" % [player_path, node.get_class()])
	var player := node as AnimationPlayer
	var lib: AnimationLibrary = null
	if player.has_animation_library(""):
		lib = player.get_animation_library("")
	return {"player": player, "library": lib}


## Resolve for read operations (no library requirement).
func _resolve_player_read(player_path: String) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	var node := ScenePath.resolve(player_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % player_path)
	if not node is AnimationPlayer:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Node at %s is not an AnimationPlayer (got %s)" % [player_path, node.get_class()])
	return {"player": node as AnimationPlayer}


## Resolve an animation by name, searching all libraries.
## Accepts bare clip names ("idle") and library-qualified names ("moves/idle")
## as returned by `list_animations` for non-default libraries.
func _resolve_animation(player: AnimationPlayer, anim_name: String) -> Dictionary:
	if not player.has_animation(anim_name):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Animation '%s' not found on player. Available: %s" % [
				anim_name,
				", ".join(Array(player.get_animation_list()))
			])
	# If the caller passed "library/clip", look up in that specific library.
	var slash := anim_name.find("/")
	if slash >= 0:
		var lib_key := anim_name.substr(0, slash)
		var clip_key := anim_name.substr(slash + 1)
		if player.has_animation_library(lib_key):
			var lib: AnimationLibrary = player.get_animation_library(lib_key)
			if lib.has_animation(clip_key):
				return {"animation": lib.get_animation(clip_key), "library": lib, "library_key": lib_key}
	# Otherwise scan libraries for a bare clip name.
	for lib_name in player.get_animation_library_list():
		var lib2: AnimationLibrary = player.get_animation_library(lib_name)
		if lib2.has_animation(anim_name):
			return {"animation": lib2.get_animation(anim_name), "library": lib2, "library_key": lib_name}
	# Fallback — shouldn't happen if has_animation returned true.
	return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Animation found by player but not in any library")


# ============================================================================
# Helpers — value coercion
# ============================================================================

## Coerce a JSON value to match the expected Godot type for the given
## track_path. Returns {"ok": value} or {"error": msg}.
## Passes the raw value through when the target node isn't in the scene
## yet (authoring-time path). Errors when the target exists but the
## property doesn't, or when parsing a typed value (Color/Vector2/Vector3)
## clearly fails — better to reject than silently store garbage.
static func _coerce_value_for_track(value: Variant, track_path: String, player: AnimationPlayer) -> Dictionary:
	var colon := track_path.rfind(":")
	if colon < 0:
		return {"ok": value}

	var node_part := track_path.substr(0, colon)
	var prop_part := track_path.substr(colon + 1)

	var root_node: Node = null
	if player.is_inside_tree():
		var rn := player.root_node
		if rn != NodePath():
			root_node = player.get_node_or_null(rn)
		if root_node == null:
			root_node = player.get_parent()
	if root_node == null:
		return {"ok": value}

	var target: Node = root_node.get_node_or_null(node_part)
	if target == null:
		return {"ok": value}

	for p in target.get_property_list():
		if p.name == prop_part:
			return _coerce_for_type(value, p.get("type", TYPE_NIL), prop_part)

	# Property not found on current target — pass through. The caller may
	# plan to retarget the AnimationPlayer (set root_node) before playback.
	return {"ok": value}


## Coerce a single value to the given Godot variant type. Returns
## {"ok": coerced} or {"error": msg}. Unknown types pass through.
static func _coerce_for_type(value: Variant, prop_type: int, prop_name: String) -> Dictionary:
	match prop_type:
		TYPE_COLOR:
			if value is Color:
				return {"ok": value}
			if value is String:
				var s := value as String
				var a := Color.from_string(s, Color(0, 0, 0, 0))
				var b := Color.from_string(s, Color(1, 1, 1, 1))
				if a == b:
					return {"ok": a}
				return {"error": "Cannot parse '%s' as Color for property '%s'" % [s, prop_name]}
			if value is Dictionary and value.has("r") and value.has("g") and value.has("b"):
				return {"ok": Color(float(value.r), float(value.g), float(value.b), float(value.get("a", 1.0)))}
			return {"error": "Cannot coerce value to Color for property '%s' (expected string, {r,g,b}, or Color)" % prop_name}
		TYPE_VECTOR2:
			if value is Vector2:
				return {"ok": value}
			if value is Dictionary and value.has("x") and value.has("y"):
				return {"ok": Vector2(float(value.x), float(value.y))}
			if value is Array and value.size() >= 2:
				return {"ok": Vector2(float(value[0]), float(value[1]))}
			return {"error": "Cannot coerce value to Vector2 for property '%s' (expected {x,y}, [x,y], or Vector2)" % prop_name}
		TYPE_VECTOR3:
			if value is Vector3:
				return {"ok": value}
			if value is Dictionary and value.has("x") and value.has("y") and value.has("z"):
				return {"ok": Vector3(float(value.x), float(value.y), float(value.z))}
			return {"error": "Cannot coerce value to Vector3 for property '%s' (expected {x,y,z} or Vector3)" % prop_name}
		TYPE_FLOAT:
			if value is int or value is float:
				return {"ok": float(value)}
		TYPE_INT:
			if value is float or value is int:
				return {"ok": int(value)}
		TYPE_BOOL:
			if value is int or value is float or value is bool:
				return {"ok": bool(value)}
	return {"ok": value}


# ============================================================================
# Helpers — parsing + serializing
# ============================================================================

## Parse a transition value: named string or raw float.
## Named values live in `_NAMED_TRANSITIONS` so the mapping has a single source.
static func _parse_transition(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	if v is String:
		var key: String = (v as String).to_lower()
		if _NAMED_TRANSITIONS.has(key):
			return float(_NAMED_TRANSITIONS[key])
	return 1.0


## Map an Animation.TrackType enum to a stable string. Unknown types report
## as "unknown" rather than being silently coerced to "method" — callers that
## only produce value/method tracks can ignore the others; clients that want
## to round-trip bezier/audio/etc. get an honest label to key off.
static func _track_type_to_string(track_type: int) -> String:
	match track_type:
		Animation.TYPE_VALUE: return "value"
		Animation.TYPE_METHOD: return "method"
		Animation.TYPE_POSITION_3D: return "position_3d"
		Animation.TYPE_ROTATION_3D: return "rotation_3d"
		Animation.TYPE_SCALE_3D: return "scale_3d"
		Animation.TYPE_BLEND_SHAPE: return "blend_shape"
		Animation.TYPE_BEZIER: return "bezier"
		Animation.TYPE_AUDIO: return "audio"
		Animation.TYPE_ANIMATION: return "animation"
		_: return "unknown"


static func _loop_mode_to_string(mode: int) -> String:
	match mode:
		Animation.LOOP_LINEAR: return "linear"
		Animation.LOOP_PINGPONG: return "pingpong"
		_: return "none"


static func _interp_to_string(mode: int) -> String:
	match mode:
		Animation.INTERPOLATION_NEAREST: return "nearest"
		Animation.INTERPOLATION_CUBIC: return "cubic"
		_: return "linear"


## Convert a Godot Variant to a JSON-safe value.
static func _serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_NODE_PATH:
			return str(value)
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(_serialize_value(item))
			return arr
		TYPE_DICTIONARY:
			var out := {}
			for k in value:
				out[str(k)] = _serialize_value(value[k])
			return out
	return str(value)
