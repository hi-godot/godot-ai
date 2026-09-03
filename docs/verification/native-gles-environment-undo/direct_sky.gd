extends SceneTree

## Engine-only game-process control: no editor, scene, material or undo manager.
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	await process_frame
	var before := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	var skies: Array[RID] = []
	for index in range(8):
		var sky := RenderingServer.sky_create()
		RenderingServer.sky_set_radiance_size(sky, 128)
		skies.append(sky)
	if OS.get_environment("CONTROL_CLEAR") == "deferred":
		await process_frame
		await process_frame
	for sky in skies:
		RenderingServer.free_rid(sky)
	await create_timer(3).timeout
	var after := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	print("DIRECT SKY COMPLETE ", JSON.stringify({
		"clear": OS.get_environment("CONTROL_CLEAR"),
		"before_texture_bytes": before,
		"after_texture_bytes": after,
		"delta_texture_bytes": after - before}))
	quit()
