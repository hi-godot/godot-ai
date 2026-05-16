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


## Returns true if the string value is truthy
## ("1", "true", "yes", "on", case-insensitive, whitespace-trimmed).
static func truthy(value: String) -> bool:
	return value.strip_edges().to_lower() in ["1", "true", "yes", "on"]


## Returns true if the named environment variable is set to a truthy value.
static func env_truthy(var_name: String) -> bool:
	return truthy(OS.get_environment(var_name))


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
