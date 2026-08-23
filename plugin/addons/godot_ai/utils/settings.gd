@tool
class_name McpSettings
extends RefCounted

## Shared EditorSettings key constants for the godot_ai/* namespace.
##
## Centralised here so lightweight files (e.g. telemetry.gd) can reference
## settings keys without pulling in the full client_configurator.gd dep tree.
## All keys must keep their raw string values stable across releases because
## they are persisted in the user's editor_settings-4.tres.

const SETTING_HTTP_PORT := "godot_ai/http_port"
## Comma-separated list of tool domains excluded from the server at spawn time.
const SETTING_EXCLUDED_DOMAINS := "godot_ai/excluded_domains"
const SETTING_TELEMETRY_ENABLED := "godot_ai/telemetry_enabled"
## Comma-separated CIDRs / bare IPs passed to the server as `--allow-host`
## at spawn time (#507, server core #421). Empty means loopback-only.
const SETTING_ALLOW_HOSTS := "godot_ai/allow_remote_hosts"
## Whether MCP log lines echo to the Godot console (dock "Log" toggle).
## The dock's ring-buffer log panel keeps recording regardless.
const SETTING_MCP_LOGGING := "godot_ai/mcp_logging"
## Which scope CLI-configured clients register the server in. Claude Code's
## `--scope user` writes the global block of ~/.claude.json, which that client
## loads in EVERY workspace — so the server gets spawned in unrelated,
## non-Godot projects. `project` writes <project>/.mcp.json instead, so the
## entry travels with the project. Defaults to `user` to preserve the
## historical behaviour for existing installs.
const SETTING_CLIENT_SCOPE := "godot_ai/mcp_client_scope"

## Scopes accepted for SETTING_CLIENT_SCOPE. These are the values the Claude
## Code CLI's `--scope` flag takes; an unrecognised setting falls back to
## DEFAULT_CLIENT_SCOPE rather than passing junk to the CLI.
const CLIENT_SCOPES := ["user", "project", "local"]
const DEFAULT_CLIENT_SCOPE := "user"


## Returns true if the string value is truthy
## ("1", "true", "yes", "on", case-insensitive, whitespace-trimmed).
static func truthy(value: String) -> bool:
	return value.strip_edges().to_lower() in ["1", "true", "yes", "on"]


## Returns true if the named environment variable is set to a truthy value.
static func env_truthy(var_name: String) -> bool:
	return truthy(OS.get_environment(var_name))


## #691: EditorInterface / EditorSettings are not thread-safe, and the dock
## runs Configure / Remove on a worker Thread (mcp_dock.gd
## `_run_client_action_worker` -> McpClientConfigurator -> McpCliStrategy
## `_format_args` -> client_scope()). Same contract as
## McpClientConfigurator._editor_setting_lookup: the main thread does a live
## read and refreshes the snapshot; worker threads read the snapshot only, so
## a never-warmed value reads as null (unset) rather than touching
## EditorInterface off-thread. Warmed on the main thread by
## McpClientConfigurator.warm_env_snapshot() before each worker dispatch.
##
## Kept here rather than reusing the configurator's `_editor_setting_lookup`
## so utils/settings.gd stays free of the client_configurator.gd dep tree —
## see this file's header.
static var _client_scope_snapshot: Variant = null
static var _client_scope_mutex := Mutex.new()


static func _client_scope_setting() -> Variant:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		var live: Variant = null
		if Engine.is_editor_hint():
			var es := EditorInterface.get_editor_settings()
			if es != null and es.has_setting(SETTING_CLIENT_SCOPE):
				live = es.get_setting(SETTING_CLIENT_SCOPE)
		_client_scope_mutex.lock()
		_client_scope_snapshot = live
		_client_scope_mutex.unlock()
		return live
	_client_scope_mutex.lock()
	var cached: Variant = _client_scope_snapshot
	_client_scope_mutex.unlock()
	return cached


## Main-thread pre-warm of the scope snapshot so the dock's Configure/Remove
## worker resolves `{scope}` from a value captured while EditorSettings access
## was safe. Idempotent; called from warm_env_snapshot().
static func warm_client_scope() -> void:
	_client_scope_setting()


## Returns the scope CLI clients should register the MCP server in, as
## substituted into `{scope}` in a descriptor's cli_register_template /
## cli_unregister_template. Safe to call from either thread (see
## _client_scope_setting). Unrecognised values fall back to
## DEFAULT_CLIENT_SCOPE so a hand-edited editor_settings-4.tres can never make
## the plugin shell out with a bad flag.
static func client_scope() -> String:
	var value: Variant = _client_scope_setting()
	## String(null) is a hard error (#850) — an unset/never-warmed key must
	## short-circuit before the cast.
	if value == null:
		return DEFAULT_CLIENT_SCOPE
	var raw := String(value).strip_edges().to_lower()
	if raw in CLIENT_SCOPES:
		return raw
	return DEFAULT_CLIENT_SCOPE


## Returns true if telemetry should be active, checking in priority order:
##   1. GODOT_AI_DISABLE_TELEMETRY / DISABLE_TELEMETRY env vars
##   2. The godot_ai/telemetry_enabled EditorSetting written by the dock UI
## Defaults to true when neither source has set a preference.
static func telemetry_enabled() -> bool:
	if env_truthy("GODOT_AI_DISABLE_TELEMETRY") or env_truthy("DISABLE_TELEMETRY"):
		return false
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(SETTING_TELEMETRY_ENABLED):
		return bool(es.get_setting(SETTING_TELEMETRY_ENABLED))
	return true


## Returns whether MCP log lines should echo to the Godot console. Read at
## plugin startup (to apply the persisted choice to the log buffer and
## dispatcher) and by the dock's LogViewer toggle for its initial state.
## Defaults to true when the user has never touched the toggle.
static func mcp_logging_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(SETTING_MCP_LOGGING):
		return bool(es.get_setting(SETTING_MCP_LOGGING))
	return true


## Persist the dock "Log" toggle so the choice survives editor restarts (#626).
static func set_mcp_logging_enabled(enabled: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(SETTING_MCP_LOGGING, enabled)
