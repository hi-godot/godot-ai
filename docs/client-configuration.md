# Client configuration

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


The registry + strategy system that auto-configures MCP clients.

## Client configuration

The plugin auto-configures every registered MCP client via a registry + strategy
system in `plugin/addons/godot_ai/clients/` —
`_registry.gd::_CLIENT_SCRIPT_PATHS` is the authoritative list. Read that directory for the mechanics; two
rules are not visible in the code:

- **Descriptors are data only** — no `Callable` fields, no control flow. Strategies
  interpret the data. `test_descriptors_are_data_only` enforces this (issue #229:
  hot-reloaded per-client lambdas raced with worker threads).
- **No per-client branching inside strategies.** Non-standard entry shapes are
  expressed declaratively on the descriptor (`entry_url_field`, `entry_extra_fields`,
  `command_shape`, `command_initial_fields`, `command_legacy_keys`,
  `command_supports_url_fallback`, `config_path_candidates`). Adding a client
  with a shape one of the existing strategies already writes means exactly two
  things: write `clients/<name>.gd` extending `McpClient`, then append its
  script path to `_CLIENT_SCRIPT_PATHS` in `_registry.gd`. No edits to the
  dock, the facade, or the strategies. A client whose config language is a
  genuinely new shape gets a small dedicated strategy instead (DeepSeek
  Harness' loader `insert` list is the current example: `_dsh_strategy.gd`,
  dispatched on `config_type "dsh"`), plus the matching branch in
  `client_configurator.gd` and `_manual_command.gd`.

MCP tools `client_configure`, `client_remove`, and `client_status` expose this to
AI clients.

Client-owned attach entries carry a launch command rather than only an HTTP
URL. As of #838 every registered client is command-shape except
`cherry_studio` (its `mcp_servers.json` path is not read by the app at all —
servers live in an internal database — so a file-based migration would be a
no-op; it stays URL-mode pending a deep-link design). The dock captures
ports, canonical excluded domains, plugin version, dev/user mode, and the
telemetry preference on the main thread, then workers resolve the same three
launch tiers used by server startup (dev venv → exact-version uvx → matching
system install). A disabled telemetry preference renders as
`--disable-telemetry` on the attach argv — the env-injection path that covers
plugin-spawned servers never runs for a client-spawned bridge or its backend
(see docs/TELEMETRY.md). Package pins, command paths, ports, exclusions,
telemetry, and required uv options are verified as launch drift;
**Configure all** is the repair path after a self-update, port change,
telemetry toggle, or tool-domain change. Never silently fall back to a bare `uvx`
command for these entries—report ERROR and leave the config untouched when no
verified tier exists.

Per-strategy command rendering (`CommandShape` docs in `_base.gd`):

- **JSON** — FLAT (`command` string + `args` array, optional
  `command_transport_key` pin: VS Code's `type: "stdio"`, Claude Code's
  fallback file) and COMMAND_ARRAY (OpenCode: the `command` field IS the argv
  array, pinned `type: "local"`, env under `environment`).
- **TOML** — COMMAND_ARRAY renders `command = "…"` + `args = […]` lines
  (Codex, Grok).
- **YAML** — FLAT with flow-style `args` (Hermes); `url`/`headers` are the
  legacy keys there because Hermes infers transport from key presence.
- **JSON, typeless** — Antigravity, Pi Agent: FLAT `command`/`args`/`env`
  with no `type` discriminator; transport is inferred from key presence
  (`command` vs `url`), so `url`, `headers`, and any leftover `type` key
  from a previous http-era entry join `command_legacy_keys` and are
  scrubbed on reconfigure.
  Pi also accepts top-level `mcpServers`, `mcp-servers`, and `servers` maps;
  Configure and manual instructions reuse the first existing map in that
  precedence order so they do not shadow and deactivate legacy entries. Pi
  merges `~/.pi/agent/mcp.json`, `~/.pi/agent/.mcp.json`, then project-level
  `.pi/mcp.json` and `.mcp.json`. Configure updates the effective highest global
  definition, status verifies it, and Remove clears all global definitions with
  rollback on partial failure. Because project tiers are relative to Pi's own
  working directory, the dock identifies plausible overrides but fails closed
  with the exact path instead of mutating an inferred project root.

- **DSH** — DeepSeek Harness (dsh) has no `mcp` CLI verb. MCP servers register
  as `@deepseek-ai/dsh-mcp-client` plugin entries in the HOME patch layer
  `$DSH_HOME/cordis.patch.yml` (applies over every profile, web GUI included).
  New servers must be added as `insert` rows — a plain `- id:` row only
  overrides an existing bundle id and is skipped with a warning (verified
  live against dsh 0.1.0-rc.6 via `dsh --profile web --dump-config`). The
  strategy writes one dedicated insert row and preserves every other row
  byte-for-byte (other insert rows, overrides, comments, `!!js` expressions).
  The entry's launch nests under `config`
  (`serverName`/`transport`/`command`/`args`); `serverName` is the
  model-facing tool namespace. dsh's patch parser rejects a non-array file at
  boot, so Remove deletes an all-blank patch file instead of writing it back.
- **CLI** — `cli_register_template` uses the whole-element tokens
  `{command}` / `{args...}`, plus the optional `{scope}` token resolved from
  the `godot_ai/mcp_client_scope` EditorSetting (Claude Code:
  `mcp add --scope {scope} {name} -- {command} {args...}`; `{scope}` is one of
  `user` / `project` / `local`, defaulting to `user`). Status for command-shape
  CLI clients reads the JSON fallback file the CLI itself writes — exact drift
  detection that `mcp list` stdout scanning cannot give — but **only while the
  selected scope is the one `path_template` points at**. `project` and `local`
  land outside that file, so status falls through to a CLI probe, which
  inherits the same cwd the register ran in and therefore agrees with it by
  construction (#872). Trading exact drift detection for a correct status dot
  is deliberate: `_verify_post_state` re-reads status after every Configure, so
  a file read that can't see the entry would report every successful
  project-scope Configure as a failure.

  That probe is `cli_scope_status_template`, **not** `cli_status_args`.
  `mcp list` prints whatever resolved for the current directory without saying
  which scope won, so a leftover user-scope entry carrying our exact command
  reads as CONFIGURED while the selected project scope is empty — a green dot
  over precisely the "loaded in every workspace" state the setting exists to
  end. `mcp get <name>` returns the command *and* a `Scope:` line in the same
  single subprocess (adding a second spawn per status check would be
  unacceptable — see #238 / #239), so an entry resolved from another scope is
  reported as MISMATCH and the dock's Reconfigure moves it. Verified against
  claude 2.1.241, which prints `Scope: User config (…)` /
  `Scope: Project config (…)` / `Scope: Local config (…)` and exits non-zero
  when the entry is absent. The parser matches the first word after `Scope:`
  and degrades to the command check if a future release drops the line.

Per-client sharp edges (each is descriptor data, cited in the descriptor):
Kilo Code stdio entries must stay TYPELESS (`type` is a legacy key — its v7
migrator drops http-typed command entries); Zed's untagged entry enum makes
removing `url`/`headers`/`oauth` load-bearing; VS Code's stdio schema is
`additionalProperties: false`; gemini-cli/qwen configs are one-of
`command`|`url`|`httpUrl`, so both URL keys are legacy; kimi_code also
removes its legacy `transport` key and honors `$KIMI_CODE_HOME`; DeepSeek
Harness writes the loader `insert` row into `$DSH_HOME/cordis.patch.yml`
(the home patch layer, not a per-profile file), requires `transport` next to
command fields, rejects `url` next to them, and honors `$DSH_HOME` for the
whole home root.

Command migrations deep-copy existing JSON entries before replacing pinned
launch fields. `command_user_fields` documents known client-owned settings but
is not a preservation whitelist: unknown future fields survive too.
`command_legacy_keys` removes conflicting top-level transport fields, while
`command_env_legacy_keys` removes only named legacy values inside `env` and
preserves every other user environment variable.

Manual URL fallback is an explicit client capability, not an implication of a
command shape. Set `command_supports_url_fallback = true` only when the client
accepts that URL form in the same native config file. Codex does; Claude
Desktop's local `claude_desktop_config.json` entries do not.

Packaged applications may expose a different effective config file to the app
than an unpackaged editor sees at the conventional path. Descriptors express
that through ordered, platform-specific `config_path_candidates`; candidates
remain plain data and may use one wildcard in a directory segment. Existing
files win in descriptor order, but a unique wildcard package match is
authoritative even before its config leaf exists. This creates a packaged
app's private config directly instead of relying on copy-on-write read-through
from a fallback path. When that private leaf is absent, the first later
existing candidate is a read-only seed: Configure starts from its complete
contents, merges the new entry, and writes only the authoritative private
target. If no wildcard package matches and no file exists, the first
non-wildcard candidate is the deterministic create target. Ambiguous wildcard
groups return a structured resolution error that status, Configure, Remove,
and manual instructions surface to the user. Claude Desktop uses this on
Windows to select its MSIX `LocalCache/Roaming` config without hardcoding the
Store publisher hash. With no Store package it uses normal roaming; the dock
never writes divergent copies.

Use wildcard `detect_paths` alongside packaged config candidates so a fresh
installation still receives an installed badge before it creates a config.
Configure, status, remove, manual instructions, and post-write verification all
call `resolved_config_path()`, so they operate on the same effective file.

Launch resolution intentionally fails **closed**: Configure returns ERROR and
leaves the config untouched if no valid launch tier exists on any platform, or
if `_finalize_attach_launch()` cannot resolve a consoleless interpreter on
Windows. The Windows result also carries the unwrapped console shape
(`console_command`/`console_args`); `launch_for_client()` swaps it in for
descriptors that set `needs_consoleless_launcher = false` — clients whose
spawner cannot drive a GUI-subsystem pythonw (Antigravity, #863) and which
hide child consoles themselves. Non-Windows platforms succeed as soon as a valid launch tier is
available; a missing entry is better than one known to be broken. Backend spawn
intentionally fails **open**: `backend_python_executable()` prefers a sibling
`pythonw.exe` on Windows but falls back to the current executable when it is
absent, because a visible console is better than a dead backend at runtime.

`client_status` returns `{"clients": [{id, display_name, status, installed,
error?}, …]}`. `error` is present only when status resolution produced an
actionable diagnostic, such as an ambiguous package path or unreadable config.
The dock renders one row per client with a status dot, Configure/Remove buttons,
and a per-row "Run this manually" fallback for cases when auto-configure cannot
find a CLI.
