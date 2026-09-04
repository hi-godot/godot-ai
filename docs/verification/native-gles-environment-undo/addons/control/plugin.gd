@tool
extends EditorPlugin

var started := false

func _process(_delta: float) -> void:
	if started or EditorInterface.get_resource_filesystem().is_scanning():
		return
	started = true
	_run()

func _run() -> void:
	var initial := Node3D.new()
	initial.name = "Main"
	var packed := PackedScene.new()
	assert(packed.pack(initial) == OK)
	assert(ResourceSaver.save(packed, "res://main.tscn") == OK)
	initial.free()
	packed = null
	EditorInterface.get_resource_filesystem().update_file("res://main.tscn")
	await get_tree().create_timer(1).timeout
	EditorInterface.open_scene_from_path("res://main.tscn")
	await get_tree().create_timer(1).timeout
	var root := EditorInterface.get_edited_scene_root()
	assert(root.name == "Main")
	var count := int(OS.get_environment("CONTROL_COUNT")) if OS.has_environment("CONTROL_COUNT") else 8
	var clear_mode := OS.get_environment("CONTROL_CLEAR")
	var batches := int(OS.get_environment("CONTROL_BATCHES")) if OS.has_environment("CONTROL_BATCHES") else 1
	var idle := float(OS.get_environment("CONTROL_IDLE")) if OS.has_environment("CONTROL_IDLE") else 3.0
	assert(count >= 1 and count <= 16)
	assert(batches >= 1 and batches <= 10)
	assert(idle >= 0.0 and idle <= 60.0)
	_report(0)
	for batch in range(batches):
		await _batch(root, count, clear_mode)
		await get_tree().create_timer(0.25).timeout
		_report(batch + 1)
	await get_tree().create_timer(idle).timeout
	_report(batches + 1)
	print("CONTROL COMPLETE: count=%s batches=%s clear=%s free=%s direct_sky=%s idle=%s" % [count, batches, clear_mode, OS.get_environment("CONTROL_FREE"), OS.get_environment("CONTROL_DIRECT_SKY"), idle])
	get_tree().quit()

func _report(batch: int) -> void:
	# These are engine accounting counters, not independent GPU-driver measurements.
	print("CONTROL MEMORY ", JSON.stringify({"batch": batch,
		"texture_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),
		"video_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
		"resource_count": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"object_count": Performance.get_monitor(Performance.OBJECT_COUNT)}))

func _batch(root: Node, count: int, clear_mode: String) -> void:
	if OS.get_environment("CONTROL_DIRECT_SKY") == "1":
		# No Environment, material, node or undo action participates in this control.
		var skies: Array[RID] = []
		for index in range(count):
			var sky_rid := RenderingServer.sky_create()
			RenderingServer.sky_set_radiance_size(sky_rid, 128)
			skies.append(sky_rid)
		if clear_mode == "deferred":
			await get_tree().process_frame
			await get_tree().process_frame
		for sky_rid in skies:
			RenderingServer.free_rid(sky_rid)
		return
	for index in range(count):
		var node := WorldEnvironment.new()
		node.name = "Environment%s" % index
		root.add_child(node)
		node.owner = root
		var environment := Environment.new()
		var sky := Sky.new()
		var material := ProceduralSkyMaterial.new()
		sky.sky_material = material
		environment.sky = sky
		environment.background_mode = Environment.BG_SKY
		var undo := get_undo_redo()
		undo.create_action("Native assign environment")
		undo.add_do_property(node, "environment", environment)
		undo.add_undo_property(node, "environment", null)
		undo.add_do_reference(environment)
		undo.add_do_reference(sky)
		undo.add_do_reference(material)
		undo.commit_action()
		assert(node.environment == environment)
		root.remove_child(node)
		if OS.get_environment("CONTROL_FREE") == "immediate":
			node.free()
		else:
			node.queue_free()
	if clear_mode == "deferred":
		await get_tree().process_frame
		await get_tree().process_frame
	if clear_mode != "none":
		get_undo_redo().clear_history()
