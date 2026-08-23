<p align="center">
  <img src="docs/hero.png" alt="Godot AI — The wait is over" width="700">
</p>

# Godot AI

[![CI](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml/badge.svg)](https://github.com/hi-godot/godot-ai/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/hi-godot/godot-ai/graph/badge.svg)](https://codecov.io/gh/hi-godot/godot-ai)
[![Godot Asset Library](https://img.shields.io/badge/Godot-Asset%20Library-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org/asset-library/asset/5050)
[![Discord](https://img.shields.io/badge/Discord-Join%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/FDZ5fr2QkP)

**Connect MCP clients directly to a live Godot editor** via the [Model Context Protocol](https://modelcontextprotocol.io/introduction). Over **120 ops across ~43 MCP tools** ([full list](docs/TOOLS.md)) let AI assistants (Claude Code, Codex, **Grok Build**, Antigravity, Hermes Agent, etc.) build scenes, edit nodes and scripts, wire signals, and configure UI, materials, animations, particles, cameras, and environments.

> 🎉 **Now on the [Godot Asset Library](https://godotengine.org/asset-library/asset/5050) and the [new Godot Asset Store](https://store.godotengine.org/asset/dlight/godot-ai/)** — one-click install from Godot's **AssetLib** tab. You'll still need [uv](https://docs.astral.sh/uv/) for the Python server (see [Quick Start](#quick-start)).

<img src="docs/images/assetlib.png" alt="Godot AI on the Godot Asset Library" width="312">

> 💬 **[Join the Discord](https://discord.gg/FDZ5fr2QkP)** — questions, showcases, and contributor chat.

---

<p align="center">
  <img src="docs/images/huddemo.gif" alt="Cyberpunk HUD demo" width="800"><br>
  <em>UI demo built in ~2 hours with zero coding, zero image gen, all programmatically drawn by Godot AI — <a href="https://github.com/hi-godot/cyberpunk-hud-demo">source</a></em>
</p>

---

## Quick Start

### Prerequisites

- Godot `4.5+` (`4.7+` recommended)
- [uv](https://docs.astral.sh/uv/) (for the Python server)

  <details>
  <summary>How to install uv (macOS / Linux / Windows / package managers)</summary>

  - **macOS / Linux:** `curl -LsSf https://astral.sh/uv/install.sh | sh`
  - **Windows (PowerShell):** `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`
  - **Prefer your package manager?** `uv` is a popular open-source tool packaged in
    most distro repos, so you don't have to pipe a script from the web:
    - **Arch:** `sudo pacman -S uv`
    - **Debian / Ubuntu:** `sudo apt install uv` (older releases: `pipx install uv` or the script above)
    - **Fedora:** `sudo dnf install uv`
    - **macOS (Homebrew):** `brew install uv`
  - Other options: [uv install docs](https://docs.astral.sh/uv/getting-started/installation/)

  </details>
- An MCP client ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) | [Codex](https://openai.com/index/codex/) | [Antigravity](https://www.antigravity.dev/))

### 1. Install the plugin

**Recommended — install from source** (always the latest):

```bash
git clone https://github.com/hi-godot/godot-ai.git
cp -r godot-ai/plugin/addons/godot_ai your-project/addons/
```

Or [download the latest release ZIP](https://github.com/hi-godot/godot-ai/releases/latest) and extract `addons/godot_ai` into your project's `addons/` folder.

<details>
<summary>Or via the Godot Asset Library</summary>

In Godot, open the **AssetLib** tab, search for **Godot AI**, click **Download**, then **Install**. Note: Asset Library updates lag behind GitHub, so this version may not be the most recent.

> 🚨 **If installing from the Asset Library**, most issues can be resolved by disabling and re-enabling the plugin in **Project > Project Settings > Plugins**.

</details>

### 2. Enable the plugin

In Godot: **Project > Project Settings > Plugins** — enable **Godot AI**.

The plugin will automatically start the MCP server, connect over WebSocket, and show status in the **Godot AI** dock.

<p align="center"><img src="docs/images/dock.png" alt="Godot AI dock — Clients & Tools button highlighted" width="350"></p>

### 3. Connect your MCP client

The dock lists every supported client with a status dot and per-row
**Configure** / **Remove** buttons, or press **Configure all**. Auto-configure
covers:

- **Claude Code**, **Claude Desktop**, **Antigravity**, **Hermes Agent**

<details>
<summary><strong>…and 17+ more clients</strong></summary>

Codex, **Grok Build**, Cursor, Devin Desktop (formerly Windsurf), VS Code, VS Code Insiders, Zed, Gemini CLI, Cline,
Kilo Code, Roo Code, Zoo Code, Kiro, Trae, Cherry Studio, OpenCode, Qwen Code,
Kimi Code.

</details>

Nearly every client is configured with the client-owned `godot-ai attach`
stdio bridge: the client launches a local command that starts or adopts the
shared HTTP backend, so tools are discoverable before Godot opens and keep
working across same-version editor restarts. Each dock row carries an
`attach` / `URL` tag naming which transport Configure writes. If
auto-configure can't find a compatible local launcher, the row exposes a
**Run this manually** panel with a copyable snippet, and clients whose native
configuration supports URL transport also show an advanced URL fallback.
(Cherry Studio intentionally stays URL-mode — its MCP servers are managed
inside the app, not via an external config file.)

<details>
<summary><strong>Registering per-project instead of globally</strong></summary>

CLI-configured clients register at **user** scope by default, which is a single
global config the client loads in every workspace — so the Godot AI tools are
present even in projects that have nothing to do with Godot.

Set **Editor Settings → Plugins → `godot_ai/mcp_client_scope`** to `project` and
Configure writes the entry into the project's own config (for Claude Code,
`<project>/.mcp.json`) instead. The server is then loaded only when the client is
opened on that project. `local` is also accepted for clients that support it.

The default stays `user` so existing installs are unchanged on upgrade. To move
an existing entry, change the setting and press **Configure** again — Configure
clears `godot-ai` out of every scope before writing the new one, so the old
entry doesn't linger. **Remove**, by contrast, only targets the scope that is
currently selected, so switch back before removing if you changed the setting.

Two caveats for `project` scope:

- The client CLI resolves the project config against **its own working
  directory**, which is the one the Godot editor was launched from — not
  necessarily the project folder. Launching Godot from the project directory
  (or from a shell already `cd`'d into it) puts `.mcp.json` where you expect.
- Claude Code will not actually load a `project`-scoped server until you
  approve it: run `claude` in that project once and accept the prompt. Until
  then `claude mcp get godot-ai` reports *Pending approval*, and an older
  `user`-scoped entry can keep answering in its place.
- Status for a project- or local-scoped entry is read back by asking the client
  CLI about the server rather than by reading the config file directly. The
  dock reports configured / not configured correctly and will flag an entry
  that resolved from a different scope than the one you selected, but it can no
  longer spot a stale entry whose *arguments* drifted — press **Configure**
  again after changing the port or excluded domains.

</details>

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

**Tools and resources:** see [docs/TOOLS.md](docs/TOOLS.md) for the full tool, op, and resource list (~43 tools exposing 120+ ops, plus read-only `godot://` resources), grouped by domain.

**Testing:** the plugin ships an in-editor GDScript test framework — your AI client (or you) can write `McpTestSuite` suites for your own game under `res://tests/` and run them with `test_run`. See [docs/testing.md](docs/testing.md).

<details>
<summary><strong>Manual Client Configuration</strong></summary>

**Claude Code**

```bash
claude mcp add --scope user --transport http godot-ai http://127.0.0.1:8000/mcp
```

**Claude Desktop** (`claude_desktop_config.json`)

Claude Desktop local configuration requires a launched stdio command. Per
[Anthropic's remote MCP guidance](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp),
it does not accept a remote `url` entry in `claude_desktop_config.json`;
Claude's remote Connectors flow is cloud-brokered and cannot reach this
loopback-only server.
Use the dock-generated entry so the command is an absolute, GUI-safe launcher.
Its non-Windows uvx shape is:

```json
{
  "mcpServers": {
    "godot-ai": {
      "command": "/absolute/path/to/uvx",
      "args": ["--link-mode", "copy", "--from", "godot-ai==VERSION", "godot-ai", "attach", "--port", "8000", "--ws-port", "9500"]
    }
  }
}
```

On Windows, the dock also detects Store/MSIX AppData virtualization. When one
Store package is installed, Configure uses its private `LocalCache/Roaming`
path, creating the config there if necessary so a later copy-on-write cannot
hide an entry written to conventional roaming. If the private file is new and
the roaming config already exists, its full contents seed the private file
before the `godot-ai` entry is merged; the roaming source remains byte-identical.
Without a Store package it uses the conventional roaming config. Multiple
matching Store packages fail with an actionable error instead of choosing one,
and Configure never writes both.

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers."godot-ai"]
command = "godot-ai"
args = [
  "attach",
  "--port", "8000",
  "--ws-port", "9500",
]
enabled = true
startup_timeout_sec = 60
tool_timeout_sec = 360
```

The dock chooses a compatible launcher automatically: a development venv,
an exact-version `uvx --link-mode copy --from godot-ai==VERSION ...` command,
or a matching system `godot-ai` install. Re-run **Configure** after changing
ports, excluded tool domains, or plugin versions so those launch arguments
stay synchronized.

On Windows, **Configure** writes a `pythonw.exe` launch (and, for uvx/system
tiers, a small stdio-preserving `CREATE_NO_WINDOW` bootstrap). This prevents a
terminal window from opening with Claude Desktop or Codex while keeping the MCP
process attached to the client's stdin/stdout pipes. Do not simplify that
generated entry back to a console-subsystem `python.exe`, `uvx.exe`, or
`godot-ai.exe` command. Antigravity is the exception: its spawner hangs tool
calls behind a GUI-subsystem executable (#863), so its entry is written with
the plain console command instead — Antigravity hides child console windows
itself.

Advanced fallback for clients intentionally kept in URL mode:

```toml
[mcp_servers."godot-ai"]
url = "http://127.0.0.1:8000/mcp"
enabled = true
```

URL mode depends on the client's own reconnect behavior. If Godot AI is not
running when the client starts, a client restart may still be required.

**Grok Build** (`~/.grok/config.toml`)

```toml
[mcp_servers."godot-ai"]
command = "/absolute/path/to/uvx"
args = [
  "--link-mode",
  "copy",
  "--from",
  "godot-ai==VERSION",
  "godot-ai",
  "attach",
  "--port", "8000",
  "--ws-port", "9500",
]
startup_timeout_sec = 60
```

Or dock → **Clients** → **Grok Build** → **Configure**.

**Antigravity** (`~/.gemini/config/mcp_config.json`)

```json
{
  "mcpServers": {
    "godot-ai": {
      "command": "/absolute/path/to/uvx",
      "args": ["--link-mode", "copy", "--from", "godot-ai==VERSION", "godot-ai", "attach", "--port", "8000", "--ws-port", "9500"],
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
<summary><strong>Remote / LAN access (<code>--allow-host</code>)</strong></summary>

The MCP server binds to `127.0.0.1` by default. To reach it from another
machine on your network (e.g. a remote coding agent), pass `--allow-host`
with one or more CIDRs or bare IPs (repeat the flag or comma-separate
values) when launching the server:

```bash
godot-ai --allow-host 192.168.1.0/24
```

This binds the HTTP transport off loopback and gates every request on the
real (unforgeable) socket peer address, so only hosts inside the named
range(s) get in — DNS-rebinding defenses (Origin / Host / Sec-Fetch-Site
checks) stay active. The plugin's WebSocket bridge to the editor always
stays loopback-only since it's unauthenticated. Only name ranges you trust;
prefer an SSH tunnel or Tailscale on untrusted networks.

</details>

<details>
<summary><strong><code>ImportError</code> from <code>mcp-proxy</code> (<code>streamablehttp_client</code> or <code>request_ctx</code>)</strong></summary>

An older client configuration may launch `mcp-proxy` against an unbounded
`mcp>=1.17.0` dependency. `mcp` 2.x is incompatible with released
`mcp-proxy` versions: 0.11.0 fails on `streamablehttp_client`, while 0.12.0
contains both incompatible imports and may report `request_ctx` first.

Preferred fix: update Godot AI, click **Configure** for Claude Desktop, and
restart it. This replaces the legacy proxy entry with the current
`godot-ai attach` launcher. As a temporary workaround, constrain the old uvx
command with `--with "mcp<2"` before its `mcp-proxy` package argument.

</details>

<details>
<summary><strong>Windows: an <code>uvx</code> attach launcher won't start (<code>pywin32</code> install fails)</strong></summary>

Symptom (in your MCP client's server log):

```text
error: Failed to install: pywin32-311-cp313-cp313-win_amd64.whl (pywin32==311)
  Caused by: failed to remove directory `C:\Users\<you>\AppData\Local\uv\cache\builds-v0\.tmpXXXXXX\Lib\site-packages\pywin32-311.data`: ... os error 32
```

Cause: uv hard-links shared `.pyd` files (notably
`pydantic_core/_pydantic_core.cp313-win_amd64.pyd`) from `archive-v0\` into
each new `builds-v0\.tmpXXXXXX\` build venv. The running `godot-ai` Python
process has the same `.pyd` mapped via `LoadLibrary` — and because hard
links share the inode, Windows refuses to delete it under any path until
every process unmaps it. uv's post-install cleanup of the build venv then
dies on a stale lock; the misleading `pywin32` mention is just the last
package in the resolution order, not the actual lock holder.

**Mitigation in this plugin:**

1. `_stop_server` and `force_restart_server` both call
   `McpUvCacheCleanup.purge_stale_builds()` immediately after killing the
   server children, while the `.pyd` is briefly unmapped. See
   [`plugin/addons/godot_ai/utils/uv_cache_cleanup.gd`](plugin/addons/godot_ai/utils/uv_cache_cleanup.gd).
2. Attach entries put `--link-mode copy` directly in the generated uvx
   arguments, telling uv to copy shared C extensions instead of hard-linking
   them. This works for configuration formats that do not support an `env`
   object and removes the reverse race where an MCP client starts its attach
   launcher while a server child still holds the `.pyd`.

The shape `client_configure` writes for Claude Desktop is now:

```json
{
  "mcpServers": {
    "godot-ai": {
      "command": "/absolute/path/to/uvx",
      "args": ["--link-mode", "copy", "--from", "godot-ai==VERSION", "godot-ai", "attach", "--port", "8000", "--ws-port", "9500"]
    }
  }
}
```

The exact command may be an absolute uvx path or a Windows `pythonw.exe`
bootstrap; use the dock-generated form rather than simplifying it. If you've
already hit the lock, click **Configure** on Claude Desktop to rewrite its old
mcp-proxy entry to the attach shape, then quit and reopen Claude Desktop. If the
lock persists (rare — pre-existing orphans the cache sweeper couldn't reach),
kill stray `python.exe` children whose command line contains
`spawn_main(parent_pid=...)` and delete
`%LOCALAPPDATA%\uv\cache\builds-v0\.tmp*` manually before retrying.

</details>

<details>
<summary><strong>Contributing</strong></summary>

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for development setup, testing, and PR guidelines. AI assistants should also read [AGENTS.md](AGENTS.md).

**Windows contributors:** run `.\script\setup-dev.ps1` in PowerShell. It builds `test_project\addons\godot_ai` as a directory junction — no admin rights and no Windows Developer Mode required.

</details>

<details>
<summary><strong>Telemetry &amp; Privacy</strong></summary>

Godot AI ships anonymous, privacy-focused telemetry (no code, no scene contents, no project or file names, no personal data). Project-directory slugs are sha256-hashed before any event leaves your machine; only an anonymous installation UUID, the tool/event name, success/duration, and platform/version fields are sent.

Opt out by setting either environment variable to `true`:

```bash
export GODOT_AI_DISABLE_TELEMETRY=true
# or the cross-tool convention
export DISABLE_TELEMETRY=true
```

Opt-out is fully side-effect-free — no UUID generated, no worker thread, no files written.

Full details (what's collected, where data lives, how to self-host the endpoint): [docs/TELEMETRY.md](docs/TELEMETRY.md).

</details>

---

## Star History

<!-- Regenerated daily by .github/workflows/star-history.yml (#750):
     GitHub restricted stargazer history to repo collaborators, which broke
     star-history.com's unauthenticated embed, so the chart is rendered in CI
     and published to the dedicated `star-history` branch (do not delete it —
     embedded below; a manual workflow run recreates it if needed). -->
<a href="https://github.com/hi-godot/godot-ai/stargazers">
  <img src="https://raw.githubusercontent.com/hi-godot/godot-ai/star-history/star-history.svg" alt="Star History Chart" width="700">
</a>

---

**License:** [MIT](LICENSE) | **Issues:** [GitHub](https://github.com/hi-godot/godot-ai/issues)
