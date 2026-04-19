# Available Tools

Godot AI exposes 120+ MCP tools. They're grouped below by domain.

## Sessions and Editor

| Tool | Description |
|------|-------------|
| `session_list` | List connected Godot editor sessions |
| `session_activate` | Set the active session for multi-editor routing |
| `editor_state` | Read Godot version, project name, current scene, and play state |
| `editor_selection_get` / `editor_selection_set` | Read or set the editor selection |
| `editor_screenshot` | Capture the 3D editor viewport or the running game's framebuffer. `source="game"` works in every embed / floating / separate-window mode via the debugger-channel bridge (requires the `_mcp_game_helper` autoload, registered automatically when the plugin is enabled) |
| `editor_reload_plugin` / `editor_quit` | Reload the plugin or quit the editor |
| `logs_read` / `logs_clear` | Read or clear recent log lines. `source="plugin"` (default) returns MCP traffic; `source="game"` returns `print` / `push_error` / `push_warning` from the running game with per-run `run_id`, `is_running`, and `dropped_count`; `source="all"` returns both streams. Game capture requires Godot 4.5+ (Logger API) and the `_mcp_game_helper` autoload registered automatically by the plugin |
| `performance_monitors_get` | Read Godot performance monitors (FPS, memory, draw calls, etc.) |
| `batch_execute` | Run multiple plugin commands in one round trip |

## Scene and Nodes

| Tool | Description |
|------|-------------|
| `scene_create` / `scene_open` / `scene_save` / `scene_save_as` | Create, open, and save scenes |
| `scene_get_hierarchy` / `scene_get_roots` | Read the scene tree or list open scenes |
| `node_create` / `node_delete` / `node_duplicate` | Create, delete, or duplicate nodes |
| `node_rename` / `node_reparent` / `node_move` | Rename, reparent, or reorder nodes |
| `node_find` | Search nodes by name, type, or group |
| `node_get_properties` / `node_set_property` | Read or write node properties |
| `node_get_children` | Read direct children for a node |
| `node_add_to_group` / `node_remove_from_group` / `node_get_groups` | Manage group membership |

## Scripts and Signals

| Tool | Description |
|------|-------------|
| `script_create` / `script_read` / `script_patch` | Create, read, or patch GDScript files |
| `script_attach` / `script_detach` | Attach or detach scripts from nodes |
| `script_find_symbols` | Find class, function, or signal symbols in project scripts |
| `signal_list` / `signal_connect` / `signal_disconnect` | Inspect and wire up signals |

## Resources, Materials, Textures

| Tool | Description |
|------|-------------|
| `resource_create` / `resource_load` / `resource_assign` / `resource_get_info` / `resource_search` | Create, load, assign, and search `.tres` / `.res` resources |
| `material_create` / `material_list` / `material_get` | Create and inspect materials |
| `material_assign` / `material_apply_to_node` / `material_apply_preset` | Assign materials and apply named presets |
| `material_set_param` / `material_set_shader_param` | Set material or shader parameters |
| `gradient_texture_create` / `noise_texture_create` | Generate gradient or noise textures |
| `curve_set_points` | Set points on a `Curve` resource |

## UI, Controls, Theme

| Tool | Description |
|------|-------------|
| `ui_build_layout` | Build a Control layout tree from a recipe |
| `ui_set_text` / `ui_set_anchor_preset` | Set Control text or anchor preset |
| `control_draw_recipe` | Attach a procedural draw recipe script to a Control |
| `theme_create` / `theme_apply` | Create themes and apply them to Controls |
| `theme_set_color` / `theme_set_constant` / `theme_set_font_size` / `theme_set_stylebox_flat` | Edit theme entries |

## Animation

| Tool | Description |
|------|-------------|
| `animation_player_create` | Create an `AnimationPlayer` node |
| `animation_create` / `animation_create_simple` / `animation_delete` | Create or delete animations |
| `animation_list` / `animation_get` / `animation_validate` | Inspect and validate animations |
| `animation_add_property_track` / `animation_add_method_track` | Add property or method tracks |
| `animation_play` / `animation_stop` / `animation_set_autoplay` | Playback controls |
| `animation_preset_fade` / `animation_preset_pulse` / `animation_preset_shake` / `animation_preset_slide` | Named animation presets |

## Audio

| Tool | Description |
|------|-------------|
| `audio_player_create` / `audio_list` | Create and list audio players |
| `audio_play` / `audio_stop` | Control playback |
| `audio_player_set_stream` / `audio_player_set_playback` | Assign streams and tune playback |

## Particles, Environment, Camera

| Tool | Description |
|------|-------------|
| `particle_create` / `particle_get` / `particle_restart` | Create, inspect, restart particle systems |
| `particle_set_main` / `particle_set_process` / `particle_set_draw_pass` / `particle_apply_preset` | Configure particle nodes |
| `environment_create` | Create a `WorldEnvironment` with a configured `Environment` |
| `camera_create` / `camera_list` / `camera_get` | Create and inspect cameras |
| `camera_configure` / `camera_apply_preset` | Tune camera settings or apply presets |
| `camera_follow_2d` / `camera_set_limits_2d` / `camera_set_damping_2d` | 2D camera helpers |
| `physics_shape_autofit` | Auto-fit a collision shape to a mesh |

## Project, Filesystem, Input

| Tool | Description |
|------|-------------|
| `project_settings_get` / `project_settings_set` | Read or write Godot project settings |
| `project_run` / `project_stop` | Run or stop the project from the editor |
| `autoload_add` / `autoload_remove` / `autoload_list` | Manage autoload singletons |
| `filesystem_search` / `filesystem_read_text` / `filesystem_write_text` / `filesystem_reimport` | Search, read, write, and reimport project files |
| `input_map_add_action` / `input_map_remove_action` / `input_map_bind_event` / `input_map_list` | Manage the project input map |

## Testing and Client Setup

| Tool | Description |
|------|-------------|
| `test_run` | Run GDScript test suites inside the editor |
| `test_results_get` | Read the most recent test results without rerunning |
| `client_configure` / `client_remove` / `client_status` | Configure, remove, or check supported MCP clients |

## MCP Resources

| Resource URI | Description |
|-------------|-------------|
| `godot://sessions` | Connected editor sessions with metadata |
| `godot://scene/current` | Current scene path, project name, and play state |
| `godot://scene/hierarchy` | Full scene hierarchy from the active editor |
| `godot://selection/current` | Current editor selection |
| `godot://project/info` | Active project metadata |
| `godot://project/settings` | Common project settings subset |
| `godot://logs/recent` | Recent editor log lines |
