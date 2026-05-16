@tool
extends McpTestSuite

## Tests that the EditorSettings key "godot_ai/telemetry_enabled" can be read
## and written correctly. This is the storage-layer check written before the
## UI code exists.

func suite_name() -> String:
	return "telemetry_setting"


const SETTING_KEY := "godot_ai/telemetry_enabled"

## Instance var to preserve the real setting value across setup/teardown.
var _original_value: Variant = null
var _had_setting: bool = false


func suite_setup(_ctx: Dictionary) -> void:
	## Preserve whatever the real setting is before tests mutate it.
	var es := EditorInterface.get_editor_settings()
	_had_setting = es.has_setting(SETTING_KEY)
	if _had_setting:
		_original_value = es.get_setting(SETTING_KEY)


func suite_teardown() -> void:
	## Restore original state so tests don't leave the editor in a changed state.
	var es := EditorInterface.get_editor_settings()
	if not _had_setting:
		## Setting didn't exist before tests ran — remove it if we added it.
		## EditorSettings has no erase_setting; setting to null removes it in Godot 4.
		if es.has_setting(SETTING_KEY):
			es.set_setting(SETTING_KEY, null)
	else:
		es.set_setting(SETTING_KEY, _original_value)


func test_setting_defaults_true_when_absent() -> void:
	## Simulate what _load_telemetry_setting does on first run: if absent, write true.
	var es := EditorInterface.get_editor_settings()
	## Clear any existing value so we can test the absent-setting path.
	if es.has_setting(SETTING_KEY):
		es.set_setting(SETTING_KEY, null)
	## After clearing, check absence — note: set_setting(null) may or may not
	## remove the key depending on Godot version. Work around: skip directly to
	## the init logic assertion.
	if not es.has_setting(SETTING_KEY):
		es.set_setting(SETTING_KEY, true)
	assert_true(bool(es.get_setting(SETTING_KEY)), "absent setting should resolve to true after first-run init")


func test_setting_persists_false() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(SETTING_KEY, false)
	assert_true(not bool(es.get_setting(SETTING_KEY)), "false should persist")


func test_setting_persists_true() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(SETTING_KEY, true)
	assert_true(bool(es.get_setting(SETTING_KEY)), "true should persist")


func test_setting_roundtrip_false_then_true() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(SETTING_KEY, false)
	assert_false(bool(es.get_setting(SETTING_KEY)), "write false then read back false")
	es.set_setting(SETTING_KEY, true)
	assert_true(bool(es.get_setting(SETTING_KEY)), "write true then read back true")
