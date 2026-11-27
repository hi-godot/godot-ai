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


func test_wildcard_transitions_round_trip_all_four_native_rules_in_either_order() -> void:
	var music := _silent_mp3()
	assert_true(music != null)
	if music == null:
		return
	music.bpm = 120.0
	var clips := _clips()
	var timed_path := _save_audio_fixture(music)
	clips[0]["stream_path"] = timed_path
	_reject({
		"clips": clips, "transitions": [{"from": "*", "to": "*", "when": "next_bar"}],
	}, "effective transition 'Combat' to 'Explore'")
	clips[0]["stream_path"] = WAV
	clips[1]["stream_path"] = timed_path
	var rules := [
		{"from": "*", "to": "*", "when": "next_beat"},
		{"from": "*", "to": "Combat", "when": "next_bar"},
		{"from": "Explore", "to": "*"},
		{"from": "Explore", "to": "Combat", "when": "end"},
	]
	const ANY := AudioStreamInteractive.CLIP_ANY
	var second := _directory.path_join("score_reversed_%d.tres" % Time.get_ticks_usec())
	_audio_fixtures.append(second)
	for path in [_score, second]:
		var created := _handler.interactive_create({"path": path, "clips": clips, "transitions": rules})
		assert_has_key(created, "data")
		if not created.has("data"):
			return
		var native := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as AudioStreamInteractive
		assert_true(native != null)
		if native == null:
			return
		assert_eq(native.get_transition_list().size(), 8)
		assert_eq(native.get_transition_from_time(ANY, ANY), AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BEAT)
		assert_eq(native.get_transition_from_time(ANY, 1), AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BAR)
		assert_eq(native.get_transition_from_time(0, ANY), AudioStreamInteractive.TRANSITION_FROM_TIME_IMMEDIATE)
		assert_eq(native.get_transition_from_time(0, 1), AudioStreamInteractive.TRANSITION_FROM_TIME_END)
		var inspected := _handler.interactive_get({"path": path})
		assert_has_key(inspected, "data")
		if not inspected.has("data"):
			return
		var read_rules: Array = []
		for rule in inspected.data.transitions:
			read_rules.append([rule.from, rule.to, rule.get("from_any", false), rule.get("to_any", false)])
		assert_eq(read_rules, [
			["*", "*", true, true], ["*", "Combat", true, false],
			["Explore", "*", false, true], ["Explore", "Combat", false, false],
		])
		rules.reverse()


func test_wildcard_accepts_source_override_and_checks_same_target_fallback() -> void:
	var music := _silent_mp3()
	assert_true(music != null)
	if music == null:
		return
	music.bpm = 120.0
	var clips := _clips()
	clips[1]["stream_path"] = _save_audio_fixture(music)
	var target_rule := {"from": "*", "to": "Explore", "when": "next_bar"}
	_reject({
		"clips": clips,
		"transitions": [target_rule, {"from": "Explore", "to": "Combat"}],
	}, "effective transition 'Explore' to 'Explore'")
	_reject({"clips": clips, "transitions": [target_rule]}, "needs positive BPM and Bar Beats")
	var created := _handler.interactive_create({
		"path": _score, "clips": clips,
		"transitions": [
			target_rule,
			{"from": "*", "to": "Combat", "when": "next_bar"},
			{"from": "Explore", "to": "*"},
		],
	})
	assert_has_key(created, "data")
	if created.has("data"):
		assert_eq(created.data.transitions[2].from, "Explore")
		assert_eq(created.data.transitions[2].when, "immediate")


func test_wildcard_transitions_reject_invalid_or_duplicate_authored_keys() -> void:
	for rule in [
		{"from": "*", "to": "*"}, {"from": "Explore", "to": "*"}, {"from": "*", "to": "Combat"},
	]:
		_reject({"transitions": [rule, rule]}, "duplicate transition")
	_reject({"transitions": [{"from": "Explore", "to": "Explore"}]}, "distinct named endpoints")
	_reject({"transitions": [{"from": "**", "to": "*"}]}, "transitions[0].from")
	_reject({"transitions": [{"from": "*", "to": "* "}]}, "transitions[0].to")
	_reject({"transitions": [{"from": "*", "to": "*", "filler_clip": "*", "fade": "in"}]}, "expected a named clip")
	_reject({"initial_clip": "*"}, "initial_clip")
	_reject({"clips": [{"name": "*", "stream_path": WAV}]}, "reserved wildcard")
	_reject({"transitions": [
		{"from": "*", "to": "Combat", "when": "bad_timing"},
		{"from": "Explore", "to": "*"},
		{"from": "Combat", "to": "*"},
	]}, "transitions[0].when")


func test_wildcard_filler_checks_only_effective_concrete_pairs() -> void:
	var music := _silent_mp3()
	assert_true(music != null)
	if music == null:
		return
	music.bpm = 120.0
	var clips := _clips_with_filler(WAV, _save_audio_fixture(music))
	clips[1]["next_clip"] = "Explore"
	var wildcard := {"from": "Explore", "to": "*", "filler_clip": "Fill", "fade": "in"}
	var enter_cue := {"from": "Explore", "to": "Combat"}
	var enter_fill := {"from": "Explore", "to": "Fill"}
	_reject({
		"clips": clips,
		"transitions": [{"from": "Explore", "to": "*", "fade": "in", "fade_beats": 2.0}],
	}, "incoming fade must finish before 'Combat' ends")
	_reject({
		"clips": clips, "transitions": [wildcard, enter_fill],
	}, "effective transition 'Explore' to 'Combat'")
	_reject({
		"clips": clips, "transitions": [wildcard, enter_cue],
	}, "effective transition 'Explore' to 'Fill'")
	var created := _handler.interactive_create({
		"path": _score, "clips": clips, "transitions": [wildcard, enter_cue, enter_fill],
	})
	assert_has_key(created, "data")
	if created.has("data"):
		assert_eq(created.data.transitions[0].filler_clip, "Fill")
		assert_eq(created.data.clips[1].next_clip, "Explore")


func test_named_next_clip_resolves_forward_and_backward_and_round_trips() -> void:
	var looped := AudioStreamWAV.new()
	looped.data = PackedByteArray([0, 0, 0, 0])
	looped.loop_mode = AudioStreamWAV.LOOP_FORWARD
	looped.loop_end = 4
	var clips := [
		{"name": "Intro", "stream_path": WAV, "next_clip": "Explore"},
		{"name": "Explore", "stream_path": _save_audio_fixture(looped)},
		{"name": "Return", "stream_path": WAV, "next_clip": "Intro"},
	]
	var created := _handler.interactive_create({"path": _score, "clips": clips, "initial_clip": "Return"})
	assert_has_key(created, "data")
	if not created.has("data"):
		return
	assert_eq(created.data.clips[0].next_clip, "Explore")
	assert_eq(created.data.clips[2].auto_advance, "enabled")

	var score := ResourceLoader.load(_score, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as AudioStreamInteractive
	assert_true(score != null)
	if score == null:
		return
	assert_eq(score.initial_clip, 2)
	assert_eq(score.get_clip_auto_advance(0), AudioStreamInteractive.AUTO_ADVANCE_ENABLED)
	assert_eq(score.get_clip_auto_advance_next_clip(0), 1)
	assert_eq(score.get_clip_auto_advance(2), AudioStreamInteractive.AUTO_ADVANCE_ENABLED)
	assert_eq(score.get_clip_auto_advance_next_clip(2), 0)
	assert_eq(score.get_clip_auto_advance(1), AudioStreamInteractive.AUTO_ADVANCE_DISABLED)
	assert_eq((score.get_clip_stream(1) as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_FORWARD)

	var inspected := _handler.interactive_get({"path": _score})
	assert_has_key(inspected, "data")
	if inspected.has("data"):
		assert_eq(inspected.data.clips[0].auto_advance, "enabled")
		assert_eq(inspected.data.clips[0].next_clip, "Explore")
		assert_eq(inspected.data.clips[2].next_clip, "Intro")
		assert_false(inspected.data.clips[1].has("auto_advance"))
		assert_false(inspected.data.clips[1].has("next_clip"))


func test_named_next_clip_rejects_invalid_references() -> void:
	for name in [null, 2, "", "Unknown", "*"]:
		var clips := _clips()
		clips[0]["next_clip"] = name
		_reject({"clips": clips}, "clips[0].next_clip")
	var clips := _clips()
	clips[0]["next_clip"] = "Explore"
	_reject({"clips": clips}, "choose a clip other than 'Explore'")


func test_named_next_clip_requires_compatible_non_looping_audio_with_a_usable_end() -> void:
	var clips := _clips()
	clips[0]["next_clip"] = "Combat"
	clips[0]["stream_path"] = _save_audio_fixture(AudioStreamGenerator.new())
	_reject({"clips": clips}, "WAV, Ogg Vorbis, or MP3")

	var wav := AudioStreamWAV.new()
	clips[0]["stream_path"] = _save_audio_fixture(wav)
	_reject({"clips": clips}, "auto-advance source audio")
	wav.data = PackedByteArray([0, 0, 0, 0])
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = 4
	clips[0]["stream_path"] = _save_audio_fixture(wav)
	_reject({"clips": clips}, "disable looping")

	var music := _silent_mp3()
	assert_true(music != null)
	if music == null:
		return
	music.bpm = 120.0
	music.beat_count = 1
	assert_gt(music.get_length(), 0.5)
	clips[0]["stream_path"] = _save_audio_fixture(music)
	_reject({"clips": clips}, "Beat Count that ends before its non-looping audio")


func test_filler_rules_cannot_enter_or_use_named_auto_advance_cues() -> void:
	var clips := _clips_with_filler(WAV)
	var rules := [{"from": "Explore", "to": "Combat", "filler_clip": "Fill", "fade": "cross"}]
	clips[1]["next_clip"] = "Explore"
	_reject({"clips": clips, "transitions": rules}, "does not schedule next_clip")
	clips[1].erase("next_clip")
	clips[2]["next_clip"] = "Explore"
	_reject({"clips": clips, "transitions": rules}, "separate filler-only clip name")


func test_fading_into_named_auto_advance_cue_requires_time_to_schedule_next_clip() -> void:
	var music := _silent_mp3()
	assert_true(music != null)
	if music == null:
		return
	music.bpm = 120.0
	var clips := _clips_with_filler(WAV, _save_audio_fixture(music))
	clips[1]["next_clip"] = "Fill"
	var rule := {"from": "Explore", "to": "Combat", "fade": "in", "fade_beats": 0.5}
	_reject({"clips": clips, "transitions": [rule.merged({"start_at": "same_position"})]}, "use start")
	_reject(
		{"clips": clips, "transitions": [rule.merged({"fade_beats": 2.0}, true)]},
		"incoming fade must finish before"
	)
	var created := _handler.interactive_create({
		"path": _score, "clips": clips,
		"transitions": [rule, {"from": "Fill", "to": "Combat", "start_at": "same_position"}],
	})
	assert_has_key(created, "data")
	if created.has("data"):
		assert_eq(created.data.clips[1].next_clip, "Fill")
		assert_eq(created.data.transitions[0].fade, "in")
		assert_eq(created.data.transitions[1].start_at, "same_position")


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
