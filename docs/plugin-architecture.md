# Godot AI — Plugin Architecture

*Updated 2026-05-08 (document self-update runner/update-manager/plugin boundary and compatibility rules; previous: add `PreserveGodotCommandErrorData` to the middleware list and note registration-order is load-bearing; refresh file-structure tree, server-side modules, session metadata, and handshake JSON to match shipped code; add `<domain>_manage` rollups + resources + middleware to server responsibilities)*

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
                                       WebSocket (default :9500,
                                       overridable via the
                                       godot_ai/ws_port EditorSetting
                                       under Editor Settings > Plugins)
                                                 ↓
                                       Godot EditorPlugin
```

Internal companion: `godot_ai/managed_server_ws_port` is an EditorSetting the plugin uses to remember the managed server's resolved port across editor restarts and adoption — not a user knob.

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
- middleware that smooths over client quirks and shapes error responses: `PreserveGodotCommandErrorData` (outermost — packages `GodotCommandError` with structured `error.data` so candidate-path / suggestion payloads survive), `StripClientWrapperKwargs` (Cline's `task_progress`), `ParseStringifiedParams` (clients that auto-stringify nested params for `_manage` calls), `HintOpTypoOnManage` (innermost — rewrites Pydantic `literal_error` with a `difflib`-derived "Did you mean" hint). Order is load-bearing and locked by `tests/unit/test_server_middleware_order.py`; rationale lives in the docstring above the `mcp.add_middleware(...)` calls in `server.py`.
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
├── update_reload_runner.gd      ## self-update single-pass extract, scan, and re-enable handoff
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
├── clients/                     ## descriptor + strategy system for 19 IDE configs
│   ├── _base.gd, _registry.gd
│   ├── _json_strategy.gd, _toml_strategy.gd, _cli_strategy.gd
│   ├── _atomic_write.gd, _cli_finder.gd, _cli_exec.gd
│   ├── _path_template.gd, _manual_command.gd
│   └── claude_code.gd, claude_desktop.gd, cursor.gd, …  ## one per client
├── debugger/
│   └── mcp_debugger_plugin.gd   ## editor-side debugger-channel bridge
├── runtime/
│   ├── game_helper.gd           ## autoload that runs inside the game subprocess
│   ├── editor_logger.gd         ## Logger-backed editor diagnostics capture
│   ├── game_logger.gd           ## Logger-backed game log bridge
│   ├── validation_logger.gd     ## short-lived Logger for script-write diagnostics
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
- `src/godot_ai/runtime/direct.py` — `DirectRuntime`, the in-process runtime adapter that handlers depend on
- `src/godot_ai/handlers/` — shared sync handlers; `_readiness.py` gates writes; `_target.py` resolves nodes
- `src/godot_ai/tools/` — MCP tool wrappers per domain + `_meta_tool.py::register_manage_tool` rollup factory + `domains.py` (CI-paired with `tool_catalog.gd`)
- `src/godot_ai/resources/` — read-only `godot://...` URI handlers
- `src/godot_ai/middleware/` — `PreserveGodotCommandErrorData`, `StripClientWrapperKwargs`, `ParseStringifiedParams`, `HintOpTypoOnManage` (registration order is load-bearing — see `server.py` docstring + `tests/unit/test_server_middleware_order.py`)
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

Outer-to-inner teardown order matters (see #46). Handlers themselves are preloaded scripts without `class_name`, but they hold typed members backed by `Mcp*` utility classes that *do* carry `class_name` (e.g. `McpGameLogBuffer._storage : Array[Dictionary]`). When Godot reloads those `class_name`-bearing scripts during plugin disable/enable, any Callable still pinning a handler past that moment will hit a stale class descriptor on its first post-reload call and SIGSEGV. The shipped order avoids that:

1. `_connection.teardown()` first, so `_process` stops enqueuing new commands
2. `_dispatcher.clear()` next, breaking the Callable→handler ref chain so the array-clear in step 3 actually decrefs the handler RefCounteds to zero
3. `_handlers.clear()` runs handler destructors while their `Mcp*` utility scripts are still loaded
4. detach the dock, debugger plugin, and editor logger
5. `_stop_server()` and reset the spawn-guard so a re-enabled plugin instance can respawn

A symmetric `prepare_for_update_reload()` path runs during self-update so the new plugin version starts (or adopts) the right server.

Step 5 has one opt-in exception: with the `godot_ai/keep_server_on_exit` EditorSetting enabled (#800), spawns skip `GODOT_AI_OWNER_PID` and stage `GODOT_AI_NO_IDLE_EXIT`, so neither the owner-PID reaper nor the session-idle backstop reclaims a server that is idle between editor runs by design. `_exit_tree` routes through `teardown_for_editor_exit()`, which picks by how the *running* server was actually launched — a keep-alive flag set at spawn and persisted in the managed-server record (`managed_server_keep_alive`), never the live setting, which may have been toggled since the spawn. Flag set → `detach_server()`: the watch stops and state settles on STOPPED, but the process, record, and pid-file are left alone, so MCP clients connected over HTTP stay served and the next editor session adopts the survivor — managed adoption recovers the flag from the record, so the survivor detaches again on that session's exit. Flag clear → `stop_server()` kills as always, even with the setting enabled: the server's spawn env has the reapers armed, so detaching would just leave a record pointing at a soon-reaped PID. Net effect: toggling the setting takes effect on the next server start (dock Restart applies it immediately). Explicit stops — dock Restart, `prepare_for_update_reload()` — always kill. Trust model: a kept server keeps listening on its localhost-only port while no editor is attached — the same binding and handshake rules as during a session (tokenless handshakes remain accepted for adoption, #690/#798), so enabling this setting means accepting that any local process can reach the MCP surface between editor runs, not just during them.

### Self-update Boundary And Compatibility

The update path is intentionally split so the runner can stay focused on the fragile editor reload window:

- `utils/update_manager.gd` owns pre-runner work: release lookup, download, staging, version checks, and install gating. Its `class_name McpUpdateManager` declaration is published API surface and must remain unless replaced by a same-path compatibility shim.
- `plugin.gd::prepare_for_update_reload()` owns pre-runner server stop prep. It stops the managed server and resets the spawn guard before the runner starts. Do not move this server lifecycle prep into the runner.
- `plugin.gd::install_downloaded_update(...)` is the handoff point. It calls `prepare_for_update_reload()`, detaches the dock so it survives plugin teardown, creates the runner, parents it to the editor root, and calls `runner.start(...)`.
- `update_reload_runner.gd` owns the install-and-reload sequence from that handoff onward: extract files into `addons/godot_ai/`, keep rollback bookkeeping, scan the filesystem, re-enable the plugin, clean up update temp state, and free itself.

The runner's key safety property is a consistent snapshot before scan. It writes all staged new and existing files for v(N+1) in one install pass, then runs one `EditorFileSystem.scan()` before enabling the plugin. This avoids Godot parsing a mixed old/new plugin snapshot and reusing stale Script-object content.

Compatibility rules that follow from that model:

- Never delete a `class_name` declaration that has shipped in a release. Dropping a registered global class can produce a "Could not resolve script" cascade during the disable -> extract -> enable window, independent of the single-pass runner fix.
- If a published `class_name` has to retire, keep the original file path and declaration as a shape-aware shim. Static constants and static methods need explicit forwarding or redeclaration; simple `extends` is only enough for compatible instance-surface cases.
- Until old two-phase runners have aged out, release ZIPs should avoid adding new files that reference constants, methods, or static/non-static shape changes added to existing load-surface scripts in the same release. This applies to both `class_name` scripts and preload-only scripts because the failure mode is stale Script-object content, not only class registry skew.

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

#### Readiness gating — implementation contract

Write operations check session readiness (`ready`/`importing`/`playing`/`no_scene`) before executing. Plugin sends readiness in handshake and via `readiness_changed` events. Python `await require_writable_async()` in `handlers/_readiness.py` gates all write handlers; new write handlers must `await` it. Two layers self-heal a stale cache so a missed `readiness_changed` event can't strand an agent in `EDITOR_NOT_READY` against a writable editor: (1) every command response carries an envelope-level `readiness` field stamped by the plugin's dispatcher, piped through `sync_readiness_for_session` in the WebSocket transport — so the very next tool call after any state change refreshes the cache; (2) `require_writable_async` itself fires one `get_editor_state` probe before rejecting on a non-writable cached value, so the FIRST post-staleness call (which has no prior response to self-heal from) also recovers. Fast path (cache says writable) skips the probe — zero added latency in the common case. Any new plugin response builder (success, error, deferred reply, backpressure error) must include the envelope field; old plugins that omit it fall back to the event-driven path. Every `EDITOR_NOT_READY` emission carries `data.sub_code` naming the concrete editor state (`EDITOR_IMPORTING`, `EDITOR_PLAYING`, `EDITOR_NO_SCENE`, …) plus `retryable`/`hint` (#651 stage 1) — the top-level code is frozen (dashboards key on it), so never promote a sub-code to `error.code`. When the probe live-confirms `importing`, the gate holds the write and re-probes (~500ms interval, ~8s cap — telemetry-tuned constants in `_readiness.py`) instead of rejecting, since most import windows clear within seconds; past the cap it raises exactly the pre-hold error (#651 stage 2). The hold is importing-only — `playing` and every other blocking state stay fail-fast, and per-tool retry loops must not be added on top. GDScript emitters use `ErrorCodes.make_not_ready`; the sub-code vocabulary lives in `utils/error_codes.gd` (`SUB_*`) and `protocol/errors.py` (`EditorNotReadySubCode`), kept in sync by `tests/unit/test_editor_not_ready_hint_contract.py`. Only add a sub-code for a state the editor can report deterministically; undetectable busy states stay bare `EDITOR_NOT_READY`.

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

#### Deferred responses (tools whose reply flows out-of-band)

The dispatcher runs handlers synchronously and auto-sends one response per command. For work whose reply arrives over a different channel or spans frames — the game-bus tools (`editor_screenshot(source="game")`, `game_eval`, `game_command`) plus multi-frame editor work in the scene, script, filesystem, and project handlers — use the deferred pattern:

- Return `McpDispatcher.DEFERRED_RESPONSE` (a `{"_deferred": true}` sentinel dict). `tick()` skips auto-sending for these. `_call_handler` recognises it alongside `data` / `error` so the sentinel doesn't trip the malformed-result guard.
- Read the incoming request id from `params["_request_id"]`. The dispatcher injects it on a **duplicated** params dict so the original queued command isn't mutated. Hand it off to whatever async source will produce the reply.
- When the reply arrives, call `McpConnection.send_deferred_response(request_id, payload)`. `payload` must carry `data` or `error` in the same shape handlers normally return. The method attaches `request_id`, infers `status`, and pushes the JSON over the WebSocket.

This is the only pattern in the plugin that decouples response from handler-return. Reach for it only when the work can't fit in a frame and the reply genuinely has to flow back later (IPC, remote-debugger queries, multi-frame renders). Everything else should stay synchronous.

---

## Undo Contract

Every undoable scene mutation should use `EditorUndoRedoManager`.

The contract is:

- scene-tree mutations are undoable unless there is a strong reason otherwise
- file writes are not editor-undoable and should say so explicitly
- tool responses should make undoability obvious

This is part of product trust, not just implementation detail.

### Auto-create missing dependencies in the same undo action

When a write tool needs a sub-resource that may not exist yet (e.g. `animation_create` needs an `AnimationLibrary` on the AnimationPlayer; `particle_set_process` needs a `ParticleProcessMaterial` on the GPU emitter; `material_assign` with `create_if_missing=true` needs a `Material` on the mesh), do **not** error or do a separate setup write. Bundle the dependency creation into the same `create_action` so a single Ctrl-Z rolls back both:

```gdscript
var library = player.get_animation_library("") if player.has_animation_library("") else null
var created = library == null
if created:
    library = AnimationLibrary.new()

_undo_redo.create_action("MCP: Create animation foo")
if created:
    _undo_redo.add_do_method(player, "add_animation_library", "", library)
    _undo_redo.add_undo_method(player, "remove_animation_library", "")
    _undo_redo.add_do_reference(library)  # keep alive across undo→redo
_undo_redo.add_do_method(library, "add_animation", "foo", anim)
_undo_redo.add_undo_method(library, "remove_animation", "foo")
_undo_redo.add_do_reference(anim)
_undo_redo.commit_action()
```

Surface a `<dependency>_created: bool` field in the response so callers (and tests) can confirm the auto-creation actually happened. See `animation_handler.gd:create_animation`, `material_handler.gd:assign_material` (auto-creates a default material when `create_if_missing=true`), and `particle_handler.gd:create_particle` / `set_process` / `set_draw_pass_gpu_3d` for worked examples. The draw-pass handler also grows `draw_passes` when the target `draw_pass_N` slot doesn't exist yet — Godot only exposes `draw_pass_N` as a live property once the count is ≥ N, and naive `add_do_property` on a ghost slot silently no-ops.
### Value coercion: assert on the stored Variant, not on counts

JSON dicts like `{"r":1,"g":0,"b":0,"a":1}` only become `Color` / `Vector2` / `Vector3` if the coercer finds a matching property on the target node and that property's `TYPE_*` is in the coerce table. If the property is missing (wrong scene root type) or the type isn't handled, the raw dict is silently stored as the keyframe value and Godot plays garbage at runtime.

GDScript tests that just assert `track_count == 1` will pass even when coercion is broken. **Always read back via `track_get_key_value(idx, k)` and assert `value is Color` / `value is Vector3` / etc.** `test_animation.gd` `test_add_property_track_coerces_vector3_dict` is the reference pattern. The same rule applies to any future handler that takes JSON values intended to land as typed Variants in the scene.

Same principle for theme override pseudo-properties on Controls: assert `has_theme_color_override` (or constant/font-size/stylebox variant) before reading the value back with the regular getter — Godot 4.6 removed `get_theme_*_override`, and the presence check is what stops a broken override from silently resolving via the theme fallback. `test_ui.gd` `test_build_layout_theme_override_*` are the reference pattern.
### Auto-generated indices: look up at undo time, not do time

When a write tool mutates a resource whose index is assigned by Godot (`Animation.add_track` returns an int index, same for track keys, `MultiMesh.instance_count`, etc.), do **not** capture that index at do time and reuse it in the undo callable. Any other mutation landing between the do and the undo makes the index stale — the undo will then remove the wrong element (or error).

Instead, undo via a helper that resolves the index at undo time via a stable lookup:

```gdscript
_undo_redo.add_undo_method(self, "_undo_remove_track_by_path", anim, track_path, Animation.TYPE_VALUE)

func _undo_remove_track_by_path(anim: Animation, path: String, type: int) -> void:
    var idx := anim.find_track(NodePath(path), type)
    if idx >= 0:
        anim.remove_track(idx)
```

See `animation_handler.gd::_undo_remove_track_by_path` for the reference pattern. Cover with a test that interleaves a second mutation between the do and undo of the first (`test_animation.gd::test_add_property_track_undo_survives_interleaving`).
### Scene instancing: use GEN_EDIT_STATE_INSTANCE

When a tool instantiates a PackedScene into the edited scene, pass `PackedScene.GEN_EDIT_STATE_INSTANCE` to `instantiate()`:

```gdscript
new_node = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
```

This makes Godot treat the result as a real scene instance: the root shows the foldout icon, the `.tscn` stores a reference to the sub-scene rather than an exploded subtree, and the instance can be swapped or toggled editable via the usual editor UI. Don't manually set descendant owners to your scene_root — descendants of a scene instance stay owned by their sub-scene; overriding that breaks the instance link. See `node_handler.gd::create_node`.

---

## Security Model

The security posture should stay explicit:

- localhost-first by default
- project trust is explicit, not implied
- dangerous or privileged operations are clearly marked
- editor-side arbitrary code execution remains gated and exceptional
- mutation and execution paths are auditable enough to debug what happened

This should be visible in both the protocol and the user-facing docs.

### WebSocket trust boundary — the concrete contract

The editor↔server WebSocket (port 9500) is **effectively unauthenticated** — the primary control is loopback-only binding: the WS port always binds `127.0.0.1` and `--allow-host` deliberately does NOT widen it (see `transport/websocket.py::start`). Defense in depth on top of that: unguessable `uuid4` request ids, session-scoped response correlation (a reply is only accepted from the connection its command was sent to — #690), and a compat-gated per-launch handshake token (#690 finding 4): the spawning plugin generates it, hands it to the server via the `GODOT_AI_WS_TOKEN` spawn env, and echoes it in the handshake; a handshake carrying a *wrong* token is rejected, but a token-less handshake is still accepted (older plugins, adopted servers, and the field is attacker-omittable — so the token is hardening, not an authentication boundary). Never bind the WS port beyond loopback. **The token authenticates the plugin TO the server, and nothing authenticates the server to the plugin**: `connection.gd` dials `ws://127.0.0.1:<ws_port>` and hands whatever answers the full write surface (`filesystem_write_text`, `script_create`, `game_eval`, `editor_quit`), adoption of an existing `:8000` listener is decided by a *self-reported* status JSON, and `_note_post_open_close` drops the token entirely after two close-4003 frames (an attacker-triggerable downgrade, deliberately accepted because omitting the field is always allowed anyway). Loopback binding is the whole boundary on the plugin side — do not add plugin-side logic that assumes the peer on 9500 is trusted.

---

## WebSocket Protocol Summary

### Handshake

Plugin to server (initial handshake — exact field set, see [`connection.gd::_send_handshake`](../plugin/addons/godot_ai/connection.gd)):

```json
{
  "type": "handshake",
  "session_id": "godot-ai@a3f2",
  "godot_version": "4.6.0",
  "project_path": "/path/to/project",
  "plugin_version": "2.2.3",
  "protocol_version": 1,
  "readiness": "ready",
  "editor_pid": 12345,
  "server_launch_mode": "managed"
}
```

Server-derived fields:

- `name` — derived by the server from `project_path` (the project directory basename); not sent on the wire.
- `server_version` — sent back to the plugin in a `handshake_ack` reply, not in the handshake itself.

Subsequent runtime state (current scene, play state, readiness transitions) flows as separate `{"type": "event", "event": <name>, "data": …}` messages — `scene_changed`, `readiness_changed`, etc. — not as part of the initial handshake.

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
