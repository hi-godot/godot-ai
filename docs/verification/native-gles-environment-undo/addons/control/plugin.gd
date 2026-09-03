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
	await get_tree().create_timer(3).timeout
	print("CONTROL COMPLETE: count=%s clear=%s free=%s" % [count, clear_mode, OS.get_environment("CONTROL_FREE")])
	get_tree().quit()
