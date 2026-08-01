@tool
class_name McpPathTemplate
extends RefCounted

## Expands ~ / $HOME / $APPDATA / $XDG_CONFIG_HOME / $LOCALAPPDATA / $USERPROFILE
## inside path templates so per-client descriptors can declare paths declaratively
## without hand-rolling per-OS lookups.

## #691: dock worker threads (client-status refresh, configure/remove
## actions) and the #678 startup walk's discovery worker expand these
## templates off the main thread, while the spawn step mutates the
## process-global environment around `OS.create_process`
## (`GODOT_AI_OWNER_PID`, `GODOT_AI_PLUGIN_SPAWNED`, `PYTHONPATH`,
## `GODOT_AI_DISABLE_TELEMETRY`). A glibc `getenv` racing a concurrent
## `setenv` can return a freed pointer — rare but process-fatal. All env
## reads in this layer therefore go through `env_lookup`: on the MAIN
## thread it reads live and refreshes a mutex-guarded snapshot; off the
## main thread it serves from the snapshot, so no `OS.get_environment`
## runs concurrently with the spawn window's mutations. Callers pre-warm
## every var their workers can touch via `warm_env_snapshot` (plugin
## `_enter_tree` and the dock's phase-1 refresh prep, both main-thread,
## both before any worker starts).
static var _env_snapshot := {}
static var _env_snapshot_mutex := Mutex.new()

## Every var this layer and its sibling consumers (`_base.gd`
## `config_home_override`, `_cli_finder.gd` lookups,
## `client_configurator.gd` mode/trace reads) can touch off-main.
## Descriptor-declared `config_home_env` names are passed as extras by
## the warm callers.
const _BASE_ENV_VARS: Array[String] = [
	"HOME",
	"USERPROFILE",
	"XDG_CONFIG_HOME",
	"APPDATA",
	"LOCALAPPDATA",
	"SHELL",
	"ProgramFiles",
	"GODOT_AI_MODE",
	"GODOT_AI_STARTUP_TRACE",
	## #804 (#752 adoption): _find_venv_python reads this via env_lookup on
	## the dock's worker path; without pre-warming, a set override reads as
	## empty there and is silently ignored — the exact misconfiguration the
	## push_warning in client_configurator.gd exists to surface.
	"GODOT_AI_VENV_PYTHON",
]


## Thread-safe env read (#691). Main thread: live read + snapshot refresh.
## Worker thread: snapshot only, so it can never race a main-thread
## setenv/unsetenv. A worker read of a never-warmed var returns "" — the
## same value an unset var reads as — never a live OS.get_environment,
## which would reintroduce the race for exactly the vars nobody thought
## to warm. Missing warm-up degrades resolution; it must not touch the
## process-global environment off-main.
static func env_lookup(name: String) -> String:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		var live := OS.get_environment(name)
		_env_snapshot_mutex.lock()
		_env_snapshot[name] = live
		_env_snapshot_mutex.unlock()
		return live
	_env_snapshot_mutex.lock()
	var cached: Variant = _env_snapshot.get(name, null)
	_env_snapshot_mutex.unlock()
	if cached != null:
		return str(cached)
	return ""


## Main-thread pre-warm so subsequent worker reads never touch the real
## environment. Idempotent; safe to call before every worker dispatch.
static func warm_env_snapshot(extra_vars: PackedStringArray = PackedStringArray()) -> void:
	for var_name in _BASE_ENV_VARS:
		env_lookup(var_name)
	for var_name in extra_vars:
		if not String(var_name).is_empty():
			env_lookup(String(var_name))


## Pick the right entry from a {"darwin": ..., "windows": ..., "linux": ...} map.
static func resolve(template_map: Dictionary) -> String:
	var key := platform_key(template_map)
	if key.is_empty():
		return ""
	var template: String = template_map[key]
	return expand(template)


## Return the platform-specific key present in a descriptor map. `unix` is a
## shorthand for macOS and Linux. Public so descriptors can use the same
## platform selection for ordered path-candidate arrays as for one path.
static func platform_key(template_map: Dictionary) -> String:
	var key := _os_key()
	if template_map.has(key):
		return key
	if (key == "darwin" or key == "linux") and template_map.has("unix"):
		return "unix"
	return ""


## Expand one path template into zero or more concrete paths. A single `*` is
## allowed inside one DIRECTORY segment (for example `Packages/Claude_*`). The
## wildcard is resolved by enumerating that segment's parent; the remaining
## suffix may name a file that does not exist yet, which lets callers derive a
## deterministic create target for a fresh packaged-app install.
##
## Multiple wildcards fail closed and return no candidates. A wildcard final
## segment may identify an installation directory for `detect_paths`. Returned
## paths are sorted for deterministic tests and diagnostics; callers still
## reject ambiguous config groups rather than picking one.
static func expand_path_candidates(template: String) -> PackedStringArray:
	var expanded := expand(template)
	if expanded.is_empty():
		return PackedStringArray()
	var star := expanded.find("*")
	if star < 0:
		return PackedStringArray([expanded])
	if expanded.find("*", star + 1) >= 0:
		return PackedStringArray()

	var slash_before := maxi(expanded.rfind("/", star), expanded.rfind("\\", star))
	var forward_after := expanded.find("/", star)
	var backward_after := expanded.find("\\", star)
	var slash_after := forward_after
	if slash_after < 0 or (backward_after >= 0 and backward_after < slash_after):
		slash_after = backward_after
	if slash_before < 0:
		return PackedStringArray()

	var parent := expanded.substr(0, slash_before)
	var pattern := (
		expanded.substr(slash_before + 1)
		if slash_after < 0
		else expanded.substr(slash_before + 1, slash_after - slash_before - 1)
	)
	var suffix := "" if slash_after < 0 else expanded.substr(slash_after + 1)
	var pattern_star := pattern.find("*")
	if pattern_star < 0:
		return PackedStringArray()
	var prefix := pattern.substr(0, pattern_star)
	var ending := pattern.substr(pattern_star + 1)
	var dir := DirAccess.open(parent)
	if dir == null:
		return PackedStringArray()

	var matches := PackedStringArray()
	for child in dir.get_directories():
		if _wildcard_segment_matches(String(child), prefix, ending):
			var matched_path := parent.path_join(String(child))
			matches.append(matched_path if suffix.is_empty() else matched_path.path_join(suffix))
	matches.sort()
	return matches


## Substitute env vars and ~ in a single template string.
static func expand(template: String) -> String:
	if template.is_empty():
		return ""
	var out := template
	if out.begins_with("~/") or out == "~":
		var home := _home()
		out = home if out == "~" else home.path_join(out.substr(2))
	# $HOME, $APPDATA, $LOCALAPPDATA, $USERPROFILE, $XDG_CONFIG_HOME
	for var_name in ["XDG_CONFIG_HOME", "LOCALAPPDATA", "USERPROFILE", "APPDATA", "HOME"]:
		var token := "$%s" % var_name
		if out.find(token) >= 0:
			var value := env_lookup(var_name)
			if value.is_empty() and var_name == "XDG_CONFIG_HOME":
				value = _home().path_join(".config")
			if value.is_empty() and var_name == "APPDATA":
				value = _home().path_join("AppData/Roaming")
			if value.is_empty() and var_name == "LOCALAPPDATA":
				value = _home().path_join("AppData/Local")
			if value.is_empty() and var_name == "HOME":
				value = _home()
			out = out.replace(token, value)
	return out


static func _os_key() -> String:
	match OS.get_name():
		"macOS":
			return "darwin"
		"Windows":
			return "windows"
		_:
			return "linux"


static func _wildcard_segment_matches(value: String, prefix: String, ending: String) -> bool:
	# Prefix/suffix tests alone allow the two fixed portions to overlap inside a
	# too-short value. Glob semantics require room for both portions even when
	# `*` matches an empty string.
	if value.length() < prefix.length() + ending.length():
		return false
	if OS.get_name() == "Windows":
		return value.to_lower().begins_with(prefix.to_lower()) and value.to_lower().ends_with(ending.to_lower())
	return value.begins_with(prefix) and value.ends_with(ending)


static func _home() -> String:
	var h := env_lookup("HOME")
	if h.is_empty():
		h = env_lookup("USERPROFILE")
	return h
