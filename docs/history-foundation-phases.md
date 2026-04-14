# Godot AI — Foundation History

*Updated 2026-04-13*

This document preserves the early implementation history that used to live inside the main implementation plan. It is intentionally archival. For the current roadmap, use [implementation-plan.md](implementation-plan.md).

---

## Original Assumptions

The project started with these assumptions:

- solo developer plus Claude Code as AI pair
- Godot 4.4+ target
- persistent editor plugin over WebSocket
- Python FastMCP server
- eventual distribution through PyPI, `uvx`, and possibly standalone binaries

The early plan mixed “how to bootstrap the repo” with “what the long-term product should become.” That was useful at the start, but too noisy once the project had real momentum.

---

## Weekend Spike Objective

The original weekend spike was designed to prove the full vertical:

- AI client
- MCP server
- WebSocket transport
- Godot editor plugin
- editor API execution
- response back to the client

### Python Track

The server-side spike focused on:

- project bootstrap
- protocol envelope and response correlation
- WebSocket transport
- session registry
- first tool and first resource
- mock integration test coverage

### Godot Track

The plugin-side spike focused on:

- editor plugin bootstrap
- WebSocket connection and reconnect
- handshake
- command dispatch
- `editor.state`
- `scene.get_hierarchy`

### What The Spike Needed To Prove

- Godot’s `WebSocketPeer` was workable enough for this architecture
- a real MCP tool could roundtrip through the editor
- the editor API surface was reachable from the plugin the way the product needed

---

## Post-Spike Hardening That Shipped

These items were identified immediately after the spike and are now done:

- [x] split the early `connection.gd` god-object into connection, dispatcher, handlers, and dock responsibilities
- [x] made client configuration opt-in instead of silently mutating user config on plugin enable
- [x] added undo integration for write tools
- [x] fixed session state freshness so scene and play-state updates propagate live
- [x] built the Godot dock panel
- [x] switched the test project to use a symlinked plugin copy
- [x] added meaningful integration tests

This was the point where the project stopped being a vertical-slice experiment and started becoming a real tool.

---

## Phase 0 / 0.5 Outcomes

The “Phase 0” part of the old plan covered protocol and reliability work:

- versioned handshake and structured errors
- session model and metadata
- connection reliability
- command queue and frame-budget dispatch
- readiness tracking
- headless-path investigation

The “Phase 0.5” part covered distribution thinking:

- PyInstaller as an early packaging spike
- end-user install flow
- client configuration expectations
- release CI assumptions

That work now lives more cleanly in:

- [plugin-architecture.md](plugin-architecture.md)
- [packaging-distribution.md](packaging-distribution.md)
- [go-no-go-gates.md](go-no-go-gates.md)

---

## Phase 1 Delivered Surface

Phase 1 established the “read-first” product slice.

### Read Tools

- [x] `session.list`
- [x] `session.activate`
- [x] `editor.state`
- [x] `editor.selection.get`
- [x] `scene.get_hierarchy`
- [x] `scene.get_roots`
- [x] `node.find`
- [x] `node.get_properties`
- [x] `node.get_children`
- [x] `node.get_groups`
- [x] `project_settings.get`
- [x] `logs.read`
- [x] `filesystem.search`

### Read Resources

- [x] `godot://sessions`
- [x] `godot://scene/current`
- [x] `godot://scene/hierarchy`
- [x] `godot://selection/current`
- [x] `godot://project/info`
- [x] `godot://project/settings`
- [x] `godot://logs/recent`

### Supporting Systems

- [x] pagination for large results
- [x] Godot dock panel with setup status
- [x] handler/runtime abstraction layer
- [x] Codex client configurator
- [x] `reload_plugin`
- [x] Python auto-reload path for dev
- [x] Godot-side test harness

Phase 1 was where the product became useful even before the write path was complete.

---

## Phase 2 Delivered Surface

Phase 2 established the safe write path.

### Scene And Node Writes

- [x] `scene.create`
- [x] `scene.open`
- [x] `scene.save`
- [x] `scene.save_as`
- [x] `node.create`
- [x] `node.delete`
- [x] `node.reparent`
- [x] `node.set_property` for simple types
- [x] `node.duplicate`
- [x] `node.move`
- [x] `node.add_to_group`
- [x] `node.remove_from_group`
- [x] `editor.selection.set`

### Script / Resource / Filesystem Writes

- [x] `script.create`
- [x] `script.read`
- [x] `script.attach`
- [x] `script.detach`
- [x] `script.find_symbols`
- [x] `resource.search`
- [x] `resource.load`
- [x] `resource.assign`
- [x] `filesystem.read_text`
- [x] `filesystem.write_text`
- [x] `import.reimport`

### Safety And Reliability Work

- [x] readiness gating for unsafe editor states
- [x] undo integration for scene-tree mutations
- [x] graceful editor quit
- [x] fixes for re-entrant frame processing during scene save

### What Phase 2 Proved

- the project could safely mutate small Godot projects
- undo and readiness were real product features, not just ideas
- the AI could create scenes, add nodes, attach scripts, and set properties without handholding on every step

---

## Why This History Was Split Out

The early plan mixed too many concerns:

- bootstrap checklist
- historical record
- live roadmap
- architecture reference
- packaging notes
- risk tracking

That made the main plan hard to read. This archive keeps the important history without forcing the current roadmap to carry all of it.

