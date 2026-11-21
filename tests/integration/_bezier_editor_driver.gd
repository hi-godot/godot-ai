@tool
extends EditorPlugin

const PROOF := "res://.bezier-test/"


func _enter_tree() -> void:
	EditorInterface.get_editor_settings().set_setting("godot_ai/v4_endpoint_ports", {
		"http_port": ProjectSettings.get_setting("bezier_test/http_port"),
		"ws_port": ProjectSettings.get_setting("bezier_test/ws_port"),
	})
	_enable_mcp.call_deferred()


func _enable_mcp() -> void:
	if not EditorInterface.is_plugin_enabled("godot_ai"):
		EditorInterface.set_plugin_enabled("godot_ai", true)


func _process(_delta: float) -> void:
	var request := PROOF + "action.request"
	if not FileAccess.file_exists(request):
		return
	var action := FileAccess.get_file_as_string(request)
	DirAccess.remove_absolute(request)
	var root := EditorInterface.get_edited_scene_root()
	var receipt := {
		"pid": OS.get_process_id(),
		"scene": root.scene_file_path if root else "",
	}
	if root != null:
		match action:
			"undo", "redo":
				var undo := get_undo_redo()
				var history := undo.get_history_undo_redo(undo.get_object_history_id(root))
				receipt["changed"] = history.undo() if action == "undo" else history.redo()
			"sample":
				receipt.merge(_sample_player(root))
	var output := FileAccess.open(PROOF + "receipt.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(receipt))
	output.close()


func _sample_player(root: Node) -> Dictionary:
	var player := root.get_node("Player") as AnimationPlayer
	var door := root.get_node("Rig/Door") as Node3D
	var current := player.current_animation
	var playing := player.is_playing()
	var manual := player.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var original := door.transform
	var rotation_degrees: Array[float] = []
	var height: Array[float] = []
	for time in [0.25, 0.75]:
		player.seek(time, true)
		rotation_degrees.append(door.rotation_degrees.y)
		height.append(door.position.y)
	door.transform = original
	return {
		"animation": current,
		"playing": playing,
		"manual": manual,
		"rotation_degrees": rotation_degrees,
		"height": height,
	}
