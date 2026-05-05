@tool
class_name McpClientConfigurator
extends RefCounted

## Public facade for the MCP client configuration system.
##
## Per-client logic lives in clients/*.gd (one descriptor per client) and is
## dispatched through clients/_registry.gd. This file:
##   - owns server-side identifiers (SERVER_NAME, HTTP/WS port helpers)
##   - registers the EditorSettings port overrides and resolves the live
##     port/URL via `http_port()` / `ws_port()` / `http_url()`
##   - keeps server-launch discovery (.venv → uvx → system godot-ai)
##   - exposes string-id wrappers around configure / check_status / remove /
##     manual_command so callers don't need to touch the registry directly
##
## To add a new client: drop a file in clients/, then preload it in
## clients/_registry.gd. No edits required here.

const Client := preload("res://addons/godot_ai/clients/_base.gd")
const ClientRegistry := preload("res://addons/godot_ai/clients/_registry.gd")
const JsonStrategy := preload("res://addons/godot_ai/clients/_json_strategy.gd")
const TomlStrategy := preload("res://addons/godot_ai/clients/_toml_strategy.gd")
const CliStrategy := preload("res://addons/godot_ai/clients/_cli_strategy.gd")
const ManualCommand := preload("res://addons/godot_ai/clients/_manual_command.gd")
const CliFinder := preload("res://addons/godot_ai/clients/_cli_finder.gd")
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")

const SERVER_NAME := "godot-ai"

## Fallback ports. Live port selection goes through `http_port()` / `ws_port()`,
## which read overrides from EditorSettings first. Users on Windows whose 8000
## is grabbed by Hyper-V / WSL2 / Docker can pick a different port in
## Editor Settings > Plugins > godot_ai without touching code. See #146 for
## the Windows-reservation diagnostics this is the escape hatch for.
const DEFAULT_HTTP_PORT := 8000
const DEFAULT_WS_PORT := 9500
const SETTING_HTTP_PORT := "godot_ai/http_port"
const SETTING_WS_PORT := "godot_ai/ws_port"
const SETTING_STARTUP_TRACE := "godot_ai/log_startup_timing"
const STARTUP_TRACE_ENV := "GODOT_AI_STARTUP_TRACE"
const MIN_PORT := 1024
const MAX_PORT := 65535

## Comma-separated list of tool domains to drop from the server at spawn
## time. Maps 1:1 onto the `--exclude-domains` CLI flag. Set via the dock's
## "Tools" tab; a change requires a server restart (the dock handles this
## by triggering a plugin reload). Unknown names are warned about on the
## Python side and skipped, so an EditorSetting left over from a previous
## plugin version can't wedge the spawn.
const SETTING_EXCLUDED_DOMAINS := "godot_ai/excluded_domains"


## Active HTTP port: user override (if in range) or `DEFAULT_HTTP_PORT`.
static func http_port() -> int:
	return _read_port_setting(SETTING_HTTP_PORT, DEFAULT_HTTP_PORT)


## Active WebSocket port: user override (if in range) or `DEFAULT_WS_PORT`.
static func ws_port() -> int:
	return _read_port_setting(SETTING_WS_PORT, DEFAULT_WS_PORT)


static func http_url() -> String:
	return "http://127.0.0.1:%d/mcp" % http_port()


static func _read_port_setting(key: String, default_port: int) -> int:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(key):
		return default_port
	var value: int = int(es.get_setting(key))
	if value < MIN_PORT or value > MAX_PORT:
		return default_port
	return value


## Register the port overrides in EditorSettings so they show up in the
## editor's Settings > Plugins section with a range hint. Called once from
## `plugin.gd._enter_tree` before `_start_server` so spawn args see the
## configured values. Safe to call repeatedly — `add_property_info` is
## idempotent and `set_initial_value` only seeds the default.
static func ensure_settings_registered() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	_register_port_setting(es, SETTING_HTTP_PORT, DEFAULT_HTTP_PORT)
	_register_port_setting(es, SETTING_WS_PORT, DEFAULT_WS_PORT)
	_register_bool_setting(es, SETTING_STARTUP_TRACE, false)


static func _register_port_setting(es: EditorSettings, key: String, default_port: int) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default_port)
	es.set_initial_value(key, default_port, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "%d,%d,1" % [MIN_PORT, MAX_PORT],
	})


static func _register_bool_setting(es: EditorSettings, key: String, default_value: bool) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default_value)
	es.set_initial_value(key, default_value, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_BOOL,
	})


static func startup_trace_enabled() -> bool:
	var raw := OS.get_environment(STARTUP_TRACE_ENV).strip_edges().to_lower()
	if raw == "1" or raw == "true" or raw == "yes" or raw == "on":
		return true
	if Engine.is_editor_hint():
		var es := EditorInterface.get_editor_settings()
		if es != null and es.has_setting(SETTING_STARTUP_TRACE):
			return bool(es.get_setting(SETTING_STARTUP_TRACE))
	return false


## Read the `godot_ai/excluded_domains` EditorSetting as a canonicalized
## comma-separated list (sorted, deduplicated, whitespace-stripped). Returns
## "" when the setting is missing or resolves to an empty set — callers can
## skip appending the flag in that case so older servers that don't know
## `--exclude-domains` don't see an empty argument.
static func excluded_domains() -> String:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(SETTING_EXCLUDED_DOMAINS):
		return ""
	var raw := str(es.get_setting(SETTING_EXCLUDED_DOMAINS))
	var parts := PackedStringArray()
	for p in raw.split(","):
		var t := p.strip_edges()
		if not t.is_empty() and parts.find(t) == -1:
			parts.append(t)
	parts.sort()
	return ",".join(parts)


## Clamp `start` into the legal port range, then walk
## `candidate`..`candidate+span-1` and return the first port that is NOT
## currently excluded by Windows' winnat reservation table. Falls back to the
## clamped candidate if nothing clears (caller can apply anyway — user may
## just retry). On non-Windows this is a no-op: all ports pass, returns the
## clamped candidate.
static func suggest_free_port(start: int, span: int = 2048) -> int:
	var candidate := clampi(start, MIN_PORT, MAX_PORT - span + 1)
	return WindowsPortReservation.suggest_non_excluded_port(candidate, span, MAX_PORT)


# --- Client operations (string id) ---------------------------------------

static func client_ids() -> PackedStringArray:
	return ClientRegistry.ids()


static func has_client(id: String) -> bool:
	return ClientRegistry.has_id(id)


static func client_display_name(id: String) -> String:
	var c := ClientRegistry.get_by_id(id)
	return c.display_name if c != null else id


## Pass an explicit `url` when calling from a worker thread: `http_url()`
## reads `EditorInterface.get_editor_settings()`, which is main-thread-only.
## Empty defaults to the live server URL — appropriate for MCP-tool callers
## that always run on main.
static func configure(id: String, url: String = "") -> Dictionary:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {"status": "error", "message": "Unknown client: %s" % id}
	## Capture `url` once so a port flip in EditorSettings between write and
	## verify can't trigger a spurious CONFIGURED_MISMATCH against an entry
	## that just landed correctly.
	if url.is_empty():
		url = http_url()
	var result := _dispatch_configure(client, url)
	## Trust-but-verify: a strategy may report ok and have actually written the
	## file, yet the entry is missing/stale on the read-back path — most often
	## because the user's installed client is reading a different file than
	## `path_template` resolves to (issue #201). Re-read the live state and
	## surface a clear error before the dock reports a bogus green dot.
	return _verify_post_state(client, result, Client.Status.CONFIGURED, url, "configure")


static func check_status(id: String) -> Client.Status:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return Client.Status.NOT_CONFIGURED
	return _dispatch_check_status(client, http_url())


static func check_status_for_url(id: String, url: String) -> Client.Status:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return Client.Status.NOT_CONFIGURED
	return _dispatch_check_status(client, url)


static func check_status_for_url_with_cli_path(id: String, url: String, cli_path: String) -> Client.Status:
	return check_status_details_for_url_with_cli_path(id, url, cli_path).get("status", Client.Status.NOT_CONFIGURED)


## Detailed variant used by the dock refresh worker. Returns
## `{"status": Status, "error_msg": String}` so the worker can surface
## "probe timed out" on the row instead of silently flipping it to
## NOT_CONFIGURED. Callers that only need the status can use the simpler
## helper above.
static func check_status_details_for_url_with_cli_path(id: String, url: String, cli_path: String) -> Dictionary:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {"status": Client.Status.NOT_CONFIGURED, "error_msg": ""}
	if client.config_type == "cli" and cli_path.is_empty():
		return {"status": Client.Status.NOT_CONFIGURED, "error_msg": ""}
	return _dispatch_check_status_with_cli_path_details(client, url, cli_path)


static func client_status_probe_snapshot(id: String) -> Dictionary:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {}
	var cli_path := ""
	var installed := false
	if client.config_type == "cli":
		cli_path = CliStrategy.resolve_cli_path(client)
		installed = not cli_path.is_empty()
	else:
		installed = client.is_installed()
	return {"id": id, "cli_path": cli_path, "installed": installed}


## Pass an explicit `url` when calling from a worker thread — see
## `configure()` above for why. The url is only used to format the
## verify-after-write diagnostic message; the remove itself doesn't need it.
static func remove(id: String, url: String = "") -> Dictionary:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {"status": "error", "message": "Unknown client: %s" % id}
	if url.is_empty():
		url = http_url()
	var result := _dispatch_remove(client)
	return _verify_post_state(client, result, Client.Status.NOT_CONFIGURED, url, "remove")


# --- Strategy dispatch + verify (testable seam) --------------------------

static func _dispatch_configure(client: Client, url: String) -> Dictionary:
	match client.config_type:
		"json":
			return JsonStrategy.configure(client, SERVER_NAME, url)
		"toml":
			return TomlStrategy.configure(client, SERVER_NAME, url)
		"cli":
			return CliStrategy.configure(client, SERVER_NAME, url)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [client.id, client.config_type]}


static func _dispatch_remove(client: Client) -> Dictionary:
	match client.config_type:
		"json":
			return JsonStrategy.remove(client, SERVER_NAME)
		"toml":
			return TomlStrategy.remove(client, SERVER_NAME)
		"cli":
			return CliStrategy.remove(client, SERVER_NAME)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [client.id, client.config_type]}


static func _dispatch_check_status(client: Client, url: String) -> Client.Status:
	return _dispatch_check_status_with_cli_path(client, url, "")


static func _dispatch_check_status_with_cli_path(client: Client, url: String, cli_path: String) -> Client.Status:
	return _dispatch_check_status_with_cli_path_details(client, url, cli_path).get("status", Client.Status.NOT_CONFIGURED)


static func _dispatch_check_status_with_cli_path_details(client: Client, url: String, cli_path: String) -> Dictionary:
	match client.config_type:
		"json":
			return {"status": JsonStrategy.check_status(client, SERVER_NAME, url), "error_msg": ""}
		"toml":
			return {"status": TomlStrategy.check_status(client, SERVER_NAME, url), "error_msg": ""}
		"cli":
			if cli_path.is_empty():
				return CliStrategy.check_status_details(client, SERVER_NAME, url, CliStrategy.resolve_cli_path(client))
			return CliStrategy.check_status_details(client, SERVER_NAME, url, cli_path)
	return {"status": Client.Status.NOT_CONFIGURED, "error_msg": ""}


## After a configure/remove returns ok, re-read the live status. If it doesn't
## match `expected`, replace the result with an error that names the actual
## status and the resolved config path so the user can self-diagnose. The
## strategy's own error path is left untouched — already actionable.
static func _verify_post_state(
	client: Client,
	result: Dictionary,
	expected: Client.Status,
	url: String,
	action: String,
) -> Dictionary:
	if result.get("status") != "ok":
		return result
	var actual := _dispatch_check_status(client, url)
	if actual == expected:
		return result
	var path := client.resolved_config_path()
	var path_hint := "" if path.is_empty() else " Inspect %s and remove the godot-ai entry by hand if needed." % path
	return {
		"status": "error",
		"message": "%s reported %s ok but verification still reads %s (expected %s).%s" % [
			client.display_name, action,
			Client.status_label(actual), Client.status_label(expected),
			path_hint,
		],
	}


static func manual_command(id: String) -> String:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return ""
	return ManualCommand.build(client, SERVER_NAME, http_url(), client.resolved_config_path())


static func is_installed(id: String) -> bool:
	var client := ClientRegistry.get_by_id(id)
	return client != null and client.is_installed()


# --- Server command discovery --------------------------------------------
#
# Three-tier resolution:
#   1. .venv python  — dev checkout, source code
#   2. uvx           — user install, published package from PyPI
#   3. godot-ai CLI  — system-wide pip/pipx/uv install

static func get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/godot_ai/plugin.cfg") == OK:
		return cfg.get_value("plugin", "version", "0.0.1")
	return "0.0.1"


## Override for the dev-vs-user heuristic. Accepted values:
##   "dev"   — force dev-checkout mode (skip update check + self-install)
##   "user"  — force user-install mode (run update check, allow self-install)
##            as long as the data-safety guard (addons_dir_is_symlink) passes
##   other / unset — "auto": fall back to the .venv-proximity heuristic
##
## Use `user` to test the AssetLib self-update flow from inside a dev
## checkout (there's a .venv nearby but `addons/godot_ai` is a plain copy —
## e.g. after unpacking a release zip into `test_project/`).
##
## Two ways to set it, resolved in priority order:
##   1. EditorSettings → `godot_ai/mode_override` — UI dropdown in the dock,
##      persists per-editor-install. Wins over the env var so a UI action
##      always takes effect without relaunching the editor.
##   2. Env var `GODOT_AI_MODE` — useful for CLI launches and CI.
const MODE_OVERRIDE_ENV := "GODOT_AI_MODE"
const MODE_OVERRIDE_SETTING := "godot_ai/mode_override"


static func mode_override() -> String:
	# 1. EditorSetting wins — the user explicitly chose via the dock dropdown.
	#    Guarded on `Engine.is_editor_hint()` so this is a no-op when the
	#    plugin code runs inside the game subprocess (where EditorInterface
	#    isn't available). See CLAUDE.md "Game-side code: gate on
	#    Engine.is_editor_hint(), not OS.has_feature("editor")".
	if Engine.is_editor_hint():
		var es := EditorInterface.get_editor_settings()
		if es != null and es.has_setting(MODE_OVERRIDE_SETTING):
			var setting_val := str(es.get_setting(MODE_OVERRIDE_SETTING)).strip_edges().to_lower()
			if setting_val == "dev" or setting_val == "user":
				return setting_val
	# 2. Env var fallback.
	var raw := OS.get_environment(MODE_OVERRIDE_ENV).strip_edges().to_lower()
	if raw == "dev" or raw == "user":
		return raw
	return ""


static func is_dev_checkout() -> bool:
	match mode_override():
		"dev":
			return true
		"user":
			return false
	return not _find_venv_python().is_empty()


## Data-safety check for self-install: is `res://addons/godot_ai` a symbolic
## link? In a dev checkout this points at the canonical `plugin/` source
## tree, and writing files into it would clobber tracked source. This check
## is independent of `is_dev_checkout()` so a forced-user mode override
## still cannot extract a release zip over the symlink.
static func addons_dir_is_symlink() -> bool:
	return _is_symlink(ProjectSettings.globalize_path("res://addons/godot_ai"))


## Mirrors the idiom used in `mcp_dock.gd::_resolve_plugin_symlink_target` —
## open the parent dir and ask Godot via `DirAccess.is_link()`, which
## handles symlinks on POSIX and reparse points on Windows natively.
static func _is_symlink(path: String) -> bool:
	if path.is_empty():
		return false
	var dir := DirAccess.open(path.get_base_dir())
	return dir != null and dir.is_link(path)


## `refresh` forces uvx to re-fetch PyPI index metadata on spawn — used by
## `_start_server`'s one-shot retry when the first attempt exited fast with
## no pid-file on the uvx tier (stale-index-cache failure mode). No-op on
## other tiers: dev_venv and system resolve locally, so the flag has nowhere
## to go. See plugin.gd::_should_retry_with_refresh.
static func get_server_command(refresh: bool = false) -> Array[String]:
	## `mode_override() == "user"` skips the dev_venv tier even when a nearby
	## .venv exists — the UI dropdown then becomes an actual workaround for
	## the "user venv misidentified as dev checkout" bug, not just a
	## cosmetic relabel.
	if mode_override() != "user":
		var venv_python := _cached_venv_python()
		if not venv_python.is_empty():
			print("MCP | using dev venv: %s" % venv_python)
			return [venv_python, "-m", "godot_ai"]

	var uvx := find_uvx()
	if not uvx.is_empty():
		var version := get_plugin_version()
		## Pin to the EXACT plugin version rather than `~=<minor>`. Under the
		## tilde form, uvx was happy to reuse a cached tool env that matched
		## the minor constraint — so an install that first spawned 1.2.0 kept
		## using 1.2.0 even after 1.2.1/1.2.2 landed. Exact pinning makes the
		## cache key version-specific: if the cached env matches, fast hit;
		## otherwise uvx installs the exact version fresh. Keeps plugin and
		## server version in lockstep without needing `--refresh-package` on
		## every spawn. See issue #133.
		print("MCP | using uvx (godot-ai==%s)%s" % [version, " [refresh]" if refresh else ""])
		var cmd: Array[String] = [uvx]
		if refresh:
			cmd.append("--refresh")
		cmd.append_array(["--from", "godot-ai==%s" % version, "godot-ai"])
		return cmd

	var system_cmd := _find_system_install()
	if not system_cmd.is_empty():
		print("MCP | using system install: %s" % system_cmd)
		return [system_cmd]

	push_warning("MCP | no server found — install uv or run: pip install godot-ai")
	return []


## Which tier `get_server_command` would resolve to, without side-effects.
## Returned as a stable string so handshakes and session_list can expose it
## to MCP callers. Values track the `Literal` on the Python side.
static func get_server_launch_mode() -> String:
	if mode_override() != "user" and not _cached_venv_python().is_empty():
		return "dev_venv"
	if not find_uvx().is_empty():
		return "uvx"
	if not _find_system_install().is_empty():
		return "system"
	return "unknown"


static func find_uvx() -> String:
	return CliFinder.find(_uvx_cli_names())


static func _uvx_cli_names() -> Array[String]:
	var names: Array[String] = []
	names.append("uvx.exe" if OS.get_name() == "Windows" else "uvx")
	return names


## Drop the `CliFinder` cache for the platform-specific uvx binary
## name. Pairs with `invalidate_uv_version_cache()` so the dock's
## `_on_install_uv` can refresh both caches with one call each. The
## OS-specific name matters: Windows caches under `uvx.exe`, every
## other platform under `uvx`; hard-coding `"uvx"` here would leave
## the CLI-path cache stale on Windows after a fresh install and the
## dock would keep showing "uv: not found" for the rest of the session.
static func invalidate_uvx_cli_cache() -> void:
	for name in _uvx_cli_names():
		CliFinder.invalidate(name)


## Drop the entire `CliFinder` cache. Called from any explicit-user-action
## refresh path (`force=true` in `_request_client_status_refresh` — manual
## Refresh button, popup-open, compat wrapper, future external API) so a
## freshly-installed CLI (claude, codex, gemini, …) gets detected without
## an editor restart. Per-CLI invalidation (`invalidate_uvx_cli_cache`) is
## preferred when the dock knows which binary changed; this catch-all
## handles the "any CLI may have been installed since the last sweep" case.
##
## Thread safety: `CliFinder.invalidate()` guards `_cache` / `_searched`
## with a mutex so it can race safely against worker threads calling
## `find()` from `_run_client_action_worker`. The mutex is held only
## across the dictionary clear, never across `OS.execute`, so this call
## can never block the main thread on a subprocess.
static func invalidate_cli_cache() -> void:
	CliFinder.invalidate()


static var _uv_version_cache: String = ""
static var _uv_version_searched: bool = false


## Cached for the editor session. The dock's `_refresh_setup_status`
## (called via `call_deferred` from `_build_ui`) calls this on the
## main thread in user mode, so a single cold `OS.execute(uvx,
## ["--version"])` adds ~80 ms to the dock's first paint on Linux and
## more on Windows. Subsequent calls (focus-in refresh, manual Refresh
## clicks) reuse the cached string.
##
## Invalidate via `invalidate_uv_version_cache()` when the user
## installs / reinstalls uv via the dock so the next refresh reflects
## the new install. The dock's `_on_install_uv` calls this alongside
## `CliFinder.invalidate("uvx")` to clear both the path cache and
## the version cache in one place.
static func check_uv_version() -> String:
	if _uv_version_searched:
		return _uv_version_cache
	var uvx := find_uvx()
	if uvx.is_empty():
		_uv_version_searched = true
		_uv_version_cache = ""
		return ""
	var output: Array = []
	if OS.execute(uvx, ["--version"], output, true) == 0 and output.size() > 0:
		_uv_version_cache = output[0].strip_edges()
	else:
		_uv_version_cache = ""
	_uv_version_searched = true
	return _uv_version_cache


static func invalidate_uv_version_cache() -> void:
	_uv_version_searched = false
	_uv_version_cache = ""


static var _venv_python_cache: String = ""
static var _venv_python_searched: bool = false


static func _cached_venv_python() -> String:
	if not _venv_python_searched:
		_venv_python_cache = _find_venv_python()
		_venv_python_searched = true
	return _venv_python_cache


static func _find_venv_python() -> String:
	return _find_venv_python_in(ProjectSettings.globalize_path("res://").rstrip("/"))


## Pure path-based lookup so tests can drive it with a scratch dir instead of
## monkey-patching `res://`. Only treats a `.venv/bin/python` as a godot-ai dev
## venv if a sibling `src/godot_ai/` exists in the same parent dir — otherwise
## an unrelated user venv (e.g. `~/.venv` from a data-science side project)
## gets picked up and `python -m godot_ai` fails with ModuleNotFoundError about
## 5s into startup, cascading into an infinite reconnect loop. The retry-with-
## refresh recovery in `plugin.gd::_should_retry_with_refresh` only fires on
## the uvx tier, so the dev_venv misidentification has no escape hatch — the
## detection has to be right the first time.
static func _find_venv_python_in(start_dir: String) -> String:
	var dir := start_dir.rstrip("/")
	var python_name := "python" if OS.get_name() != "Windows" else "python.exe"
	var venv_dir := ".venv/bin/" if OS.get_name() != "Windows" else ".venv/Scripts/"
	for i in 5:
		var venv_path := dir.path_join(venv_dir + python_name)
		if FileAccess.file_exists(venv_path) and DirAccess.dir_exists_absolute(dir.path_join("src/godot_ai")):
			return venv_path
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


## Walk up from `start_dir` looking for a sibling `src/godot_ai/` — returns
## the absolute path of the enclosing `src/` dir, or "". Used by the dev
## server launcher to prepend the caller's own source to PYTHONPATH so a
## worktree-launched editor serves the worktree's Python, not the root
## repo's editable install. See #84.
static func find_worktree_src_dir(start_dir: String) -> String:
	var dir := start_dir.rstrip("/")
	for i in 5:
		var candidate := dir.path_join("src/godot_ai")
		if DirAccess.dir_exists_absolute(candidate):
			return dir.path_join("src")
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


static func _find_system_install() -> String:
	var cmd := "which" if OS.get_name() != "Windows" else "where"
	var output: Array = []
	if OS.execute(cmd, ["godot-ai"], output, true) == 0 and output.size() > 0:
		var found: String = output[0].strip_edges()
		if not found.is_empty():
			return found
	return ""
