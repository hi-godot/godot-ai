@tool
extends McpTestSuite

## Tests for AudioHandler — AudioStreamPlayer / 2D / 3D node authoring,
## stream assignment, playback properties, editor-preview play/stop, and
## audio asset listing.
##
## A silent AudioStreamWAV fixture is generated at runtime (written to
## user://) rather than committing a binary file. Cleaned up by
## suite_teardown.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: AudioHandler
var _undo_redo: EditorUndoRedoManager
var _created_paths: Array[String] = []
var _fixture_path: String = ""


func suite_name() -> String:
	return "audio"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = AudioHandler.new(_undo_redo)
	_fixture_path = _make_fixture()


func suite_teardown() -> void:
	for path in _created_paths:
		_remove_by_path(path)
	_created_paths.clear()
	if not _fixture_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_path))
		_fixture_path = ""


# Build a tiny silent 16-bit mono WAV stream and save it to user://.
# user:// paths are valid res:// surrogates for ResourceLoader but live
# outside the imported asset pipeline, so they don't pollute the project
# or require a reimport cycle.
func _make_fixture() -> String:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.stereo = false
	stream.mix_rate = 22050
	# ~0.1s of silence: 22050Hz * 0.1s * 2 bytes/sample = 4410 bytes
	var silence := PackedByteArray()
	silence.resize(4410)
	silence.fill(0)
	stream.data = silence
	var path := "user://audio_fixture.wav.tres"
	var err := ResourceSaver.save(stream, path)
	if err != OK:
		return ""
	return path


func _remove_by_path(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := ScenePath.resolve(path, scene_root)
	if node != null and node.get_parent() != null:
		node.get_parent().remove_child(node)
		node.queue_free()


func _create(node_name: String, type_str: String = "1d") -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var result := _handler.create_player({
		"parent_path": "/" + scene_root.name,
		"name": node_name,
		"type": type_str,
	})
	if result.has("data"):
		_created_paths.append(result.data.path)
	return result


# ============================================================================
# audio_player_create
# ============================================================================

func test_create_1d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene root — test cannot run")
		return
	var result := _create("TestPlayer1D", "1d")
	assert_has_key(result, "data")
	assert_eq(result.data.class, "AudioStreamPlayer")
	assert_eq(result.data.type, "1d")
	assert_true(result.data.undoable)


func test_create_2d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene root — test cannot run")
		return
	var result := _create("TestPlayer2D", "2d")
	assert_has_key(result, "data")
	assert_eq(result.data.class, "AudioStreamPlayer2D")


func test_create_3d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene root — test cannot run")
		return
	var result := _create("TestPlayer3D", "3d")
	assert_has_key(result, "data")
	assert_eq(result.data.class, "AudioStreamPlayer3D")
	var node := ScenePath.resolve(result.data.path, scene_root) as AudioStreamPlayer3D
	assert_true(node != null, "Created node should resolve as AudioStreamPlayer3D")


func test_create_invalid_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene root — test cannot run")
		return
	var result := _handler.create_player({
		"parent_path": "/" + scene_root.name,
		"name": "BadType",
		"type": "gpu_3d",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_missing_parent() -> void:
	var result := _handler.create_player({
		"parent_path": "/NoSuchParent",
		"name": "Orphan",
		"type": "1d",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ============================================================================
# audio_player_set_stream
# ============================================================================

func test_set_stream_loads_and_assigns() -> void:
	if _fixture_path.is_empty():
		assert_true(false, "Fixture setup failed — cannot test stream loading")
		return
	var r := _create("TestSetStream", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.set_stream({
		"player_path": r.data.path,
		"stream_path": _fixture_path,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.stream_path, _fixture_path)
	assert_true(result.data.undoable)
	# Critical: read back the stored value — must be an AudioStream, not a string.
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(r.data.path, scene_root) as AudioStreamPlayer
	assert_true(node.stream is AudioStream,
		"stream must be AudioStream (got %s)" % type_string(typeof(node.stream)))


func test_set_stream_missing_resource() -> void:
	var r := _create("TestSetStreamMissing", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.set_stream({
		"player_path": r.data.path,
		"stream_path": "res://does_not_exist.ogg",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_stream_wrong_type() -> void:
	# Point to this test script itself — it exists but isn't an AudioStream.
	var r := _create("TestSetStreamWrongType", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.set_stream({
		"player_path": r.data.path,
		"stream_path": "res://tests/test_audio.gd",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_stream_empty_path() -> void:
	var r := _create("TestSetStreamEmpty", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.set_stream({
		"player_path": r.data.path,
		"stream_path": "",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_stream_on_non_player_errors() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene root")
		return
	if _fixture_path.is_empty():
		assert_true(false, "Fixture setup failed")
		return
	var mi := Node3D.new()
	mi.name = "NotAnAudioNode"
	scene_root.add_child(mi)
	mi.owner = scene_root
	var result := _handler.set_stream({
		"player_path": ScenePath.from_node(mi, scene_root),
		"stream_path": _fixture_path,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	mi.get_parent().remove_child(mi)
	mi.queue_free()


# ============================================================================
# audio_player_set_playback
# ============================================================================

func test_set_playback_all_fields() -> void:
	var r := _create("TestPlaybackAll", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.set_playback({
		"player_path": r.data.path,
		"volume_db": -6.0,
		"pitch_scale": 1.25,
		"autoplay": true,
		"bus": "Master",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(r.data.path, scene_root) as AudioStreamPlayer
	assert_true(abs(node.volume_db - (-6.0)) < 0.01)
	assert_true(abs(node.pitch_scale - 1.25) < 0.01)
	assert_eq(node.autoplay, true)
	assert_eq(String(node.bus), "Master")


func test_set_playback_partial_update_leaves_others_unchanged() -> void:
	var r := _create("TestPlaybackPartial", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(r.data.path, scene_root) as AudioStreamPlayer
	var old_pitch := node.pitch_scale
	var old_bus := String(node.bus)
	var result := _handler.set_playback({
		"player_path": r.data.path,
		"volume_db": -12.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.applied, ["volume_db"])
	assert_true(abs(node.volume_db - (-12.0)) < 0.01)
	# Others untouched.
	assert_true(abs(node.pitch_scale - old_pitch) < 0.01)
	assert_eq(String(node.bus), old_bus)


func test_set_playback_empty_rejected() -> void:
	var r := _create("TestPlaybackEmpty", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.set_playback({"player_path": r.data.path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_playback_type_mismatch_rejected() -> void:
	var r := _create("TestPlaybackTypeErr", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	# volume_db must be a number — pass a string and expect rejection.
	var result := _handler.set_playback({
		"player_path": r.data.path,
		"volume_db": "loud",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ============================================================================
# audio_play / audio_stop  (runtime preview — not undoable)
# ============================================================================

func test_play_without_stream_rejected() -> void:
	var r := _create("TestPlayNoStream", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var result := _handler.play({"player_path": r.data.path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_play_and_stop_roundtrip() -> void:
	if _fixture_path.is_empty():
		assert_true(false, "Fixture setup failed")
		return
	var r := _create("TestPlayStop", "1d")
	if r.is_empty():
		assert_true(false, "Player creation failed")
		return
	var set_result := _handler.set_stream({
		"player_path": r.data.path,
		"stream_path": _fixture_path,
	})
	if not set_result.has("data"):
		assert_true(false, "set_stream failed: %s" % str(set_result))
		return
	var play_result := _handler.play({"player_path": r.data.path})
	assert_has_key(play_result, "data")
	assert_eq(play_result.data.undoable, false)
	assert_eq(play_result.data.reason, "Runtime playback state — not saved with scene")
	var stop_result := _handler.stop({"player_path": r.data.path})
	assert_has_key(stop_result, "data")
	assert_eq(stop_result.data.undoable, false)
	assert_eq(stop_result.data.playing, false)


func test_play_missing_player_path() -> void:
	var result := _handler.play({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_stop_missing_player_path() -> void:
	var result := _handler.stop({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ============================================================================
# audio_list
# ============================================================================

func test_list_returns_result() -> void:
	# Basic shape check — the EditorFileSystem may or may not have indexed
	# user:// fixtures depending on scan timing, so we assert on structure,
	# not specific membership.
	var result := _handler.list_streams({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "streams")
	assert_has_key(result.data, "count")


func test_list_include_duration_false_omits_field() -> void:
	# Even if no streams exist in res://, this test verifies the flag is
	# plumbed: we just check the entries (if any) lack duration_seconds.
	var result := _handler.list_streams({"include_duration": false})
	assert_has_key(result, "data")
	for entry in result.data.streams:
		assert_false(entry.has("duration_seconds"),
			"include_duration=false should omit duration_seconds (entry: %s)" % str(entry))


func test_list_filters_by_root() -> void:
	# A non-existent root should yield 0 streams.
	var result := _handler.list_streams({"root": "res://definitely_does_not_exist_xyz/"})
	assert_has_key(result, "data")
	assert_eq(int(result.data.count), 0)


func test_list_rejects_non_res_root() -> void:
	var result := _handler.list_streams({"root": "user://"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
