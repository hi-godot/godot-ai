# Godot AI Telemetry

Godot AI includes anonymous, privacy-focused telemetry that helps us
understand which tools are used, surface performance regressions, and
prioritize bug fixes. This document covers what is collected, where it
goes, and how to opt out. All telemetry code is open source and lives in
`src/godot_ai/telemetry.py` and `plugin/addons/godot_ai/telemetry.gd`.

## Privacy first

- **Anonymous**: a randomly generated UUID per installation. No account,
  no email, no machine fingerprint beyond OS / Python version.
- **Hashed session ids**: Godot AI session ids include a project-directory
  slug (e.g. `secret-game-prototype@a3f2`). Before any event leaves the
  process, the slug is replaced with the first 8 hex chars of its sha256
  — `3f1a8b22@a3f2`. The slug-derived hash is stable per project but
  doesn't leak the directory name.
- **Non-blocking**: events go through a bounded in-process queue and a
  single daemon worker. Telemetry failures never propagate to tool
  callers.
- **Easy opt-out**: Respects opt-out via environment variable or through
  in-editor settings menu. See "Opting out" below.

## What we collect

### Tool & resource execution
Every MCP tool and resource call emits one record with:
- tool / resource name (e.g. `node_create`, `scene_manage`)
- `sub_action` — for rollup tools, the `op` (e.g. `save_as` for `scene_manage`)
- `success` bool
- `duration_ms`
- truncated error message (max 200 chars) on failure
- the hashed `session_id` if the tool targets a specific editor

### Startup
A single `startup` record on server lifespan enter:
- `server_version`
- `ws_port`
- `lifespan_start_ms` (time from lifespan begin to telemetry emit)
- `FIRST_STARTUP` milestone (one-shot, persisted to `milestones.json`)

### Connection events
- `godot_connection` on plugin connect / disconnect: `godot_version`,
  `plugin_version`, `protocol_version`, `server_launch_mode`,
  `session_count`.
- `MULTIPLE_SESSIONS` milestone when a second concurrent editor connects.

### Plugin events (from the GDScript side)
Relayed through the existing WebSocket as a `plugin_event` envelope.
Allowlist (mirrored in `plugin/addons/godot_ai/telemetry.gd` and
`src/godot_ai/transport/websocket.py::_PLUGIN_EVENT_NAMES`):
- `dock_startup` — dock loaded
- `plugin_reload` — `set_plugin_enabled(false→true)` outcome
- `self_update` — `success`, `failed_clean`, or `failed_mixed`
- `dev_server_toggle` — Start/Stop Dev Server button activity

### What we never collect
- Source code, scene contents, file paths
- Project names (the slug is hashed before sending)
- Editor logs, console output
- Identifying user information (no email, IP, account)

## Opting out

Telemetry is **on by default** — a fresh install posts anonymous usage
events to the maintainers' endpoint. There are two ways to opt out:

### Via the editor UI

Open the "Clients & Settings" popup from the Godot AI dock, go to the
"Settings" tab, and uncheck the "Telemetry" checkbox. Click "Apply &
Restart Server" to apply the change. The preference is persisted in
EditorSettings and survives across editor restarts.

### Via environment variable

Set either environment variable to `true` / `1` / `yes` / `on`:

```bash
# Godot-AI-specific
export GODOT_AI_DISABLE_TELEMETRY=true

# Cross-tool convention also honored
export DISABLE_TELEMETRY=true
```

If either of the above environment variables is enabled, the opt-out is
saved to Godot's editor settings and will persist between runs. Similarly,
if an environment variable is explicitly set and disabled, that will be
persisted to the editor settings.

If telemetry is disabled, any local telemetry files are removed upon server
startup.

### Effect

On opt-out, the collector enters disabled mode. No records are enqueued,
no UUID is generated, no worker thread is spawned, and no data directory
is created. Existing local telemetry files (`customer_uuid.txt`,
`milestones.json`) are deleted on the next server startup. The plugin-side
helper honors the same variables and stops buffering events.

## Endpoint configuration

Telemetry POSTs to a baked-in default endpoint operated by the
godot-ai maintainers. The endpoint URL lives in
``TelemetryConfig.DEFAULT_ENDPOINT`` (`src/godot_ai/telemetry.py`); see
the source for the current value.

Self-hosters and CI flows can override the destination:

```bash
# Send to your own collector / database front-end instead:
export GODOT_AI_TELEMETRY_ENDPOINT=https://telemetry.example.com/events

# Optional: customize request timeout (default 1.5 seconds):
export GODOT_AI_TELEMETRY_TIMEOUT=2.5

# Local-sink smoke testing (loopback endpoints are otherwise rejected):
export GODOT_AI_TELEMETRY_ALLOW_LOOPBACK=1
export GODOT_AI_TELEMETRY_ENDPOINT=http://127.0.0.1:7777/
```

Only `http://` and `https://` schemes are accepted; localhost is rejected
unless `GODOT_AI_TELEMETRY_ALLOW_LOOPBACK=1` is also set. An invalid
override does **not** silently fall back to the baked-in default — it
disables sending and emits a warning, so a misconfigured self-host
can't accidentally ship events to the maintainers' endpoint.

## Where data is stored locally

Per-OS data directory:

- **macOS**: `~/Library/Application Support/godot-ai/`
- **Linux**: `$XDG_DATA_HOME/godot-ai/` (default `~/.local/share/godot-ai/`)
- **Windows**: `%APPDATA%\godot-ai\`

Two files:

- `customer_uuid.txt` — anonymous installation id
- `milestones.json` — one-shot event ledger (so each FIRST_X fires once)

Delete the data directory to reset both.

## Example record

```json
{
  "record": "tool_execution",
  "timestamp": 1736294400.123,
  "customer_uuid": "550e8400-e29b-41d4-a716-446655440000",
  "session_id": "3f1a8b22@a3f2",
  "version": "0.0.41",
  "platform": "Darwin",
  "source": "darwin",
  "data": {
    "tool_name": "scene_manage",
    "sub_action": "save_as",
    "success": true,
    "duration_ms": 12.7,
    "platform_detail": "Darwin 24.0.0 (arm64)",
    "python_version": "3.11.10"
  }
}
```

## How it's wired

- `src/godot_ai/telemetry.py` — collector, decorators, FastMCP wrap helper.
- `src/godot_ai/server.py` — calls `install_fastmcp_wraps(mcp)` once,
  before any tool registration; emits `STARTUP` on lifespan enter.
- `src/godot_ai/sessions/registry.py` — emits `GODOT_CONNECTION` on
  `register` / `unregister`.
- `src/godot_ai/transport/websocket.py` — routes `plugin_event` envelopes
  through the allowlist.
- `plugin/addons/godot_ai/telemetry.gd` — plugin-side helper.

Adding telemetry to a new tool or resource needs **no work**: the
FastMCP wrap installed in `server.py` instruments every subsequent
`@mcp.tool` / `@mcp.resource` automatically.

## Adding a new plugin event

1. Add the name to the allowlist in
   `plugin/addons/godot_ai/telemetry.gd` (`_ALLOWED_EVENTS`).
2. Mirror it in `src/godot_ai/transport/websocket.py`
   (`_PLUGIN_EVENT_NAMES`).
3. Document the field shape here.
4. Add a test in `test_project/tests/test_plugin_telemetry.gd`.
