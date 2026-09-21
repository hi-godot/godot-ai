@tool
extends Node

## Compile this source into a GDScript with no resource_path before creating
## the node. Its named callbacks must survive replacement of the file itself.
## The caller verifies/stages/quiesces and owns the update lock. No plugin,
## dock, handler, or suspended caller frame crosses the deferred handoff.
const LIVE_ROOT := "res://addons/godot_ai"
const PLUGIN_CFG := LIVE_ROOT + "/plugin.cfg"
const STAGE_ROOT := "res://addons/.godot_ai_update/stage/addons/godot_ai"
const INSTALLER_PATH := LIVE_ROOT + "/utils/update_installer.gd"
const VERIFIER_PATH := LIVE_ROOT + "/utils/release_verifier.gd"
const RECEIPT_PATH := "res://addons/.godot_ai_update/activation.json"
const SCAN_TIMEOUT_MS := 60000

enum Phase { IDLE, DRAIN, REQUEST_OLD_SCAN, WAIT_OLD_SCAN, SWAPPING, REQUEST_NEW_SCAN, WAIT_NEW_SCAN, ENABLING, DONE }

var _phase := Phase.IDLE
var _package: Dictionary = {}
var _installer: Script
var _verifier: Script
var _frames := 0
var _deadline := 0
var _filesystem: EditorFileSystem
var _failure := ""
var _outcome := ""
var _backup_root := ""
var _retired_scripts: Array[Script] = []
var _inspected_objects := {}
var _inspection_budget := 100000
## Copied by a caller when start() refuses, before the runner is freed.
var refusal_reason := "The independent activation handoff was refused."


func start(package: Dictionary) -> bool:
	if _phase != Phase.IDLE:
		refusal_reason = "The activation runner has already started."
		return false
	if not is_inside_tree():
		refusal_reason = "The activation runner must belong to the editor scene tree."
		return false
	if not str(get_script().resource_path).is_empty():
		refusal_reason = "The activation runner must be source-free before replacing its files."
		return false  # A file-backed runner can be replaced by the scan it starts.
	if package.get("stage_root") != STAGE_ROOT:
		refusal_reason = "The update stage root does not match the verified activation location."
		return false
	if not package.get("record") is Dictionary:
		refusal_reason = "The update handoff requires an installer record Dictionary."
		return false
	var record: Dictionary = package.record
	for key in ["from_version", "to_version", "manifest_sha256", "expected_tree_sha256", "editor_nonce"]:
		if not record.get(key) is String or str(record[key]).is_empty():
			refusal_reason = "The update record requires a nonempty String field: %s." % key
			return false
	if not record.get("replace_owned_mismatches") is bool:
		refusal_reason = "The update record requires a boolean replace_owned_mismatches field."
		return false
	# Copy only values that belong to the existing installer's swap record.
	_package = {"stage_root": STAGE_ROOT, "record": {}}
	for key in ["from_version", "to_version", "manifest_sha256", "expected_tree_sha256", "editor_nonce", "replace_owned_mismatches"]:
		_package.record[key] = record[key]
	_installer = ResourceLoader.load(INSTALLER_PATH, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as Script
	_verifier = ResourceLoader.load(VERIFIER_PATH, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as Script
	if _installer == null or _verifier == null:
		refusal_reason = "The update installer or release verifier script could not be loaded."
		return false
	for method in ["swap", "verify_after_restart", "release_lock", "read_lock", "discard_stage"]:
		if not _declares(_installer, method):
			refusal_reason = "The update installer is missing its required %s method." % method
			return false
	if not _declares(_verifier, "hash_tree"):
		refusal_reason = "The release verifier is missing its required hash_tree method."
		return false
	var lock: Dictionary = _installer.call("read_lock")
	if int(lock.get("pid", 0)) != OS.get_process_id() or str(lock.get("fingerprint", "")).is_empty():
		refusal_reason = "The update lock does not identify this editor with a process fingerprint."
		return false
	_inspected_objects.clear()
	_inspection_budget = 100000
	if not _user_resources_can_keep_paths():
		return false
	refusal_reason = ""
	process_mode = Node.PROCESS_MODE_ALWAYS
	_phase = Phase.DRAIN
	set_process(false)
	_begin.call_deferred()
	return true


func _declares(script: Script, method: String) -> bool:
	for entry in script.get_script_method_list():
		if str(entry.get("name", "")) == method:
			return true
	return false


func _begin() -> void:
	_filesystem = EditorInterface.get_resource_filesystem()
	if _filesystem == null:
		_stop("The editor filesystem is unavailable; no update swap was attempted.")
		return
	_filesystem.sources_changed.connect(_scan_completed)
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, false)
	if EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		_stop("Godot could not disable the plugin; the verified stage was retained.")
		return
	_frames = 2
	set_process(true)


func _process(_delta: float) -> void:
	if _phase == Phase.DRAIN:
		_frames -= 1
		if _frames <= 0:
			_phase = Phase.REQUEST_OLD_SCAN
			_deadline = Time.get_ticks_msec() + SCAN_TIMEOUT_MS
	elif _phase in [Phase.REQUEST_OLD_SCAN, Phase.WAIT_OLD_SCAN, Phase.REQUEST_NEW_SCAN, Phase.WAIT_NEW_SCAN]:
		if Time.get_ticks_msec() >= _deadline:
			_stop("The filesystem scan did not complete. The plugin remains disabled; the staged update and any backup were retained.")
		elif _phase in [Phase.REQUEST_OLD_SCAN, Phase.REQUEST_NEW_SCAN] and not _filesystem.is_scanning():
			_phase = Phase.WAIT_OLD_SCAN if _phase == Phase.REQUEST_OLD_SCAN else Phase.WAIT_NEW_SCAN
			# scan() may decline while a finished worker still awaits GUI
			# completion. Its sources_changed signal remains a valid barrier.
			_filesystem.scan()


func _swap() -> void:
	set_process(false)
	# A cache lookup may resolve dependencies even when the requested script
	# is cached. Retain all old references while their complete tree exists;
	# never load a canonical path after the swap to recover an old script.
	if not _collect_cached_scripts(LIVE_ROOT):
		_stop("The previous script cache could not be captured safely; no update swap was attempted.")
		return
	var before: Dictionary = _verifier.call("hash_tree", LIVE_ROOT)
	if not bool(before.get("ok", false)):
		_stop("Could not hash the previous tree before activation; no swap was attempted.")
		return
	var swapped: Dictionary = _installer.call("swap", STAGE_ROOT, LIVE_ROOT, _package.record)
	if not bool(swapped.get("ok", false)):
		_failure = "Update swap failed: %s" % str(swapped.get("error", "unknown error"))
		var restored: Dictionary = _verifier.call("hash_tree", LIVE_ROOT)
		if not bool(restored.get("ok", false)) or restored.get("tree_sha256") != before.get("tree_sha256"):
			_stop(_failure + "; the original tree could not be proven restored. Explicit repair is required.")
			return
		_installer.call("discard_stage")
		_outcome = "previous_tree_retained"
	else:
		print("MCP | update to %s swapped in; reloading the plugin in this editor" % str(_package.record.to_version))
		var verified: Dictionary = _installer.call("verify_after_restart", LIVE_ROOT)
		_outcome = str(verified.get("status", ""))
		if _outcome != "success" and _outcome != "rolled_back":
			_stop("The installed tree could not be verified: %s" % str(verified.get("error", "unknown outcome")))
			return
		if _outcome == "rolled_back":
			_failure = "Update verification failed; the previous tree was restored: %s" % str(verified.get("error", ""))
		else:
			_backup_root = str(verified.get("backup_root", ""))
			var expected_backup := "res://addons/.godot_ai_update/backup/" + str(_package.record.from_version)
			if _backup_root != expected_backup:
				_stop("The update marker names an unexpected backup. The plugin remains disabled.")
				return
			var backup: Dictionary = _verifier.call("hash_tree", _backup_root)
			if not bool(backup.get("ok", false)) or backup.get("tree_sha256") != before.get("tree_sha256"):
				_stop("The retained backup could not be proven to match the previous tree. The plugin remains disabled.")
				return
	if _outcome == "success" and not _retire_cached_scripts(_backup_root):
		_stop("The previous script cache could not be retained safely. The plugin remains disabled.")
		return
	_release_scripts()
	_phase = Phase.REQUEST_NEW_SCAN
	_deadline = Time.get_ticks_msec() + SCAN_TIMEOUT_MS
	set_process(true)


func _scan_completed(_sources_changed: bool) -> void:
	if _phase not in [Phase.WAIT_OLD_SCAN, Phase.WAIT_NEW_SCAN]:
		return
	if _filesystem.is_scanning():
		return  # Another completion listener already started a newer scan.
	if Time.get_ticks_msec() >= _deadline:
		_stop("The filesystem scan completion arrived after the activation deadline. The plugin remains disabled.")
		return
	set_process(false)
	# sources_changed follows scan actions, documentation, and GUI updates.
	# filesystem_changed can occur earlier; a deferred completion can become
	# stale during a newer GUI scan. Consume this boundary synchronously.
	if _phase == Phase.WAIT_OLD_SCAN:
		_phase = Phase.SWAPPING
		_swap()
	else:
		_phase = Phase.ENABLING
		_filesystem.sources_changed.disconnect(_scan_completed)
		_enable()


func _enable() -> void:
	if not _failure.is_empty() and str(_package.record.from_version).get_slice(".", 0).to_int() < 4:
		# A restored capsule must show Retry instead of automatically repeating
		# the failed update. This is its existing project-scoped status key.
		var settings := EditorInterface.get_editor_settings()
		if settings != null:
			var key := "godot_ai/v4_migration_bridge_status_" + ProjectSettings.globalize_path("res://").sha256_text()
			settings.set_setting(key, JSON.stringify({"error": _failure}))
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, true)
	if not EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		_stop("The scanned plugin could not be enabled. The installed tree and backup were retained.")
		return
	if _outcome == "success":
		var plugin := _find_plugin(get_tree().root)
		if plugin == null or str(plugin.get("_loaded_plugin_version")) != str(_package.record.to_version):
			EditorInterface.set_plugin_enabled(PLUGIN_CFG, false)
			_stop("The enabled plugin did not report the installed version. The update evidence was retained.")
			return
	var saved := ProjectSettings.save()
	if saved != OK:
		_stop("The plugin is enabled, but saving its enabled state failed: %s" % error_string(saved))
		return
	_phase = Phase.DONE
	_record(_outcome, _failure)
	if not _failure.is_empty():
		_show_failure(_failure)
		return
	print("MCP | update activation completed in editor PID %d" % OS.get_process_id())
	queue_free()


func _user_resources_can_keep_paths() -> bool:
	# Retiring a Script changes resource_path for all its existing users.
	# Refuse serializable scene/resource references instead of silently making
	# a user's next save point into the updater's retained backup directory.
	var roots: Array = []
	if EditorInterface.has_method("get_open_scene_roots"):
		roots = EditorInterface.call("get_open_scene_roots")
	else:
		if EditorInterface.get_open_scenes().size() > 1:
			refusal_reason = "This Godot version cannot inspect every open scene safely. Close the other scene tabs before retrying the update."
			return false
		var current := EditorInterface.get_edited_scene_root()
		if current != null:
			roots.append(current)
	for root in roots:
		if not _inspect_user_node(root):
			return false
	var inspected := EditorInterface.get_inspector().get_edited_object()
	if inspected is Resource and not _inspect_user_value(inspected, 0):
		return false
	return true


func _inspect_user_node(node: Node) -> bool:
	if not _inspect_user_value(node, 0):
		return false
	for child in node.get_children():
		if not _inspect_user_node(child):
			return false
	return true


func _inspect_user_value(value: Variant, depth: int) -> bool:
	_inspection_budget -= 1
	if _inspection_budget < 0 or depth > 64:
		refusal_reason = "Open scene or resource data exceeded the safe inspection limit. Close the affected scenes or resources before retrying the update."
		return false
	if value is Script:
		if value.resource_path.begins_with(LIVE_ROOT + "/"):
			refusal_reason = "An open scene or resource references addon script %s. In-editor activation would change its saved script path. Close the scene or resource before retrying; the update was not installed." % value.resource_path
			return false
		return true
	if value is Resource or value is Node:
		var identity: int = value.get_instance_id()
		if _inspected_objects.has(identity):
			return true
		_inspected_objects[identity] = true
		for property in value.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE:
				if not _inspect_user_value(value.get(property.name), depth + 1):
					return false
	elif value is Array:
		for entry in value:
			if not _inspect_user_value(entry, depth + 1):
				return false
	elif value is Dictionary:
		for key in value:
			if not _inspect_user_value(key, depth + 1) or not _inspect_user_value(value[key], depth + 1):
				return false
	return true


func _retire_cached_scripts(backup_root: String) -> bool:
	# All references were captured before replacement. Godot moves
	# both its resource and GDScript cache entries through take_over_path().
	# Existing UndoRedo callbacks keep the old compiled code and typed state;
	# canonical loads create a fresh graph, including fresh static variables.
	for script in _retired_scripts:
		var previous_path := script.resource_path
		var retained_path := backup_root + previous_path.trim_prefix(LIVE_ROOT)
		if not previous_path.begins_with(LIVE_ROOT + "/") or not FileAccess.file_exists(retained_path):
			return false
		if ResourceLoader.has_cached(retained_path):
			return false  # Never displace a different retained generation.
	# A later update in this same editor must not prune source files still
	# referenced by an earlier generation's undo callbacks.
	get_tree().root.set_meta("godot_ai_retained_update_scripts", true)
	for script in _retired_scripts:
		var retained_path := backup_root + script.resource_path.trim_prefix(LIVE_ROOT)
		script.take_over_path(retained_path)
		if script.resource_path != retained_path:
			return false
	return true


func _collect_cached_scripts(folder: String) -> bool:
	var directory := DirAccess.open(folder)
	if directory == null:
		return false
	for filename in directory.get_files():
		if not filename.ends_with(".gd"):
			continue
		var canonical := folder.path_join(filename)
		if ResourceLoader.has_cached(canonical):
			var script := ResourceLoader.load(canonical) as Script
			if script == null or script.resource_path != canonical:
				return false
			_retired_scripts.append(script)
	for child in directory.get_directories():
		if not _collect_cached_scripts(folder.path_join(child)):
			return false
	return true


func _find_plugin(node: Node) -> Node:
	var script := node.get_script() as Script
	if script != null and script.resource_path == LIVE_ROOT + "/plugin.gd":
		return node
	for child in node.get_children():
		var found := _find_plugin(child)
		if found != null:
			return found
	return null


func _release_scripts() -> void:
	if _installer != null:
		_installer.call("release_lock")
	_installer = null
	_verifier = null


func _stop(message: String) -> void:
	_phase = Phase.DONE
	set_process(false)
	if _filesystem != null and _filesystem.sources_changed.is_connected(_scan_completed):
		_filesystem.sources_changed.disconnect(_scan_completed)
	_release_scripts()
	_record("activation_failed", message)
	_show_failure(message)


func _record(status: String, message: String) -> void:
	var file := FileAccess.open(RECEIPT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"status": status, "error": message,
			"editor_pid": OS.get_process_id(), "from_version": _package.record.from_version,
			"to_version": _package.record.to_version, "unix": Time.get_unix_time_from_system()}))
	else:
		push_error("MCP | could not write update activation evidence: %s" % error_string(FileAccess.get_open_error()))


func _show_failure(message: String) -> void:
	push_error("MCP | %s" % message)
	if DisplayServer.get_name() == "headless":
		queue_free()
		return
	var dialog := AcceptDialog.new()
	dialog.title = "Godot AI update needs attention"
	dialog.dialog_text = message + "\nUpdate evidence: res://addons/.godot_ai_update/"
	add_child(dialog)
	dialog.confirmed.connect(_dismiss_failure)
	dialog.canceled.connect(_dismiss_failure)
	dialog.popup_centered(Vector2i(620, 220))


func _dismiss_failure() -> void:
	## Godot may have left its shared progress dialog under the failure window.
	## Return it before freeing our subtree and leaving the editor's pointer dangling.
	if is_inside_tree():
		for dialog in find_children("*", "ProgressDialog", true, false):
			dialog.reparent(get_tree().root)
	queue_free()
