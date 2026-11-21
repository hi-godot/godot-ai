@tool
extends McpTestSuite

const AudioHandler := preload("res://addons/godot_ai/handlers/audio_handler.gd")
const WAV := "res://tests/fixtures/import_settings.wav"

var _handler: AudioHandler
var _directory: String
var _score: String


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


func suite_teardown() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_directory))


func _clips() -> Array:
	return [{"name": "Explore", "stream_path": WAV}, {"name": "Combat", "stream_path": WAV}]


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
	score.clip_count = 2
	for i in score.clip_count:
		score.set_clip_name(i, &"Explore" if i == 0 else &"Combat")
		score.set_clip_stream(i, load(WAV))
	score.add_transition(AudioStreamInteractive.CLIP_ANY, 1,
		AudioStreamInteractive.TRANSITION_FROM_TIME_NEXT_BEAT,
		AudioStreamInteractive.TRANSITION_TO_TIME_PREVIOUS_POSITION,
		AudioStreamInteractive.FADE_AUTOMATIC, 0.5, true, 0, true)
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
