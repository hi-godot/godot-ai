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


## One-line configure success message, shared by every strategy so the dock
## and the `client_manage` tool describe the transport that was actually
## written. Command-shape clients register the stdio `godot-ai attach`
## bridge — the URL-era "(HTTP: <url>)" suffix would name a transport the
## write never touched (found live in the #838 Windows smoke).
static func configured_message(client: McpClient, server_url: String) -> String:
	if client.command_shape != CommandShape.NONE:
		return "%s configured (stdio attach)" % client.display_name
	return "%s configured (HTTP: %s)" % [client.display_name, server_url]

var id: String = ""                              ## stable key, e.g. "cursor"
var display_name: String = ""                    ## "Cursor"
var config_type: String = ""                     ## "json" | "toml" | "yaml" | "cli" | "dsh"

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
## Exact-file and config-home environment overrides still have higher
## priority. When this map has no entry for the current platform,
## `path_template` remains the fallback.
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

## Client-owned stdio launch shape. Each strategy renders the shape in its
## config language:
##
## - FLAT — `command` string + `args` array as sibling keys. JSON and YAML
##   strategies. A client whose docs require a type discriminator next to the
##   flat keys (VS Code's `type: "stdio"`, Claude Code's fallback file) stays
##   FLAT and declares it via `command_transport_key` / `command_transport_value`,
##   so TYPED_FLAT remains reserved vocabulary.
## - COMMAND_ARRAY — the launch argv carried as one array. In the JSON
##   strategy the entry's `command` field IS that array (OpenCode's
##   `"command": ["uvx", …]`). In the TOML strategy the launcher renders as a
##   `command = "…"` line plus an `args = […]` array (Codex, Grok) — the name
##   refers to the argv-as-TOML-array body it emits.
## - NESTED_COMMAND — command/args nested inside a sub-object. Reserved; no
##   current client needs it and strategies reject it with an actionable error.
##
## CLI-registered clients (`config_type == "cli"`) express the launch through
## `cli_register_template` tokens instead; their `command_shape` governs the
## JSON-fallback file rendering (Claude Code, #463).
##
## Values are data-only shared vocabulary; keeping them data-only avoids
## reintroducing the descriptor Callable race from #229.
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

## Whether this client's Windows stdio entry must launch through the
## GUI-subsystem pythonw bootstrap (#827). The bootstrap exists for clients
## that run console-subsystem MCP commands in a visible terminal (Codex);
## Electron-family spawners hide child consoles themselves, and at least one
## (Antigravity) hangs tool calls when handed a GUI-subsystem executable
## (#863). Set false to write the plain console launcher on Windows.
var needs_consoleless_launcher: bool = true

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
## checks `resolved_config_path()`, so a config relocated via an environment
## override is detected without listing it here.
var detect_paths: PackedStringArray = PackedStringArray()

# Config-path env overrides --------------------------------------------------
## Some clients name the exact config file in an environment variable
## (OpenCode: `$OPENCODE_CONFIG`). When the variable is set and non-empty, it
## wins over directory-valued `config_home_env` and `path_template`. Relative
## values fail closed because the editor and client may have different working
## directories; auto-configuration cannot safely assume they resolve alike.
var config_file_env: String = ""

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
## semantics, no shell expansion. Command-shape templates additionally use the
## whole-element tokens `{command}` / `{args...}` (see `McpCliStrategy.format_args`).
## Populated by CLI descriptors (currently `claude_code`; `kimi_code` moved to
## mcp.json in #813).
var cli_register_template: PackedStringArray = PackedStringArray()
var cli_unregister_template: PackedStringArray = PackedStringArray()
## Args run to read current state; stdout is scanned for the server name and
## URL. Presence of `name` AND `url` → CONFIGURED, name only → MISMATCH,
## neither → NOT_CONFIGURED.
var cli_status_args: PackedStringArray = PackedStringArray()
## Optional scope-aware status template with a `{name}` token, for descriptors
## that also take `{scope}` in their register template. `cli_status_args` lists
## whatever the CLI resolves for the current directory and cannot say WHICH
## scope an entry came from, so a leftover user-scope entry reads as CONFIGURED
## while the selected project scope is empty — the dock then shows green over
## exactly the "loaded in every workspace" state the scope setting exists to
## end (#872). This template must print a `Scope: <user|project|local> …` line
## (`claude mcp get <name>` does) and exit non-zero when the server is absent.
## Only consulted when the selected scope isn't the one `path_template` reads.
var cli_scope_status_template: PackedStringArray = PackedStringArray()

# Codex / TOML clients -----------------------------------------------------
## Dotted TOML path under which our entry lives, e.g. ["mcp_servers", "godot-ai"].
## Strategies build the [section."name"] header from this.
var toml_section_path: PackedStringArray = PackedStringArray()
var toml_legacy_section_aliases: PackedStringArray = PackedStringArray()
## Lines (without the [header]) emitted under the section, with `{url}`
## tokens. Substituted at call time.
var toml_body_template: PackedStringArray = PackedStringArray()


## Resolved absolute config path for this client on the current OS. Exact-file
## overrides win first, followed by directory-valued `config_home_env`, then
## ordered candidates / `path_template`. Ignoring either override can write a
## file the client never reads and false-succeed.
func resolved_config_path() -> String:
	return str(resolved_config_path_details().get("path", ""))


## Detailed sibling used by status/configure/remove so safe resolution
## failures reach the dock instead of collapsing into NOT_CONFIGURED. `error`
## is empty for ordinary unsupported/missing path mappings to preserve the
## long-standing status behavior for clients not installed on this platform.
func resolved_config_path_details() -> Dictionary:
	## Reflected reads: after an in-session self-update, an instance created
	## before the update can answer Nil for vars the update added, and the
	## typed calls below would each hard-error (Nil -> Dictionary, #850's
	## per-row error wall). Fail with the
	## one repair message instead; the registry's coherence probe drives the
	## same text on the status path.
	var candidates: Variant = get("config_path_candidates")
	var template: Variant = get("path_template")
	var file_env: Variant = get("config_file_env")
	if not (candidates is Dictionary) or not (template is Dictionary) or not (file_env is String):
		return {"path": "", "error": McpClientRegistry.RESTART_TO_FINISH_UPDATE}
	var file_override := config_file_override_details()
	if not str(file_override.get("path", "")).is_empty() or not str(file_override.get("error", "")).is_empty():
		_clear_config_path_warning()
		return file_override
	var override := config_home_override()
	if not override.is_empty():
		_clear_config_path_warning()
		return {"path": override, "error": ""}
	var candidate_key := McpPathTemplate.platform_key(candidates)
	if not candidate_key.is_empty():
		return _resolve_ordered_config_path_candidates(candidates[candidate_key])
	_clear_config_path_warning()
	return {"path": McpPathTemplate.resolve(template), "error": ""}


## The exact-file env override plus any fail-closed diagnostic. Empty path and
## error means no override applies (no mapping, unset, or blank env var).
func config_file_override_details() -> Dictionary:
	if config_file_env.is_empty():
		return {"path": "", "error": ""}
	## env_lookup, not OS.get_environment: this can run on dock workers (#691).
	var raw_path := McpPathTemplate.env_lookup(config_file_env).strip_edges()
	if raw_path.is_empty():
		return {"path": "", "error": ""}
	var expanded := McpPathTemplate.expand(raw_path)
	if not expanded.is_absolute_path():
		return {
			"path": "",
			"error": "%s's $%s override must be an absolute config-file path; got %s" % [
				display_name, config_file_env, raw_path,
			],
		}
	if DirAccess.dir_exists_absolute(expanded):
		return {
			"path": "",
			"error": "%s's $%s override must point to a config file, not a directory: %s" % [
				display_name, config_file_env, expanded,
			],
		}
	return {"path": expanded, "error": ""}


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
