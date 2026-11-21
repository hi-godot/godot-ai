@tool
extends RefCounted

## Native AudioStreamInteractive resource construction and inspection.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MAX_CLIPS := 63 # AudioStreamInteractive's native clip limit.
const WHEN := {
	"immediate": AudioStreamInteractive.TRANSITION_FROM_TIME_IMMEDIATE,
	"next_beat": AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BEAT,
	"next_bar": AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BAR,
	"end": AudioStreamInteractive.TRANSITION_FROM_TIME_END,
}
const START_AT := {
	"start": AudioStreamInteractive.TRANSITION_TO_TIME_START,
	"same_position": AudioStreamInteractive.TRANSITION_TO_TIME_SAME_POSITION,
	"previous_position": AudioStreamInteractive.TRANSITION_TO_TIME_PREVIOUS_POSITION,
}
const FADE := {
	"disabled": AudioStreamInteractive.FADE_DISABLED,
	"in": AudioStreamInteractive.FADE_IN,
	"out": AudioStreamInteractive.FADE_OUT,
	"cross": AudioStreamInteractive.FADE_CROSS,
	"automatic": AudioStreamInteractive.FADE_AUTOMATIC,
}


static func create(params: Dictionary, connection: McpConnection) -> Dictionary:
	var error: Variant = _fields_error(
		params, ["path", "clips", "initial_clip", "transitions", "_request_id"], "interactive_create"
	)
	if error != null:
		return error
	var path: Variant = params.get("path", "")
	if not path is String:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "path must be a string")
	error = McpPathValidator.path_error(path, "path", true)
	if error != null:
		return error
	if path.get_extension() != "tres" or path.contains("::"):
		return _invalid("path", "expected a new .tres file beneath res://, got '%s'" % path)
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return _invalid("path", "parent directory must already exist: %s" % path.get_base_dir())
	if (
		FileAccess.file_exists(path)
		or DirAccess.dir_exists_absolute(path)
		or FileAccess.file_exists(path + ".import")
	):
		return _invalid("path", "choose a fresh destination; '%s' is already in use" % path)

	var clips: Variant = params.get("clips", [])
	if not clips is Array or clips.is_empty() or clips.size() > MAX_CLIPS:
		return _invalid("clips", "provide an ordered array of 1–%d named clips" % MAX_CLIPS)
	var interactive := AudioStreamInteractive.new()
	interactive.clip_count = clips.size()
	var indices := {}
	var loaded_streams := {}
	for i in clips.size():
		var location := "clips[%d]" % i
		var entry: Variant = clips[i]
		error = _fields_error(entry, ["name", "stream_path"], location)
		if error != null:
			return error
		var name: Variant = entry.get("name")
		if not name is String or not _valid_clip_name(name):
			return _invalid(location + ".name", "use a nonempty clip name without commas, control characters, surrounding whitespace, or the reserved wildcard '*'")
		if indices.has(name):
			return _invalid(location + ".name", "duplicate clip name '%s'" % name)
		var stream_path: Variant = entry.get("stream_path", "")
		if not loaded_streams.has(stream_path):
			var loaded := _load_audio(stream_path, location + ".stream_path", ResourceLoader.CACHE_MODE_IGNORE)
			if loaded.has("error"):
				return loaded
			loaded_streams[stream_path] = loaded.stream
		indices[name] = i
		interactive.set_clip_name(i, name)
		interactive.set_clip_stream(i, loaded_streams[stream_path])

	var initial: Variant = params.get("initial_clip", interactive.get_clip_name(0))
	if not (initial is String or initial is StringName) or not indices.has(String(initial)):
		return _invalid("initial_clip", "unknown clip '%s'" % [initial])
	interactive.initial_clip = indices[String(initial)]

	var transitions: Variant = params.get("transitions", [])
	if not transitions is Array:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "transitions must be an array")
	for i in transitions.size():
		error = _add_transition(interactive, indices, transitions[i], "transitions[%d]" % i)
		if error != null:
			return error

	# Stage through the shared resource saver, which also embeds a fresh UID,
	# registers the file with the editor and protects against save re-entry.
	return McpResourceIO.save_to_disk(
		interactive, path, false, "AudioStreamInteractive", _describe(interactive, path),
		connection, false, true
	)


static func inspect(params: Dictionary) -> Dictionary:
	var path: Variant = params.get("path", "")
	var loaded := _load_audio(path, "path", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if loaded.has("error"):
		return loaded
	var interactive := loaded.stream as AudioStreamInteractive
	if interactive == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s is not an AudioStreamInteractive (got %s)" % [path, loaded.stream.get_class()])
	return {"data": _describe(interactive, path)}


static func _valid_clip_name(name: String) -> bool:
	if name.is_empty() or name == "*" or name != name.strip_edges() or name.contains(","):
		return false
	for i in name.length():
		var codepoint := name.unicode_at(i)
		if codepoint < 32 or codepoint == 127:
			return false
	return true


static func _fields_error(entry: Variant, allowed: Array, location: String) -> Variant:
	if not entry is Dictionary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be an object" % location)
	for key in entry:
		if key not in allowed:
			return _invalid(location, "unknown field '%s'" % [key])
	return null


static func _load_audio(path: Variant, location: String, cache_mode: ResourceLoader.CacheMode) -> Dictionary:
	if not path is String:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a string" % location)
	var error: Variant = McpPathValidator.path_error(path, location)
	if error != null:
		return error
	if path.contains("::"):
		return _invalid(location, "expected an external project AudioStream file, got '%s'" % path)
	if not FileAccess.file_exists(path) or not ResourceLoader.exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "%s: no imported AudioStream at %s" % [location, path])
	var resource := ResourceLoader.load(path, "", cache_mode)
	if not resource is AudioStream:
		var found := resource.get_class() if resource != null else "unloadable resource"
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s: expected AudioStream at %s, got %s" % [location, path, found])
	return {"stream": resource}


static func _add_transition(interactive: AudioStreamInteractive, indices: Dictionary, entry: Variant, location: String) -> Variant:
	var error: Variant = _fields_error(entry, ["from", "to", "when", "start_at", "fade", "fade_beats"], location)
	if error != null:
		return error
	var pair := Vector2i()
	for field in ["from", "to"]:
		var name: Variant = entry.get(field)
		if not name is String or not indices.has(name):
			return _invalid(location + "." + field, "unknown clip '%s'" % [name])
		pair[0 if field == "from" else 1] = indices[name]
	if pair.x == pair.y or interactive.has_transition(pair.x, pair.y):
		return _invalid(location, "provide one rule per directed pair of distinct clips: '%s' to '%s'" % [entry["from"], entry.to])

	var when: Variant = entry.get("when", "immediate")
	var start_at: Variant = entry.get("start_at", "start")
	var fade: Variant = entry.get("fade", "disabled")
	if not when is String or not WHEN.has(when):
		return _invalid(location + ".when", "expected immediate, next_beat, next_bar, or end, got '%s'" % [when])
	if not start_at is String or start_at not in ["start", "same_position"]:
		return _invalid(location + ".start_at", "expected start or same_position, got '%s'" % [start_at])
	if not fade is String or fade not in ["disabled", "in", "out", "cross"]:
		return _invalid(location + ".fade", "expected disabled, in, out, or cross, got '%s'" % [fade])
	if when == "end" and start_at == "same_position":
		return _invalid(location + ".start_at", "Godot starts the destination at zero for end transitions; use start")

	var beats: Variant = entry.get("fade_beats", 1.0)
	if not (beats is int or beats is float) or not is_finite(float(beats)) or float(beats) <= 0.0:
		return _invalid(location + ".fade_beats", "expected a finite positive number, got '%s'" % [beats])
	var stored_beats := _engine_float(float(beats))
	if not is_finite(stored_beats) or stored_beats <= 0.0:
		return _invalid(location + ".fade_beats", "duration is outside Godot's supported range")

	var outgoing := interactive.get_clip_stream(pair.x)
	if when == "end":
		error = _end_error(outgoing, location)
		if error != null:
			return error
	if when in ["next_beat", "next_bar"] or fade != "disabled":
		var bpm := _engine_float(_bpm(outgoing))
		var meter := _beats_per_bar(outgoing)
		if not is_finite(bpm) or bpm <= 0.0 or (when == "next_bar" and meter <= 0):
			return _invalid(
				location,
				"outgoing clip '%s' (%s) needs positive BPM%s. Use an Ogg Vorbis or MP3 stream. "
				% [entry["from"], outgoing.resource_path, " and Bar Beats" if when == "next_bar" else ""]
				+ "Configure its metadata through Advanced Import Settings and reimport, or use "
				+ "filesystem_manage import_get followed by import_set with expected_revision."
			)
		var beat_seconds := _engine_float(60.0 / bpm)
		if not is_finite(beat_seconds) or beat_seconds <= 0.0:
			return _invalid(location, "outgoing BPM is outside Godot's supported timing range")
		if when == "next_bar" and not is_finite(_engine_float(beat_seconds * meter)):
			return _invalid(location, "outgoing bar duration is outside Godot's supported timing range")
		if fade != "disabled":
			var fade_seconds := _engine_float(stored_beats * beat_seconds)
			if fade_seconds <= 0.0 or not is_finite(fade_seconds) or not is_finite(_engine_float(1.0 / fade_seconds)):
				return _invalid(location + ".fade_beats", "fade duration is outside Godot's supported timing range")
	interactive.add_transition(pair.x, pair.y, WHEN[when], START_AT[start_at], FADE[fade], stored_beats)
	return null


static func _end_error(stream: AudioStream, location: String) -> Variant:
	var length := _engine_float(stream.get_length())
	if not is_finite(length) or length <= 0.0:
		return _invalid(location, "end requires an outgoing clip with a known positive duration")
	if not ClassDB.class_has_method(stream.get_class(), &"get_beat_count"):
		return null
	var count := int(stream.call(&"get_beat_count"))
	var bpm := _bpm(stream)
	if count <= 0 or bpm == 0.0:
		return null
	var engine_bpm := _engine_float(bpm)
	if engine_bpm <= 0.0 or not is_finite(engine_bpm):
		return _invalid(location, "outgoing BPM is outside Godot's supported timing range")
	var beat_end := _engine_float(_engine_float(60.0 / engine_bpm) * count)
	if not is_finite(beat_end) or beat_end <= 0.0:
		return _invalid(location, "outgoing beat end is outside Godot's supported timing range")
	var loops: bool = stream.has_method(&"has_loop") and bool(stream.call(&"has_loop"))
	if beat_end < length and not loops:
		return _invalid(
			location,
			"outgoing clip %s has a Beat Count that ends before its non-looping audio. "
			% stream.resource_path
			+ "Adjust Beat Count in Advanced Import Settings and reimport, or choose a different transition time."
		)
	return null


## Native transition values and timing arithmetic use 32-bit floats.
static func _engine_float(value: float) -> float:
	return PackedFloat32Array([value])[0]


static func _bpm(stream: AudioStream) -> float:
	if stream == null or not ClassDB.class_has_method(stream.get_class(), &"get_bpm"):
		return 0.0
	var value := float(stream.call(&"get_bpm"))
	return value if is_finite(value) else 0.0


static func _beats_per_bar(stream: AudioStream) -> int:
	if stream == null or not ClassDB.class_has_method(stream.get_class(), &"get_bar_beats"):
		return 0
	return int(stream.call(&"get_bar_beats"))


static func _describe(interactive: AudioStreamInteractive, path: String) -> Dictionary:
	var clips: Array[Dictionary] = []
	for i in interactive.clip_count:
		var stream := interactive.get_clip_stream(i)
		var clip := {
			"name": String(interactive.get_clip_name(i)),
			"stream_path": stream.resource_path if stream != null else null,
			"bpm": _bpm(stream),
			"beats_per_bar": _beats_per_bar(stream),
		}
		match interactive.get_clip_auto_advance(i):
			AudioStreamInteractive.AUTO_ADVANCE_ENABLED:
				clip["auto_advance"] = "enabled"
				clip["next_clip"] = clip_name(interactive, interactive.get_clip_auto_advance_next_clip(i))
			AudioStreamInteractive.AUTO_ADVANCE_RETURN_TO_HOLD:
				clip["auto_advance"] = "return_to_hold"
		clips.append(clip)

	var raw := interactive.get_transition_list()
	var pairs: Array[Vector2i] = []
	for i in range(0, raw.size(), 2):
		pairs.append(Vector2i(raw[i], raw[i + 1]))
	pairs.sort()
	var transitions: Array[Dictionary] = []
	for pair in pairs:
		var beats := interactive.get_transition_fade_beats(pair.x, pair.y)
		var rule := {
			"from": "*" if pair.x == AudioStreamInteractive.CLIP_ANY else clip_name(interactive, pair.x),
			"to": "*" if pair.y == AudioStreamInteractive.CLIP_ANY else clip_name(interactive, pair.y),
			"when": WHEN.find_key(interactive.get_transition_from_time(pair.x, pair.y)),
			"start_at": START_AT.find_key(interactive.get_transition_to_time(pair.x, pair.y)),
			"fade": FADE.find_key(interactive.get_transition_fade_mode(pair.x, pair.y)),
			"fade_beats": beats if is_finite(beats) else null,
		}
		if pair.x == AudioStreamInteractive.CLIP_ANY:
			rule["from_any"] = true
		if pair.y == AudioStreamInteractive.CLIP_ANY:
			rule["to_any"] = true
		if interactive.is_transition_using_filler_clip(pair.x, pair.y):
			rule["filler_clip"] = clip_name(interactive, interactive.get_transition_filler_clip(pair.x, pair.y))
		if interactive.is_transition_holding_previous(pair.x, pair.y):
			rule["hold_previous"] = true
		transitions.append(rule)
	return {
		"path": path,
		"type": "AudioStreamInteractive",
		"initial_clip": clip_name(interactive, interactive.initial_clip),
		"clips": clips,
		"transitions": transitions,
	}


static func clip_name(interactive: AudioStreamInteractive, index: int) -> Variant:
	if index < 0 or index >= interactive.clip_count:
		return null
	return String(interactive.get_clip_name(index))


static func _invalid(location: String, message: String) -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s: %s" % [location, message])
