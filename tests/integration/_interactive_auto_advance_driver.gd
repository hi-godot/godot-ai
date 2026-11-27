@tool
extends EditorPlugin

const PROOF_DIR := "res://.auto-advance-test/"

var _capture: AudioEffectCapture
var _take := ""
var _visits: Array[Dictionary] = []
var _discarded_at_start := 0
var _expected_visits := 3
var _pre_switch_seconds := 0.25
var _tail_seconds := 1.5
var _measure_switch := false
var _switch_marked := false
var _switch_ready_after_frames := 0
var _finish_after_frames := 0
var _finished := false


func _enter_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("godot_ai/v4_endpoint_ports", {
		"http_port": ProjectSettings.get_setting("auto_advance_test/http_port"),
		"ws_port": ProjectSettings.get_setting("auto_advance_test/ws_port"),
	})
	_start.call_deferred()


func _start() -> void:
	if not EditorInterface.is_plugin_enabled("godot_ai"):
		EditorInterface.set_plugin_enabled("godot_ai", true)
	if not FileAccess.file_exists(PROOF_DIR + "capture.request"):
		set_process(false)
		return
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 12.0
	AudioServer.add_bus_effect(0, _capture)
	_expected_visits = int(ProjectSettings.get_setting("auto_advance_test/expected_visits", 3))
	_pre_switch_seconds = float(ProjectSettings.get_setting("auto_advance_test/pre_switch_seconds", 0.25))
	_tail_seconds = float(ProjectSettings.get_setting("auto_advance_test/tail_seconds", 1.5))
	_measure_switch = bool(ProjectSettings.get_setting("auto_advance_test/measure_switch", false))


func _process(_delta: float) -> void:
	if _capture == null:
		return
	var requested := FileAccess.get_file_as_string(PROOF_DIR + "capture.request")
	if requested != _take:
		_take = requested
		_capture.clear_buffer()
		_discarded_at_start = _capture.get_discarded_frames()
		_visits.clear()
		_switch_marked = false
		_switch_ready_after_frames = 0
		_finish_after_frames = 0
		_finished = false
		_receipt("ready", {"pid": OS.get_process_id()})
	if _take.is_empty() or _finished:
		return
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	var player := scene.get_node_or_null("Player") as AudioStreamPlayer
	if player == null or not player.playing:
		return
	var playback := player.get_stream_playback() as AudioStreamPlaybackInteractive
	if playback == null:
		return
	var index := playback.get_current_clip_index()
	if index < 0:
		return
	var score := player.stream as AudioStreamInteractive
	var clip := String(score.get_clip_name(index))
	if _visits.is_empty() or _visits.back().clip != clip:
		var observation := {
			"clip": clip,
			"length_seconds": score.get_clip_stream(index).get_length(),
			"player_id": player.get_instance_id(),
			"playback_id": playback.get_instance_id(),
			"score_path": score.resource_path,
		}
		_visits.append(observation)
		if _visits.size() == 1:
			_receipt("started", observation)
			# The clip index can change before its first audio block is mixed.
			_switch_ready_after_frames = _capture.get_frames_available() + int(AudioServer.get_mix_rate() * _pre_switch_seconds)
		if _visits.size() == _expected_visits:
			_finish_after_frames = _capture.get_frames_available() + int(AudioServer.get_mix_rate() * _tail_seconds)
	if _switch_ready_after_frames > 0 and _capture.get_frames_available() >= _switch_ready_after_frames:
		_switch_ready_after_frames = 0
		_receipt("switch-ready", {"pid": OS.get_process_id(), "frames": _capture.get_frames_available()})
	if _measure_switch and not _switch_marked and FileAccess.file_exists(PROOF_DIR + _take + "-switched.request"):
		_switch_marked = true
		_receipt("switched", {"pid": OS.get_process_id(), "frames": _capture.get_frames_available()})
	if _finish_after_frames > 0 and _capture.get_frames_available() >= _finish_after_frames:
		_record(player, playback)


func _record(player: AudioStreamPlayer, playback: AudioStreamPlaybackInteractive) -> void:
	var frames := _capture.get_buffer(_capture.get_frames_available())
	var output := FileAccess.open(PROOF_DIR + _take + "-stereo.f32", FileAccess.WRITE)
	for frame in frames:
		output.store_float(frame.x)
		output.store_float(frame.y)
	output.close()
	_finished = true
	_receipt("audio", {
		"pid": OS.get_process_id(),
		"rate": AudioServer.get_mix_rate(),
		"frames": frames.size(),
		"discarded_frames": _capture.get_discarded_frames() - _discarded_at_start,
		"visits": _visits,
		"player_id": player.get_instance_id(),
		"playback_id": playback.get_instance_id(),
	})


func _receipt(label: String, data: Dictionary) -> void:
	var output := FileAccess.open(PROOF_DIR + _take + "-" + label + ".json", FileAccess.WRITE)
	output.store_string(JSON.stringify(data))
	output.close()
