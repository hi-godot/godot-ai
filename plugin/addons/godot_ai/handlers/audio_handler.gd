@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles AudioStreamPlayer / 2D / 3D authoring — node creation, stream
## assignment, playback-property edits, and real editor preview playback.
##
## Stream assignment loads a Godot-imported AudioStream resource from
## res:// (the editor's import step converts .ogg / .wav / .mp3 into a
## streamable AudioStream subclass before we ever see it).
##
## play() / stop() call the live node method directly — no undo, no
## persistence; they match what the inspector's play button does.


const _VALID_TYPES := {
	"1d": "AudioStreamPlayer",
	"2d": "AudioStreamPlayer2D",
	"3d": "AudioStreamPlayer3D",
}

## Whitelist of playback properties settable via audio_player_set_playback.
## Each value is the expected Variant type of the param dict value.
const _PLAYBACK_KEYS := {
	"volume_db": TYPE_FLOAT,
	"pitch_scale": TYPE_FLOAT,
	"autoplay": TYPE_BOOL,
	"bus": TYPE_STRING,
}


var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# audio_player_create
# ============================================================================

func create_player(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "AudioStreamPlayer")
	var type_str: String = params.get("type", "1d")

	if not _VALID_TYPES.has(type_str):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid audio player type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_player(type_str)
	if node == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate audio player")
	if not node_name.is_empty():
		node.name = node_name

	_undo_redo.create_action("MCP: Create %s '%s'" % [_VALID_TYPES[type_str], node.name])
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
			"name": String(node.name),
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"undoable": true,
		}
	}


# ============================================================================
# audio_player_set_stream
# ============================================================================

func set_stream(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var stream_path: String = params.get("stream_path", "")

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if stream_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: stream_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: Node = resolved.player

	if not ResourceLoader.exists(stream_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "AudioStream not found: %s" % stream_path)
	var loaded := ResourceLoader.load(stream_path)
	if loaded == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load AudioStream: %s" % stream_path)
	if not (loaded is AudioStream):
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Resource at %s is not an AudioStream (got %s)" % [stream_path, loaded.get_class()]
		)

	var old_stream: AudioStream = player.stream

	_undo_redo.create_action("MCP: Set audio stream on %s" % player.name)
	_undo_redo.add_do_property(player, "stream", loaded)
	_undo_redo.add_undo_property(player, "stream", old_stream)
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"stream_path": stream_path,
			"stream_class": loaded.get_class(),
			"duration_seconds": float(loaded.get_length()),
			"undoable": true,
		}
	}


# ============================================================================
# audio_player_set_playback
# ============================================================================

func set_playback(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: Node = resolved.player

	var updates: Dictionary = {}
	for key in _PLAYBACK_KEYS:
		if params.has(key):
			var expected_type: int = _PLAYBACK_KEYS[key]
			var value = params.get(key)
			var coerced = _coerce_playback_value(value, expected_type)
			if coerced == null:
				return ErrorCodes.make(
					ErrorCodes.INVALID_PARAMS,
					"Invalid value for %s: expected %s, got %s" % [
						key, type_string(expected_type), type_string(typeof(value))
					]
				)
			updates[key] = coerced

	if updates.is_empty():
		return ErrorCodes.make(
			ErrorCodes.MISSING_REQUIRED_PARAM,
			"At least one of %s is required" % ", ".join(_PLAYBACK_KEYS.keys())
		)

	var old_values: Dictionary = {}
	for key in updates:
		old_values[key] = player.get(key)

	_undo_redo.create_action("MCP: Update playback on %s" % player.name)
	for key in updates:
		_undo_redo.add_do_property(player, key, updates[key])
		_undo_redo.add_undo_property(player, key, old_values[key])
	_undo_redo.commit_action()

	return {
		"data": {
			"player_path": player_path,
			"applied": updates.keys(),
			"values": updates,
			"undoable": true,
		}
	}


# ============================================================================
# audio_play  (runtime preview — not saved with scene)
# ============================================================================

func play(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var from_position: float = float(params.get("from_position", 0.0))

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: Node = resolved.player

	if player.stream == null:
		return ErrorCodes.make(
			ErrorCodes.MISSING_REQUIRED_PARAM,
			"Player has no stream assigned — call audio_player_set_stream first"
		)

	player.play(from_position)

	return {
		"data": {
			"player_path": player_path,
			"from_position": from_position,
			"playing": bool(player.playing),
			"undoable": false,
			"reason": "Runtime playback state — not saved with scene",
		}
	}


# ============================================================================
# audio_stop  (runtime preview — not saved with scene)
# ============================================================================

func stop(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var resolved := _resolve_player(player_path)
	if resolved.has("error"):
		return resolved
	var player: Node = resolved.player

	player.stop()

	return {
		"data": {
			"player_path": player_path,
			"playing": bool(player.playing),
			"undoable": false,
			"reason": "Runtime playback state — not saved with scene",
		}
	}


# ============================================================================
# audio_list  (read — scan project for AudioStream resources)
# ============================================================================

func list_streams(params: Dictionary) -> Dictionary:
	var root: String = params.get("root", "res://")
	var include_duration: bool = bool(params.get("include_duration", true))

	if not root.begins_with("res://"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "root must start with res://")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "EditorFileSystem not available")

	var results: Array[Dictionary] = []
	var start_dir := efs.get_filesystem_path(root)
	if start_dir == null:
		start_dir = efs.get_filesystem()
	_scan_audio(start_dir, root, include_duration, results)
	return {
		"data": {
			"root": root,
			"streams": results,
			"count": results.size(),
		}
	}


func _scan_audio(dir: EditorFileSystemDirectory, root: String, include_duration: bool, out: Array[Dictionary]) -> void:
	if dir == null:
		return
	for i in dir.get_file_count():
		var file_path := dir.get_file_path(i)
		if not file_path.begins_with(root):
			continue
		var file_type := dir.get_file_type(i)
		var is_audio := file_type == "AudioStream" or ClassDB.is_parent_class(file_type, "AudioStream")
		if not is_audio:
			continue
		var entry: Dictionary = {
			"path": file_path,
			"class": file_type,
		}
		if include_duration:
			var res := ResourceLoader.load(file_path)
			if res is AudioStream:
				entry["duration_seconds"] = float((res as AudioStream).get_length())
			else:
				entry["duration_seconds"] = 0.0
		out.append(entry)
	for i in dir.get_subdir_count():
		_scan_audio(dir.get_subdir(i), root, include_duration, out)


# ============================================================================
# Helpers
# ============================================================================

static func _instantiate_player(type_str: String) -> Node:
	match type_str:
		"1d":
			return AudioStreamPlayer.new()
		"2d":
			return AudioStreamPlayer2D.new()
		"3d":
			return AudioStreamPlayer3D.new()
	return null


func _resolve_player(player_path: String) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(player_path, "player_path")
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var is_player := node is AudioStreamPlayer \
		or node is AudioStreamPlayer2D \
		or node is AudioStreamPlayer3D
	if not is_player:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Node at %s is not an AudioStreamPlayer/2D/3D (got %s)" % [player_path, node.get_class()]
		)
	return {"player": node}


## Coerce a playback param value to the expected type. int→float is allowed
## so JSON integers pass through; everything else requires the exact type.
## Returns the coerced value, or null on type mismatch.
static func _coerce_playback_value(value: Variant, expected_type: int) -> Variant:
	match expected_type:
		TYPE_FLOAT:
			if value is float or value is int:
				return float(value)
		TYPE_BOOL:
			if value is bool:
				return value
		TYPE_STRING:
			if value is String:
				return value
	return null
