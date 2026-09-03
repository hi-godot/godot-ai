@tool
extends Node

## Value-only handoff across the bridge -> v4 tree swap. The Python actor owns
## every live namespace mutation; this compiled node only disables the bridge,
## requests a clean editor restart, and restores the bridge after rollback.

const BridgeExec := preload("res://addons/godot_ai/bridge_exec.gd")
const PLUGIN_CFG := "res://addons/godot_ai/plugin.cfg"
const STATUS_SETTING := "godot_ai/v4_migration_bridge_status"
const TRANSACTION_ENV := "GODOT_AI_UPDATE_TRANSACTION"
const EDITOR_NONCE_ENV := "GODOT_AI_UPDATE_EDITOR_NONCE"
const ACTOR_HANDOFF_ENV := "GODOT_AI_UPDATE_ACTOR_HANDOFF"
const POLL_MSEC := 50
const DEADLINE_MSEC := 90 * 1000
const STARTUP_TIMEOUT_SECONDS := 180

enum Phase { DRAIN, WAIT_STAGE, WAIT_SCAN, DONE }

var _package: Dictionary = {}
var _phase := Phase.DONE
var _frames := 0
var _actor_pid := -1
var _deadline := 0
var _next_poll := 0
var _rollback := false


func start(package: Dictionary) -> void:
	if _phase != Phase.DONE or not _valid_package(package):
		_fail("The prepared v4 migration handoff is invalid.")
		return
	_package = package.duplicate(true)
	OS.set_environment(TRANSACTION_ENV, str(_package.transaction))
	OS.set_environment(EDITOR_NONCE_ENV, str(_package.editor_nonce))
	OS.set_environment(ACTOR_HANDOFF_ENV, JSON.stringify({
		"schema_version": 1,
		"protocol_version": 1,
		"package_version": str(_package.to_version),
		"transaction": str(_package.transaction),
		"editor_nonce": str(_package.editor_nonce),
		"command": (_package.actor_command as Array).duplicate(),
	}))
	_deadline = Time.get_ticks_msec() + DEADLINE_MSEC
	_frames = 2
	_phase = Phase.DRAIN
	set_process(true)


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() >= _deadline:
		_fail("The v4 activation timed out; explicit recovery is required.")
		return
	if _phase == Phase.DRAIN:
		_frames -= 1
		if _frames <= 0:
			_disable_and_activate()
		return
	if Time.get_ticks_msec() < _next_poll:
		return
	_next_poll = Time.get_ticks_msec() + POLL_MSEC
	if _phase == Phase.WAIT_STAGE:
		var journal := _record("journal.json")
		match str(journal.get("phase", "")):
			"stage_live":
				_restart_into_v4()
			"rolled_back":
				_scan(true)
			"repair_required":
				_fail("The v4 activation requires explicit recovery; the plugin remains disabled.")
		if _actor_pid > 1 and not OS.is_process_running(_actor_pid) and journal.is_empty():
			_fail("The v4 transaction actor exited before publishing a durable outcome.")


func _disable_and_activate() -> void:
	print("MCP | v3 bridge disabling transition plugin")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, false)
	if EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		_fail("Godot could not disable the migration capsule safely.")
		return
	var arguments: Array[String] = [
		"activate",
		"--project", str(_package.project_root),
		"--install", str(_package.install_root),
		"--recovery-root", str(_package.recovery_root),
		"--stage", str(_package.stage_root),
		"--transaction", str(_package.transaction),
		"--from-version", str(_package.from_version),
		"--to-version", str(_package.to_version),
		"--manifest-sha256", str(_package.manifest_sha256),
		"--editor-pid", str(OS.get_process_id()),
		"--editor-nonce", str(_package.editor_nonce),
		"--readiness-timeout", str(STARTUP_TIMEOUT_SECONDS),
		"--claim-timeout", str(STARTUP_TIMEOUT_SECONDS),
	]
	_actor_pid = BridgeExec.create_process(_package.actor_command, arguments)
	if _actor_pid <= 1:
		_clear_environment()
		_set_status("The v4 transaction actor could not be started. Click Retry migration.")
		EditorInterface.set_plugin_enabled(PLUGIN_CFG, true)
		queue_free()
		return
	_phase = Phase.WAIT_STAGE


func _scan(rollback: bool) -> void:
	_rollback = rollback
	_phase = Phase.WAIT_SCAN
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		_enable_after_scan.call_deferred()
		return
	if not filesystem.filesystem_changed.is_connected(_enable_after_scan):
		filesystem.filesystem_changed.connect(_enable_after_scan, CONNECT_ONE_SHOT)
	filesystem.scan()


func _restart_into_v4() -> void:
	## The final-v3 plugin has loaded class_name resources whose cached method
	## shapes cannot be made equivalent to v4 by a filesystem scan. Godot's
	## own graceful restart preserves the transaction environment while giving
	## the authenticated v4 tree a clean script VM.
	## Disabling the capsule also removes it from editor_plugins/enabled. Persist
	## the next-start intent before restarting, but DO NOT enable the plugin in
	## this process: that would load v4 scripts into the old class cache.
	var enabled: Variant = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	if not enabled is PackedStringArray:
		_fail("The enabled-plugin settings are invalid; explicit recovery is required.")
		return
	var next_enabled: PackedStringArray = enabled.duplicate()
	if not next_enabled.has(PLUGIN_CFG):
		next_enabled.append(PLUGIN_CFG)
	ProjectSettings.set_setting("editor_plugins/enabled", next_enabled)
	var saved := _save_project_settings()
	if saved != OK:
		ProjectSettings.set_setting("editor_plugins/enabled", enabled)
		_fail("Could not save v4 startup settings (%s); explicit recovery is required." % error_string(saved))
		return
	print("MCP | v3 bridge restarting editor into canonical v4 tree")
	_phase = Phase.DONE
	set_process(false)
	EditorInterface.restart_editor(true)


func _save_project_settings() -> Error:
	return ProjectSettings.save()


func _enable_after_scan() -> void:
	if _phase != Phase.WAIT_SCAN:
		return
	if _rollback:
		_clear_environment()
		_set_status("The v4 activation rolled back safely. Click Retry migration.")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, true)
	if _rollback:
		queue_free()


func _record(name: String) -> Dictionary:
	var path := str(_package.recovery_root).path_join("transactions").path_join(str(_package.transaction)).path_join(name)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > 64 * 1024:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _fail(message: String) -> void:
	_set_status(message)
	_phase = Phase.DONE
	set_process(false)
	push_error("Godot AI v4 migration: %s" % message)


static func _set_status(error: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings != null:
		settings.set_setting(status_setting(), JSON.stringify({"error": error}))


static func status_setting() -> String:
	## A failed migration in one project must not block a different project.
	return STATUS_SETTING + "_" + ProjectSettings.globalize_path("res://").sha256_text()


static func _clear_environment() -> void:
	OS.unset_environment(TRANSACTION_ENV)
	OS.unset_environment(EDITOR_NONCE_ENV)
	OS.unset_environment(ACTOR_HANDOFF_ENV)


static func _valid_package(package: Dictionary) -> bool:
	var command: Variant = package.get("actor_command", [])
	if not command is Array or command.is_empty():
		return false
	for name in [
		"editor_nonce", "from_version", "install_root", "manifest_sha256",
		"project_root", "recovery_root", "stage_root", "to_version", "transaction",
	]:
		if str(package.get(name, "")).is_empty():
			return false
	return true
