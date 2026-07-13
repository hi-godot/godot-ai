@tool
extends EditorExportPlugin

## Strips the MCP game-helper autoload from exported builds (#740).
##
## plugin.gd writes `autoload/_mcp_game_helper` into project.godot so the
## editor-spawned game process loads the helper. Exports bake project
## settings into the pack's project.binary, so without this plugin every
## export ships the autoload — and users who exclude addons/godot_ai/**
## in their export preset get three "Failed to instantiate an autoload"
## errors at game start. Even when the files ARE shipped, the helper is
## editor-tooling: no exported build should carry it.
##
## Strip mechanics: clear the in-memory ProjectSettings entry in
## _export_begin, restore it in _export_end. The export pipeline reads
## the live ProjectSettings when it bakes project.binary, which happens
## after _export_begin — verified end-to-end by
## script/ci-export-strip-smoke, which exports a real pack and asserts
## the autoload is absent inside it. We never call ProjectSettings.save()
## while stripped, so project.godot on disk keeps the autoload
## throughout; only the export snapshot loses it.
##
## Failure containment: if an export aborts so hard that _export_end
## never fires, the damage is bounded to the editor's in-memory settings
## — the running game reads project.godot from disk, and plugin.gd's
## _ensure_game_helper_autoload() re-asserts the entry on the next
## plugin enable / editor launch.

## Must equal "autoload/" + plugin.gd's GAME_HELPER_AUTOLOAD_NAME.
## Duplicated (not preloaded from plugin.gd) to avoid a cyclic preload —
## plugin.gd preloads this script. The pairing is locked by
## test_export_strip.gd's constants-contract test.
const AUTOLOAD_KEY := "autoload/_mcp_game_helper"

var _saved_value: Variant = null
var _stripped := false


func _get_name() -> String:
	return "GodotAIStripAutoload"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	## `_stripped` guard: if a previous export died before _export_end,
	## don't overwrite the genuinely-saved value with the already-cleared
	## state — restore semantics stay anchored to the original value.
	if _stripped:
		return
	if not ProjectSettings.has_setting(AUTOLOAD_KEY):
		return
	_saved_value = ProjectSettings.get_setting(AUTOLOAD_KEY)
	## Setting a project setting to null erases it.
	ProjectSettings.set_setting(AUTOLOAD_KEY, null)
	_stripped = true
	print("MCP | export: stripping %s from the exported pack (restored in the editor after export)" % AUTOLOAD_KEY)


func _export_end() -> void:
	if not _stripped:
		return
	ProjectSettings.set_setting(AUTOLOAD_KEY, _saved_value)
	## Mirror _ensure_game_helper_autoload()'s registration shape so the
	## restored entry is indistinguishable from the original: initial
	## value "" keeps project.godot diff-clean, basic keeps it visible in
	## the non-advanced settings view.
	ProjectSettings.set_initial_value(AUTOLOAD_KEY, "")
	ProjectSettings.set_as_basic(AUTOLOAD_KEY, true)
	_saved_value = null
	_stripped = false
