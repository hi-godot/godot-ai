# Port 8000 is in use by another process

Godot AI's local Python backend listens on HTTP port `8000`; its authenticated
editor WebSocket listens on `9500`. Port `8000` is also a common default for
Django, `python -m http.server`, and other development servers.

When a foreign process owns either port, Godot AI does not kill or reuse it.
The dock reports the conflict and suggests free replacements, for example:

> Port 8000 is occupied by an incompatible server. Choose both ports below,
> click Apply + Reload, then Configure your AI clients to use the new pair.

This guide covers that foreign-process case. If the dock identifies a stale
Godot AI process that it can prove belongs to the same local account, use the
dock's recovery action instead.

## 1. Choose free ports

The plugin needs both an HTTP port and a WebSocket port. The conflict message
suggests values checked by the plugin (for example `8001` and `9501`). On
Windows the check also excludes Hyper-V, WSL2, and Docker reserved ranges.

Move only the occupied port if the other one is free. Moving both is often
simpler when another tool owns the same pair.

## 2. Apply the ports in the dock

1. In the conflict panel, choose distinct HTTP and WebSocket ports.
2. Click **Apply + Reload**. The plugin saves the effective pair and reloads.
3. Reconfigure your clients as described below.

For manual changes in **Editor → Editor Settings**, a migrated installation's
`godot_ai/v4_endpoint_ports` Dictionary takes precedence over the legacy
`godot_ai/http_port` and `godot_ai/ws_port` settings. Set its `http_port` and
`ws_port` entries to distinct integers between `1024` and `65535`. Without that
override, edit the two legacy settings instead. Then reload the plugin.

These are Editor Settings, not Project Settings. They apply to every project
opened by that Godot editor installation.

## 3. Reconfigure every MCP client

V4 clients do not persist a backend URL or bearer token. Every supported
client launches the `godot-ai attach` stdio bridge, which obtains and rotates
private local capabilities at runtime. The generated command still includes
both port numbers, so a port change requires regeneration.

In the dock, click **Configure** for each client (or **Configure all**). This
rewrites the existing entry with the current exact package version, HTTP and
WebSocket ports, excluded domains, and telemetry preference.

If you maintain an attach entry by hand, change the values after `--port` and
`--ws-port`. Its relevant argv should look like:

```text
godot-ai attach --port 8001 --ws-port 9501
```

Do not replace it with `http://127.0.0.1:8001/mcp`. A persistent bare URL
cannot carry the rotating private capability and is rejected by v4.

## Reverting

After the foreign process is gone, restore your previous effective pair using
the manual settings described above, reload the plugin, and run **Configure
all** again. Editing legacy keys alone does not change an existing v4 pair.
