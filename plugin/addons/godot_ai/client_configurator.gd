@tool
class_name McpClientConfigurator
extends RefCounted

## Configures MCP clients (Claude Code, Codex, Antigravity, etc.) to connect to
## the Godot AI server.

enum ClientType { CLAUDE_CODE, CLAUDE_DESKTOP, CODEX, ANTIGRAVITY }
enum ConfigStatus { NOT_CONFIGURED, CONFIGURED, ERROR }

const SERVER_NAME := "godot-ai"
const SERVER_WS_PORT := 9500
const SERVER_HTTP_PORT := 8000
const SERVER_HTTP_URL := "http://127.0.0.1:%d/mcp" % SERVER_HTTP_PORT

## Map client name strings to enum values.
const CLIENT_TYPE_MAP := {
	"claude_code": ClientType.CLAUDE_CODE,
	"claude_desktop": ClientType.CLAUDE_DESKTOP,
	"codex": ClientType.CODEX,
	"antigravity": ClientType.ANTIGRAVITY,
}


static func configure(client: ClientType) -> Dictionary:
	match client:
		ClientType.CLAUDE_CODE:
			return _configure_claude_code()
		ClientType.CLAUDE_DESKTOP:
			return _configure_claude_desktop()
		ClientType.CODEX:
			return _configure_codex()
		ClientType.ANTIGRAVITY:
			return _configure_antigravity()
	return {"status": "error", "message": "Unknown client type"}


static func check_status(client: ClientType) -> ConfigStatus:
	match client:
		ClientType.CLAUDE_CODE:
			return _check_claude_code()
		ClientType.CLAUDE_DESKTOP:
			return _check_claude_desktop()
		ClientType.CODEX:
			return _check_codex()
		ClientType.ANTIGRAVITY:
			return _check_antigravity()
	return ConfigStatus.NOT_CONFIGURED


static func remove(client: ClientType) -> Dictionary:
	match client:
		ClientType.CLAUDE_CODE:
			return _remove_claude_code()
		ClientType.CLAUDE_DESKTOP:
			return _remove_claude_desktop()
		ClientType.CODEX:
			return _remove_codex()
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
## On GUI-launched Godot, PATH is minimal, so we check well-known
## install locations explicitly before falling back to which/where.
static func find_uvx() -> String:
	var extra_paths := _get_platform_path_prepend()
	var is_windows := OS.get_name() == "Windows"
	var exe_name := "uvx.exe" if is_windows else "uvx"

	# Check well-known platform paths first (works even with minimal PATH)
	for dir in extra_paths:
		var full := dir.path_join(exe_name)
		if FileAccess.file_exists(full):
			return full

	# Fallback: which/where using inherited PATH
	var cmd := "where" if is_windows else "which"
	var output: Array = []
	var exit_code := OS.execute(cmd, [exe_name], output, true)
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

static var _claude_cli_cache: String = ""
static var _claude_cli_searched: bool = false


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


# --- Generic JSON config helpers (used by Claude Desktop and Antigravity) ---

static func _read_json_config(config_path: String, label: String) -> Variant:
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return null
	var content := file.get_as_text()
	file.close()
	if content.is_empty():
		return null
	var json := JSON.new()
	if json.parse(content) != OK:
		push_warning("MCP | %s config parse error: %s (at line %d)" % [label, json.get_error_message(), json.get_error_line()])
		return null
	if not (json.data is Dictionary):
		return null
	return json.data


static func _write_json_config(config_path: String, config: Dictionary) -> bool:
	var dir_path := config_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(config, "\t"))
	file.close()
	return true


# --- Claude Code ---

## GUI-launched Godot has a minimal PATH, so resolve `claude` in three steps:
##   1. Check well-known install locations (covers most users)
##   2. Run a login shell (`bash -lc 'which claude'`) to pick up the user's
##      full PATH as configured in .zshrc / .bash_profile / etc.
##   3. Fall back to which/where with the inherited PATH.
static func _find_claude_cli() -> String:
	var is_windows := OS.get_name() == "Windows"
	var exe_name := "claude.exe" if is_windows else "claude"

	# 1. Well-known locations
	var candidates: Array[String] = []
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	if not home.is_empty():
		candidates.append(home.path_join(".local/bin").path_join(exe_name))
		candidates.append(home.path_join(".claude/local").path_join(exe_name))
	candidates.append("/usr/local/bin/%s" % exe_name)
	candidates.append("/opt/homebrew/bin/%s" % exe_name)

	for p in candidates:
		if FileAccess.file_exists(p):
			return p

	# 2. Login shell lookup (Unix only) — catches custom PATH entries in the
	#    user's shell rc files (nvm, asdf, volta, custom prefix, etc.)
	if not is_windows:
		var login_output: Array = []
		var login_exit := OS.execute("/bin/bash", ["-lc", "command -v claude"], login_output, true)
		if login_exit == 0 and login_output.size() > 0:
			var login_found: String = login_output[0].strip_edges()
			if not login_found.is_empty() and FileAccess.file_exists(login_found):
				return login_found

	# 3. which/where fallback using the inherited PATH
	var lookup := "where" if is_windows else "which"
	var output: Array = []
	var exit_code := OS.execute(lookup, [exe_name], output, true)
	if exit_code == 0 and output.size() > 0:
		var found: String = output[0].strip_edges()
		if not found.is_empty():
			return found

	return ""


## Return a human-runnable manual configuration command / instruction for a client.
## Used as a fallback when auto-configure can't find a required CLI, and shown
## in the dock so the user can copy+paste.
static func manual_command(client: ClientType) -> String:
	match client:
		ClientType.CLAUDE_CODE:
			return "claude mcp add --scope user --transport http %s %s" % [SERVER_NAME, SERVER_HTTP_URL]
		ClientType.CLAUDE_DESKTOP:
			return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"command\": \"npx\", \"args\": [\"-y\", \"mcp-remote\", \"%s\"] }" % [
				_get_claude_desktop_config_path(), SERVER_NAME, SERVER_HTTP_URL,
			]
		ClientType.CODEX:
			return "Edit %s and add:\n  [mcp_servers.\"%s\"]\n  url = \"%s\"\n  enabled = true" % [
				_get_codex_config_path(), SERVER_NAME, SERVER_HTTP_URL,
			]
		ClientType.ANTIGRAVITY:
			return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"serverUrl\": \"%s\", \"disabled\": false }" % [
				_get_antigravity_config_path(), SERVER_NAME, SERVER_HTTP_URL,
			]
	return ""


static func _cached_claude_cli() -> String:
	if not _claude_cli_searched:
		_claude_cli_cache = _find_claude_cli()
		_claude_cli_searched = true
	return _claude_cli_cache


static func _configure_claude_code() -> Dictionary:
	var claude_cli := _cached_claude_cli()
	if claude_cli.is_empty():
		return {"status": "error", "message": "Claude CLI not found — install from https://claude.ai/download"}

	OS.execute(claude_cli, ["mcp", "remove", SERVER_NAME], [], true)

	var args: Array[String] = ["mcp", "add", "--scope", "user", "--transport", "http", SERVER_NAME, SERVER_HTTP_URL]
	var output: Array = []
	var exit_code := OS.execute(claude_cli, args, output, true)

	if exit_code == 0:
		return {"status": "ok", "message": "Claude Code configured (HTTP: %s)" % SERVER_HTTP_URL}
	var err_msg: String = output[0].strip_edges() if output.size() > 0 else "Unknown error"
	return {"status": "error", "message": "Failed to configure Claude Code: %s" % err_msg}


static func _check_claude_code() -> ConfigStatus:
	var claude_cli := _cached_claude_cli()
	if claude_cli.is_empty():
		return ConfigStatus.NOT_CONFIGURED
	var output: Array = []
	var exit_code := OS.execute(claude_cli, ["mcp", "list"], output, true)
	if exit_code != 0:
		return ConfigStatus.NOT_CONFIGURED

	var output_text: String = output[0] if output.size() > 0 else ""
	if output_text.find(SERVER_NAME) < 0:
		return ConfigStatus.NOT_CONFIGURED
	if output_text.find(SERVER_HTTP_URL) < 0:
		return ConfigStatus.NOT_CONFIGURED

	return ConfigStatus.CONFIGURED


static func _remove_claude_code() -> Dictionary:
	var claude_cli := _cached_claude_cli()
	if claude_cli.is_empty():
		return {"status": "error", "message": "Claude CLI not found"}
	var output: Array = []
	var exit_code := OS.execute(claude_cli, ["mcp", "remove", SERVER_NAME], output, true)
	if exit_code == 0:
		return {"status": "ok", "message": "Claude Code configuration removed"}
	var err_msg: String = output[0].strip_edges() if output.size() > 0 else "Unknown error"
	return {"status": "error", "message": "Failed to remove: %s" % err_msg}


# --- Codex ---

static func _get_codex_config_path() -> String:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	return home.path_join(".codex/config.toml")


static func _codex_server_header() -> String:
	return "[mcp_servers.\"%s\"]" % SERVER_NAME


static func _codex_legacy_server_header() -> String:
	return "[mcp_servers.%s]" % SERVER_NAME.replace("-", "_")


static func _codex_server_prefixes() -> Array[String]:
	return [
		"[mcp_servers.\"%s\"" % SERVER_NAME,
		"[mcp_servers.%s" % SERVER_NAME.replace("-", "_"),
	]


static func _read_codex_config() -> String:
	var config_path := _get_codex_config_path()
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


static func _write_codex_config(content: String) -> bool:
	var config_path := _get_codex_config_path()
	DirAccess.make_dir_recursive_absolute(config_path.get_base_dir())
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return true


static func _split_lines(content: String) -> Array[String]:
	var lines: Array[String] = []
	for line in content.split("\n"):
		lines.append(line)
	return lines


static func _find_codex_server_section(lines: Array[String]) -> Dictionary:
	var headers := [_codex_server_header(), _codex_legacy_server_header()]
	for i in range(lines.size()):
		var trimmed := lines[i].strip_edges()
		if headers.has(trimmed):
			var end := lines.size()
			for j in range(i + 1, lines.size()):
				var next_trimmed := lines[j].strip_edges()
				if next_trimmed.begins_with("[") and next_trimmed.ends_with("]"):
					end = j
					break
			return {"start": i, "end": end}
	return {}


static func _is_codex_server_section_header(trimmed: String) -> bool:
	for prefix in _codex_server_prefixes():
		if trimmed.begins_with(prefix):
			return true
	return false


static func _join_lines(lines: Array[String]) -> String:
	return "\n".join(lines)


static func _configure_codex() -> Dictionary:
	var content := _read_codex_config()
	var lines := _split_lines(content)
	var section := _find_codex_server_section(lines)
	var server_lines: Array[String] = [
		_codex_server_header(),
		"url = \"%s\"" % SERVER_HTTP_URL,
		"enabled = true",
	]

	if section.is_empty():
		if not lines.is_empty() and not lines[-1].strip_edges().is_empty():
			lines.append("")
		lines.append_array(server_lines)
	else:
		var start: int = section["start"]
		var end: int = section["end"]
		var filtered_body: Array[String] = []
		for i in range(start + 1, end):
			var trimmed := lines[i].strip_edges()
			if trimmed.begins_with("url ="):
				continue
			if trimmed.begins_with("enabled ="):
				continue
			filtered_body.append(lines[i])

		var updated: Array[String] = []
		updated.append_array(lines.slice(0, start))
		updated.append_array(server_lines)
		updated.append_array(filtered_body)
		updated.append_array(lines.slice(end))
		lines = updated

	if not _write_codex_config(_join_lines(lines)):
		return {"status": "error", "message": "Cannot write to %s" % _get_codex_config_path()}
	return {"status": "ok", "message": "Codex configured (HTTP: %s)" % SERVER_HTTP_URL}


static func _check_codex() -> ConfigStatus:
	var content := _read_codex_config()
	if content.is_empty():
		return ConfigStatus.NOT_CONFIGURED

	var lines := _split_lines(content)
	var section := _find_codex_server_section(lines)
	if section.is_empty():
		return ConfigStatus.NOT_CONFIGURED

	var start: int = section["start"]
	var end: int = section["end"]
	var configured_url := ""
	var enabled := true
	for i in range(start + 1, end):
		var trimmed := lines[i].strip_edges()
		if trimmed.begins_with("url ="):
			var first_quote := trimmed.find("\"")
			var last_quote := trimmed.rfind("\"")
			if first_quote >= 0 and last_quote > first_quote:
				configured_url = trimmed.substr(first_quote + 1, last_quote - first_quote - 1)
		elif trimmed.begins_with("enabled ="):
			enabled = trimmed.to_lower().find("false") < 0

	if configured_url != SERVER_HTTP_URL:
		return ConfigStatus.NOT_CONFIGURED
	if not enabled:
		return ConfigStatus.NOT_CONFIGURED
	return ConfigStatus.CONFIGURED


static func _remove_codex() -> Dictionary:
	var content := _read_codex_config()
	if content.is_empty():
		return {"status": "ok", "message": "Not configured"}

	var lines := _split_lines(content)
	var updated: Array[String] = []
	var i := 0
	while i < lines.size():
		var trimmed := lines[i].strip_edges()
		if _is_codex_server_section_header(trimmed):
			i += 1
			while i < lines.size():
				var next_trimmed := lines[i].strip_edges()
				if next_trimmed.begins_with("[") and next_trimmed.ends_with("]"):
					break
				i += 1
			continue
		updated.append(lines[i])
		i += 1

	if not _write_codex_config(_join_lines(updated)):
		return {"status": "error", "message": "Cannot write to %s" % _get_codex_config_path()}
	return {"status": "ok", "message": "Codex configuration removed"}


# --- Claude Desktop ---

static func _get_claude_desktop_config_path() -> String:
	match OS.get_name():
		"macOS":
			return OS.get_environment("HOME").path_join("Library/Application Support/Claude/claude_desktop_config.json")
		"Windows":
			var appdata := OS.get_environment("APPDATA")
			if appdata.is_empty():
				appdata = OS.get_environment("USERPROFILE").path_join("AppData/Roaming")
			return appdata.path_join("Claude/claude_desktop_config.json")
		_:
			# Linux / unofficial — best-effort
			var xdg := OS.get_environment("XDG_CONFIG_HOME")
			if xdg.is_empty():
				xdg = OS.get_environment("HOME").path_join(".config")
			return xdg.path_join("Claude/claude_desktop_config.json")


static func _read_claude_desktop_config() -> Variant:
	return _read_json_config(_get_claude_desktop_config_path(), "Claude Desktop")


static func _write_claude_desktop_config(config: Dictionary) -> bool:
	return _write_json_config(_get_claude_desktop_config_path(), config)


## Claude Desktop only accepts stdio `command`/`args` entries in `mcpServers`.
## For our HTTP server, bridge via `npx mcp-remote <url>` which ships the
## mcp-remote proxy from npm on demand.
static func _claude_desktop_entry() -> Dictionary:
	return {
		"command": "npx",
		"args": ["-y", "mcp-remote", SERVER_HTTP_URL],
	}


static func _configure_claude_desktop() -> Dictionary:
	var config = _read_claude_desktop_config()
	if not (config is Dictionary):
		config = {"mcpServers": {}}
	if not config.has("mcpServers") or not (config["mcpServers"] is Dictionary):
		config["mcpServers"] = {}

	config["mcpServers"][SERVER_NAME] = _claude_desktop_entry()

	if not _write_claude_desktop_config(config):
		return {"status": "error", "message": "Cannot write to %s" % _get_claude_desktop_config_path()}
	return {"status": "ok", "message": "Claude Desktop configured (via npx mcp-remote → %s) — restart Claude Desktop to load" % SERVER_HTTP_URL}


static func _check_claude_desktop() -> ConfigStatus:
	var config = _read_claude_desktop_config()
	if not (config is Dictionary):
		return ConfigStatus.NOT_CONFIGURED

	var servers = config.get("mcpServers", {})
	if not (servers is Dictionary):
		return ConfigStatus.NOT_CONFIGURED
	if not servers.has(SERVER_NAME):
		return ConfigStatus.NOT_CONFIGURED

	var entry = servers.get(SERVER_NAME)
	if not (entry is Dictionary):
		return ConfigStatus.NOT_CONFIGURED

	# Accept either: (a) the bridge form we write (command=npx, args include mcp-remote + SERVER_HTTP_URL),
	#                (b) a legacy/newer url-style entry pointing at our server.
	if entry.get("url", "") == SERVER_HTTP_URL:
		return ConfigStatus.CONFIGURED
	var args = entry.get("args", [])
	if entry.get("command", "") == "npx" and args is Array and args.has(SERVER_HTTP_URL):
		return ConfigStatus.CONFIGURED

	return ConfigStatus.NOT_CONFIGURED


static func _remove_claude_desktop() -> Dictionary:
	var config = _read_claude_desktop_config()
	if not (config is Dictionary):
		return {"status": "ok", "message": "Not configured"}

	var servers = config.get("mcpServers")
	if servers is Dictionary:
		servers.erase(SERVER_NAME)
		_write_claude_desktop_config(config)
	return {"status": "ok", "message": "Claude Desktop configuration removed"}


# --- Antigravity ---

static func _get_antigravity_config_path() -> String:
	return OS.get_environment("HOME").path_join(".gemini/antigravity/mcp_config.json")


static func _read_antigravity_config() -> Variant:
	return _read_json_config(_get_antigravity_config_path(), "Antigravity")


static func _write_antigravity_config(config: Dictionary) -> bool:
	return _write_json_config(_get_antigravity_config_path(), config)


static func _configure_antigravity() -> Dictionary:
	var config = _read_antigravity_config()
	if not (config is Dictionary):
		config = {"mcpServers": {}}
	if not config.has("mcpServers") or not (config["mcpServers"] is Dictionary):
		config["mcpServers"] = {}

	config["mcpServers"][SERVER_NAME] = {"serverUrl": SERVER_HTTP_URL, "disabled": false}

	if not _write_antigravity_config(config):
		return {"status": "error", "message": "Cannot write to %s" % _get_antigravity_config_path()}
	return {"status": "ok", "message": "Antigravity configured (HTTP: %s)" % SERVER_HTTP_URL}


static func _check_antigravity() -> ConfigStatus:
	var config = _read_antigravity_config()
	if not (config is Dictionary):
		return ConfigStatus.NOT_CONFIGURED

	var servers = config.get("mcpServers", {})
	if not (servers is Dictionary):
		return ConfigStatus.NOT_CONFIGURED
	if not servers.has(SERVER_NAME):
		return ConfigStatus.NOT_CONFIGURED

	var entry = servers.get(SERVER_NAME)
	if not (entry is Dictionary):
		return ConfigStatus.NOT_CONFIGURED
	if entry.get("serverUrl", "") != SERVER_HTTP_URL:
		return ConfigStatus.NOT_CONFIGURED

	return ConfigStatus.CONFIGURED


static func _remove_antigravity() -> Dictionary:
	var config = _read_antigravity_config()
	if not (config is Dictionary):
		return {"status": "ok", "message": "Not configured"}

	var servers = config.get("mcpServers")
	if servers is Dictionary:
		servers.erase(SERVER_NAME)
		_write_antigravity_config(config)
	return {"status": "ok", "message": "Antigravity configuration removed"}
