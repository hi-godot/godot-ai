@tool
extends McpTestSuite

## Tests for export/mcp_export_plugin.gd (#740) — the EditorExportPlugin
## that strips the `_mcp_game_helper` autoload from exported packs.
##
## These tests drive the _export_begin/_export_end callbacks directly
## against the live editor's ProjectSettings (the test_project has the
## autoload registered by plugin.gd). The real export pipeline is covered
## end-to-end by script/ci-export-strip-smoke, which exports an actual
## pack and asserts the autoload is absent inside it; this suite locks
## the strip/restore state machine and its edge cases.

const ExportPlugin := preload("res://addons/godot_ai/export/mcp_export_plugin.gd")
const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")

const KEY := "autoload/_mcp_game_helper"
const CANONICAL_VALUE := "*res://addons/godot_ai/runtime/game_helper.gd"

var _orig_value: Variant = null
var _had_setting := false


func suite_name() -> String:
	return "export_strip"


func setup() -> void:
	_had_setting = ProjectSettings.has_setting(KEY)
	_orig_value = ProjectSettings.get_setting(KEY, "") if _had_setting else null


func teardown() -> void:
	## Whatever a test did, put the live editor's setting back exactly as
	## we found it so later suites (and the editor session itself) see the
	## real autoload registration.
	if _had_setting:
		ProjectSettings.set_setting(KEY, _orig_value)
		ProjectSettings.set_initial_value(KEY, "")
		ProjectSettings.set_as_basic(KEY, true)
	elif ProjectSettings.has_setting(KEY):
		ProjectSettings.set_setting(KEY, null)


func _make_plugin() -> EditorExportPlugin:
	return ExportPlugin.new()


static func _begin(plugin: EditorExportPlugin) -> void:
	plugin._export_begin(PackedStringArray(), false, "/tmp/ignored.pck", 0)


# ----- constants contract -----

func test_autoload_key_matches_plugin_gd() -> void:
	## The key is duplicated in the export plugin to avoid a cyclic
	## preload with plugin.gd. This test is the lock that keeps the two
	## in sync — if GAME_HELPER_AUTOLOAD_NAME ever changes, this fails.
	assert_eq(
		ExportPlugin.AUTOLOAD_KEY,
		"autoload/" + GodotAiPlugin.GAME_HELPER_AUTOLOAD_NAME,
		"export plugin must strip exactly the autoload plugin.gd registers"
	)


# ----- strip / restore -----

func test_begin_strips_setting_and_end_restores_it() -> void:
	ProjectSettings.set_setting(KEY, CANONICAL_VALUE)
	var plugin := _make_plugin()

	_begin(plugin)
	assert_false(ProjectSettings.has_setting(KEY), "autoload must be gone during export")

	plugin._export_end()
	assert_true(ProjectSettings.has_setting(KEY), "autoload must be restored after export")
	assert_eq(ProjectSettings.get_setting(KEY, ""), CANONICAL_VALUE)


func test_begin_preserves_nonstandard_value_verbatim() -> void:
	## If a user hand-edited the autoload value, restore must reproduce
	## their value, not the canonical one.
	var custom := "*res://somewhere/else/game_helper.gd"
	ProjectSettings.set_setting(KEY, custom)
	var plugin := _make_plugin()

	_begin(plugin)
	plugin._export_end()
	assert_eq(ProjectSettings.get_setting(KEY, ""), custom)


func test_disk_project_godot_untouched_while_stripped() -> void:
	## The strip is in-memory only: project.godot on disk keeps the
	## autoload for the whole export window (we never call save()).
	ProjectSettings.set_setting(KEY, CANONICAL_VALUE)
	var plugin := _make_plugin()

	_begin(plugin)
	var disk_text := FileAccess.get_file_as_string("res://project.godot")
	plugin._export_end()

	assert_true(
		disk_text.contains("_mcp_game_helper"),
		"project.godot on disk must keep the autoload during export"
	)


# ----- edge cases -----

func test_begin_noop_when_setting_absent() -> void:
	ProjectSettings.set_setting(KEY, null)
	var plugin := _make_plugin()

	_begin(plugin)
	assert_false(ProjectSettings.has_setting(KEY))

	plugin._export_end()
	assert_false(
		ProjectSettings.has_setting(KEY),
		"end must not invent a setting that was never stripped"
	)


func test_end_without_begin_is_noop() -> void:
	ProjectSettings.set_setting(KEY, CANONICAL_VALUE)
	var plugin := _make_plugin()

	plugin._export_end()
	assert_eq(ProjectSettings.get_setting(KEY, ""), CANONICAL_VALUE)


func test_double_begin_keeps_original_saved_value() -> void:
	## Simulates an export that died before _export_end: the next export's
	## _export_begin must not clobber the saved value with the
	## already-stripped state, and its _export_end must still restore the
	## original.
	ProjectSettings.set_setting(KEY, CANONICAL_VALUE)
	var plugin := _make_plugin()

	_begin(plugin)
	_begin(plugin)  ## second begin while stripped

	plugin._export_end()
	assert_eq(ProjectSettings.get_setting(KEY, ""), CANONICAL_VALUE)


func test_two_sequential_exports_roundtrip() -> void:
	ProjectSettings.set_setting(KEY, CANONICAL_VALUE)
	var plugin := _make_plugin()

	for i in 2:
		_begin(plugin)
		assert_false(ProjectSettings.has_setting(KEY), "export %d: stripped" % i)
		plugin._export_end()
		assert_eq(ProjectSettings.get_setting(KEY, ""), CANONICAL_VALUE, "export %d: restored" % i)
