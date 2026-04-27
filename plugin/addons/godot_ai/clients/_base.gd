@tool
class_name McpClient
extends RefCounted

## Descriptor for one MCP client (Cursor, Claude Desktop, Codex, ...).
##
## Subclasses set fields in `_init()` and MUST NOT carry Callables — strategies
## (json/toml/cli) interpret the data. Enforced by
## `test_clients.gd::test_descriptors_are_data_only`.
##
## Why no Callables: per-client `.gd` files get hot-reloaded on disk-mtime
## change. A worker thread mid-call into a descriptor lambda races the
## bytecode swap and SEGVs (issue #229). Bonus: also obsoletes the stale-
## Callable workaround from #192.

## CONFIGURED_MISMATCH = an entry with our `SERVER_NAME` exists in the user's
## client config, but its URL doesn't match `http_url()` — typical after the
## user changes `godot_ai/http_port` and reloads. Distinguishing this from
## `NOT_CONFIGURED` lets the dock surface a "your saved client URLs are stale"
## banner instead of conflating it with "you never configured this client".
enum Status { NOT_CONFIGURED, CONFIGURED, CONFIGURED_MISMATCH, ERROR }


## Lowercase string label for a `Status` value. Single source of truth so the
## MCP `client_status` tool, the dock, and the verify-after-write diagnostic
## in `McpClientConfigurator` all emit the same names — agents pattern-match
## against this set, so a fifth value being silently introduced would break
## them.
static func status_label(status: Status) -> String:
	match status:
		Status.CONFIGURED:
			return "configured"
		Status.NOT_CONFIGURED:
			return "not_configured"
		Status.CONFIGURED_MISMATCH:
			return "configured_mismatch"
	return "error"

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

## Field inside the entry dict that holds our server URL.
## "url" by default; some clients use "serverUrl" or "httpUrl".
var entry_url_field: String = "url"

## Required entry fields — written on every Configure AND verified by the
## default verifier. Use this for transport pins (e.g. `type:
## "streamable-http"`) where a missing/wrong value breaks negotiation: a
## legacy entry without the pin fails verification and surfaces as drift.
##
## DO NOT put user-mutable state here (auto-approval lists, `disabled`
## flags, opt-in toggles). Verifying those treats every user customisation
## as drift, and Configure-All-Mismatched then silently overwrites them
## back to defaults — see the `entry_initial_fields` doc below.
var entry_extra_fields: Dictionary = {}

## Default fields written ONLY when the entry doesn't yet exist. Reconfigure
## preserves whatever the user (or the client itself) has set; the verifier
## ignores these keys entirely. Use for opt-in flags and user-state arrays —
## e.g. Roo / Cline / Kilo `alwaysAllow` / `autoApprove` lists, `disabled:
## false`, `isActive: true`. The pre-#229 behaviour was equivalent: per-
## client `entry_builder` lambdas seeded these as defaults but the
## per-client `verify_entry` lambdas only checked transport pins, so a
## user-customised array was `CONFIGURED`, not drift. Splitting the field
## restores that contract under the data-only descriptor model.
var entry_initial_fields: Dictionary = {}

## stdio→HTTP bridge mode for clients that don't speak HTTP natively.
##   NONE    — entry is `{[entry_url_field]: url, **entry_extra_fields,
##             ...entry_initial_fields (only for new entries)}`
##   FLAT    — Claude Desktop shape: `{"command": <uvx>, "args": [...bridge...]}`
##             Verifier ALSO accepts a future url-style entry.
##   NESTED  — Zed shape: `{"command": {"path": <uvx>, "args": [...]}, "settings": {}}`
##             Verifier requires the bridge form (no url-style fallback).
##
## Enum (vs. String) so a typo in a descriptor fails at parse time instead of
## silently falling through `match` to the non-bridge path.
enum UvxBridge { NONE, FLAT, NESTED }
var entry_uvx_bridge: UvxBridge = UvxBridge.NONE

## Paths whose existence implies the user has this client installed.
## Used purely for the dock's "installed" badge.
var detect_paths: PackedStringArray = PackedStringArray()

# CLI clients --------------------------------------------------------------
var cli_names: PackedStringArray = PackedStringArray()
## Argument templates with `{name}` and `{url}` tokens; the strategy
## substitutes them at call time. Tokens are matched verbatim — no escaping
## semantics, no shell expansion. Today only `claude_code` populates these.
var cli_register_template: PackedStringArray = PackedStringArray()
var cli_unregister_template: PackedStringArray = PackedStringArray()
## Args run to read current state; stdout is scanned for the server name and
## URL. Presence of `name` AND `url` → CONFIGURED, name only → MISMATCH,
## neither → NOT_CONFIGURED.
var cli_status_args: PackedStringArray = PackedStringArray()

# Codex / TOML clients -----------------------------------------------------
## Dotted TOML path under which our entry lives, e.g. ["mcp_servers", "godot-ai"].
## Strategies build the [section."name"] header from this.
var toml_section_path: PackedStringArray = PackedStringArray()
var toml_legacy_section_aliases: PackedStringArray = PackedStringArray()
## Lines (without the [header]) emitted under the section, with `{url}`
## tokens. Substituted at call time.
var toml_body_template: PackedStringArray = PackedStringArray()


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


## Slice a PackedStringArray into a new PackedStringArray over [from, to).
## Used by `_toml_strategy` and `_manual_command` to peel the section path
## apart for `[a.b."c"]` header rendering.
static func _packed_slice(packed: PackedStringArray, from: int, to: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(from, to):
		out.append(packed[i])
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
