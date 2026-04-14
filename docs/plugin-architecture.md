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

- create `Connection`
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
