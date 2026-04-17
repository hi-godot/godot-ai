@tool
class_name McpCliFinder
extends RefCounted

## Generic three-tier CLI resolution for clients whose binary lives somewhere
## a GUI-launched Godot's minimal PATH won't see:
##   1. Well-known install locations (~/.local/bin, /opt/homebrew/bin, ...)
##   2. Login shell lookup (`bash -lc 'command -v <exe>'`) — picks up .zshrc / .bashrc
##   3. Plain `which` / `where` against the inherited PATH
## Caches per-exe so repeated dock refreshes don't fork a shell every frame.


static var _cache: Dictionary = {}  # exe_name -> resolved path (or "")
static var _searched: Dictionary = {}


## Find any of the supplied exe names; returns the first hit.
## On Windows pass the .exe variant in `exe_names` if relevant.
static func find(exe_names: Array[String]) -> String:
	for name in exe_names:
		var hit := _find_one(name)
		if not hit.is_empty():
			return hit
	return ""


## Drop cache for one exe (call after the user installs / reinstalls).
static func invalidate(exe_name: String = "") -> void:
	if exe_name.is_empty():
		_cache.clear()
		_searched.clear()
	else:
		_cache.erase(exe_name)
		_searched.erase(exe_name)


static func _find_one(exe_name: String) -> String:
	if _searched.get(exe_name, false):
		return _cache.get(exe_name, "")
	var hit := _resolve(exe_name)
	_cache[exe_name] = hit
	_searched[exe_name] = true
	return hit


static func _resolve(exe_name: String) -> String:
	var is_windows := OS.get_name() == "Windows"

	# 1. Well-known locations
	for dir in _well_known_dirs():
		var full := dir.path_join(exe_name)
		if FileAccess.file_exists(full):
			return full

	# 2. Login shell lookup (Unix only)
	if not is_windows:
		var shell := OS.get_environment("SHELL")
		if shell.is_empty():
			shell = "/bin/bash"
		var login_output: Array = []
		var stripped := exe_name.trim_suffix(".exe")
		var login_exit := OS.execute(shell, ["-lc", "command -v %s" % stripped], login_output, true)
		if login_exit == 0 and login_output.size() > 0:
			var login_found: String = login_output[0].strip_edges()
			if not login_found.is_empty() and FileAccess.file_exists(login_found):
				return login_found

	# 3. which / where with inherited PATH
	var lookup := "where" if is_windows else "which"
	var output: Array = []
	var exit_code := OS.execute(lookup, [exe_name], output, true)
	if exit_code == 0 and output.size() > 0:
		var found: String = output[0].strip_edges().split("\n")[0].strip_edges()
		if not found.is_empty():
			return found
	return ""


static func _well_known_dirs() -> Array[String]:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	match OS.get_name():
		"macOS":
			return [
				home.path_join(".local/bin"),
				home.path_join(".claude/local"),
				home.path_join(".cargo/bin"),
				"/opt/homebrew/bin",
				"/usr/local/bin",
			]
		"Windows":
			var local := OS.get_environment("LOCALAPPDATA")
			var prog := OS.get_environment("ProgramFiles")
			var paths: Array[String] = []
			if not home.is_empty():
				paths.append(home.path_join(".claude/local"))
				paths.append(home.path_join(".local/bin"))
				paths.append(home.path_join(".cargo/bin"))
				paths.append(home.path_join("AppData/Local/Programs/uv"))
			if not local.is_empty():
				paths.append(local.path_join("Programs/uv"))
			if not prog.is_empty():
				paths.append(prog.path_join("uv"))
			return paths
		_:
			return [
				home.path_join(".local/bin"),
				home.path_join(".claude/local"),
				home.path_join(".cargo/bin"),
				"/usr/local/bin",
			]
