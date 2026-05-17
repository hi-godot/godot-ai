@tool
extends McpTestSuite

## Tests for McpSettings utility helpers: truthy(), env_truthy(),
## and telemetry_enabled().

const _TENV1 := "GODOT_AI_DISABLE_TELEMETRY"
const _TENV2 := "DISABLE_TELEMETRY"

var _saved_tenv1: Variant = null
var _saved_tenv2: Variant = null
var _saved_telemetry_setting: Variant = null


func suite_name() -> String:
	return "settings"


func suite_setup(_ctx: Dictionary) -> void:
	_saved_tenv1 = OS.get_environment(_TENV1) if OS.has_environment(_TENV1) else null
	_saved_tenv2 = OS.get_environment(_TENV2) if OS.has_environment(_TENV2) else null
	var es := EditorInterface.get_editor_settings()
	if es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
		_saved_telemetry_setting = es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)


func suite_teardown() -> void:
	_restore_env(_TENV1, _saved_tenv1)
	_restore_env(_TENV2, _saved_tenv2)
	# NB: If originally unset, _saved_telemetry_setting will be null and this will unset any
	# value set by tests. No-op if already unset and then set to null.
	EditorInterface.get_editor_settings().set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, _saved_telemetry_setting)


func _restore_env(name: String, saved: Variant) -> void:
	if saved == null:
		OS.unset_environment(name)
	else:
		OS.set_environment(name, str(saved))


# ----- truthy -----

func test_truthy_accepts_1() -> void:
	assert_true(McpSettings.truthy("1"))

func test_truthy_accepts_true() -> void:
	assert_true(McpSettings.truthy("true"))

func test_truthy_accepts_yes() -> void:
	assert_true(McpSettings.truthy("yes"))

func test_truthy_accepts_on() -> void:
	assert_true(McpSettings.truthy("on"))

func test_truthy_is_case_insensitive() -> void:
	assert_true(McpSettings.truthy("TRUE"))
	assert_true(McpSettings.truthy("True"))
	assert_true(McpSettings.truthy("YES"))
	assert_true(McpSettings.truthy("ON"))

func test_truthy_strips_whitespace() -> void:
	assert_true(McpSettings.truthy("  1  "))
	assert_true(McpSettings.truthy("\ttrue\n"))

func test_truthy_rejects_empty() -> void:
	assert_false(McpSettings.truthy(""))

func test_truthy_rejects_false() -> void:
	assert_false(McpSettings.truthy("false"))

func test_truthy_rejects_zero() -> void:
	assert_false(McpSettings.truthy("0"))

func test_truthy_rejects_arbitrary_string() -> void:
	assert_false(McpSettings.truthy("maybe"))


# ----- env_truthy -----

func test_env_truthy_returns_true_when_var_set_truthy() -> void:
	OS.set_environment(_TENV1, "1")
	assert_true(McpSettings.env_truthy(_TENV1))

func test_env_truthy_returns_false_when_var_set_falsy() -> void:
	OS.set_environment(_TENV1, "false")
	assert_false(McpSettings.env_truthy(_TENV1))

func test_env_truthy_returns_false_when_var_absent() -> void:
	OS.unset_environment(_TENV1)
	assert_false(McpSettings.env_truthy(_TENV1))


# ----- telemetry_enabled -----

func test_telemetry_enabled_returns_false_when_disable_env_set() -> void:
	OS.set_environment(_TENV1, "1")
	OS.unset_environment(_TENV2)
	assert_false(McpSettings.telemetry_enabled())

func test_telemetry_enabled_returns_false_when_alt_env_set() -> void:
	OS.unset_environment(_TENV1)
	OS.set_environment(_TENV2, "true")
	assert_false(McpSettings.telemetry_enabled())

func test_telemetry_enabled_reads_editor_setting_when_no_env() -> void:
	OS.unset_environment(_TENV1)
	OS.unset_environment(_TENV2)
	EditorInterface.get_editor_settings().set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, false)
	assert_false(McpSettings.telemetry_enabled())
	EditorInterface.get_editor_settings().set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, true)
	assert_true(McpSettings.telemetry_enabled())

func test_telemetry_enabled_defaults_true_when_no_env_and_no_setting() -> void:
	OS.unset_environment(_TENV1)
	OS.unset_environment(_TENV2)
	var es := EditorInterface.get_editor_settings()
	es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, null)
	assert_true(McpSettings.telemetry_enabled(), "absent setting must default to enabled")

func test_telemetry_env_overrides_editor_setting() -> void:
	OS.set_environment(_TENV1, "1")
	EditorInterface.get_editor_settings().set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, true)
	assert_false(McpSettings.telemetry_enabled(),
		"env var opt-out must win over EditorSetting true")
