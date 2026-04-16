# Godot AI — Tool Taxonomy

*Updated 2026-04-16*

This document describes the intended Godot-native tool surface.

Use the related docs for the adjacent concerns:

- [proposal.md](proposal.md) for the product case and scope
- [implementation-plan.md](implementation-plan.md) for what is being built next
- [plugin-architecture.md](plugin-architecture.md) for the plugin/server model

---

## Tool Design Rules

The surface should look like a Godot product, not a generalized game-engine layer.

The rules are:

- use Godot names directly
- prefer small, composable tools over blob commands
- expose read-heavy state as MCP resources where that is cleaner than a tool
- keep filesystem and resource workflows aware of Godot import behavior
- treat runtime feedback as first-class, not optional

One important example is filesystem handling: raw OS writes to `res://` are not enough when Godot still needs to scan or reimport. That is why `filesystem.*` and `import.reimport` are meaningful even when the client already has native file access.

---

## Core Tool Families

### Session and editor

- `session.list`
- `session.activate`
- `editor.state`
- `editor.selection.get`
- `editor.selection.set`
- `editor.screenshot`
- `editor.command.execute`

These tools make the editor visible and routable.

### Scene and node

- `scene.create`
- `scene.open`
- `scene.save`
- `scene.save_as`
- `scene.close`
- `scene.instantiate`
- `scene.inherit`
- `scene.get_hierarchy`
- `scene.get_roots`
- `node.create`
- `node.delete`
- `node.duplicate`
- `node.reparent`
- `node.rename`
- `node.move`
- `node.find`
- `node.get_properties`
- `node.set_property`
- `node.get_children`
- `node.get_groups`
- `node.add_to_group`
- `node.remove_from_group`

This is the core authoring surface for real Godot projects.

### Resource and filesystem

- `resource.search`
- `resource.load`
- `resource.save`
- `resource.create`
- `resource.assign`
- `resource.inspect`
- `resource.instantiate`
- `filesystem.search`
- `filesystem.read_text`
- `filesystem.write_text`
- `filesystem.move`
- `filesystem.rename`
- `filesystem.delete`
- `import.reimport`

This is the data-authoring and content-pipeline surface.

### Script

- `script.create`
- `script.read`
- `script.patch`
- `script.attach`
- `script.detach`
- `script.find_symbols`
- `script.get_class_info`

`script.patch` is especially sensitive because GDScript is indentation- and annotation-sensitive. It is valuable, but it should only ship with a trustworthy contract.

### Project configuration

- `signal.list`
- `signal.connect`
- `signal.disconnect`
- `autoload.list`
- `autoload.add`
- `autoload.remove`
- `input_map.list`
- `input_map.add_action`
- `input_map.remove_action`
- `input_map.bind_event`
- `project_settings.get`
- `project_settings.set`
- `uid.get`
- `uid.update`

These tools are disproportionately useful because they let an AI wire actual game structure instead of only manipulating isolated nodes.

### Runtime and diagnostics

- `project.run`
- `project.stop`
- `logs.read`
- `logs.clear`
- `performance.get_monitors`
- `batch.execute`
- `build.list_presets`
- `build.export`

This surface is what turns the project from an authoring assistant into an iterative game-development tool.

### MCP resources

Read-heavy state should often be exposed as resources instead of tools:

- `godot://sessions`
- `godot://scene/current`
- `godot://scene/hierarchy`
- `godot://selection/current`
- `godot://project/info`
- `godot://project/settings`
- `godot://autoloads`
- `godot://input-map`
- `godot://filesystem/index`
- `godot://logs/recent`

---

## Production Extensions

These are the next layers once the core runtime loop is dependable.

### Better 2D game-production tools

- `ui.*` for HUDs, menus, upgrade screens, theme/layout work
- `camera.*` for follow, bounds, zoom, shake, and capture helpers
- `animation_*` — AnimationPlayer authoring shipped (player + animation creation, property/method tracks, autoplay, dev-time play/stop, list/get, `animation_create_simple` composer, `animation_delete`, `animation_validate`). `animation_create` and `animation_create_simple` support an `overwrite` parameter to replace existing animations in place. Auto-attaches a default `AnimationLibrary` on first write. Works for 2D, 3D, and UI; `animation_tree.*`, bezier/audio tracks, preset helpers, and 3D material-fade coercion are tracked as follow-ups in `implementation-plan.md`.
- `audio.*`

These are the tools that move the project from "functional prototype" toward "readable and polished prototype."

### Strong polish multipliers

- `material.*`
- `shader.*`
- `particles.*`
- `physics.*` helpers
- light `tilemap.*`
- light `navigation.*`

These matter, but they should come after the project can already run, inspect, and safely iterate.

---

## Capability Mapping

Looking at mature editor MCP work is useful, but only if the translation stays honest.

### Capabilities that translate cleanly

- scene lifecycle tools
- node inspection and mutation
- resource and filesystem management
- script creation and inspection
- run/stop controls
- log inspection
- batch execution

These should anchor the first serious release.

### Capabilities that need Godot-native adaptation

- build workflows should be modeled around Godot export presets, not another engine's build pipeline
- camera tools should use `Camera2D`, `Camera3D`, `SpringArm3D`, and viewport capture rather than pretending Cinemachine exists
- UI tools should be modeled around `Control`, containers, anchors, offsets, size flags, and themes
- data-asset workflows should lean into `Resource` rather than cargo-culting ScriptableObject terminology
- profiler-style tooling should start as lightweight runtime diagnostics instead of promising parity with more mature profiler products

### Capabilities that should not be cloned literally

- `manage_*` blob tools with huge optional schemas
- package-manager assumptions tied to another engine's ecosystem
- package-specific VFX or camera abstractions that Godot does not have
- any naming layer that hides Godot's actual scene/node/resource model

---

## Strategic Takeaway

The right target is not parity theater. The right target is a mature, useful, reliable editor MCP expressed through Godot-native concepts and workflows.
