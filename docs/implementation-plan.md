# Godot AI — Working Plan

*Updated 2026-04-16 (PR #30 — materials + particles)*

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
- [~] Polished game-production extensions have started — `ui_*` (anchor presets, `ui_build_layout` composer, `theme_override_*` pseudo-properties), `theme_*` (color/constant/font-size/stylebox_flat with nested `border`/`corners`/`margins`/`shadow` dicts, `apply`), `animation_*` (AnimationPlayer + `animation_create_simple` composer + delete/validate + overwrite support, undo robust to history interleaving), `material_*` (Standard / ORM / CanvasItem / Shader with enum-by-name + 6 presets), `particle_*` (GPU+CPU 2D+3D with 7 presets, auto-attached billboard draw material so color_ramp renders out of the box), and `camera_*` (Camera2D/Camera3D create/configure/limits/damping/follow/get/list + 4 presets, sibling-unmark on `current=true`, one-undo reparent-based follow) shipped; `audio_*`, dedicated `shader_*` CRUD, animation preset helpers, and 3D follow (SpringArm3D rig) still pending

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
- [x] `node.rename` with sibling-collision validation and char-safety checks (NodePath/script references in OTHER nodes are not auto-updated — documented in the tool). Now also allows renaming the scene root node.
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
- [x] test coverage and smoke coverage increase where the new runtime loop needs it (388 Python + 345 GDScript = 733 total)

---

## Next Priority: Phase 4 Release Path

See [Packaging & Distribution](packaging-distribution.md) for full detail. The short version:

- [x] clean install docs for Claude Code, Claude Desktop, Codex, and Antigravity (README + dock auto-configure with manual fallback)
- [ ] PyPI / `uvx` path works reliably
- [ ] desktop binary path is real, not aspirational
- [~] plugin is downloadable from the Godot AssetLib — release ZIP workflow ships `godot-ai-plugin.zip` via GitHub Releases; AssetLib submission in progress; dock has self-update check
- [x] CI covers Python tests, Godot-side tests, and release-smoke install paths (3 OS × 2 Python + 3 OS Godot + release-smoke). Linux CI uses `chickensoft-games/setup-godot` on `ubuntu-latest`. GDScript parse validation (`ci-check-gdscript`) runs before tests. Step timeouts prevent hangs.
- [x] bump-and-release workflow — `gh workflow run bump-and-release.yml -f bump=patch/minor/major` bumps versions, commits, tags, and triggers release build
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
  - [x] `ui_set_anchor_preset` — wrap `Control.set_anchors_and_offsets_preset`
  - [x] `ui_build_layout` — declarative nested-dict → atomic Control subtree
  - [x] `theme_create` / `theme_set_color` / `theme_set_constant` / `theme_set_font_size` / `theme_set_stylebox_flat` / `theme_apply` — Theme authoring (Godot's CSS-analog)
  - [ ] `theme_set_stylebox_texture` — 9-slice image-backed styleboxes for pixel-art UI (buttons, panels with real artwork)
  - [ ] `theme_set_font` + `theme_set_icon` — custom typography and icon sets (needs a Font / Texture2D resource handler first)
  - [ ] `ui_set_text` convenience — one call to set `.text` across Label / Button / LineEdit / RichTextLabel without remembering per-class property quirks
- [~] `camera_*` for follow, bounds, zoom, damping — shipped: `camera_create`, `camera_configure` (class-aware batch), `camera_set_limits_2d` (room bounds), `camera_set_damping_2d` (position/rotation smoothing + drag-margin deadzone), `camera_follow_2d` (reparent-based, one-undo), `camera_get`, `camera_list`, `camera_apply_preset` (topdown_2d, platformer_2d, cinematic_3d, action_3d). `current=true` auto-unmarks siblings of the same class in the same undo action. Pending: `camera_*` 3D follow via `SpringArm3D` rig (3D damping lives there too — Camera3D has no native smoothing) and screen shake (tracked as `animation_preset_shake`)
- `resource.create` / `resource.save` / `resource.instantiate`
- `scene.instantiate` and `scene.inherit`
  - [~] `node_create` now supports a `scene_path` parameter for instancing a `.tscn` as a child node. This covers the basic "instance a prefab" use case. Dedicated `scene.instantiate` (with transform overrides) and `scene.inherit` (inherited scenes) are still pending for full reusable-scene workflows.
- `animation_player.*` / `animation_tree.*`
  - [~] AnimationPlayer scaffolding shipped (`animation_player_create`, `animation_create`, `animation_add_property_track`, `animation_add_method_track`, `animation_set_autoplay`, `animation_play`, `animation_stop`, `animation_list`, `animation_get`, `animation_create_simple` composer, `animation_delete`, `animation_validate`). `animation_create` and `animation_create_simple` support `overwrite` parameter for re-creating animations in place.
  - [ ] **Preset helpers** — `animation_preset_fade`, `animation_preset_slide_in`, `animation_preset_shake`, `animation_preset_pulse_loop`. Thin wrappers over `animation_create_simple` that bake in the right transition / loop_mode / two-keyframe shape for each effect. Cuts a "fade in this Panel" from a 6-line tween spec to one call.
  - [ ] **Bezier and audio tracks** — `animation_add_bezier_track` (for hand-tuned curves where keyframe interpolation isn't enough) and `animation_add_audio_track` (timed AudioStreamPlayer cues; needs the audio resource handler first).
  - [ ] **`animation_tree.*`** — state-machine and blend-tree authoring for character locomotion (idle ↔ walk ↔ run blends, attack one-shots). Larger surface; depends on the AnimationPlayer being solid first.
  - [ ] **3D material fades / sub-resource paths** — animating a 3D mesh's transparency means tweening `MeshInstance3D:material_override:albedo_color`, which the value coercer needs to walk into. Today it falls through to raw value for nested resource paths. Requires extending `_coerce_value_for_track` to resolve `node:resource:property` chains, plus a worked example in the docstring.
  - [ ] **Coercion gaps for non-UI types** — `_coerce_for_type` currently handles Color / Vector2 / Vector3 / int / float / bool. Missing: `Transform3D` / `Quaternion` / `Basis` (3D rigging), `Vector3i` (TileMap), `NodePath` / `StringName` (prop-redirection animations), `Rect2` / `AABB`. Today these silently store the raw JSON value and play garbage. Fix is local to one function; the test plan is the harder bit (need fixture nodes for each property type).
  - [ ] **Library-keyed access** — current API targets the default library only. Multi-library workflows (e.g. importing a glTF skeleton with named clip libraries) need explicit `library` params on `animation_create` / `animation_add_*_track` / `animation_play`. Low priority — most users won't hit this.
- `audio.*`

### Tier 2: Strong Polish Multipliers

- [x] `material_*` — StandardMaterial3D / ORMMaterial3D / CanvasItemMaterial / ShaderMaterial authoring shipped. Tools: `material_create`, `material_set_param`, `material_set_shader_param`, `material_get`, `material_list`, `material_assign` (with `create_if_missing`), `material_apply_to_node` (inline material builder, one-undo), `material_apply_preset` (metal, glass, emissive, unlit, matte, ceramic). Enum-by-name coercion for transparency / shading_mode / blend_mode / cull_mode / etc. Shader uniform setting via `material_set_shader_param` drives arbitrary `.gdshader` parameters.
- [x] `particle_*` — GPUParticles2D/3D + CPUParticles2D/3D shipped with 7 presets (`fire`, `smoke`, `spark_burst`, `magic_swirl`, `rain`, `explosion`, `lightning`). Tools: `particle_create`, `particle_set_main`, `particle_set_process` (auto-creates `ParticleProcessMaterial` in-one-undo if missing), `particle_set_draw_pass` (grows `draw_passes` count + auto-default QuadMesh if slot empty), `particle_restart`, `particle_get`, `particle_apply_preset`. Every auto-create draw pass gets a billboard `StandardMaterial3D` with `vertex_color_use_as_albedo=true` so `color_ramp` actually renders — the default Godot draw pass has no material and silently ignores the gradient.
- [ ] `shader.*` for CRUD on `.gdshader` files (currently shaders can only be created by writing them via `filesystem_write_text` and loading with `material_set_shader_param`)
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

### UI Scenarios The Current Stack Can Already Scaffold

With `ui_set_anchor_preset`, `ui_build_layout`, and the `theme_*` authoring
family in place, an agent can one-shot a styled, anchored, undoable Control
tree for each of these benchmark-relevant UI surfaces — `theme_*` defines the
look once, `ui_build_layout` places it, `signal_connect` wires behavior:

- **Roguelite HUD** — health bottom-left, ammo bottom-right, score / boss bar top-center, minimap / combo top-right; one theme applied at `/Main/HUD` styles everything inside
- **Pause menu overlay** — full-rect dim panel, centered `VBoxContainer` with Resume / Settings / Quit buttons, themed hover/pressed states
- **Upgrade-draft screen** — centered bordered `Panel` with three side-by-side `Button` cards; rounded corners, drop shadow, and border from one `theme_set_stylebox_flat`
- **Game-over screen** — dim overlay, YOU DIED label, stats `Label` filled by the game script, Retry / MainMenu / Quit button row
- **Settings menu** — dialog panel with labeled slider rows (`HBoxContainer` of Label + HSlider) for master/music/SFX volume, fullscreen `CheckBox`, uniform spacing via `theme_set_constant`
- **Dialogue box** — `bottom_wide` panel with portrait `TextureRect`, name + message `RichTextLabel`, continue hint; game code mutates `.text` per line
- **Main menu** — logo top-center, title centered, vertical stack of nav buttons
- **Inventory grid** — `GridContainer` of themed `Panel` slots each holding an icon `TextureRect` and quantity `Label`; re-skinnable by swapping the theme
- **Tutorial prompt** — small themed `Panel` anchored where the tutorial wants it, styled key-cap via stylebox, text mutated as the tutorial progresses
- **Boss overlay** — `top_wide` panel with name Label, wide `ProgressBar` for health, horizontal row of phase indicators; phase color changes via a single `theme_set_color` update
- **Sliding pause menu** — `animation_create_simple` tweens `PauseMenu:position` from off-screen left to center with `ease_out`; `loop_mode="none"`; `animation_set_autoplay` omitted so script triggers it on pause input
- **Hover pulse on buttons** — `animation_create_simple` tweens `Button:scale` from `{x:1,y:1}` to `{x:1.08,y:1.08}` with `loop_mode="pingpong"`; autoplay starts immediately
- **Damage shake on HUD root** — property track on `HUD:position` with rapid keyframes at ±8px offsets over 0.3s; triggered by script on `player_hit` signal
- **Fade transition between UI screens** — `animation_create_simple` tweens `TransitionRect:modulate` from `{a:0}` to `{a:1}` (fade to black), then a method track calls `emit_signal("fade_complete")` at the midpoint

Each of these is now a single-prompt target. What these scenarios still
cannot express is: sound feedback, custom fonts, and pixel-art 9-slice buttons. Those are blocked by
the `audio.*` / `theme_set_font` / `theme_set_stylebox_texture` gaps
tracked above.

### What Must Exist Before This Is A Fair Benchmark

- [x] run/stop plus screenshot capture and basic performance sampling
- [x] `batch.execute` and a safe partial-edit story
- [ ] data-authoring surface for upgrades, enemies, room data, and reusable scenes
- [~] `ui.*` for HUD and upgrade selection — anchor presets, declarative `ui_build_layout` composer, and `theme_*` authoring shipped; still need `ui_set_text`, `theme_set_font`, `theme_set_stylebox_texture` for pixel-art / custom typography
- [~] `camera_*` for follow, bounds, zoom, damping — 2D surface shipped (see Tier 1 above); 3D follow / SpringArm3D rig and screen shake (`animation_preset_shake`) still pending
- [~] `animation_player.*` shipped; `audio.*` still pending for combat readability and feel
- [~] `material_*` and `particle_*` shipped (see Tier 2 above); still need a dedicated `shader_*` CRUD surface for `.gdshader` editing outside of `filesystem_write_text`
- [ ] light `physics.*` and optionally `tilemap.*` / `navigation.*` if rooms become more authored

### Versioned Milestones (v1 / v2 / v3)

The benchmark isn't a single "done" switch. It's three readable gates, each composed from capabilities already tracked in this file. Climbing the ladder is the same as landing Tier 1 → 2 → 3 tools above.

#### v1 — "Ugly but playable"

Matches what the current stack can already produce (see "What The Current Stack Can Already Do" above).

- one arena, move + shoot (dash deferred to v2)
- one enemy archetype, no boss
- flat-color HUD (health + score) via `ui_build_layout` + `theme_set_stylebox_flat`
- pause overlay, death → restart loop
- no particles, no audio, no screen shake
- AI authors the whole loop end-to-end and launches it via `project_run`
- **Goal:** prove end-to-end AI authoring of a complete gameplay loop on today's tool surface.

#### v2 — "Readable and juicy"

Unlocks once Tier 2 tools land (most already shipped — `particle_*`, `material_*`, `animation_player.*`).

- dash ability with trail particle + brief `modulate` fade on the player
- three enemy archetypes, XP / currency pickups
- 10–15 upgrades presented via a draft screen (see UI pattern for "Upgrade-draft screen" above)
- hit-flash via `animation_create_simple` modulate tween; muzzle flash via `particle_apply_preset "spark_burst"`; death via `"explosion"`
- screen shake via the damage-shake animation pattern on HUD root
- sliding pause menu + hover pulse animations on buttons
- **Goal:** combat feel + meta progression loop readable enough to iterate on.

#### v3 — "Shippable slice"

Requires the remaining Tier 1 gaps (`camera.*`, `audio.*`) plus Tier 3 shipping support (`build.*`).

- `camera.*` follow + bounds + shake, replacing the v2 HUD-shake stand-in
- `audio.*` SFX for shoot / hit / dash / pickup, plus a music bed
- boss encounter OR escalating-wave survival spike
- 3–5 authored rooms (if `tilemap.*` / `navigation.*` lands) or a single polished arena with a wave system
- main menu and settings menu with volume sliders
- desktop export via `build.*` without bespoke handholding
- **Goal:** meets all four Benchmark Exit Criteria below.

**How this ladder composes with the tier list:** a Tier 1/2/3 checkbox landing is not progress on its own — v1/v2/v3 are the gates where we stop and verify the capability actually produces a shippable feel. Tools enable versions; versions validate tools.

### Asset Sourcing Strategy

"Placeholder art is acceptable" above is easy to misread as "we have an asset pipeline gap." We don't — for v1 and v2. This subsection states what the AI actually uses per version, and answers the recurring question of whether we need a dedicated texture-generation tool in this repo.

#### Per-version asset sources

- **v1 — Primitives only, no image files.**
  - UI is `ColorRect`, `Panel`, and `theme_set_stylebox_flat` — solid colors, rounded corners, no textures.
  - Gameplay uses `Sprite2D` with `PlaceholderTexture2D`, or `Polygon2D` / shape-based visuals. Colored flat-shade `StandardMaterial3D` if anything 3D sneaks in.
  - Particle colors come from the gradient presets already baked into `particle_apply_preset` — the `GradientTexture1D` is generated inside the handler, no asset file needed.
  - **The AI ships v1 without reading or writing a single `.png`.** Contributors should stop worrying about an art pipeline at this stage.

- **v2 — Procedural + built-in textures.**
  - Godot-native procedural texture resources via `resource_create`: `NoiseTexture2D` (noise backgrounds, particle sprites), `GradientTexture2D` (radial glows, health-bar fills), `PlaceholderTexture2D` (anything with a size hint).
  - Shader-based visuals for hit-flash, dash trail, and damage vignette via `material_set_shader_param` plus a `.gdshader` written through `filesystem_write_text`.
  - **Still no binary image files.** This is a recipes-only stage — the tools already exist.

- **v3 — Real art drops in.**
  - Pixel-art sprites, 9-slice UI buttons, custom fonts, SFX / music are binary files the AI cannot author directly. Three sourcing paths, priority order:
    1. **CC0 asset packs** (Kenney, itch.io). AI suggests a pack, user drops the folder into `res://assets/`, AI calls `filesystem_reimport` and wires references. No new tooling in this repo.
    2. **External image-gen MCP server** composed alongside `godot-ai`. Any image-gen MCP with a file-write tool can produce a PNG on disk inside the project, then `filesystem_reimport` picks it up. No new tooling in this repo.
    3. **SVG icon set** via `theme_set_icon` (tracked above, pending). SVG is text, so `filesystem_write_text` can author simple geometric icons directly.

#### Do we need a separate `texture_*` / image-gen tool here?

**Default answer: no.** The reasoning:

- **Image generation is out of scope for an editor-integration server.** Bundling model-calling logic into `godot-ai` drags in API keys, credit accounting, and model-vendor choice. The `filesystem_reimport` tool already exists so an external image-gen MCP can drop a PNG on disk and have Godot pick it up.
- **"Texture adjust" is a shader concern, not an asset concern.** `CanvasItemMaterial` / `ShaderMaterial` / `modulate` / `self_modulate` are all reachable today.
- **Weak case for one helper — `resource_create_procedural_texture`:** a thin wrapper that creates `NoiseTexture2D` / `GradientTexture2D` / `PlaceholderTexture2D` with sensible defaults and saves to a `res://` path. These are the three most common v2 needs and today require multi-step `resource_create` + property-set sequences. Deferred — build it only if a real v2 attempt shows the multi-step version is painful.
- **Revisit trigger:** if v3 sourcing via external image-gen MCP proves unreliable in practice (latency, quality, auth friction), revisit whether a bundled `texture_gen` tool belongs here. Don't speculatively build it.

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
