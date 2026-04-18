<p align="center">
  <img src="docs/hero.png" alt="Godot AI — The wait is over" width="700">
</p>

# Godot AI

[![CI](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml/badge.svg)](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/hi-godot/godot-ai/graph/badge.svg)](https://codecov.io/gh/hi-godot/godot-ai)

**Connect MCP clients directly to a live Godot editor.** Godot AI bridges AI assistants (Claude Code, Codex, Antigravity, etc.) with your Godot Editor via the [Model Context Protocol](https://modelcontextprotocol.io/introduction). Inspect scenes, create nodes, search project data, run tests, and read structured editor resources — all from a prompt.

*Independent community project, not affiliated with the [Godot Foundation](https://godot.foundation). Godot Engine is [MIT-licensed](https://godotengine.org/license).*

---

## Quick Start

### Prerequisites

- Godot `4.3+` (`4.4+` recommended)
- [uv](https://docs.astral.sh/uv/) (used to install the Python server)
- An MCP client ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) | [Codex](https://openai.com/index/codex/) | [Antigravity](https://www.antigravity.dev/))

### 1. Install the plugin

Clone the repo (or [download the zip](https://github.com/hi-godot/godot-ai/archive/refs/heads/main.zip)) and copy the plugin into your Godot project:

```bash
git clone https://github.com/hi-godot/godot-ai.git
cp -r godot-ai/plugin/addons/godot_ai your-project/addons/
```

### 2. Enable the plugin

In Godot: **Project > Project Settings > Plugins** — enable **Godot AI**.

The plugin will automatically start the MCP server, connect over WebSocket, and show status in the **Godot AI** dock.

<p align="center"><img src="docs/images/dock.png" alt="Godot AI dock" width="320"></p>

### 3. Connect your MCP client

The dock lists every supported client in a scrollable grid with a status dot
and per-row **Configure** / **Remove** buttons. Press **Configure all** to set
up every client at once. Auto-configure handles:

- **Claude Code** — CLI (`claude mcp add`)
- **Claude Desktop** — JSON config + `npx mcp-remote` stdio bridge
- **Antigravity** — JSON config

<details>
<summary><strong>…and 15+ more clients</strong></summary>

- **Codex** — TOML (`~/.codex/config.toml`)
- **Cursor** — `~/.cursor/mcp.json`
- **Windsurf** — `~/.codeium/windsurf/mcp_config.json`
- **VS Code** & **VS Code Insiders** — `<user>/Code/User/mcp.json`
- **Zed** — `~/.config/zed/settings.json` (via `npx mcp-remote`)
- **Gemini CLI** — `~/.gemini/settings.json`
- **Cline**, **Kilo Code**, **Roo Code** — VS Code extension globalStorage
- **Kiro** — `~/.kiro/settings/mcp.json`
- **Trae** — `<user>/Trae/User/mcp.json`
- **Cherry Studio** — `<user>/CherryStudio/mcp_servers.json`
- **OpenCode** — `~/.config/opencode/opencode.json`
- **Qwen Code** — `~/.qwen/settings.json`

</details>

If auto-configure can't find a CLI (GUI-launched editors have a limited PATH),
each row exposes a **Run this manually** panel with a copyable snippet. Server
URL is always `http://127.0.0.1:8000/mcp`.

> Adding a new client: drop a `clients/<name>.gd` descriptor under
> `plugin/addons/godot_ai/clients/` and add one `preload(...)` line to
> `clients/_registry.gd`. No edits to dock or facade required.

### 4. Try it

- *"Show me the current scene hierarchy."*
- *"Create a Camera3D named MainCamera under /Main."*
- *"Search the project for PackedScene files in ui/."*
- *"Run the scene test suite."*
- *"Build a neon space city with glass towers, glowing planets, and fire / magic / spark particle effects."*

<p align="center">
  <a href="docs/images/space-city.png"><img src="docs/images/space-city.png" alt="Space city scene — neon towers, glowing planets, Tron streets, and varied particle FX, all built from MCP tool calls" width="640"></a>
</p>
<p align="center"><em>An AI-authored scene: 10 emissive buildings, 3 glowing planets, Tron-style floor strips, and 6 varied particle effects — every node, material, and preset placed by MCP tool calls.</em></p>

---

<details>
<summary><strong>Available Tools</strong></summary>

### Sessions and Editor

| Tool | Description |
|------|-------------|
| `session_list` | List connected Godot editor sessions |
| `session_activate` | Set the active session for multi-editor routing |
| `editor_state` | Read Godot version, project name, current scene, and play state |
| `editor_selection_get` / `editor_selection_set` | Read or set the editor selection |
| `editor_screenshot` | Capture the editor viewport or a sub-viewport |
| `editor_reload_plugin` / `editor_quit` | Reload the plugin or quit the editor |
| `logs_read` / `logs_clear` | Read or clear recent MCP log lines |
| `performance_monitors_get` | Read Godot performance monitors (FPS, memory, draw calls, etc.) |
| `batch_execute` | Run multiple plugin commands in one round trip |

### Scene and Nodes

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

### Scripts and Signals

| Tool | Description |
|------|-------------|
| `script_create` / `script_read` / `script_patch` | Create, read, or patch GDScript files |
| `script_attach` / `script_detach` | Attach or detach scripts from nodes |
| `script_find_symbols` | Find class, function, or signal symbols in project scripts |
| `signal_list` / `signal_connect` / `signal_disconnect` | Inspect and wire up signals |

### Resources, Materials, Textures

| Tool | Description |
|------|-------------|
| `resource_create` / `resource_load` / `resource_assign` / `resource_get_info` / `resource_search` | Create, load, assign, and search `.tres` / `.res` resources |
| `material_create` / `material_list` / `material_get` | Create and inspect materials |
| `material_assign` / `material_apply_to_node` / `material_apply_preset` | Assign materials and apply named presets |
| `material_set_param` / `material_set_shader_param` | Set material or shader parameters |
| `gradient_texture_create` / `noise_texture_create` | Generate gradient or noise textures |
| `curve_set_points` | Set points on a `Curve` resource |

### UI, Controls, Theme

| Tool | Description |
|------|-------------|
| `ui_build_layout` | Build a Control layout tree from a recipe |
| `ui_set_text` / `ui_set_anchor_preset` | Set Control text or anchor preset |
| `control_draw_recipe` | Attach a procedural draw recipe script to a Control |
| `theme_create` / `theme_apply` | Create themes and apply them to Controls |
| `theme_set_color` / `theme_set_constant` / `theme_set_font_size` / `theme_set_stylebox_flat` | Edit theme entries |

### Animation

| Tool | Description |
|------|-------------|
| `animation_player_create` | Create an `AnimationPlayer` node |
| `animation_create` / `animation_create_simple` / `animation_delete` | Create or delete animations |
| `animation_list` / `animation_get` / `animation_validate` | Inspect and validate animations |
| `animation_add_property_track` / `animation_add_method_track` | Add property or method tracks |
| `animation_play` / `animation_stop` / `animation_set_autoplay` | Playback controls |
| `animation_preset_fade` / `animation_preset_pulse` / `animation_preset_shake` / `animation_preset_slide` | Named animation presets |

### Audio

| Tool | Description |
|------|-------------|
| `audio_player_create` / `audio_list` | Create and list audio players |
| `audio_play` / `audio_stop` | Control playback |
| `audio_player_set_stream` / `audio_player_set_playback` | Assign streams and tune playback |

### Particles, Environment, Camera

| Tool | Description |
|------|-------------|
| `particle_create` / `particle_get` / `particle_restart` | Create, inspect, restart particle systems |
| `particle_set_main` / `particle_set_process` / `particle_set_draw_pass` / `particle_apply_preset` | Configure particle nodes |
| `environment_create` | Create a `WorldEnvironment` with a configured `Environment` |
| `camera_create` / `camera_list` / `camera_get` | Create and inspect cameras |
| `camera_configure` / `camera_apply_preset` | Tune camera settings or apply presets |
| `camera_follow_2d` / `camera_set_limits_2d` / `camera_set_damping_2d` | 2D camera helpers |
| `physics_shape_autofit` | Auto-fit a collision shape to a mesh |

### Project, Filesystem, Input

| Tool | Description |
|------|-------------|
| `project_settings_get` / `project_settings_set` | Read or write Godot project settings |
| `project_run` / `project_stop` | Run or stop the project from the editor |
| `autoload_add` / `autoload_remove` / `autoload_list` | Manage autoload singletons |
| `filesystem_search` / `filesystem_read_text` / `filesystem_write_text` / `filesystem_reimport` | Search, read, write, and reimport project files |
| `input_map_add_action` / `input_map_remove_action` / `input_map_bind_event` / `input_map_list` | Manage the project input map |

### Testing and Client Setup

| Tool | Description |
|------|-------------|
| `test_run` | Run GDScript test suites inside the editor |
| `test_results_get` | Read the most recent test results without rerunning |
| `client_configure` / `client_remove` / `client_status` | Configure, remove, or check supported MCP clients |

</details>

<details>
<summary><strong>MCP Resources</strong></summary>

| Resource URI | Description |
|-------------|-------------|
| `godot://sessions` | Connected editor sessions with metadata |
| `godot://scene/current` | Current scene path, project name, and play state |
| `godot://scene/hierarchy` | Full scene hierarchy from the active editor |
| `godot://selection/current` | Current editor selection |
| `godot://project/info` | Active project metadata |
| `godot://project/settings` | Common project settings subset |
| `godot://logs/recent` | Recent editor log lines |

</details>

<details>
<summary><strong>Manual Client Configuration</strong></summary>

**Claude Code**

```bash
claude mcp add --scope user --transport http godot-ai http://127.0.0.1:8000/mcp
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers."godot-ai"]
url = "http://127.0.0.1:8000/mcp"
enabled = true
```

**Antigravity** (`~/.gemini/antigravity/mcp_config.json`)

```json
{
  "mcpServers": {
    "godot-ai": {
      "serverUrl": "http://127.0.0.1:8000/mcp",
      "disabled": false
    }
  }
}
```

</details>

<details>
<summary><strong>How It Works</strong></summary>

```text
MCP Client
   | HTTP (/mcp)
   v
Python Server (FastMCP)      port 8000
   | WebSocket               port 9500
   v
Godot Editor Plugin
   | EditorInterface + SceneTree APIs
   v
Godot Editor
```

The plugin starts or reuses the Python server, connects over WebSocket, and exposes editor capabilities as MCP tools and resources over HTTP.

</details>

<details>
<summary><strong>Contributing</strong></summary>

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for development setup, testing, and PR guidelines.

</details>

---

**License:** [MIT](LICENSE) | **Issues:** [GitHub](https://github.com/hi-godot/godot-ai/issues)
