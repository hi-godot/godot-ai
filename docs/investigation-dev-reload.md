# Investigation: Automated Dev Reload

## Goal

In dev mode, Claude should be able to edit Python server code and/or GDScript plugin code and have changes take effect automatically, with no human clicking buttons, no `/mcp`, and no CLI commands. The target loop:

1. Claude edits `src/godot_ai/**/*.py` -> server-side behavior updates
2. Claude edits `plugin/addons/godot_ai/**/*.gd` -> plugin reloads in Godot
3. Claude edits both -> both reload
4. Claude's MCP connection survives throughout

## Current State

- **GDScript reload**: `reload_plugin` works. The plugin acks, reloads via `call_deferred()`, reconnects over WebSocket, and the tool waits for the new session.
- **Python reload**: Broken. `--reload` is passed into FastMCP's uvicorn config, but FastMCP runs `uvicorn.Server(config).serve()`, so uvicorn's reload supervisor is never created.
- **MCP session**: streamable-http session state is in-process. If the Python server process restarts, Claude loses the MCP session and must `/mcp` to reconnect.
- **Architecture coupling**: the FastMCP app, HTTP transport, tool/resource registry, WebSocket server, and `SessionRegistry` all currently live in one process lifespan.
- **Dependency note**: `watchfiles` is not currently a project dependency, so any watcher-based approach must add it first.

## Root Cause (Python Reload)

Two layers:

1. FastMCP calls `uvicorn.Server(config).serve()` rather than `uvicorn.run()`, so uvicorn's `ChangeReload` supervisor is never instantiated.
2. Even if it were, uvicorn reload requires the ASGI app as an import string such as `"godot_ai.asgi:app"`. FastMCP passes a live Starlette app object, so `config.should_reload` is false.

## The Real Problem: Session Survival, Not Just Reload

For this project, "reload works" is not enough. There are three separate constraints:

1. Python code changes are detected and applied
2. The Godot plugin stays connected, or reconnects cleanly
3. Claude's MCP session and tool inventory stay valid

Approaches that restart the Python process solve only the first constraint. They may reconnect Godot, but they still kill Claude's MCP session. That is why the current `--reload` failure matters less than the process boundary itself.

There is also a second-order issue: even if the MCP session survives, schema changes are different from implementation changes. If tool names, parameters, or resources change, the server must emit MCP `list_changed` notifications and the client must honor them. In practice, most iteration is implementation changes, not tool-schema changes, so a good design should optimize for that common case.

---

## Approach 1: Bypass FastMCP for reload and use `uvicorn.run()`

Create `src/godot_ai/asgi.py` with a module-level `app`. When `--reload` is passed, run:

```python
uvicorn.run("godot_ai.asgi:app", reload=True, ...)
```

instead of `server.run()`.

**How it works**: uvicorn's `ChangeReload` supervisor owns the HTTP socket and restarts the worker subprocess on file change.

**Changes**: Low. Roughly 25-40 lines across `asgi.py` and `__init__.py`.

**Dev UX**: Edit Python file -> auto-restart in about 0.5-1s. Godot reconnects over WebSocket. Claude loses the MCP session and must `/mcp`.

| Pro | Con |
|-----|-----|
| Battle-tested reload mechanism | Claude session dies on every restart |
| HTTP port stays bound across restart | WebSocket port may briefly flap |
| Small code change | Needs import-string app wiring |
| Good near-term fix for broken `--reload` | Does not meet the automation goal |

**Robustness**: High for process reload. Low for the actual product goal.

---

## Approach 2: Process-level supervisor with `watchfiles`

Add a small wrapper that watches `src/godot_ai/`, kills the child on change, and respawns it.

**How it works**: an outer process owns the watcher and respawns the server process directly.

**Changes**: Medium. Roughly 50-70 lines, plus adding `watchfiles`.

**Dev UX**: Similar to Approach 1, but both ports are usually released during restart. Claude still loses the MCP session.

| Pro | Con |
|-----|-----|
| Simple mental model | Worse port behavior than uvicorn's supervisor |
| No FastMCP internals | Claude session dies on every restart |
| Easy to debug | Must add `watchfiles` and handle process lifecycle cleanly |
| Flexible for custom restart policies | Mostly dominated by Approach 1 |

**Robustness**: Medium.

**Assessment**: This is not a bad approach, but it is hard to justify over Approach 1 unless custom restart policy is the real goal. For dev reload specifically, it is a weaker version of the same idea.

---

## Approach 3: In-process hot-swap with `importlib.reload()`

Watch selected modules in-process, call `importlib.reload()` on change, then re-register the affected tools and resources on the live FastMCP instance.

**How it works**:

1. A background watcher monitors `src/godot_ai/tools/` and optionally `src/godot_ai/resources/`
2. On change, reload the changed modules
3. Remove and re-add the affected tools/resources
4. Existing HTTP server, WebSocket server, and MCP session stay alive

**Changes**: Medium-high. Roughly 80-120 lines plus a watcher dependency.

**Dev UX**: Edit a tool/resource implementation -> new calls pick up the change without a process restart, `/mcp`, or Godot reconnect.

| Pro | Con |
|-----|-----|
| Best short-term UX for implementation edits | `importlib.reload()` is fragile |
| Claude session survives | Structural changes still require restart |
| WebSocket stays up | Reload leaks and stale references are real risks |
| Fast to implement in the current codebase | Schema changes need explicit MCP refresh behavior |

**Where it fits well**:

- Tool implementation changes
- Resource implementation changes
- The current codebase, where registration is centralized and current tools/resources are simple request handlers

**Where it breaks down**:

- Lifespan changes
- Transport and protocol changes
- WebSocket server changes
- Session management changes
- Broad refactors with module-level state or cross-module import cycles

**Robustness**: Medium.

**Assessment**: This is the fastest path to a good developer loop without `/mcp`, but it gets its ergonomics by mutating live Python state. It is a tactical solution, not the cleanest long-term architecture.

---

## Approach 4: Explicit reload endpoint + dock button

Add a `POST /reload` endpoint, or a `reload_server` tool, that tells the process to exit cleanly and restart under a small wrapper. Optionally watch files and show "changes detected" in the dock without auto-restarting.

**Changes**: Low-medium. Roughly 40-60 lines across the server entry point, wrapper, and dock.

**Dev UX**: Edit Python file -> click reload or tell Claude to trigger reload. Process restarts. Claude loses the MCP session.

| Pro | Con |
|-----|-----|
| Deterministic and simple | Manual or explicit action required |
| Clean full restart | Claude session dies |
| Good fallback for structural changes | Not fully automated |
| Easy to reason about in production-like flows | Ports flap during restart unless paired with a supervisor |

**Robustness**: High for the mechanism. Low for the stated automation goal.

---

## Approach 5: Dev-Mode Thin Stable Host + Restartable Worker

Split the system into two layers:

- **Stable host process**: owns the HTTP MCP transport, streamable-http session/event state, WebSocket server to Godot, session routing, file watching, and supervision
- **Reloadable worker process**: owns most server-side implementation code and can be restarted freely on file change

The key design principle is that the process holding Claude's MCP session must stay alive. Reload should be a worker concern, not a transport concern.

The important refinement is that this should be a **dev-mode architecture**, not the default production/runtime shape:

- **Normal mode**: single process, direct execution, no worker, no RPC
- **Dev reload mode**: stable host + restartable worker

That avoids paying permanent latency and runtime complexity costs for a developer convenience feature.

### What the host owns

- FastMCP transport and session lifecycle
- MCP tool/resource facade exposed to Claude
- WebSocket server and `SessionRegistry`
- A narrow internal API for talking to Godot and reading active session state
- Worker supervision and restart policy

### What the worker owns

- Most fast-changing Python behavior
- Domain logic behind scene, node, project, testing, and editor workflows
- Any code we expect Claude to iterate on frequently

### How calls would flow

1. Claude calls an MCP tool on the host
2. The host dispatches to the worker over a local RPC boundary
3. The worker does the computation and, when needed, calls back through the host's narrow Godot/session API
4. On file change, the host restarts the worker
5. Claude's MCP session survives because the host never died

### Why this is attractive in an early project

Because the project is young, the boundary can be chosen now rather than reverse-engineered later. The host can stay intentionally small and boring, while the worker absorbs most of the fast-moving code.

This avoids the biggest weakness of Approach 3: no mutation of live Python objects, no `importlib.reload()` games, no half-reloaded module graph.

### The important constraint

This architecture preserves sessions cleanly only if the host owns the stable parts:

- MCP transport/session state
- WebSocket server to Godot
- session registry / active session routing

If those stay in the worker, restarting the worker still drops the state we care about.

### Open design choice: stable schema vs dynamic schema

There are two ways to structure the host:

1. **Stable schema host**: host exposes a fixed set of tools/resources and forwards each call into the worker. This is the cleanest design if tool names and signatures are mostly stable.
2. **Dynamic schema host**: worker publishes a manifest and the host updates its MCP registry when schema changes. This is more flexible, but requires careful handling of MCP `list_changed` notifications and client behavior.

Given the current project, a stable-schema host is the cleaner first version.

The other important design choice is shared implementation:

- shared handler logic should be used in both modes
- normal mode should call those handlers directly
- dev mode should call those same handlers through the worker RPC boundary

That keeps the worker split from becoming a separate product architecture.

| Pro | Con |
|-----|-----|
| Best long-term balance of cleanliness, iteration speed, and robustness | Highest upfront design cost |
| Real process restart for most code, without killing Claude's session | Requires defining and maintaining an internal RPC boundary |
| Avoids `importlib.reload()` fragility | Two-process debugging is more complex in dev mode |
| Host can keep Godot connected while worker reloads | Host-side changes still require a real restart |
| Zero production impact if kept dev-only | Tool-schema evolution still needs an explicit strategy |

**Robustness**: High, if the host boundary stays small.

**Assessment**: This is the cleanest end-state architecture for **dev reload**. It turns reload into a normal supervision problem rather than a runtime object mutation trick, without forcing production into a permanent two-process runtime.

See [design-stable-host-worker.md](design-stable-host-worker.md) for the concrete host/worker boundary, RPC shape, and migration plan.

---

## Comparison Matrix

| | Auto-detect changes | Claude session survives | Godot WS survives | Handles all code | Complexity |
|---|---|---|---|---|---|
| **1: uvicorn bypass** | Yes | No | Reconnects | Yes | Low |
| **2: process wrapper** | Yes | No | Reconnects | Yes | Medium |
| **3: hot-swap** | Yes | Yes | Yes | Selected modules only | Medium-high |
| **4: explicit reload** | Optional | No | Reconnects | Yes | Low |
| **5: dev-only stable host + worker** | Yes | Yes | Yes, if host owns WS | All worker-side code in dev mode | High |

---

## Recommendation

If the question is "what is the smallest fix for broken Python reload?", the answer is **Approach 1**.

If the question is "what is the fastest way to get a good no-`/mcp` dev loop in this codebase?", the answer is **Approach 3**, limited to tool/resource implementation modules, with **Approach 4** as a fallback for structural changes.

If the question is "what is the best system to build now, given that the project is early and we can choose the architecture freely?", the answer is **Approach 5**, but specifically as a **dev-mode-only split**, not the default production runtime.

### Why Approach 5 is the best long-term system

- It preserves Claude's MCP session by keeping the transport process stable
- It preserves Godot connectivity if the host owns the WebSocket server and session registry
- It allows real process restarts for most code instead of in-process mutation
- It creates a cleaner separation between stable runtime plumbing and fast-changing application logic
- It keeps production/default mode simple if the split is activated only for dev reload
- It is more robust under refactors, broader code changes, and future growth

### Suggested practical plan

1. Keep normal mode single-process.
2. Extract shared handler logic so normal and dev paths use the same implementation.
3. Build a small dev host that owns MCP transport, WebSocket, sessions, and supervision.
4. Put fast-changing server logic behind a narrow worker boundary in dev mode only.
5. Keep the initial host schema stable rather than dynamically regenerating tools/resources.
6. Add file watching to restart the worker on Python changes.
7. Keep `reload_plugin` for GDScript changes.
8. Reserve full host restart for transport/protocol/session-layer changes.

### Recommended fallback if Approach 5 feels too large right now

Implement **Approach 3 + Approach 4** first, but do it with the host/worker split in mind:

- hot-reload only tool/resource implementation modules
- avoid hot-reloading transport/session/lifespan code
- keep the future stable host boundary obvious

That gives a good dev loop quickly without locking the project into `importlib.reload()` forever.

## Bottom Line

Approach 3 is the best **tactical** answer.

Approach 5, implemented as a **dev-only split**, is the best **system**.
