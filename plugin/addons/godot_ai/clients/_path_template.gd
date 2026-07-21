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
	var key := _os_key()
	if not template_map.has(key):
		# Allow "unix" as a shorthand for both macOS and Linux.
		if (key == "darwin" or key == "linux") and template_map.has("unix"):
			key = "unix"
		else:
			return ""
	var template: String = template_map[key]
	return expand(template)


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


static func _home() -> String:
	var h := env_lookup("HOME")
	if h.is_empty():
		h = env_lookup("USERPROFILE")
	return h
