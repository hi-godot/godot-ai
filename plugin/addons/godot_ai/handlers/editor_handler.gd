@tool
class_name EditorHandler
extends RefCounted

## Handles editor state, selection, and log commands.

var _log_buffer: McpLogBuffer


func _init(log_buffer: McpLogBuffer) -> void:
	_log_buffer = log_buffer


func get_editor_state(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	return {
		"data": {
			"godot_version": Engine.get_version_info().get("string", "unknown"),
			"project_name": ProjectSettings.get_setting("application/config/name", ""),
			"current_scene": scene_root.scene_file_path if scene_root else "",
			"is_playing": EditorInterface.is_playing_scene(),
		}
	}


func get_selection(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var paths: Array[String] = []
	for node in selected:
		paths.append(ScenePath.from_node(node, scene_root))
	return {"data": {"selected_paths": paths, "count": paths.size()}}


func get_logs(params: Dictionary) -> Dictionary:
	var count: int = params.get("count", 50)
	var lines := _log_buffer.get_recent(count)
	return {
		"data": {
			"lines": lines,
			"total_count": _log_buffer.total_count(),
			"returned_count": lines.size(),
		}
	}


func reload_plugin(_params: Dictionary) -> Dictionary:
	_log_buffer.log("reload_plugin requested, reloading next frame")
	(func():
		EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
		EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)
	).call_deferred()
	return {"data": {"status": "reloading", "message": "Plugin reload initiated"}}
