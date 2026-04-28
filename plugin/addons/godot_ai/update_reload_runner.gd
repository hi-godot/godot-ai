@tool
extends Node

## Runs the self-update after the visible plugin has handed off control.
##
## This node is deliberately tiny and not parented under the EditorPlugin:
## it survives `set_plugin_enabled(false)`, extracts the downloaded release,
## waits for Godot's filesystem scan, then enables the plugin again. The old
## dock is detached before this runner starts, kept alive while deferred
## Callables drain, and freed only after the new plugin instance is loaded.

const PLUGIN_CFG_PATH := "res://addons/godot_ai/plugin.cfg"
const PRE_DISABLE_DRAIN_FRAMES := 8
const POST_DISABLE_DRAIN_FRAMES := 2
const POST_ENABLE_FREE_FRAMES := 8

var _zip_path := ""
var _temp_dir := ""
var _detached_dock = null
var _started := false
var _next_step := ""
var _frames_remaining := 0
var _waiting_for_scan := false


func start(zip_path: String, temp_dir: String, detached_dock) -> void:
	if _started:
		return
	_started = true
	_zip_path = zip_path
	_temp_dir = temp_dir
	_detached_dock = detached_dock
	_wait_frames(PRE_DISABLE_DRAIN_FRAMES, "_disable_old_plugin")


func _process(_delta: float) -> void:
	if _frames_remaining <= 0:
		set_process(false)
		return

	_frames_remaining -= 1
	if _frames_remaining <= 0:
		var step := _next_step
		_next_step = ""
		set_process(false)
		call(step)


func _wait_frames(frame_count: int, next_step: String) -> void:
	_next_step = next_step
	_frames_remaining = max(1, frame_count)
	set_process(true)


func _disable_old_plugin() -> void:
	## Disable before writing or scanning new scripts. This avoids both the
	## Dict/Array field-storage hot-reload crash (#245) and cached handler
	## constructor shape mismatches (#247) for plugin-owned instances.
	print("MCP | update runner disabling old plugin")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, false)
	_wait_frames(POST_DISABLE_DRAIN_FRAMES, "_extract_and_scan")


func _extract_and_scan() -> void:
	if not _extract_update():
		EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
		_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")
		return

	_cleanup_update_temp()
	_start_filesystem_scan()


func _start_filesystem_scan() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		_enable_new_plugin.call_deferred()
		return

	_waiting_for_scan = true
	if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed, CONNECT_ONE_SHOT)
	fs.scan()


func _extract_update() -> bool:
	var zip_path := ProjectSettings.globalize_path(_zip_path)
	var install_base := ProjectSettings.globalize_path("res://")

	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		print("MCP | update extract failed: could not open %s" % zip_path)
		return false

	var files := reader.get_files()
	for file_path in files:
		if not file_path.begins_with("addons/godot_ai/"):
			continue
		if file_path.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(install_base.path_join(file_path))
		else:
			var dir := file_path.get_base_dir()
			DirAccess.make_dir_recursive_absolute(install_base.path_join(dir))
			var content := reader.read_file(file_path)
			var target_path := install_base.path_join(file_path)
			var f := FileAccess.open(target_path, FileAccess.WRITE)
			if f == null:
				print("MCP | update extract failed: could not write %s (error %d)" % [
					target_path,
					FileAccess.get_open_error(),
				])
				reader.close()
				return false
			f.store_buffer(content)
			var write_error := f.get_error()
			f.close()
			if write_error != OK:
				print("MCP | update extract failed: write error %d for %s" % [
					write_error,
					target_path,
				])
				reader.close()
				return false

	reader.close()
	return true


func _cleanup_update_temp() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_zip_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_temp_dir))


func _on_filesystem_changed() -> void:
	_finish_scan_wait()


func _finish_scan_wait() -> void:
	if not _waiting_for_scan:
		return
	_waiting_for_scan = false
	set_process(false)
	_enable_new_plugin.call_deferred()


func _enable_new_plugin() -> void:
	print("MCP | update runner enabling new plugin")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
	_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")


func _cleanup_and_finish() -> void:
	_cleanup_detached_dock()
	queue_free()


func _cleanup_detached_dock() -> void:
	if _detached_dock != null and is_instance_valid(_detached_dock):
		_detached_dock.queue_free()
	_detached_dock = null
