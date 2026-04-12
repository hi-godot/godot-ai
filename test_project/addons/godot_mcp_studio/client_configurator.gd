@tool
class_name McpClientConfigurator
extends RefCounted

## Configures MCP clients (Claude Code, Antigravity, etc.) to connect to
## the Godot MCP Studio server.

enum ClientType { CLAUDE_CODE, ANTIGRAVITY }
enum ConfigStatus { NOT_CONFIGURED, CONFIGURED, ERROR }

const SERVER_NAME := "godot-mcp-studio"
const SERVER_WS_PORT := 9500
const SERVER_HTTP_PORT := 8000
const SERVER_HTTP_URL := "http://127.0.0.1:%d/mcp" % SERVER_HTTP_PORT

## Map client name strings to enum values.
const CLIENT_TYPE_MAP := {
	"claude_code": ClientType.CLAUDE_CODE,
	"antigravity": ClientType.ANTIGRAVITY,
}


static func configure(client: ClientType) -> Dictionary:
	match client:
		ClientType.CLAUDE_CODE:
			return _configure_claude_code()
		ClientType.ANTIGRAVITY:
			return _configure_antigravity()
	return {"status": "error", "message": "Unknown client type"}


static func check_status(client: ClientType) -> ConfigStatus:
	match client:
		ClientType.CLAUDE_CODE:
			return _check_claude_code()
		ClientType.ANTIGRAVITY:
			return _check_antigravity()
	return ConfigStatus.NOT_CONFIGURED


static func remove(client: ClientType) -> Dictionary:
	match client:
		ClientType.CLAUDE_CODE:
			return _remove_claude_code()
		ClientType.ANTIGRAVITY:
			return _remove_antigravity()
	return {"status": "error", "message": "Unknown client type"}


## Resolve a client name string to enum. Returns -1 if unknown.
static func client_type_from_string(name: String) -> int:
	return CLIENT_TYPE_MAP.get(name, -1)


# --- Server command discovery ---

## Get the absolute path to the server command.
## Checks: well-known install locations → which → venv python → system python.
static func get_server_command() -> Array[String]:
	var home := OS.get_environment("HOME")
	for bin_path in [
		home.path_join(".local/bin/godot-mcp-studio"),
		"/usr/local/bin/godot-mcp-studio",
		"/opt/homebrew/bin/godot-mcp-studio",
	]:
		if FileAccess.file_exists(bin_path):
			return [bin_path]

	var output: Array = []
	var exit_code := OS.execute("which", ["godot-mcp-studio"], output, true)
	if exit_code == 0 and output.size() > 0:
		var cmd_path: String = output[0].strip_edges()
		if not cmd_path.is_empty():
			return [cmd_path]

	var venv_python := _find_venv_python()
	if not venv_python.is_empty():
		return [venv_python, "-m", "godot_mcp_studio"]

	return ["python3", "-m", "godot_mcp_studio"]


static func _find_venv_python() -> String:
	var project_dir := ProjectSettings.globalize_path("res://")
	var dir := project_dir
	for i in 5:
		var venv_path := dir.path_join(".venv/bin/python")
		if FileAccess.file_exists(venv_path):
			return venv_path
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


# --- Claude Code ---

static func _configure_claude_code() -> Dictionary:
	OS.execute("claude", ["mcp", "remove", SERVER_NAME], [], true)

	var args: Array[String] = ["mcp", "add", "--scope", "user", "--transport", "http", SERVER_NAME, SERVER_HTTP_URL]
	var output: Array = []
	var exit_code := OS.execute("claude", args, output, true)

	if exit_code == 0:
		return {"status": "ok", "message": "Claude Code configured (HTTP: %s)" % SERVER_HTTP_URL}
	var err_msg: String = output[0].strip_edges() if output.size() > 0 else "Unknown error"
	return {"status": "error", "message": "Failed to configure Claude Code: %s" % err_msg}


static func _check_claude_code() -> ConfigStatus:
	var output: Array = []
	var exit_code := OS.execute("claude", ["mcp", "list"], output, true)
	if exit_code != 0:
		return ConfigStatus.NOT_CONFIGURED

	var output_text: String = output[0] if output.size() > 0 else ""
	if output_text.find(SERVER_NAME) < 0:
		return ConfigStatus.NOT_CONFIGURED
	if output_text.find(SERVER_HTTP_URL) < 0:
		return ConfigStatus.NOT_CONFIGURED

	return ConfigStatus.CONFIGURED


static func _remove_claude_code() -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute("claude", ["mcp", "remove", SERVER_NAME], output, true)
	if exit_code == 0:
		return {"status": "ok", "message": "Claude Code configuration removed"}
	var err_msg: String = output[0].strip_edges() if output.size() > 0 else "Unknown error"
	return {"status": "error", "message": "Failed to remove: %s" % err_msg}


# --- Antigravity ---

static func _get_antigravity_config_path() -> String:
	return OS.get_environment("HOME").path_join(".gemini/antigravity/mcp_config.json")


## Read and parse the Antigravity config file. Returns null if missing/invalid.
static func _read_antigravity_config() -> Variant:
	var config_path := _get_antigravity_config_path()
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return null
	var content := file.get_as_text()
	file.close()
	if content.is_empty():
		return null
	var json := JSON.new()
	if json.parse(content) != OK:
		push_warning("MCP | Antigravity config parse error: %s (at line %d)" % [json.get_error_message(), json.get_error_line()])
		return null
	if not (json.data is Dictionary):
		return null
	return json.data


## Write the Antigravity config file, preserving other entries.
static func _write_antigravity_config(config: Dictionary) -> bool:
	var config_path := _get_antigravity_config_path()
	var dir_path := config_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(config, "\t"))
	file.close()
	return true


static func _configure_antigravity() -> Dictionary:
	var config: Dictionary = _read_antigravity_config()
	if config == null:
		config = {"mcpServers": {}}
	if not config.has("mcpServers"):
		config["mcpServers"] = {}

	config["mcpServers"][SERVER_NAME] = {"serverUrl": SERVER_HTTP_URL, "disabled": false}

	if not _write_antigravity_config(config):
		return {"status": "error", "message": "Cannot write to %s" % _get_antigravity_config_path()}
	return {"status": "ok", "message": "Antigravity configured (HTTP: %s)" % SERVER_HTTP_URL}


static func _check_antigravity() -> ConfigStatus:
	var config: Dictionary = _read_antigravity_config()
	if config == null:
		return ConfigStatus.NOT_CONFIGURED

	var servers: Dictionary = config.get("mcpServers", {})
	if not servers.has(SERVER_NAME):
		return ConfigStatus.NOT_CONFIGURED

	var entry: Dictionary = servers[SERVER_NAME]
	if entry.get("serverUrl", "") != SERVER_HTTP_URL:
		return ConfigStatus.NOT_CONFIGURED

	return ConfigStatus.CONFIGURED


static func _remove_antigravity() -> Dictionary:
	var config: Dictionary = _read_antigravity_config()
	if config == null:
		return {"status": "ok", "message": "Not configured"}

	if config.has("mcpServers"):
		config["mcpServers"].erase(SERVER_NAME)
		_write_antigravity_config(config)
	return {"status": "ok", "message": "Antigravity configuration removed"}
