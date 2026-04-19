<p align="center">
  <img src="docs/hero.png" alt="Godot AI — The wait is over" width="700">
</p>

# Godot AI

[![CI](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml/badge.svg)](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/hi-godot/godot-ai/graph/badge.svg)](https://codecov.io/gh/hi-godot/godot-ai)
[![Godot Asset Library](https://img.shields.io/badge/Godot-Asset%20Library-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org/asset-library/asset/5050)
[![Discord](https://img.shields.io/badge/Discord-Join%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/FDZ5fr2QkP)

**Connect MCP clients directly to a live Godot editor** via the [Model Context Protocol](https://modelcontextprotocol.io/introduction). Over **120 MCP tools** ([full list](docs/TOOLS.md)) let AI assistants (Claude Code, Codex, Antigravity, etc.) build scenes, edit nodes and scripts, wire signals, and configure UI, materials, animations, particles, cameras, and environments.

> 🎉 **Now on the [Godot Asset Library](https://godotengine.org/asset-library/asset/5050)** — one-click install from Godot's **AssetLib** tab. You'll still need [uv](https://docs.astral.sh/uv/) for the Python server (see [Quick Start](#quick-start)).

<p align="center"><img src="docs/images/assetlib.png" alt="Godot AI on the Godot Asset Library" width="520"></p>

> 💬 **[Join the Discord](https://discord.gg/FDZ5fr2QkP)** — questions, showcases, and contributor chat.

*Independent community project, not affiliated with the [Godot Foundation](https://godot.foundation). Godot Engine is [MIT-licensed](https://godotengine.org/license).*

---

<p align="center">
  <img src="docs/images/huddemo.gif" alt="Cyberpunk HUD demo" width="800"><br>
  <em>UI demo built in ~2 hours with zero coding, zero image gen, all programmatically drawn by Godot AI — <a href="https://github.com/hi-godot/cyberpunk-hud-demo">source</a></em>
</p>

---

## Quick Start

### Prerequisites

- Godot `4.3+` (`4.4+` recommended)
- [uv](https://docs.astral.sh/uv/) (for the Python server):
  - **macOS / Linux:** `curl -LsSf https://astral.sh/uv/install.sh | sh`
  - **Windows (PowerShell):** `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`
  - Other options: [uv install docs](https://docs.astral.sh/uv/getting-started/installation/)
- An MCP client ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) | [Codex](https://openai.com/index/codex/) | [Antigravity](https://www.antigravity.dev/))

### 1. Install the plugin

**Recommended — via the [Godot Asset Library](https://godotengine.org/asset-library/asset/5050):** in Godot, open the **AssetLib** tab, search for **Godot AI**, click **Download**, then **Install**.

<details>
<summary>Or install from source</summary>

```bash
git clone https://github.com/hi-godot/godot-ai.git
cp -r godot-ai/plugin/addons/godot_ai your-project/addons/
```

Alternatively, [download the latest release ZIP](https://github.com/hi-godot/godot-ai/releases/latest) and extract `addons/godot_ai` into your project's `addons/` folder.

</details>

### 2. Enable the plugin

In Godot: **Project > Project Settings > Plugins** — enable **Godot AI**.

The plugin will automatically start the MCP server, connect over WebSocket, and show status in the **Godot AI** dock.

<p align="center"><img src="docs/images/dock.png" alt="Godot AI dock" width="640"></p>

### 3. Connect your MCP client

The dock lists every supported client with a status dot and per-row
**Configure** / **Remove** buttons, or press **Configure all**. Auto-configure
covers:

- **Claude Code**, **Claude Desktop**, **Antigravity**

<details>
<summary><strong>…and 15+ more clients</strong></summary>

Codex, Cursor, Windsurf, VS Code, VS Code Insiders, Zed, Gemini CLI, Cline,
Kilo Code, Roo Code, Kiro, Trae, Cherry Studio, OpenCode, Qwen Code.

</details>

Server URL is always `http://127.0.0.1:8000/mcp`. If auto-configure can't find
a CLI, each dock row exposes a **Run this manually** panel with a copyable
snippet.

### 4. Try it

- *"Show me the current scene hierarchy."*
- *"Create a Camera3D named MainCamera under /Main."*
- *"Search the project for PackedScene files in ui/."*
- *"Run the scene test suite."*
- *"Build a voxel block-world game with a player, blocks to place and destroy, and save slots."*

<p align="center">
  <img src="docs/images/blockarena.gif" alt="Block-world game scene built from MCP tool calls — voxel terrain, player, and UI" width="640">
</p>
<p align="center"><em>Demo gamelet with sophisticated save system built from a handful of Godot AI MCP prompts. Code and Godot project  <a href="https://github.com/dsarno/save-system-godot-claude">available free here</a>.</em></p>

---

**Tools and resources:** see [docs/TOOLS.md](docs/TOOLS.md) for the full list of 120+ MCP tools and resources, grouped by domain.

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

## Star History

<a href="https://star-history.com/#hi-godot/godot-ai&Date">
  <img src="https://api.star-history.com/svg?repos=hi-godot/godot-ai&type=Date" alt="Star History Chart" width="700">
</a>

---

**License:** [MIT](LICENSE) | **Issues:** [GitHub](https://github.com/hi-godot/godot-ai/issues)
