# Server lifecycle, discovery, and plugin reload

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


How the plugin starts, adopts, and tears down the Python server in development.

## Server lifecycle in dev

The plugin manages the server process:
- On startup, plugin checks if port 8000 is already in use. If yes, uses existing server. If no, spawns `.venv/bin/python -m godot_ai --transport streamable-http --port 8000`.
- The plugin prefers the local `.venv` over system-installed `godot-ai` so dev checkouts always use source code.
- **External adoption does not transfer process ownership**: when the plugin adopts an externally started server (CI's `script/ci-start-server`, a hand-started dev server, or an attach-owned backend), `server_lifecycle.gd::adopt_compatible_server` sets `_server_pid = -1` and clears the managed record/pid file. Normal editor teardown therefore has no PID authority to kill and leaves that external server running. Plugin-spawned servers remain managed and follow their normal stop/`keep_server_on_exit` policy. Status fields such as `owner_type` are diagnostic only and never sufficient kill proof. **One deliberate, bounded exception**: during a stale-recovery episode — armed only by an explicit user action (the Update click via the post-update marker, or the dock's Restart click) — a brand-verified godot-ai occupant whose *version differs* from the plugin's may be killed on the weak `status_name` proof tier, for a bounded number of rounds (`_stale_recovery_budget`, see [docs/releasing.md](releasing.md)). This intentionally covers a hand-started *previous-version* server too: a stale-version backend on the configured port is incompatible with the plugin either way, and the user's click chose replacement. Same-version and foreign occupants remain protected in all cases.
- **Bridge leases bound crash survival for plugin-spawned servers**: the Python owner-PID watchdog and idle backstop both defer shutdown while an attach bridge holds a live lease. A plugin-spawned backend can therefore outlive a crashed editor until its last client lease expires, extending the same tokenless-loopback trust window as `keep_server_on_exit`, but only for the lease TTL. That bound depends on the lease registry refusing to grow without limit: the `/godot-ai/lease/*` routes are loopback-guarded but **not authenticated**, and the `instance_id` they require is published by the unauthenticated `/godot-ai/status` probe, so any local process can register. `LeaseRegistry` therefore caps concurrent leases (`DEFAULT_MAX_ACTIVE_LEASES`, 429 `LEASE_LIMIT_EXCEEDED` past it) and prunes through an expiry heap rather than a full scan — the old full-dict scan ran on every register/heartbeat/release/`active_count`, so N registrations cost O(N²) CPU *on the event loop serving all MCP traffic*. Keep both properties: a bridge holds exactly one lease, so neither constrains real use. This does not yet cover a normal editor exit: the GDScript `_exit_tree` path still stops a plugin-managed backend without consulting leases, so that clean-exit case churns the backend and is tracked separately from #822.
- **Attach response-stream limitation**: the bridge deliberately has no post-dispatch read deadline. A same-instance network stream loss, or a server-side request task that dies without producing a response, can therefore wait until the MCP client cancels the call. FastMCP 3.0 exposes `event_store`, but the real cut-and-resume flow hangs at that supported floor (while working on 3.4), so resumability remains a compatibility follow-up rather than a version-dependent feature. Cancellation is cleanup-safe and never replays an ambiguously dispatched mutation.
- **Attach runtime files**: `godot-ai attach` keeps its per-port advisory lock and backend log in a private per-user runtime directory. Override it with `GODOT_AI_RUNTIME_DIR`; otherwise Windows uses `%LOCALAPPDATA%\godot-ai\runtime`, POSIX uses `$XDG_RUNTIME_DIR/godot-ai` when available, and the final fallback is a user-specific temporary directory. On POSIX the selected directory is rejected if it is a symlink, is not owned by the current user, or cannot be enforced as mode 0700; the predictable `/tmp` fallback is therefore not vulnerable to another user's pre-created directory or log-target symlink. A backend crash-loop diagnostic points to `backend-<HTTP-port>.log` there; each spawn retains one previous generation as `.old`. Future client-config rollout must pass the same `--exclude-domains` selection used by the plugin; differing exclusions intentionally fail compatibility with `NEW_CLIENT_SESSION_REQUIRED` rather than replacing the running backend.
- **HTTP access-log lines are opt-in**: uvicorn's per-request `INFO: 127.0.0.1:... "POST /mcp HTTP/1.1" 200 OK` lines are disabled by default on both the plugin-spawned path and `--reload` — every tool call, `/godot-ai/status` probe, and lease heartbeat would otherwise print one, drowning the server's real log lines. Set `GODOT_AI_HTTP_ACCESS_LOG=1` before starting the server to re-enable them when debugging HTTP traffic. Application logs (WebSocket startup, reaper arming, session events) are unaffected and stay at INFO.
- In `--headless` / headless-display launches, the plugin returns early and does not start/adopt the server, open a WebSocket, add the dock, attach loggers, register the debugger plugin, instantiate handlers, or write the game-helper autoload. Set `GODOT_AI_ALLOW_HEADLESS=1` only for intentional headless MCP sessions such as CI handler tests.

For Python auto-reload during dev (no need to touch Godot):
```bash
python -m godot_ai --transport streamable-http --port 8000 --reload
```
This uses `src/godot_ai/asgi.py` to run uvicorn with its factory reload path. Uvicorn watches `src/` for changes and restarts the server process automatically. The plugin auto-reconnects.

## Server discovery (3-tier)

1. `.venv/bin/python -m godot_ai` — dev checkout (venv near project)
2. `uvx --from godot-ai==VERSION godot-ai` — user install (PyPI via uvx, exact version pin)
3. `godot-ai` CLI — system install fallback

## Plugin reload

The `editor_reload_plugin` MCP tool triggers a live plugin reload inside Godot (`EditorInterface.set_plugin_enabled` off/on). It works with both an externally-run server and the plugin-managed server (the handler special-cases the plugin-managed path, where the reload tears down and respawns the server process). The Python handler waits for the new session via `SessionRegistry.wait_for_session()`.

The Godot dock also has a **Start/Stop Dev Server** button for convenience (visible in developer mode).
