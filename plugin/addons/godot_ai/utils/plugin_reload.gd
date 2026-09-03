@tool
extends RefCounted

## Ordinary in-editor reload only. Transaction activation keeps its own
## quiescence, lock and readiness protocol; this is not a hot-update grant.
const PLUGIN_CFG := "res://addons/godot_ai/plugin.cfg"
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const SCAN_TIMEOUT_SECONDS := 5.0

## One command-scoped native-signal handoff, not a suspended GDScript frame.
## Named callbacks survive the source reload caused by the scan itself.
static var _pending_scan: Dictionary = {}


static func reload_after_scan(work: int = 0) -> void:
	if work == 0:
		work = ScriptWork.begin("reload_plugin")
	_start_scan(EditorInterface.get_resource_filesystem(), null, work)


static func _start_scan(filesystem: Object, timer: Object, work: int) -> void:
	if not _pending_scan.is_empty():
		ScriptWork.finish(work)
		push_error("MCP | a plugin reload is already waiting for its filesystem scan")
		return
	if timer == null:
		# Editor deadlines must not inherit a project's pause or time scale.
		timer = Engine.get_main_loop().create_timer(SCAN_TIMEOUT_SECONDS, true, false, true)
	var complete := _finish_scan.bind(work, false)
	var timeout := _finish_scan.bind(work, true)
	_pending_scan = {"work": work, "filesystem": filesystem, "timer": timer,
		"complete": complete, "timeout": timeout}
	filesystem.filesystem_changed.connect(complete, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	timer.timeout.connect(timeout, CONNECT_ONE_SHOT)
	filesystem.scan()


static func _take_scan() -> Dictionary:
	var pending := _pending_scan
	_pending_scan = {}
	if not pending.is_empty():
		if pending.filesystem.filesystem_changed.is_connected(pending.complete):
			pending.filesystem.filesystem_changed.disconnect(pending.complete)
		if pending.timer.timeout.is_connected(pending.timeout):
			pending.timer.timeout.disconnect(pending.timeout)
	return pending


static func _finish_scan(work: int, timed_out: bool) -> void:
	# A queued callback from an earlier scan can never consume a later request.
	if _pending_scan.get("work", 0) != work:
		return
	var pending := _take_scan()
	if timed_out:
		push_error("MCP | filesystem scan did not finish; plugin left unchanged, retry reload")
	else:
		reload_enabled_plugin()
	ScriptWork.finish(pending.work)


static func reload_enabled_plugin() -> Error:
	# An explicit direct reload supersedes a still-pending ordinary scan.
	var pending := _take_scan()
	if not pending.is_empty():
		ScriptWork.finish(pending.work)
	if not EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		push_error("MCP | cannot reload a disabled plugin")
		return ERR_UNAVAILABLE
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, false)
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, true)
	if not EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		push_error("MCP | plugin could not be re-enabled after reload")
		return FAILED
	## Plugin callbacks save autoload changes while the temporary disabled state
	## is still visible. Persist only after set_plugin_enabled has completed, or
	## the next editor process can reopen with this working plugin disabled.
	var error := ProjectSettings.save()
	if error != OK:
		push_error("MCP | reloaded plugin enablement could not be saved: %s" % error_string(error))
	return error
