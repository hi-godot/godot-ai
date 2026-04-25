# Available Tools

Godot AI exposes ~39 MCP tools — ~18 high-traffic verbs as named tools, plus
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
| `logs_read` | Read plugin / game / combined log buffers (game source needs `_mcp_game_helper` autoload) |
| `editor_screenshot` | Capture editor viewport, cinematic camera, or running game framebuffer |
| `editor_reload_plugin` | Reload the plugin and wait for reconnect (server must be external) |
| `animation_create` | Create an Animation clip (auto-creates AnimationPlayer + library if missing) |

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
| `editor_manage` | `state`, `selection_get`, `selection_set`, `monitors_get`, `quit`, `logs_clear` |
| `session_manage` | `list` |
| `test_manage` | `results_get` |
| `animation_manage` | `player_create`, `delete`, `validate`, `add_property_track`, `add_method_track`, `set_autoplay`, `play`, `stop`, `list`, `get`, `create_simple`, `preset_fade`, `preset_slide`, `preset_shake`, `preset_pulse` |
| `material_manage` | `create`, `set_param`, `set_shader_param`, `get`, `list`, `assign`, `apply_to_node`, `apply_preset` |
| `audio_manage` | `player_create`, `player_set_stream`, `player_set_playback`, `play`, `stop`, `list` |
| `particle_manage` | `create`, `set_main`, `set_process`, `set_draw_pass`, `restart`, `get`, `apply_preset` |
| `camera_manage` | `create`, `configure`, `set_limits_2d`, `set_damping_2d`, `follow_2d`, `get`, `list`, `apply_preset` |
| `signal_manage` | `list`, `connect`, `disconnect` |
| `input_map_manage` | `list`, `add_action`, `remove_action`, `bind_event` |
| `autoload_manage` | `list`, `add`, `remove` |
| `filesystem_manage` | `read_text`, `write_text`, `reimport`, `search` |
| `theme_manage` | `create`, `set_color`, `set_constant`, `set_font_size`, `set_stylebox_flat`, `apply` |
| `ui_manage` | `set_anchor_preset`, `set_text`, `build_layout`, `draw_recipe` |
| `resource_manage` | `search`, `load`, `assign`, `get_info`, `create`, `curve_set_points`, `environment_create`, `physics_shape_autofit`, `gradient_texture_create`, `noise_texture_create` |
| `client_manage` | `status`, `configure`, `remove` |

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
| `godot://script/{path}` | GDScript source by res:// path (drop the `res://` prefix) |
| `godot://project/info` | Active project metadata |
| `godot://project/settings` | Common project settings subset |
| `godot://materials` | All Material resources under res:// |
| `godot://input_map` | Project input actions and their bound events |
| `godot://performance` | Performance singleton snapshot |
| `godot://test/results` | Most recent `test_run` results |
