# Available Tools

Godot AI exposes ~41 MCP tools — ~18 high-traffic verbs as named tools, plus
one rolled-up `<domain>_manage` per domain that takes `op="..."` + a `params`
dict. The rollup pattern keeps the tool count well below the 100-tool caps
some clients enforce while still exposing every action.

The plugin command surface (over WebSocket) is unchanged; only the MCP tool
names move. Inside `batch_execute`'s `commands[].command` field, keep using
the underlying plugin command names (e.g. `create_node`, `set_property`),
not the MCP tool names.

## Always-loaded core tools

| Tool | Description |
|------|-------------|
| `editor_state` | Editor version, project name, current scene, readiness, play state |
| `scene_get_hierarchy` | Paginated scene tree walk (depth, offset, limit) |
| `node_get_properties` | Full property snapshot of a node |
| `session_activate` | Pin subsequent calls to a specific connected editor |

## Top-level deferred verbs (high-traffic write/read)

| Tool | Description |
|------|-------------|
| `batch_execute` | Run multiple plugin commands atomically (rollback on first error) |
| `node_create` / `node_set_property` / `node_find` | Common node writes + search |
| `scene_open` / `scene_save` | Open and save scenes |
| `script_create` / `script_attach` / `script_patch` | Create, attach, anchor-edit GDScript files |
| `project_run` | Play the project (autosave persists in-memory MCP edits unless `autosave=False`) |
| `test_run` | Run GDScript test suites in the editor |
| `logs_read` | Read plugin / game / editor / combined log buffers. `source="editor"` surfaces parse errors, GDScript reload warnings, @tool/EditorPlugin runtime errors, push_error/push_warning, and visible Debugger dock Errors-tab rows — use this when the editor's Output or Debugger Errors panel shows red/yellow rows |
| `editor_screenshot` | Capture editor viewport, cinematic camera, or running game framebuffer |
| `editor_reload_plugin` | Reload the plugin and wait for reconnect (server must be external) |
| `animation_create` | Create an Animation clip (auto-creates AnimationPlayer + library if missing) |

`logs_read` also accepts `include_details=true` for `source="editor"`,
`source="game"`, and `source="all"`. Detailed entries include the original
Godot `_log_error` code/rationale when available, error type, resolved source
location, and stack/error-tree context corresponding to the Debugger dock's
Errors tab.

For game logs, `logs_read(source="game")` returns lines from the current game
run only. Each play-start creates a new `run_id`, even if the game never reaches
the `_mcp_game_helper` hello beacon; prior run lines stay retained but do not
appear in the default response. To retrieve a prior run, keep the `run_id` from
an earlier response and pass `logs_read(source="game", since_run_id="...")`;
the response includes both `run_id` (the run being read) and `current_run_id`
(the latest run). `stale_run_id=true` means the requested run is not the current
one. There is no single `source="game"` call that returns every retained game
line across all runs; consumers that need history should retain run ids and
query each run explicitly.

Game and combined log responses also include `game_status` and a liveness-based
`is_running`. `is_running` is no longer raw editor play-state: it is `false` for
`game_status.status` of `"not_live"` or `"stopped"`, and `true` for `"live"`,
`"launching"`, or `"no_helper"`. This lets a parse/load failure that leaves the
editor play button active report as not running, while a legitimate headless or
custom-main-loop project without `_mcp_game_helper` remains running with
`game_status.status="no_helper"`.

For incremental editor-log polling, call `logs_read(source="editor")` once and
save the returned `next_cursor`; later calls can pass
`logs_read(source="editor", since_cursor=N)` to receive only Logger-backed
editor entries appended after that cursor. Cursor responses include
`cursor`, `oldest_cursor`, `next_cursor`, `appended_total`, `truncated`, and
`has_more`; `since_cursor` supersedes `offset`. If `truncated=true`, the
caller fell behind the ring and some entries were evicted before the poll —
continue from the returned `next_cursor` and treat `oldest_cursor` as the
earliest retained sequence. If the plugin reloads, a stale high cursor
self-heals to the new tail with an empty response and a corrected
`next_cursor`. Live Debugger dock Errors-tab rows are merged into regular
`source="editor"` reads, but they are UI state rather than ring-buffer entries
and are not included in `since_cursor` responses.

`editor_manage(op="logs_clear")` accepts `clear_debugger_errors=true` to also
clear the Debugger dock's visible Errors-tab rows (routed through the panel's
own Clear path so the tab badge and counters reset). The Errors panel is
user-facing UI, so the default leaves it untouched.

`script_create` and `script_patch` validate written `.gd` content before the
editor import step and include per-write diagnostics in their response:
`diagnostics` (array of structured editor-style entries), `diagnostics_scope`
(`"this_file"`), `diagnostics_status` (`"checked"` or `"partial"` if the scoped
validation log window overflowed), and `diagnostics_detail`.
`diagnostics_detail` is `"log_capture"` when Godot 4.5+'s Logger API supplied
real parse diagnostics for the written file, `"fallback"` when validation failed
but Logger details were unavailable (for example on Godot < 4.5), and `"none"`
when no diagnostics were reported. Fallback diagnostics still prove the content
failed validation, but their line number is a best-effort hint marked with
`details.fallback_line`.

## Domain rollups (`<domain>_manage`)

Each rollup is a single MCP tool dispatched by `op` name + `params` dict.
The `op` field is a `Literal[...]` enum so MCP clients with schema-aware
autocomplete still see every valid verb. Unknown ops surface a structured
error with fuzzy `data.suggestions`.

Calls take the form:

```json
{"op": "set_color", "params": {"theme_path": "res://theme.tres",
                                "class_name": "Label", "name": "font_color",
                                "value": "#ff0000"}}
```

| Tool | Ops |
|------|-----|
| `scene_manage` | `create`, `save_as`, `get_roots` |
| `node_manage` | `get_children`, `get_groups`, `delete`, `duplicate`, `rename`, `move`, `reparent`, `add_to_group`, `remove_from_group` |
| `script_manage` | `read`, `detach`, `find_symbols` |
| `project_manage` | `stop`, `settings_get`, `settings_set` |
| `editor_manage` | `state`, `selection_get`, `selection_set`, `monitors_get`, `quit`, `logs_clear`, `game_eval` |
| `session_manage` | `list` |
| `test_manage` | `results_get` |
| `animation_manage` | `player_create`, `delete`, `validate`, `add_property_track`, `add_method_track`, `set_autoplay`, `play`, `stop`, `list`, `get`, `create_simple`, `preset_fade`, `preset_slide`, `preset_shake`, `preset_pulse` |
| `material_manage` | `create`, `set_param`, `set_shader_param`, `get`, `list`, `assign`, `apply_to_node`, `apply_preset` |
| `audio_manage` | `player_create`, `player_set_stream`, `player_set_playback`, `play`, `stop`, `list` |
| `particle_manage` | `create`, `set_main`, `set_process`, `set_draw_pass`, `restart`, `get`, `apply_preset` |
| `camera_manage` | `create`, `configure`, `set_limits_2d`, `set_damping_2d`, `follow_2d`, `get`, `list`, `apply_preset` |
| `signal_manage` | `list`, `connect`, `disconnect` |
| `input_map_manage` | `list`, `add_action`, `remove_action`, `bind_event` |
| `game_manage` | `get_scene_tree`, `get_node_info`, `get_ui_elements`, `input_key`, `input_mouse`, `input_gamepad`, `input_state` |
| `autoload_manage` | `list`, `add`, `remove` |
| `filesystem_manage` | `read_text`, `write_text`, `reimport`, `search` |
| `theme_manage` | `create`, `set_color`, `set_constant`, `set_font_size`, `set_stylebox_flat`, `apply` |
| `ui_manage` | `set_anchor_preset`, `set_text`, `build_layout`, `draw_recipe` |
| `resource_manage` | `search`, `load`, `assign`, `get_info`, `create`, `curve_set_points`, `environment_create`, `physics_shape_autofit`, `gradient_texture_create`, `noise_texture_create` |
| `api_manage` | `get_class` |
| `client_manage` | `status`, `configure`, `remove` |

`api_manage(op="get_class")` inspects Godot API/ClassDB metadata for a class
without creating an instance. By default it returns direct class members only,
with each returned section capped at 100 items. Pass `sections` (`properties`,
`methods`, `signals`, `enums`, `constants`, `inheritors`),
`include_inherited=true`, `include_inheritors=true`, `offset`, or `limit=0`
when a fuller class reference is needed. When paginating, request one section
at a time so `offset`/`limit` apply only to the list you are paging.

Every rolled-up tool also accepts an optional top-level `session_id` for
per-call multi-editor routing (sibling of `op` and `params`, *not* nested
inside `params`).

## MCP Resources

Read-only URIs served alongside the tool surface. They don't count against
tool caps and are preferred for active-session reads when the client
surfaces them. The matching tool form is the fallback for clients that
don't, and the only path that supports `session_id` pinning.

| Resource URI | Description |
|--------------|-------------|
| `godot://sessions` | All connected editor sessions with metadata |
| `godot://editor/state` | Editor version, project, current scene, readiness, play state |
| `godot://selection/current` | Current editor selection |
| `godot://logs/recent` | Last 100 plugin log lines |
| `godot://scene/current` | Active scene path + project + play state |
| `godot://scene/hierarchy` | Full scene hierarchy from the active editor |
| `godot://node/{path}/properties` | All properties of a node by scene path |
| `godot://node/{path}/children` | Direct children (name, type, path each) |
| `godot://node/{path}/groups` | Group memberships for a node |
| `godot://class/{class_name}` | ClassDB metadata: properties, methods, signals, enums, constants, inheritance, and defaults |
| `godot://script/{path}` | GDScript source by res:// path (drop the `res://` prefix) |
| `godot://project/info` | Active project metadata |
| `godot://project/settings` | Common project settings subset |
| `godot://materials` | All Material resources under res:// |
| `godot://input_map` | Project input actions and their bound events |
| `godot://performance` | Performance singleton snapshot |
| `godot://test/results` | Most recent `test_run` results |
