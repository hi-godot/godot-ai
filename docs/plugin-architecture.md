# Godot AI — Plugin Architecture

*Updated 2026-04-13*

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
AI Client → MCP (stdio / HTTP / SSE) → Python FastMCP server → WebSocket → Godot EditorPlugin

Optional side path:

Python FastMCP server → headless Godot process for exports, CI, and recovery workflows
```

The plugin is persistent. It does not spin up per command. That is the foundation for:

- live editor inspection
- safe scene mutation
- session tracking
- runtime feedback loops
- eventually multi-instance routing

---

## Server Responsibilities

The Python server should own orchestration, not editor mutation.

That includes:

- MCP transport and tool/resource registration
- session registry and active-session resolution
- request validation and structured error mapping
- job tracking for long-running operations
- typed client communication with the plugin
- CLI entry points for diagnostics, packaging, and headless flows

The plugin should stay thin. Complex orchestration belongs in Python; direct editor work belongs in Godot.

---

## Plugin File Structure

```text
plugin/addons/godot_ai/
├── plugin.cfg
├── plugin.gd
├── connection.gd
├── dispatcher.gd
├── mcp_dock.gd
├── handlers/
│   ├── editor_handler.gd
│   ├── scene_handler.gd
│   ├── node_handler.gd
│   ├── script_handler.gd
│   ├── resource_handler.gd
│   ├── project_handler.gd
│   └── batch_handler.gd
├── debugger/
│   └── mcp_debugger_plugin.gd   ## editor-side debugger-channel bridge
├── runtime/
│   └── game_helper.gd           ## autoload that runs inside the game
├── state/
│   ├── session_state.gd
│   └── log_buffer.gd
└── utils/
    ├── serializer.gd
    └── node_finder.gd
```

The server-side counterparts live in:

- `src/godot_ai/server.py`
- `src/godot_ai/transport/websocket.py`
- `src/godot_ai/sessions/registry.py`
- `src/godot_ai/godot_client/client.py`
- `src/godot_ai/handlers/`
- `src/godot_ai/tools/`

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

- disconnect cleanly
- release plugin-owned resources
- avoid leaving stale sessions or dangling reconnect attempts

---

## Session And Readiness Model

The session model exists so the server can distinguish live editor instances and refuse writes when the editor is in an unsafe state.

### Session Metadata

- session id
- Godot version
- project path
- plugin version
- current scene
- play state
- readiness state

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
  "session_id": "uuid",
  "godot_version": "4.4.1",
  "project_path": "/path/to/project",
  "plugin_version": "0.0.1",
  "protocol_version": 1
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
