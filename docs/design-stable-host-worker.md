# Design: Dev-Mode Stable Host + Restartable Worker

*Revised 2026-04-12*

## Purpose

This document defines the clean version of "Approach 5" for this repository.

The important constraint is that dev reload is a **development facilitator**, not the product's core runtime architecture. We want a robust no-`/mcp` dev loop without paying permanent production costs in latency, indirection, or operational complexity.

The result is:

- **normal mode**: single-process, direct execution, no worker, no RPC
- **dev reload mode**: stable host + restartable worker, activated only for development

## Design Goals

- Preserve Claude's MCP session during normal Python dev reloads
- Preserve Godot connectivity during normal Python dev reloads
- Keep production/default mode fast and simple
- Avoid `importlib.reload()` fragility
- Reuse the same handler logic in both modes
- Keep the runtime-critical layer small and explicit

## Non-Goals For V1

- Making host/worker the production runtime
- Dynamic tool registration from the worker
- Eliminating all restart windows for in-flight requests
- Reloading host/runtime-critical code without a full restart
- Building a general distributed RPC system

## Two Operating Modes

### Mode A: Normal / production

This should remain the default runtime shape.

```text
Claude / MCP Client
   |
   | MCP over HTTP
   v
Single Python Process
   |- FastMCP transport
   |- SessionRegistry
   |- WebSocket server to Godot
   |- MCP schema wrappers
   |- Shared handlers
   |- Direct runtime adapter
   v
Godot plugin
```

Characteristics:

- no worker process
- no internal RPC
- no extra serialization hops
- same basic runtime model as the current codebase

### Mode B: Dev reload

This mode exists only to support automatic Python reload without losing Claude's MCP session.

```text
Claude / MCP Client
   |
   | MCP over HTTP
   v
Stable Host Process
   |- FastMCP transport + session state
   |- SessionRegistry
   |- WebSocket server to Godot
   |- MCP schema wrappers
   |- Worker supervisor + watcher
   |- Host callback surface
   |
   | bidirectional stdio JSON-RPC
   v
Restartable Worker Process
   |- Shared handlers
   |- RPC runtime adapter
   v
Godot plugin (through host callbacks)
```

Characteristics:

- only the worker restarts on normal Python edits
- Claude stays connected because the host owns MCP transport/session state
- Godot stays connected because the host owns the WebSocket server and session registry
- only dev mode pays the internal RPC cost

## Key Principle: Share Logic, Not Runtime Wiring

We should not have separate implementations for production and dev. The runtime wiring changes, but the handler logic should be shared.

The design should separate the code into three layers:

1. **Schema layer**
   FastMCP tool/resource registrations and wrappers
2. **Handler layer**
   shared implementation functions for tools/resources
3. **Runtime adapter layer**
   how handlers talk to Godot/session state

### Runtime adapters

- **DirectRuntime** in normal mode
  handlers call Godot/session operations directly in-process
- **RpcRuntime** in dev worker mode
  handlers make host callback requests over stdio RPC

That is the key design decision that keeps the worker boundary from infecting the whole codebase.

## What Stays Stable In Both Modes

These responsibilities should remain in the host process whenever dev mode is active, and remain in the single process in normal mode:

- FastMCP transport and client-facing HTTP behavior
- streamable-http session/event state
- WebSocket server and command correlation with Godot
- `SessionRegistry` and active-session selection
- `reload_plugin` flow

These are the runtime-critical parts that should not be reloaded on every code edit.

## Ownership Boundary In Dev Mode

### Host owns

- FastMCP server and client-facing transport
- streamable-http session/event state
- WebSocket server to Godot
- `SessionRegistry`
- stable MCP schema wrappers
- worker supervision and file watching
- host-native tools/resources
- worker stderr capture and surfacing

### Worker owns

- shared handler execution
- orchestration logic
- pagination, shaping, and validation
- most fast-changing domain behavior

### Host-native tools/resources in V1

These should remain host-native in both modes because they directly manipulate runtime-owned state:

- `session_list`
- `session_activate`
- `reload_plugin`
- `godot://sessions`

Everything else should use shared handlers and be eligible for worker execution in dev mode.

## Mapping To The Current Repo

### Runtime-critical modules

These remain direct/runtime-owned:

- `src/godot_ai/transport/websocket.py`
- `src/godot_ai/sessions/registry.py`
- `src/godot_ai/godot_client/client.py`
- FastMCP bootstrap code currently in `src/godot_ai/server.py`

### Shared handler candidates

These should become shared logic rather than "worker-only" logic:

- `src/godot_ai/tools/editor.py` except `reload_plugin`
- `src/godot_ai/tools/scene.py`
- `src/godot_ai/tools/node.py`
- `src/godot_ai/tools/project.py`
- `src/godot_ai/tools/testing.py`
- `src/godot_ai/tools/client.py`
- `src/godot_ai/resources/editor.py`
- `src/godot_ai/resources/scenes.py`
- `src/godot_ai/resources/project.py`

## Recommended Package Layout

```text
src/godot_ai/
├── __init__.py
├── cli.py
├── app.py                    # mode selection: normal vs dev reload
├── schema/
│   ├── tools.py              # FastMCP tool registration
│   └── resources.py          # FastMCP resource registration
├── handlers/
│   ├── editor.py
│   ├── scene.py
│   ├── node.py
│   ├── project.py
│   ├── testing.py
│   ├── client.py
│   └── resources.py          # or split per-domain if clearer
├── runtime/
│   ├── interface.py          # protocol / abstract surface for handlers
│   ├── direct.py             # production/default adapter
│   └── rpc.py                # worker-side adapter backed by host callbacks
├── dev/
│   ├── host.py               # dev host bootstrap
│   ├── supervisor.py         # spawn/restart worker
│   ├── watcher.py            # file watching + debounce
│   ├── worker_main.py        # worker entrypoint
│   └── rpc/
│       ├── messages.py
│       ├── stdio_client.py   # host -> worker
│       ├── stdio_server.py   # worker request loop
│       └── dispatch.py       # host callback handlers
├── sessions/
├── transport/
├── godot_client/
└── protocol/
```

This does not need to be a flag day refactor. The important thing is the shape:

- schema separate from handlers
- handlers separate from runtime adapters
- dev-only host/worker plumbing isolated under `dev/`

## Stable Schema First

V1 should keep the MCP schema fixed in both modes.

That means:

- the schema layer defines tool/resource names and signatures
- wrappers call host-native code or shared handlers
- in dev mode, wrappers forward to the worker for shared-handler-backed operations
- the worker does not dynamically mutate the host's MCP registry

This is the right tradeoff because implementation reload is the problem we are solving first, not schema churn.

## RPC Design

Use **bidirectional JSON-RPC over stdio** between dev host and dev worker.

### Why stdio

- no extra localhost ports
- subprocess lifetime and transport lifetime match
- cross-platform
- private by default
- straightforward to supervise

### Why bidirectional

The host needs to ask the worker to execute handlers, and the worker needs to call back into the host for runtime-owned actions such as:

- send a Godot command
- read active session info
- emit logs

### Transport rules

- JSON-RPC 2.0 subset
- newline-delimited JSON messages on stdin/stdout
- worker stderr is reserved for logs and crash diagnostics
- host captures worker stderr and forwards it into structured logs and, where useful, the Godot dock/log surfaces

### Host -> worker methods

- `worker.initialize`
- `tool.call`
- `resource.read`
- `worker.health`
- `worker.shutdown`

### Worker -> host methods

- `host.session.list`
- `host.session.get_active`
- `host.session.get`
- `host.godot.send`
- `host.log`

V1 should keep this set short.

## Session Handling Rule

The worker should not own session resolution policy.

The host should remain the authority for:

- current active session
- session existence
- connection status

In practice that means worker code should usually call `host.godot.send(...)` without needing to understand `SessionRegistry` internals. Session-aware policy stays at the host/runtime layer.

## Call Flows

### Normal mode: `editor_state`

1. Claude calls `editor_state`
2. schema wrapper calls shared editor handler directly
3. handler uses `DirectRuntime`
4. `DirectRuntime` sends `get_editor_state` to Godot in-process
5. result returns to Claude

### Dev mode: `editor_state`

1. Claude calls `editor_state`
2. host wrapper forwards `tool.call(name="editor_state", args=...)` to the worker
3. worker runs the same shared editor handler
4. handler uses `RpcRuntime`
5. `RpcRuntime` calls `host.godot.send(command="get_editor_state")`
6. host sends the command to Godot and returns the result
7. worker returns the tool result
8. host returns the MCP response to Claude

This extra path exists only in dev mode.

### `reload_plugin`

This remains host-native in both modes:

1. resolve active session
2. send `reload_plugin` over WebSocket
3. wait on `SessionRegistry.wait_for_session(exclude_id=old_id)`
4. return the new session metadata

That flow is tightly coupled to runtime/session ownership and should not be routed through the worker in V1.

## Reload Model

### Normal mode

- no worker
- no auto-reload machinery
- direct execution only

### Dev mode

Editing shared-handler or worker-owned Python files should:

1. trigger the host watcher
2. debounce rapid changes
3. mark the worker as restarting
4. terminate the worker
5. spawn a fresh worker
6. reconnect RPC
7. clear the restarting state

The host does not restart, so Claude stays connected.

### Host restart scope

Editing runtime-critical files still requires a real restart, for example:

- `dev/host.py`
- `transport/websocket.py`
- `sessions/registry.py`
- RPC message protocol
- FastMCP transport bootstrap

That is acceptable because these files should change less frequently than handler logic.

## Failure Model

### Worker crashes

- host stays alive
- Claude stays connected
- host restarts the worker
- worker stderr is preserved in logs
- requests during the restart window fail with a clear retryable error in V1

### In-flight request during restart

V1 recommendation:

- fail fast with a retryable "worker restarting" error

Do not queue and replay by default. Read-only replay can be added later if measurement shows it is worth it, but writes should not be retried implicitly without deliberate policy.

### Godot disconnect during worker-backed request

The host converts runtime/transport failures into structured callback errors. Shared handlers then either:

- propagate those errors directly
- or map them into the MCP-friendly response shapes already used by current tools/resources

## Latency Expectations

The worker boundary adds extra serialization hops in dev mode. That should be measured, not guessed.

Important points:

- production/default mode pays **zero** RPC tax
- dev mode likely remains dominated by Godot round-trip and editor work, not local stdio JSON overhead
- we should still measure simple and heavy calls once the first vertical slice is running

Recommended first measurements:

- `editor_state`
- `scene_get_hierarchy`
- `run_tests`

## Implementation Plan

### Phase 0: Extract shared handlers without changing runtime mode

Before adding a worker, separate:

- schema wrappers
- handler functions
- runtime adapter interface

Do this inside the current single-process runtime first.

Success criteria:

- normal mode behavior is unchanged
- tool/resource logic no longer depends directly on FastMCP internals
- handlers run through `DirectRuntime`

### Phase 1: Add dev host/worker skeleton

Deliverables:

- `dev/host.py`
- `dev/supervisor.py`
- bidirectional stdio RPC
- worker entrypoint
- worker stderr capture
- one dummy host -> worker -> host callback roundtrip

Success criteria:

- normal mode still works unchanged
- dev mode can start host + worker
- one dummy request succeeds through the RPC boundary

### Phase 2: Migrate one real vertical slice in dev mode

Recommended first slice:

- `editor_state`

Why:

- simple
- read-only
- representative
- easy to compare between direct and dev-RPC paths

Success criteria:

- `editor_state` works in normal mode via direct execution
- `editor_state` works in dev mode via host/worker
- restarting the worker does not require `/mcp`
- Godot stays connected

### Phase 3: Add file watching in dev mode

Once the slice is proven, add automatic worker restart on file change.

Initial watch scope:

- `handlers/**`
- `runtime/rpc.py`
- `dev/**`
- any not-yet-migrated modules temporarily backing worker execution

Do not watch runtime-critical direct-mode modules in V1.

### Phase 4: Migrate the rest of the shared handler surface

Suggested order:

1. editor read tools/resources
2. scene tools/resources
3. node tools
4. project tools/resources
5. testing tools
6. client tools if they still belong in Python

Keep these host-native:

- `session_list`
- `session_activate`
- `reload_plugin`
- `godot://sessions`

### Phase 5: Hardening

- restart backoff for crash loops
- health checks
- clearer restart-window errors
- timing metrics for direct vs dev mode
- integration tests for worker restart with active MCP session
- optional Godot dock visibility for worker state

## Testing Strategy

### Unit

- runtime adapter interface behavior
- direct vs RPC adapter parity
- supervisor state transitions
- RPC message serialization
- handler logic with mocked runtime

### Integration

- normal mode unchanged
- dev host + worker roundtrip
- dev host + worker + mock Godot session
- worker restart while MCP client remains connected
- `reload_plugin` still works in dev mode

### Manual

1. connect Claude once
2. run in dev mode
3. edit a shared handler
4. confirm behavior changes apply without `/mcp`
5. edit GDScript
6. confirm plugin reload still works

## Key Decisions

### Decision: dev-only split

Chosen because reload is a dev concern. Production should not pay permanent complexity or latency for it.

### Decision: shared handlers

Chosen so that production and dev paths share implementation logic rather than diverging into two systems.

### Decision: stable schema first

Chosen because schema churn is not the main problem.

### Decision: stdio RPC

Chosen because the worker is a supervised child and stdio is the simplest private transport.

### Decision: keep session/runtime ownership in the host

Chosen because session survival is the entire reason for the split.

## Bottom Line

The clean version of dev reload for this project is:

- **single-process direct runtime in normal mode**
- **stable host + restartable worker only in dev reload mode**
- **shared handlers across both modes**

That keeps production simple, keeps dev robust, and avoids turning a developer convenience feature into permanent runtime cruft.
