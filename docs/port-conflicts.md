# Port 8000 is in use by another process

Godot AI's Python server listens on HTTP port `8000` (and WebSocket port
`9500`). Port `8000` is a popular default for other dev tools — Django,
`python -m http.server`, and many local servers grab it — so a genuinely
foreign occupant is not rare.

When a **non-godot-ai** process is already bound to `8000`, the dock can't
reclaim the port (it has no proof it owns whatever is there), so it stops and
shows a message like:

> Port 8000 is occupied by an incompatible server. Port 8001 is free — set
> `godot_ai/http_port` in Editor Settings, then update your client config.

The crash panel names a concrete free port for you. This guide covers the
second half: changing the port and pointing your MCP clients at the new one.

> If the dock instead offers a **Restart Server** button, the occupant is an
> older godot-ai server it *can* reclaim — click that rather than changing the
> port. This guide is only for the foreign-process case.

## 1. Pick free ports

The plugin uses **two** ports: HTTP (`8000`, the one your MCP clients talk to)
and WebSocket (`9500`, used internally between the server and the editor). The
crash body suggests a free value for each (e.g. HTTP `8001`, WS `9501`). On
Windows those suggestions are checked against the Hyper-V / WSL2 / Docker
reservation table, so they won't themselves fail with `WinError 10013`. You can
use the suggested ports or choose your own free ones.

If only port `8000` is taken, you technically only need to move the HTTP port —
but the incompatible-server case that lands you here can hold both, so changing
both settings is the reliable fix.

## 2. Change `godot_ai/http_port` and `godot_ai/ws_port` in Editor Settings

1. In the Godot editor, open **Editor → Editor Settings**.
2. Search for `godot_ai/http_port` and set it to the free HTTP port from step 1
   (e.g. `8001`).
3. Search for `godot_ai/ws_port` and set it to the free WS port from step 1
   (e.g. `9501`).
4. Reload the plugin (toggle it off/on in **Project → Project Settings →
   Plugins**, or restart the editor).

> **Note:** both are **Editor Settings**, not project settings — they are
> stored per editor install, so the change applies to *every* project you open
> with this editor. If you only hit the conflict on one machine, remember to
> revert them later if the foreign process goes away.

## 3. Reconfigure your MCP clients

Editor Settings only moves the *server*. URL-mode clients still point at the
old URL (`http://127.0.0.1:8000/mcp`), while attach-mode Claude Desktop and
Codex entries still carry the old HTTP and WebSocket ports in their `args`.
Both need reconfiguration.

The fastest way is the dock itself: each client row's **Configure** button
rewrites that client's config with the current server URL, so once the server
is on the new port, click **Configure** (or **Configure all**) again to rewrite
every already-configured client.

If you configured a client by hand, update its URL to use the new port. For
example, for Claude Code:

```bash
claude mcp remove godot-ai
claude mcp add --scope user --transport http godot-ai http://127.0.0.1:8001/mcp
```

For attach-mode Claude Desktop and Codex, re-running **Configure** is preferred
because it updates both `--port` and `--ws-port` and re-verifies the package pin
and excluded tool domains. If editing by hand, change the values following
those two flags in the `args` array; there is no `url` field in an attach entry.

For URL-mode config-file clients (Grok Build, Antigravity, Cursor, …), edit the
`url` / `serverUrl` field to match the new HTTP port. See the **Manual Client
Configuration** section in the [README](../README.md) for each client's file
and format. Grok Build uses `~/.grok/config.toml`
(`[mcp_servers.godot-ai]`).

## Reverting

If the foreign process is gone and you want the defaults back, set
`godot_ai/http_port` back to `8000` and `godot_ai/ws_port` back to `9500` (or
clear the overrides) in Editor Settings, reload the plugin, and re-run
**Configure all** to point your clients back.
