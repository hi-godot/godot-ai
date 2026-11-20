@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles AnimationPlayer authoring: creating players, animations, tracks,
## keyframes, autoplay, and dev-ergonomics playback.
##
## Animations live inside an AnimationLibrary attached to an AnimationPlayer
## node in the scene. They save with the .tscn — no separate resource file
## needed. Undo callables hold direct Animation references (not paths).
##
## Split (issue #342, audit finding #13):
##   - animation_presets.gd  → preset_fade / slide / shake / pulse + helpers
##   - animation_values.gd   → animation_list / get / validate + shared
##                             value coercion / serialization
## Both submodules hold a WeakRef back to this handler. The handler's
## preset_* / list / get / validate methods are thin proxies so existing
## dispatcher registrations and test fixtures don't change.

const AnimationPresets := preload("res://addons/godot_ai/handlers/animation_presets.gd")
const AnimationValues := preload("res://addons/godot_ai/handlers/animation_values.gd")

var _undo_redo: EditorUndoRedoManager
var _presets
var _values

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


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo
	_presets = AnimationPresets.new(self)
	_values = AnimationValues.new(self)


# ============================================================================
# animation_player_create
# ============================================================================

func create_player(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "AnimationPlayer")

	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_parent_error(parent_path, scene_root))

	var write_error := McpNodeValidator.writable_error(parent, scene_root)
	if not write_error.is_empty():
		return write_error

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
			"path": McpScenePath.from_node(player, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")
	if length <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "length must be > 0 (got %s)" % length)

	if not _LOOP_MODES.has(loop_mode_str):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
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
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: animation_name")

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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: animation_name")
	if track_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
			"Missing required param: track_path (format: 'NodeName:property', e.g. 'Panel:modulate')")
	if not track_path.contains(":"):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"track_path must include ':property' suffix (e.g. 'Panel:modulate', '.:position')")
	if not _INTERP_MODES.has(interp_str):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid interpolation '%s'. Valid: %s" % [interp_str, ", ".join(_INTERP_MODES.keys())])
	if typeof(keyframes) != TYPE_ARRAY or keyframes.is_empty():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "keyframes must be a non-empty array")

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
	var ctx := AnimationValues.resolve_track_prop_context(track_path, player)
	if ctx.has("error"):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, ctx.error)
	var coerced_keyframes: Array = []
	for kf in keyframes:
		if typeof(kf) != TYPE_DICTIONARY:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Each keyframe must be a dictionary")
		if not "time" in kf:
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Each keyframe must have a 'time' field")
		if not "value" in kf:
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Each keyframe must have a 'value' field")
		var coerce_result := AnimationValues.coerce_with_context(kf.get("value"), ctx)
		if coerce_result.has("error"):
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, coerce_result.error)
		coerced_keyframes.append({
			"time": kf.get("time"),
			"value": coerce_result.ok,
			"transition": kf.get("transition", "linear"),
		})

	_create_scene_pinned_action("MCP: Add property track %s to %s" % [track_path, anim_name])
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
## AnimationValues.coerce_value_for_track) — this method runs inside the
## undo do-method path where error propagation isn't possible.
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
		var trans: float = AnimationValues.parse_transition(kf.get("transition", "linear"))
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: animation_name")
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: target_node_path")
	if target_path.contains(":"):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"target_node_path is a bare NodePath without ':property' (got '%s'). " % target_path +
			"Method name goes in each keyframe's 'method' field, not the path.")
	if typeof(keyframes) != TYPE_ARRAY or keyframes.is_empty():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "keyframes must be a non-empty array")

	for kf in keyframes:
		if typeof(kf) != TYPE_DICTIONARY:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Each keyframe must be a dictionary")
		if not "time" in kf:
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Each keyframe must have a 'time' field")
		if not "method" in kf:
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Each keyframe must have a 'method' field")
		var method_field = kf.get("method")
		if typeof(method_field) != TYPE_STRING or (method_field as String).is_empty():
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "'method' must be a non-empty string")
		if kf.has("args") and typeof(kf.get("args")) != TYPE_ARRAY:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"'args' must be an array if provided (got %s)" % type_string(typeof(kf.get("args"))))

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation

	_create_scene_pinned_action("MCP: Add method track %s to %s" % [target_path, anim_name])
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
# animation_add_audio_track
# ============================================================================

func add_audio_track(params: Dictionary) -> Dictionary:
	var player_path = params.get("player_path", "")
	var anim_name = params.get("animation_name", "")
	var target_path = params.get("target_node_path", "")
	var keyframes = params.get("keyframes", [])
	if not (player_path is String and anim_name is String and target_path is String):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "player_path, animation_name and target_node_path must be strings")
	for param: String in ["player_path", "animation_name", "target_node_path"]:
		if params.get(param, "").is_empty():
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: %s" % param)
	var target_node_path := NodePath(target_path)
	if target_node_path.is_absolute() or target_path.contains(":"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"target_node_path must be a relative node path from AnimationPlayer.root_node (got '%s')" % target_path)
	if not keyframes is Array or keyframes.is_empty():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "keyframes must be a non-empty array")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player
	var scene_root := EditorInterface.get_edited_scene_root()
	var anim_resolved := _resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation
	var animation_root := player.get_node_or_null(player.root_node)
	if McpScenePath.from_node(animation_root, scene_root).is_empty():
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			"AnimationPlayer.root_node '%s' at %s must resolve inside the edited scene" % [player.root_node, player_path])
	var target := animation_root.get_node_or_null(target_node_path)
	if McpScenePath.from_node(target, scene_root).is_empty():
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			"target_node_path '%s' must resolve inside the edited scene relative to AnimationPlayer.root_node" % target_path)
	if not (target is AudioStreamPlayer or target is AudioStreamPlayer2D or target is AudioStreamPlayer3D):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"target_node_path '%s' is not an AudioStreamPlayer, AudioStreamPlayer2D or AudioStreamPlayer3D (got %s)" % [target_path, target.get_class()])
	var track_path := animation_root.get_path_to(target)
	for i in anim.get_track_count():
		if anim.track_get_type(i) == Animation.TYPE_AUDIO and animation_root.get_node_or_null(anim.track_get_path(i)) == target:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Animation '%s' already has an audio track for '%s'" % [anim_name, track_path])

	var prepared := _prepare_audio_track(track_path, keyframes)
	if prepared.has("error"):
		return prepared
	if EditorInterface.get_edited_scene_root() != scene_root:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "The edited scene changed while loading audio keyframes")
	var scratch: Animation = prepared.animation
	_create_scene_pinned_action("MCP: Add audio track %s to %s" % [track_path, anim_name])
	_undo_redo.add_do_method(scratch, "copy_track", 0, anim)
	_undo_redo.add_do_reference(scratch)
	_undo_redo.add_undo_method(self, "_undo_remove_track_by_path", anim, String(track_path), Animation.TYPE_AUDIO)
	_undo_redo.commit_action()
	return {"data": {
		"player_path": player_path,
		"animation_name": anim_name,
		"target_node_path": String(track_path),
		"keyframe_count": scratch.track_get_key_count(0),
		"undoable": true,
	}}


static func _prepare_audio_track(track_path: NodePath, keyframes: Array) -> Dictionary:
	var frames: Array[Dictionary] = []
	var streams := {}
	var single_precision := not OS.has_feature("double")
	for i in keyframes.size():
		var key = keyframes[i]
		var prefix := "keyframes[%d]" % i
		if not key is Dictionary:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a dictionary" % prefix)
		if not key.has("time"):
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "%s.time is required" % prefix)
		var frame := {"input_index": i}
		for field: String in ["time", "start_offset", "end_offset"]:
			var value = key.get(field, 0.0)
			if not (value is int or value is float):
				return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s.%s must be a number" % [prefix, field])
			var number := float(value)
			if not is_finite(number) or number < 0.0:
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s.%s must be finite and nonnegative (got %s)" % [prefix, field, number])
			# Godot stores offsets and serializes audio key times as real_t.
			# Build the track at that precision so saving cannot collapse its keys.
			var stored: float = PackedFloat32Array([number])[0] if single_precision else number
			if not is_finite(stored) or (number > 0.0 and stored == 0.0):
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s.%s is outside Godot's audio track precision (got %s)" % [prefix, field, number])
			frame[field] = stored
		var stream_path = key.get("stream_path", "")
		if not stream_path is String:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s.stream_path must be a string" % prefix)
		var path_error = McpPathValidator.path_error(stream_path, prefix + ".stream_path")
		if path_error != null:
			return path_error
		if not streams.has(stream_path):
			if not FileAccess.file_exists(stream_path) or not ResourceLoader.exists(stream_path):
				return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "%s AudioStream not found: %s" % [prefix, stream_path])
			var stream := ResourceLoader.load(stream_path)
			if stream == null:
				return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "%s could not load AudioStream: %s" % [prefix, stream_path])
			if not stream is AudioStream:
				return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s resource at %s is not an AudioStream (got %s)" % [prefix, stream_path, stream.get_class()])
			streams[stream_path] = stream
		frame["stream"] = streams[stream_path]
		frames.append(frame)

	# Use the same time order as copy_track. Native insertion can replace an
	# existing key even for distinct times when they are approximately equal.
	frames.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.time < b.time)
	var scratch := Animation.new()
	var track := scratch.add_track(Animation.TYPE_AUDIO)
	scratch.track_set_path(track, track_path)
	for i in frames.size():
		var frame := frames[i]
		var inserted := scratch.audio_track_insert_key(track, frame.time, frame.stream, frame.start_offset, frame.end_offset)
		if inserted < 0 or scratch.track_get_key_count(track) != i + 1:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"keyframes[%d].time (%s) collides with another audio key in Godot" % [frame.input_index, frame.time])
	return {"animation": scratch}


# ============================================================================
# animation_set_autoplay
# ============================================================================

func set_autoplay(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	# Allow empty string to clear autoplay; otherwise validate the name exists.
	if not anim_name.is_empty() and not player.has_animation(anim_name):
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var resolved := _resolve_player(player_path, false, false)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	if not anim_name.is_empty() and not player.has_animation(anim_name):
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var resolved := _resolve_player(player_path, false, false)
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
# animation_create_simple  (composer)
# ============================================================================

func create_simple(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("name", "")
	var tweens = params.get("tweens", [])
	var loop_mode_str: String = params.get("loop_mode", "none")

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")
	if typeof(tweens) != TYPE_ARRAY or tweens.is_empty():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "tweens must be a non-empty array")
	if not _LOOP_MODES.has(loop_mode_str):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid loop_mode '%s'. Valid: %s" % [loop_mode_str, ", ".join(_LOOP_MODES.keys())])

	# Validate all tween specs before touching the scene.
	var seen_paths := {}
	for spec in tweens:
		if typeof(spec) != TYPE_DICTIONARY:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Each tween spec must be a dictionary")
		for field in ["target", "property", "from", "to", "duration"]:
			if not field in spec:
				return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
					"Each tween spec must have '%s'" % field)
		if float(spec.get("duration", 0.0)) <= 0.0:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"tween 'duration' must be > 0")
		var dup_key: String = str(spec.target) + ":" + str(spec.property)
		if seen_paths.has(dup_key):
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
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
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
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
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
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
		var from_result := AnimationValues.coerce_value_for_track(spec.get("from"), track_path, player, coerce_root)
		if from_result.has("error"):
			if created_player:
				player.queue_free()
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "tween '%s': %s" % [track_path, from_result.error])
		var to_result := AnimationValues.coerce_value_for_track(spec.get("to"), track_path, player, coerce_root)
		if to_result.has("error"):
			if created_player:
				player.queue_free()
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "tween '%s': %s" % [track_path, to_result.error])
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
# Proxies — preset_* and read methods live in the submodules. Kept here so
# the dispatcher registrations and `_handler.method(...)` test fixtures stay
# unchanged across the split.
# ============================================================================

func preset_fade(params: Dictionary) -> Dictionary:
	return _presets.preset_fade(params)


func preset_slide(params: Dictionary) -> Dictionary:
	return _presets.preset_slide(params)


func preset_shake(params: Dictionary) -> Dictionary:
	return _presets.preset_shake(params)


func preset_pulse(params: Dictionary) -> Dictionary:
	return _presets.preset_pulse(params)


func list_animations(params: Dictionary) -> Dictionary:
	return _values.list_animations(params)


func get_animation(params: Dictionary) -> Dictionary:
	return _values.get_animation(params)


func validate_animation(params: Dictionary) -> Dictionary:
	return _values.validate_animation(params)


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


## Open a `create_action` pinned to the edited scene's history.
##
## Without an explicit context, `add_do_method(self, ...)` against a
## RefCounted handler lands in GLOBAL_HISTORY while sibling actions whose
## first do-target is a Resource (e.g. AnimationLibrary) land in the scene's
## history. Mismatched histories make the test-side `editor_undo` helper
## (walks scene first) undo the wrong action, and break batch_handler's
## rollback. Mirrors `camera_handler.gd`'s identical pinning rationale.
func _create_scene_pinned_action(action_label: String) -> void:
	_undo_redo.create_action(
		action_label, UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root(),
	)


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
func _resolve_player(player_path: String, create_if_missing: bool = false, for_write: bool = true) -> Dictionary:
	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root
	var node := McpScenePath.resolve(player_path, scene_root)
	if node == null:
		if not create_if_missing:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_node_error(player_path, scene_root))
		return _instantiate_player(player_path, scene_root)
	if not node is AnimationPlayer:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node at %s is not an AnimationPlayer (got %s)" % [player_path, node.get_class()])
	if for_write:
		var write_error := McpNodeValidator.writable_error(node, scene_root)
		if not write_error.is_empty():
			return write_error
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
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"Cannot auto-create AnimationPlayer: player_path '%s' has no leaf name" % player_path)
	var parent: Node
	if parent_path.is_empty():
		parent = scene_root
	else:
		parent = McpScenePath.resolve(parent_path, scene_root)
	if parent == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			"Cannot auto-create AnimationPlayer at %s: %s" % [
				player_path, McpScenePath.format_parent_error(parent_path, scene_root)])
	var write_error := McpNodeValidator.writable_error(parent, scene_root)
	if not write_error.is_empty():
		return write_error

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


## Resolve for read operations (no library requirement).
func _resolve_player_read(player_path: String) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(player_path, "player_path")
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is AnimationPlayer:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node at %s is not an AnimationPlayer (got %s)" % [player_path, node.get_class()])
	return {"player": node as AnimationPlayer}


## Resolve an animation by name, searching all libraries.
## Accepts bare clip names ("idle") and library-qualified names ("moves/idle")
## as returned by `list_animations` for non-default libraries.
func _resolve_animation(player: AnimationPlayer, anim_name: String) -> Dictionary:
	if not player.has_animation(anim_name):
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
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
	return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Animation found by player but not in any library")


func _resolve_mixer(player_path: String, for_write: bool = false) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(player_path, "player_path", "", for_write)
	if resolved.has("error"):
		return resolved
	if not resolved.node is AnimationMixer:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node at %s is not an AnimationMixer (got %s)" % [player_path, resolved.node.get_class()])
	return resolved


func library_add(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var library_name: String = params.get("library_name", "")
	var resource_path: String = params.get("resource_path", "")
	var path_error = McpPathValidator.loadable_error(resource_path, "resource_path")
	if path_error != null:
		return path_error
	for forbidden in ["/", ":", ",", "["]:
		if library_name.contains(forbidden):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"library_name cannot contain '/', ':', ',' or '['")
	var resolved := _resolve_mixer(player_path, true)
	if resolved.has("error"):
		return resolved
	var mixer: AnimationMixer = resolved.node
	if mixer.has_animation_library(library_name):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"Library '%s' already exists; remove it first." % library_name)
	if not ResourceLoader.exists(resource_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % resource_path)
	var resource := ResourceLoader.load(resource_path)
	if resource == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load resource: %s" % resource_path)
	if not resource is AnimationLibrary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Expected AnimationLibrary at %s (got %s)" % [resource_path, resource.get_class()])
	for existing_name in mixer.get_animation_library_list():
		if mixer.get_animation_library(existing_name) == resource:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Resource is already attached as library '%s'." % existing_name)
	_create_scene_pinned_action("MCP: Add animation library %s" % library_name)
	_undo_redo.add_do_method(mixer, "add_animation_library", library_name, resource)
	_undo_redo.add_undo_method(mixer, "remove_animation_library", library_name)
	_undo_redo.add_do_reference(resource)
	_undo_redo.commit_action()
	return {"data": {
		"player_path": player_path, "library_name": library_name,
		"resource_path": resource.resource_path, "undoable": true,
	}}


func library_remove(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var library_name: String = params.get("library_name", "")
	var resolved := _resolve_mixer(player_path, true)
	if resolved.has("error"):
		return resolved
	var mixer: AnimationMixer = resolved.node
	if not mixer.has_animation_library(library_name):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Library not found: %s" % library_name)
	var library := mixer.get_animation_library(library_name)
	var old_autoplay := ""
	if mixer is AnimationPlayer:
		old_autoplay = String(mixer.autoplay)
	var clears_autoplay: bool = not old_autoplay.is_empty() and (
		(library_name.is_empty() and not old_autoplay.contains("/"))
		or (not library_name.is_empty() and old_autoplay.contains("/") and old_autoplay.get_slice("/", 0) == library_name)
	)
	_create_scene_pinned_action("MCP: Remove animation library %s" % library_name)
	if clears_autoplay:
		_undo_redo.add_do_property(mixer, "autoplay", "")
	_undo_redo.add_do_method(mixer, "remove_animation_library", library_name)
	_undo_redo.add_undo_method(mixer, "add_animation_library", library_name, library)
	if clears_autoplay:
		_undo_redo.add_undo_property(mixer, "autoplay", old_autoplay)
	_undo_redo.add_undo_reference(library)
	_undo_redo.commit_action()
	return {"data": {
		"player_path": player_path, "library_name": library_name,
		"autoplay_cleared": clears_autoplay, "undoable": true,
	}}


func library_list(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var resolved := _resolve_mixer(player_path)
	if resolved.has("error"):
		return resolved
	var mixer: AnimationMixer = resolved.node
	var libraries := library_metadata(mixer)
	var data := {"player_path": player_path, "libraries": libraries, "count": libraries.size()}
	if mixer is AnimationPlayer:
		data["autoplay"] = String(mixer.autoplay)
	return {"data": data}


static func library_metadata(mixer: AnimationMixer) -> Array[Dictionary]:
	var libraries: Array[Dictionary] = []
	for library_name in mixer.get_animation_library_list():
		var library := mixer.get_animation_library(library_name)
		libraries.append({
			"name": String(library_name),
			"resource_path": "" if library.resource_path.contains("::") else library.resource_path,
			"animations": Array(PackedStringArray(library.get_animation_list())),
		})
	return libraries
