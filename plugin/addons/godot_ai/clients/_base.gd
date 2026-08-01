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
## client config, but its URL or launch command doesn't match the current
## ports/version/exclusions — typical after a setting change or update.
## Distinguishing this from `NOT_CONFIGURED` lets the dock surface a "your
## saved client configuration is stale" banner instead of conflating it with
## "you never configured this client".
enum Status { NOT_CONFIGURED, CONFIGURED, CONFIGURED_MISMATCH, ERROR }


## Lowercase string label for a `Status` value. Single source of truth so the
## MCP `client_status` tool, the dock, and the verify-after-write diagnostic
## in `McpClientConfigurator` all emit the same names — agents pattern-match
## against this set, so a fifth value being silently introduced would break
## them.
static func status_label(status: McpClient.Status) -> String:
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
var config_type: String = ""                     ## "json" | "toml" | "yaml" | "cli"

# JSON / TOML clients ------------------------------------------------------
## {"darwin": "~/...", "windows": "$APPDATA/...", "linux": "$XDG_CONFIG_HOME/..."}
## Keys may also use "unix" as a shorthand for darwin+linux.
var path_template: Dictionary = {}

## Optional ordered path candidates by platform. Each value is an Array of
## templates; one `*` may appear in a directory segment so packaged-app roots
## can be discovered without hardcoding publisher hashes.
##
## Resolution contract:
##   1. Existing files win in descriptor order, except that a unique wildcard
##      match is authoritative even before its config leaf exists. A matching
##      package root therefore creates inside that package rather than writing
##      a fallback path that may become invisible after copy-on-write. When
##      that private leaf is new, Configure seeds it from the first later
##      existing candidate so read-through content is not shadowed.
##   2. If no file or wildcard package match exists, the first non-wildcard
##      template is the deterministic create target.
##   3. Multiple matches within any wildcard group are ambiguous and fail
##      closed instead of choosing an arbitrary package.
##
## `config_home_override` still has higher priority. When this map has no entry
## for the current platform, `path_template` remains the fallback.
var config_path_candidates: Dictionary = {}

## De-duplicate persistent path-ambiguity warnings across recurring status
## refreshes. The actionable message still returns on every resolution; only
## the editor-console echo is single-shot until the ambiguity clears/changes.
var _last_config_path_warning := ""
var _config_path_warning_mutex := Mutex.new()

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

## Client-owned stdio launch shape.
##
## COMMAND_ARRAY is consumed by the TOML strategy and FLAT by the JSON
## strategy. The remaining values are shared vocabulary for later JSON, YAML,
## and CLI migrations; keeping them data-only avoids reintroducing the
## descriptor Callable race from #229.
enum CommandShape { NONE, FLAT, TYPED_FLAT, COMMAND_ARRAY, NESTED_COMMAND }
var command_shape: CommandShape = CommandShape.NONE

## Whether manual instructions may offer the client's native URL transport as
## an alternative to its command shape. This is capability metadata, not a
## consequence of `command_shape`: Codex supports a URL block, while Claude
## Desktop's local `claude_desktop_config.json` entries are stdio-only.
var command_supports_url_fallback: bool = false

## Optional discriminator required by a client's command transport shape
## (for example `type = "stdio"`). Empty means command+args are sufficient.
var command_transport_key: String = ""
var command_transport_value: Variant = null

## Keys from the legacy transport that Configure must delete. Codex removes
## `url`, because Codex rejects a server entry containing both URL and stdio
## launch fields.
var command_legacy_keys: PackedStringArray = PackedStringArray()

## Keys inside a preserved JSON `env` object that belonged to a legacy launch
## shape and must be removed during migration. Other environment values remain
## user-owned and survive Configure. Currently consumed by the JSON strategy.
var command_env_legacy_keys: PackedStringArray = PackedStringArray()

## Defaults seeded only for a new entry. Reconfigure preserves user values.
## Codex uses this for enabled/startup/tool timeout defaults.
var command_initial_fields: Dictionary = {}

## Declarative documentation of fields owned by the user and timeout fields
## supported by this client. Strategies preserve these values and tests pin
## the descriptor contract; no control flow lives on the descriptor.
var command_user_fields: PackedStringArray = PackedStringArray()
var command_timeout_fields: PackedStringArray = PackedStringArray()

## Paths whose existence implies the user has this client installed.
## Used purely for the dock's "installed" badge. `is_installed()` additionally
## checks `resolved_config_path()`, so a config relocated via
## `config_home_env` is detected without listing it here.
var detect_paths: PackedStringArray = PackedStringArray()

# Config-home env override ---------------------------------------------------
## Some clients honor an env var that relocates their entire config home
## (Codex: `$CODEX_HOME/config.toml`; Claude Code: `$CLAUDE_CONFIG_DIR/.claude.json`).
## When `config_home_env` names an env var that is set and non-empty,
## `resolved_config_path()` returns `<env value>/<config_home_env_subpath>`
## instead of resolving `path_template`. Both fields must be non-empty for the
## override to apply. Only declare a mapping when the client's docs guarantee
## the env var relocates the exact file we write — a wrong mapping writes the
## MCP entry somewhere the client never reads and Configure false-succeeds.
var config_home_env: String = ""
## Path of the config file relative to the env var's directory, e.g.
## "config.toml". Joined verbatim — no per-OS variants needed because the env
## value itself is already an absolute (or ~-prefixed) directory.
var config_home_env_subpath: String = ""

# CLI clients --------------------------------------------------------------
var cli_names: PackedStringArray = PackedStringArray()
## Argument templates with `{name}` and `{url}` tokens; the strategy
## substitutes them at call time. Tokens are matched verbatim — no escaping
## semantics, no shell expansion. Populated by CLI descriptors (`claude_code`, `kimi_code`).
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
## A set, non-empty `config_home_env` env var overrides `path_template`
## (issue #617: e.g. CODEX_HOME relocates ~/.codex — writing the default
## path would false-succeed while Codex reads elsewhere).
func resolved_config_path() -> String:
	return str(resolved_config_path_details().get("path", ""))


## Detailed sibling used by status/configure/remove so safe resolution
## failures reach the dock instead of collapsing into NOT_CONFIGURED. `error`
## is empty for ordinary unsupported/missing path mappings to preserve the
## long-standing status behavior for clients not installed on this platform.
func resolved_config_path_details() -> Dictionary:
	var override := config_home_override()
	if not override.is_empty():
		_clear_config_path_warning()
		return {"path": override, "error": ""}
	var candidate_key := McpPathTemplate.platform_key(config_path_candidates)
	if not candidate_key.is_empty():
		return _resolve_ordered_config_path_candidates(config_path_candidates[candidate_key])
	_clear_config_path_warning()
	return {"path": McpPathTemplate.resolve(path_template), "error": ""}


func _resolve_ordered_config_path_candidates(templates: Variant) -> Dictionary:
	if not (templates is Array or templates is PackedStringArray):
		_clear_config_path_warning()
		return {"path": "", "error": ""}
	var ordered_templates: Array = []
	for template_variant in templates:
		ordered_templates.append(str(template_variant))
	var fallback_create_path := ""
	for index in range(ordered_templates.size()):
		var template := str(ordered_templates[index])
		var group := McpPathTemplate.expand_path_candidates(template)
		if group.size() > 1:
			var message := (
				"%s has multiple matching config package paths for %s: %s. "
				+ "Remove the stale package installation or edit the intended config manually."
			) % [display_name, template, ", ".join(group)]
			_warn_config_path_once(message)
			return {"path": "", "error": message}
		if group.is_empty():
			continue
		var path := String(group[0])
		if FileAccess.file_exists(path):
			_clear_config_path_warning()
			return {"path": path, "error": ""}
		# A wildcard only resolves when its package directory exists. Treat that
		# installation evidence as authoritative and create its private config
		# directly instead of relying on copy-on-write read-through. Preserve
		# anything currently visible through read-through by naming the first
		# later existing candidate as a one-time seed source.
		if template.contains("*"):
			var seed_path := _first_existing_later_candidate(ordered_templates, index + 1)
			_clear_config_path_warning()
			return {"path": path, "error": "", "seed_path": seed_path}
		if fallback_create_path.is_empty():
			fallback_create_path = path
	_clear_config_path_warning()
	return {"path": fallback_create_path, "error": ""}


func _first_existing_later_candidate(templates: Array, start_index: int) -> String:
	for index in range(start_index, templates.size()):
		var group := McpPathTemplate.expand_path_candidates(str(templates[index]))
		# A seed is optional. Never choose among an ambiguous later wildcard;
		# the authoritative target was already resolved by the earlier group.
		if group.size() != 1:
			continue
		var path := String(group[0])
		if FileAccess.file_exists(path):
			return path
	return ""


func _warn_config_path_once(message: String) -> void:
	_config_path_warning_mutex.lock()
	var should_warn := message != _last_config_path_warning
	_last_config_path_warning = message
	_config_path_warning_mutex.unlock()
	if should_warn:
		push_warning(message)


func _clear_config_path_warning() -> void:
	_config_path_warning_mutex.lock()
	_last_config_path_warning = ""
	_config_path_warning_mutex.unlock()


## The env-var-relocated config path, or "" when no override applies
## (no mapping declared, env var unset, or env var empty/whitespace).
func config_home_override() -> String:
	if config_home_env.is_empty() or config_home_env_subpath.is_empty():
		return ""
	## env_lookup, not OS.get_environment: this runs on dock worker threads,
	## which must not race the spawn window's setenv/unsetenv (#691).
	var home := McpPathTemplate.env_lookup(config_home_env).strip_edges()
	if home.is_empty():
		return ""
	# Expand a leading ~ so `CODEX_HOME=~/codex-alt` behaves like the shell.
	return McpPathTemplate.expand(home).path_join(config_home_env_subpath)


## True when a CLI client also declares where its config file lives, so it can
## fall back to writing that file directly when the CLI binary isn't on PATH.
## #463: Claude Code installed only as a VS Code / Cursor extension exposes no
## `claude` binary, but `claude mcp add --scope user` just writes `mcpServers`
## into ~/.claude.json — so we can produce the same entry ourselves.
func has_json_fallback() -> bool:
	return config_type == "cli" and not path_template.is_empty() and not server_key_path.is_empty()


## True if the user appears to have this client installed locally.
func is_installed() -> bool:
	if config_type == "cli":
		if not McpCliFinder.find(_array_from_packed(cli_names)).is_empty():
			return true
		# CLI not on PATH. A cli client with a JSON fallback (Claude Code as a
		# VS Code/Cursor extension, #463) still counts as installed if its
		# fallback config file already exists.
		if has_json_fallback():
			var cfg := resolved_config_path()
			return not cfg.is_empty() and FileAccess.file_exists(cfg)
		return false
	for p in detect_paths:
		for resolved in McpPathTemplate.expand_path_candidates(p):
			if FileAccess.file_exists(resolved) or DirAccess.dir_exists_absolute(resolved):
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
