@tool
extends EditorPlugin


func _enter_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("godot_ai/v4_endpoint_ports", {
		"http_port": ProjectSettings.get_setting("loop_test/http_port"),
		"ws_port": ProjectSettings.get_setting("loop_test/ws_port"),
	})
	_start.call_deferred()


func _start() -> void:
	if not EditorInterface.is_plugin_enabled("godot_ai"):
		EditorInterface.set_plugin_enabled("godot_ai", true)
	var request := "res://.loop-test/capture.request"
	if not FileAccess.file_exists(request):
		return
	var count := FileAccess.get_file_as_string(request).to_int()
	var stream := load("res://loop.wav") as AudioStreamWAV
	if stream == null:
		push_error("Could not load the reimported WAV")
		return
	var playback := stream.instantiate_playback()
	playback.start()
	var pcm := PackedByteArray()
	pcm.resize(count * 4)
	var frame_index := 0
	while frame_index < count:
		var frames := playback.mix_audio(1.0, mini(257, count - frame_index))
		if frames.is_empty():
			push_error("Native WAV playback stopped producing frames")
			return
		for frame in frames:
			pcm.encode_s16(frame_index * 4, roundi(frame.x * 32767.0))
			pcm.encode_s16(frame_index * 4 + 2, roundi(frame.y * 32767.0))
			frame_index += 1
	var receipt := FileAccess.open("res://.loop-test/capture.json", FileAccess.WRITE)
	receipt.store_string(JSON.stringify({
		"pcm": Marshalls.raw_to_base64(pcm),
		"pid": OS.get_process_id(),
		"format": stream.format,
		"stereo": stream.stereo,
		"sample_rate": stream.mix_rate,
		"mixer_rate": AudioServer.get_mix_rate(),
		"loop_mode": stream.loop_mode,
		"loop_begin": stream.loop_begin,
		"loop_end": stream.loop_end,
		"playing": playback.is_playing(),
	}))
	receipt.close()
	playback.stop()
