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

const LinuxProc := preload("res://addons/godot_ai/utils/linux_proc.gd")
const _MOUNTINFO_PATH := "/proc/self/mountinfo"

## `/.flatpak-info` as Flatpak wrote it before this process started, or "" when
## this is not a Flatpak sandbox. The sandbox it describes cannot change while
## the process runs, so one read serves every thread. Guarded by
## `_env_snapshot_mutex`, like the snapshot it is consulted alongside.
static var _flatpak_info := ""
static var _flatpak_info_read := false
## What that sandbox mounted, from `/proc/self/mountinfo`: read with the file
## above, and only inside a sandbox. Empty when it could not be read.
static var _flatpak_mounts: Array[Dictionary] = []

## Every var this layer and its sibling consumers (`_base.gd`
## `config_file_override_details`, `config_home_override_details`, `_cli_finder.gd` lookups,
## `client_configurator.gd` mode/trace reads) can touch off-main.
## Descriptor-declared config-file/config-home env names are passed as extras
## by the warm callers.
const _BASE_ENV_VARS: Array[String] = [
	"HOME",
	"USERPROFILE",
	"XDG_CONFIG_HOME",
	## What `$XDG_CONFIG_HOME` reads in a Flatpak editor — see `_env_source`.
	"HOST_XDG_CONFIG_HOME",
	## Read by `flatpak_hides_credentials` on the workers that run Configure.
	"GODOT_AI_CAPABILITY_DIR",
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
	_flatpak_info_text()


## Cached `/.flatpak-info`, read on first use from whichever thread asks. Only
## Linux has Flatpak; elsewhere the leading slash would name a drive root.
static func _flatpak_info_text() -> String:
	_env_snapshot_mutex.lock()
	_read_flatpak_sandbox()
	var info := _flatpak_info
	_env_snapshot_mutex.unlock()
	return info


## The sandbox's mounts, cached with the description above. The list is built
## once and never changed, so callers on any thread may read it.
static func _flatpak_mount_list() -> Array[Dictionary]:
	_env_snapshot_mutex.lock()
	_read_flatpak_sandbox()
	var mounts := _flatpak_mounts
	_env_snapshot_mutex.unlock()
	return mounts


## Caller holds `_env_snapshot_mutex`.
static func _read_flatpak_sandbox() -> void:
	if _flatpak_info_read:
		return
	_flatpak_info = McpTransportCapability._flatpak_info() if _os_key() == "linux" else ""
	var mountinfo := ""
	if not _flatpak_info.is_empty():
		mountinfo = str(LinuxProc.read_text(_MOUNTINFO_PATH).text)
	_flatpak_mounts = McpTransportCapability.parse_mountinfo(mountinfo)
	_flatpak_info_read = true


## Stand in for the sandbox description so tests can cover Flatpak resolution
## on any host, with `mountinfo` as its `/proc/self/mountinfo`: by default no
## mount evidence at all, never the real file's. Pass null to forget both; the
## next read then asks the real files.
static func _set_flatpak_info_for_test(info: Variant, mountinfo: String = "") -> void:
	_env_snapshot_mutex.lock()
	_flatpak_info = "" if info == null else str(info)
	_flatpak_mounts = McpTransportCapability.parse_mountinfo(mountinfo)
	_flatpak_info_read = info != null
	_env_snapshot_mutex.unlock()


## This editor's Flatpak application ID, or "" outside Flatpak.
static func flatpak_app_id() -> String:
	return McpTransportCapability.flatpak_application_id(_flatpak_info_text())


## The host's config directory when this editor is a Flatpak that shares it
## (through the home directory, or a grant for the whole of `xdg-config`); ""
## anywhere else, and when it cannot be resolved. For callers whose own
## default is `OS.get_config_dir()`, which in that sandbox is the per-app
## directory that nothing outside it reads.
static func flatpak_host_config_home() -> String:
	if not McpTransportCapability.flatpak_shares_config_home(_flatpak_info_text()):
		return ""
	var config_home := expand("$XDG_CONFIG_HOME")
	return config_home if config_home.is_absolute_path() else ""


## Whether this editor's Flatpak sandbox keeps Godot AI's credentials where a
## client outside it does not look. The bridge a client starts reads the
## host's `<config home>/godot-ai/capabilities`, so an entry Configure writes
## from such a sandbox cannot connect, however right its file is.
##
## The server publishes in the host's config directory when the sandbox
## shares it (`McpTransportCapability.linux_config_home_variable`), and
## otherwise in the per-app one, which is the host's only where an
## `xdg-config/` grant mounted the host's directory inside it. Either way the
## host's directory has to be shared read-write, which `flatpak_write_block`
## decides. An editor given `GODOT_AI_CAPABILITY_DIR` publishes somewhere this
## cannot judge, and its client needs the same variable: never hidden here.
static func flatpak_hides_credentials() -> bool:
	var info := _flatpak_info_text()
	if info.is_empty():
		return false
	if not env_lookup(McpTransportCapability.CAPABILITY_DIR_ENV).strip_edges().is_empty():
		return false
	var config_home := expand("$XDG_CONFIG_HOME")
	if not config_home.is_absolute_path():
		return false
	var host_directory := config_home.path_join("godot-ai/capabilities")
	if not flatpak_write_block(host_directory.path_join("http.json")).is_empty():
		return true
	if McpTransportCapability.flatpak_shares_config_home(info):
		return false
	var grant := McpTransportCapability.flatpak_grant_over(
		info, host_directory, _home(), config_home
	)
	return not str(grant.get("location", "")).begins_with("xdg-config/")


## The `~/.var/app/<id>` directory of another Flatpak app that `path` lies in,
## when this editor's own Flatpak sandbox does not show it; "" otherwise.
## Flatpak mounts only the running app's directory under `~/.var/app`, and a
## `host` or `home` grant does not widen that. From in here another app's
## settings are therefore unknown rather than absent until the user grants
## that directory by name, and anything created below it would land on the
## sandbox's private tmpfs.
static func hidden_flatpak_app_dir(path: String) -> String:
	if _flatpak_info_text().is_empty():
		return ""
	var home := _home()
	if home.is_empty():
		return ""
	var apps := home.path_join(".var/app") + "/"
	if not path.begins_with(apps):
		return ""
	var app_dir := apps + path.trim_prefix(apps).get_slice("/", 0)
	return "" if DirAccess.dir_exists_absolute(app_dir) else app_dir


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
##
## A token that cannot be resolved — the var is unset and no home-derived
## fallback applies, or a dock worker's env snapshot was never warmed with it —
## is LEFT IN PLACE rather than replaced with "". Substituting "" is what turns
## `$USERPROFILE/godot` into `/godot`: a root-relative path that
## `is_absolute_path()` accepts, so every fail-closed guard downstream waves it
## through and the caller reads or writes a directory the user never named.
## `$USERPROFILE` is the easy repro (unset off Windows, and the only one of
## these vars with no fallback), but `$HOME`/`$XDG_CONFIG_HOME`/`$APPDATA`/
## `$LOCALAPPDATA` reach the same state whenever `_home()` is empty, which the
## missing-warm-up degradation above makes reachable on a worker thread.
##
## The surviving token keeps the result non-absolute, so those guards catch it,
## and the unexpanded path they report still shows what failed to resolve.
## `~` is left alone for the same reason: collapsing `~/godot` to the relative
## `godot` aims it at the editor's own working directory.
static func expand(template: String) -> String:
	if template.is_empty():
		return ""
	var out := template
	if out.begins_with("~/") or out == "~":
		var home := _home()
		if not home.is_empty():
			out = home if out == "~" else home.path_join(out.substr(2))
	# $HOME, $APPDATA, $LOCALAPPDATA, $USERPROFILE, $XDG_CONFIG_HOME
	for var_name in ["XDG_CONFIG_HOME", "LOCALAPPDATA", "USERPROFILE", "APPDATA", "HOME"]:
		var token := "$%s" % var_name
		if out.find(token) < 0:
			continue
		var value := env_lookup(_env_source(var_name))
		if value.is_empty():
			value = _home_fallback(var_name)
		if value.is_empty():
			continue
		out = out.replace(token, value)
	return out


## The environment variable a token's value is read from. Flatpak points
## `XDG_CONFIG_HOME` at the editor's own `~/.var/app/<id>/config`, where no
## client looks: a path expanded from it is written, read back, and reported
## as configured without the client ever seeing it. Inside a sandbox the token
## therefore reads the host's variable, so a template always names the file
## the client reads. Whether this sandbox can reach that file is a separate
## question, answered by `flatpak_write_block`. Every grant that shares part
## of the host's config directory mounts it at the host's path, an
## `xdg-config/<dir>` grant included, so no path has to go through the per-app
## directory, where a leftover from an earlier run would pass for the client's
## own file.
static func _env_source(var_name: String) -> String:
	if var_name == "XDG_CONFIG_HOME" and not _flatpak_info_text().is_empty():
		return "HOST_XDG_CONFIG_HOME"
	return var_name


## Why a file this editor writes at `path` would not be the one a client
## outside its Flatpak sandbox reads there. {} when it would be, and always
## outside Flatpak. Otherwise one of:
## - {"needs": grant}: no read-write grant covers the file's directory, and
##   this is the `--filesystem=` value that would. That is the read-only grant
##   that does cover it when there is one, because a wider grant does not
##   lift it.
## - {"unmounted": directory}: a read-write grant names this directory, but
##   Flatpak mounted nothing there, which is what it does when the directory
##   does not exist as the app starts.
## - {"hidden": directory}: inside a granted directory, this one is an empty
##   tmpfs, which is how Flatpak carries out a denial (`--nofilesystem`).
## - {"read_only": directory}: granted read-write, mounted read-only.
##
## The directory is what has to be shared, not the file: `McpAtomicWrite`
## stages a temporary file beside the target and renames it into place, which
## cannot replace a file Flatpak mounted on its own. It also follows a
## symlinked config file to its target, so that is the file tested.
static func flatpak_write_block(path: String) -> Dictionary:
	var info := _flatpak_info_text()
	if info.is_empty():
		return {}
	var directory := McpAtomicWrite._resolve_symlink_target(path).get_base_dir()
	var home := _home()
	var inside_home := (
		not home.is_empty() and McpTransportCapability.path_is_within(home, directory)
	)
	var grant := McpTransportCapability.flatpak_grant_over(
		info, directory, home, expand("$XDG_CONFIG_HOME")
	)
	if not grant.get("writable", false):
		if not grant.is_empty():
			return {"needs": str(grant["location"])}
		## Nothing under ~/.var/app comes with the home, so there the app's
		## directory has to be granted by name.
		var apps := home.path_join(".var/app") + "/"
		if inside_home and directory.begins_with(apps):
			return {"needs": apps + directory.trim_prefix(apps).get_slice("/", 0)}
		return {"needs": "home" if inside_home else directory}
	var root := str(grant["root"])
	var real_root := McpTransportCapability.real_path(root)
	var mount := McpTransportCapability.flatpak_blocking_mount(
		_flatpak_mount_list(),
		McpTransportCapability.real_path(directory),
		McpTransportCapability.real_path(home) if inside_home else real_root,
	)
	if mount.is_empty():
		return {}
	var mount_point := str(mount["mount_point"])
	if mount["read_only"]:
		return {"read_only": mount_point}
	## A tmpfs above the granted directory is not there because of the grant:
	## the grant's own mount is what is missing.
	if not McpTransportCapability.path_is_within(real_root, mount_point):
		return {"unmounted": root}
	return {"hidden": mount_point}


## Home-derived default for a var the environment does not define. Returns ""
## when home itself is unresolvable so `expand` leaves the token alone: rooting
## these at an empty home yields a RELATIVE path, not an absent one —
## `"".path_join(".config")` is `.config`, which reads against the editor's
## working directory rather than the user's config dir. `USERPROFILE` has no
## fallback (it is the thing `_home()` itself falls back to).
static func _home_fallback(var_name: String) -> String:
	var home := _home()
	if home.is_empty():
		return ""
	match var_name:
		"XDG_CONFIG_HOME":
			return home.path_join(".config")
		"APPDATA":
			return home.path_join("AppData/Roaming")
		"LOCALAPPDATA":
			return home.path_join("AppData/Local")
		"HOME":
			return home
	return ""


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
