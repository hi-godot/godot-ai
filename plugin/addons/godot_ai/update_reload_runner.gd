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
const INSTALL_BASE_PATH := "res://"
const ZIP_ADDON_PREFIX := "addons/godot_ai/"
const TEMP_FILE_SUFFIX := ".godot_ai_update_tmp"

var _zip_path := ""
var _temp_dir := ""
var _detached_dock = null
var _started := false
var _next_step := ""
var _frames_remaining := 0
var _waiting_for_scan := false
var _scan_next_step := ""
## Keep Array fields untyped: this runner survives fs.scan() during update,
## and typed Variant storage is part of the hot-reload crash class.
var _new_file_paths = []
var _existing_file_paths = []


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
	if not _read_update_manifest():
		EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
		_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")
		return

	if not _install_zip_paths(_new_file_paths):
		EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
		_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")
		return

	if _new_file_paths.is_empty():
		_install_existing_files_and_scan.call_deferred()
	else:
		## Register newly added class_name/base scripts while all old plugin
		## files are still intact. Updating plugin.gd or handler preloads
		## before this scan can make Godot parse a new dependency graph
		## before its new global classes exist.
		_start_filesystem_scan("_install_existing_files_and_scan")


func _start_filesystem_scan(next_step: String = "_enable_new_plugin") -> void:
	var fs := EditorInterface.get_resource_filesystem()
	var deferred_step := next_step if not next_step.is_empty() else "_enable_new_plugin"
	if fs == null:
		call_deferred(deferred_step)
		return

	_waiting_for_scan = true
	_scan_next_step = deferred_step
	if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed, CONNECT_ONE_SHOT)
	fs.scan()


func _read_update_manifest() -> bool:
	var zip_path := ProjectSettings.globalize_path(_zip_path)
	var install_base := ProjectSettings.globalize_path(INSTALL_BASE_PATH)

	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		print("MCP | update extract failed: could not open %s" % zip_path)
		return false

	_new_file_paths.clear()
	_existing_file_paths.clear()
	var has_plugin_cfg := false
	var has_plugin_script := false
	var files := reader.get_files()
	for file_path in files:
		if not file_path.begins_with(ZIP_ADDON_PREFIX):
			continue
		if not _is_safe_zip_addon_file(file_path):
			print("MCP | update extract failed: unsafe zip path %s" % file_path)
			reader.close()
			return false
		var rel_path := file_path.trim_prefix(ZIP_ADDON_PREFIX)
		if rel_path.is_empty() or file_path.ends_with("/"):
			continue
		if rel_path == "plugin.cfg":
			has_plugin_cfg = true
		elif rel_path == "plugin.gd":
			has_plugin_script = true
		var target_path := install_base.path_join(file_path)
		if FileAccess.file_exists(target_path):
			_existing_file_paths.append(file_path)
		else:
			_new_file_paths.append(file_path)
	reader.close()
	if not has_plugin_cfg:
		print("MCP | update extract failed: zip is missing plugin.cfg")
		return false
	if not has_plugin_script:
		print("MCP | update extract failed: zip is missing plugin.gd")
		return false
	return true


func _install_existing_files_and_scan() -> void:
	if not _install_zip_paths(_existing_file_paths):
		EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
		_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")
		return

	_cleanup_update_temp()
	_start_filesystem_scan("_enable_new_plugin")


func _is_safe_zip_addon_file(file_path: String) -> bool:
	if file_path.is_absolute_path() or file_path.contains("\\"):
		return false
	if not file_path.begins_with(ZIP_ADDON_PREFIX):
		return false
	var rel_path := file_path.trim_prefix(ZIP_ADDON_PREFIX)
	if rel_path.is_empty() or rel_path.ends_with("/"):
		return false
	for segment in rel_path.split("/", true):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


func _install_zip_paths(paths: Array) -> bool:
	if paths.is_empty():
		return true

	var zip_path := ProjectSettings.globalize_path(_zip_path)
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		print("MCP | update extract failed: could not reopen %s" % zip_path)
		return false

	for file_path in paths:
		if not _install_zip_file(reader, String(file_path)):
			reader.close()
			return false
	reader.close()
	return true


func _install_zip_file(reader: ZIPReader, file_path: String) -> bool:
	var install_base := ProjectSettings.globalize_path(INSTALL_BASE_PATH)
	var target_path := install_base.path_join(file_path)
	var dir := target_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		print("MCP | update extract failed: could not create %s" % dir)
		return false

	var temp_path := target_path + TEMP_FILE_SUFFIX
	DirAccess.remove_absolute(temp_path)
	var content := reader.read_file(file_path)
	var f := FileAccess.open(temp_path, FileAccess.WRITE)
	if f == null:
		print("MCP | update extract failed: could not write %s (error %d)" % [
			temp_path,
			FileAccess.get_open_error(),
		])
		return false
	f.store_buffer(content)
	var write_error := f.get_error()
	f.close()
	if write_error != OK:
		print("MCP | update extract failed: write error %d for %s" % [
			write_error,
			temp_path,
		])
		DirAccess.remove_absolute(temp_path)
		return false

	if DirAccess.rename_absolute(temp_path, target_path) != OK:
		## POSIX and APFS replace atomically. Some filesystems reject
		## rename-over-existing; keep a fallback so the update can still
		## proceed, but the common path never exposes a truncated target.
		DirAccess.remove_absolute(target_path)
		if DirAccess.rename_absolute(temp_path, target_path) != OK:
			DirAccess.remove_absolute(temp_path)
			print("MCP | update extract failed: could not replace %s" % target_path)
			return false
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
	var next_step := _scan_next_step
	_scan_next_step = ""
	set_process(false)
	if next_step.is_empty():
		next_step = "_enable_new_plugin"
	call_deferred(next_step)


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
