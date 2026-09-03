@tool
extends EditorPlugin

## Temporary v3-compatible entry point delivered through the signed legacy
## updater asset. It owns presentation only. Preparation runs in the detached
## bridge node; the value-only coordinator survives this plugin being disabled.

const MigrationBridge := preload("res://addons/godot_ai/migration_bridge.gd")
const MigrationCoordinator := preload("res://addons/godot_ai/migration_coordinator.gd")
const FLOOR_REFUSAL := "Godot AI v4 migration requires Godot 4.7 or newer; bridge remains inactive."
const RESTART_REQUIRED := "Migration actor termination could not be proved. Restart Godot before retrying."

var _dock: VBoxContainer
var _label: Label
var _retry: Button
var _bridge


func _enter_tree() -> void:
	_build_dock()
	if Engine.has_meta(_restart_key()):
		_present_state(str(Engine.get_meta(_restart_key())), true, true)
		return
	var prior := _bridge_status()
	if not prior.is_empty():
		_present_error(str(prior.get("error", "The previous migration attempt did not finish.")))
		return
	var version := Engine.get_version_info()
	if int(version.get("major", 0)) != 4 or int(version.get("minor", 0)) < 7:
		print(FLOOR_REFUSAL)
		_present_error("Godot AI v4 requires Godot 4.7 or newer. Upgrade Godot, reopen this project, then click Retry.")
		return
	_start_migration.call_deferred()


func _exit_tree() -> void:
	if _bridge != null and is_instance_valid(_bridge):
		if not _bridge.cancel_and_join():
			Engine.set_meta(_restart_key(), RESTART_REQUIRED)
		_bridge.queue_free()
	_bridge = null
	if _dock != null and is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
	_dock = null


func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "Godot AI"
	_label = Label.new()
	_label.text = "Preparing the signed Godot AI v4 migration…"
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 15)
	_dock.add_child(_label)
	_retry = Button.new()
	_retry.text = "Retry migration"
	_retry.visible = false
	_retry.pressed.connect(_on_retry)
	_dock.add_child(_retry)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _start_migration() -> void:
	if _bridge != null or Engine.has_meta(_restart_key()):
		return
	_clear_bridge_status()
	_retry.visible = false
	_label.text = "Preparing the signed Godot AI v4 migration…"
	print("MCP | v3 bridge preparing signed v4 tree")
	_bridge = MigrationBridge.new()
	_bridge.state_changed.connect(_present_state)
	_bridge.prepared.connect(_activate_prepared)
	var parent: Node = EditorInterface.get_base_control()
	if parent == null:
		parent = get_tree().root
	parent.add_child(_bridge)
	_bridge.start()


func _present_state(message: String, failed: bool = false, termination_unproven: bool = false) -> void:
	if termination_unproven:
		message = RESTART_REQUIRED
		Engine.set_meta(_restart_key(), message)
	if failed:
		print("MCP | v3 bridge: %s" % message)
	if _label != null:
		_label.text = message
	if failed and _retry != null:
		_retry.visible = not Engine.has_meta(_restart_key())
		if _retry.visible:
			if _bridge != null and is_instance_valid(_bridge):
				_bridge.queue_free()
			_bridge = null


static func _restart_key() -> String:
	## Process-scoped and project-bound: plugin reload must not permit Retry.
	return "godot_ai_bridge_restart_" + ProjectSettings.globalize_path("res://").sha256_text()


func _present_error(message: String) -> void:
	_present_state(message, true)


func _activate_prepared(package: Dictionary) -> void:
	if _bridge != null and is_instance_valid(_bridge):
		_bridge.queue_free()
	_bridge = null
	print("MCP | v3 bridge activating canonical v4 tree")
	var coordinator = MigrationCoordinator.new()
	var parent: Node = EditorInterface.get_base_control()
	if parent == null:
		parent = get_tree().root
	parent.add_child(coordinator)
	if _dock != null and is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
	_dock = null
	coordinator.start(package)


func _on_retry() -> void:
	var version := Engine.get_version_info()
	if int(version.get("major", 0)) != 4 or int(version.get("minor", 0)) < 7:
		_present_error("Godot AI v4 requires Godot 4.7 or newer. Upgrade Godot and reopen this project first.")
		return
	_start_migration()


static func _bridge_status() -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	var key := MigrationCoordinator.status_setting()
	if settings == null or not settings.has_setting(key):
		return {}
	var parsed: Variant = JSON.parse_string(str(settings.get_setting(key)))
	return parsed if parsed is Dictionary else {}


static func _clear_bridge_status() -> void:
	var settings := EditorInterface.get_editor_settings()
	var key := MigrationCoordinator.status_setting()
	if settings != null and settings.has_setting(key):
		settings.erase(key)
