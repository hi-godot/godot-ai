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

- **GDScript plugin is the canonical copy** in `plugin/`. `test_project/addons/godot_ai` is a symlink — no copy needed.
- **Error codes**: Defined in `protocol/errors.py` (Python) and `utils/error_codes.gd` (GDScript). Keep in sync. Use Godot's built-in `error_string(err)` to translate numeric error codes in error messages — do not write a custom lookup table.
- **Tools return `dict`**: Handlers call `runtime.send_command(command, params)` which returns a dict or raises. Tools create a `DirectRuntime` and delegate to handlers.
- **Plugin runs on main thread**: All GDScript executes in `_process()` with a 4ms frame budget. Never block. Use `call_deferred` for scene tree mutations.
- **Scene paths are clean**: `/Main/Camera3D` format, not raw Godot internal paths. Use `ScenePath.from_node(node, scene_root)` in GDScript.
- **MCP logging**: Plugin prints `MCP | [recv] command(params)` / `MCP | [send] command -> ok` to Godot console. Controlled by `mcp_logging` var.
- **Tool-search-friendly naming**: All MCP tools use `domain_action` namespacing (`scene_*`, `node_*`, `script_*`, etc.). Non-core tools are tagged `meta={"defer_loading": True}` for Anthropic tool-search compatibility; core tools (`editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_list`, `session_activate`) stay non-deferred. Plugin command names (sent over WebSocket) are independent — the MCP tool `editor_reload_plugin` dispatches the plugin command `reload_plugin`.
- **`batch_execute` uses plugin command names, not MCP tool names**: The MCP tool `node_create` dispatches the plugin command `create_node`. Inside `batch_execute`'s `commands[].command` field, use the plugin name (`create_node`), not the MCP name (`node_create`). The Python handlers in `src/godot_ai/handlers/` are the authoritative map — each handler calls `runtime.send_command("<plugin_cmd>", ...)`. When an agent passes the wrong form, the error message spells out the convention and suggests near-matches from `dispatcher.suggest_similar()`, with structured fuzzy matches in `error.data.suggestions`.
- **Session IDs**: format is `<project-slug>@<4hex>` (e.g. `godot-ai@a3f2`). The slug is derived from the project directory name so agents can recognize which editor they're targeting; the hex suffix disambiguates same-project twins. Server treats the ID as an opaque key.
- **Per-call session routing**: every Godot-talking tool accepts an optional `session_id` parameter. Empty (the default) resolves to the global active session. When supplied, that single call targets that session — `require_writable` and every handler inside the call see the pinned session, not the active one. Use this when multiple AI clients share one MCP server. Resources (`godot://...`) still resolve via the active session.

## Worktrees

Claude Code sessions often run in git worktrees (`.claude/worktrees/<name>/`). Be aware of which worktree you're in — it affects everything:

- **File paths**: Your working directory is the worktree, not the repo root. Files you create live in that worktree.
- **Godot editor**: The editor runs against a specific worktree's `test_project/`. The plugin is symlinked from that worktree's `plugin/` directory. Check `session_list` — the `project_path` field tells you which worktree the editor is using.
- **Dev server**: The `--reload` dev server uses the root repo's `.venv` and `src/`, not the worktree's. Python code changes in any worktree won't take effect unless the root repo also has them (e.g. via `git pull`). To serve the worktree's own Python source, use `script/serve-this-worktree` (prepends the worktree's `src/` to `PYTHONPATH` and frees port 8000 before starting).
- **Passing info between sessions**: When writing prompts, handoff notes, or file references intended for another session, **always include the full worktree path** or specify the worktree name. Relative paths like `docs/friction-log.md` are ambiguous — a different session may be in a different worktree or on `main`. Use the absolute path.
- **Merging**: Worktree branches must be merged to `main` and pulled into other worktrees for changes to propagate. The plugin symlink means GDScript changes propagate within the same worktree immediately, but not across worktrees.

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

Two safe patterns:
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
  path_template, server_key_path, entry_builder, …)
- `_registry.gd` — explicit `preload(...)` list of every client. Adding a client
  means: write `clients/<name>.gd` extending `McpClient`, then append one
  preload here. No edits to dock or facade required.
- `_json_strategy.gd` / `_toml_strategy.gd` / `_cli_strategy.gd` — three
  reusable writers, selected by descriptor `config_type`. **No per-client
  branching** inside strategies — non-standard entry shapes (Claude Desktop's
  `npx mcp-remote` bridge, Antigravity's `serverUrl`, Zed's `command`/`settings`
  shape) supply their own `entry_builder` (and optionally a `verify_entry`
  callable for status checks).
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
4. Add a Python tool in `tools/<domain>.py` — name it `domain_action` (e.g. `scene_open`, `node_create`), decorate with `@mcp.tool(meta=DEFER_META)` from `godot_ai.tools`. Only omit `meta` for the ~5 always-loaded core tools (`editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_list`, `session_activate`). Add `session_id: str = ""` as the last parameter and pass it in: `DirectRuntime.from_context(ctx, session_id=session_id or None)` — this lets callers pin the tool to a specific editor when multiple are connected.
5. Register the tool module in `server.py` if it's a new file. If it introduces a new namespace, add it to the tool-categories blurb in `server.py` `instructions=`
6. For write tools: add `require_writable(runtime)` call at the top of the Python handler
7. Write a description with natural-language keywords a user would search for (e.g. `screenshot`, `keybinding`, `asset`) alongside the Godot term
8. Add tests: handler unit test, Python integration test, AND GDScript test in `test_project/tests/`

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
- Don't write GDScript tests that `return` without asserting — the runner flags these as failures. Use `assert_true(false, "reason")` before the `return` if a precondition isn't met
- Don't forget the `overwrite` parameter on `animation_create` / `animation_create_simple` — without it, creating an animation with the same name errors instead of replacing
