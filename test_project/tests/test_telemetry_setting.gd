@tool
extends McpTestSuite

## Tests that the EditorSettings key "godot_ai/telemetry_enabled" can be read
## and written correctly. This suite covers the storage-layer behavior
## independently of any telemetry UI.

func suite_name() -> String:
	return "telemetry_setting"


## Instance var to preserve the real setting value across setup/teardown.
var _original_value: Variant = null
var _had_setting: bool = false


func suite_setup(_ctx: Dictionary) -> void:
	## Preserve whatever the real setting is before tests mutate it.
	var es := EditorInterface.get_editor_settings()
	_had_setting = es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED)
	if _had_setting:
		_original_value = es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)


func suite_teardown() -> void:
	## Restore original state so tests don't leave the editor in a changed state.
	var es := EditorInterface.get_editor_settings()
	if not _had_setting:
		## Setting didn't exist before tests ran — remove it if we added it.
		## NB: Passing null to set_setting is the intended way to unset editor settings in Godot 3/4.
		if es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
			es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, null)
	else:
		es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, _original_value)


func test_setting_defaults_true_when_absent() -> void:
	## Simulate what _load_telemetry_setting does on first run: if absent, write true.
	var es := EditorInterface.get_editor_settings()
	## Clear any existing value so we can test the absent-setting path.
	## NB: Passing null to set_setting is the intended way to unset editor settings in Godot 3/4.
	if es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
		es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, null)
	if not es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
		es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, true)
	assert_true(bool(es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)), "absent setting should resolve to true after first-run init")


func test_setting_persists_false() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, false)
	assert_true(not bool(es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)), "false should persist")


func test_setting_persists_true() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, true)
	assert_true(bool(es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)), "true should persist")


func test_setting_roundtrip_false_then_true() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, false)
	assert_false(bool(es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)), "write false then read back false")
	es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, true)
	assert_true(bool(es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)), "write true then read back true")
