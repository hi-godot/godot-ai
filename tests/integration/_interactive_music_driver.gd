@tool
extends EditorPlugin

const Capture := preload("capture.gd")
const SCORE := "res://score.tres"

var _last_clip := -1
var _observation := 0


func _enter_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("godot_ai/v4_endpoint_ports", {
		"http_port": ProjectSettings.get_setting("adaptive_test/http_port"),
		"ws_port": ProjectSettings.get_setting("adaptive_test/ws_port"),
	})
	_start.call_deferred()


func _start() -> void:
	if not EditorInterface.is_plugin_enabled("godot_ai"):
		EditorInterface.set_plugin_enabled("godot_ai", true)
	if FileAccess.file_exists(Capture.PROOF_DIR + "capture.request"):
		var score := load(SCORE) as AudioStreamInteractive
		if score == null:
			push_error("Could not reload the saved adaptive score")
			return
		Capture.record(score)
		set_process(true)
	else:
		set_process(false)


func _process(_delta: float) -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	var player := scene.get_node_or_null("Player") as AudioStreamPlayer
	if player == null or not player.playing or player.stream == null:
		return
	var playback := player.get_stream_playback() as AudioStreamPlaybackInteractive
	if playback == null:
		return
	var index := playback.get_current_clip_index()
	if index < 0 or index == _last_clip:
		return
	_last_clip = index
	var score := player.stream as AudioStreamInteractive
	Capture.write_receipt("preview-%d.json" % _observation, {
		"pid": OS.get_process_id(),
		"player_id": player.get_instance_id(),
		"playback_id": playback.get_instance_id(),
		"stream_path": score.resource_path,
		"clip": score.get_clip_name(index),
	})
	_observation += 1
