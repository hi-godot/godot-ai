@tool
class_name McpClientConfigurator
extends RefCounted

## Public facade for the MCP client configuration system.
##
## Per-client logic lives in clients/*.gd (one descriptor per client) and is
## dispatched through clients/_registry.gd. This file:
##   - keeps server-side constants (SERVER_NAME, SERVER_HTTP_URL, ports)
##   - keeps server-launch discovery (.venv → uvx → system godot-ai)
##   - exposes string-id wrappers around configure / check_status / remove /
##     manual_command so callers don't need to touch the registry directly
##
## To add a new client: drop a file in clients/, then preload it in
## clients/_registry.gd. No edits required here.

const SERVER_NAME := "godot-ai"
const SERVER_WS_PORT := 9500
const SERVER_HTTP_PORT := 8000
const SERVER_HTTP_URL := "http://127.0.0.1:%d/mcp" % SERVER_HTTP_PORT


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
	match client.config_type:
		"json":
			return McpJsonStrategy.configure(client, SERVER_NAME, SERVER_HTTP_URL)
		"toml":
			return McpTomlStrategy.configure(client, SERVER_NAME, SERVER_HTTP_URL)
		"cli":
			return McpCliStrategy.configure(client, SERVER_NAME, SERVER_HTTP_URL)
	return {"status": "error", "message": "Unknown config_type for %s: %s" % [id, client.config_type]}


static func check_status(id: String) -> McpClient.Status:
	var client := McpClientRegistry.get_by_id(id)
	if client == null:
		return McpClient.Status.NOT_CONFIGURED
	match client.config_type:
		"json":
			return McpJsonStrategy.check_status(client, SERVER_NAME, SERVER_HTTP_URL)
		"toml":
			return McpTomlStrategy.check_status(client, SERVER_NAME, SERVER_HTTP_URL)
		"cli":
			return McpCliStrategy.check_status(client, SERVER_NAME, SERVER_HTTP_URL)
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
	return client.manual_command_builder.call(SERVER_NAME, SERVER_HTTP_URL, client.resolved_config_path())


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


static func is_dev_checkout() -> bool:
	return not _find_venv_python().is_empty()


static func get_server_command() -> Array[String]:
	var venv_python := _cached_venv_python()
	if not venv_python.is_empty():
		print("MCP | using dev venv: %s" % venv_python)
		return [venv_python, "-m", "godot_ai"]

	var uvx := find_uvx()
	if not uvx.is_empty():
		var version := get_plugin_version()
		print("MCP | using uvx (godot-ai~=%s)" % version)
		return [uvx, "--from", "godot-ai~=%s" % version, "godot-ai"]

	var system_cmd := _find_system_install()
	if not system_cmd.is_empty():
		print("MCP | using system install: %s" % system_cmd)
		return [system_cmd]

	push_warning("MCP | no server found — install uv or run: pip install godot-ai")
	return []


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
	if OS.execute(cmd, ["godot-ai"], output, true) == 0 and output.size() > 0:
		var found: String = output[0].strip_edges()
		if not found.is_empty():
			return found
	return ""
