# Godot AI — Plugin Architecture

*Updated 2026-04-29 (refresh file-structure tree, server-side modules, session metadata, and handshake JSON to match shipped code; add `<domain>_manage` rollups + resources + middleware to server responsibilities)*

This document is the architecture reference for the Godot-side plugin and the server-to-plugin interaction model.

Use the related docs for adjacent concerns:

- [implementation-plan.md](implementation-plan.md) for the active roadmap
- [tool-taxonomy.md](tool-taxonomy.md) for the detailed tool surface
- [testing-strategy.md](testing-strategy.md) for verification and CI
- [packaging-distribution.md](packaging-distribution.md) for release/install mechanics

---

## Architecture Overview

The core shape is:

```text
AI Client → MCP (streamable-http, SSE, stdio) → Python FastMCP server
                                                 ↓
                                          WebSocket :9500
                                                 ↓
                                       Godot EditorPlugin
```

The plugin is persistent. It does not spin up per command. That is the foundation for:

- live editor inspection
- safe scene mutation
- session tracking (multi-editor, with per-call routing)
- runtime feedback loops (game-side capture, performance monitors, logs)

---

## Server Responsibilities

The Python server owns orchestration, not editor mutation.

That includes:

- MCP transport (FastMCP v3 over streamable-http, SSE, or stdio) and tool/resource registration
- the rolled-up tool surface — ~15 named verbs plus per-domain `<domain>_manage` tools wired by `tools/_meta_tool.py::register_manage_tool`, which builds a dynamic `Literal[...]` op enum so schema-aware clients see every op
- read-only `godot://...` MCP resources (sessions, editor state, scenes, nodes, scripts, project, materials, performance, test results) that mirror the cheap reads and don't count against tool-cap budgets
- per-call session routing — every Godot-talking tool accepts an optional `session_id`, bound at the `DirectRuntime` boundary so `require_writable` and downstream handlers see the pinned session, not the active one
- middleware that smooths over client quirks: `StripClientWrapperKwargs` (Cline's `task_progress`), `ParseStringifiedParams` (clients that auto-stringify nested params for `_manage` calls), `HintOpTypoOnManage` (rewrites Pydantic `literal_error` with a `difflib`-derived "Did you mean" hint)
- session registry and active-session resolution, with `<project-slug>@<4hex>` IDs and substring/path matching in `session_activate`
- request validation and structured error mapping (`protocol/errors.py`)
- job tracking for long-running operations and the deferred-response pattern for replies that flow back over a different channel (game capture)
- the `--exclude-domains` CLI flag and dock UI knob, so tool-capped clients (Antigravity, etc.) can drop entire domains at server start while keeping the four core tools alive
- CLI entry points for diagnostics and packaging (`python -m godot_ai`, the dev `--reload` runner via `src/godot_ai/asgi.py`)

The plugin stays thin. Complex orchestration belongs in Python; direct editor work belongs in Godot.

---

## Plugin File Structure

```text
plugin/addons/godot_ai/
├── plugin.cfg
├── plugin.gd                    ## EditorPlugin lifecycle, handler registration
├── connection.gd                ## WebSocket client + send_deferred_response
├── dispatcher.gd                ## command routing, frame budget, DEFERRED_RESPONSE sentinel
├── mcp_dock.gd                  ## editor dock: status, clients, logs, self-update banner, Tools tab
├── client_configurator.gd       ## thin facade for client config (configure/remove/status)
├── tool_catalog.gd              ## mirrors src/godot_ai/tools/domains.py; CI-enforced
├── update_reload_runner.gd      ## self-update extract + plugin re-enable handoff
├── handlers/                    ## one file per domain; ~30 handlers
│   ├── editor_handler.gd        ## screenshot, logs, monitors, reload_plugin, quit_editor
│   ├── scene_handler.gd, node_handler.gd, script_handler.gd
│   ├── project_handler.gd, resource_handler.gd, filesystem_handler.gd
│   ├── animation_handler.gd, material_handler.gd, particle_handler.gd
│   ├── camera_handler.gd, audio_handler.gd, theme_handler.gd, ui_handler.gd
│   ├── signal_handler.gd, autoload_handler.gd, input_handler.gd
│   ├── batch_handler.gd, test_handler.gd, client_handler.gd
│   ├── environment_handler.gd, texture_handler.gd, curve_handler.gd
│   ├── physics_shape_handler.gd, control_draw_recipe_handler.gd
│   ├── *_values.gd / *_presets.gd  ## per-domain enum coercion + preset libraries
│   └── _param_validators.gd, _property_errors.gd  ## shared utilities (Mcp* class_name)
├── clients/                     ## descriptor + strategy system for 18 IDE configs
│   ├── _base.gd, _registry.gd
│   ├── _json_strategy.gd, _toml_strategy.gd, _cli_strategy.gd
│   ├── _atomic_write.gd, _cli_finder.gd, _cli_exec.gd
│   ├── _path_template.gd, _manual_command.gd
│   └── claude_code.gd, claude_desktop.gd, cursor.gd, …  ## one per client
├── debugger/
│   └── mcp_debugger_plugin.gd   ## editor-side debugger-channel bridge
├── runtime/
│   ├── game_helper.gd           ## autoload that runs inside the game subprocess
│   ├── game_logger.gd           ## game-side logger, ferries lines back via debugger
│   ├── editor_logger.gd         ## editor-process logger for logs_read(source="editor")
│   └── draw_recipe.gd           ## reusable runtime for control_draw_recipe
├── testing/
│   ├── test_runner.gd, test_suite.gd, stub_backtrace.gd
└── utils/
    ├── scene_path.gd            ## McpScenePath for clean /Main/Camera3D paths
    ├── error_codes.gd           ## McpErrorCodes
    ├── log_buffer.gd, editor_log_buffer.gd, game_log_buffer.gd, structured_log_ring.gd
    ├── log_backtrace.gd
    ├── resource_io.gd           ## shared resource load/save logic
    ├── mcp_spawn_state.gd       ## tracks managed-server PID + version across reloads
    ├── windows_port_reservation.gd  ## avoids Windows-reserved ephemeral ports
    └── uv_cache_cleanup.gd      ## prunes stale uvx cache before self-update
```

The server-side counterparts live in:

- `src/godot_ai/server.py` — FastMCP entry point, lifespan, tool/resource registration, `--exclude-domains`
- `src/godot_ai/asgi.py` — uvicorn factory for `--reload`; ships `StaleMcpSessionDiagnosticMiddleware`
- `src/godot_ai/transport/websocket.py` — WebSocket server adopting/owning the :9500 socket
- `src/godot_ai/sessions/registry.py` — multi-session tracking, active resolution, substring matching
- `src/godot_ai/godot_client/client.py` — typed async client; raises `GodotCommandError`
- `src/godot_ai/runtime/{interface.py, direct.py}` — `Runtime` protocol + `DirectRuntime` impl that handlers depend on
- `src/godot_ai/handlers/` — shared sync handlers; `_readiness.py` gates writes; `_target.py` resolves nodes
- `src/godot_ai/tools/` — MCP tool wrappers per domain + `_meta_tool.py::register_manage_tool` rollup factory + `domains.py` (CI-paired with `tool_catalog.gd`)
- `src/godot_ai/resources/` — read-only `godot://...` URI handlers
- `src/godot_ai/middleware/` — `StripClientWrapperKwargs`, `ParseStringifiedParams`, `HintOpTypoOnManage`
- `src/godot_ai/protocol/` — envelope types and error codes (kept in sync with `utils/error_codes.gd`)

---

## Concurrency Model

The plugin must never behave like a blocking RPC worker. Godot editor APIs are main-thread sensitive, and `WebSocketPeer` requires polling.

### Receive Path

```text
WebSocket receive
       │
       ▼
command_queue append
       │
       ▼
_process(delta)
       │
       ├─ poll WebSocket
       ├─ drain queue within frame budget
       ├─ dispatch editor work
       └─ send responses
```

### Rules

1. Never call `EditorInterface` methods directly from WebSocket callbacks.
2. Queue inbound commands and dispatch them from `_process()`.
3. Use `call_deferred()` for scene-tree mutations.
4. Yield large read operations across frames where needed.
5. Gate writes on readiness state.
6. Use `EditorUndoRedoManager` for undoable scene mutations.

---

## Plugin Lifecycle

### `_enter_tree()`

- create `McpConnection`
- create `Dispatcher`
- register handlers
- start connection attempt
- create or attach the dock panel

### `_process(delta)`

- poll the WebSocket transport
- drain queued commands within the frame budget
- emit responses
- watch scene/play/readiness changes
- update the dock and log buffer

### `_exit_tree()`

Outer-to-inner teardown order matters (see #46): the dispatcher's Callables hold handler RefCounteds alive past the point where Godot reloads their `class_name` scripts, so the next post-reload call into a typed-array-holding handler SIGSEGVs against a stale class descriptor. The shipped order is:

1. `_connection.teardown()` first, so `_process` stops enqueuing new commands
2. `_dispatcher.clear()` next, breaking the Callable→handler ref chain
3. `_handlers.clear()` runs handler destructors while their `class_name` scripts are still loaded
4. detach the dock, debugger plugin, and editor logger
5. `_stop_server()` and reset the spawn-guard so a re-enabled plugin instance can respawn

A symmetric `prepare_for_update_reload()` path runs during self-update so the new plugin version starts (or adopts) the right server.

---

## Session And Readiness Model

The session model exists so the server can distinguish live editor instances and refuse writes when the editor is in an unsafe state.

### Session Metadata

- session id, formatted `<project-slug>@<4hex>` (e.g. `godot-ai@a3f2`) — slug derives from the project directory name so agents can recognise which editor they're targeting; the hex suffix disambiguates same-project twins
- name (project basename)
- Godot version, plugin version, server version
- project path
- editor PID
- current scene, play state, readiness state
- last_seen heartbeat, used by `session_list` and stale-session diagnostics
- server launch mode (managed vs. external) reported via `session_list`

### Readiness States

- `ready`
- `importing`
- `playing`
- `no_scene`

The exact set can evolve, but the behavior should stay the same:

- reads remain broadly available
- writes are rejected or constrained when the editor is unsafe
- `project.stop` remains explicitly allowed while already playing

---

## Jobs And Long-Running Work

Some operations should not pretend to be instant:

- export/build work
- reimports and filesystem refreshes
- screenshot capture batches
- large hierarchy or filesystem reads

The architecture should treat these as tracked jobs with:

- a stable job identifier
- progress or phase information where possible
- structured result payloads
- explicit partial-failure reporting when the work is composite

`batch.execute` in particular should promise ordered execution and clear per-step results, not fake atomicity.

---

## Game-Process Capture Bridge

The running game is always a separate OS child process — "Embed Game Mode"
on Windows and Linux (and macOS 4.5+) just reparents the game's window into
the editor via `SetParent` / `XReparentWindow` / remote-layer. The editor
never has direct access to the game's framebuffer through its own
`Viewport`, so anything that needs pixels from the running game has to ask
the game for them.

The plugin does this over Godot's editor-debugger channel — the same
channel Godot itself uses for the Remote scene tree, profiler, and
live-edit — via three cooperating pieces:

- `plugin/addons/godot_ai/debugger/mcp_debugger_plugin.gd` — an
  `EditorDebuggerPlugin` that registers on `_enter_tree`. `_has_capture`
  claims the `"mcp"` prefix. `_capture` routes the replies that come back
  from the game: `mcp:hello` (boot beacon), `mcp:screenshot_response`,
  `mcp:screenshot_error`.
- `plugin/addons/godot_ai/runtime/game_helper.gd` — an autoload the plugin
  registers as `_mcp_game_helper` via direct `ProjectSettings.set_setting`
  + `save()` on `_enter_tree` (the `EditorPlugin.add_autoload_singleton`
  convenience method only mutates in-memory settings and doesn't persist
  before Godot spawns the subprocess). The autoload guards on
  `Engine.is_editor_hint()` so it no-ops inside the editor itself — not
  `OS.has_feature("editor")`, which is a compile-time `TOOLS_ENABLED`
  check that returns true in the game subprocess too because it runs the
  same editor binary.
- Capture flow: the editor-side plugin waits for the game to beacon
  `mcp:hello` (proving its `EngineDebugger.register_message_capture("mcp",
  ...)` has run — Godot silently drops messages to unregistered prefixes),
  then sends `mcp:take_screenshot`. The game's capture replies with a PNG
  of `get_tree().root.get_texture().get_image()` as base64. The
  editor-side plugin pushes the reply back over the MCP WebSocket via
  `McpConnection.send_deferred_response` with the original `request_id`.

### Deferred-Response Pattern

The MCP dispatcher runs handlers synchronously and sends one response per
command. Game capture can't fit that shape: the reply arrives arbitrarily
later over a different channel. The dispatcher supports this via a
sentinel:

- Handlers that produce their reply out-of-band return
  `McpDispatcher.DEFERRED_RESPONSE` (a dict containing `{"_deferred":
  true}`). `tick()` skips auto-sending for these.
- The dispatcher threads the incoming `request_id` through `params` under
  the `"_request_id"` key (on a duplicated params dict — the original
  queued command is not mutated). Deferred handlers read it and hand it
  off to whatever async source ultimately produces the reply.
- When the reply arrives (debugger capture, timeout, etc.), the async
  source calls `McpConnection.send_deferred_response(request_id, payload)`,
  which JSON-serialises with `request_id` attached and ships it over the
  WebSocket just like a normal response.

This is the only pattern in the plugin today that decouples response from
handler-return. New tools should only reach for it when the work can't
fit in a frame and the reply genuinely has to flow back later — think
IPC, remote-debugger queries, multi-frame renders.

---

## Undo Contract

Every undoable scene mutation should use `EditorUndoRedoManager`.

The contract is:

- scene-tree mutations are undoable unless there is a strong reason otherwise
- file writes are not editor-undoable and should say so explicitly
- tool responses should make undoability obvious

This is part of product trust, not just implementation detail.

---

## Security Model

The security posture should stay explicit:

- localhost-first by default
- project trust is explicit, not implied
- dangerous or privileged operations are clearly marked
- editor-side arbitrary code execution remains gated and exceptional
- mutation and execution paths are auditable enough to debug what happened

This should be visible in both the protocol and the user-facing docs.

---

## WebSocket Protocol Summary

### Handshake

Plugin to server:

```json
{
  "type": "handshake",
  "session_id": "godot-ai@a3f2",
  "name": "godot-ai",
  "godot_version": "4.6.0",
  "project_path": "/path/to/project",
  "editor_pid": 12345,
  "plugin_version": "2.2.3",
  "protocol_version": 1,
  "readiness": "ready",
  "current_scene": "res://main.tscn"
}
```

### Command

Server to plugin:

```json
{
  "request_id": "uuid",
  "command": "get_scene_tree",
  "params": {"depth": 10}
}
```

### Response

Plugin to server:

```json
{
  "request_id": "uuid",
  "status": "ok",
  "data": {}
}
```

### Error Response

Plugin to server:

```json
{
  "request_id": "uuid",
  "status": "error",
  "error": {
    "code": "NODE_NOT_FOUND",
    "message": "Node at path '/root/Main/Player' not found"
  }
}
```

---

## Architecture Constraints That Still Matter

- Godot-side save operations can trigger re-entrant frame processing
- plugin reload is special and needs explicit reconnect handling
- the active session model must stay coherent as multi-instance support grows
- any new runtime-feedback tools must respect the same queueing and readiness rules as existing write tools
