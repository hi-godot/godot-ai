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
const YamlStrategy := preload("res://addons/godot_ai/clients/_yaml_strategy.gd")
const DshStrategy := preload("res://addons/godot_ai/clients/_dsh_strategy.gd")
const CliStrategy := preload("res://addons/godot_ai/clients/_cli_strategy.gd")
const ManualCommand := preload("res://addons/godot_ai/clients/_manual_command.gd")
const CliFinder := preload("res://addons/godot_ai/clients/_cli_finder.gd")
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")

const SERVER_NAME := "godot-ai"

## Fallback ports. Live port selection goes through `http_port()` / `ws_port()`,
## which read overrides from EditorSettings first. Users on Windows whose 8000
## is grabbed by Hyper-V / WSL2 / Docker can pick a different port in
## Editor Settings > Plugins > godot_ai without touching code. See #146 for
## the Windows-reservation diagnostics this is the escape hatch for.
const DEFAULT_HTTP_PORT := 8000
const DEFAULT_WS_PORT := 9500
const STARTUP_TRACE_ENV := "GODOT_AI_STARTUP_TRACE"
const MIN_PORT := 1024
const MAX_PORT := 65535
## Cap on `can_bind_local_port` probes per `suggest_free_port` call so a
## pathological run of occupied ports can't stall the (cold-path) caller.
## 64 localhost binds are sub-millisecond; finding a free port realistically
## takes one or two probes, so this only bounds the worst case.
const SUGGEST_PORT_MAX_PROBES := 64
const SETTING_WS_PORT := "godot_ai/ws_port"
const SETTING_STARTUP_TRACE := "godot_ai/log_startup_timing"
const SETTING_KEEP_SERVER_ON_EXIT := "godot_ai/keep_server_on_exit"
## External cwd the user can set when an MCP client (Pi, code-server, …) reads
## project-tier config files from a directory this editor can't see. The
## merge-tier strategies include it as an extra `_project_candidate_paths` root
## so project overrides there are detected instead of silently shadowed by a
## global-tier write. Codex-review finding F1.
const SETTING_EXTERNAL_CLIENT_CWD := "godot_ai/external_client_cwd"
const _DISCOVERY_TIMEOUT_MS := 3000
## Codex launches Windows console-subsystem MCP commands in a visible terminal.
## A GUI-subsystem Python keeps the bridge attached to Codex's redirected MCP
## pipes without allocating a console, then starts console launchers such as
## uvx with CREATE_NO_WINDOW. Keep stdin/stdout/stderr explicit: pythonw can use
## its own inherited pipes, but subprocess defaults do not reliably forward
## them to a child when no console exists.
## This string is a wire format written verbatim into user config `args`.
## Whitespace or formatting changes make every existing Windows entry report
## CONFIGURED_MISMATCH, so changing it is a deliberate migration decision, not
## a refactor. The inline `-c` script is required because the uvx and system
## tiers resolve a system interpreter where `godot_ai` is not importable.
const _WINDOWS_STDIO_BOOTSTRAP := (
	"import subprocess,sys; "
	+ "raise SystemExit(subprocess.call(sys.argv[1:], stdin=sys.stdin, stdout=sys.stdout, "
	+ "stderr=sys.stderr, creationflags=0x08000000))"
)


## Active HTTP port: user override (if in range) or `DEFAULT_HTTP_PORT`.
static func http_port() -> int:
	return _read_port_setting(McpSettings.SETTING_HTTP_PORT, DEFAULT_HTTP_PORT)


## Active WebSocket port: user override (if in range) or `DEFAULT_WS_PORT`.
static func ws_port() -> int:
	return _read_port_setting(SETTING_WS_PORT, DEFAULT_WS_PORT)


static func http_url() -> String:
	return "http://127.0.0.1:%d/mcp" % http_port()


## Read a URL already captured on the main thread without evaluating the
## EditorSettings-backed fallback unless the snapshot is genuinely incomplete.
static func server_url_from(launch_context: Dictionary) -> String:
	if launch_context.has("server_url"):
		return str(launch_context["server_url"])
	return http_url()


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
	_register_port_setting(es, McpSettings.SETTING_HTTP_PORT, DEFAULT_HTTP_PORT)
	_register_port_setting(es, SETTING_WS_PORT, DEFAULT_WS_PORT)
	_register_bool_setting(es, SETTING_STARTUP_TRACE, false)
	_register_bool_setting(es, SETTING_KEEP_SERVER_ON_EXIT, false)
	_register_client_scope_setting(es)
	_register_string_setting(es, SETTING_EXTERNAL_CLIENT_CWD, "")


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


## Surface the CLI registration scope as an enum in Settings > Plugins so it is
## discoverable without hand-editing editor_settings-4.tres. Kept at `user` by
## default; `project` writes the entry into <project>/.mcp.json instead.
static func _register_client_scope_setting(es: EditorSettings) -> void:
	var key := McpSettings.SETTING_CLIENT_SCOPE
	if not es.has_setting(key):
		es.set_setting(key, McpSettings.DEFAULT_CLIENT_SCOPE)
	es.set_initial_value(key, McpSettings.DEFAULT_CLIENT_SCOPE, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(PackedStringArray(McpSettings.CLIENT_SCOPES)),
	})


static func _register_bool_setting(es: EditorSettings, key: String, default_value: bool) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default_value)
	es.set_initial_value(key, default_value, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_BOOL,
	})


static func _register_string_setting(es: EditorSettings, key: String, default_value: String) -> void:
	## Same idempotent set-then-hint dance as the bool helper; `PROPERTY_HINT_NONE`
	## leaves the editor's plain text-input widget in place (the cwd string is
	## freeform). The hint-string slot is required by the API even when empty.
	if not es.has_setting(key):
		es.set_setting(key, default_value)
	es.set_initial_value(key, default_value, false)
	es.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	})


static func startup_trace_enabled() -> bool:
	## env_lookup + _editor_setting_lookup for the same worker-thread
	## reason as mode_override (#691).
	var raw := McpPathTemplate.env_lookup(STARTUP_TRACE_ENV).strip_edges().to_lower()
	if raw == "1" or raw == "true" or raw == "yes" or raw == "on":
		return true
	var setting: Variant = _editor_setting_lookup(SETTING_STARTUP_TRACE)
	if setting != null:
		return bool(setting)
	return false


## keep_server_on_exit (#800): when enabled, editor teardown detaches from
## the managed server instead of killing it, and the spawn env opts the
## server out of both self-reap paths (owner-PID watchdog, session-idle
## backstop) — so MCP clients connected over HTTP stay served across editor
## sessions, and the next editor start adopts the survivor. Off by default:
## "server dies with the editor" stays the shipped behavior. Read via
## _editor_setting_lookup for the same worker-thread reason as
## startup_trace_enabled (#691).
static func keep_server_on_exit() -> bool:
	var setting: Variant = _editor_setting_lookup(SETTING_KEEP_SERVER_ON_EXIT)
	if setting != null:
		return bool(setting)
	return false


## #691: EditorSettings counterpart of McpPathTemplate.env_lookup. The #678
## startup walk's discovery worker reaches mode_override() (via
## get_server_command) and EditorInterface / EditorSettings are not
## thread-safe objects. Main thread: live read + mutex-guarded snapshot
## refresh. Worker thread: snapshot only — a never-warmed key reads as
## null (unset), never a live EditorInterface call. Warmed alongside the
## env snapshot in warm_env_snapshot(), which runs on the main thread
## before any worker dispatch.
static var _setting_snapshot := {}
static var _setting_snapshot_mutex := Mutex.new()
## The aggregate MCP status command runs on a worker thread. Keep the same
## main-thread-only LaunchContext contract used by dock workers by publishing a
## deep snapshot whenever capture_launch_context() runs on the main thread.
static var _launch_context_snapshot := {}
static var _launch_context_snapshot_mutex := Mutex.new()


static func _editor_setting_lookup(key: String) -> Variant:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		var live: Variant = null
		if Engine.is_editor_hint():
			var es := EditorInterface.get_editor_settings()
			if es != null and es.has_setting(key):
				live = es.get_setting(key)
		_setting_snapshot_mutex.lock()
		_setting_snapshot[key] = live
		_setting_snapshot_mutex.unlock()
		return live
	_setting_snapshot_mutex.lock()
	var cached: Variant = _setting_snapshot.get(key, null)
	_setting_snapshot_mutex.unlock()
	return cached


## Read the `godot_ai/excluded_domains` EditorSetting as a canonicalized
## comma-separated list (sorted, deduplicated, whitespace-stripped). Returns
## "" when the setting is missing or resolves to an empty set — callers can
## skip appending the flag in that case so older servers that don't know
## `--exclude-domains` don't see an empty argument.
##
## Unknown domain names (e.g. a domain removed since the setting was last
## written) are dropped here, at the single chokepoint both the startup
## flag builder (plugin.gd) and the dock display read — the server's
## `parse_exclude_list` hard-fails on unknown names, so a stale setting
## would otherwise block server startup.
static func excluded_domains() -> String:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(McpSettings.SETTING_EXCLUDED_DOMAINS):
		return ""
	return _canonicalize_excluded_domains(str(es.get_setting(McpSettings.SETTING_EXCLUDED_DOMAINS)))


## Pure canonicalizer shared by the main-thread LaunchContext capture and
## tests. Unknown domains are dropped for the same startup-safety reason as
## `excluded_domains()` above.
static func _canonicalize_excluded_domains(raw: String) -> String:
	var parts := PackedStringArray()
	for p in raw.split(","):
		var t := p.strip_edges()
		if t.is_empty() or parts.find(t) != -1:
			continue
		if not McpToolCatalog.is_excludable_domain(t):
			continue
		parts.append(t)
	parts.sort()
	return ",".join(parts)


## Snapshot every EditorSettings-backed value needed to render or verify an
## attach launch command. Main-thread calls refresh the snapshot; worker calls
## return that snapshot without touching EditorInterface (#691). Warm it on the
## main thread before dispatching a worker.
static func capture_launch_context() -> Dictionary:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		_launch_context_snapshot_mutex.lock()
		var cached := _launch_context_snapshot.duplicate(true)
		_launch_context_snapshot_mutex.unlock()
		return cached
	var captured_http_port := http_port()
	var context := {
		"http_port": captured_http_port,
		"ws_port": ws_port(),
		"excluded_domains": excluded_domains(),
		"plugin_version": get_plugin_version(),
		"allow_dev_venv": mode_override() != "user",
		"platform": OS.get_name(),
		"server_url": "http://127.0.0.1:%d/mcp" % captured_http_port,
		"project_roots": capture_project_roots(),
		## The opt-out must ride the attach argv: the client spawns the bridge
		## (and the bridge its backend) with no editor in the loop, so the
		## env-injection path in server_lifecycle.gd never runs for them.
		"telemetry_enabled": McpSettings.telemetry_enabled(),
	}
	_launch_context_snapshot_mutex.lock()
	_launch_context_snapshot = context.duplicate(true)
	_launch_context_snapshot_mutex.unlock()
	return context


## Resolve roots used by cwd-relative client project config tiers while the
## engine singletons are safe to access. Workers receive this immutable snapshot.
static func capture_project_roots() -> PackedStringArray:
	var current_access := DirAccess.open(".")
	var current_root := "" if current_access == null else current_access.get_current_dir().simplify_path()
	var project_root := ProjectSettings.globalize_path("res://").simplify_path()
	# Codex F1: when the user sets `godot_ai/external_client_cwd` we probe that
	# directory in addition to the two guessed roots. The setter / setter-snapshot
	# pathway is the same as the existing EditorSettings (warm_env_snapshot
	# pre-warms this key so worker-thread callers see the snapshot, not the live
	# EditorInterface). Empty string is filtered out by `_canonicalize_roots_for_test`.
	var external_cwd := str(_editor_setting_lookup(SETTING_EXTERNAL_CLIENT_CWD))
	return _canonicalize_roots_for_test(PackedStringArray([current_root, project_root, external_cwd]))


## Canonicalize a list of root paths to one filesystem representation per
## directory and deduplicate. `ProjectSettings.globalize_path` maps any
## `res://` / `user://` form to the absolute path and is idempotent on an
## already-absolute path, so a `res://`-form candidate and its absolute twin
## collapse to the same entry. Without this pass, `_project_candidate_paths`
## would probe `<root>/.pi/mcp.json` against both representations of the same
## directory and `manual_target_details` would mis-report a single project
## override as multiple tiers (codex-review finding F4). Public-ish seam
## (named `_..._for_test`) so the clients suite can pin the behaviour without
## having to mock `DirAccess.open(".")`.
static func _canonicalize_roots_for_test(raws: PackedStringArray) -> PackedStringArray:
	var seen := {}
	var roots := PackedStringArray()
	for raw in raws:
		var s := str(raw).strip_edges()
		if s.is_empty():
			continue
		var canon := ProjectSettings.globalize_path(s).simplify_path()
		if canon.is_empty() or seen.has(canon):
			continue
		seen[canon] = true
		roots.append(canon)
	return roots


static func _project_roots_from_context(context: Dictionary) -> PackedStringArray:
	var roots = context.get("project_roots", PackedStringArray())
	return roots if roots is PackedStringArray else PackedStringArray()


## Read the `godot_ai/allow_remote_hosts` EditorSetting as a canonicalized
## comma-separated list of CIDRs / bare IPs (#507). Returns "" when the
## setting is missing or empty — callers skip appending `--allow-host` in
## that case so spawns stay byte-for-byte identical to the loopback-only
## default (and compatible with pre-#421 servers). Mirrors
## `excluded_domains()` above.
static func allow_hosts() -> String:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(McpSettings.SETTING_ALLOW_HOSTS):
		return ""
	return McpAllowHosts.normalize(str(es.get_setting(McpSettings.SETTING_ALLOW_HOSTS)))


## Suggest a port the caller can actually switch to. Walks
## `candidate`..`candidate+span-1` and returns the first port that is both
## (a) NOT inside a Windows winnat reservation range (Hyper-V / WSL2 / Docker
## grab these; bind fails with WinError 10013 and netstat shows nothing) and
## (b) actually bindable right now on 127.0.0.1. The bind probe is what makes
## "free" honest on macOS/Linux, where the reservation table is empty but the
## next port up may still be occupied — the same suggestion feeds the dock
## crash body, the port-picker spinbox, and the non-recoverable INCOMPATIBLE
## log line. Falls back to the clamped candidate if nothing in the window
## clears both checks (caller surfaces it as a best-effort hint; the user can
## retry or pick another). Best-effort by nature: a TOCTOU window remains
## between the probe and the caller actually binding the port. The bind probe
## is bounded to `SUGGEST_PORT_MAX_PROBES` attempts so this cold path can't
## stall on a pathological run of occupied ports.
static func suggest_free_port(start: int, span: int = 2048) -> int:
	var candidate := clampi(start, MIN_PORT, MAX_PORT - span + 1)
	var limit := mini(candidate + span - 1, MAX_PORT)
	var p := candidate
	var probes := 0
	while p <= limit and probes < SUGGEST_PORT_MAX_PROBES:
		## Jump past a whole Windows-reserved range in one step (no-op on
		## POSIX: returns `p` unchanged), so we don't probe port-by-port
		## through the large adjacent ranges those services reserve. The
		## jump itself runs no bind probes, so it doesn't count against the cap.
		var not_reserved := WindowsPortReservation.suggest_non_excluded_port(p, limit - p + 1, MAX_PORT)
		if not_reserved < p or not_reserved > limit:
			break
		p = not_reserved
		probes += 1
		if PortResolver.can_bind_local_port(p):
			return p
		p += 1
	return candidate


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
static func configure(id: String, url: String = "", launch_context: Dictionary = {}) -> Dictionary:
	if ClientRegistry.stale_session_detected():
		return {"status": "error", "message": ClientRegistry.RESTART_TO_FINISH_UPDATE}
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {"status": "error", "message": "Unknown client: %s" % id}
	var path_error := _config_path_resolution_error(client)
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	## Capture `url` once so a port flip in EditorSettings between write and
	## verify can't trigger a spurious CONFIGURED_MISMATCH against an entry
	## that just landed correctly.
	if url.is_empty():
		url = http_url()
	var context := launch_context
	if client.command_shape != Client.CommandShape.NONE and context.is_empty():
		if OS.get_thread_caller_id() != OS.get_main_thread_id():
			return {
				"status": "error",
				"message": "Cannot configure %s without a main-thread launch snapshot; retry from the dock." % client.display_name,
			}
		context = capture_launch_context()
	var launch := (
		resolve_attach_launch(context)
		if client.command_shape != Client.CommandShape.NONE
		else {}
	)
	var result := _dispatch_configure(client, url, launch, context)
	## Trust-but-verify: a strategy may report ok and have actually written the
	## file, yet the entry is missing/stale on the read-back path — most often
	## because the user's installed client is reading a different file than
	## `path_template` resolves to (issue #201). Re-read the live state and
	## surface a clear error before the dock reports a bogus green dot.
	return _verify_post_state(client, result, Client.Status.CONFIGURED, url, "configure", launch, context)


static func check_status(id: String) -> Client.Status:
	if ClientRegistry.stale_session_detected():
		return Client.Status.ERROR
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return Client.Status.NOT_CONFIGURED
	var context := capture_launch_context() if client.command_shape != Client.CommandShape.NONE else {}
	return _dispatch_check_status(client, http_url(), context)


static func check_status_for_url_with_cli_path(
	id: String, url: String, cli_path: String, launch_context: Dictionary = {}
) -> Client.Status:
	return check_status_details_for_url_with_cli_path(id, url, cli_path, launch_context).get("status", Client.Status.NOT_CONFIGURED)


## True when <id>'s stored entry verifies EXACTLY against the launch this
## editor would have rendered at `from_version` — same ports, exclusions,
## telemetry flag, command shape; nothing differs but the version pin. This
## is the post-update auto-repin gate: only such entries are provably "what
## Configure wrote before the update", so rewriting them to the current
## version restores the user's own prior intent. Anything else — entries
## pointing at another editor's ports (the smoke-fixture blast radius that
## motivated this gate), hand-edits, changed settings — stays untouched for
## the drift banner's human click. An empty `from_version` (marker written
## by a pre-gate runner) fails closed.
##
## The version-substituted context is safe to resolve and cache:
## `plugin_version` is part of both the attach-launch resolution
## (`_resolve_attach_launch_uncached`) and its cache key.
static func entry_drift_is_version_pin_only(
	id: String, from_version: String, launch_context: Dictionary = {}
) -> bool:
	var pinned_from := from_version.strip_edges()
	if pinned_from.is_empty():
		return false
	## Never shell out from this gate — it runs on the MAIN thread from the
	## dock's sweep-completion callback (#890 review P2). The cli-descriptor
	## probe paths run a subprocess with a multi-second timeout (`claude mcp
	## get` is 6s), which would freeze the editor; those clients fail closed
	## to the drift banner's click flow, whose fan-out already runs on
	## worker threads. Every path left after these guards is a bounded
	## config-file read plus cached launch discovery (worst case one CLI
	## lookup on a cold CliFinder cache — the same bounded one-shot the
	## dock's `_reprobe_uv_if_negative` accepts on this thread).
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return false
	if client.config_type == "cli":
		if client.command_shape == Client.CommandShape.NONE:
			return false
		if not client.has_json_fallback():
			return false
		if _scope_diverges_from_json_fallback(client):
			return false
	var context := launch_context if not launch_context.is_empty() else capture_launch_context()
	var old_context := context.duplicate(true)
	old_context["plugin_version"] = pinned_from
	## Same URL under both versions: the URL carries the port, not the
	## version, so URL-mode entries can never be version-pin-only drift and
	## correctly fail this check.
	var url := str(context.get("server_url", http_url()))
	var status := check_status_for_url_with_cli_path(id, url, "", old_context)
	return status == Client.Status.CONFIGURED


## Detailed variant used by the dock refresh worker. Returns
## `{"status": Status, "error_msg": String}` so the worker can surface
## "probe timed out" on the row instead of silently flipping it to
## NOT_CONFIGURED. Callers that only need the status can use the simpler
## helper above.
static func check_status_details_for_url_with_cli_path(
	id: String,
	url: String,
	cli_path: String,
	launch_context: Dictionary = {},
	resolved_launch: Dictionary = {},
) -> Dictionary:
	## One comprehensible line per row beats a wall of per-field type errors —
	## the dock keeps painting, every row names the same repair (restart).
	if ClientRegistry.stale_session_detected():
		return {"status": Client.Status.ERROR, "error_msg": ClientRegistry.RESTART_TO_FINISH_UPDATE}
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {"status": Client.Status.NOT_CONFIGURED, "error_msg": ""}
	# A cli client with no resolved binary normally reads as NOT_CONFIGURED.
	# Skip that shortcut when the client has a JSON fallback (#463): the
	# dispatch below reads its config file directly so the status dot reflects
	# a fallback-configured entry instead of always showing red.
	if client.config_type == "cli" and cli_path.is_empty() and not client.has_json_fallback():
		return {"status": Client.Status.NOT_CONFIGURED, "error_msg": ""}
	var path_error := _config_path_resolution_error(client)
	if not path_error.is_empty():
		return {"status": Client.Status.ERROR, "error_msg": path_error}
	if client.command_shape != Client.CommandShape.NONE and launch_context.is_empty():
		return {
			"status": Client.Status.ERROR,
			"error_msg": "Missing launch-context snapshot; retry the status refresh.",
		}
	return _dispatch_check_status_with_cli_path_details(
		client, url, cli_path, launch_context, resolved_launch
	)


## #691: main-thread pre-warm of McpPathTemplate's env snapshot, covering
## the base vars plus every descriptor-declared config-file/config-home env
## (OPENCODE_CONFIG, CLAUDE_CONFIG_DIR, CODEX_HOME, …), so worker-thread config-path
## resolution never calls OS.get_environment concurrently with the spawn
## window's setenv/unsetenv. Also warms the EditorSettings snapshot for
## the mode/trace overrides so worker-thread mode_override() /
## startup_trace_enabled() never touch EditorInterface. Idempotent;
## called from plugin _enter_tree and before each dock worker dispatch.
static func warm_env_snapshot() -> void:
	var extras := PackedStringArray()
	for id in client_ids():
		var client := ClientRegistry.get_by_id(String(id))
		if client == null:
			continue
		## Reflected get(): after an in-session self-update these fields can
		## read as Nil on stale instances, and String(Nil) is a hard error (#850). Skipping just degrades env-override
		## resolution until the restart the registry is already asking for.
		for env_name in [client.get("config_file_env"), client.get("config_home_env")]:
			if env_name is String and not env_name.is_empty() and not extras.has(env_name):
				extras.append(env_name)
	McpPathTemplate.warm_env_snapshot(extras)
	_editor_setting_lookup(MODE_OVERRIDE_SETTING)
	_editor_setting_lookup(SETTING_STARTUP_TRACE)
	_editor_setting_lookup(SETTING_KEEP_SERVER_ON_EXIT)
	_editor_setting_lookup(SETTING_EXTERNAL_CLIENT_CWD)
	McpSettings.warm_client_scope()
	# Publish the complete launch context while EditorInterface access is safe;
	# worker callers of capture_launch_context() read this snapshot only.
	capture_launch_context()


static func client_status_probe_snapshot(id: String) -> Dictionary:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {}
	var cli_path := ""
	var installed := false
	if client.config_type == "cli":
		cli_path = CliStrategy.resolve_cli_path(client)
		# #463: a JSON-fallback cli client (Claude Code as a VS Code extension)
		# is "installed" when its fallback config exists, even with no binary.
		installed = not cli_path.is_empty() or client.is_installed()
	else:
		installed = client.is_installed()
	return {"id": id, "cli_path": cli_path, "installed": installed}


## Force lazy GDScript bytecode swaps to complete before a client-status
## worker reaches the registry and strategies. Pure-memory only: callers can
## run this on the handler thread without performing CLI or config probes.
static func warm_status_worker_bytecode() -> void:
	var ids := client_ids()
	if ids.is_empty():
		return
	var any_client := ClientRegistry.get_by_id(String(ids[0]))
	if any_client != null:
		JsonStrategy.verify_entry(any_client, {}, "")
		DshStrategy.command_launch_error(any_client, {})
	TomlStrategy.format_body(PackedStringArray(), "")
	CliStrategy.format_args(PackedStringArray(), "", "")
	# Compile the aggregate worker entry point on main as well. After a plugin
	# reload, first-dereferencing this function from Thread can hang in Godot's
	# lazy bytecode swap even when every strategy it calls was already warmed.
	run_client_status_sweep({}, true)


## Worker entry point for the MCP aggregate status command. Every filesystem,
## CLI, and launch-discovery probe stays inside this function; the WebSocket
## handler only schedules it and returns the deferred sentinel.
static func run_client_status_sweep(
	fallback_launch_context: Dictionary = {}, warm_only: bool = false
) -> Dictionary:
	if warm_only:
		return {}
	var clients := []
	var launch_context := capture_launch_context()
	if launch_context.is_empty():
		launch_context = fallback_launch_context.duplicate(true)
	if launch_context.is_empty():
		return {"worker_error": "Client status launch context was not warmed on the main thread."}
	var server_url := server_url_from(launch_context)
	var resolved_launch := resolve_attach_launch(launch_context)
	for client_id in client_ids():
		var probe := client_status_probe_snapshot(client_id)
		var details := check_status_details_for_url_with_cli_path(
			client_id,
			server_url,
			str(probe.get("cli_path", "")),
			launch_context,
			resolved_launch,
		)
		clients.append(_client_status_sweep_entry(
			client_id, details, bool(probe.get("installed", false))
		))
	return {"data": {"clients": clients}}


static func _client_status_sweep_entry(
	client_id: String, details: Dictionary, installed: bool
) -> Dictionary:
	var status = details.get("status", Client.Status.NOT_CONFIGURED)
	var entry := {
		"id": client_id,
		"display_name": client_display_name(client_id),
		"status": Client.status_label(status),
		"installed": installed,
	}
	var error_msg := str(details.get("error_msg", ""))
	if not error_msg.is_empty():
		entry["error"] = error_msg
	return entry


## Pass an explicit `url` when calling from a worker thread — see
## `configure()` above for why. The url is only used to format the
## verify-after-write diagnostic message; the remove itself doesn't need it.
static func remove(id: String, url: String = "", launch_context: Dictionary = {}) -> Dictionary:
	if ClientRegistry.stale_session_detected():
		return {"status": "error", "message": ClientRegistry.RESTART_TO_FINISH_UPDATE}
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return {"status": "error", "message": "Unknown client: %s" % id}
	var path_error := _config_path_resolution_error(client)
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if url.is_empty():
		url = http_url()
	var context := launch_context
	if client.command_shape != Client.CommandShape.NONE and context.is_empty():
		if OS.get_thread_caller_id() != OS.get_main_thread_id():
			return {
				"status": "error",
				"message": "Cannot remove %s without a main-thread launch snapshot; retry from the dock." % client.display_name,
			}
		context = capture_launch_context()
	var launch := (
		resolve_attach_launch(context)
		if client.command_shape != Client.CommandShape.NONE
		else {}
	)
	var result := _dispatch_remove(client, context)
	return _verify_post_state(client, result, Client.Status.NOT_CONFIGURED, url, "remove", launch, context)


## Resolve config-backed path errors before attach-launch discovery. This both
## gives ambiguity precedence over unrelated launcher failures and avoids
## spending the status worker's command budget on a Configure action that must
## fail closed regardless. CLI clients keep their existing CLI/fallback dispatch.
static func _config_path_resolution_error(client: Client) -> String:
	if client.config_type == "cli":
		return ""
	return str(client.resolved_config_path_details().get("error", ""))


# --- Strategy dispatch + verify (testable seam) --------------------------

static func _dispatch_configure(
	client: Client, url: String, launch: Dictionary = {}, launch_context: Dictionary = {}
) -> Dictionary:
	launch = launch_for_client(client, launch)
	match client.config_type:
		"json":
			return JsonStrategy.configure(client, SERVER_NAME, url, launch, _project_roots_from_context(launch_context))
		"toml":
			return TomlStrategy.configure(client, SERVER_NAME, url, launch)
		"yaml":
			return YamlStrategy.configure(client, SERVER_NAME, url, launch)
		"dsh":
			return DshStrategy.configure(client, SERVER_NAME, url, launch)
		"cli":
			# #463: fall back to writing the config file directly when the CLI
			# binary isn't on PATH (Claude Code as a VS Code/Cursor extension).
			if client.has_json_fallback() and CliStrategy.resolve_cli_path(client).is_empty():
				return _note_unhonoured_scope(
					client, JsonStrategy.configure(client, SERVER_NAME, url, launch, _project_roots_from_context(launch_context))
				)
			return CliStrategy.configure(client, SERVER_NAME, url, launch)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [client.id, client.config_type]}


static func _dispatch_remove(client: Client, launch_context: Dictionary = {}) -> Dictionary:
	match client.config_type:
		"json":
			return JsonStrategy.remove(client, SERVER_NAME, _project_roots_from_context(launch_context))
		"toml":
			return TomlStrategy.remove(client, SERVER_NAME)
		"yaml":
			return YamlStrategy.remove(client, SERVER_NAME)
		"dsh":
			return DshStrategy.remove(client, SERVER_NAME)
		"cli":
			# #463: mirror the configure fallback so Remove also works without
			# the CLI binary — otherwise a fallback-written entry is unremovable.
			if client.has_json_fallback() and CliStrategy.resolve_cli_path(client).is_empty():
				return JsonStrategy.remove(client, SERVER_NAME, _project_roots_from_context(launch_context))
			return CliStrategy.remove(client, SERVER_NAME)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [client.id, client.config_type]}


static func _dispatch_check_status(
	client: Client, url: String, launch_context: Dictionary = {}
) -> Client.Status:
	return _dispatch_check_status_with_cli_path(client, url, "", launch_context)


static func _dispatch_check_status_with_cli_path(
	client: Client, url: String, cli_path: String, launch_context: Dictionary = {}
) -> Client.Status:
	return _dispatch_check_status_with_cli_path_details(client, url, cli_path, launch_context).get("status", Client.Status.NOT_CONFIGURED)


static func _dispatch_check_status_with_cli_path_details(
	client: Client,
	url: String,
	cli_path: String,
	launch_context: Dictionary = {},
	resolved_launch: Dictionary = {},
) -> Dictionary:
	match client.config_type:
		"json":
			var launch := {}
			if client.command_shape != Client.CommandShape.NONE:
				launch = _resolved_or_discovered_launch(client, resolved_launch, launch_context)
			return JsonStrategy.check_status_details(client, SERVER_NAME, url, launch, _project_roots_from_context(launch_context))
		"toml":
			var launch := {}
			if client.command_shape != Client.CommandShape.NONE:
				launch = _resolved_or_discovered_launch(client, resolved_launch, launch_context)
			return TomlStrategy.check_status_details(client, SERVER_NAME, url, launch)
		"yaml":
			var yaml_launch := {}
			if client.command_shape != Client.CommandShape.NONE:
				yaml_launch = _resolved_or_discovered_launch(client, resolved_launch, launch_context)
			return YamlStrategy.check_status_details(client, SERVER_NAME, url, yaml_launch)
		"dsh":
			var dsh_launch := {}
			if client.command_shape != Client.CommandShape.NONE:
				dsh_launch = _resolved_or_discovered_launch(client, resolved_launch, launch_context)
			return DshStrategy.check_status_details(client, SERVER_NAME, url, dsh_launch)
		"cli":
			# Command-shape CLI clients register through their CLI, but the entry
			# lands in the same file the JSON fallback reads (`claude mcp add
			# --scope user` writes mcpServers in ~/.claude.json). Reading that
			# file gives exact launch-drift detection — a changed port, version
			# pin, or exclusion list — which scanning `mcp list` stdout cannot,
			# so it is preferred even when the CLI binary resolves.
			# #872: ...but only while the selected scope is still the one
			# `path_template` points at — see _scope_diverges_from_json_fallback.
			if (
				client.command_shape != Client.CommandShape.NONE
				and client.has_json_fallback()
				and not _scope_diverges_from_json_fallback(client)
			):
				var command_launch := _resolved_or_discovered_launch(client, resolved_launch, launch_context)
				return JsonStrategy.check_status_details(client, SERVER_NAME, url, command_launch, _project_roots_from_context(launch_context))
			var resolved_cli := cli_path if not cli_path.is_empty() else CliStrategy.resolve_cli_path(client)
			# #463: with no CLI binary, read the JSON fallback config so a
			# fallback-configured entry reports CONFIGURED instead of red.
			if resolved_cli.is_empty() and client.has_json_fallback():
				var fallback_launch := {}
				if client.command_shape != Client.CommandShape.NONE:
					fallback_launch = _resolved_or_discovered_launch(client, resolved_launch, launch_context)
				return JsonStrategy.check_status_details(client, SERVER_NAME, url, fallback_launch, _project_roots_from_context(launch_context))
			var cli_launch := {}
			if client.command_shape != Client.CommandShape.NONE:
				cli_launch = _resolved_or_discovered_launch(client, resolved_launch, launch_context)
			# #872: at a scope `path_template` can't see, a plain listing probe
			# cannot tell our entry from a leftover one in another scope. When
			# the descriptor offers a scope-aware probe, use it — same single
			# subprocess, but it reports which scope actually resolved.
			if (
				not client.cli_scope_status_template.is_empty()
				and CliStrategy.uses_scope_token(client)
			):
				return CliStrategy.check_scope_status_details(
					client, SERVER_NAME, url, resolved_cli, cli_launch, McpSettings.client_scope()
				)
			return CliStrategy.check_status_details(client, SERVER_NAME, url, resolved_cli, cli_launch)
	return {"status": Client.Status.NOT_CONFIGURED, "error_msg": ""}


## #872: the #463 JSON fallback writes the user-scope file whatever
## `godot_ai/mcp_client_scope` says — that file IS `path_template`, and
## `clients/_path_template.gd` has no project-relative token to aim it
## elsewhere. Returning a bare "configured" would hide that the requested
## scope was not honoured, so say so in the message.
##
## Deliberately a message and not a status. `_verify_post_state` compares the
## post-write status against CONFIGURED and replaces the ok with an error on
## any mismatch (pinned by test_verify_post_state_treats_drift_as_failure_
## after_configure), so reporting this write as NOT_CONFIGURED or MISMATCH
## would turn a *successful* configure into a user-facing failure — the same
## false-error class #872's blocker was about, just moved onto the fallback
## path. The entry is genuinely written and genuinely works; only its scope
## differs from the request, and that is a caveat, not a failure.
static func _note_unhonoured_scope(client: Client, result: Dictionary) -> Dictionary:
	if result.get("status") != "ok":
		return result
	if not CliStrategy.uses_scope_token(client):
		return result
	var scope := McpSettings.client_scope()
	if scope == McpSettings.DEFAULT_CLIENT_SCOPE:
		return result
	var noted := result.duplicate(true)
	noted["message"] = (
		"%s — wrote %s scope, not %s: the %s CLI wasn't found, and the file fallback can only write %s"
		% [
			str(result.get("message", "")),
			McpSettings.DEFAULT_CLIENT_SCOPE,
			scope,
			client.display_name,
			client.resolved_config_path(),
		]
	)
	return noted


## True when this client's CLI writes its entry somewhere `path_template`
## cannot see, so reading that file would describe the wrong thing (#872).
##
## `claude mcp add --scope project` writes <cwd>/.mcp.json and `--scope local`
## writes a per-project block inside ~/.claude.json — neither is the top-level
## `mcpServers` map `path_template` + `server_key_path` resolve to. Reading it
## anyway makes `_verify_post_state` turn every successful project-scope
## Configure into "configure ok but verification still reads Not configured",
## and pins the dock row red (or green, describing a stale user-scope entry).
##
## Diverging sends status down the CLI probe instead: `mcp list` is
## scope-agnostic and inherits the same cwd the register ran in, so read-back
## and write agree by construction. The cost is losing exact launch-drift
## detection — a stdout scan sees the command, not the full argv — which is the
## documented trade for a status that is merely coarse instead of wrong.
##
## Deliberately says nothing about whether the CLI resolves (#879). An earlier
## version walked PATH here and returned false for an unresolvable binary, on
## the reasoning that configure would then have taken the #463 JSON fallback —
## which writes user scope whatever the setting says — so the file was the
## right thing to read again. That extra clause could not change any outcome:
## this is only consulted from the one call site below, already guarded on
## `has_json_fallback()`, and when the CLI does not resolve the very next
## branch (`resolved_cli.is_empty() and client.has_json_fallback()`) takes the
## fallback read anyway. All it bought was a second full `McpCliFinder.find`
## sweep per status check, on top of the one that immediately follows.
static func _scope_diverges_from_json_fallback(client: Client) -> bool:
	if not CliStrategy.uses_scope_token(client):
		return false
	return McpSettings.client_scope() != McpSettings.DEFAULT_CLIENT_SCOPE


static func _resolved_or_discovered_launch(
	client: Client, resolved_launch: Dictionary, launch_context: Dictionary
) -> Dictionary:
	var launch := (
		resolved_launch
		if not resolved_launch.is_empty()
		else resolve_attach_launch(launch_context)
	)
	return launch_for_client(client, launch)


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
	resolved_launch: Dictionary = {},
	launch_context: Dictionary = {},
) -> Dictionary:
	if result.get("status") != "ok":
		return result
	var details := _dispatch_check_status_with_cli_path_details(
		client, url, "", launch_context, resolved_launch
	)
	var actual := details.get("status", Client.Status.NOT_CONFIGURED)
	if actual == expected:
		return result
	var path_hint := _post_state_path_hint(client, str(details.get("resolved_scope", "")))
	return {
		"status": "error",
		"message": "%s reported %s ok but verification still reads %s (expected %s).%s" % [
			client.display_name, action,
			Client.status_label(actual), Client.status_label(expected),
			path_hint,
		],
	}


## Where to send the user when verification finds an entry that should not be
## there. `resolved_config_path()` is `path_template` — right only for the
## default user scope. Naming ~/.claude.json for a project-scope survivor sends
## them to a file with nothing in it, which is worse than naming no file at all
## (#879). The scope probe supplies `resolved_scope`; `path_template` has no
## project-relative token (see `_note_unhonoured_scope`), so the project case is
## described rather than resolved to a path.
static func _post_state_path_hint(client: Client, resolved_scope: String) -> String:
	match resolved_scope:
		"project":
			return (
				" The surviving entry is project-scoped: inspect the .mcp.json in the"
				+ " directory the editor was launched from and remove the godot-ai entry"
				+ " by hand if needed."
			)
		"local":
			var local_path := client.resolved_config_path()
			if local_path.is_empty():
				return ""
			return (
				" The surviving entry is local-scoped: inspect the block for the"
				+ " directory the editor was launched from in %s and remove the"
				+ " godot-ai entry by hand if needed."
			) % local_path
		_:
			var path := client.resolved_config_path()
			if path.is_empty():
				return ""
			return " Inspect %s and remove the godot-ai entry by hand if needed." % path


## #877: Configure's first act is the all-scope pre-cleanup — it deletes the
## `godot-ai` entry from every scope the descriptor can write to, including a
## `.mcp.json` resolved against the CLI's working directory, which need not be
## this project's folder. The manual-command panel that spells those removes
## out is only shown when Configure FAILS (`mcp_dock.gd`), so on the success
## path — the one where the sweep actually ran — this note is its only
## disclosure. Empty for descriptors without a scope token: their single
## implicit pass removes exactly the entry the register is about to rewrite,
## which needs no warning (the same rule `_sweep_caveat` applies).
##
## "attempted", not "cleared": `CliStrategy.configure` discards every
## pre-cleanup result, and `mcp remove` exits non-zero for an absent entry as
## well as for a real failure, so a timed-out or failed remove leaves the scope
## untouched while the register still returns ok. The note names what ran,
## not what it can prove.
static func configure_sweep_note(id: String) -> String:
	var client := ClientRegistry.get_by_id(id)
	if client == null or client.config_type != "cli":
		return ""
	if client.cli_unregister_template.is_empty() or not CliStrategy.uses_scope_token(client):
		return ""
	return "attempted to clear %s from %s" % [
		SERVER_NAME, ", ".join(CliStrategy.cleanup_scopes(client)),
	]


static func manual_command(id: String) -> String:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return ""
	var path_resolution := client.resolved_config_path_details()
	var path_error := str(path_resolution.get("error", ""))
	if not path_error.is_empty():
		return "Config path unavailable: %s" % path_error
	var context := capture_launch_context() if client.command_shape != Client.CommandShape.NONE else {}
	var launch := (
		launch_for_client(client, resolve_attach_launch(context))
		if client.command_shape != Client.CommandShape.NONE
		else {}
	)
	var cmd := ManualCommand.build(
		client,
		SERVER_NAME,
		server_url_from(context),
		str(path_resolution.get("path", "")),
		launch,
		_project_roots_from_context(context),
	)
	if cmd.is_empty():
		return cmd
	## #507: when the allow-host opt-in names a non-loopback range, also
	## surface the LAN URL so the user can copy-paste the right address into
	## a remote agent. Informational only — configure/remove still WRITE the
	## loopback URL above; nothing about the config-file contract changes.
	var note := McpAllowHosts.lan_url_note(allow_hosts(), IP.get_local_addresses(), http_port())
	if not note.is_empty():
		cmd += "\n\n" + note
	return cmd


static func config_path(id: String) -> String:
	var client := ClientRegistry.get_by_id(id)
	return client.resolved_config_path() if client != null else ""


## Resolve the highest-precedence config tier that actually contains the server
## entry. For Pi-style merge clients, returns the tier path the entry lives in
## (e.g. `~/.pi/agent/.mcp.json`) instead of the lowest-tier `path_template`
## `config_path()` returns. Falls back to `path_template` when no entry is
## found anywhere. Empty `launch_context` is allowed; command-shape clients
## synthesize one via `capture_launch_context()` so dock row construction can
## call this without first capturing launch state.
static func effective_config_path(id: String, launch_context: Dictionary = {}) -> String:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return ""
	var resolution := client.resolved_config_path_details()
	var fallback := str(resolution.get("path", ""))
	var context := launch_context
	if context.is_empty() and client.command_shape != Client.CommandShape.NONE:
		context = capture_launch_context()
	var roots := _project_roots_from_context(context)
	var target := JsonStrategy.manual_target_details(client, SERVER_NAME, fallback, roots)
	if bool(target.get("ok", false)):
		return str(target.get("path", fallback))
	return fallback


## Path that `_check_status_merged` would consider authoritative for the
## server entry, or `path_template` when no entry is found anywhere.
## For Pi-style merge clients this is the latest project tier when one
## exists (matching the F2 last-wins status logic), falling back to the
## latest global tier, then to `path_template`.
##
## The dock uses this for Open/Reveal so the file the user inspects is
## the same file that drives the status check — `effective_config_path`
## fails closed (returns `path_template`) when there are multiple project
## tiers, which historically sent users to the wrong file (codex round 3,
## F-3-4). Splitting this from `effective_config_path` keeps the manual
## instructions fail-closed while letting the dock follow the
## authoritative tier.
static func effective_authoritative_path(id: String, launch_context: Dictionary = {}) -> String:
	var client := ClientRegistry.get_by_id(id)
	if client == null:
		return ""
	var resolution := client.resolved_config_path_details()
	var fallback := str(resolution.get("path", ""))
	var context := launch_context
	if context.is_empty() and client.command_shape != Client.CommandShape.NONE:
		context = capture_launch_context()
	var roots := _project_roots_from_context(context)
	var authoritative: String = JsonStrategy.authoritative_tier_path(client, SERVER_NAME, roots)
	if not authoritative.is_empty():
		return authoritative
	return fallback


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


## Strip PEP 440 local build metadata for PyPI pins: `3.0.2+local.1` → `3.0.2`.
## Pre-release segments (`3.1.0-rc1`) are preserved — only `+…` is removed.
static func _pypi_pin_version(version: String) -> String:
	var v := version.strip_edges()
	var plus := v.find("+")
	if plus >= 0:
		v = v.substr(0, plus)
	return v


## Resolve the client-owned `godot-ai attach` command from a main-thread
## LaunchContext. Discovery itself is worker-safe: path/environment lookup is
## snapshot-backed and subprocess probes are wall-clock bounded.
##
## `discovery_override` is a data-only test seam. Supplying a key (including
## an empty value) bypasses that tier's live lookup; `system_version_result`
## bypasses the real `godot-ai --version` subprocess.
static func resolve_attach_launch(
	launch_context: Dictionary, discovery_override: Dictionary = {}
) -> Dictionary:
	## Test overrides always bypass the session cache so fixture-controlled
	## discovery remains deterministic. Production results are keyed by every
	## setting that affects the rendered command; a port/domain/version change
	## therefore cannot reuse stale arguments.
	if not discovery_override.is_empty():
		return _resolve_attach_launch_uncached(launch_context, discovery_override)
	var cache_key := _attach_launch_cache_key(launch_context)
	_attach_launch_cache_mutex.lock()
	if _attach_launch_cache.has(cache_key):
		var cached: Dictionary = _attach_launch_cache[cache_key].duplicate(true)
		_attach_launch_cache_mutex.unlock()
		return cached
	## Keep the cache lock through the bounded discovery probes. This cold path
	## runs at most once per distinct context and prevents simultaneous status
	## workers from repeating the same subprocess probes. Invalidation waits for
	## the in-flight result, then clears it, so stale work cannot repopulate a
	## freshly invalidated cache.
	var resolved := _resolve_attach_launch_uncached(launch_context)
	_attach_launch_cache[cache_key] = resolved.duplicate(true)
	_attach_launch_cache_mutex.unlock()
	return resolved


static func _resolve_attach_launch_uncached(
	launch_context: Dictionary, discovery_override: Dictionary = {}
) -> Dictionary:
	for key in ["http_port", "ws_port", "excluded_domains", "plugin_version", "allow_dev_venv", "platform"]:
		if not launch_context.has(key):
			return _attach_discovery_error("Launch context is missing `%s`; retry Configure." % key)

	var plugin_version := str(launch_context.get("plugin_version", "")).strip_edges()
	if plugin_version.is_empty():
		return _attach_discovery_error("The bundled godot-ai version is unavailable; reinstall the plugin and retry Configure.")

	var common_args: Array[String] = [
		"attach",
		"--port", str(int(launch_context.get("http_port", DEFAULT_HTTP_PORT))),
		"--ws-port", str(int(launch_context.get("ws_port", DEFAULT_WS_PORT))),
	]
	var exclusions := str(launch_context.get("excluded_domains", "")).strip_edges()
	if not exclusions.is_empty():
		common_args.append_array(["--exclude-domains", exclusions])
	## Default true when the key is absent (hand-built contexts in tests, stale
	## pre-upgrade snapshots) — matching the server's send-by-default posture.
	## Toggling the setting changes the rendered argv, so existing entries read
	## CONFIGURED_MISMATCH and the dock offers Reconfigure, like any other
	## launch-affecting value.
	if not bool(launch_context.get("telemetry_enabled", true)):
		common_args.append("--disable-telemetry")

	var venv_python := ""
	if discovery_override.has("venv_python"):
		venv_python = str(discovery_override["venv_python"])
	elif bool(launch_context.get("allow_dev_venv", true)):
		venv_python = _cached_venv_python()
	if bool(launch_context.get("allow_dev_venv", true)) and not venv_python.is_empty():
		var venv_args: Array[String] = ["-m", "godot_ai"]
		venv_args.append_array(common_args)
		return _finalize_attach_launch(
			"dev_venv", venv_python, venv_args, launch_context, discovery_override
		)

	var uvx := ""
	if discovery_override.has("uvx_path"):
		uvx = str(discovery_override["uvx_path"])
	else:
		## Strict lookup for attach entries: never write a bare `uvx` command
		## that a GUI-launched client may be unable to resolve from its PATH.
		uvx = find_uvx()
	if not uvx.is_empty():
		var uvx_args: Array[String] = [
			"--link-mode", "copy",
			"--from", "godot-ai==%s" % _pypi_pin_version(plugin_version),
			"godot-ai",
		]
		uvx_args.append_array(common_args)
		return _finalize_attach_launch(
			"uvx", uvx, uvx_args, launch_context, discovery_override
		)

	var system_cmd := ""
	if discovery_override.has("system_path"):
		system_cmd = str(discovery_override["system_path"])
	else:
		system_cmd = _find_system_install()
	if not system_cmd.is_empty():
		var probe: Dictionary
		if discovery_override.has("system_version_result"):
			probe = discovery_override["system_version_result"] as Dictionary
		else:
			probe = McpCliExec.run(system_cmd, ["--version"], _DISCOVERY_TIMEOUT_MS, false)
		var version_check := _system_version_from_probe(probe)
		if bool(version_check.get("ok", false)):
			var found_version := str(version_check.get("version", ""))
			if found_version == plugin_version:
				return _finalize_attach_launch(
					"system", system_cmd, common_args, launch_context, discovery_override
				)
			return _attach_discovery_error(
				"System godot-ai is version %s, but this plugin requires %s. Install uv or update the system package, then retry Configure."
				% [found_version, plugin_version]
			)
		if bool(probe.get("timed_out", false)):
			return _attach_discovery_error(
				"Timed out checking the system godot-ai version. Install uv or repair the system command, then retry Configure."
			)
		return _attach_discovery_error(
			"Could not verify the system godot-ai version. Install uv or repair the system command, then retry Configure."
		)

	return _attach_discovery_error(
		"No compatible godot-ai launcher was found. Install uv (provides uvx), then retry Configure."
	)


## Return a launch shape that cannot allocate a visible console on Windows.
## The development tier can execute its sibling pythonw directly. uvx and the
## system entry point still need their own environments, so pythonw acts only
## as a stdio-preserving, CREATE_NO_WINDOW process bootstrap for those tiers.
static func _finalize_attach_launch(
	tier: String,
	command: String,
	args: Array[String],
	launch_context: Dictionary,
	discovery_override: Dictionary,
) -> Dictionary:
	if str(launch_context.get("platform", "")) != "Windows":
		return {"ok": true, "tier": tier, "command": command, "args": args}

	var pythonw := _resolve_consoleless_python(command, tier, discovery_override)
	if pythonw.is_empty():
		return _attach_discovery_error(
			"Windows requires pythonw.exe to launch the MCP bridge without opening a terminal window. Repair this Python or uv installation, then retry Configure."
		)

	## `console_command`/`console_args` carry the unwrapped console-subsystem
	## launch for clients that opt out of pythonw via
	## `needs_consoleless_launcher = false` (#863). Strategies only consume
	## `command`/`args`/`ok`; `launch_for_client` swaps the shapes per client.
	if tier == "dev_venv":
		return {
			"ok": true, "tier": tier, "command": pythonw, "args": args,
			"console_command": command, "console_args": args,
		}

	var wrapped_args: Array[String] = ["-c", _WINDOWS_STDIO_BOOTSTRAP, command]
	wrapped_args.append_array(args)
	return {
		"ok": true, "tier": tier, "command": pythonw, "args": wrapped_args,
		"console_command": command, "console_args": args,
	}


## Select the launch shape a specific client should see. Clients with
## `needs_consoleless_launcher = false` (Antigravity, #863) get the plain
## console command captured by `_finalize_attach_launch`; everyone else keeps
## the pythonw shape unchanged. Idempotent: the returned dict carries no
## console keys, so a second application is a no-op.
static func launch_for_client(client: Client, launch: Dictionary) -> Dictionary:
	if client == null or client.needs_consoleless_launcher:
		return launch
	if not launch.has("console_command"):
		return launch
	var selected := launch.duplicate(true)
	selected["command"] = selected["console_command"]
	selected["args"] = selected["console_args"]
	selected.erase("console_command")
	selected.erase("console_args")
	return selected


static func _resolve_consoleless_python(
	command: String, tier: String, discovery_override: Dictionary
) -> String:
	## Data-only override keeps resolver tests independent of the host's Python.
	if discovery_override.has("consoleless_python"):
		return str(discovery_override["consoleless_python"])

	## Venv/system console-script launchers normally keep pythonw beside their
	## python.exe. The dev tier must use that exact interpreter so godot_ai is
	## imported from the selected checkout rather than some unrelated install.
	var sibling := command.get_base_dir().path_join("pythonw.exe")
	if FileAccess.file_exists(sibling):
		return sibling
	if tier == "dev_venv":
		return ""

	## uvx may be installed without a PATH-visible CPython. Ask its sibling uv
	## for the already-managed system interpreter; Godot AI's existing uvx
	## server launch ensures one normally exists before client configuration.
	if tier == "uvx":
		var uv := command.get_base_dir().path_join("uv.exe")
		if not FileAccess.file_exists(uv):
			uv = CliFinder.find(["uv.exe"])
		if not uv.is_empty():
			var probe := McpCliExec.run(
				uv, ["python", "find", "--system"], _DISCOVERY_TIMEOUT_MS, false
			)
			if int(probe.get("exit_code", -1)) == 0:
				var python := str(probe.get("stdout", "")).strip_edges()
				if not python.is_empty():
					var managed_pythonw := python.get_base_dir().path_join("pythonw.exe")
					if FileAccess.file_exists(managed_pythonw):
						return managed_pythonw

	## A system Python GUI launcher is sufficient for the non-dev bootstrap;
	## it does not import godot_ai itself.
	return CliFinder.find(["pythonw.exe"])


static func _system_version_from_probe(probe: Dictionary) -> Dictionary:
	if int(probe.get("exit_code", -1)) != 0:
		return {"ok": false}
	var output := str(probe.get("stdout", "")).strip_edges()
	var pattern := RegEx.new()
	if pattern.compile("^godot-ai\\s+([^\\s]+)(?:\\s|$)") != OK:
		return {"ok": false}
	var matched := pattern.search(output)
	if matched == null:
		return {"ok": false}
	return {"ok": true, "version": matched.get_string(1)}


static func _attach_discovery_error(message: String) -> Dictionary:
	return {"ok": false, "error": message}


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
##   1. EditorSettings → `godot_ai/mode_override` — set manually via
##      Editor Settings (no dock UI writes it today); persists
##      per-editor-install and wins over the env var so an editor-side
##      choice always takes effect without relaunching.
##   2. Env var `GODOT_AI_MODE` — useful for CLI launches and CI.
const MODE_OVERRIDE_ENV := "GODOT_AI_MODE"
const MODE_OVERRIDE_SETTING := "godot_ai/mode_override"


static func mode_override() -> String:
	# 1. EditorSetting wins — the user explicitly set it via Editor Settings.
	#    _editor_setting_lookup handles the `Engine.is_editor_hint()` gate
	#    (no-op in the game subprocess; see CLAUDE.md "Game-side code") and
	#    serves worker threads from a main-thread-warmed snapshot — this
	#    runs on the #678 startup walk's discovery worker, and
	#    EditorInterface/EditorSettings are not thread-safe (#691).
	var setting: Variant = _editor_setting_lookup(MODE_OVERRIDE_SETTING)
	if setting != null:
		var setting_val := str(setting).strip_edges().to_lower()
		if setting_val == "dev" or setting_val == "user":
			return setting_val
	# 2. Env var fallback. env_lookup, not OS.get_environment: same
	#    worker-thread reason (#691).
	var raw := McpPathTemplate.env_lookup(MODE_OVERRIDE_ENV).strip_edges().to_lower()
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
	if dir == null:
		## This is a data-safety guard (a symlinked addons dir is a dev
		## checkout self-update must never write through). When the path
		## exists but its parent can't be opened, we can't PROVE it isn't
		## a link — fail closed and treat it as one (#711).
		return DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path)
	return dir.is_link(path)


## `refresh` forces uvx to re-fetch PyPI index metadata on spawn — used by
## `_start_server`'s one-shot retry when the first attempt exited fast with
## no pid-file on the uvx tier (stale-index-cache failure mode). No-op on
## other tiers: dev_venv and system resolve locally, so the flag has nowhere
## to go. See plugin.gd::_should_retry_with_refresh.
static func get_server_command(refresh: bool = false) -> Array[String]:
	## `mode_override() == "user"` skips the dev_venv tier even when a nearby
	## .venv exists — the override then becomes an actual workaround for
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
		## PEP 440 local build tags (e.g. 3.0.2+local.1) are not on PyPI.
		## Pin uvx to the public base version so the server still boots;
		## checkout-local extras need the dev_venv tier above
		## (symlink/junction → repo .venv).
		var pypi_version := _pypi_pin_version(version)
		## Pin to the EXACT plugin version rather than `~=<minor>`. Under the
		## tilde form, uvx was happy to reuse a cached tool env that matched
		## the minor constraint — so an install that first spawned 1.2.0 kept
		## using 1.2.0 even after 1.2.1/1.2.2 landed. Exact pinning makes the
		## cache key version-specific: if the cached env matches, fast hit;
		## otherwise uvx installs the exact version fresh. Keeps plugin and
		## server version in lockstep without needing `--refresh-package` on
		## every spawn. See issue #133.
		if pypi_version != version:
			print(
				"MCP | using uvx (godot-ai==%s; local plugin %s not on PyPI)%s"
				% [pypi_version, version, " [refresh]" if refresh else ""]
			)
		else:
			print("MCP | using uvx (godot-ai==%s)%s" % [pypi_version, " [refresh]" if refresh else ""])
		var cmd: Array[String] = [uvx]
		if refresh:
			cmd.append("--refresh")
		cmd.append_array(["--from", "godot-ai==%s" % pypi_version, "godot-ai"])
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


## Pre-build the uvx tool environment for `godot-ai==<version>` in the
## background, so the FIRST spawn of that version is a warm cache hit.
## Fired when a self-update install starts: post-update the old backend is
## killed and the new one spawned, and a cold `uvx --from godot-ai==<new>`
## resolve+install takes seconds — while an attach bridge pinned to the OLD
## version respawns its already-cached backend near-instantly, winning the
## port bind race every time (the INCOMPATIBLE dead end after every
## self-update with a live AI client). Warming the new env while the plugin
## zip downloads flips that race.
##
## `--version` makes the spawned process exit immediately after uv resolves
## and installs the env. Detached fire-and-forget: a failure only means the
## post-update spawn pays the cold cost it always used to. Returns the
## spawned PID, or -1 when skipped (no uvx on this machine — the dev-venv
## and system tiers have no per-version cache to warm — or no version).
static func prewarm_server_package(version: String) -> int:
	var args := prewarm_server_package_argv(version)
	if args.is_empty():
		return -1
	var uvx := find_uvx()
	if uvx.is_empty():
		return -1
	var pid := OS.create_process(uvx, args)
	if pid > 0:
		print("MCP | pre-warming godot-ai==%s server package for the post-update restart" % version.strip_edges())
	return pid


## Pure argv builder for the pre-warm spawn, split out so tests can pin the
## exact command without spawning a process. Empty array when there is no
## version to pin, or when the version carries characters outside the PEP
## 440 alphabet — the value can originate from a GitHub release tag, and
## while OS.create_process argv can't be shell-injected, constraining the
## pin keeps a hostile tag from smuggling anything into the requirement
## spec uv parses (#890 review).
static func prewarm_server_package_argv(version: String) -> Array[String]:
	var pinned := version.strip_edges()
	if pinned.is_empty():
		return []
	var re := RegEx.new()
	if re.compile("^[A-Za-z0-9.+!*-]+$") != OK or re.search(pinned) == null:
		return []
	return ["--from", "godot-ai==%s" % pinned, "godot-ai", "--version"]


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
## across the dictionary clear, never across the bounded subprocess lookup,
## so this call can never block the main thread on a subprocess.
static func invalidate_cli_cache() -> void:
	CliFinder.invalidate()


static var _uv_version_cache: String = ""
static var _uv_version_searched: bool = false


## Cached for the editor session. The dock's `_refresh_setup_status`
## (called via `call_deferred` from `_build_ui`) calls this on the
## main thread in user mode, so the cold `uvx --version` probe is
## wall-clock bounded and cached. Subsequent calls (focus-in refresh,
## manual Refresh clicks) reuse the cached string.
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
	var result := McpCliExec.run(uvx, ["--version"], _DISCOVERY_TIMEOUT_MS, false)
	if int(result.get("exit_code", -1)) == 0:
		var lines := PackedStringArray(str(result.get("stdout", "")).split("\n"))
		_uv_version_cache = lines[0].strip_edges() if lines.size() > 0 else ""
	else:
		_uv_version_cache = ""
	_uv_version_searched = true
	return _uv_version_cache


static func invalidate_uv_version_cache() -> void:
	_uv_version_searched = false
	_uv_version_cache = ""


## True when a probe has run this session and came back empty — i.e. the
## dock is currently rendering "uv: not found". Lets callers decide when
## a re-probe is worth paying for (server-connect transition, manual
## Refresh) without ever re-probing once uv has been found.
static func uv_probe_negative() -> bool:
	return _uv_version_searched and _uv_version_cache.is_empty()


## Drop both uv caches — the resolved uvx path AND the cached
## `uvx --version` output — so the next check_uv_version() re-runs the
## full detection. #739: a probe that fails once at editor startup
## (contended spawn, cold Defender scan, stale PATH under a
## Steam-launched editor) used to pin "uv: not found" for the whole
## session; the Install-uv click was the only invalidation path. Callers
## invoke this on events that suggest the failure was transient.
static func invalidate_uv_detection() -> void:
	invalidate_uvx_cli_cache()
	invalidate_uv_version_cache()
	_attach_launch_cache_mutex.lock()
	_attach_launch_cache.clear()
	_attach_launch_cache_mutex.unlock()


static var _venv_python_cache: String = ""
static var _venv_python_searched: bool = false
## #678 worker threads write this cache while main-thread callers read
## it; same lock discipline as McpCliFinder (clients/_cli_finder.gd).
static var _venv_mutex: Mutex = Mutex.new()
static var _attach_launch_cache := {}
static var _attach_launch_cache_mutex := Mutex.new()


static func _attach_launch_cache_key(launch_context: Dictionary) -> String:
	return JSON.stringify([
		launch_context.get("http_port", null),
		launch_context.get("ws_port", null),
		launch_context.get("excluded_domains", null),
		launch_context.get("plugin_version", null),
		launch_context.get("allow_dev_venv", null),
		launch_context.get("platform", null),
		launch_context.get("telemetry_enabled", null),
	])


static func _cached_venv_python() -> String:
	_venv_mutex.lock()
	if not _venv_python_searched:
		_venv_python_cache = _find_venv_python()
		_venv_python_searched = true
	var cached := _venv_python_cache
	_venv_mutex.unlock()
	return cached


## Absolute path to `res://addons/godot_ai`, resolving Windows junctions /
## POSIX symlinks via `DirAccess.read_link`. Unresolved globalize_path only
## walks the *logical* project path (e.g. MyGame/addons/godot_ai → MyGame)
## and never reaches a fork checkout's `.venv` (…/godot-ai/.venv).
static func resolve_addons_realpath() -> String:
	var addons_path := ProjectSettings.globalize_path("res://addons/godot_ai").rstrip("/").rstrip("\\")
	if addons_path.is_empty():
		return ""
	var parent := addons_path.get_base_dir()
	var dir := DirAccess.open(parent)
	if dir != null and dir.is_link(addons_path):
		var target := dir.read_link(addons_path)
		if not target.is_empty():
			if target.is_relative_path():
				target = parent.path_join(target).simplify_path()
			return target.rstrip("/").rstrip("\\")
	return addons_path


static func _find_venv_python() -> String:
	## Optional hard override (junction edge cases / CI).
	var env_py := McpPathTemplate.env_lookup("GODOT_AI_VENV_PYTHON").strip_edges()
	if not env_py.is_empty():
		if FileAccess.file_exists(env_py):
			return env_py
		## An explicit override pointing nowhere is a misconfiguration the
		## user needs to see — falling through silently would make the dev
		## venv appear randomly ignored.
		push_warning(
			"godot-ai: GODOT_AI_VENV_PYTHON is set but no file exists at '%s'; ignoring override."
			% env_py
		)
	## 1) Walk up from the open project (classic monorepo / test_project layout).
	var from_project := _find_venv_python_in(
		ProjectSettings.globalize_path("res://").rstrip("/").rstrip("\\")
	)
	if not from_project.is_empty():
		return from_project
	## 2) Junctioned plugin: resolve reparse target, then walk up to fork root.
	var addons_real := resolve_addons_realpath()
	if not addons_real.is_empty():
		var from_addons := _find_venv_python_in(addons_real)
		if not from_addons.is_empty():
			return from_addons
	return ""


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
	var dir := start_dir.rstrip("/").rstrip("\\")
	var python_name := "python" if OS.get_name() != "Windows" else "python.exe"
	var venv_dir := ".venv/bin/" if OS.get_name() != "Windows" else ".venv/Scripts/"
	## 8 hops: game project roots are shallow; junctioned plugins sit at
	## <repo>/plugin/addons/godot_ai (4) and nested worktrees may be deeper.
	for i in 8:
		var venv_path := dir.path_join(venv_dir + python_name)
		if FileAccess.file_exists(venv_path) and DirAccess.dir_exists_absolute(dir.path_join("src/godot_ai")):
			return venv_path
		var parent := dir.get_base_dir()
		if parent == dir or parent.is_empty():
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


## Delegates to McpCliFinder rather than shelling out to which/where
## directly: the finder adds the well-known-install-dirs and login-shell
## PATH tiers plus its per-exe cache, and this drops the private
## `_pick_best_path` cross-class reach (#711).
static func _find_system_install() -> String:
	## Built with append, not a ternary of untyped literals — assigning a
	## ternary's Array to Array[String] is a runtime error on newer Godot
	## builds (same idiom as _uvx_cli_names above).
	var names: Array[String] = ["godot-ai"]
	if OS.get_name() == "Windows":
		names.push_front("godot-ai.exe")
	return CliFinder.find(names)
