@tool
class_name McpClientConfigurator
extends RefCounted

## Configures MCP clients (Claude Code, Antigravity, etc.) to connect to
## the Godot MCP Studio server.

enum ClientType { CLAUDE_CODE, ANTIGRAVITY }
enum ConfigStatus { NOT_CONFIGURED, CONFIGURED, ERROR }

const SERVER_NAME := "godot-ai"
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
#
# Three-tier resolution:
#   1. .venv python  — dev checkout, source code
#   2. uvx           — user install, published package from PyPI
#   3. godot-ai CLI  — system-wide pip/pipx/uv install

## Read the plugin version from plugin.cfg.
static func get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/godot_ai/plugin.cfg") == OK:
		return cfg.get_value("plugin", "version", "0.0.1")
	return "0.0.1"


## True if a .venv exists near the project (repo checkout).
static func is_dev_checkout() -> bool:
	return not _find_venv_python().is_empty()


## Get the server launch command. Returns empty array if nothing found.
static func get_server_command() -> Array[String]:
	# Tier 1: dev checkout — use venv python + source
	var venv_python := _cached_venv_python()
	if not venv_python.is_empty():
		print("MCP | using dev venv: %s" % venv_python)
		return [venv_python, "-m", "godot_ai"]

	# Tier 2: uvx — published package, auto-updates
	var uvx := find_uvx()
	if not uvx.is_empty():
		var version := get_plugin_version()
		print("MCP | using uvx (godot-ai~=%s)" % version)
		return [uvx, "--from", "godot-ai~=%s" % version, "godot-ai"]

	# Tier 3: system install fallback
	var system_cmd := _find_system_install()
	if not system_cmd.is_empty():
		print("MCP | using system install: %s" % system_cmd)
		return [system_cmd]

	push_warning("MCP | no server found — install uv or run: pip install godot-ai")
	return []


## Find the uvx executable, checking platform-specific locations.
static func find_uvx() -> String:
	var extra_paths := _get_platform_path_prepend()
	var search_names := ["uvx"]

	for name in search_names:
		# Check extra platform paths first
		for dir in extra_paths:
			var full := dir.path_join(name)
			if FileAccess.file_exists(full):
				return full

		# Check via which/where
		var cmd := "which" if OS.get_name() != "Windows" else "where"
		var output: Array = []
		var env_path := OS.get_environment("PATH")
		if not extra_paths.is_empty():
			var prepend := ":".join(extra_paths) if OS.get_name() != "Windows" else ";".join(extra_paths)
			env_path = prepend + (":" if OS.get_name() != "Windows" else ";") + env_path
		var exit_code := OS.execute(cmd, [name], output, true)
		if exit_code == 0 and output.size() > 0:
			var found: String = output[0].strip_edges()
			if not found.is_empty():
				return found

	return ""


## Check if uv/uvx is installed. Returns version string or empty.
static func check_uv_version() -> String:
	var uvx := find_uvx()
	if uvx.is_empty():
		return ""
	var output: Array = []
	var exit_code := OS.execute(uvx, ["--version"], output, true)
	if exit_code == 0 and output.size() > 0:
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
	var dir := ProjectSettings.globalize_path("res://").rstrip("/")
	var python_name := "python" if OS.get_name() != "Windows" else "python.exe"
	var venv_dir := ".venv/bin/" if OS.get_name() != "Windows" else ".venv/Scripts/"
	for i in 5:
		var venv_path := dir.path_join(venv_dir + python_name)
		if FileAccess.file_exists(venv_path):
			return venv_path
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


static func _find_system_install() -> String:
	var cmd := "which" if OS.get_name() != "Windows" else "where"
	var output: Array = []
	var exit_code := OS.execute(cmd, ["godot-ai"], output, true)
	if exit_code == 0 and output.size() > 0:
		var found: String = output[0].strip_edges()
		if not found.is_empty():
			return found
	return ""


## Platform-specific directories where uv/uvx might be installed.
static func _get_platform_path_prepend() -> Array[String]:
	match OS.get_name():
		"macOS":
			var home := OS.get_environment("HOME")
			return [
				home.path_join(".local/bin"),
				"/opt/homebrew/bin",
				"/usr/local/bin",
			]
		"Windows":
			var local := OS.get_environment("LOCALAPPDATA")
			var prog := OS.get_environment("ProgramFiles")
			var paths: Array[String] = []
			if not local.is_empty():
				paths.append(local.path_join("Programs/uv"))
			if not prog.is_empty():
				paths.append(prog.path_join("uv"))
			return paths
		"Linux":
			var home := OS.get_environment("HOME")
			return [
				home.path_join(".local/bin"),
				"/usr/local/bin",
			]
	return []


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
