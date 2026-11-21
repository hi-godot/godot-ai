@tool
extends RefCounted

const BLOCK := 256
const PROOF_DIR := "res://.adaptive-test/"


static func record(score: AudioStreamInteractive) -> void:
	var playback := score.instantiate_playback() as AudioStreamPlaybackInteractive
	var rate := int(AudioServer.get_mix_rate())
	var output := FileAccess.open(PROOF_DIR + "stereo.f32", FileAccess.WRITE)
	playback.start()
	if not _mix(playback, output, rate):
		return
	var clip_before_request := playback.get_current_clip_index()
	playback.switch_to_clip_by_name(&"combat")
	if not _mix(playback, output, int(rate * 2.5)):
		return
	output.close()
	write_receipt("timing.json", {
		"pid": OS.get_process_id(),
		"rate": rate,
		"block": BLOCK,
		"requested_at_frame": rate,
		"clip_before_request": clip_before_request,
		"clip_after_capture": playback.get_current_clip_index(),
	})
	playback.stop()


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
