@tool
class_name McpClient
extends RefCounted

## Descriptor for one MCP client (Cursor, Claude Desktop, Codex, ...).
## Subclasses set fields in _init(); they should not contain control flow.
## Strategies (json/toml/cli) consume these fields.

## CONFIGURED_MISMATCH = an entry with our `SERVER_NAME` exists in the user's
## client config, but its URL doesn't match `http_url()` — typical after the
## user changes `godot_ai/http_port` and reloads. Distinguishing this from
## `NOT_CONFIGURED` lets the dock surface a "your saved client URLs are stale"
## banner instead of conflating it with "you never configured this client".
enum Status { NOT_CONFIGURED, CONFIGURED, CONFIGURED_MISMATCH, ERROR }

var id: String = ""                              ## stable key, e.g. "cursor"
var display_name: String = ""                    ## "Cursor"
var config_type: String = ""                     ## "json" | "toml" | "cli"
var doc_url: String = ""

# JSON / TOML clients ------------------------------------------------------
## {"darwin": "~/...", "windows": "$APPDATA/...", "linux": "$XDG_CONFIG_HOME/..."}
## Keys may also use "unix" as a shorthand for darwin+linux.
var path_template: Dictionary = {}

## Path inside the config object where the per-server map lives.
## Cursor / Claude Desktop / most others: ["mcpServers"]
## VS Code:                                ["servers"]
## OpenCode:                               ["mcp"]
var server_key_path: PackedStringArray = PackedStringArray()

## func(server_name: String, server_url: String) -> Dictionary
## Returns the JSON object stored under server_key_path[server_name].
var entry_builder: Callable = Callable()

## Optional: custom verifier. func(entry: Dictionary, server_url: String) -> bool
## Defaults: a JSON entry passes if entry[entry_url_field] == server_url.
var entry_url_field: String = "url"
var verify_entry: Callable = Callable()

## Paths whose existence implies the user has this client installed.
## Used purely for the dock's "installed" badge.
var detect_paths: PackedStringArray = PackedStringArray()

# CLI clients --------------------------------------------------------------
var cli_names: PackedStringArray = PackedStringArray()
var cli_register_args: Callable = Callable()
var cli_unregister_args: Callable = Callable()
var cli_status_check: Callable = Callable()  ## func(cli_path, name, url) -> Status

# Codex / TOML clients -----------------------------------------------------
## Dotted TOML path under which our entry lives, e.g. ["mcp_servers", "godot-ai"].
## Strategies build the [section."name"] header from this.
var toml_section_path: PackedStringArray = PackedStringArray()
var toml_legacy_section_aliases: PackedStringArray = PackedStringArray()
## Lines (without the [header]) emitted under the section.
## func(server_url) -> PackedStringArray
var toml_body_builder: Callable = Callable()

# Manual fallback ----------------------------------------------------------
## func(server_name, server_url, resolved_path) -> String
var manual_command_builder: Callable = Callable()


## Resolved absolute config path for this client on the current OS.
func resolved_config_path() -> String:
	return McpPathTemplate.resolve(path_template)


## True if the user appears to have this client installed locally.
func is_installed() -> bool:
	if config_type == "cli":
		return not McpCliFinder.find(_array_from_packed(cli_names)).is_empty()
	for p in detect_paths:
		var resolved := McpPathTemplate.expand(p)
		if not resolved.is_empty() and (FileAccess.file_exists(resolved) or DirAccess.dir_exists_absolute(resolved)):
			return true
	# Fall back to "config file already exists" — usually means installed at some point.
	var cfg := resolved_config_path()
	return not cfg.is_empty() and FileAccess.file_exists(cfg)


static func _array_from_packed(packed: PackedStringArray) -> Array[String]:
	var out: Array[String] = []
	for s in packed:
		out.append(s)
	return out


# ----- stdio→http bridge helpers (Claude Desktop, Zed) --------------------

## Pinned mcp-proxy release used by every stdio-only client's bridge. uvx's
## cache key is version-specific, so pinning guarantees all users run the
## same vetted bridge — a malicious or broken future release on PyPI can't
## silently break everyone's Configure flow. Bump deliberately when the
## upstream publishes something we want.
const MCP_PROXY_VERSION := "0.11.0"


## Resolve `uvx` to an absolute path. GUI-launched apps (Claude Desktop,
## Zed) often run with a minimal PATH that excludes ~/.local/bin on macOS /
## Linux, so a bare "uvx" string in the config would fail at spawn time
## with the same "Server disconnected" symptom we're trying to cure. The
## shared three-tier McpCliFinder covers the well-known install dirs;
## returns bare "uvx" as a last-resort fallback so the entry is still
## well-formed even if the lookup failed.
static func resolve_uvx_path() -> String:
	var names: Array[String] = []
	names.append("uvx.exe" if OS.get_name() == "Windows" else "uvx")
	var resolved := McpCliFinder.find(names)
	return resolved if not resolved.is_empty() else "uvx"


## Build the `mcp-proxy` bridge argv (without the leading uvx command).
## Callers splice this into the client-specific command shape.
static func mcp_proxy_bridge_args(url: String) -> Array:
	return ["mcp-proxy==" + MCP_PROXY_VERSION, "--transport", "streamablehttp", url]
