# Godot AI — Product Proposal

*Updated 2026-04-14*

This document defines what **Godot AI** should be and why it should exist.

Use the supporting docs for the other concerns:

- [Working Plan](implementation-plan.md) for active and upcoming work
- [Tool Taxonomy](tool-taxonomy.md) for the detailed tool surface
- [Plugin Architecture](plugin-architecture.md) for plugin/server design
- [Testing Strategy](testing-strategy.md) for verification and CI
- [Packaging & Distribution](packaging-distribution.md) for install and release paths
- [Product Positioning](product-positioning.md) for naming, differentiation, and community strategy

---

## Thesis

Build a production-grade, fully open-source Godot MCP server that feels native to Godot and mature enough for real daily use.

The project should clear a much higher bar than a thin editor bridge:

- persistent editor integration
- reliable session routing
- strong read resources and safe write workflows
- runtime feedback loops that let an AI inspect what it just changed
- tests, CI, documentation, diagnostics, and operational discipline

The opportunity is not to clone another engine MCP. The opportunity is to bring a mature product and maintenance standard to the Godot community in a tool that is openly built for Godot from day one.

---

## Why This Project Exists

Godot is a strong fit for a serious MCP server:

- the ecosystem is open, scriptable, and community-oriented
- the engine exposes the right core APIs for scenes, nodes, resources, project settings, editor plugins, viewport capture, and project automation
- the current Godot MCP landscape still leaves room for a better-tested, more usability-focused product

The project should be built around a simple idea:

- make an excellent Godot MCP for the Godot community

That means:

- deep support for common Godot workflows
- practical tooling that improves day-to-day editor use
- open-source development with clear contributor paths
- product decisions shaped by real user feedback instead of novelty chasing

---

## Product Principles

### Godot-native naming

Use Godot concepts directly:

- `scene.*`, not generic level abstractions
- `node.*`, not `entity.*`
- `resource.*`, not fake cross-engine asset terms
- `signal.*`, `autoload.*`, `input_map.*`, `project_settings.*`

If a concept is Godot-specific, expose it directly.

### Persistent editor plugin first, headless path second

Interactive editor automation should run through a persistent Godot editor plugin with a long-lived connection to the MCP server.

Headless execution still matters, but as a separate path for:

- CI
- exports
- scripted imports
- recovery when the editor plugin is unavailable

### Read surfaces before aggressive mutation

The product should first become excellent at reliable inspection:

- scene tree
- selection
- project info
- filesystem index
- logs
- project settings

Then it should add write tools with proper undo integration, readiness gating, and error reporting.

### Explicit session targeting

Every tool call must target a specific Godot editor session. Never rely on "last connected editor."

### `code.execute` stays privileged

Editor-side GDScript execution is useful, but it should stay an escape hatch and security boundary, not the main API.

---

## Product Scope

### V1 product standard

**Godot 4.3+ is required. Godot 4.4+ is preferred** for UID support and newer editor APIs.

The first serious release should be strong in these areas:

- scene creation and lifecycle
- node hierarchy inspection and mutation
- resource and filesystem workflows that stay in sync with Godot import state
- script creation, reading, and attachment
- signals, autoloads, input, and project configuration
- run/stop, screenshots, logs, and basic runtime diagnostics
- multi-instance awareness
- tests, CI, and a real install story

### Explicit non-goals for V1

- exhaustive coverage of every Godot editor subsystem
- full parity with every mature Unity MCP or editor package
- giant action-blob tools with huge optional parameter surfaces
- profiler, package-manager, or marketplace ambition before core workflows are solid
- broad arbitrary code execution as the default interface

---

## Capability Direction

The product should feel like a Godot tool, not a generic game-engine bridge.

### Core tool families

The core surface should center on:

- `session.*` and `editor.*`
- `scene.*` and `node.*`
- `resource.*` and `filesystem.*`
- `script.*`
- `signal.*`, `autoload.*`, `input_map.*`, `project_settings.*`
- `project.run`, `project.stop`, `logs.*`, `performance.*`
- read-heavy MCP resources for sessions, scene state, selection, project settings, and recent logs

Detailed tool-family guidance lives in [tool-taxonomy.md](tool-taxonomy.md).

### Runtime feedback is the real threshold

A tool surface that can only author files and scene structure is not enough. The product becomes materially more useful when it can:

- launch the project
- inspect logs and runtime state
- capture screenshots
- measure basic performance signals
- iterate without losing session safety

That is the difference between "can scaffold a project" and "can improve a game."

### Prototype-driven extensions

After the runtime loop is solid, the next major surface should support higher-quality game production:

- `ui.*`
- `camera.*`
- `animation_player.*` / `animation_tree.*`
- `audio.*`
- `material.*`, `shader.*`, `particles.*`
- light `physics.*`, `tilemap.*`, and `navigation.*` where the benchmark justifies them

The first serious benchmark for that stage should be the small top-down roguelite slice in [implementation-plan.md](implementation-plan.md).

### Borrow mature patterns, not engine-specific assumptions

What should carry over from mature editor MCP work:

- persistent connections
- session routing
- readiness checks
- resources for read-heavy state
- structured errors
- batch execution with clear contracts
- layered testing and CI

What should not be copied literally:

- `manage_*` blob tools
- Unity-specific object or package assumptions
- fake portability that hides Godot concepts behind generic names

---

## Product Quality Bar

The project should be judged as a serious developer tool, not just as an experiment.

That means:

- installable without repo archaeology
- trustworthy under normal editor use
- explicit about undoability and safety boundaries
- documented well enough for contributors to extend it
- tested across Python, plugin, and real-project workflows

The intent is not breadth for its own sake. The intent is a smaller surface that is coherent, dependable, and obviously shaped by real use.

---

## Why Godot AI Can Win

The differentiation is straightforward:

- Godot-native tool families instead of a thin generic bridge
- persistent plugin architecture instead of one-shot command relay
- runtime feedback loops instead of file-authoring only
- real tests, CI, docs, and release discipline
- open development shaped by community feedback

That is enough to make the project meaningful if it is executed well.

For the detailed positioning, naming, and community strategy, use [product-positioning.md](product-positioning.md).
