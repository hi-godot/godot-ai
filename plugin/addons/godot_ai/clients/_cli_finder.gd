@tool
class_name McpCliFinder
extends RefCounted

## Generic three-tier CLI resolution for clients whose binary lives somewhere
## a GUI-launched Godot's minimal PATH won't see:
##   1. Well-known install locations (~/.local/bin, /opt/homebrew/bin, ...)
##   2. Login shell lookup (`bash -lc 'command -v <exe>'`) — picks up .zshrc / .bashrc
##   3. Plain `which` / `where` against the inherited PATH
## Caches per-exe so repeated dock refreshes don't fork a shell every frame.
##
## Thread safety: `find()` runs on action-worker threads
## (`_run_client_action_worker` in `mcp_dock.gd`), and `invalidate()` runs on
## the main thread (manual Refresh path). Godot `Dictionary` is not safe for
## concurrent mutation, so `_cache` / `_searched` access is guarded by
## `_mutex`. The mutex is held only across dictionary read/write — the slow
## `_resolve()` path (FileAccess + bounded subprocess lookup) runs unlocked, so a
## main-thread `invalidate()` can never block on a worker's subprocess.
## Two workers racing the same exe both call `_resolve()` and both write
## back the same answer; that's wasted work, not corruption.


static var _mutex: Mutex = Mutex.new()
static var _cache: Dictionary = {}  # exe_name -> resolved path (or "")
static var _searched: Dictionary = {}

const _LOOKUP_TIMEOUT_MS := 3000


## Find any of the supplied exe names; returns the first hit.
## On Windows pass the .exe variant in `exe_names` if relevant.
static func find(exe_names: Array[String], trace: Callable = Callable()) -> String:
	for name in exe_names:
		var hit := _find_one(name, trace)
		if not hit.is_empty():
			return hit
	return ""


## Drop cache for one exe (call after the user installs / reinstalls).
static func invalidate(exe_name: String = "") -> void:
	_mutex.lock()
	if exe_name.is_empty():
		_cache.clear()
		_searched.clear()
	else:
		_cache.erase(exe_name)
		_searched.erase(exe_name)
	_mutex.unlock()


static func _find_one(exe_name: String, trace: Callable = Callable()) -> String:
	var started := Time.get_ticks_msec()
	_mutex.lock()
	var already_searched: bool = _searched.get(exe_name, false)
	var cached: String = _cache.get(exe_name, "")
	_mutex.unlock()
	if already_searched:
		_trace_lookup(trace, "cache", "resolved" if not cached.is_empty() else "cached_miss", started, {}, true)
		return cached
	# `_resolve()` does FileAccess + bounded subprocess lookup (forks
	# `bash -lc` / `which`), which can take 100ms-1s. Holding the mutex across that
	# would let a concurrent `invalidate()` on the main thread freeze the
	# editor for the duration of the subprocess — which defeats the whole
	# point of running CLI lookup off the main thread.
	var hit := _resolve(exe_name, trace)
	_mutex.lock()
	_cache[exe_name] = hit
	_searched[exe_name] = true
	_mutex.unlock()
	return hit


static func _resolve(exe_name: String, trace: Callable = Callable()) -> String:
	var started := Time.get_ticks_msec()
	var is_windows := OS.get_name() == "Windows"

	# 1. Well-known locations
	for dir in _well_known_dirs():
		var full := dir.path_join(exe_name)
		if FileAccess.file_exists(full):
			_trace_lookup(trace, "well_known", "resolved", started)
			return full
	_trace_lookup(trace, "well_known", "no_match", started)

	# 2. Login shell lookup (Unix only)
	if not is_windows:
		## env_lookup, not OS.get_environment: CLI resolution runs on dock
		## worker threads (configure/remove actions) and must not race the
		## spawn window's setenv/unsetenv (#691).
		var shell := McpPathTemplate.env_lookup("SHELL")
		if shell.is_empty():
			shell = "/bin/bash"
		var stripped := exe_name.trim_suffix(".exe")
		started = Time.get_ticks_msec()
		var login_result := McpCliExec.run(shell, ["-lc", "command -v %s" % stripped], _LOOKUP_TIMEOUT_MS, false)
		if int(login_result.get("exit_code", -1)) == 0:
			var login_found: String = str(login_result.get("stdout", "")).strip_edges()
			if not login_found.is_empty() and FileAccess.file_exists(login_found):
				_trace_lookup(trace, "login_shell", "resolved", started, login_result)
				return login_found
		_trace_lookup(trace, "login_shell", _lookup_failure(login_result, false), started, login_result)

	# 3. which / where with inherited PATH
	var lookup := "where" if is_windows else "which"
	started = Time.get_ticks_msec()
	var result := McpCliExec.run(lookup, [exe_name], _LOOKUP_TIMEOUT_MS, false)
	if int(result.get("exit_code", -1)) == 0:
		var output := str(result.get("stdout", ""))
		var lines := PackedStringArray(output.split("\n"))
		var found := _pick_best_path(lines) if is_windows else lines[0].strip_edges()
		if not found.is_empty():
			_trace_lookup(trace, "inherited_path", "resolved", started, result)
			return found
	_trace_lookup(trace, "inherited_path", _lookup_failure(result, true), started, result)
	return ""


static func _lookup_failure(result: Dictionary, absence_exit: bool) -> String:
	for flag in ["termination_failed", "cancelled", "timed_out", "spawn_failed"]:
		if bool(result.get(flag, false)):
			return flag
	var code := int(result.get("exit_code", -1))
	if code == 0:
		return "empty_output" if str(result.get("stdout", "")).strip_edges().is_empty() else "unusable_output"
	return "not_found" if absence_exit and code == 1 else "nonzero_exit"


static func _trace_lookup(
	trace: Callable, tier: String, status: String, started: int,
	result: Dictionary = {}, cache_hit := false,
) -> void:
	if not trace.is_valid():
		return
	trace.call({
		"tier": tier, "status": status,
		"elapsed_ms": clampi(Time.get_ticks_msec() - started, 0, 2147483647),
		"cache_hit": cache_hit,
		"exit_code": clampi(int(result.get("exit_code", -1)), -2147483648, 2147483647),
		"timed_out": bool(result.get("timed_out", false)),
		"spawn_failed": bool(result.get("spawn_failed", false)),
		"cancelled": bool(result.get("cancelled", false)),
		"termination_failed": bool(result.get("termination_failed", false)),
	})


## Executable extensions Windows' CreateProcessW can launch from a path
## (after the cmd.exe wrap in `_cli_exec.gd`). Order is preference: `.exe`
## is a native PE binary; `.cmd` / `.bat` go through the shell; `.com` is
## the legacy COM-format executable that some shims still ship.
const _WINDOWS_EXEC_EXTS := [".exe", ".cmd", ".bat", ".com"]


## Pick the best path from `where` output on Windows.
##
## npm-installed Node CLIs ship as BOTH `<dir>/<name>` (a POSIX bash shim
## for WSL / Git Bash users) AND `<dir>/<name>.cmd` (the actual Windows
## wrapper). `where <name>` lists both. CreateProcessW — the underlying
## syscall behind `OS.execute_with_pipe` — refuses to launch the
## extensionless POSIX shim, surfacing as
## `ERROR: Could not create child process: "...\claude" mcp list`
## in Godot's output log (#251). Picking a path with a real executable
## extension dodges that entirely.
##
## Extension scan is the OUTER loop so the order in `_WINDOWS_EXEC_EXTS`
## drives preference — `.exe` wins over `.cmd` even when the `.cmd` shows
## up first in `where` output (one fewer process per shell-out). Falls
## back to the first non-empty line when no entry has a recognised
## extension, so we never come up empty when `where` returned *something*.
static func _pick_best_path(lines: PackedStringArray) -> String:
	var stripped := PackedStringArray()
	for raw in lines:
		var line := raw.strip_edges()
		if not line.is_empty():
			stripped.append(line)
	if stripped.is_empty():
		return ""
	for ext in _WINDOWS_EXEC_EXTS:
		for candidate in stripped:
			if candidate.to_lower().ends_with(ext):
				return candidate
	return stripped[0]


static func _well_known_dirs() -> Array[String]:
	## env_lookup, not OS.get_environment — see _resolve()'s worker-thread
	## note (#691).
	var home := McpPathTemplate.env_lookup("HOME")
	if home.is_empty():
		home = McpPathTemplate.env_lookup("USERPROFILE")
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
			var local := McpPathTemplate.env_lookup("LOCALAPPDATA")
			var prog := McpPathTemplate.env_lookup("ProgramFiles")
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
