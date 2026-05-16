@tool
extends McpTestSuite

## Tests that the telemetry CheckButton in McpDock reflects env-var state.
## We instantiate McpDock directly (without adding it to the scene tree, so
## _ready() never fires) and inject a bare CheckButton into _telemetry_toggle
## before calling _load_telemetry_setting(), which is the method that drives
## the toggle's disabled state.

func suite_name() -> String:
	return "telemetry_toggle"


const _ENV1 := "GODOT_AI_DISABLE_TELEMETRY"
const _ENV2 := "DISABLE_TELEMETRY"

var _saved_env1: Variant = null
var _saved_env2: Variant = null
var _had_setting: bool = false
var _saved_setting: Variant = null


func suite_setup(_ctx: Dictionary) -> void:
	_saved_env1 = OS.get_environment(_ENV1) if OS.has_environment(_ENV1) else null
	_saved_env2 = OS.get_environment(_ENV2) if OS.has_environment(_ENV2) else null
	var es := EditorInterface.get_editor_settings()
	_had_setting = es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED)
	if _had_setting:
		_saved_setting = es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)


func suite_teardown() -> void:
	_restore_env(_ENV1, _saved_env1)
	_restore_env(_ENV2, _saved_env2)
	var es := EditorInterface.get_editor_settings()
	if not _had_setting:
		if es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
			## Setting didn't exist before tests ran — remove it if we added it.
			## NB: Passing null to set_setting is the intended way to unset editor settings in Godot 3/4.
			es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, null)
	else:
		es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, _saved_setting)


func _restore_env(name: String, saved: Variant) -> void:
	if saved == null:
		OS.unset_environment(name)
	else:
		OS.set_environment(name, str(saved))


func _clear_env_vars() -> void:
	OS.unset_environment(_ENV1)
	OS.unset_environment(_ENV2)


## Returns [dock, toggle] with the toggle already wired in.
## Caller must free both after the test.
func _make_dock_with_toggle() -> Array:
	var dock := McpDock.new()
	var toggle := CheckButton.new()
	dock._telemetry_toggle = toggle
	return [dock, toggle]


func test_toggle_disabled_when_godot_ai_disable_telemetry_set() -> void:
	_clear_env_vars()
	OS.set_environment(_ENV1, "true")
	var pair := _make_dock_with_toggle()
	var dock: McpDock = pair[0]
	var toggle: CheckButton = pair[1]
	dock._load_telemetry_setting()
	var disabled := toggle.disabled
	toggle.free()
	dock.free()
	assert_true(disabled, "toggle must be disabled when GODOT_AI_DISABLE_TELEMETRY=true")


func test_toggle_disabled_when_disable_telemetry_set() -> void:
	_clear_env_vars()
	OS.set_environment(_ENV2, "1")
	var pair := _make_dock_with_toggle()
	var dock: McpDock = pair[0]
	var toggle: CheckButton = pair[1]
	dock._load_telemetry_setting()
	var disabled := toggle.disabled
	toggle.free()
	dock.free()
	assert_true(disabled, "toggle must be disabled when DISABLE_TELEMETRY=1")


func test_toggle_enabled_when_no_env_var() -> void:
	_clear_env_vars()
	var pair := _make_dock_with_toggle()
	var dock: McpDock = pair[0]
	var toggle: CheckButton = pair[1]
	dock._load_telemetry_setting()
	var disabled := toggle.disabled
	toggle.free()
	dock.free()
	assert_false(disabled, "toggle must not be disabled when no env var is set")
