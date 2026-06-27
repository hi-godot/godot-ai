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

## 1. Pick a free port

The crash body already suggests one (e.g. `8001`). On Windows that suggestion
is checked against the Hyper-V / WSL2 / Docker reservation table, so it won't
itself fail with `WinError 10013`. You can use the suggested port or choose
your own free port.

## 2. Change `godot_ai/http_port` in Editor Settings

1. In the Godot editor, open **Editor → Editor Settings**.
2. Search for `godot_ai/http_port`.
3. Set it to the free port from step 1 (e.g. `8001`).
4. Reload the plugin (toggle it off/on in **Project → Project Settings →
   Plugins**, or restart the editor).

> **Note:** `godot_ai/http_port` is an **Editor Setting**, not a project
> setting — it is stored per editor install, so the change applies to *every*
> project you open with this editor. If you only hit the conflict on one
> machine, remember to revert it later if the foreign process goes away.

## 3. Reconfigure your MCP clients

Editor Settings only moves the *server*. Every MCP client still points at the
old URL (`http://127.0.0.1:8000/mcp`), so they'll silently fail to connect
until you update them too.

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

For config-file clients (Codex, Antigravity, Cursor, …), edit the `url` /
`serverUrl` field to match the new port. See the **Manual Client
Configuration** section in the [README](../README.md) for each client's file
and format.

## Reverting

If the foreign process is gone and you want `8000` back, set
`godot_ai/http_port` back to `8000` (or clear the override) in Editor Settings,
reload the plugin, and re-run **Configure all** to point your clients back.
