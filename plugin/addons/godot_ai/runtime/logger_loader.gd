@tool
extends RefCounted

## Runtime builder for the `extends Logger` scripts in `runtime/loggers/`.
##
## `Logger` is a Godot 4.5+ class. A `.gd` file that statically declares
## `extends Logger` is rejected by the parser on Godot < 4.5 — and Godot's
## editor filesystem scan parses *every* `.gd` under the project, so just
## shipping `editor_logger.gd` / `game_logger.gd` printed two
## `Parse Error: Could not find base class "Logger"` lines on every 4.3/4.4
## editor startup (#475 follow-up). They were functionally harmless (the
## scripts are only ever instanced behind a `ClassDB.class_exists("Logger")`
## gate) but they were real red error text we shouldn't ship.
##
## Fix: the two logger scripts live in `runtime/loggers/`, which carries a
## `.gdignore` so the editor scan skips the folder entirely — no parse, no
## error, on any engine. This loader reads the source off disk with
## `FileAccess` (unaffected by `.gdignore`, which only governs the resource
## importer) and compiles it at runtime via `GDScript.new()`. Callers gate
## on `ClassDB.class_exists("Logger")` first, so `build()` only ever runs on
## 4.5+, where `extends Logger` resolves cleanly.
##
## This script itself does NOT extend Logger, so it parses on every engine
## and is safe to `preload` from `plugin.gd` and `game_helper.gd`.

const EDITOR_LOGGER_PATH := "res://addons/godot_ai/runtime/loggers/editor_logger.gd"
const GAME_LOGGER_PATH := "res://addons/godot_ai/runtime/loggers/game_logger.gd"


## Compile a `.gdignore`'d logger script from its on-disk source. Returns the
## ready-to-instance GDScript, or null if the file is missing (e.g. excluded
## from an exported game) or fails to compile. Callers must already have
## confirmed `ClassDB.class_exists("Logger")` — building an `extends Logger`
## script on an engine without the class will fail the reload() and return
## null, which the gated callers treat as "logging unavailable".
static func build(path: String) -> GDScript:
	if not FileAccess.file_exists(path):
		return null
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return null
	var script := GDScript.new()
	script.source_code = source
	## Deliberately do NOT set `script.resource_path`: this builds a fresh
	## anonymous GDScript every call, and a reload cycle (editor_reload_plugin,
	## self-update disable→enable) calls build() again for the same path. Two
	## live Resources sharing one non-empty resource_path trips Godot's
	## "Another resource is loaded from path ..." error and leaves the new
	## script with an empty path anyway — re-introducing red console text on
	## every reload, the exact thing this folder's .gdignore set out to remove.
	## game_helper.gd::_handle_eval compiles from source the same way and also
	## omits resource_path. The script still resolves its absolute preloads /
	## class_names fine without a path.
	if script.reload() != OK:
		return null
	return script
