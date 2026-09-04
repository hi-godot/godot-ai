# AGENTS.md - Godot AI

This guide is for any AI assistant working in this repository. Keep Claude-specific files such as `.claude/CLAUDE.md` and `.claude/skills/*` as thin pointers to this shared guidance.

## What this project is

A production-grade MCP server for Godot. Python server (FastMCP v3) communicates over WebSocket with a GDScript editor plugin. AI clients call MCP tools → Python routes commands → Godot plugin executes against the editor API → results flow back.

## Architecture

- **Protocol**: v4 protocol 2 uses mutual, transcript-bound HMAC over a private per-backend WebSocket capability. The editor reveals metadata only after verifying the server proof; the server publishes a reserved peer only after its final ACK succeeds. Missing/wrong capabilities, protocol-1 frames, duplicate keys, and downgrade attempts fail closed.
- **Transport boundary**: WebSocket remains loopback-only and HTTP is localhost-first, but neither relies on loopback as authentication. HTTP/status/lease require a separate bearer capability; both transports have finite connection/body/frame/session budgets. Never add tokenless, bare-URL, or legacy-handshake fallback. Full contract: [docs/plugin-architecture.md](docs/plugin-architecture.md#security-model).
- **Session model**: Multiple Godot editors connect through one authoritative `_entries` table. Public `Session` values are immutable snapshots; settlement/removal is bound to the exact peer and request reservation. Tools route through the active or explicitly pinned session.
- **Handler/Runtime layer**: Shared handlers in `src/godot_ai/handlers/` contain tool logic. They depend on `DirectRuntime`, the in-process runtime adapter. Tools and resources are thin wrappers that create a runtime and delegate.
- **Readiness gating**: writes check session readiness before executing — Python write handlers must `await require_writable_async()` (`handlers/_readiness.py`), and every new plugin response builder must stamp the envelope-level `readiness` field. `EDITOR_NOT_READY` is frozen as a top-level code; never promote a `data.sub_code` into `error.code`. Self-healing, the importing-hold, and the sub-code vocabulary: [docs/plugin-architecture.md](docs/plugin-architecture.md#session-and-readiness-model).

## Project structure

Read the tree directly — `src/godot_ai/` (Python MCP server) and
`plugin/addons/godot_ai/` (GDScript editor plugin) are the two roots, and the
directory names say what they hold. The parts the layout does *not* tell you:

- `plugin/addons/godot_ai/` is the canonical GDScript copy. `test_project/addons/godot_ai`
  is a locally-built symlink (Windows junction) into it, not tracked in git.
- `src/godot_ai/tools/_meta_tool.py` holds `register_manage_tool`, the rollup factory.
- `src/godot_ai/middleware/` registration order is load-bearing — see "Key conventions".
- `script/` ships fixers for dev-environment problems; scan it before doing setup by hand.

## Key conventions

- **GDScript plugin is the canonical copy** in `plugin/`. `test_project/addons/godot_ai` is a locally-built symlink (or Windows junction) into `plugin/addons/godot_ai` — not tracked in git, created by `script/setup-dev` / `script/verify-worktree`.
- **Error codes**: Defined in `protocol/errors.py` (Python) and `utils/error_codes.gd` (GDScript). Keep in sync. Use Godot's built-in `error_string(err)` to translate numeric error codes in error messages — do not write a custom lookup table.
- **Tools return `dict`**: Handlers call `runtime.send_command(command, params)` which returns a dict or raises. Tools create a `DirectRuntime` and delegate to handlers.
- **Plugin runs on main thread**: All GDScript executes in `_process()` with a 4ms frame budget. Never block. Use `call_deferred` for scene tree mutations.
- **Scene paths are clean**: `/Main/Camera3D` format, not raw Godot internal paths. Use `McpScenePath.from_node(node, scene_root)` in GDScript.
- **Class naming**: classes that need a project-wide `class_name` (i.e. used as a type annotation across multiple files or exposed to third-party addons) carry the `Mcp*` prefix to avoid colliding with user-project classes. Internals only used inside the plugin (handlers, presets/values, test stubs) skip `class_name` and load by path. Handlers are registered lazily so `plugin.gd` does not preload their compile closure. V4 is a clean break from pre-v4 updater and wire compatibility, not a silent revocation of published addon APIs: any previously shipped `class_name` needs an explicit API decision before removal and may remain as a tiny path/UID-stable shim.
- **MCP logging**: Plugin prints `MCP | [recv] command(params)` / `MCP | [send] command -> ok` to Godot console. Controlled by the dock's "Log" toggle, persisted via EditorSetting `godot_ai/mcp_logging` (routes to the dispatcher `mcp_logging` var and `McpLogBuffer.enabled` console echo). High-frequency `[event] readiness -> ...` lines record to the ring buffer only (`log(msg, echo=false)`) and never echo to the console (#626).
- **Tool surface — 46 tools: 19 named tools + 27 `<domain>_manage` rollups**: each domain exposes one rolled-up tool taking `op="<verb>"` + a `params` dict, alongside high-traffic verbs as named tools, so clients that ignore `defer_loading` stay under their tool-count caps. Four of the named tools (`editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`) stay non-deferred; the other 15 and all 27 rollups are tagged `meta={"defer_loading": True}`. When adding a verb, prefer an op on the existing `register_manage_tool(...)` call over a new top-level tool. Rationale and the full checklist: [docs/tool-surface.md](docs/tool-surface.md); op map: `docs/TOOLS.md`.
- **Tool resources alongside tools**: Read-only `godot://...` URIs mirror the most-used reads (`godot://node/{path}/properties`, `godot://script/{path}`, `godot://materials`, …). Resources don't count against tool caps; tool forms are the fallback for clients that don't surface resources, and the only path that supports per-call `session_id` pinning. When a tool has a resource counterpart, its description appends `Resource form: godot://...` so aware clients can route the cheap reads through the URI.
- **`batch_execute` uses plugin command names, not MCP tool names**: the MCP tool `node_create` dispatches the plugin command `create_node`. Inside `batch_execute`'s `commands[].command` field — and inside a `<domain>_manage` op — use the plugin name. The Python handlers in `src/godot_ai/handlers/` are the authoritative map: each calls `runtime.send_command("<plugin_cmd>", ...)`. [docs/tool-surface.md](docs/tool-surface.md)
- **Session IDs**: format is `<project-slug>@<16hex>` (for example, `godot-ai@7f9c3a10d8e426b1`). The slug is recognizable; the 64-bit cryptographic suffix safely disambiguates same-project editors. Server treats the ID as an opaque key.
- **Per-call session routing**: every Godot-talking tool accepts an optional `session_id` parameter. Empty (the default) resolves to the global active session. When supplied, that single call targets that session — `require_writable` and every handler inside the call see the pinned session, not the active one. Use this when multiple AI clients share one MCP server. For `<domain>_manage` rollups, `session_id` is a sibling of `op` and `params` (top-level), *not* nested inside `params`. Resources (`godot://...`) still resolve via the active session.
- **FastMCP middleware order is load-bearing**: `src/godot_ai/server.py` registers `PreserveGodotCommandErrorData → StripClientWrapperKwargs → ParseStringifiedParams → FoldFlatManageParams → HintOpTypoOnManage → TrackMcpSessions`. FastMCP composes the chain via `reversed(self.middleware)`, so first-added is **outermost** (sees response last) and last-added is **innermost** (sees response first). The first five transforms have load-bearing positions; `TrackMcpSessions` is observational and its position is conventional. The rationale is in the docstring above registration and the complete inventory is locked by `tests/unit/test_server_middleware_order.py`.
- **Telemetry is wrap-once at server build time**: `src/godot_ai/server.py` calls `install_fastmcp_wraps(mcp)` right after constructing the FastMCP instance and before any `register_<domain>_tools(mcp)`. That call replaces `mcp.tool` / `mcp.resource` with auto-instrumenting versions, so every tool and resource (including the `<domain>_manage` rollups, whose `op` arg is captured as `sub_action`) gets one `tool_execution` / `resource_retrieval` record per call automatically. Adding a new tool, resource, or rollup op needs **no telemetry call**. Opt-out is `GODOT_AI_DISABLE_TELEMETRY=true` (also accepts `DISABLE_TELEMETRY=true`). The endpoint is configured via `GODOT_AI_TELEMETRY_ENDPOINT`; if unset, a baked-in production default endpoint is used, so telemetry sends by default. Sends stop via the opt-out env var, or via the `telemetry_opt_out` WebSocket event a connected editor latches on a server the plugin adopted rather than spawned (#913) — that latch is one-way for the process's life. Session-id slugs are sha256-hashed before leaving the process so project directory names don't leak. Plugin-side events (dock startup, self-update outcome) ride the existing `send_event("plugin_event", …)` channel; the names allowlist lives in both `plugin/addons/godot_ai/telemetry.gd` and `src/godot_ai/transport/websocket.py::_PLUGIN_EVENT_NAMES` — keep them in sync, along with the `OPT_OUT_EVENT` / `TELEMETRY_OPT_OUT_EVENT` twins. `tests/unit/test_telemetry_event_name_parity.py` locks both. Full reference: `docs/TELEMETRY.md`.
- **Client auto-configuration**: the plugin configures MCP clients from a registry of
  data-only descriptors — `_registry.gd::_CLIENT_SCRIPT_PATHS` is the authoritative
  list; adding one is a new `clients/<name>.gd` plus one script path there, with no
  strategy edits for standard shapes. Every advertised descriptor is command-shape
  (`godot-ai attach` stdio); clients without verified stdio/dynamic-capability
  support, including Cherry Studio, are not advertised in v4.
  [docs/client-configuration.md](docs/client-configuration.md)

### Published `class_name` surface

Do not reintroduce private pre-v4 machinery merely to make old in-place updates
work: the major migration swaps the entire tree while editors are closed.
Published `Mcp*` classes used by third-party addons are a separate API contract.
Prefer keeping their implementation at the original path; if an implementation
is retired, a minimal path/UID-stable declaration is cheaper than an accidental
source break. Removal requires an explicit API decision plus clean-install and
class-cache evidence.

## Worktrees

Assistant sessions may run in git worktrees. Claude Code commonly uses `.claude/worktrees/<name>/`. Be aware of which worktree you're in — it affects everything:

- **File paths**: Your working directory is the worktree, not the repo root. Files you create live in that worktree.
- **Godot editor**: The editor runs against a specific worktree's `test_project/`. The plugin is symlinked from that worktree's `plugin/` directory. Check `session_list` — the `project_path` field tells you which worktree the editor is using.
- **Dev server**: The plugin-managed server (auto-spawned on editor start, no `--reload`) uses the root repo's `.venv` and `src/`. Python code changes in a worktree won't take effect there unless the root repo also has them. Two ways to serve the worktree's own Python source: (a) click **Start Dev Server** in the dock — it walks up from `res://` to find a sibling `src/godot_ai/` and auto-sets `PYTHONPATH` to that tree's `src/` before spawning `--reload`; (b) run `script/serve-this-worktree` from a terminal for the same effect outside the editor.
- **Passing info between sessions**: When writing prompts, handoff notes, or file references intended for another session, **always include the full worktree path** or specify the worktree name. Relative paths like `docs/friction-log.md` are ambiguous — a different session may be in a different worktree or on `main`. Use the absolute path.
- **Merging**: Worktree branches must be merged to `main` and pulled into other worktrees for changes to propagate. The plugin symlink means GDScript changes propagate within the same worktree immediately, but not across worktrees.

Repairing a broken worktree (`script/verify-worktree`, the `post-checkout` hook) and
coexisting with another session's in-flight work: [docs/worktrees.md](docs/worktrees.md).

### Godot editor + worktree safety

**Never launch Godot at *another session's* worktree.** Worktrees can be auto-removed when their owning assistant session exits — MCP tools write files to whatever `test_project/` the editor is running, so all uncommitted scene files, scripts, and themes inside a vanished worktree are permanently lost. Launching at *your own* worktree (the one this session created) is fine, and is the right call when you need to test plugin code that only exists on this branch — just commit frequently so an unexpected exit doesn't drop work.

```bash
# SAFE — root repo, never auto-cleaned:
/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path ~/godot-ai/test_project/

# SAFE — this session's own worktree (commit frequently):
/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path .claude/worktrees/<this-session>/test_project/

# DANGEROUS — another session's worktree, can vanish out from under you:
/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path .claude/worktrees/some-other-name/test_project/
```

When in doubt, prefer the root repo's `test_project/` — it's never auto-cleaned and matches what most CI smoke flows assume. For auto-cleaned assistant worktrees, this is the safe default unless you intentionally need the current worktree's live plugin code and are committing frequently.

### Live-smoke scene hygiene

Write tools that mutate the scene (`script_attach`, `node_create`, `node_set_property`, etc.) dirty the scene in memory but don't touch disk. `project_run` with any mode internally calls `try_autosave()` → `_save_scene_with_preview()`, which **persists those in-memory mutations to the scene file on disk**. A common trap during live smoke tests: attach a throwaway script to `/Main`, run the scene to exercise `_ready()`, and discover the attachment is now committed to `test_project/main.tscn`.

Three safe patterns:
- **`project_run(autosave=False, …)`** suppresses Godot's save-before-running for the play call, so MCP scene mutations stay in memory and the `.tscn` on disk is untouched. Preferred for smoke tests; default stays `True` so existing callers see no behavior change.
- **Attach to a throwaway scene** dedicated to smoke work, not to `main.tscn` or any scene a test suite depends on.
- **Plan to revert**: after smoking, `git status` in the worktree and `git checkout -- test_project/<scene>` to undo any autosaved pollution. Verify before staging.

Also note: `script_create` and `filesystem_write_text` are **not undoable** — they write `.gd`/`.uid`/other files directly to disk and response bodies carry `"undoable": false` with a reason. Smoke artifacts need explicit cleanup (`rm` the file pair, or `git clean -n` first to preview).

## Dev workflow

```bash
cd ~/godot-ai
script/setup-dev             # creates .venv, installs deps, applies macOS .pth fix
source .venv/bin/activate
pytest -v                    # run tests
```

`uv.lock` is intentionally untracked: dependencies resolve from `pyproject.toml`, and CI installs with pip (`pip install -e ".[dev]"`) rather than enforcing a uv lockfile.

**macOS + Python 3.13 note**: Files inside `.venv` inherit the macOS hidden flag (dot-prefix directory). Python 3.13 skips hidden `.pth` files (CPython gh-113659), breaking editable installs. `script/setup-dev` generates a `sitecustomize.py` in the venv that adds `src/` to `sys.path` via normal import (unaffected by hidden flags). No manual `chflags` needed.

**Windows note**: use `.\script\setup-dev.ps1` instead of `script/setup-dev`. The Windows script creates `test_project\addons\godot_ai` as a directory junction — no admin rights and no Windows Developer Mode required. If you ever need to recreate the link by hand (e.g. outside setup-dev), either form works:

```powershell
# from repo root or worktree root
Remove-Item -LiteralPath test_project\addons\godot_ai -Force -ErrorAction SilentlyContinue
New-Item -ItemType Junction -Path test_project\addons\godot_ai -Target ..\..\plugin\addons\godot_ai
```

Or in cmd: `mklink /J test_project\addons\godot_ai ..\..\plugin\addons\godot_ai`.

**When troubleshooting any dev-environment / setup / dependency / symlink issue, scan `script/` first** for an existing fixer before doing it by hand. The project ships scripts for a reason — bypassing them re-introduces the bugs they were written to handle.

- Server start/adopt/teardown, discovery tiers, `editor_reload_plugin`: [docs/server-lifecycle.md](docs/server-lifecycle.md)
- Cutting a release: [docs/releasing.md](docs/releasing.md).
- Self-update, migration capsule, or release verification changes:
  [docs/self-update.md](docs/self-update.md). **Any change touching update
  discovery, `update_manager.gd`, `release_verifier.gd`, `update_installer.gd`,
  `release_verify.py`, the migration bridge, plugin disable/enable, or the
  signed release layout must pass `test_project/tests/test_update_installer.gd`
  and the three real-editor scenarios in
  `tests/integration/test_self_update_upgrade_paths.py` (run with `GODOT_BIN`
  set).**

## Testing

### Python tests
```bash
pytest -v                    # full Python unit + integration suite
```

### Godot-side tests
GDScript test suites in `test_project/tests/` exercise handlers inside the running editor. Run via MCP:
```
test_run                     # compact: summary + failures only
test_run suite=scene         # run one suite
test_run verbose=true        # include every individual test result
test_manage op=results_get   # review last results (resource form: godot://test/results)
```

Test suites extend `McpTestSuite`; drop `test_*.gd` files in `res://tests/` and they're auto-discovered. Authoring guide + full assertion/lifecycle API reference: [docs/testing.md](docs/testing.md).

### Stress / load testing

`script/stormtest.py` fires concurrent randomized tool calls with reload churn at a live
editor. Run it after changes to the dispatcher, transport, readiness gating, session
routing, or the reload/handoff path: [docs/STRESS_TESTING.md](docs/STRESS_TESTING.md).

### Test hygiene checklist — common silent-failure patterns to avoid

A test that passes for the wrong reason is worse than a missing test: it ships a regression under a green check. Watch for these masking patterns when writing or reviewing tests:

- **Bare `return` in a test body**. Every `return` in a `test_*` function must be preceded by either an `assert_*` call (for a real failure) or `skip("reason")` (for an environment precondition that can't be met). A silent `return` passes with zero assertions — the runner guardrail catches this now, but the failure message ("0 assertions") is noisier than a targeted `skip()` that reports *why* the test couldn't run.
- **Counts instead of stored Variants**. Asserting `track_count == 1` or `child_count > 0` says nothing about the stored value. For mutation tools that take JSON dicts (Color, Vector2, Vector3, keyframe values), read back via `track_get_key_value`, `mi.mesh`, `mat.gravity`, etc. and assert `value is Color` / `value is Vector3`. See "Value coercion" in [docs/plugin-architecture.md](docs/plugin-architecture.md#undo-contract).
- **Bare `get_theme_*` getters in override tests**. Reading a theme value via `get_theme_color(...)` alone falls back through the theme chain — a broken `add_theme_color_override` will silently resolve to the default, passing the assertion. Godot 4.6 removed the `get_theme_*_override` getters, so the honest pattern is now: assert `has_theme_color_override(...)` (or the constant/font-size/stylebox variant) FIRST, then read the value with the regular getter — the override presence check is what prevents the fallback from masking a bug. `test_ui.gd::test_build_layout_theme_override_*` are the reference pattern.
- **`assert_has_key` without a follow-up value check**. Presence of `"data"` in a response says nothing about correctness. Every `assert_has_key(result, "data")` should be paired with at least one `assert_eq` / `assert_true` on a field inside `result.data`.
- **`editor_undo()` / `editor_redo()` without checking the return**. The helper returns `bool` — `false` means the undo silently no-oped. For tests that assert post-undo state, capture `var did_undo := editor_undo(_undo_redo); assert_true(did_undo, "undo should succeed")` before asserting the rolled-back value.
- **Bare `except: pass` in Python tests**. Swallowing exceptions can let a half-failed operation still pass the downstream assertion. Catch specific exceptions, and if you truly want to ignore a cleanup failure, log it.
- **CI scripts that drop `failures[]`**. When a `script/ci-*` parses a `test_run` response, it must iterate `content.get("failures", [])` and print `{suite}.{test}: {message}` on failure — not just the passed/failed counts. `script/ci-godot-tests` is the reference implementation.
- **Unsupported-engine skips**. Do not version-gate v4 behavior inside the
  supported suite: Godot 4.7 is the floor. CI runs separate 4.5 and 4.6
  no-mutation refusal smokes; those versions must never enter normal tests or
  make older-engine branches part of production behavior.

## Before you commit

**Always run the full gauntlet before every commit** — `ruff check`, `pytest -v`,
then `test_run` against a live Godot editor, plus a live smoke of anything you
changed. Python mocks do not catch GDScript bugs, editor API regressions, or
undo/redo breakage. Steps: [docs/verification.md](docs/verification.md).

## Tool inventory sources

Do not maintain a full tool inventory in this guide. The active inventory has canonical sources:

- `src/godot_ai/tools/domains.py` defines the domain metadata used by Python registration.
- `plugin/addons/godot_ai/tool_catalog.gd` mirrors the registered tool surface for the Godot dock.
- `tests/unit/test_tool_domains.py` verifies the GDScript catalog stays in sync with the Python registrations and prints a paste-over-ready diff when it drifts.
- `docs/TOOLS.md` is the human-facing reference for the full current tool/resource list and op map.

Use those sources when you need the current inventory. Keep this guide focused on the rules for changing the tool surface so it does not become another stale hand-maintained list.

Why the surface is shaped this way, how plugin command names differ from MCP tool names,
and the checklist for adding a tool: [docs/tool-surface.md](docs/tool-surface.md).

## Python conventions

- Handlers: `return await runtime.send_command("command_name", params)` — don't handle errors.
- Write handlers: `await require_writable_async(runtime)` before sending commands (from `handlers/_readiness.py`).
- Tools create `DirectRuntime.from_context(ctx)` and delegate to handlers.

## Game-side code: gate on `Engine.is_editor_hint()`, not `OS.has_feature("editor")`

Code shipped as an autoload (e.g. `plugin/addons/godot_ai/runtime/game_helper.gd`) that's intended to run only in the game subprocess must guard on `Engine.is_editor_hint()`. `OS.has_feature("editor")` is a compile-time `TOOLS_ENABLED` check — it returns true in the game subprocess too, because play-in-editor spawns the game with the same editor binary. `is_editor_hint()` is the runtime-context check.

Corollary for the plugin side: when registering a game-side autoload via `add_autoload_singleton`, also call `ProjectSettings.save()` explicitly. `EditorPlugin.add_autoload_singleton` only mutates in-memory settings — the subprocess reads project.godot from disk, so without an explicit save the autoload is missing in the child process. See `plugin.gd::_ensure_game_helper_autoload`.

## Write tools must be undoable

Every tool that mutates the scene (create, delete, reparent, set_property, etc.) must use `EditorUndoRedoManager`. No exceptions. The pattern:

```gdscript
_undo_redo.create_action("MCP: <description>")
_undo_redo.add_do_method(...)
_undo_redo.add_undo_method(...)
_undo_redo.add_do_reference(node)  # prevent GC of created nodes
_undo_redo.commit_action()
```

Response must include `"undoable": true`. If an operation genuinely can't be undone (file writes, scene open/close), include `"undoable": false` with a reason.

Four patterns this rule implies — bundling auto-created dependencies into the same undo
action, coercing JSON values to typed Variants, resolving auto-generated indices at undo
time rather than do time, and `GEN_EDIT_STATE_INSTANCE` for scene instancing — are worked
through in [docs/plugin-architecture.md](docs/plugin-architecture.md#undo-contract).

### Additional GDScript conventions

- Handlers are `@tool` `RefCounted` scripts with **no** `class_name`. `plugin.gd` registers them by script path (`McpDispatcher.register_lazy_handler` / `register_lazy`) and the dispatcher `load()`s them at first dispatch (#736) — do not add a `const X := preload(...)` for a handler back into `plugin.gd`; that re-inflates the boot-time compile closure. Cross-handler and values/presets deps inside `handlers/` still use `const X := preload(...)` from their consumers. The `Mcp*`-prefixed `class_name` is reserved for utility classes shared across the project (e.g. `McpScenePath`, `McpPropertyErrors`, `McpParamValidators`); see #253 for why bare `class_name`s on handlers are forbidden.
- Return `{"data": {...}}` on success, `McpErrorCodes.make(code, msg)` on failure — include the failing parameter value and use `error_string(err)` for Godot error codes.
- The dispatcher detects empty/null handler results and reports `INTERNAL_ERROR` — a handler crash no longer looks like success.
- Use `##` for doc comments, typed arrays (`Array[String]`), never Python-style `"""`.

## Test coverage

Security, protocol, ownership, and changed behavior need direct regression
coverage at the layer that owns them. Python orchestration belongs in
`tests/unit/` or `tests/integration/`; editor APIs and undo semantics belong in
`test_project/tests/`. Cross-boundary behavior needs both sides or a live smoke.
Coverage reports are diagnostic—CI does not claim or enforce a universal 100%
line threshold.


## v4 architecture work

The active rebuild is governed by
[docs/architecture-simplification-plan.md](docs/architecture-simplification-plan.md)
and its
[verification companion](docs/architecture-simplification-verification-plan.md).
The maximal hardening tree is preserved separately at
`checkpoint/architecture-hardening-2026-08-30-draft1` as an oracle, not as the
implementation base. The earlier [docs/audit-tier2-plan.md](docs/audit-tier2-plan.md)
is archived point-in-time evidence, not a live backlog. Never implement or
re-file one of its findings without verifying it against current code; paths,
severity, and proposed fixes may already be stale or superseded. The full test
gauntlet remains required before every commit.

## Godot version support (4.7+)

Godot AI v4 supports **Godot 4.7 and newer**. The plugin entry point checks the
engine before constructing the lifecycle or any side-effecting owner. Godot
4.5/4.6 emit one actionable refusal and remain inert.

- **Newer APIs**: a direct engine API that postdates 4.7 is parsed against the
  current floor even behind `has_method`. Use a dynamic `Engine.call(...)` /
  `OS.call(...)` seam when forward compatibility genuinely requires it.
- **Supported parse gate**: `script/ci-check-gdscript` scans the Godot 4.7
  import log and fails on parse/load errors or an empty validation run.
- **Unsupported floor gate**: `script/ci-unsupported-godot-smoke` runs against
  official 4.5 and 4.6, requires the exact refusal, and proves byte-identical
  add-on files and `project.godot`, with no capability record. Godot's generated
  `.godot/` import cache is outside this mutation contract.
- **Hosted matrix**: normal Godot tests run on Linux, macOS, and Windows at
  4.7.0. Unsupported versions never run the behavioral suite.

## What NOT to do

- Don't call `EditorInterface` methods from WebSocket callbacks — always queue
- Don't cache `get_edited_scene_root()` across frames — it changes on scene switch
- Don't add error handling in individual tools — `GodotClient.send()` raises on errors
- Don't forget the `overwrite` parameter on `animation_create` / `animation_create_simple` — without it, creating an animation with the same name errors instead of replacing
