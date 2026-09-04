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
  `config_path_candidates`). Adding a client
  with a shape one of the existing strategies already writes means exactly two
  things: write `clients/<name>.gd` extending `McpClient`, then append its
  script path to `_CLIENT_SCRIPT_PATHS` in `_registry.gd`. No edits to the
  dock, the facade, or the strategies. A client whose config language is a
  genuinely new shape gets a small dedicated strategy instead (DeepSeek
  Harness' loader `insert` list is the current example: `_dsh_strategy.gd`,
  dispatched on `config_type "dsh"`), plus the matching branch in
  `client_configurator.gd` and `_manual_command.gd`.

### Path resolution fails closed

Every descriptor path is `~`- or `$VAR`-rooted and expands through
`_path_template.gd`. A token that cannot be resolved — the variable is unset, or
a dock worker is reading an env snapshot that was never warmed — is **left in
the string** rather than replaced with an empty string. Substituting the empty
string is what turned `$USERPROFILE/godot` into `/godot`, a root-relative path
that `is_absolute_path()` accepts, so every fail-closed guard in this layer
waved it through and Configure wrote somewhere the user never named.

The invariant that replaces it: **a resolved config path is absolute or it is an
error**. `McpClient.resolved_config_path_details()` enforces it for every
descriptor path (both env overrides, `config_path_candidates`, and plain
`path_template`), `_json_strategy.gd::_load_merge_tiers` enforces it for Pi's
merge tiers, and `McpAtomicWrite.write` refuses a non-absolute destination as a
last line of defence. The dock reports the unexpanded path, which still shows
what failed to resolve.

MCP tools `client_configure`, `client_remove`, and `client_status` expose this to
AI clients.

Client-owned attach entries carry an authenticated stdio launch command rather
than a persistent HTTP URL. Cherry Studio is not advertised in v4 because its
servers live in an internal database and it has no verified dynamic-capability
or stdio configuration surface. The dock captures
ports, canonical excluded domains, plugin version, dev/user mode, and the
telemetry preference on the main thread, then workers resolve the same three
launch tiers used by server startup (dev venv → exact-version uvx → matching
system install). A disabled telemetry preference renders as
`--disable-telemetry` on the attach argv — the env-injection path that covers
plugin-spawned servers never runs for a client-spawned bridge or its backend
(see docs/TELEMETRY.md). Package pins, command paths, ports, exclusions,
telemetry, and required uv options are verified as launch drift. After an
update restarts the editor and the live tree verifies, the plugin repins
configured clients automatically (pin-only). **Configure all** is manual
remediation when that repin reports drift or failure, and remains the explicit
repair path after a port
change, telemetry toggle, or tool-domain change. Never silently fall back to a
bare `uvx` command for these entries—report ERROR and leave the config untouched
when no verified tier exists.

The uvx tier is isolated/no-config/no-build and names official PyPI explicitly.
Godot-owned server/prewarm spawns also clear inherited uv resolution controls;
client-owned bridges carry the same resolver policy in their persisted argv.
Only the process-local qualification switch documented in the release plan may
omit the public-index options, and it never persists its private endpoint or
credentials. This removes ambient alternate-index authority; it does not bind
the bytes later returned by public PyPI. PyPI/TLS, the selected uv executable
and cache, and same-user machine integrity remain runtime trust roots.

Dock-initiated Configure attempts to pre-build the pinned `godot-ai==X` uv
environment before the Dock reports completion (`prewarm_attach_plan` /
`prewarm_attach_launch`). When that best-effort prewarm succeeds, the first
client spawn is a warm cache hit.
Without it the *client* pays for building ~67 packages on its own critical
path, which flashes a terminal window on Windows (#851) and can overrun an MCP
client's default 30s connect timeout—the tools then appear to vanish until a
restart. Only the `uvx` tier is warmed; dev-venv and system launches run an
already-installed package. The warm is best-effort and never rewrites or rolls
back a successfully verified config entry. MCP `client_configure` keeps its
mutation-only deferred contract and deliberately skips this Dock convenience.
The Dock relabels the button `Installing…` while it runs so a cold build does
not read as a hang.

### Global mutation lock and recovery

Every automatic Configure or Remove operation—JSON, TOML, YAML, CLI, DSH, and
post-update client repinning—acquires one account-wide
durable lock at the exact path reported by
`McpClientMutationLock.recovery_message()`. It lives below the OS config
directory rather than `user://`, because global client configuration is shared
by every Godot project for the account. The claim stays held through post-write
status verification. Status probes and manual instructions remain lock-free.

An existing or malformed lock fails closed. If a timed-out CLI mutation cannot
prove that its process tree terminated, the lock deliberately survives plugin
reload, editor restart, and crashes. Stop the relevant client processes—or
reboot—then explicitly remove the **entire exact lock directory printed in the
error** before retrying. Restarting Godot alone is not proof that a descendant
stopped, and deleting only `owner.json` leaves the deny marker in place.

The lock serializes each mutation and its readback; it does not make a
multi-client post-update repin batch or the earlier lock-free status/drift
probes atomic. The
migration fails closed on observed non-version drift, but another project can
complete a serialized write between that observation and a later per-client
claim. Treat that probe-to-write interval as an explicit P2 last-writer
limitation rather than claiming batch-wide compare-and-mutate semantics.

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

`automatic_config_edits = false` marks a client whose settings file the dock
never rewrites: Configure and Remove return the manual entry instead.
`config_allows_comments = true` is its read-side companion for JSONC clients —
Zed's `settings.json` opens with a `//` header that `JSON.parse` rejects, so
without it a stock install shows a permanent parse error. Status, the manual
instructions, and Open/Reveal strip `//` and `/* */` from a throwaway parse
copy; markers inside JSON strings survive, and an unterminated block comment
fails closed. No write path takes that branch, and the flag is honored only
while `automatic_config_edits` is false, so a JSONC descriptor cannot pick up a
comment-destroying rewrite by flipping one field.

Command migrations deep-copy existing JSON entries before replacing pinned
launch fields. `command_user_fields` documents known client-owned settings but
is not a preservation whitelist: unknown future fields survive too.
`command_legacy_keys` removes conflicting top-level transport fields, while
`command_env_legacy_keys` removes only named legacy values inside `env` and
preserves every other user environment variable.

Manual instructions expose only authenticated stdio attach. A bare HTTP URL
cannot carry the private rotating bearer and must never be persisted as a v4
client configuration.

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
