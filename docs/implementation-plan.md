# Godot AI — Working Plan

*Updated 2026-04-15*

This is the current working plan for Godot AI. It focuses on active and upcoming work only.

Historical bootstrap material, architecture detail, packaging mechanics, go/no-go gates, and the risk register now live in separate docs:

- [Architecture Proposal](proposal.md)
- [Tool Taxonomy](tool-taxonomy.md)
- [Foundation History](history-foundation-phases.md)
- [Plugin Architecture](plugin-architecture.md)
- [Testing Strategy](testing-strategy.md)
- [Packaging & Distribution](packaging-distribution.md)
- [Product Positioning](product-positioning.md)
- [Go/No-Go Gates](go-no-go-gates.md)
- [Risk Register](risk-register.md)

---

## Status Snapshot

- [x] Phase 1 read surface shipped
- [x] Phase 2 safe write surface shipped
- [x] Core Godot-native config tools shipped: `signal.*`, `autoload.*`, `input_map.*`, `project_settings.set`
- [x] Godot-side test harness and `test_run` / `test_results_get` shipped
- [x] Readiness gating and undo integration are in place for the current write surface
- [x] Runtime feedback loop: `project.run`/`project.stop`, `editor.screenshot`, `performance.get_monitors`, `logs.clear`
- [ ] Runtime iteration loop is complete enough for AI-driven feel tuning
- [ ] Release/install path is complete enough for new users
- [ ] Polished game-production extensions have started

## What This Plan Optimizes For

- useful day-to-day Godot editing before breadth
- AI-visible feedback loops before more authoring surface
- Godot-native tool families over generic abstraction
- tight test coverage and live smoke checks for every new surface
- small, composable tools instead of giant action blobs

---

## Current Priority: Finish Phase 3

### Runtime Feedback Loop

- [x] `project.run` with `main`, `current`, and `custom` modes
- [x] `project.stop` with validation (rejects if not playing)
- [x] `editor.screenshot` returning inline MCP ImageContent (viewport/game sources, configurable resolution)
- [x] `editor.screenshot` multi-angle coverage + temporary camera control (`view_target`, `coverage`, `elevation`, `azimuth`, `fov`) with AABB geometry metadata
- [x] `performance.get_monitors` with optional filter (30 Godot Performance monitors)
- [x] `logs.clear`
- [x] WebSocket buffer increase (4 MB) for large payloads like screenshot base64

**Why this matters:** Without a reliable launch-observe-inspect loop, the AI can build project structure but cannot tighten feel, readability, or performance.

### High-Leverage Authoring

- [x] `batch.execute` with stop-on-first-error semantics and optional grouped undo
- [x] `node.rename` with sibling-collision validation and char-safety checks (NodePath/script references in OTHER nodes are not auto-updated — documented in the tool)
- [x] complex `node.set_property` (`Resource` via res:// path, `NodePath`, `Array`, `Dictionary`, `StringName`)
- [x] `script.patch` shipped — anchor-based `old_text` → `new_text` replace with ambiguity detection and optional `replace_all`

**Why this matters:** These are workflow multipliers. They matter more for real project iteration than adding another narrow read tool.

### Multi-Session Reliability

- [x] reliable multi-instance routing — fixed `SessionRegistry.unregister` silently promoting the first-registered session; reload handler now pins `session_id` explicitly
- [x] clear session selection semantics in tools and UI — `session_activate` accepts substring hints (project folder name / path / session_id) in addition to exact UUID, with ambiguous-match and no-match paths that list candidates
- [x] enough session metadata to distinguish multiple editors safely — added `name` (project basename), `editor_pid`, and `last_seen` heartbeat to every session; surfaced in `session_list`
- [x] per-call session targeting — every Godot-talking tool accepts an optional `session_id`; bound at the `DirectRuntime` layer so `require_writable` and handlers see the pinned session. Lets two AI clients share one server without stomping each other's active.
- [x] human-readable session IDs — `<project-slug>@<4hex>` (e.g. `godot-ai@a3f2`) instead of 32-char random hex. Agents can recognize/remember the target without calling `session_list` first.

**Why this matters:** Real use will quickly involve multiple projects, multiple editor windows, or multiple test sessions. The session model needs to stop being “good enough for one editor.”

### Phase 3 Exit Criteria

- [x] `signal.*`, `autoload.*`, `input_map.*`, `project_settings.set`
- [x] run/stop cycle is reliable
- [x] batch execution is shipped with a clear contract
- [x] multi-instance routing works in practice
- [x] `script.patch` decision is made (shipped: anchor-based replace)
- [x] test coverage and smoke coverage increase where the new runtime loop needs it (310 Python + 227 GDScript = 537 total)

---

## Next Priority: Phase 4 Release Path

See [Packaging & Distribution](packaging-distribution.md) for full detail. The short version:

- [ ] clean install docs for Claude Code, Codex, and other MCP clients
- [ ] PyPI / `uvx` path works reliably
- [ ] desktop binary path is real, not aspirational
- [ ] plugin is downloadable from the Godot AssetLib
- [ ] CI covers Python tests, Godot-side tests, and release-smoke install paths
- [ ] compatibility guidance is published and maintained
- [ ] a new user can get from zero to working in under 10 minutes

Release is not just packaging. It is install flow, docs, smoke coverage, and support burden reduction.

---

## Tool Search Friendliness

Anthropic's tool search (`tool_search_tool_regex_20251119` / `tool_search_tool_bm25_20251119`) lets clients defer loading tool definitions until the model searches for them. Our surface will grow past the 30-50 tool threshold where selection accuracy starts to degrade, so the MCP server needs to be a good citizen in that system.

- [x] audit every tool name for consistent, searchable namespacing (`scene_*`, `node_*`, `script_*`, `signal_*`, `input_map_*`, `editor_*`, `project_*`, `resource_*`, `filesystem_*`, etc.) — no ambiguous or one-off prefixes
- [x] audit every tool description so it contains the keywords a user would naturally use to describe the task (e.g. `screenshot`, `viewport`, `game view`, `input action`, `autoload singleton`) in addition to the Godot term
- [x] audit argument names and argument descriptions — tool search indexes these too
- [x] document which tools should stay non-deferred (the 3-5 most common: likely `editor_state`, `scene_get_hierarchy`, `node_get_properties`, plus session tools) and mark the rest `defer_loading: true` in the server's MCP advertisement where the protocol permits
- [x] add a short "available tool categories" blurb to the server's MCP server instructions so clients using tool search have a map of what to search for
- [x] verify the published surface still works for clients that do not use tool search (no tool should require a specific discovery path)

**Why this matters:** Once the tool count crosses ~50, clients that load every definition upfront start paying a real context-window tax and the model starts picking wrong tools. Writing names and descriptions with search in mind is cheap now and costly to retrofit later.

---

## Prototype-Driven Extensions

These are not the next things to do blindly. They are the extensions that matter once the runtime loop is solid and the project is ready to prove itself against a more polished game benchmark.

### Tier 1: Needed for Better 2D Game Production

- `ui.*` for HUDs, pause menus, upgrade draft screens, game-over flows, and theme/layout work
- `camera.*` for follow, bounds, zoom, and screen shake
- `resource.create` / `resource.save` / `resource.instantiate`
- `scene.instantiate` and `scene.inherit`
- `animation_player.*` / `animation_tree.*`
- `audio.*`

### Tier 2: Strong Polish Multipliers

- `material.*`, `shader.*`, `particles.*`
- `physics.*` helpers for layers, masks, bodies, and common 2D setup
- light `tilemap.*` and/or `navigation.*` if the benchmark moves from a single arena to authored rooms

### Tier 3: Verification and Shipping Support

- `build.*`
- richer performance diagnostics
- more capture and regression-verification helpers where they materially help iteration
- `editor_viewport_*` — toggle per-viewport display options that live outside the scene (e.g. View Environment / View Gizmos, Preview Sun, Preview Environment, grid visibility, orthogonal vs. perspective). Useful when the AI needs the editor grid visible, or wants to disable the default sky to judge lighting. These are editor-only state, not scene state, so they require a dedicated surface rather than `node_set_property`.

**The rule here is simple:** Do not add broad polish tooling before the AI can already launch the game, inspect results, and make safe iterative edits.

---

## First Prototype Benchmark: Top-Down Roguelite

Use a small 2D top-down roguelite as the first benchmark, but keep it room-based or arena-based rather than jumping straight to full procedural dungeons.

### Benchmark Scope

- one player character with move, shoot, and dash
- three enemy archetypes
- one boss or final survival spike
- XP or currency pickups
- 10-15 upgrades presented through a draft or choice screen
- one arena with escalating waves or 3-5 short rooms
- HUD, pause, death, restart, and upgrade UI
- placeholder art is acceptable
- unreadable combat feedback is not acceptable

### What The Current Stack Can Already Do

- [x] build an ugly but functional arena prototype with nodes, scripts, resources, input, autoloads, signals, and tests
- [x] create and mutate small Godot projects safely in the editor
- [ ] support the kind of runtime iteration needed to make the benchmark feel good

### What Must Exist Before This Is A Fair Benchmark

- [x] run/stop plus screenshot capture and basic performance sampling
- [ ] `batch.execute` and a safe partial-edit story
- [ ] data-authoring surface for upgrades, enemies, room data, and reusable scenes
- [ ] `ui.*` for HUD and upgrade selection
- [ ] `camera.*` for follow, bounds, zoom, and shake
- [ ] `animation_player.*` and `audio.*` for combat readability and feel
- [ ] `particles.*` / `shader.*` / `material.*` for hit juice and feedback clarity
- [ ] light `physics.*` and optionally `tilemap.*` / `navigation.*` if rooms become more authored

### Benchmark Exit Criteria

- [ ] Godot AI can author the project structure, gameplay scenes, and data assets with limited manual cleanup
- [ ] the AI can launch the game, inspect results, and tighten feel over repeated iterations
- [ ] a human reviewer would call the slice readable and juicy, not just functional
- [ ] the prototype can be exported to a desktop build without bespoke handholding

---

## What We Are Not Doing Yet

- using the implementation plan as a historical changelog
- promising exhaustive tool coverage before the core loop is strong
- benchmarking with a full procedural dungeon crawler before the arena/room loop works
- building genre-specific high-level DSLs before the general authoring surface is good enough
