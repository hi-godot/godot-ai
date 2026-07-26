# AGENTS.md - Godot AI

This guide is for any AI assistant working in this repository. Keep Claude-specific files such as `CLAUDE.md` and `.claude/skills/*` as thin pointers to this shared guidance.

## What this project is

A production-grade MCP server for Godot. Python server (FastMCP v3) communicates over WebSocket with a GDScript editor plugin. AI clients call MCP tools → Python routes commands → Godot plugin executes against the editor API → results flow back.

## Architecture

- **Protocol**: JSON over WebSocket. Request/response with `request_id` correlation. Handshake on connect.
- **WS trust boundary**: the editor↔server WebSocket (port 9500) is **effectively unauthenticated** — the primary control is loopback-only binding: the WS port always binds `127.0.0.1` and `--allow-host` deliberately does NOT widen it (see `transport/websocket.py::start`). Defense in depth on top of that: unguessable `uuid4` request ids, session-scoped response correlation (a reply is only accepted from the connection its command was sent to — #690), and a compat-gated per-launch handshake token (#690 finding 4): the spawning plugin generates it, hands it to the server via the `GODOT_AI_WS_TOKEN` spawn env, and echoes it in the handshake; a handshake carrying a *wrong* token is rejected, but a token-less handshake is still accepted (older plugins, adopted servers, and the field is attacker-omittable — so the token is hardening, not an authentication boundary). Never bind the WS port beyond loopback. **The token authenticates the plugin TO the server, and nothing authenticates the server to the plugin**: `connection.gd` dials `ws://127.0.0.1:<ws_port>` and hands whatever answers the full write surface (`filesystem_write_text`, `script_create`, `game_eval`, `editor_quit`), adoption of an existing `:8000` listener is decided by a *self-reported* status JSON, and `_note_post_open_close` drops the token entirely after two close-4003 frames (an attacker-triggerable downgrade, deliberately accepted because omitting the field is always allowed anyway). Loopback binding is the whole boundary on the plugin side — do not add plugin-side logic that assumes the peer on 9500 is trusted.
- **Session model**: Multiple Godot editors can connect. Tools route through active session.
- **Handler/Runtime layer**: Shared handlers in `src/godot_ai/handlers/` contain tool logic. They depend on `DirectRuntime`, the in-process runtime adapter. Tools and resources are thin wrappers that create a runtime and delegate.
- **Readiness gating**: Write operations check session readiness (`ready`/`importing`/`playing`/`no_scene`) before executing. Plugin sends readiness in handshake and via `readiness_changed` events. Python `await require_writable_async()` in `handlers/_readiness.py` gates all write handlers; new write handlers must `await` it. Two layers self-heal a stale cache so a missed `readiness_changed` event can't strand an agent in `EDITOR_NOT_READY` against a writable editor: (1) every command response carries an envelope-level `readiness` field stamped by the plugin's dispatcher, piped through `sync_readiness_for_session` in the WebSocket transport — so the very next tool call after any state change refreshes the cache; (2) `require_writable_async` itself fires one `get_editor_state` probe before rejecting on a non-writable cached value, so the FIRST post-staleness call (which has no prior response to self-heal from) also recovers. Fast path (cache says writable) skips the probe — zero added latency in the common case. Any new plugin response builder (success, error, deferred reply, backpressure error) must include the envelope field; old plugins that omit it fall back to the event-driven path. Every `EDITOR_NOT_READY` emission carries `data.sub_code` naming the concrete editor state (`EDITOR_IMPORTING`, `EDITOR_PLAYING`, `EDITOR_NO_SCENE`, …) plus `retryable`/`hint` (#651 stage 1) — the top-level code is frozen (dashboards key on it), so never promote a sub-code to `error.code`. When the probe live-confirms `importing`, the gate holds the write and re-probes (~500ms interval, ~8s cap — telemetry-tuned constants in `_readiness.py`) instead of rejecting, since most import windows clear within seconds; past the cap it raises exactly the pre-hold error (#651 stage 2). The hold is importing-only — `playing` and every other blocking state stay fail-fast, and per-tool retry loops must not be added on top. GDScript emitters use `ErrorCodes.make_not_ready`; the sub-code vocabulary lives in `utils/error_codes.gd` (`SUB_*`) and `protocol/errors.py` (`EditorNotReadySubCode`), kept in sync by `tests/unit/test_editor_not_ready_hint_contract.py`. Only add a sub-code for a state the editor can report deterministically; undetectable busy states stay bare `EDITOR_NOT_READY`.

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
- **Class naming**: classes that need a project-wide `class_name` (i.e. used as a type annotation across multiple files) carry the `Mcp*` prefix to avoid colliding with user-project classes. Internals only used inside the plugin (handlers, presets/values, test stubs) skip `class_name` entirely and load via `const X := preload("res://addons/godot_ai/...")` from their consumers — except handlers, which `plugin.gd` deliberately does NOT preload: they register by script path via `McpDispatcher.register_lazy_handler` / `register_lazy` and are `load()`ed at first dispatch, keeping the boot-time compile closure small (#736). Do not add a bare-name `class_name` for a new class — pick `Mcp*` or `preload`. The choice of `Mcp*` vs preload-only is stylistic, not a parse-safety measure; the #398 self-update parse-error class is fixed at the runner by writing one consistent snapshot before scan, and both forms are parse-safe across upgrades from the fixed release onward.
- **Never delete a published `class_name` declaration**: removing `class_name X` from a class that was registered in any prior released version can trigger a "Could not resolve script" cascade during the self-update disable -> extract -> enable window. This is independent of the runner's single-phase install ordering. If a class_name must be retired, leave the original file path and `class_name` in place as a compatibility shim.
- **MCP logging**: Plugin prints `MCP | [recv] command(params)` / `MCP | [send] command -> ok` to Godot console. Controlled by the dock's "Log" toggle, persisted via EditorSetting `godot_ai/mcp_logging` (routes to the dispatcher `mcp_logging` var and `McpLogBuffer.enabled` console echo). High-frequency `[event] readiness -> ...` lines record to the ring buffer only (`log(msg, echo=false)`) and never echo to the console (#626).
- **Tool surface — ~18 named verbs + per-domain `<domain>_manage` rollups**: To stay under hard tool-count caps in clients that ignore Anthropic's `defer_loading` (Antigravity, etc.), each domain exposes one rolled-up MCP tool that takes `op="<verb>"` + a `params` dict, alongside the high-traffic verbs as named tools. Schema-aware clients still see every `op` because `register_manage_tool` in `src/godot_ai/tools/_meta_tool.py` builds a dynamic `Literal[...]` enum. Core tools (`editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`) stay non-deferred; named non-core verbs and every `<domain>_manage` rollup are tagged `meta={"defer_loading": True}` for tool-search-aware clients. Plugin command names (over WebSocket) are independent — the MCP tool `editor_reload_plugin` dispatches the plugin command `reload_plugin`. See `docs/TOOLS.md` for the full op map.
- **Tool resources alongside tools**: Read-only `godot://...` URIs mirror the most-used reads (`godot://node/{path}/properties`, `godot://script/{path}`, `godot://materials`, …). Resources don't count against tool caps; tool forms are the fallback for clients that don't surface resources, and the only path that supports per-call `session_id` pinning. When a tool has a resource counterpart, its description appends `Resource form: godot://...` so aware clients can route the cheap reads through the URI.
- **`batch_execute` uses plugin command names, not MCP tool names**: The MCP tool `node_create` dispatches the plugin command `create_node`. Inside `batch_execute`'s `commands[].command` field, use the plugin name (`create_node`), not the MCP name (`node_create`). Inside a `<domain>_manage` op, the same rule applies — `node_manage(op="delete", params={...})` delegates to the plugin's `delete_node`, not `node_delete`. The Python handlers in `src/godot_ai/handlers/` are the authoritative map — each handler calls `runtime.send_command("<plugin_cmd>", ...)`. When `batch_execute` receives an unknown plugin command, the GDScript batch handler returns `UNKNOWN_COMMAND` with fuzzy `data.suggestions`. Inside a `<domain>_manage` rollup, op-name validation happens earlier — at the FastMCP/Pydantic schema boundary, since `op` is typed `Literal[...]` of the registered op names. A misspelling like `theme_manage(op="set_colour")` surfaces as a Pydantic `literal_error` whose message lists the valid alternatives ("Input should be 'create', 'set_color', …"), not a structured `data.suggestions` payload. The meta-tool's own `difflib`-based fallback in `dispatch_manage_op` only fires when the call somehow bypasses Pydantic (e.g. a future internal direct-dispatch caller).
- **Session IDs**: format is `<project-slug>@<4hex>` (e.g. `godot-ai@a3f2`). The slug is derived from the project directory name so agents can recognize which editor they're targeting; the hex suffix disambiguates same-project twins. Server treats the ID as an opaque key.
- **Per-call session routing**: every Godot-talking tool accepts an optional `session_id` parameter. Empty (the default) resolves to the global active session. When supplied, that single call targets that session — `require_writable` and every handler inside the call see the pinned session, not the active one. Use this when multiple AI clients share one MCP server. For `<domain>_manage` rollups, `session_id` is a sibling of `op` and `params` (top-level), *not* nested inside `params`. Resources (`godot://...`) still resolve via the active session.
- **FastMCP middleware order is load-bearing**: `src/godot_ai/server.py` registers, in this order, `PreserveGodotCommandErrorData → StripClientWrapperKwargs → ParseStringifiedParams → FoldFlatManageParams → HintOpTypoOnManage`. FastMCP composes the chain via `reversed(self.middleware)`, so first-added is **outermost** (sees response last) and last-added is **innermost** (sees response first). The five positions are reasoned out in the docstring above the `mcp.add_middleware(...)` calls in `server.py`; the order is locked by `tests/unit/test_server_middleware_order.py`. Adding new middleware: read that docstring, decide the position, update both the docstring and the test in lockstep.
- **Telemetry is wrap-once at server build time**: `src/godot_ai/server.py` calls `install_fastmcp_wraps(mcp)` right after constructing the FastMCP instance and before any `register_<domain>_tools(mcp)`. That call replaces `mcp.tool` / `mcp.resource` with auto-instrumenting versions, so every tool and resource (including the `<domain>_manage` rollups, whose `op` arg is captured as `sub_action`) gets one `tool_execution` / `resource_retrieval` record per call automatically. Adding a new tool, resource, or rollup op needs **no telemetry call**. Opt-out is `GODOT_AI_DISABLE_TELEMETRY=true` (also accepts `DISABLE_TELEMETRY=true`). The endpoint is configured via `GODOT_AI_TELEMETRY_ENDPOINT`; if unset, a baked-in production default endpoint is used, so telemetry sends by default — the only way to prevent sends is the opt-out env var. Session-id slugs are sha256-hashed before leaving the process so project directory names don't leak. Plugin-side events (dock startup, self-update outcome) ride the existing `send_event("plugin_event", …)` channel; the names allowlist lives in both `plugin/addons/godot_ai/telemetry.gd` and `src/godot_ai/transport/websocket.py::_PLUGIN_EVENT_NAMES` — keep them in sync. Full reference: `docs/TELEMETRY.md`.

### Published `class_name` compatibility

Treat a shipped `class_name` as compatibility surface for self-update. v2.4.0 -> v2.4.1 reproduced a 500+ error cascade when `class_name McpErrorCodes` was dropped; v2.4.2 restored it. Single-phase install fixes mixed-snapshot parse errors, but it does not make deleting a previously registered class safe.

If a `class_name` needs to become a shim, keep the original file path and declaration:

- Inheritance-shaped classes can usually `extends "res://addons/godot_ai/.../impl_file.gd"`.
- Static-constants/static-method classes need explicit forwarding or duplicated constants; `extends` does not surface static members through class-name lookup.
- Mixed classes should either keep the implementation in the original file or hand-write a shim that preserves every published static and instance shape.

Practical rule: keeping the implementation in the original class_name file is usually simpler and safer than retiring it. If a class truly becomes obsolete, leave a no-op `class_name` stub in place so older projects can pass through the self-update window cleanly.

## Worktrees

Assistant sessions may run in git worktrees. Claude Code commonly uses `.claude/worktrees/<name>/`. Be aware of which worktree you're in — it affects everything:

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

Wiring: `script/setup-dev` and `script/setup-dev.ps1` copy `script/githooks/post-checkout` into `.git/hooks/post-checkout` (the default path git always looks at). `.git/hooks/` is shared across all worktrees of a clone, so one install covers every future worktree forever. A fresh clone on a new machine needs setup-dev run once before the hook is active — after that, it's automatic. (We don't use `core.hooksPath=script/githooks` because git resolves that relative path against main's working tree, which may be on a branch without `script/githooks/` — a trap that wasted a whole debugging cycle.)

**If you find a broken worktree** (empty `plugin/`, or the link missing/stale): do NOT `git add` anything. Run `script/verify-worktree` to heal, or re-create the worktree. Committing plugin/ edits from a broken worktree stages phantom deletions that overwrite the canonical plugin code in main on push.

**Parallel plugin development IS supported** — each worktree has its own `plugin/` (standard git worktree semantics) and its own locally-built `test_project/addons/godot_ai` link. Multiple Godot editors, one per worktree, all connect to the same MCP server on :8000; use `session_activate` (or `session_id` per call) to route. The ban is only on editing in *broken* worktrees.

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

### Server lifecycle in dev

The plugin manages the server process:
- On startup, plugin checks if port 8000 is already in use. If yes, uses existing server. If no, spawns `.venv/bin/python -m godot_ai --transport streamable-http --port 8000`.
- The plugin prefers the local `.venv` over system-installed `godot-ai` so dev checkouts always use source code.
- **External adoption does not transfer process ownership**: when the plugin adopts an externally started server (CI's `script/ci-start-server`, a hand-started dev server, or an attach-owned backend), `server_lifecycle.gd::adopt_compatible_server` sets `_server_pid = -1` and clears the managed record/pid file. Normal editor teardown therefore has no PID authority to kill and leaves that external server running. Plugin-spawned servers remain managed and follow their normal stop/`keep_server_on_exit` policy. Status fields such as `owner_type` are diagnostic only and never sufficient kill proof.
- **Bridge leases bound crash survival for plugin-spawned servers**: the Python owner-PID watchdog and idle backstop both defer shutdown while an attach bridge holds a live lease. A plugin-spawned backend can therefore outlive a crashed editor until its last client lease expires, extending the same tokenless-loopback trust window as `keep_server_on_exit`, but only for the lease TTL. That bound depends on the lease registry refusing to grow without limit: the `/godot-ai/lease/*` routes are loopback-guarded but **not authenticated**, and the `instance_id` they require is published by the unauthenticated `/godot-ai/status` probe, so any local process can register. `LeaseRegistry` therefore caps concurrent leases (`DEFAULT_MAX_ACTIVE_LEASES`, 429 `LEASE_LIMIT_EXCEEDED` past it) and prunes through an expiry heap rather than a full scan — the old full-dict scan ran on every register/heartbeat/release/`active_count`, so N registrations cost O(N²) CPU *on the event loop serving all MCP traffic*. Keep both properties: a bridge holds exactly one lease, so neither constrains real use. This does not yet cover a normal editor exit: the GDScript `_exit_tree` path still stops a plugin-managed backend without consulting leases, so that clean-exit case churns the backend and is tracked separately from #822.
- **Attach response-stream limitation**: the bridge deliberately has no post-dispatch read deadline. A same-instance network stream loss, or a server-side request task that dies without producing a response, can therefore wait until the MCP client cancels the call. FastMCP 3.0 exposes `event_store`, but the real cut-and-resume flow hangs at that supported floor (while working on 3.4), so resumability remains a compatibility follow-up rather than a version-dependent feature. Cancellation is cleanup-safe and never replays an ambiguously dispatched mutation.
- **Attach runtime files**: `godot-ai attach` keeps its per-port advisory lock and backend log in a private per-user runtime directory. Override it with `GODOT_AI_RUNTIME_DIR`; otherwise Windows uses `%LOCALAPPDATA%\godot-ai\runtime`, POSIX uses `$XDG_RUNTIME_DIR/godot-ai` when available, and the final fallback is a user-specific temporary directory. On POSIX the selected directory is rejected if it is a symlink, is not owned by the current user, or cannot be enforced as mode 0700; the predictable `/tmp` fallback is therefore not vulnerable to another user's pre-created directory or log-target symlink. A backend crash-loop diagnostic points to `backend-<HTTP-port>.log` there; each spawn retains one previous generation as `.old`. Future client-config rollout must pass the same `--exclude-domains` selection used by the plugin; differing exclusions intentionally fail compatibility with `NEW_CLIENT_SESSION_REQUIRED` rather than replacing the running backend.
- In `--headless` / headless-display launches, the plugin returns early and does not start/adopt the server, open a WebSocket, add the dock, attach loggers, register the debugger plugin, instantiate handlers, or write the game-helper autoload. Set `GODOT_AI_ALLOW_HEADLESS=1` only for intentional headless MCP sessions such as CI handler tests.

For Python auto-reload during dev (no need to touch Godot):
```bash
python -m godot_ai --transport streamable-http --port 8000 --reload
```
This uses `src/godot_ai/asgi.py` to run uvicorn with its factory reload path. Uvicorn watches `src/` for changes and restarts the server process automatically. The plugin auto-reconnects.

### Server discovery (3-tier)

1. `.venv/bin/python -m godot_ai` — dev checkout (venv near project)
2. `uvx --from godot-ai==VERSION godot-ai` — user install (PyPI via uvx, exact version pin)
3. `godot-ai` CLI — system install fallback

### Plugin reload

The `editor_reload_plugin` MCP tool triggers a live plugin reload inside Godot (`EditorInterface.set_plugin_enabled` off/on). It works with both an externally-run server and the plugin-managed server (the handler special-cases the plugin-managed path, where the reload tears down and respawns the server process). The Python handler waits for the new session via `SessionRegistry.wait_for_session()`.

The Godot dock also has a **Start/Stop Dev Server** button for convenience (visible in developer mode).

### Releasing

Use the GitHub Actions workflow to cut a release:
```bash
gh workflow run bump-and-release.yml -f bump=patch   # or minor / major
```
This bumps `plugin.cfg` + `pyproject.toml`, commits, tags, and pushes. The `release.yml` workflow triggers on the tag and builds a `godot-ai-plugin.zip` attached to the GitHub Release.

### Self-update

The dock checks the GitHub releases API on startup. If a newer version exists, a yellow banner appears with an "Update" button that downloads the release ZIP, hands off to `update_reload_runner.gd`, disables the old plugin, extracts over the current `addons/godot_ai/`, waits for Godot's filesystem scan, and enables a fresh plugin instance. There must be no manual editor restart and no programmatic `OS.create_process` + `quit` restart in this path.

The server process is intentionally prepared for reload, not left untouched: `prepare_for_update_reload()` stops the managed server and resets the spawn guard so the re-enabled plugin starts or adopts the correct server for the new plugin version.

In dev checkouts the check is skipped: `is_dev_checkout()` detects a nearby `.venv` and short-circuits to avoid offering a path that would overwrite tracked source (the addons dir is a symlink into `plugin/`). Three override knobs let you exercise the update flow without leaving the repo (resolved in priority order):

1. **EditorSetting `godot_ai/mode_override`** — set it manually via Editor > Editor Settings (there is currently no dock UI that writes it). Values: empty/absent (auto) / `user` / `dev`, read by `client_configurator.gd::mode_override()`.
2. **`GODOT_AI_MODE` env var** — fallback for CLI launches and CI. Values: `user` / `dev`. Only takes effect when the EditorSetting is unset (the setting always wins).
3. Neither set → the `.venv`-proximity heuristic runs as before.

When either override reports `user`, the yellow update banner's label includes `(forced)` (the `forced` hint in `update_manager.gd`'s banner payload) so testers don't forget they're in override mode.

`_install_update` keeps a physical data-safety guard (`addons_dir_is_symlink()`) independent of the mode override: even in forced-user mode the self-install bails if `res://addons/godot_ai` is a symlink. To actually test the end-to-end extract path, unpack a release zip over a plain-directory copy of the addons dir (or test from a standalone project outside the dev tree).

For self-update changes, run the local interactive smoke harness:

```bash
script/local-self-update-smoke
```

For runner-ordering changes, the current-as-base form above is the forward
regression check: it proves the runner shipped in this branch can upgrade to a
future zip without parse errors. A base from a pre-fix release is a historical
constraint case: its old installed runner may still print transient parse
errors during that one upgrade, and PRs in the new version cannot retroactively
change that runner.

Until old two-phase runners have aged out, release shape matters for the next
upgrade those users take: avoid adding new files that reference constants,
methods, or static/non-static shape changes added to existing load-surface
scripts in the same release. This applies to both `class_name` scripts and
preload-only scripts because the failure mode is stale Script-object content,
not just class registry skew.

Agent trigger: this smoke is required whenever a change touches any of these areas:

- `mcp_dock.gd` update check/download/install paths
- `update_reload_runner.gd`
- `plugin.gd` plugin disable/enable, dock detach, or update handoff paths
- server reload prep around `prepare_for_update_reload()`
- release ZIP layout or install/extract behavior

The harness creates a disposable project with a physical addon copy, stages a synthetic v(N+1) ZIP that adds a new typed Dict/Array field read from `_exit_tree`, forces the Update banner to use that local ZIP, records the macOS DiagnosticReports baseline, and launches Godot. The only operator action is to click Update in the dock. Passing means the editor stays alive without restart, the plugin version advances, `user://godot_ai_update/` is consumed, no new Godot `.ips` appears, and the vNext `_exit_tree` trigger does not print during the update window.

## Testing

### Python tests
```bash
pytest -v                    # ~1300 unit + integration tests
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

### Stress / load testing — `script/stormtest.py`

`stormtest` opens many concurrent MCP clients and fires rapid, randomized tool calls across most tool domains at a live editor, with periodic `editor_reload_plugin` churn mixed in. It's a robustness test, not a correctness test: it answers "does the editor + plugin + WebSocket dispatcher + server survive sustained concurrent abuse and reload cycles without crashing?" and surfaces per-tool latency/error hot-spots. Use it after changes to the dispatcher, transport, readiness gating, session routing, or the reload/handoff path. Full reference: `docs/STRESS_TESTING.md`.

```bash
.venv/bin/python script/stormtest.py                       # ≈ 1000 calls, with reload churn
SS_WORKERS=12 SS_WAVES=30 .venv/bin/python script/stormtest.py   # brutal ≈ 9000 calls
SS_RELOAD=0 .venv/bin/python script/stormtest.py           # reads-only smoke, no reloads
SS_URL=http://127.0.0.1:8010/mcp .venv/bin/python script/stormtest.py  # target another stack
```

To stress a *branch's* code (plugin + server), point a Godot editor at that worktree's `test_project/` and serve its `src/` via `script/serve-this-worktree` (external server, so `editor_reload_plugin` exercises reload without killing the server), then run stormtest against it. A full JSON snapshot lands in `$TMPDIR/stormtest_report.json` (override with `SS_REPORT`), flushed every few seconds so a crash/kill still leaves data. A small `EDITOR_NOT_READY` / `NODE_NOT_FOUND` / `CONNECTION` error rate is expected noise under concurrency + reloads — watch instead for the process dying, a reload that never recovers, or one op with pathological error/latency.

On Windows, a reads-dominant run (`SS_RELOAD=0`) works, but **reload churn (`SS_RELOAD=1`, the default) currently wedges the harness**. `script/serve-this-worktree.ps1` provides the external-server flow on Windows (thin wrapper over the cross-platform `script/serve_worktree.py`, see #509/#514). The editor itself survives reloads — only the harness hangs. Use `.venv\Scripts\python.exe` and note `$TMPDIR` is `%TEMP%`. See the "Windows / cross-platform notes" callout in `docs/STRESS_TESTING.md` (issues #513 / #514; resilience tracked in #509).

**Guardrails built into the test runner:**
- **Zero-assertion detection**: Tests that complete with 0 assertions are flagged as failures ("Test completed with 0 assertions — likely skipped its logic"). This catches tests that silently `return` before asserting anything.
- **Resilient discovery**: If a `.gd` file fails to load (parse error, duplicate method, wrong base class), the rest of the suites still run and the failing files are reported in `load_errors`.
- **Suite isolation**: Each suite gets a fresh `ctx.duplicate()` so `suite_setup()` mutations can't leak to the next suite.

### Test hygiene checklist — common silent-failure patterns to avoid

A test that passes for the wrong reason is worse than a missing test: it ships a regression under a green check. Watch for these masking patterns when writing or reviewing tests:

- **Bare `return` in a test body**. Every `return` in a `test_*` function must be preceded by either an `assert_*` call (for a real failure) or `skip("reason")` (for an environment precondition that can't be met). A silent `return` passes with zero assertions — the runner guardrail catches this now, but the failure message ("0 assertions") is noisier than a targeted `skip()` that reports *why* the test couldn't run.
- **Counts instead of stored Variants**. Asserting `track_count == 1` or `child_count > 0` says nothing about the stored value. For mutation tools that take JSON dicts (Color, Vector2, Vector3, keyframe values), read back via `track_get_key_value`, `mi.mesh`, `mat.gravity`, etc. and assert `value is Color` / `value is Vector3`. See "Value coercion" in the "Write tools must be undoable" section above.
- **Bare `get_theme_*` getters in override tests**. Reading a theme value via `get_theme_color(...)` alone falls back through the theme chain — a broken `add_theme_color_override` will silently resolve to the default, passing the assertion. Godot 4.6 removed the `get_theme_*_override` getters, so the honest pattern is now: assert `has_theme_color_override(...)` (or the constant/font-size/stylebox variant) FIRST, then read the value with the regular getter — the override presence check is what prevents the fallback from masking a bug. `test_ui.gd::test_build_layout_theme_override_*` are the reference pattern.
- **`assert_has_key` without a follow-up value check**. Presence of `"data"` in a response says nothing about correctness. Every `assert_has_key(result, "data")` should be paired with at least one `assert_eq` / `assert_true` on a field inside `result.data`.
- **`editor_undo()` / `editor_redo()` without checking the return**. The helper returns `bool` — `false` means the undo silently no-oped. For tests that assert post-undo state, capture `var did_undo := editor_undo(_undo_redo); assert_true(did_undo, "undo should succeed")` before asserting the rolled-back value.
- **Bare `except: pass` in Python tests**. Swallowing exceptions can let a half-failed operation still pass the downstream assertion. Catch specific exceptions, and if you truly want to ignore a cleanup failure, log it.
- **CI scripts that drop `failures[]`**. When a `script/ci-*` parses a `test_run` response, it must iterate `content.get("failures", [])` and print `{suite}.{test}: {message}` on failure — not just the passed/failed counts. The reference pattern is in `script/ci-godot-tests:117-119`.
- **Version-gated skips**. For a test that depends on future newer-engine behavior, call `if skip_on_godot_lt("4.6", "reason"): return` at the top (`McpTestSuite.skip_on_godot_lt` returns `bool`). CI runs a Godot 4.5 Linux canary (`Godot tests / Linux (Godot 4.5)`, pinned to `4.5.0`) in addition to the three 4.7.0 OS rows so the documented floor catches parse-cascade regressions. `ci-check-gdscript` is strict on every supported version; Logger-backed scripts are parsed normally now.

## Testing against Godot

1. Open `test_project/` in Godot, enable plugin in Project Settings > Plugins
2. Open a scene (e.g. `main.tscn`)
3. Plugin starts the server automatically; logs should show `Session connected`
4. Use your MCP client's server connection flow to connect (for example, `/mcp` in Claude Code)

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
7. If the change touches self-update, plugin reload handoff, or install/extract logic, run `script/local-self-update-smoke` and click Update in the launched fixture.
8. Only commit when all of the above are green

## Client configuration

The plugin auto-configures 19+ MCP clients via a registry + strategy system in
`plugin/addons/godot_ai/clients/`. Read that directory for the mechanics; two
rules are not visible in the code:

- **Descriptors are data only** — no `Callable` fields, no control flow. Strategies
  interpret the data. `test_descriptors_are_data_only` enforces this (issue #229:
  hot-reloaded per-client lambdas raced with worker threads).
- **No per-client branching inside strategies.** Non-standard entry shapes are
  expressed declaratively on the descriptor (`entry_url_field`, `entry_extra_fields`,
  `entry_uvx_bridge`). Adding a client means exactly two things: write
  `clients/<name>.gd` extending `McpClient`, then append one `preload` to
  `_registry.gd`. No edits to the dock, the facade, or the strategies.

MCP tools `client_configure`, `client_remove`, and `client_status` expose this to
AI clients.


## Tool-search friendliness + tool-count caps

The MCP tool surface is shaped to satisfy two pressures at once:

1. **Anthropic tool-search clients** (`tool_search_tool_bm25_20251119` / `tool_search_tool_regex_20251119`) — non-core tools are tagged `meta={"defer_loading": True}` so the client only loads schemas it searches for.
2. **Tool-count caps in non-search clients** (Antigravity, etc., that ignore `defer_loading` and refuse to start past ~40 tools) — long-tail verbs collapse into per-domain `<domain>_manage` rollups (`op="<verb>"` + `params` dict). Schema-aware clients still see every op via the dynamic `Literal[...]` enum built by `register_manage_tool` in `tools/_meta_tool.py`.

Result: ~43 MCP tools (4 core + 15 named verbs + 24 rollups), down from a flat surface that crossed 100. Plugin command names over WebSocket stay independent — they're documented in `tool_catalog.gd` and unchanged by the rollup refactor.

- All tools follow `domain_action` namespacing — no ambiguous prefixes
- Core tools loaded upfront (no `meta=`): `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`
- Descriptions include natural-language keywords users would search for (e.g. "screenshot", "keybinding", "asset", "event / callback") so tool-search BM25 hits them
- `server.py` `instructions=` includes a tool categories blurb listing the rollup map, so tool-search clients have a discovery map without reading every schema
- Read-only `godot://...` resources mirror the cheap reads (`godot://editor/state`, `godot://node/{path}/properties`, `godot://script/{path}`, etc.) — they don't count against the tool cap, and aware clients prefer them. Tool form remains for `session_id`-pinned reads.

For tool-capped clients without tool-search support, the server accepts `--exclude-domains audio,particle,...` (CLI flag and `EditorSettings`-backed dock UI) to drop entire domains' rollups and named tools while keeping the core 4 alive.

When adding a new verb, prefer adding it as an op on the domain's existing `register_manage_tool(...)` call rather than registering a new top-level tool — only the highest-traffic verbs warrant a named tool (see "Adding a new tool" below).

## Tool inventory sources

Do not maintain a full tool inventory in this guide. The active inventory has canonical sources:

- `src/godot_ai/tools/domains.py` defines the domain metadata used by Python registration.
- `plugin/addons/godot_ai/tool_catalog.gd` mirrors the registered tool surface for the Godot dock.
- `tests/unit/test_tool_domains.py` verifies the GDScript catalog stays in sync with the Python registrations and prints a paste-over-ready diff when it drifts.
- `docs/TOOLS.md` is the human-facing reference for the full current tool/resource list and op map.

Use those sources when you need the current inventory. Keep this guide focused on the rules for changing the tool surface so it does not become another stale hand-maintained list.

## Plugin command vs MCP tool names

The plugin (GDScript) uses short command names over WebSocket (`run_tests`, `reload_plugin`, `reimport`, `set_selection`, `search_filesystem`, `get_performance_monitors`, `create_node`, `set_property`, `delete_node`, etc.). These are internal — `plugin.gd::_register_handlers` is the authoritative list (`tool_catalog.gd` mirrors the MCP tool surface, not the plugin command names). They are independent of the MCP tool names. The Python handler in `src/godot_ai/handlers/<domain>.py` is the authoritative MCP-name → plugin-command map.

When using `batch_execute`'s `commands[].command` field, use the **plugin command name** (`create_node`, `set_property`) — not the MCP tool name (`node_create`, `node_set_property`). The same rule applies inside a `<domain>_manage` op (`node_manage(op="delete", ...)` delegates to the plugin's `delete_node`, not `node_delete`).

`batch_execute` is a meta-tool that invokes other plugin commands in a single call. Execution stops on first error; when `undo=True` (default), successful sub-commands are rolled back via scene UndoRedo on failure. Implemented via `McpDispatcher.dispatch_direct()` and `has_command()`. Unknown plugin commands return `INVALID_PARAMS` with fuzzy `data.suggestions`.

## Adding a new tool

1. Add a handler method in the appropriate GDScript `handlers/*.gd` file
2. Register it in `plugin.gd`: `_dispatcher.register_lazy("command_name", "<handler_key>", &"method")` (for a brand-new handler file, also add one `register_lazy_handler("<handler_key>", HANDLERS_DIR + "<file>.gd", [ctor args])` line — handlers are load()ed lazily at first dispatch, #736)
3. Add a shared Python handler in `handlers/<domain>.py` that calls `runtime.send_command("command_name", params)`
4. **Decide the MCP tool surface**:
   - **High-traffic verb (top-20)** → register as a named tool in `tools/<domain>.py` with `@mcp.tool(meta=DEFER_META)` (import `DEFER_META` from `godot_ai.tools`; omit `meta` if it's one of the ~4 always-loaded core tools: `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`). Add `session_id: str = ""` as the last parameter and pass it in: `DirectRuntime.from_context(ctx, session_id=session_id or None)`.
   - **Long-tail verb (default)** → add it to the `ops={}` dict for the existing `register_manage_tool(...)` call. The `<domain>_manage` rollup picks it up automatically; the meta-tool helper handles `session_id` extraction, JSON-string param coercion, and unknown-op error suggestions. No new tool registration needed.
5. Update `tool_catalog.gd` to mirror the new tool list — `tests/unit/test_tool_domains.py` will fail with a paste-over-ready diff if you forget.
6. Update the tool-surface blurb in `server.py` `instructions=` if the new verb is named (rollups are listed by tool, not by op).
7. For write tools: add an `await require_writable_async(runtime)` call at the top of the Python handler.
8. Write a description with natural-language keywords a user would search for (e.g. `screenshot`, `keybinding`, `asset`) alongside the Godot term. For ops inside a rollup, edit the `_DESCRIPTION` block of the domain's tool file so the rolled-up tool's docstring stays exhaustive.
9. **Consider a resource form**: pure reads with no `session_id` filtering benefit from a matching `godot://...` resource (or template) in `src/godot_ai/resources/`. The tool form remains for `session_id`-pinned reads; clients that surface resources prefer the URI. When you add a resource form, append `Resource form: godot://...` to the tool's description so aware clients can route reads through the URI.
10. Add tests: handler unit test, Python integration test, AND GDScript test in `test_project/tests/`. Migrate any integration tests for an existing verb when you move it under a rollup — the form changes from `client.call_tool("domain_verb", {...})` to `client.call_tool("domain_manage", {"op": "verb", "params": {...}, "session_id": ...})`.

## Python conventions

- Handlers: `return await runtime.send_command("command_name", params)` — don't handle errors.
- Write handlers: `await require_writable_async(runtime)` before sending commands (from `handlers/_readiness.py`).
- Tools create `DirectRuntime.from_context(ctx)` and delegate to handlers.
- Error codes in `protocol/errors.py` — keep in sync with `utils/error_codes.gd`.

## Deferred responses (tools whose reply flows out-of-band)

The dispatcher runs handlers synchronously and auto-sends one response per command. For work whose reply arrives over a different channel or spans frames — the game-bus tools (`editor_screenshot(source="game")`, `game_eval`, `game_command`) plus multi-frame editor work in the scene, script, filesystem, and project handlers — use the deferred pattern:

- Return `McpDispatcher.DEFERRED_RESPONSE` (a `{"_deferred": true}` sentinel dict). `tick()` skips auto-sending for these. `_call_handler` recognises it alongside `data` / `error` so the sentinel doesn't trip the malformed-result guard.
- Read the incoming request id from `params["_request_id"]`. The dispatcher injects it on a **duplicated** params dict so the original queued command isn't mutated. Hand it off to whatever async source will produce the reply.
- When the reply arrives, call `McpConnection.send_deferred_response(request_id, payload)`. `payload` must carry `data` or `error` in the same shape handlers normally return. The method attaches `request_id`, infers `status`, and pushes the JSON over the WebSocket.

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

Same principle for theme override pseudo-properties on Controls: assert `has_theme_color_override` (or constant/font-size/stylebox variant) before reading the value back with the regular getter — Godot 4.6 removed `get_theme_*_override`, and the presence check is what stops a broken override from silently resolving via the theme fallback. `test_ui.gd` `test_build_layout_theme_override_*` are the reference pattern.

### Additional GDScript conventions

- Handlers are `@tool` `RefCounted` scripts with **no** `class_name`. `plugin.gd` registers them by script path (`McpDispatcher.register_lazy_handler` / `register_lazy`) and the dispatcher `load()`s them at first dispatch (#736) — do not add a `const X := preload(...)` for a handler back into `plugin.gd`; that re-inflates the boot-time compile closure. Cross-handler and values/presets deps inside `handlers/` still use `const X := preload(...)` from their consumers. The `Mcp*`-prefixed `class_name` is reserved for utility classes shared across the project (e.g. `McpScenePath`, `McpPropertyErrors`, `McpParamValidators`); see #253 for why bare `class_name`s on handlers are forbidden.
- Return `{"data": {...}}` on success, `McpErrorCodes.make(code, msg)` on failure — include the failing parameter value and use `error_string(err)` for Godot error codes.
- The dispatcher detects empty/null handler results and reports `INTERNAL_ERROR` — a handler crash no longer looks like success.
- Use `##` for doc comments, typed arrays (`Array[String]`), never Python-style `"""`.

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

## Fix every bug you find

When you encounter a failing test or bug — even one that predates your changes — fix it. Never dismiss a failure as "pre-existing" or "unrelated" and move on. The only exception is a massive architectural issue that would derail the current task; in that case, record a follow-up issue, task, or handoff note. But if you can fix it in a few minutes, just fix it.

## Audit follow-up work

A whole-codebase audit's Tier-1 cleanup merged as PR #684. The remaining work — issues #685–#691 plus a 115-item backlog — is tracked in [docs/audit-tier2-plan.md](docs/audit-tier2-plan.md). When picking up any of it, follow that file's workflow: one PR per theme, the full test gauntlet before every commit, verify each finding against current code before touching anything, and ask the maintainer before the flagged design decisions.

## Godot version support (4.5+)

The plugin supports **Godot 4.5+** (4.7+ recommended). 4.5 is exercised by a CI canary (`Godot tests / Linux (Godot 4.5)` in `ci.yml`, pinned to `4.5.0`) so the parse-cascade class of regression cannot recur unnoticed at the documented floor.

- **Forward-compat engine APIs go through `Engine.call(...)` / `OS.call(...)` when they are newer than the supported floor.** A direct call to a method that only exists in a newer Godot is type-checked by the older engine's GDScript parser against the native class and rejected at parse time, even when guarded by `has_method(...)` at runtime. That parse failure can cascade through preloads and brick the whole plugin. This was the #476 regression for `Engine.capture_script_backtraces()` on 4.3. The current floor makes that specific call safe, but the pattern still applies to future 4.6+ APIs until the floor moves again.
- **CI GDScript validation**: `script/ci-check-gdscript` runs before Godot tests in CI. It scans the `--import` log for `SCRIPT ERROR` / `Parse Error` lines and fails the build early if any GDScript has syntax errors, before the test runner even starts. Strict on every supported Godot version, including the 4.5 canary.
- **CI Linux runner**: Linux Godot CI uses `chickensoft-games/setup-godot@v2` on `ubuntu-latest` (not a Docker image). All three OS jobs (Linux, macOS, Windows) use the same chickensoft action for consistent Godot setup, pinned to `4.7.0`. A fourth `godot-tests` row runs the Linux 4.5 canary on `4.5.0` (the action wants 3-part semver — `4.5` / `4.5.stable` are rejected). Step timeouts are set on test and smoke steps to prevent CI hangs.
- **Version-gated tests are for future floor bumps only.** Keep `McpTestSuite.skip_on_godot_lt(...)` available, but do not skip current-floor behavior; the 4.5 canary should exercise it.
## What NOT to do

- Don't call `EditorInterface` methods from WebSocket callbacks — always queue
- Don't cache `get_edited_scene_root()` across frames — it changes on scene switch
- Don't use `pop_front()` on arrays in hot paths — use index + slice
- Don't add error handling in individual tools — `GodotClient.send()` raises on errors
- Don't use Python-style `"""docstrings"""` in GDScript — use `##` comments
- Don't write GDScript tests that `return` without asserting — the runner flags these as failures. Use `skip("reason")` for unmet environmental preconditions, or `assert_true(false, "reason")` when setup that should have worked failed. See "Test hygiene checklist" above
- Don't forget the `overwrite` parameter on `animation_create` / `animation_create_simple` — without it, creating an animation with the same name errors instead of replacing
