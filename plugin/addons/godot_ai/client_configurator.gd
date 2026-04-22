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
const MIN_PORT := 1024
const MAX_PORT := 65535


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


## Walk `start`..`start+span-1` and return the first port that is NOT
## currently excluded by Windows' winnat reservation table. Falls back to
## `start` if nothing clears (caller can apply anyway — user may just
## retry). On non-Windows this is a no-op: all ports pass, returns `start`.
static func suggest_free_port(start: int, span: int = 100) -> int:
	var candidate := clampi(start, MIN_PORT, MAX_PORT - span + 1)
	for i in span:
		var p := candidate + i
		if p > MAX_PORT:
			break
		if not WindowsPortReservation.is_port_excluded(p):
			return p
	return candidate


# --- Client operations (string id) ---------------------------------------

static func client_ids() -> PackedStringArray:
	return McpClientRegistry.ids()


static func has_client(id: String) -> bool:
	return McpClientRegistry.has_id(id)


static func client_display_name(id: String) -> String:
	var c := McpClientRegistry.get_by_id(id)
	return c.display_name if c != null else id


static func configure(id: String) -> Dictionary:
	var client := McpClientRegistry.get_by_id(id)
	if client == null:
		return {"status": "error", "message": "Unknown client: %s" % id}
	var url := http_url()
	match client.config_type:
		"json":
			return McpJsonStrategy.configure(client, SERVER_NAME, url)
		"toml":
			return McpTomlStrategy.configure(client, SERVER_NAME, url)
		"cli":
			return McpCliStrategy.configure(client, SERVER_NAME, url)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [id, client.config_type]}


static func check_status(id: String) -> McpClient.Status:
	var client := McpClientRegistry.get_by_id(id)
	if client == null:
		return McpClient.Status.NOT_CONFIGURED
	var url := http_url()
	match client.config_type:
		"json":
			return McpJsonStrategy.check_status(client, SERVER_NAME, url)
		"toml":
			return McpTomlStrategy.check_status(client, SERVER_NAME, url)
		"cli":
			return McpCliStrategy.check_status(client, SERVER_NAME, url)
	return McpClient.Status.NOT_CONFIGURED


static func remove(id: String) -> Dictionary:
	var client := McpClientRegistry.get_by_id(id)
	if client == null:
		return {"status": "error", "message": "Unknown client: %s" % id}
	match client.config_type:
		"json":
			return McpJsonStrategy.remove(client, SERVER_NAME)
		"toml":
			return McpTomlStrategy.remove(client, SERVER_NAME)
		"cli":
			return McpCliStrategy.remove(client, SERVER_NAME)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [id, client.config_type]}


static func manual_command(id: String) -> String:
	var client := McpClientRegistry.get_by_id(id)
	if client == null or not client.manual_command_builder.is_valid():
		return ""
	return client.manual_command_builder.call(SERVER_NAME, http_url(), client.resolved_config_path())


static func is_installed(id: String) -> bool:
	var client := McpClientRegistry.get_by_id(id)
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
	var names: Array[String] = []
	names.append("uvx.exe" if OS.get_name() == "Windows" else "uvx")
	return McpCliFinder.find(names)


static func check_uv_version() -> String:
	var uvx := find_uvx()
	if uvx.is_empty():
		return ""
	var output: Array = []
	if OS.execute(uvx, ["--version"], output, true) == 0 and output.size() > 0:
		return output[0].strip_edges()
	return ""


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
