# Godot AI Telemetry

Godot AI includes anonymous, privacy-focused telemetry that helps us
understand which tools are used, surface performance regressions, and
prioritize bug fixes. This document covers what is collected, where it
goes, and how to opt out. All telemetry code is open source and lives in
`src/godot_ai/telemetry.py` and `plugin/addons/godot_ai/telemetry.gd`.

## Privacy first

- **Anonymous**: a randomly generated UUID per installation. No account,
  no email, no machine fingerprint beyond OS / Python version.
- **Salted, hashed session ids**: Godot AI session ids include a
  project-directory slug (e.g. `secret-game-prototype@7f9c3a10d8e426b1`). Before any
  event leaves the process, the slug is replaced with the first 8 hex
  chars of `sha256(customer_uuid + slug)` — `3f1a8b22@7f9c3a10d8e426b1`. Salting with
  the per-installation UUID means the hash is stable per project on a
  given install, but the same project name produces different hashes on
  different installations — so hashes can't be correlated across users or
  reversed with a dictionary of common project names.
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
- an error *category* on failure — the structured error-code value for `GodotCommandError` (plus an allowlisted `sub_code` for `EDITOR_NOT_READY`), otherwise just the exception class name. Exception message text never leaves the process (it can embed project paths).
- the hashed `session_id` if the tool targets a specific editor

### Startup
A single `startup` record on server lifespan enter:
- `server_version`
- `ws_port`
- `lifespan_start_ms` (time from lifespan begin to telemetry emit)
- `diagnostic_hints_suppressed` — whether the client's default diagnostic
  hint policy is `discard` (the `GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS`
  escape hatch). Read from the constructed client, not the env var, so
  the flag reflects actual behavior. A single boolean derived from a
  config flag — no new identifying data.
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
- `dev_server_toggle` — managed server start/restart/stop button activity (the
  legacy event name is retained for telemetry-schema continuity)

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

The preference reaches both server-spawn paths: plugin-spawned servers get
`GODOT_AI_DISABLE_TELEMETRY` injected into their environment at spawn time,
and client-owned `godot-ai attach` entries carry `--disable-telemetry` on
their argv (the bridge sets the same env var for itself and any backend it
spawns). Attach entries written before the toggle changed read as
`configured_mismatch` — re-run Configure so the client relaunches the bridge
with the current preference.

### Reaching a server the plugin did not spawn

Spawn-time environment injection only covers servers the plugin started. A
server it *adopted* — a hand-started dev server, a CI backend, an attach-owned
process — never saw the env var, and the editor cannot write another process's
environment. Applying the checkbox therefore also sends a `telemetry_opt_out`
event over the WebSocket the plugin is already authenticated on (issue #913).
The receiving server stops sending immediately.

One timing caveat: the opt-out frame can only be sent after the WebSocket handshake, but the server records its `connected` telemetry event as part of publishing that connection. On an opted-out editor's *first* connect to a fresh adopted server, that single `connected` record (versions, hashed session id, session count) can therefore be enqueued before the opt-out is latched; every later record on that process is suppressed. Carrying the opt-out inside the authenticated handshake would close this window and is a planned follow-up.

Four properties of that channel, since it is a privacy contract:

- **Authenticated and instance-bound.** It rides the mutually authenticated
  per-backend WebSocket, after a completed handshake, and only from a session
  the server has registered. The loopback `/godot-ai/status` and lease routes
  stay strictly read-only — no opt-out is accepted there.
- **Opt-out only.** The event is field-free. There is no "enable" message on
  the wire and no un-latch on the server, so on a backend shared by several
  editors the most restrictive preference wins: one editor can never turn
  telemetry back on for another.
- **Latching, not persistent.** The opt-out holds for the rest of that
  process's life and is written nowhere. Re-checking the box takes effect when
  the server is replaced; a replacement reads the env var / EditorSetting at
  spawn as it always has.
- **Re-asserted on every connect,** so a reconnect after a plugin reload — or a
  fresh editor attaching to an already-running server — re-delivers it.

`/godot-ai/status` publishes `telemetry_enabled` from a live read of the env
vars *and* the runtime latch, so the dock reports what the running server will
actually send. A server too old to publish the field omits it, and the dock
shows nothing rather than guessing.

Record/send paths in an already-running Python process also re-read
`GODOT_AI_DISABLE_TELEMETRY` / `DISABLE_TELEMETRY` on each event, so a later
in-process env change takes effect without reconstructing the collector.

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

A *runtime* opt-out — a later in-process env change, or the latched
`telemetry_opt_out` event — arrives after those startup decisions were already
made, so it is narrower: records and sends stop immediately, but an already-
spawned worker thread stays idle rather than exiting and local files already on
disk are left alone. They are cleaned up the next time that server starts with
telemetry disabled.

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
unless `GODOT_AI_TELEMETRY_ALLOW_LOOPBACK=1` is also set. Plain `http://`
to a non-loopback host is rejected (it would ship telemetry in cleartext)
unless `GODOT_AI_TELEMETRY_ALLOW_INSECURE_HTTP=1` is set. An invalid
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
  "session_id": "3f1a8b22@7f9c3a10d8e426b1",
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
