@tool
extends McpTestSuite

const AudioHandler := preload("res://addons/godot_ai/handlers/audio_handler.gd")
const WAV := "res://tests/fixtures/import_settings.wav"

var _handler: AudioHandler
var _directory: String
var _score: String
var _audio_fixtures: Array[String] = []


func suite_name() -> String:
	return "interactive_music"


func suite_setup(ctx: Dictionary) -> void:
	_handler = AudioHandler.new(ctx.get("undo_redo"))
	_directory = "res://interactive_music_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_absolute(ProjectSettings.globalize_path(_directory)) != OK:
		fail_setup("Could not create the temporary score directory")


func setup() -> void:
	_score = _directory.path_join("score_%d.tres" % Time.get_ticks_usec())


func teardown() -> void:
	if FileAccess.file_exists(_score):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_score))
	for path in _audio_fixtures:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_audio_fixtures.clear()


func suite_teardown() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_directory))


func _clips() -> Array:
	return [{"name": "Explore", "stream_path": WAV}, {"name": "Combat", "stream_path": WAV}]


func _clips_with_filler(path: String, music_path: String = WAV) -> Array:
	return [
		{"name": "Explore", "stream_path": music_path},
		{"name": "Combat", "stream_path": music_path},
		{"name": "Fill", "stream_path": path},
	]


func _save_audio_fixture(stream: AudioStream) -> String:
	var path := _directory.path_join("audio_%d.res" % Time.get_ticks_usec())
	assert_eq(ResourceSaver.save(stream, path), OK)
	_audio_fixtures.append(path)
	return path


func _silent_mp3() -> AudioStreamMP3:
	# Valid silent MPEG-1 Layer III frames, 128 kbps mono at 44.1 kHz.
	var frame := PackedByteArray([0xFF, 0xFB, 0x90, 0xC0])
	frame.resize(417)
	var frames := PackedByteArray()
	for i in 30:
		frames.append_array(frame)
	return AudioStreamMP3.load_from_buffer(frames)


func _reject(params: Dictionary, message_fragment: String = "") -> void:
	var spec := {"path": _score, "clips": _clips()}
	spec.merge(params, true)
	var result := _handler.interactive_create(spec)
	assert_is_error(result, "", str(params))
	if result.has("error") and not message_fragment.is_empty():
		assert_contains(result.error.message, message_fragment)
	assert_false(FileAccess.file_exists(_score), "An invalid score was written")


func test_reload_native_score_and_inspect_defaults() -> void:
	var result := _handler.interactive_create({
		"path": _score, "clips": _clips(), "transitions": [{"from": "Explore", "to": "Combat"}],
	})
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_false(result.data.undoable)
	var native := ResourceLoader.load(_score, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStreamInteractive
	assert_true(native != null)
	if native == null:
		return
	assert_eq(native.clip_count, 2)
	assert_eq(native.get_clip_name(native.initial_clip), &"Explore")
	assert_eq(native.get_clip_stream(1).resource_path, WAV)
	assert_true(native.has_transition(0, 1))
	assert_false(native.has_transition(1, 0))
	var inspected := _handler.interactive_get({"path": _score})
	assert_has_key(inspected, "data")
	if not inspected.has("data"):
		return
	assert_eq(inspected.data.initial_clip, "Explore")
	assert_eq(inspected.data.clips[1].name, "Combat")
	assert_eq(inspected.data.clips[1].stream_path, WAV)
	var rule: Dictionary = inspected.data.transitions[0]
	assert_eq(rule.from, "Explore")
	assert_eq(rule.to, "Combat")
	assert_eq(rule.when, "immediate")
	assert_eq(rule.start_at, "start")
	assert_eq(rule.fade, "disabled")


func test_transition_filler_persists_natively_and_preserves_other_rules() -> void:
	var music := _silent_mp3()
	assert_true(music != null)
	if music == null:
		return
	music.bpm = 120.0
	var music_path := _save_audio_fixture(music)
	var filler := AudioStreamWAV.new()
	filler.mix_rate = 8000
	var silence := PackedByteArray()
	silence.resize(2000)
	filler.data = silence
	var filler_path := _save_audio_fixture(filler)
	var result := _handler.interactive_create({
		"path": _score, "clips": _clips_with_filler(filler_path, music_path),
		"transitions": [
			{"from": "Explore", "to": "Combat", "filler_clip": "Fill", "fade": "in"},
			{"from": "Combat", "to": "Explore", "filler_clip": "Fill", "fade": "cross"},
			{"from": "Fill", "to": "Explore"},
		],
	})
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(result.data.transitions[0].filler_clip, "Fill")
	var score := ResourceLoader.load(_score, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as AudioStreamInteractive
	assert_true(score != null)
	if score == null:
		return
	assert_true(score.is_transition_using_filler_clip(0, 1))
	assert_eq(score.get_transition_filler_clip(0, 1), 2)
	assert_eq(score.get_transition_fade_mode(0, 1), AudioStreamInteractive.FADE_IN)
	assert_eq(score.get_clip_stream(2).resource_path, filler_path)
	assert_true(score.is_transition_using_filler_clip(1, 0))
	assert_eq(score.get_transition_fade_mode(1, 0), AudioStreamInteractive.FADE_CROSS)
	assert_true(score.has_transition(2, 0))
	assert_false(score.is_transition_using_filler_clip(2, 0))
	var inspected := _handler.interactive_get({"path": _score})
	assert_has_key(inspected, "data")
	if inspected.has("data"):
		assert_eq(inspected.data.transitions[0].filler_clip, "Fill")
		assert_eq(inspected.data.transitions[0].when, "immediate")
		assert_eq(inspected.data.transitions[0].fade, "in")
		assert_eq(inspected.data.transitions[1].fade, "cross")
		assert_eq(inspected.data.transitions[2].fade, "disabled")
		assert_false(inspected.data.transitions[2].has("filler_clip"))


func test_transition_filler_requires_explicit_destination_fade() -> void:
	var rule := {"from": "Explore", "to": "Combat", "filler_clip": "Fill"}
	for options in [{}, {"fade": "disabled"}, {"fade": "out"}]:
		_reject(
			{"clips": _clips_with_filler(WAV), "transitions": [rule.merged(options)]},
			"one-second destination fade"
		)


func test_transition_filler_must_name_a_distinct_existing_clip() -> void:
	for name in ["Explore", "Combat"]:
		_reject(
			{"transitions": [{"from": "Explore", "to": "Combat", "filler_clip": name, "fade": "in"}]},
			"distinct from both transition endpoints"
		)
	for name in ["", "Unknown", null, 2]:
		_reject(
			{"transitions": [{"from": "Explore", "to": "Combat", "filler_clip": name, "fade": "in"}]},
			"filler_clip"
		)


func test_transition_filler_requires_supported_non_looping_audio_with_duration() -> void:
	var rule := {"from": "Explore", "to": "Combat", "filler_clip": "Fill", "fade": "in"}
	var generator_path := _save_audio_fixture(AudioStreamGenerator.new())
	_reject({"clips": _clips_with_filler(generator_path), "transitions": [rule]}, "WAV, Ogg Vorbis, or MP3")
	var empty_ogg_path := _save_audio_fixture(AudioStreamOggVorbis.new())
	_reject({"clips": _clips_with_filler(empty_ogg_path), "transitions": [rule]}, "finite positive duration")
	var wav := AudioStreamWAV.new()
	var empty_path := _save_audio_fixture(wav)
	_reject({"clips": _clips_with_filler(empty_path), "transitions": [rule]}, "finite positive duration")
	wav.data = PackedByteArray([0, 0, 0, 0])
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = 4
	var looping_path := _save_audio_fixture(wav)
	_reject({"clips": _clips_with_filler(looping_path), "transitions": [rule]}, "disable looping")


func test_transition_filler_uses_positive_native_beat_duration() -> void:
	var mp3 := _silent_mp3()
	assert_true(mp3 != null)
	if mp3 == null:
		return
	assert_gt(mp3.get_length(), 0.5)
	var rule := {"from": "Explore", "to": "Combat", "filler_clip": "Fill", "fade": "cross"}
	mp3.beat_count = 1
	mp3.bpm = 1.0e-39
	var invalid_path := _save_audio_fixture(mp3)
	_reject({"clips": _clips_with_filler(invalid_path), "transitions": [rule]}, "finite positive delay")
	mp3.bpm = 120.0
	var valid_path := _save_audio_fixture(mp3)
	var result := _handler.interactive_create({
		"path": _score, "clips": _clips_with_filler(valid_path, valid_path), "transitions": [rule],
	})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.transitions[0].filler_clip, "Fill")
		assert_eq(result.data.clips[2].bpm, 120.0)


func test_existing_destination_preserves_initial_clip_and_bytes() -> void:
	var result := _handler.interactive_create({"path": _score, "clips": _clips(), "initial_clip": "Combat"})
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	var original := FileAccess.get_sha256(_score)
	assert_is_error(_handler.interactive_create({"path": _score, "clips": _clips()}))
	assert_eq(FileAccess.get_sha256(_score), original)
	var native := ResourceLoader.load(_score, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStreamInteractive
	assert_true(native != null)
	if native != null:
		assert_eq(native.get_clip_name(native.initial_clip), &"Combat")


func test_inspection_reads_disk_and_preserves_unsaved_resource() -> void:
	var result := _handler.interactive_create({"path": _score, "clips": _clips()})
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	var open_score := ResourceLoader.load(_score) as AudioStreamInteractive
	open_score.initial_clip = 1
	var inspected := _handler.interactive_get({"path": _score})
	assert_has_key(inspected, "data")
	if inspected.has("data"):
		assert_eq(inspected.data.initial_clip, "Explore")
	assert_eq(open_score.initial_clip, 1)


func test_validate_names_assets_and_destination() -> void:
	_reject({"clips": []})
	var too_many: Array = []
	for i in 64:
		too_many.append({"name": "Clip%d" % i, "stream_path": WAV})
	_reject({"clips": too_many}, "63")
	_reject({"clips": [_clips()[0], _clips()[0]]})
	_reject({"clips": [{"name": "", "stream_path": WAV}]})
	_reject({"clips": [{"name": "Music", "stream_path": _directory.path_join("missing.ogg")}]})
	_reject({"clips": [{"name": "Music", "stream_path": "res://tests/test_audio.gd"}]})
	_reject({"initial_clip": "Unknown"})
	var missing_dir := _directory.path_join("missing")
	_reject({"path": missing_dir.path_join("score.tres")})
	assert_false(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(missing_dir)))
	var wrong_extension := _directory.path_join("score.res")
	_reject({"path": wrong_extension})
	assert_false(FileAccess.file_exists(wrong_extension))


func test_validate_transitions_before_saving() -> void:
	var rule := {"from": "Explore", "to": "Combat"}
	_reject({"transitions": [rule, rule]})
	_reject({"transitions": [rule.merged({"from": "Unknown"}, true)]})
	_reject({"transitions": [rule.merged({"to": "Unknown"}, true)]})
	_reject({"transitions": [rule.merged({"when": "next_hour"})]})
	_reject({"transitions": [rule.merged({"start_at": "offset"})]})
	_reject({"transitions": [rule.merged({"fade": "linear"})]})
	_reject({"transitions": [rule.merged({"when": "end", "start_at": "same_position"})]}, "start_at")
	for beats in [0, -0.5, INF, NAN, "two", true]:
		_reject({"transitions": [rule.merged({"fade": "cross", "fade_beats": beats})]}, "fade_beats")


func test_tempo_dependent_rules_require_outgoing_tempo() -> void:
	var original := FileAccess.get_sha256(WAV)
	var rule := {"from": "Explore", "to": "Combat"}
	for timing in [{"when": "next_beat"}, {"when": "next_bar"}, {"fade": "cross"}]:
		_reject({"transitions": [rule.merged(timing)]}, "import_get")
	assert_eq(FileAccess.get_sha256(WAV), original)


func test_inspect_requires_an_interactive_resource() -> void:
	assert_is_error(_handler.interactive_get({"path": WAV}))
	assert_is_error(_handler.interactive_get({"path": _score}))


func test_inspect_preserves_native_wildcard_and_advanced_rules() -> void:
	var score := AudioStreamInteractive.new()
	var names := [&"Explore", &"Combat", &"Fill"]
	score.clip_count = names.size()
	for i in score.clip_count:
		score.set_clip_name(i, names[i])
		score.set_clip_stream(i, load(WAV))
	score.add_transition(AudioStreamInteractive.CLIP_ANY, 1,
		AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BEAT,
		AudioStreamInteractive.TRANSITION_TO_TIME_PREVIOUS_POSITION,
		AudioStreamInteractive.FADE_AUTOMATIC, 0.5, true, 0, true)
	score.add_transition(0, 1,
		AudioStreamInteractive.TRANSITION_FROM_TIME_IMMEDIATE,
		AudioStreamInteractive.TRANSITION_TO_TIME_START,
		AudioStreamInteractive.FADE_OUT, 0.5, true, 2)
	assert_eq(ResourceSaver.save(score, _score), OK)
	var result := _handler.interactive_get({"path": _score})
	assert_has_key(result, "data")
	if result.has("data"):
		var rule: Dictionary = result.data.transitions[0]
		assert_eq(rule.from, "*")
		assert_eq(rule.to, "Combat")
		assert_eq(rule.start_at, "previous_position")
		assert_eq(rule.fade, "automatic")
		assert_eq(rule.fade_beats, 0.5)
		assert_eq(rule.filler_clip, "Explore")
		assert_true(rule.hold_previous)
		assert_eq(result.data.transitions[1].fade, "out")
		assert_eq(result.data.transitions[1].filler_clip, "Fill")


func test_preview_requires_a_playing_interactive_player() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("Requires an open scene for preview players")
		return
	var result := _handler.interactive_create({"path": _score, "clips": _clips()})
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	var score := ResourceLoader.load(_score) as AudioStreamInteractive
	for player: Node in [AudioStreamPlayer.new(), AudioStreamPlayer2D.new(), AudioStreamPlayer3D.new()]:
		track(player)
		root.add_child(player, true)
		var params := {"player_path": McpScenePath.from_node(player, root), "clip": "Combat"}
		player.set("stream", score)
		assert_is_error(_handler.interactive_switch(params))
		player.set("stream", load(WAV))
		player.call("play")
		assert_is_error(_handler.interactive_switch(params))
