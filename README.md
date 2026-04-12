# Godot AI

[![CI](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml/badge.svg)](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/hi-godot/godot-ai/graph/badge.svg)](https://codecov.io/gh/hi-godot/godot-ai)

Production-grade MCP server and AI tools for the Godot engine.

> **Status: Early development.** Core read tools working, write tools coming.

*This is an independent community project, not affiliated with or endorsed by the [Godot Foundation](https://godot.foundation). Godot Engine is a free and open-source project under the [MIT license](https://godotengine.org/license).*

## How it works

```
AI Client (Claude Code, Antigravity, etc.)
   │ MCP (HTTP)
   ▼
Python Server (FastMCP) ← started by the Godot plugin
   │ WebSocket
   ▼
Godot Editor Plugin (GDScript)
   │ EditorInterface + SceneTree APIs
   ▼
Godot Editor
```

The Godot plugin starts a shared Python server. MCP clients connect via HTTP. The plugin connects via WebSocket. All clients share the same server and see the same Godot sessions.

## Quick start

### 1. Install uv

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Windows
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

### 2. Install the plugin

Copy `plugin/addons/godot_ai/` into your Godot project's `addons/` folder.

### 3. Enable the plugin

In Godot: **Project > Project Settings > Plugins** — enable "Godot AI".

The plugin will:
- Install and start the MCP server automatically (via uvx)
- Connect to the server via WebSocket
- Show connection status in the Godot AI dock panel

### 4. Connect an AI client

Use the dock panel's **Configure** buttons, or manually:

**Claude Code:**
```bash
claude mcp add --scope user --transport http godot-ai http://127.0.0.1:8000/mcp
```

**Antigravity** (`~/.gemini/antigravity/mcp_config.json`):
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

## Tools

| Tool | Description |
|------|-------------|
| `session_list` | List connected Godot editor sessions |
| `session_activate` | Set the active session for multi-editor routing |
| `editor_state` | Get Godot version, project name, current scene, play state |
| `editor_selection_get` | Get currently selected nodes |
| `scene_get_hierarchy` | Read the full scene tree with node types and paths |
| `scene_get_roots` | Get all open scenes in the editor |
| `node_create` | Create nodes by type with optional name and parent path |
| `node_find` | Find nodes by name, type, or group |
| `node_get_properties` | Get all properties of a node |
| `node_get_children` | Get direct children of a node |
| `node_get_groups` | Get groups a node belongs to |
| `project_settings_get` | Get a Godot project setting by key |
| `filesystem_search` | Search project files by name, type, or path |
| `logs_read` | Read recent MCP command log from the Godot console |
| `run_tests` | Run GDScript test suites inside the editor |
| `get_test_results` | Get results from the last test run |
| `client_configure` | Configure an MCP client (Claude Code / Antigravity) |
| `client_status` | Check which clients are configured |

## Resources

| Resource URI | Description |
|-------------|-------------|
| `godot://sessions` | All connected editor sessions with metadata |
| `godot://scene/current` | Current scene path, project name, play state |
| `godot://scene/hierarchy` | Full scene tree (nodes, types, paths) |
| `godot://selection/current` | Currently selected nodes |
| `godot://project/info` | Project name, Godot version, paths |
| `godot://project/settings` | Common settings (display, physics, rendering) |
| `godot://logs/recent` | Last 100 log lines from the editor console |

## Ports

| Port | Purpose |
|------|---------|
| 9500 | WebSocket — Godot plugin connects here |
| 8000 | HTTP — MCP clients connect here (`/mcp` endpoint) |

## Requirements

- Godot 4.3+ (4.4+ recommended, tested on 4.6.2)
- [uv](https://docs.astral.sh/uv/) (for server installation)

## Development

```bash
# Setup (handles macOS Python 3.13 .pth fix automatically)
script/setup-dev

# Run Python tests (81 unit + integration)
pytest -v

# Run Godot-side tests (44 handler tests, requires editor running)
# Use the run_tests MCP tool

# Lint
ruff check src/ tests/

# Start server with auto-reload (dev)
python -m godot_ai --transport streamable-http --port 8000 --reload
```

### Contributing

Work on feature branches and open PRs against `main`:

```bash
git checkout -b feature/my-feature
# ... make changes ...
pytest -v                    # Python tests must pass
ruff check src/ tests/       # Lint must pass
# Also run Godot-side tests via the run_tests MCP tool
git push -u origin feature/my-feature
gh pr create
```

PRs should include tests for new functionality (both Python and Godot-side where applicable).

## License

TBD
