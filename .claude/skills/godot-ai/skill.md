---
name: godot-ai
description: Build, test, and extend the Godot AI server and editor plugin
globs:
  - "**/godot-ai/**"
  - "**/godot_ai/**"
---

# Godot AI Development

## Project structure

- `src/godot_ai/` — Python MCP server (FastMCP v3)
  - `server.py` — entrypoint, lifespan, tool registration, `--exclude-domains` support
  - `tools/` — MCP tool modules (session, editor, scene, node, project, script, resource, filesystem, signal, autoload, input_map, testing, batch, client, ui, theme, animation, material, particle, camera, audio) + `_meta_tool.py` (`register_manage_tool` rollup factory)
  - `resources/` — `godot://...` read-only URIs (sessions, editor, project, nodes, scripts, scenes, library)
  - `middleware/` — `StripClientWrapperKwargs`, `ParseStringifiedParams`, `HintOpTypoOnManage`
  - `handlers/` — shared sync handlers behind a `Runtime` protocol; `_readiness.py` gates writes
  - `runtime/interface.py` + `direct.py` — `Runtime` protocol + `DirectRuntime` impl
  - `transport/websocket.py` — WebSocket server for Godot plugin
  - `sessions/registry.py` — multi-session tracking
  - `godot_client/client.py` — typed async client, raises `GodotCommandError` on errors
  - `protocol/` — envelope types, error codes
- `plugin/addons/godot_ai/` — GDScript editor plugin (canonical source)
  - `plugin.gd` — EditorPlugin lifecycle, handler registration, `_ensure_game_helper_autoload`
  - `connection.gd` — WebSocket client, reconnection, `send_deferred_response`
  - `dispatcher.gd` — command routing with frame budget; `DEFERRED_RESPONSE` sentinel
  - `handlers/` — scene, node, editor, project, client, script, resource, filesystem, signal, autoload, input, test, batch, ui, theme, animation (+ values/presets), material (+ values/presets), particle (+ values/presets), camera, audio, environment, texture, curve, physics_shape, control_draw_recipe
  - `clients/` — descriptor + strategy system (`_base`, `_registry`, `_json_strategy`, `_toml_strategy`, `_cli_strategy`, `_atomic_write`, `_cli_finder`, `_path_template`, `_manual_command`) and 18 client descriptors
  - `runtime/game_helper.gd` — game-side autoload that ferries logs back to the editor (`logs_read source=game`)
  - `testing/` — McpTestRunner + McpTestSuite framework
  - `utils/` — scene_path, error_codes, log_buffer
  - `client_configurator.gd` — server discovery (venv → uvx → system), client config
  - `mcp_dock.gd` — editor dock panel with status, setup, logs, self-update banner, Tools tab
  - `tool_catalog.gd` — mirror of `src/godot_ai/tools/domains.py`; drives Tools tab; CI-enforced via `tests/unit/test_tool_domains.py`
  - `update_reload_runner.gd` — self-update extract + plugin re-enable handoff
- `test_project/` — Godot 4.6 project (plugin symlinked via `addons/godot_ai`, locally built — not tracked in git)
  - `tests/` — GDScript test suites (auto-discovered by test_handler)
- `tests/` — Python tests (pytest)
  - `unit/` — protocol, session registry, runtime handlers, tool domains, middleware
  - `integration/` — WebSocket server + mock Godot plugin, MCP tools, rollups
- `script/` — dev and CI scripts
  - `setup-dev` / `setup-dev.ps1` / `verify-worktree` — dev environment + worktree health
  - `serve-this-worktree` / `open-godot-here` — point dev server / editor at the current worktree
  - `local-self-update-smoke` — interactive local fixture for self-update changes
  - `ci-start-server`, `ci-godot-tests`, `ci-reload-test`, `ci-quit-test`, `ci-check-gdscript` — CI scripts
  - `ci-find-regression-range` — helper for identifying CI regression windows

## Adding a new MCP tool

1. Add handler method in `plugin/addons/godot_ai/handlers/<domain>_handler.gd`
2. Register in `plugin.gd`: `_dispatcher.register("command_name", handler.method)`
3. Add shared Python handler in `src/godot_ai/handlers/<domain>.py` that calls `runtime.send_command("command_name", params)`. Write handlers must call `require_writable(runtime)` first (from `handlers/_readiness.py`).
4. **Decide the MCP tool surface** (most new verbs go in the rollup, not as a named tool):
   - **Rollup op (default)** → add it to the `ops={}` dict in the existing `register_manage_tool(...)` call for the domain (e.g. `register_manage_tool(mcp, tool_name="node_manage", ops={...})`). The rollup picks it up automatically; the meta-tool helper handles `session_id` extraction, JSON-string param coercion via `ParseStringifiedParams` middleware, and unknown-op suggestions via `HintOpTypoOnManage`. Update the `_DESCRIPTION` block at the top of the file so the rollup's docstring stays exhaustive.
   - **Top-level named tool (high-traffic verb only)** → register in `src/godot_ai/tools/<domain>.py` with `@mcp.tool(meta=DEFER_META)` (import from `godot_ai.tools`). Omit `meta=` only for the 4 always-loaded core tools: `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`. Add `session_id: str = ""` as the last parameter and pass it via `DirectRuntime.from_context(ctx, session_id=session_id or None)`.
5. Update `tool_catalog.gd` to mirror the new tool list — `tests/unit/test_tool_domains.py` will fail with a paste-over-ready diff if you forget.
6. Update the tool-surface blurb in `server.py` `instructions=` only if the new verb is named (rollups are listed by tool, not by op).
7. Write a description with natural-language keywords (`screenshot`, `keybinding`, `asset`, `clone`, `event / callback`, etc.) alongside the Godot term so tool-search clients find it.
8. **Consider a resource form**: pure reads with no `session_id` filtering benefit from a matching `godot://...` resource (or template) in `src/godot_ai/resources/`. When you add one, append `Resource form: godot://...` to the tool's description.
9. Add tests:
   - GDScript test in `test_project/tests/test_<domain>.gd`
   - Python unit test in `tests/unit/test_runtime_handlers.py`
   - Python integration test in `tests/integration/test_mcp_tools.py` — for rollup ops, the form is `client.call_tool("domain_manage", {"op": "verb", "params": {...}, "session_id": ...})`

## Test coverage

100% coverage for core features, always. Every tool needs:
- Python integration test (WebSocket mock) in `tests/`
- GDScript test (live editor) in `test_project/tests/`

## Fix every bug you find

When you encounter a failing test or bug — even one that predates your changes — fix it. Never dismiss a failure as "pre-existing" or "unrelated" and move on. The only exception is a massive architectural issue that would derail the current task; in that case, flag it with `spawn_task` for a follow-up session. But if you can fix it in a few minutes, just fix it.

Run Python tests: `pytest -v`
Run Godot tests: use `run_tests` MCP tool (no reload needed for test file edits)

Test guardrails: the runner flags tests with 0 assertions as failures (catches silent `return` before asserting). Always use `assert_true(false, "reason")` before early `return` in test methods. Test discovery is resilient — a broken `.gd` file doesn't kill discovery of the rest.

## GDScript conventions

- Handlers are `@tool` RefCounted classes with `class_name`
- Return `{"data": {...}}` on success, `McpErrorCodes.make(code, msg)` on failure — include the failing parameter value and use `error_string(err)` for Godot error codes
- All scene mutations must use `EditorUndoRedoManager` — response includes `"undoable": true`
- The dispatcher detects empty/null handler results and reports `INTERNAL_ERROR` — a handler crash no longer looks like success
- Use `ScenePath.from_node()` / `ScenePath.resolve()` for clean paths like `/Main/Camera3D`
- Use `##` for doc comments, typed arrays (`Array[String]`), never Python-style `"""`
- Main thread only — 4ms frame budget in `_process()`, use `call_deferred` for mutations

## Python conventions

- Handlers: `return await runtime.send_command("command_name", params)` — don't handle errors
- Write handlers: call `require_writable(runtime)` before sending commands (from `handlers/_readiness.py`)
- Tools create `DirectRuntime.from_context(ctx)` and delegate to handlers
- Error codes in `protocol/errors.py` — keep in sync with `utils/error_codes.gd`
- Lint: `ruff check src/ tests/` — Format: `ruff format src/ tests/`

## Server discovery (3-tier)

1. `.venv/bin/python -m godot_ai` — dev checkout (venv near project)
2. `uvx --from godot-ai~=VERSION godot-ai` — user install (PyPI via uvx)
3. `godot-ai` CLI — system install fallback

## Worktree awareness

Sessions often run in git worktrees (`.claude/worktrees/<name>/`). Always know which worktree you're in:
- Check `session_list` — `project_path` shows which worktree the Godot editor is running against
- The dev server (`--reload`) runs from the root repo's `.venv` and `src/`, not the worktree
- When writing prompts, handoff notes, or referencing files for another session, always include the worktree name or full path (e.g. "in worktree `nice-hamilton`: `docs/friction-log.md`")
- GDScript changes propagate within the same worktree via symlink, but not across worktrees — merge to main and pull
- **CRITICAL: Always launch Godot from the root repo's `test_project/`, never from a worktree.** Worktrees can be auto-removed when their owning session exits, destroying all uncommitted MCP-created files. The root repo is stable.

## Releasing

Cut a release via CLI:
```bash
gh workflow run bump-and-release.yml -f bump=patch   # or minor / major
```
This bumps `plugin.cfg` + `pyproject.toml`, commits, tags, and pushes. The `release.yml` workflow triggers on the tag and builds a `godot-ai-plugin.zip` for the Asset Library. The dock's self-update feature checks GitHub releases on startup and offers one-click updates to users.

## Dev workflow

- GDScript changes → Reload Plugin in dock
- Python changes → Reload Plugin (restarts server) or `--reload` flag
- Test file changes → just call `run_tests` (hot-reloaded via CACHE_MODE_IGNORE)

## Tool-search friendliness + tool-count caps

The MCP tool surface is shaped to satisfy two pressures at once:

1. **Anthropic tool-search clients** (`tool_search_tool_bm25_20251119` / `tool_search_tool_regex_20251119`) — non-core tools are tagged `meta={"defer_loading": True}` so the client only loads schemas it searches for.
2. **Tool-count caps in non-search clients** (Antigravity, etc., that ignore `defer_loading` and refuse to start past ~40 tools) — long-tail verbs collapse into per-domain `<domain>_manage` rollups (`op="<verb>"` + `params` dict). Schema-aware clients still see every op via the dynamic `Literal[...]` enum built by `register_manage_tool` in `tools/_meta_tool.py`.

Result: ~39 MCP tools (4 core + ~15 named verbs + ~20 rollups), down from a flat surface that crossed 100. Plugin command names over WebSocket stay independent — they're documented in `tool_catalog.gd` and unchanged by the rollup refactor.

- All tools follow `domain_action` namespacing — no ambiguous prefixes
- Core tools loaded upfront (no `meta=`): `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`
- Descriptions include natural-language keywords users would search for (e.g. "screenshot", "keybinding", "asset", "event / callback") so tool-search BM25 hits them
- `server.py` `instructions=` includes a tool categories blurb listing the rollup map, so tool-search clients have a discovery map without reading every schema
- Read-only `godot://...` resources mirror the cheap reads (`godot://editor/state`, `godot://node/{path}/properties`, `godot://script/{path}`, etc.) — they don't count against the tool cap, and aware clients prefer them. Tool form remains for `session_id`-pinned reads.

For tool-capped clients without tool-search support, the server accepts `--exclude-domains audio,particle,...` (CLI flag and `EditorSettings`-backed dock UI) to drop entire domains' rollups and named tools while keeping the core 4 alive.

When adding a new verb, prefer adding it as an op on the domain's existing `register_manage_tool(...)` call rather than registering a new top-level tool — only the highest-traffic verbs warrant a named tool (see "Adding a new MCP tool" above).

## Current tool inventory (~39 MCP tools)

`tool_catalog.gd` is the canonical list — `tests/unit/test_tool_domains.py` keeps it in sync with the Python registrations. The shape:

**4 always-loaded core tools** (no `meta=`):
`editor_state`, `node_get_properties`, `scene_get_hierarchy`, `session_activate`

**Top-level named verbs** (`@mcp.tool(meta=DEFER_META)`, deferred but not rolled up):
`editor_screenshot`, `editor_reload_plugin`, `logs_read`, `scene_open`, `scene_save`, `node_create`, `node_set_property`, `node_find`, `script_create`, `script_attach`, `script_patch`, `project_run`, `test_run`, `batch_execute`, `animation_create`

**`<domain>_manage` rollups** (one per domain; `op="<verb>"` + `params` dict + optional top-level `session_id`):

| Rollup | Ops |
|--------|-----|
| `session_manage` | `list` |
| `editor_manage` | `state`, `selection_get`, `selection_set`, `monitors_get`, `quit`, `logs_clear` |
| `scene_manage` | `create`, `save_as`, `get_roots` |
| `node_manage` | `get_children`, `get_groups`, `delete`, `duplicate`, `rename`, `move`, `reparent`, `add_to_group`, `remove_from_group` |
| `script_manage` | `read`, `detach`, `find_symbols` |
| `project_manage` | `stop`, `settings_get`, `settings_set` |
| `resource_manage` | `search`, `load`, `assign`, `get_info`, `create`, `curve_set_points`, `environment_create`, `physics_shape_autofit`, `gradient_texture_create`, `noise_texture_create` |
| `filesystem_manage` | `read_text`, `write_text`, `reimport`, `search` |
| `client_manage` | `status`, `configure`, `remove` |
| `signal_manage` | `list`, `connect`, `disconnect` |
| `autoload_manage` | `list`, `add`, `remove` |
| `input_map_manage` | `list`, `add_action`, `remove_action`, `bind_event` |
| `test_manage` | `results_get` |
| `ui_manage` | `set_anchor_preset`, `set_text`, `build_layout`, `draw_recipe` |
| `theme_manage` | `create`, `set_color`, `set_constant`, `set_font_size`, `set_stylebox_flat`, `apply` |
| `animation_manage` | `player_create`, `delete`, `validate`, `add_property_track`, `add_method_track`, `set_autoplay`, `play`, `stop`, `list`, `get`, `create_simple`, `preset_fade`, `preset_slide`, `preset_shake`, `preset_pulse` |
| `material_manage` | `create`, `set_param`, `set_shader_param`, `get`, `list`, `assign`, `apply_to_node`, `apply_preset` |
| `particle_manage` | `create`, `set_main`, `set_process`, `set_draw_pass`, `restart`, `get`, `apply_preset` |
| `camera_manage` | `create`, `configure`, `set_limits_2d`, `set_damping_2d`, `follow_2d`, `get`, `list`, `apply_preset` |
| `audio_manage` | `player_create`, `player_set_stream`, `player_set_playback`, `play`, `stop`, `list` |

**Resources** (read-only `godot://...` URIs, no tool-count cost):
`godot://sessions`, `godot://editor/state`, `godot://selection/current`, `godot://logs/recent`, `godot://scene/current`, `godot://scene/hierarchy`, `godot://node/{path}/properties`, `godot://node/{path}/children`, `godot://node/{path}/groups`, `godot://script/{path}`, `godot://project/info`, `godot://project/settings`, `godot://materials`, `godot://input_map`, `godot://performance`, `godot://test/results`.

## Plugin command vs MCP tool names

The plugin (GDScript) uses short command names over WebSocket (`run_tests`, `reload_plugin`, `reimport`, `set_selection`, `search_filesystem`, `get_performance_monitors`, `create_node`, `set_property`, `delete_node`, etc.). These are internal — see `plugin.gd::_register_handlers` and `tool_catalog.gd` for the authoritative list. They are independent of the MCP tool names. The Python handler in `src/godot_ai/handlers/<domain>.py` is the authoritative MCP-name → plugin-command map.

When using `batch_execute`'s `commands[].command` field, use the **plugin command name** (`create_node`, `set_property`) — not the MCP tool name (`node_create`, `node_set_property`). The same rule applies inside a `<domain>_manage` op (`node_manage(op="delete", ...)` delegates to the plugin's `delete_node`, not `node_delete`).

`batch_execute` is a meta-tool that invokes other plugin commands in a single call. Execution stops on first error; when `undo=True` (default), successful sub-commands are rolled back via scene UndoRedo on failure. Implemented via `McpDispatcher.dispatch_direct()` and `has_command()`. Unknown plugin commands return `INVALID_PARAMS` with fuzzy `data.suggestions`.
