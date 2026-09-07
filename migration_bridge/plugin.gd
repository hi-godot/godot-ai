@tool
extends EditorPlugin

## Temporary v3-compatible entry point delivered through the signed legacy
## updater asset. It owns presentation only. Verification and staging run in
## the detached bridge node; the value-only coordinator survives this plugin
## being disabled and performs the swap and restart.

const MigrationBridge := preload("res://addons/godot_ai/migration_bridge.gd")
const MigrationCoordinator := preload("res://addons/godot_ai/migration_coordinator.gd")
const MigrationFallback := preload("res://addons/godot_ai/migration_fallback.gd")
const FLOOR_REFUSAL := "Godot AI v4 migration requires Godot 4.7 or newer; bridge remains inactive."
const FLOOR_MESSAGE := "Godot AI v4 requires Godot 4.7 or newer. Upgrade Godot, reopen this project, then click Retry."
const FLOOR_RESTORING := (
	"Godot AI v4 requires Godot 4.7 or newer. Restoring the previous Godot AI version; "
	+ "upgrade Godot to update."
)
const EDITOR_REQUIRED := (
	"Godot AI v4 migration needs the interactive Godot editor. "
	+ "Reopen the project in the editor (not headless or exported), then click Retry migration."
)

var _dock: VBoxContainer
var _label: Label
var _retry: Button
var _bridge
var _coordinator


func _enter_tree() -> void:
	_build_dock()
	var prior := _bridge_status()
	if not prior.is_empty():
		_present_error(str(prior.get("error", "The previous migration attempt did not finish.")))
		return
	if not _editor_available():
		## Headless imports and exports must never mutate the tree, not even
		## to restore final v3; the next interactive start handles it.
		_present_state(EDITOR_REQUIRED, true, false)
		return
	if not _meets_floor():
		print(FLOOR_REFUSAL)
		## The user's updater already overlaid the capsule over their v3 tree.
		## Put the final v3 back so nothing is lost; without the fallback (an
		## older capsule) the bridge can only wait for a newer Godot.
		if MigrationFallback.available():
			_present_state(FLOOR_RESTORING, false, false)
			var fallback: Node = MigrationFallback.new()
			_parent_node().add_child(fallback)
			fallback.start()
			return
		_present_state(FLOOR_MESSAGE, true, false)
		return
	_start_migration.call_deferred()


func _exit_tree() -> void:
	_free_bridge()
	if _coordinator != null and is_instance_valid(_coordinator):
		## The coordinator outlives this plugin on purpose; it disables the
		## capsule and keeps running. Only stop listening to it.
		if _coordinator.state_changed.is_connected(_present_state):
			_coordinator.state_changed.disconnect(_present_state)
	_coordinator = null
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
	if _bridge != null or _coordinator != null:
		return
	_clear_bridge_status()
	_retry.visible = false
	_label.text = "Preparing the signed Godot AI v4 migration…"
	print("MCP | v3 bridge verifying and staging the signed v4 tree")
	_bridge = MigrationBridge.new()
	_bridge.state_changed.connect(_present_state)
	_bridge.prepared.connect(_activate_prepared)
	_parent_node().add_child(_bridge)
	_bridge.start()


func _present_state(message: String, failed: bool = false, record: bool = true) -> void:
	if failed:
		print("MCP | v3 bridge: %s" % message)
		if record:
			MigrationCoordinator.record_status(message)
		_free_bridge()
		_coordinator = null
	if _label != null:
		_label.text = message
	if _retry != null:
		_retry.visible = failed


func _present_error(message: String) -> void:
	_present_state(message, true)


func _activate_prepared(package: Dictionary) -> void:
	_free_bridge()
	print("MCP | v3 bridge activating canonical v4 tree")
	_coordinator = MigrationCoordinator.new()
	_coordinator.state_changed.connect(_present_state)
	_parent_node().add_child(_coordinator)
	_coordinator.start(package)


func _on_retry() -> void:
	if not _meets_floor():
		_present_state(FLOOR_MESSAGE, true, false)
		return
	if not _editor_available():
		_present_state(EDITOR_REQUIRED, true, false)
		return
	_start_migration()


func _free_bridge() -> void:
	if _bridge != null and is_instance_valid(_bridge):
		_bridge.queue_free()
	_bridge = null


func _parent_node() -> Node:
	var parent: Node = EditorInterface.get_base_control()
	return parent if parent != null else get_tree().root


static func _meets_floor() -> bool:
	## Test-only: lets a scenario exercise the refusal path on a current Godot.
	if OS.get_environment("GODOT_AI_TEST_GODOT_FLOOR") == "unmet":
		return false
	var version := Engine.get_version_info()
	return int(version.get("major", 0)) == 4 and int(version.get("minor", 0)) >= 7


## Updates are interactive-only: a headless import or an export run loads
## enabled plugins too, and must never swap the add-on tree or restart.
static func _editor_available() -> bool:
	if not Engine.is_editor_hint():
		return false
	if _truthy(OS.get_environment("GODOT_AI_ALLOW_HEADLESS")):
		## The override the v4 plugin honours too, so CI can drive the
		## crossing in a headless editor. Never set it for a real install.
		return EditorInterface.get_base_control() != null
	if DisplayServer.get_name().to_lower() == "headless":
		return false
	if _args_request_headless(OS.get_cmdline_args()):
		return false
	return EditorInterface.get_base_control() != null


static func _truthy(value: String) -> bool:
	var lowered := value.strip_edges().to_lower()
	return lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"


static func _args_request_headless(args: PackedStringArray) -> bool:
	for i in range(args.size()):
		var arg := args[i]
		if arg == "--headless":
			return true
		if arg == "--display-driver" and i + 1 < args.size() and args[i + 1] == "headless":
			return true
		if arg.begins_with("--display-driver=") and arg.get_slice("=", 1) == "headless":
			return true
	return false


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
