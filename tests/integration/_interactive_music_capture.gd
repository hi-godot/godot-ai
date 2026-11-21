@tool
extends RefCounted

const BLOCK := 256
const PROOF_DIR := "res://.adaptive-test/"


static func record(score: AudioStreamInteractive, prefix := "") -> void:
	var playback := score.instantiate_playback() as AudioStreamPlaybackInteractive
	var rate := int(AudioServer.get_mix_rate())
	var output := FileAccess.open(PROOF_DIR + prefix + "stereo.f32", FileAccess.WRITE)
	playback.start()
	if not _mix(playback, output, rate):
		return
	var clip_before_request := playback.get_current_clip_index()
	playback.switch_to_clip_by_name(&"combat")
	if not _mix(playback, output, rate * 3):
		return
	output.close()
	write_receipt(prefix + "timing.json", {
		"pid": OS.get_process_id(),
		"rate": rate,
		"block": BLOCK,
		"requested_at_frame": rate,
		"clip_before_request": clip_before_request,
		"clip_after_capture": playback.get_current_clip_index(),
	})
	playback.stop()


static func record_native_fill(score: AudioStreamInteractive, fade: AudioStreamInteractive.FadeMode, name: String) -> void:
	# Change the native rule on a copy so the saved score and editor preview keep the public rule.
	var baseline := score.duplicate() as AudioStreamInteractive
	baseline.add_transition(
		0, 1, score.get_transition_from_time(0, 1), score.get_transition_to_time(0, 1),
		fade, score.get_transition_fade_beats(0, 1), true, score.get_transition_filler_clip(0, 1)
	)
	record(baseline, "native-" + name + "-")


static func _mix(playback: AudioStreamPlaybackInteractive, output: FileAccess, count: int) -> bool:
	var remaining := count
	while remaining > 0:
		var wanted := mini(BLOCK, remaining)
		var stereo := playback.mix_audio(1.0, wanted)
		if stereo.size() != wanted:
			push_error("Unexpected native adaptive mixer frame count")
			return false
		for frame in stereo:
			output.store_float(frame.x)
			output.store_float(frame.y)
		remaining -= wanted
	return true


static func write_receipt(name: String, fields: Dictionary) -> void:
	var file := FileAccess.open(PROOF_DIR + name, FileAccess.WRITE)
	file.store_string(JSON.stringify(fields))
	file.close()
