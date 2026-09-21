@tool
extends Node

var _started := false
var _scan_finished := false
var _result := {"failures": []}


func _process(_delta: float) -> void:
	if _started or not Engine.is_editor_hint():
		return
	if EditorInterface.get_resource_filesystem().is_scanning():
		return
	var dock := _find_dock(get_tree().root)
	if dock == null:
		return
	_started = true
	_run.call_deferred(dock)


func _find_dock(node: Node) -> Node:
	if node.get_script() != null and str(node.get_script().resource_path).ends_with("/mcp_dock.gd"):
		return node
	for child in node.get_children(true):
		var found := _find_dock(child)
		if found != null:
			return found
	return null


func _find_progress(node: Node) -> Node:
	if node.is_class("ProgressDialog"):
		return node
	for child in node.get_children(true):
		var found := _find_progress(child)
		if found != null:
			return found
	return null


func _check(condition: bool, message: String) -> bool:
	if not condition:
		_result.failures.append(message)
	return condition


func _run(dock: Node) -> void:
	var progress := _find_progress(get_tree().root)
	if not _check(progress != null, "native editor ProgressDialog must exist"):
		_finish()
		return
	_result.progress_id_before = progress.get_instance_id()
	var dialog: Window = dock.get("_update_confirm")
	var dialog_id := dialog.get_instance_id()
	dialog.popup_centered()
	# Establish the engine's borrowed-child state with the actual native singleton.
	# No fake ProgressDialog or replacement progress object can satisfy this test.
	progress.reparent(dialog)
	dialog.hide()
	_check(progress.get_parent() == dialog, "hidden confirmation must still hold borrowed progress")
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	await get_tree().process_frame
	await get_tree().process_frame
	_result.old_dialog_destroyed = not is_instance_id_valid(dialog_id)
	if not _check(is_instance_id_valid(int(_result.progress_id_before)), "plugin disable destroyed native shared progress"):
		_finish()
		return
	progress = instance_from_id(int(_result.progress_id_before))
	_result.progress_id_after = progress.get_instance_id()
	_check(progress.get_parent() == get_tree().root, "native progress must move outside plugin ownership to editor root")
	## Godot uses foreground class-registration progress for multiple script paths.
	for suffix in ["A", "B"]:
		var script_file := FileAccess.open("res://lifetime_scan_%s.gd" % suffix, FileAccess.WRITE)
		if not _check(script_file != null, "scan fixture must be writable"):
			_finish()
			return
		script_file.store_string("class_name LifetimeScanProbe%s\nextends RefCounted\n" % suffix)
		script_file.close()
	var filesystem := EditorInterface.get_resource_filesystem()
	filesystem.sources_changed.connect(_on_scan_finished)
	filesystem.scan()
	var deadline := Time.get_ticks_msec() + 30000
	while not _scan_finished and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(_scan_finished, "post-disable filesystem scan must complete")
	var registered: Array[String] = []
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class") in ["LifetimeScanProbeA", "LifetimeScanProbeB"]:
			registered.append(entry["class"])
	_result.class_registered = registered.size() == 2
	_check(_result.class_registered, "scan must register both newly written script classes")
	_finish()


func _on_scan_finished(_changed: bool) -> void:
	_scan_finished = true


func _finish() -> void:
	var output := FileAccess.open("res://result.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(_result))
	output.close()
	get_tree().quit(0)
