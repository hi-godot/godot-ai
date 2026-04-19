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
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, ScenePath.format_parent_error(parent_path, scene_root))

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

	var resolved := _resolve_player(player_path, true)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_player: bool = resolved.get("player_created", false)
	var player_parent: Node = resolved.get("player_parent", null)
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
		player, library, created_library, anim_name, anim, old_anim,
		created_player, player_parent)

	return {
		"data": {
			"player_path": player_path,
			"name": anim_name,
			"length": length,
			"loop_mode": loop_mode_str,
			"library_created": created_library or created_player,
			"animation_player_created": created_player,
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

	# Use _resolve_animation so we can delete from ANY library, not just the
	# default. Mirrors the read-side symmetry with animation_get / animation_play
	# which already search all libraries via _resolve_animation.
	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var old_anim: Animation = anim_resolved.animation
	var library: AnimationLibrary = anim_resolved.library
	# Clip key within the owning library — strips the "libname/" prefix if the
	# caller passed a qualified name.
	var clip_key: String = anim_name
	var slash := anim_name.find("/")
	if slash >= 0:
		clip_key = anim_name.substr(slash + 1)

	_undo_redo.create_action("MCP: Delete animation %s" % anim_name)
	_undo_redo.add_do_method(library, "remove_animation", clip_key)
	_undo_redo.add_undo_method(library, "add_animation", clip_key, old_anim)
	_undo_redo.add_do_reference(old_anim)  # prevent GC so undo→redo works
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"library_key": anim_resolved.get("library_key", ""),
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
	# Resolve the target property's type ONCE — dense clips used to re-walk
	# get_property_list() per keyframe.
	var ctx := _resolve_track_prop_context(track_path, player)
	if ctx.has("error"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, ctx.error)
	var coerced_keyframes: Array = []
	for kf in keyframes:
		if typeof(kf) != TYPE_DICTIONARY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must be a dictionary")
		if not "time" in kf:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must have a 'time' field")
		if not "value" in kf:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Each keyframe must have a 'value' field")
		var coerce_result := _coerce_with_context(kf.get("value"), ctx)
		if coerce_result.has("error"):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, coerce_result.error)
		coerced_keyframes.append({
			"time": kf.get("time"),
			"value": coerce_result.ok,
			"transition": kf.get("transition", "linear"),
		})

	_undo_redo.create_action("MCP: Add property track %s to %s" % [track_path, anim_name])
	_undo_redo.add_do_method(self, "_do_add_property_track", anim, track_path, interp_str, coerced_keyframes)
	# Undo locates the track by (path, type) at undo time rather than caching
	# an index captured at do time. Cached indices go stale if any other track
	# mutation lands between do and undo (Godot editor, another MCP call, etc.)
	_undo_redo.add_undo_method(self, "_undo_remove_track_by_path", anim, track_path, Animation.TYPE_VALUE)
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"track_path": track_path,
			"interpolation": interp_str,
			"keyframe_count": keyframes.size(),
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
		var method_field = kf.get("method")
		if typeof(method_field) != TYPE_STRING or (method_field as String).is_empty():
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'method' must be a non-empty string")
		if kf.has("args") and typeof(kf.get("args")) != TYPE_ARRAY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"'args' must be an array if provided (got %s)" % type_string(typeof(kf.get("args"))))

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation

	_undo_redo.create_action("MCP: Add method track %s to %s" % [target_path, anim_name])
	_undo_redo.add_do_method(self, "_do_add_method_track", anim, target_path, keyframes)
	# Undo locates the track by (path, type) at undo time — see add_property_track.
	_undo_redo.add_undo_method(self, "_undo_remove_track_by_path", anim, target_path, Animation.TYPE_METHOD)
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"target_node_path": target_path,
			"keyframe_count": keyframes.size(),
			"undoable": true,
		}
	}


## Remove a track identified by (path, type) at undo time. Robust to
## history interleaving: if another track was added since the do, the
## find_track call still resolves to the correct index. Returns silently
## if the track is no longer present (e.g. a prior undo already removed it).
func _undo_remove_track_by_path(anim: Animation, track_path: String, track_type: int) -> void:
	var idx := anim.find_track(NodePath(track_path), track_type)
	if idx >= 0:
		anim.remove_track(idx)


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

	# Compute/validate length before resolving the player — a fresh auto-created
	# AnimationPlayer is a detached Node that leaks if we return after creation.
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

	var resolved := _resolve_player(player_path, true)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var library: AnimationLibrary = resolved.library
	var created_player: bool = resolved.get("player_created", false)
	var player_parent: Node = resolved.get("player_parent", null)
	var created_library := false
	if library == null:
		library = AnimationLibrary.new()
		created_library = true

	var overwrite: bool = params.get("overwrite", false)
	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			if created_player:
				player.queue_free()
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	# Pre-coerce all tween values before touching the anim — coercion errors
	# surface as INVALID_PARAMS, not silent garbage keyframes.
	# When the player was auto-created, it isn't in the tree yet — pass its
	# future parent so the coercer can still resolve target property types.
	var coerce_root: Node = player_parent if created_player else null
	var per_track_keyframes: Array = []
	for spec in tweens:
		var target: String = str(spec.get("target", ""))
		var property: String = str(spec.get("property", ""))
		var track_path: String = target + ":" + property
		var duration: float = float(spec.get("duration", 1.0))
		var delay: float = float(spec.get("delay", 0.0))
		var trans_str = spec.get("transition", "linear")
		var from_result := _coerce_value_for_track(spec.get("from"), track_path, player, coerce_root)
		if from_result.has("error"):
			if created_player:
				player.queue_free()
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "tween '%s': %s" % [track_path, from_result.error])
		var to_result := _coerce_value_for_track(spec.get("to"), track_path, player, coerce_root)
		if to_result.has("error"):
			if created_player:
				player.queue_free()
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

	# One atomic undo action — bundles player creation (if any), library
	# creation (if any), and the animation add. A single Ctrl-Z rolls back all.
	_commit_animation_add("MCP: Create animation %s (%d tracks)" % [anim_name, anim.get_track_count()],
		player, library, created_library, anim_name, anim, old_anim,
		created_player, player_parent)

	return {
		"data": {
			"player_path": player_path,
			"name": anim_name,
			"length": computed_length,
			"loop_mode": loop_mode_str,
			"track_count": anim.get_track_count(),
			"library_created": created_library or created_player,
			"animation_player_created": created_player,
			"overwritten": old_anim != null,
			"undoable": true,
		}
	}


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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if target_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: target_path")
	if mode != "in" and mode != "out":
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid mode '%s'. Valid: 'in', 'out'" % mode)
	if duration <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'duration' must be > 0")

	var resolved := _resolve_player(player_path)
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

	# Fade requires a `modulate` property (CanvasItem/Control/Node2D/Sprite3D/etc).
	var has_modulate := false
	for p in target.get_property_list():
		if p.name == "modulate":
			has_modulate = true
			break
	if not has_modulate:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Target '%s' (class %s) has no 'modulate' property — fade requires a CanvasItem, Control, Node2D, or Sprite3D"
			% [target_path, target.get_class()])

	if anim_name.is_empty():
		anim_name = "fade_%s" % mode

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var start_a: float = 0.0 if mode == "in" else 1.0
	var end_a: float = 1.0 if mode == "in" else 0.0

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:modulate:a" % target_path
	_do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": start_a, "transition": "linear"},
		{"time": duration, "value": end_a, "transition": "linear"},
	])

	_commit_animation_add(
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if target_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: target_path")
	if not ["left", "right", "up", "down"].has(direction):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid direction '%s'. Valid: 'left', 'right', 'up', 'down'" % direction)
	if mode != "in" and mode != "out":
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid mode '%s'. Valid: 'in', 'out'" % mode)
	if duration <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'duration' must be > 0")

	var resolved := _resolve_player(player_path)
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

	# Default distance picks 3D units vs screen pixels based on target kind.
	var default_distance: float = 1.0 if kind == "3d" else 100.0
	var distance: float = float(params.get("distance", default_distance))
	if distance == 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'distance' must be non-zero")

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
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Animation '%s' already exists. Pass overwrite=true or delete it first." % anim_name)
		old_anim = library.get_animation(anim_name)

	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_NONE

	var track_path := "%s:position" % target_path
	_do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": start_pos, "transition": "linear"},
		{"time": duration, "value": end_pos, "transition": "linear"},
	])

	_commit_animation_add(
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if target_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: target_path")
	if duration <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'duration' must be > 0")
	if frequency <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'frequency' must be > 0")

	var resolved := _resolve_player(player_path)
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

	var default_intensity: float = 0.1 if kind == "3d" else 10.0
	var intensity: float = float(params.get("intensity", default_intensity))
	if intensity <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'intensity' must be > 0")

	if anim_name.is_empty():
		anim_name = "shake"

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
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

	var track_path := "%s:position" % target_path
	_do_add_property_track(anim, track_path, "linear", kfs)

	_commit_animation_add(
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: player_path")
	if target_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: target_path")
	if duration <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'duration' must be > 0")
	if from_scale <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'from_scale' must be > 0")
	if to_scale <= 0.0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'to_scale' must be > 0")

	var resolved := _resolve_player(player_path)
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

	if anim_name.is_empty():
		anim_name = "pulse"

	var old_anim: Animation = null
	if library.has_animation(anim_name):
		if not overwrite:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
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

	var track_path := "%s:scale" % target_path
	_do_add_property_track(anim, track_path, "linear", [
		{"time": 0.0, "value": from_vec, "transition": "linear"},
		{"time": duration * 0.5, "value": to_vec, "transition": "linear"},
		{"time": duration, "value": from_vec, "transition": "linear"},
	])

	_commit_animation_add(
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

## Resolve a preset target node relative to the player's animation root and
## classify its transform kind. Mirrors the same root-node fallback that
## `_resolve_track_prop_context` uses so tool inputs match how the track path
## will resolve at playback.
## Returns {node, kind} where kind ∈ {"control", "2d", "3d"}, or an error dict.
func _resolve_preset_target(player: AnimationPlayer, target_path: String) -> Dictionary:
	var root_node: Node = null
	if player.is_inside_tree():
		var rn := player.root_node
		if rn != NodePath():
			root_node = player.get_node_or_null(rn)
		if root_node == null:
			root_node = player.get_parent()
	if root_node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"AnimationPlayer at %s has no resolvable root_node (is the scene open?)" % str(player.get_path()))
	var target: Node = root_node.get_node_or_null(target_path)
	if target == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Target node not found at '%s' (resolved against player's root_node)" % target_path)
	var kind: String
	if target is Control:
		kind = "control"
	elif target is Node2D:
		kind = "2d"
	elif target is Node3D:
		kind = "3d"
	else:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Target '%s' must be a Control, Node2D, or Node3D (got %s)" % [target_path, target.get_class()])
	return {"node": target, "kind": kind}


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


# ============================================================================
# Helpers — undo
# ============================================================================

## Shared undo setup for create_animation and create_simple. Handles fresh-
## create, overwrite, library auto-create, and player auto-create in a single
## atomic action. When `created_player` is true, the player already has the
## library attached (eagerly, from `_instantiate_player`) and the library
## doesn't need its own undo bookkeeping — it rides along with the add_child.
func _commit_animation_add(
	action_label: String,
	player: AnimationPlayer,
	library: AnimationLibrary,
	created_library: bool,
	anim_name: String,
	anim: Animation,
	old_anim: Animation,  ## null when not overwriting
	created_player: bool = false,
	player_parent: Node = null,
) -> void:
	_undo_redo.create_action(action_label)
	if created_player:
		var scene_root := EditorInterface.get_edited_scene_root()
		_undo_redo.add_do_method(player_parent, "add_child", player, true)
		_undo_redo.add_do_method(player, "set_owner", scene_root)
		_undo_redo.add_do_reference(player)
		_undo_redo.add_do_reference(library)
		_undo_redo.add_undo_method(player_parent, "remove_child", player)
	elif created_library:
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
## Returns {player, library, player_created, player_parent} on success, or an
## error dict. library is null if the player exists but has no default library
## yet — callers bundle an `add_animation_library` step into their undo action.
##
## When `create_if_missing` is true and `player_path` resolves to nothing, a
## fresh AnimationPlayer is instantiated (with an empty default library attached
## eagerly) but is NOT added to the scene tree — callers must bundle the
## add_child step into their undo action via `_commit_animation_add`.
## If the resolved node exists but isn't an AnimationPlayer, that's still an
## error — we don't clobber an existing node of a different type.
func _resolve_player(player_path: String, create_if_missing: bool = false) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	var node := ScenePath.resolve(player_path, scene_root)
	if node == null:
		if not create_if_missing:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % player_path)
		return _instantiate_player(player_path, scene_root)
	if not node is AnimationPlayer:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Node at %s is not an AnimationPlayer (got %s)" % [player_path, node.get_class()])
	var player := node as AnimationPlayer
	var lib: AnimationLibrary = null
	if player.has_animation_library(""):
		lib = player.get_animation_library("")
	return {"player": player, "library": lib, "player_created": false, "player_parent": null}


## Build a new AnimationPlayer (with empty default library) for insertion under
## the parent implied by `player_path`. Returns an error dict if the parent
## can't be resolved or the path has no usable leaf name.
func _instantiate_player(player_path: String, scene_root: Node) -> Dictionary:
	var slash := player_path.rfind("/")
	var parent_path: String
	var player_name: String
	if slash < 0:
		parent_path = ""
		player_name = player_path
	else:
		parent_path = player_path.substr(0, slash)
		player_name = player_path.substr(slash + 1)
	if player_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Cannot auto-create AnimationPlayer: player_path '%s' has no leaf name" % player_path)
	var parent: Node
	if parent_path.is_empty():
		parent = scene_root
	else:
		parent = ScenePath.resolve(parent_path, scene_root)
	if parent == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Cannot auto-create AnimationPlayer at %s: %s" % [
				player_path, ScenePath.format_parent_error(parent_path, scene_root)])
	var new_player := AnimationPlayer.new()
	new_player.name = player_name
	var lib := AnimationLibrary.new()
	new_player.add_animation_library("", lib)
	return {
		"player": new_player,
		"library": lib,
		"player_created": true,
		"player_parent": parent,
	}


## Like `_resolve_player`, but when the node at `player_path` doesn't exist,
## prepare a fresh AnimationPlayer to be added at that path instead of
## erroring. Parallels the existing library auto-create affordance — callers
## bundle the `add_child` step into the same undo action so player + library
## + animation roll back together. Returns the same shape as `_resolve_player`
## plus `{player_created: bool, player_parent: Node}` when a new player is
## staged. If the node exists but isn't an AnimationPlayer, errors exactly
## like `_resolve_player` — that's a genuine type mismatch, not a missing node.
func _resolve_or_create_player(player_path: String) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	if ScenePath.resolve(player_path, scene_root) != null:
		# Node exists — delegate so the type-mismatch error stays identical
		# to _resolve_player's.
		var existing := _resolve_player(player_path)
		if not existing.has("error"):
			existing["player_created"] = false
		return existing

	# Stage a fresh AnimationPlayer at player_path. Parent must exist (same
	# rule as node_create) — otherwise the caller's path is ambiguous.
	var parent_path := player_path.get_base_dir()
	var new_name := player_path.get_file()
	if new_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid player_path (no node name): %s" % player_path)
	var parent: Node
	if parent_path.is_empty() or parent_path == "/":
		parent = scene_root
	else:
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
				"Node not found: %s (and its parent %s also does not exist — create the parent first)" %
				[player_path, parent_path])
	var new_player := AnimationPlayer.new()
	new_player.name = new_name
	return {
		"player": new_player,
		"library": null,
		"player_created": true,
		"player_parent": parent,
	}


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
## `override_root_node` lets callers supply the root to resolve target paths
## against when the player isn't in the tree yet (auto-create flow) — the
## player's future parent stands in for the root the AnimationPlayer will
## eventually use.
static func _coerce_value_for_track(value: Variant, track_path: String, player: AnimationPlayer, override_root_node: Node = null) -> Dictionary:
	var ctx := _resolve_track_prop_context(track_path, player, override_root_node)
	if ctx.has("error"):
		return {"error": ctx.error}
	return _coerce_with_context(value, ctx)


## Resolve a track_path's target property type once, so callers coercing many
## keyframes avoid walking `get_property_list()` on every one. Returns:
##   {pass_through: true}                   — no resolution / authoring-time
##   {pass_through: false, prop_type, prop_name}  — coerce against this type
##   {error: msg}                           — property not found on target
##
## Supports Godot's native NodePath subpath form `property:sub` (e.g.
## `position:y`, `modulate:a`) — splits on the FIRST colon (node↔property
## boundary), resolves the base property on the target, and for known
## scalar subpaths (x/y/z/w on vectors, r/g/b/a on Color) narrows the
## coerce target to TYPE_FLOAT so JSON numbers land as floats, not dicts.
static func _resolve_track_prop_context(track_path: String, player: AnimationPlayer, override_root_node: Node = null) -> Dictionary:
	var colon := track_path.find(":")
	if colon < 0:
		return {"pass_through": true}

	var node_part := track_path.substr(0, colon)
	var prop_full := track_path.substr(colon + 1)

	# Property may include a subpath: "position:y", "modulate:a", etc.
	var sub_colon := prop_full.find(":")
	var prop_base := prop_full if sub_colon < 0 else prop_full.substr(0, sub_colon)
	var prop_sub := "" if sub_colon < 0 else prop_full.substr(sub_colon + 1)

	var root_node: Node = override_root_node
	if root_node == null and player.is_inside_tree():
		var rn := player.root_node
		if rn != NodePath():
			root_node = player.get_node_or_null(rn)
		if root_node == null:
			root_node = player.get_parent()
	if root_node == null:
		return {"pass_through": true}

	var target: Node = root_node.get_node_or_null(node_part)
	if target == null:
		# Target node isn't in the scene yet — authoring-time path. Pass through.
		return {"pass_through": true}

	for p in target.get_property_list():
		if p.name == prop_base:
			var base_type: int = p.get("type", TYPE_NIL)
			var coerce_type := base_type
			if not prop_sub.is_empty():
				var sub_type := _subpath_component_type(base_type, prop_sub)
				if sub_type == TYPE_NIL:
					# Unknown subpath component — pass through so Godot's own
					# NodePath resolution raises at playback if it's truly bogus,
					# rather than fabricating a coerce error for a valid-but-
					# uncommon form (e.g. Transform3D subpaths).
					return {"pass_through": true}
				coerce_type = sub_type
			return {
				"pass_through": false,
				"prop_type": coerce_type,
				"prop_name": prop_full,
			}

	# Target exists but the property doesn't. Reject loudly — silently storing
	# the raw value here produces garbage keyframes at playback time.
	return {"error":
		"%s (target path: '%s')" %
		[McpPropertyErrors.build_message(target, prop_base), node_part]}


## Component letters accepted on each aggregate base type, paired with the
## scalar Variant type the component resolves to. A subpath like `position:y`
## on a Vector3 maps to TYPE_FLOAT; on a Vector3i it maps to TYPE_INT.
const _SUBPATH_COMPONENTS := {
	TYPE_VECTOR2: ["xy", TYPE_FLOAT],
	TYPE_VECTOR3: ["xyz", TYPE_FLOAT],
	TYPE_VECTOR4: ["xyzw", TYPE_FLOAT],
	TYPE_QUATERNION: ["xyzw", TYPE_FLOAT],
	TYPE_COLOR: ["rgba", TYPE_FLOAT],
	TYPE_VECTOR2I: ["xy", TYPE_INT],
	TYPE_VECTOR3I: ["xyz", TYPE_INT],
	TYPE_VECTOR4I: ["xyzw", TYPE_INT],
}


## Map a `property:sub` subpath to its scalar component type. Returns
## TYPE_NIL when the base type / subkey pair isn't one we recognise —
## callers pass-through in that case rather than mis-coerce.
static func _subpath_component_type(base_type: int, sub: String) -> int:
	var entry = _SUBPATH_COMPONENTS.get(base_type)
	if entry == null or sub.length() != 1:
		return TYPE_NIL
	return entry[1] if (entry[0] as String).contains(sub) else TYPE_NIL


static func _coerce_with_context(value: Variant, ctx: Dictionary) -> Dictionary:
	if ctx.get("pass_through", false):
		return {"ok": value}
	return _coerce_for_type(value, ctx.prop_type, ctx.prop_name)


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
