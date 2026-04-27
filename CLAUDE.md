# CLAUDE.md — Godot AI

## What this project is

A production-grade MCP server for Godot. Python server (FastMCP v3) communicates over WebSocket with a GDScript editor plugin. AI clients call MCP tools → Python routes commands → Godot plugin executes against the editor API → results flow back.

## Architecture

```
AI Client → MCP (stdio/sse/streamable-http) → Python FastMCP server → WebSocket (port 9500) → Godot EditorPlugin
```

- **Python server**: `src/godot_ai/` — FastMCP v3, async, lifespan manages WebSocket server
- **GDScript plugin**: `plugin/addons/godot_ai/` — canonical source; symlinked into `test_project/addons/` for testing
- **Protocol**: JSON over WebSocket. Request/response with `request_id` correlation. Handshake on connect.
- **Session model**: Multiple Godot editors can connect. Tools route through active session.
- **Handler/Runtime layer**: Shared handlers in `src/godot_ai/handlers/` contain tool logic. They depend on a `Runtime` protocol (`runtime/interface.py`), implemented by `DirectRuntime` for the in-process server. Tools and resources are thin wrappers that create a runtime and delegate.
- **Readiness gating**: Write operations check session readiness (`ready`/`importing`/`playing`/`no_scene`) before executing. Plugin sends readiness in handshake and via `readiness_changed` events. Python `require_writable()` in `handlers/_readiness.py` gates all write handlers.

## Key conventions

- **GDScript plugin is the canonical copy** in `plugin/`. `test_project/addons/godot_ai` is a locally-built symlink (or Windows junction) into `plugin/addons/godot_ai` — not tracked in git, created by `script/setup-dev` / `script/verify-worktree`.
- **Error codes**: Defined in `protocol/errors.py` (Python) and `utils/error_codes.gd` (GDScript). Keep in sync. Use Godot's built-in `error_string(err)` to translate numeric error codes in error messages — do not write a custom lookup table.
- **Tools return `dict`**: Handlers call `runtime.send_command(command, params)` which returns a dict or raises. Tools create a `DirectRuntime` and delegate to handlers.
- **Plugin runs on main thread**: All GDScript executes in `_process()` with a 4ms frame budget. Never block. Use `call_deferred` for scene tree mutations.
- **Scene paths are clean**: `/Main/Camera3D` format, not raw Godot internal paths. Use `ScenePath.from_node(node, scene_root)` in GDScript.
- **MCP logging**: Plugin prints `MCP | [recv] command(params)` / `MCP | [send] command -> ok` to Godot console. Controlled by `mcp_logging` var.
- **Tool surface — ~18 named verbs + per-domain `<domain>_manage` rollups**: To stay under hard tool-count caps in clients that ignore Anthropic's `defer_loading` (Antigravity, etc.), each domain exposes one rolled-up MCP tool that takes `op="<verb>"` + a `params` dict, alongside the high-traffic verbs as named tools. Schema-aware clients still see every `op` because `register_manage_tool` in `src/godot_ai/tools/_meta_tool.py` builds a dynamic `Literal[...]` enum. Core tools (`editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`) stay non-deferred; named non-core verbs and every `<domain>_manage` rollup are tagged `meta={"defer_loading": True}` for tool-search-aware clients. Plugin command names (over WebSocket) are independent — the MCP tool `editor_reload_plugin` dispatches the plugin command `reload_plugin`. See `docs/TOOLS.md` for the full op map.
- **Tool resources alongside tools**: Read-only `godot://...` URIs mirror the most-used reads (`godot://node/{path}/properties`, `godot://script/{path}`, `godot://materials`, …). Resources don't count against tool caps; tool forms are the fallback for clients that don't surface resources, and the only path that supports per-call `session_id` pinning. When a tool has a resource counterpart, its description appends `Resource form: godot://...` so aware clients can route the cheap reads through the URI.
- **`batch_execute` uses plugin command names, not MCP tool names**: The MCP tool `node_create` dispatches the plugin command `create_node`. Inside `batch_execute`'s `commands[].command` field, use the plugin name (`create_node`), not the MCP name (`node_create`). Inside a `<domain>_manage` op, the same rule applies — `node_manage(op="delete", params={...})` delegates to the plugin's `delete_node`, not `node_delete`. The Python handlers in `src/godot_ai/handlers/` are the authoritative map — each handler calls `runtime.send_command("<plugin_cmd>", ...)`. When `batch_execute` receives an unknown plugin command, the GDScript dispatcher returns `INVALID_PARAMS` with fuzzy `data.suggestions`. Inside a `<domain>_manage` rollup, op-name validation happens earlier — at the FastMCP/Pydantic schema boundary, since `op` is typed `Literal[...]` of the registered op names. A misspelling like `theme_manage(op="set_colour")` surfaces as a Pydantic `literal_error` whose message lists the valid alternatives ("Input should be 'create', 'set_color', …"), not a structured `data.suggestions` payload. The meta-tool's own `difflib`-based fallback in `dispatch_manage_op` only fires when the call somehow bypasses Pydantic (e.g. a future internal direct-dispatch caller).
- **Session IDs**: format is `<project-slug>@<4hex>` (e.g. `godot-ai@a3f2`). The slug is derived from the project directory name so agents can recognize which editor they're targeting; the hex suffix disambiguates same-project twins. Server treats the ID as an opaque key.
- **Per-call session routing**: every Godot-talking tool accepts an optional `session_id` parameter. Empty (the default) resolves to the global active session. When supplied, that single call targets that session — `require_writable` and every handler inside the call see the pinned session, not the active one. Use this when multiple AI clients share one MCP server. For `<domain>_manage` rollups, `session_id` is a sibling of `op` and `params` (top-level), *not* nested inside `params`. Resources (`godot://...`) still resolve via the active session.

## Worktrees

Claude Code sessions often run in git worktrees (`.claude/worktrees/<name>/`). Be aware of which worktree you're in — it affects everything:

- **File paths**: Your working directory is the worktree, not the repo root. Files you create live in that worktree.
- **Godot editor**: The editor runs against a specific worktree's `test_project/`. The plugin is symlinked from that worktree's `plugin/` directory. Check `session_list` — the `project_path` field tells you which worktree the editor is using.
- **Dev server**: The plugin-managed server (auto-spawned on editor start, no `--reload`) uses the root repo's `.venv` and `src/`. Python code changes in a worktree won't take effect there unless the root repo also has them. Two ways to serve the worktree's own Python source: (a) click **Start Dev Server** in the dock — it walks up from `res://` to find a sibling `src/godot_ai/` and auto-sets `PYTHONPATH` to that tree's `src/` before spawning `--reload`; (b) run `script/serve-this-worktree` from a terminal for the same effect outside the editor.
- **Passing info between sessions**: When writing prompts, handoff notes, or file references intended for another session, **always include the full worktree path** or specify the worktree name. Relative paths like `docs/friction-log.md` are ambiguous — a different session may be in a different worktree or on `main`. Use the absolute path.
- **Merging**: Worktree branches must be merged to `main` and pulled into other worktrees for changes to propagate. The plugin symlink means GDScript changes propagate within the same worktree immediately, but not across worktrees.

### Worktree health: `script/verify-worktree` + `post-checkout` hook

`test_project/addons/godot_ai` is **not tracked in git** (see `.gitignore` and #185). Every working copy builds the link locally — as a symlink on Unix, as a directory junction on Windows. This avoids the Windows-without-Dev-Mode text-file-fallback trap and stops `git rebase` / `cherry-pick` from fighting the link on every checkout.

Before editing *anything* in `plugin/` in a worktree, the worktree must pass two invariants:

1. `plugin/addons/godot_ai/plugin.gd` exists (the worktree's `plugin/` is populated, not empty or sparse).
2. `test_project/addons/godot_ai` is a real symlink (or Windows directory junction) into **this worktree's** `plugin/addons/godot_ai`.

`script/verify-worktree` (bash, works in git-bash on Windows) checks both. If the link is missing or broken it creates/repairs it via `ln -s` or `mklink /J` — no admin rights, no Windows Developer Mode required. It runs automatically via a `post-checkout` hook on every `git worktree add` and `git checkout <branch>`, so a freshly-created worktree is healthy by the time you start editing.

Wiring: `script/setup-dev` and `setup-dev.ps1` copy `.githooks/post-checkout` into `.git/hooks/post-checkout` (the default path git always looks at). `.git/hooks/` is shared across all worktrees of a clone, so one install covers every future worktree forever. A fresh clone on a new machine needs setup-dev run once before the hook is active — after that, it's automatic. (We don't use `core.hooksPath=.githooks` because git resolves that relative path against main's working tree, which may be on a branch without `.githooks/` — a trap that wasted a whole debugging cycle.)

**If you find a broken worktree** (empty `plugin/`, or the link missing/stale): do NOT `git add` anything. Run `script/verify-worktree` to heal, or re-create the worktree. Committing plugin/ edits from a broken worktree stages phantom deletions that overwrite the canonical plugin code in main on push.

**Parallel plugin development IS supported** — each worktree has its own `plugin/` (standard git worktree semantics) and its own locally-built `test_project/addons/godot_ai` link. Multiple Godot editors, one per worktree, all connect to the same MCP server on :8000; use `session_activate` (or `session_id` per call) to route. The ban is only on editing in *broken* worktrees.

### Godot editor + worktree safety

**Always launch Godot from the root repo's `test_project/`, not from a worktree.** Worktrees can be auto-removed when their owning Claude Code session exits. MCP tools write files to whatever `test_project/` the editor is running — if that's a worktree that gets deleted, all uncommitted scene files, scripts, and themes are permanently lost.

```bash
# SAFE — root repo, never auto-cleaned:
/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path /Users/davidsarno/Documents/godot-ai/test_project/

# DANGEROUS — worktree, can vanish:
/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path .claude/worktrees/some-name/test_project/
```

If you need worktree-specific test_project changes, use your own worktree (the one your session created), commit frequently, and never point Godot at a worktree owned by another session.

### Live-smoke scene hygiene

Write tools that mutate the scene (`script_attach`, `node_create`, `node_set_property`, etc.) dirty the scene in memory but don't touch disk. `project_run` with any mode internally calls `try_autosave()` → `_save_scene_with_preview()`, which **persists those in-memory mutations to the scene file on disk**. A common trap during live smoke tests: attach a throwaway script to `/Main`, run the scene to exercise `_ready()`, and discover the attachment is now committed to `test_project/main.tscn`.

Three safe patterns:
- **`project_run(autosave=False, …)`** suppresses Godot's save-before-running for the play call, so MCP scene mutations stay in memory and the `.tscn` on disk is untouched. Preferred for smoke tests; default stays `True` so existing callers see no behavior change.
- **Attach to a throwaway scene** dedicated to smoke work, not to `main.tscn` or any scene a test suite depends on.
- **Plan to revert**: after smoking, `git status` in the worktree and `git checkout -- test_project/<scene>` to undo any autosaved pollution. Verify before staging.

Also note: `script_create` and `filesystem_write_text` are **not undoable** — they write `.gd`/`.uid`/other files directly to disk and response bodies carry `"undoable": false` with a reason. Smoke artifacts need explicit cleanup (`rm` the file pair, or `git clean -n` first to preview).

### Working in another session's worktree

Sometimes you're directed at another session's PR worktree (e.g. to fix a bug their friction log surfaced) and that session still has in-flight uncommitted work in adjacent files. Coexist safely:

1. **Inspect before you touch**: run `git status` and `git diff --stat` in the target worktree first so you know which files are already dirty — that's the other session's work, not your canvas.
2. **Stage by explicit path**: `git add plugin/foo.gd test_project/tests/test_foo.gd`, never `git add .` or `git add -A`. Even if their uncommitted work looks related to yours, it isn't yours to commit.
3. **Multi-editor is fine when you need the PR's live plugin code**: launch a second Godot editor pointed at the PR worktree's `test_project/` alongside any existing editor — both connect to the same MCP server on port 8000 and show up in `session_list`. Use `session_activate` to pin your commands to the right session. This beats killing the other session's editor or rsync'ing PR code over an unrelated project.
4. **Accept the auto-clean risk**: a worktree owned by another session can be removed when that session exits. Commit (and ideally push) as soon as your fix and tests are green — don't leave uncommitted work in a worktree you don't own.
5. **Revert your own autosave pollution** before committing (see "Live-smoke scene hygiene"). Running the scene during smoke will dirty the scene file with any in-memory mutations you staged.
6. **Push only what's yours**: don't push the branch if it still contains another session's uncommitted experimental work — they may not be ready. When in doubt, commit locally and ask.

## Dev workflow

```bash
cd ~/Documents/godot-ai
script/setup-dev             # creates .venv, installs deps, applies macOS .pth fix
source .venv/bin/activate
pytest -v                    # run tests
ruff check src/ tests/       # lint
ruff format src/ tests/      # format
```

**macOS + Python 3.13 note**: Files inside `.venv` inherit the macOS hidden flag (dot-prefix directory). Python 3.13 skips hidden `.pth` files (CPython gh-113659), breaking editable installs. `script/setup-dev` generates a `sitecustomize.py` in the venv that adds `src/` to `sys.path` via normal import (unaffected by hidden flags). No manual `chflags` needed.

**Windows note**: use `.\script\setup-dev.ps1` instead of `script/setup-dev`. The Windows script creates `test_project\addons\godot_ai` as a directory junction — no admin rights and no Windows Developer Mode required. If you ever need to recreate the link by hand (e.g. outside setup-dev), either form works:

```powershell
# from repo root or worktree root
Remove-Item -LiteralPath test_project\addons\godot_ai -Force -ErrorAction SilentlyContinue
New-Item -ItemType Junction -Path test_project\addons\godot_ai -Target ..\..\plugin\addons\godot_ai
```

Or in cmd: `mklink /J test_project\addons\godot_ai ..\..\plugin\addons\godot_ai`.

**When troubleshooting any dev-environment / setup / dependency / symlink issue, scan `script/` first** for an existing fixer before doing it by hand. The project ships scripts for a reason — bypassing them re-introduces the bugs they were written to handle.

### Server lifecycle in dev

The plugin manages the server process:
- On startup, plugin checks if port 8000 is already in use. If yes, uses existing server. If no, spawns `.venv/bin/python -m godot_ai --transport streamable-http --port 8000`.
- The plugin prefers the local `.venv` over system-installed `godot-ai` so dev checkouts always use source code.

For Python auto-reload during dev (no need to touch Godot):
```bash
python -m godot_ai --transport streamable-http --port 8000 --reload
```
This uses `src/godot_ai/asgi.py` to run uvicorn with its factory reload path. Uvicorn watches `src/` for changes and restarts the server process automatically. The plugin auto-reconnects.

### Plugin reload

The `editor_reload_plugin` MCP tool triggers a live plugin reload inside Godot (`EditorInterface.set_plugin_enabled` off/on). Requires the server to be running externally (not managed by the plugin). The Python handler waits for the new session via `SessionRegistry.wait_for_session()`.

The Godot dock also has a **Start/Stop Dev Server** button for convenience (visible in developer mode).

### Releasing

Use the GitHub Actions workflow to cut a release:
```bash
gh workflow run bump-and-release.yml -f bump=patch   # or minor / major
```
This bumps `plugin.cfg` + `pyproject.toml`, commits, tags, and pushes. The `release.yml` workflow triggers on the tag and builds a `godot-ai-plugin.zip` attached to the GitHub Release.

### Self-update

The dock checks the GitHub releases API on startup. If a newer version exists, a yellow banner appears with an "Update" button that downloads the release ZIP, extracts it over the current `addons/godot_ai/`, and reloads the plugin. The server process is unaffected.

In dev checkouts the check is skipped: `is_dev_checkout()` detects a nearby `.venv` and short-circuits to avoid offering a path that would overwrite tracked source (the addons dir is a symlink into `plugin/`). Three override knobs let you exercise the update flow without leaving the repo (resolved in priority order):

1. **Dock dropdown** (`Mode override` in the dev-section of the MCP dock) — visible when `Developer mode` is on. Persists via EditorSetting `godot_ai/mode_override`. Choices: `Auto` / `Force user` / `Force dev`. Changing the dropdown immediately re-runs the update check so you can flip to "Force user" and watch the yellow banner appear in the same frame.
2. **`GODOT_AI_MODE` env var** — fallback for CLI launches and CI. Values: `user` / `dev`. Only takes effect when the dock dropdown is `Auto` (the UI selection always wins).
3. Neither set → the `.venv`-proximity heuristic runs as before.

When either override reports `user`, the yellow update banner's label includes `(forced)` so testers don't forget they're in override mode.

`_install_update` keeps a physical data-safety guard (`addons_dir_is_symlink()`) independent of the mode override: even in forced-user mode the self-install bails if `res://addons/godot_ai` is a symlink. To actually test the end-to-end extract path, unpack a release zip over a plain-directory copy of the addons dir (or test from a standalone project outside the dev tree).

## Testing

### Python tests
```bash
pytest -v                    # 388 unit + integration tests
```

### Godot-side tests
GDScript test suites in `test_project/tests/` exercise handlers inside the running editor. Run via MCP:
```
test_run                     # compact: summary + failures only
test_run suite=scene         # run one suite
test_run verbose=true        # include every individual test result
test_results_get             # review last results
```

Test suites extend `McpTestSuite` (assertion methods: `assert_true`, `assert_eq`, `assert_has_key`, `assert_contains`, `assert_is_error`, etc.). Drop `test_*.gd` files in `res://tests/` and they're auto-discovered.

**Guardrails built into the test runner:**
- **Zero-assertion detection**: Tests that complete with 0 assertions are flagged as failures ("Test completed with 0 assertions — likely skipped its logic"). This catches tests that silently `return` before asserting anything.
- **Resilient discovery**: If a `.gd` file fails to load (parse error, duplicate method, wrong base class), the rest of the suites still run and the failing files are reported in `load_errors`.
- **Suite isolation**: Each suite gets a fresh `ctx.duplicate()` so `suite_setup()` mutations can't leak to the next suite.

### Test hygiene checklist — common silent-failure patterns to avoid

A test that passes for the wrong reason is worse than a missing test: it ships a regression under a green check. Watch for these masking patterns when writing or reviewing tests:

- **Bare `return` in a test body**. Every `return` in a `test_*` function must be preceded by either an `assert_*` call (for a real failure) or `skip("reason")` (for an environment precondition that can't be met). A silent `return` passes with zero assertions — the runner guardrail catches this now, but the failure message ("0 assertions") is noisier than a targeted `skip()` that reports *why* the test couldn't run.
- **Counts instead of stored Variants**. Asserting `track_count == 1` or `child_count > 0` says nothing about the stored value. For mutation tools that take JSON dicts (Color, Vector2, Vector3, keyframe values), read back via `track_get_key_value`, `mi.mesh`, `mat.gravity`, etc. and assert `value is Color` / `value is Vector3`. See "Value coercion" in the "Write tools must be undoable" section above.
- **`get_theme_*` (non-`_override`) getters**. Reading a theme value via `get_theme_color(...)` falls back through the theme chain — a broken `add_theme_color_override` will silently resolve to the default, passing the assertion. Always use `get_theme_color_override`, `get_theme_constant_override`, `get_theme_font_size_override`, `get_theme_stylebox_override` in override tests.
- **`assert_has_key` without a follow-up value check**. Presence of `"data"` in a response says nothing about correctness. Every `assert_has_key(result, "data")` should be paired with at least one `assert_eq` / `assert_true` on a field inside `result.data`.
- **`editor_undo()` / `editor_redo()` without checking the return**. The helper returns `bool` — `false` means the undo silently no-oped. For tests that assert post-undo state, capture `var did_undo := editor_undo(_undo_redo); assert_true(did_undo, "undo should succeed")` before asserting the rolled-back value.
- **Bare `except: pass` in Python tests**. Swallowing exceptions can let a half-failed operation still pass the downstream assertion. Catch specific exceptions, and if you truly want to ignore a cleanup failure, log it.
- **CI scripts that drop `failures[]`**. When a `script/ci-*` parses a `test_run` response, it must iterate `content.get("failures", [])` and print `{suite}.{test}: {message}` on failure — not just the passed/failed counts. The reference pattern is in `script/ci-godot-tests:117-119`.

## Testing against Godot

1. Open `test_project/` in Godot, enable plugin in Project Settings > Plugins
2. Open a scene (e.g. `main.tscn`)
3. Plugin starts the server automatically; logs should show `Session connected`
4. Use `/mcp` in Claude Code to connect

**Worktree gotcha**: each working tree (main checkout or git worktree) has its own
`test_project/addons/godot_ai` symlink pointing to *that tree's* `plugin/`. If you
edit a worktree's plugin but Godot is running on the main repo's `test_project/`,
your changes won't appear there. Use `script/open-godot-here` to launch Godot on the
current working tree's `test_project/`.

## Pre-commit smoke test

**Always do this before every commit.** Python mocks don't catch GDScript bugs, editor API regressions, or undo/redo issues.

1. `ruff check src/ tests/` — lint passes
2. `pytest -v` — all Python tests pass
3. Open `test_project/` in Godot (or launch: `/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path test_project/`)
4. `session_activate` the test_project session if multiple editors are connected
5. `test_run` via MCP — all GDScript tests pass (0 failures)
6. **Live smoke test** new/changed features against the real editor:
   - Call each new tool and verify the response makes sense
   - For write tools: verify the change is visible in the editor, and verify undo works (Ctrl+Z in Godot)
   - For read tools: compare response against what you see in the editor
   - Check `editor_state` to confirm readiness field is present
7. Only commit when all of the above are green

## Client configuration

The plugin auto-configures 18+ MCP clients via a registry + strategy system in
`plugin/addons/godot_ai/clients/`:

- `_base.gd` — `McpClient` descriptor (data only: id, display_name, config_type,
  path_template, server_key_path, entry_url_field, entry_extra_fields,
  entry_uvx_bridge, cli_register_template, cli_status_args, toml_body_template,
  …). Descriptors carry no `Callable` fields and no control flow — strategies
  interpret the data. The `test_descriptors_are_data_only` suite enforces this
  (issue #229: hot-reloaded per-client lambdas raced with worker threads).
- `_registry.gd` — explicit `preload(...)` list of every client. Adding a client
  means: write `clients/<name>.gd` extending `McpClient`, then append one
  preload here. No edits to dock or facade required.
- `_json_strategy.gd` / `_toml_strategy.gd` / `_cli_strategy.gd` — three
  reusable writers, selected by descriptor `config_type`. **No per-client
  branching** inside strategies — non-standard entry shapes are expressed
  declaratively: `entry_url_field` overrides the URL key (Antigravity's
  `serverUrl`, Gemini's `httpUrl`); `entry_extra_fields` adds verbatim keys
  (Roo's `type: streamable-http`, OpenCode's `enabled: true`); `entry_uvx_bridge`
  composes the stdio→HTTP bridge shape for stdio-only clients (Claude Desktop's
  `flat`, Zed's `nested`).
- `_manual_command.gd` — synthesizes the dock's "Run this manually" string
  from the same declarative fields. No per-client builders.
- `_path_template.gd` — expands `~`, `$HOME`, `$APPDATA`, `$XDG_CONFIG_HOME`,
  `$LOCALAPPDATA`, `$USERPROFILE`; picks the right per-OS entry from a
  `{"darwin": ..., "windows": ..., "linux": ...}` (or `"unix"` shorthand) map.
- `_atomic_write.gd` — `.tmp` + rename + `.backup` so a crash mid-write never
  truncates the user's MCP config.
- `_cli_finder.gd` — three-tier lookup (well-known dirs → login shell →
  `which`/`where`) with per-exe caching. Critical for GUI-launched editors
  whose PATH doesn't include `~/.local/bin`, `/opt/homebrew/bin`, etc.

`client_configurator.gd` is a thin facade exposing string-id wrappers
(`configure`, `check_status`, `remove`, `manual_command`, `is_installed`,
`client_ids`, `client_display_name`). It also keeps the server-launch
discovery (`get_server_command`, `find_uvx`, `is_dev_checkout`) since those
are unrelated to client configuration.

MCP tools `client_configure`, `client_remove`, and `client_status` expose this
to AI clients. `client_status` returns `{"clients": [{id, display_name, status,
installed}, …]}`. The dock renders one row per client with a status dot,
Configure/Remove buttons, and a per-row "Run this manually" fallback for cases
when auto-configure can't find a CLI.

## Adding a new tool

1. Add a handler method in the appropriate GDScript `handlers/*.gd` file
2. Register it in `plugin.gd`: `_dispatcher.register("command_name", handler.method)`
3. Add a shared Python handler in `handlers/<domain>.py` that calls `runtime.send_command("command_name", params)`
4. **Decide the MCP tool surface**:
   - **High-traffic verb (top-20)** → register as a named tool in `tools/<domain>.py` with `@mcp.tool(meta=DEFER_META)` (or omit `meta` if it's one of the ~4 always-loaded core tools: `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`). Add `session_id: str = ""` as the last parameter and pass it in: `DirectRuntime.from_context(ctx, session_id=session_id or None)`.
   - **Long-tail verb (default)** → add it to the `ops={}` dict for the existing `register_manage_tool(...)` call. The `<domain>_manage` rollup picks it up automatically; the meta-tool helper handles `session_id` extraction, JSON-string param coercion, and unknown-op error suggestions. No new tool registration needed.
5. Update `tool_catalog.gd` to mirror the new tool list — `tests/unit/test_tool_domains.py` will fail with a paste-over-ready diff if you forget.
6. Update the tool-surface blurb in `server.py` `instructions=` if the new verb is named (rollups are listed by tool, not by op).
7. For write tools: add `require_writable(runtime)` call at the top of the Python handler.
8. Write a description with natural-language keywords a user would search for (e.g. `screenshot`, `keybinding`, `asset`) alongside the Godot term. For ops inside a rollup, edit the `_DESCRIPTION` block of the domain's tool file so the rolled-up tool's docstring stays exhaustive.
9. **Consider a resource form**: pure reads with no `session_id` filtering benefit from a matching `godot://...` resource (or template) in `src/godot_ai/resources/`. The tool form remains for `session_id`-pinned reads; clients that surface resources prefer the URI. When you add a resource form, append `Resource form: godot://...` to the tool's description so aware clients can route reads through the URI.
10. Add tests: handler unit test, Python integration test, AND GDScript test in `test_project/tests/`. Migrate any integration tests for an existing verb when you move it under a rollup — the form changes from `client.call_tool("domain_verb", {...})` to `client.call_tool("domain_manage", {"op": "verb", "params": {...}, "session_id": ...})`.

## Deferred responses (tools whose reply flows out-of-band)

The dispatcher runs handlers synchronously and auto-sends one response per command. For work whose reply arrives over a different channel — currently only `editor_screenshot(source="game")`, which waits on Godot's editor-debugger bus to ferry a PNG back from the game process — use the deferred pattern:

- Return `McpDispatcher.DEFERRED_RESPONSE` (a `{"_deferred": true}` sentinel dict). `tick()` skips auto-sending for these. `_call_handler` recognises it alongside `data` / `error` so the sentinel doesn't trip the malformed-result guard.
- Read the incoming request id from `params["_request_id"]`. The dispatcher injects it on a **duplicated** params dict so the original queued command isn't mutated. Hand it off to whatever async source will produce the reply.
- When the reply arrives, call `Connection.send_deferred_response(request_id, payload)`. `payload` must carry `data` or `error` in the same shape handlers normally return. The method attaches `request_id`, infers `status`, and pushes the JSON over the WebSocket.

This is the only pattern in the plugin that decouples response from handler-return. Reach for it only when the work can't fit in a frame and the reply genuinely has to flow back later (IPC, remote-debugger queries, multi-frame renders). Everything else should stay synchronous.

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

### Auto-create missing dependencies in the same undo action

When a write tool needs a sub-resource that may not exist yet (e.g. `animation_create` needs an `AnimationLibrary` on the AnimationPlayer; `particle_set_process` needs a `ParticleProcessMaterial` on the GPU emitter; `material_assign` with `create_if_missing=true` needs a `Material` on the mesh), do **not** error or do a separate setup write. Bundle the dependency creation into the same `create_action` so a single Ctrl-Z rolls back both:

```gdscript
var library = player.get_animation_library("") if player.has_animation_library("") else null
var created = library == null
if created:
    library = AnimationLibrary.new()

_undo_redo.create_action("MCP: Create animation foo")
if created:
    _undo_redo.add_do_method(player, "add_animation_library", "", library)
    _undo_redo.add_undo_method(player, "remove_animation_library", "")
    _undo_redo.add_do_reference(library)  # keep alive across undo→redo
_undo_redo.add_do_method(library, "add_animation", "foo", anim)
_undo_redo.add_undo_method(library, "remove_animation", "foo")
_undo_redo.add_do_reference(anim)
_undo_redo.commit_action()
```

Surface a `<dependency>_created: bool` field in the response so callers (and tests) can confirm the auto-creation actually happened. See `animation_handler.gd:create_animation`, `material_handler.gd:assign_material` (auto-creates a default material when `create_if_missing=true`), and `particle_handler.gd:create_particle` / `set_process` / `set_draw_pass_gpu_3d` for worked examples. The draw-pass handler also grows `draw_passes` when the target `draw_pass_N` slot doesn't exist yet — Godot only exposes `draw_pass_N` as a live property once the count is ≥ N, and naive `add_do_property` on a ghost slot silently no-ops.

### Value coercion: assert on the stored Variant, not on counts

JSON dicts like `{"r":1,"g":0,"b":0,"a":1}` only become `Color` / `Vector2` / `Vector3` if the coercer finds a matching property on the target node and that property's `TYPE_*` is in the coerce table. If the property is missing (wrong scene root type) or the type isn't handled, the raw dict is silently stored as the keyframe value and Godot plays garbage at runtime.

GDScript tests that just assert `track_count == 1` will pass even when coercion is broken. **Always read back via `track_get_key_value(idx, k)` and assert `value is Color` / `value is Vector3` / etc.** `test_animation.gd` `test_add_property_track_coerces_vector3_dict` is the reference pattern. The same rule applies to any future handler that takes JSON values intended to land as typed Variants in the scene.

Same principle for theme override pseudo-properties on Controls: use `get_theme_color_override`, `get_theme_constant_override`, `get_theme_font_size_override`, `get_theme_stylebox_override` in tests — **not** the fallback `get_theme_color` getters — so a broken override silently resolving via the theme fallback can't mask a bug. `test_ui.gd` `test_build_layout_theme_override_*` are the reference pattern.

### Auto-generated indices: look up at undo time, not do time

When a write tool mutates a resource whose index is assigned by Godot (`Animation.add_track` returns an int index, same for track keys, `MultiMesh.instance_count`, etc.), do **not** capture that index at do time and reuse it in the undo callable. Any other mutation landing between the do and the undo makes the index stale — the undo will then remove the wrong element (or error).

Instead, undo via a helper that resolves the index at undo time via a stable lookup:

```gdscript
_undo_redo.add_undo_method(self, "_undo_remove_track_by_path", anim, track_path, Animation.TYPE_VALUE)

func _undo_remove_track_by_path(anim: Animation, path: String, type: int) -> void:
    var idx := anim.find_track(NodePath(path), type)
    if idx >= 0:
        anim.remove_track(idx)
```

See `animation_handler.gd::_undo_remove_track_by_path` for the reference pattern. Cover with a test that interleaves a second mutation between the do and undo of the first (`test_animation.gd::test_add_property_track_undo_survives_interleaving`).

### Scene instancing: use GEN_EDIT_STATE_INSTANCE

When a tool instantiates a PackedScene into the edited scene, pass `PackedScene.GEN_EDIT_STATE_INSTANCE` to `instantiate()`:

```gdscript
new_node = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
```

This makes Godot treat the result as a real scene instance: the root shows the foldout icon, the `.tscn` stores a reference to the sub-scene rather than an exploded subtree, and the instance can be swapped or toggled editable via the usual editor UI. Don't manually set descendant owners to your scene_root — descendants of a scene instance stay owned by their sub-scene; overriding that breaks the instance link. See `node_handler.gd::create_node`.

## Test coverage

100% code coverage for core features, always. Every tool, handler, and protocol path must have both:
- **Python tests** (`tests/unit/` and `tests/integration/`): protocol, WebSocket, client logic
- **Godot-side tests** (`test_project/tests/`): handlers exercised against the live editor

New features don't ship without tests. Regressions are caught before they merge.

## Known issues

- **Re-entrant `_process()` during save**: `EditorInterface.save_scene()` internally renders a preview thumbnail, which triggers frame processing. If `Connection._process()` runs during this, WebSocket polling and command dispatch re-enter, crashing Godot (`SIGABRT` in `_save_scene_with_preview`). Fixed by setting `Connection.pause_processing = true` around save calls in `SceneHandler`. Any new handler that calls `save_scene()`, `save_scene_as()`, `save_all_scenes()`, or `play_main_scene()` / `play_current_scene()` / `play_custom_scene()` (which internally call `try_autosave()` → `_save_scene_with_preview`) must do the same. `ProjectHandler.run_project` is the reference for the play path.
- **GDScript tests must not call `EditorInterface.save_scene()` or `scene_create`/`scene_open`**: These trigger modal dialogs or scene switches that freeze or crash the test runner. Test only validation/error paths for these operations in GDScript; full behavior is covered by Python integration tests.
- **GDScript tests must not call `quit_editor` or `reload_plugin`**: These terminate or restart the plugin, killing the test runner. Tested via Python integration tests and CI smoke scripts (`script/ci-quit-test`, `script/ci-reload-test`). (Note: plugin command names stay `quit_editor` / `reload_plugin`; the MCP tool names are `editor_quit` / `editor_reload_plugin`.)
- **Resilient test discovery**: `_discover_suites()` in `test_handler.gd` catches per-file load errors and returns `{suites, errors}`. Individual broken test scripts do not prevent the rest from running. The `errors` list reports which scripts failed to load.
- **CI GDScript validation**: `script/ci-check-gdscript` runs before Godot tests in CI. It scans the `--import` log for `SCRIPT ERROR` / `Parse Error` lines and fails the build early if any GDScript has syntax errors, before the test runner even starts.
- **CI Linux runner**: Linux Godot CI uses `chickensoft-games/setup-godot@v2` on `ubuntu-latest` (not a Docker image). All three OS jobs (Linux, macOS, Windows) use the same chickensoft action for consistent Godot setup. Step timeouts are set on test and smoke steps to prevent CI hangs.
- **Sleep before test_run in CI**: `script/ci-godot-tests` includes a short sleep (8s) after Godot startup to let the editor filesystem scan settle before running tests. Without this, test discovery can miss files.

## What NOT to do

- Don't call `EditorInterface` methods from WebSocket callbacks — always queue
- Don't cache `get_edited_scene_root()` across frames — it changes on scene switch
- Don't use `pop_front()` on arrays in hot paths — use index + slice
- Don't add error handling in individual tools — `GodotClient.send()` raises on errors
- Don't use Python-style `"""docstrings"""` in GDScript — use `##` comments
- Don't write GDScript tests that `return` without asserting — the runner flags these as failures. Use `skip("reason")` for unmet environmental preconditions, or `assert_true(false, "reason")` when setup that should have worked failed. See "Test hygiene checklist" above
- Don't forget the `overwrite` parameter on `animation_create` / `animation_create_simple` — without it, creating an animation with the same name errors instead of replacing
