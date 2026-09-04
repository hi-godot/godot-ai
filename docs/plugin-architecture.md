# Godot AI — Plugin Architecture

*Updated 2026-08-31 for the v4 ownership, authenticated transport, and
transactional-update architecture.*

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
AI Client -> stdio -> godot-ai attach
                         |
                         v
             authenticated MCP HTTP
                         |
                         v
                Python FastMCP server
                         |
                         v
          authenticated WebSocket (:9500)
                         |
                         v
                Godot EditorPlugin
```

The HTTP and WebSocket capabilities are independent, per-backend secrets. A
private capability record bootstraps local attach bridges and editor adoption;
secrets never appear in public session or Dock snapshots.

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
- the rolled-up tool surface — 46 tools comprising 19 named tools and 27 per-domain `<domain>_manage` rollups wired by `tools/_meta_tool.py::register_manage_tool`, which builds a dynamic `Literal[...]` op enum so schema-aware clients see every op
- read-only `godot://...` MCP resources (sessions, editor state, scenes, nodes, scripts, project, materials, performance, test results) that mirror the cheap reads and don't count against tool-cap budgets
- per-call session routing — every Godot-talking tool accepts an optional `session_id`, bound at the `DirectRuntime` boundary so `require_writable` and downstream handlers see the pinned session, not the active one
- middleware that smooths over client quirks and shapes error responses: `PreserveGodotCommandErrorData` (outermost), `StripClientWrapperKwargs`, `ParseStringifiedParams`, `FoldFlatManageParams`, and `HintOpTypoOnManage`, followed by observational `TrackMcpSessions`. The first five positions are load-bearing; the tracker never reshapes requests or responses. The full inventory is locked by `tests/unit/test_server_middleware_order.py`, with rationale above registration in `server.py`.
- session registry and active-session resolution, with `<project-slug>@<16hex>` IDs and substring/path matching in `session_activate`
- request validation and structured error mapping (`protocol/errors.py`)
- job tracking for long-running operations and the deferred-response pattern for replies that flow back over a different channel (game capture)
- the `--exclude-domains` CLI flag and dock UI knob, so tool-capped clients (Antigravity, etc.) can drop entire domains at server start while keeping the four core tools alive
- CLI entry points for diagnostics and packaging (`python -m godot_ai`, the dev `--reload` runner via `src/godot_ai/asgi.py`)

The plugin keeps editor-local ownership explicit: lifecycle, client mutation,
and disable/enable coordination remain in Godot, while signed filesystem
transactions and network-serving behavior live in Python. Policy boundaries
should be described honestly rather than calling a large owner a thin facade.

---

## Plugin File Structure

```text
plugin/addons/godot_ai/
├── plugin.cfg
├── plugin.gd                    ## EditorPlugin lifecycle, handler registration
├── connection.gd                ## WebSocket client + send_deferred_response
├── dispatcher.gd                ## command routing, frame budget, DEFERRED_RESPONSE sentinel
├── mcp_dock.gd                  ## editor dock: status, clients, logs, self-update banner, Tools tab
├── client_configurator.gd       ## client policy, mutation dispatch, verification, launch discovery
├── tool_catalog.gd              ## mirrors src/godot_ai/tools/domains.py; CI-enforced
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
├── clients/                     ## descriptor + strategy system for 23 IDE configs
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
    ├── client_job_owner.gd      ## plugin-lifetime client worker owner
    ├── server_lifecycle.gd      ## one serialized lifecycle episode
    ├── server_authority.gd      ## transport/process/replacement grants
    ├── transport_capability.gd  ## private record validation and status auth
    ├── update_manager.gd        ## signed v4 discovery/download owner; embeds the release public key
    ├── release_verifier.gd      ## McpReleaseVerifier: pure manifest/signature/archive/inventory checks
    ├── update_installer.gd      ## stage, lock, two-rename swap, restart, post-restart verify
    ├── client_mutation_lock.gd  ## durable account-wide mutation authority
    ├── uv_resolution_policy.gd  ## one production uvx resolver policy
    ├── port_resolver.gd         ## process identity and port helpers
    ├── windows_port_reservation.gd  ## avoids Windows-reserved ephemeral ports
    └── uv_cache_cleanup.gd      ## prunes stale uvx cache before self-update
```

The server-side counterparts live in:

- `src/godot_ai/server.py` — FastMCP entry point, lifespan, tool/resource registration, `--exclude-domains`
- `src/godot_ai/asgi.py` — uvicorn factory for `--reload`; ships `StaleMcpSessionDiagnosticMiddleware`
- `src/godot_ai/transport/websocket.py` — WebSocket server adopting/owning the :9500 socket
- `src/godot_ai/transport/security.py` and `transport/capability.py` — bounded authenticated HTTP and private bootstrap records
- `src/godot_ai/sessions/registry.py` — one authoritative editor/peer/pending-request table with immutable public snapshots
- `src/godot_ai/release_verify.py` — standalone signed-release verification behind `script/v4-release` (development dependency; the server imports nothing from it at runtime)
- `src/godot_ai/godot_client/client.py` — typed async client; raises `GodotCommandError`
- `src/godot_ai/runtime/direct.py` — `DirectRuntime`, the in-process runtime adapter that handlers depend on
- `src/godot_ai/handlers/` — shared sync handlers; `_readiness.py` gates writes; `_target.py` resolves nodes
- `src/godot_ai/tools/` — MCP tool wrappers per domain + `_meta_tool.py::register_manage_tool` rollup factory + `domains.py` (CI-paired with `tool_catalog.gd`)
- `src/godot_ai/resources/` — read-only `godot://...` URI handlers
- `src/godot_ai/middleware/` — `PreserveGodotCommandErrorData`, `StripClientWrapperKwargs`, `ParseStringifiedParams`, `FoldFlatManageParams`, `HintOpTypoOnManage`, and observational `TrackMcpSessions` (see the registration rationale and complete-inventory lock)
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

- reject unsupported Godot versions before constructing the lifecycle
- if `addons/.godot_ai_update/pending.json` exists, hash the live tree against
  the marker's expected tree hash and record `success`, `rolled_back`, or
  `repair_required` before normal composition ([self-update.md](self-update.md))
- construct plugin-lifetime owners (`McpServerLifecycleManager`,
  `McpClientJobOwner`, and `McpUpdateManager`) with inert constructors
- construct the connection/dispatcher/debugger/log composition and lazy
  handler registrations
- attach the replaceable Dock as a view over copied owner snapshots
- on `repair_required`, keep that composition inert and show the exact paths;
  otherwise activate client work, lifecycle, transport, telemetry, and update
  discovery only after the complete composition exists, the post-restart tree
  verification has finished, and the pin-only client repin has run

### `_process(delta)`

- poll the WebSocket transport
- drain queued commands within the frame budget
- emit responses
- watch scene/play/readiness changes
- update the dock and log buffer

### `_exit_tree()`

Outer-to-inner teardown order matters (see #46). Client work first stops
accepting requests and realizes every worker thread. The connection stops
enqueueing commands before `Dispatcher.clear()` drops its lazy handler
instances and their Callables. The Dock, update manager, client owner,
connection, debugger plugin, and logger are then detached in that order while
their script types are still valid. Finally, the lifecycle either stops the
exact process named by its owned-process grant or detaches from an external,
keep-alive, or actively leased backend.

The Dock owns no client worker, update transaction, lifecycle episode, or
process authority. Replacing the Dock therefore cannot abandon background
work.

Client-owned `godot-ai attach` bridges add a second bounded-lifetime path. Each
stdio bridge probes the configured loopback endpoint, adopts a compatible
backend or starts an attach-owned one, and maintains an instance-bound lease.
Godot adopts attach-owned backends as external and has no authority to kill
them. If a plugin-owned backend has an active attach lease during normal editor
exit, teardown transfers it to detached lifetime instead of killing it; a later
editor reconnects to the same instance. Once there are no editor sessions and
the final bridge lease is released or expires, the Python idle reaper stops the
backend after its grace period. Explicit restart and update flows may still
replace a verified owned backend. The lease is lifecycle evidence, not
kill authority; lease calls are nevertheless authenticated by the same private
HTTP capability as the rest of the server.

### Self-update

The updater is one in-editor path, specified in
[self-update.md](self-update.md). `utils/update_manager.gd` discovers a newer
`4.x` release exposing the exact six-name asset set and downloads only the
canonical triple. `utils/release_verifier.gd` (`McpReleaseVerifier`, pure and
unit-testable) checks the manifest signature against the embedded
`RELEASE_SIGNING_PUBLIC_KEY_PEM`, the release identity, the archive hash, and
every inventory entry. `utils/update_installer.gd` stages the verified tree
under `res://addons/.godot_ai_update/stage/`, waits for the dispatcher to
drain and runs `prepare_for_update_reload()`, takes `lock.json`, renames the
live tree to `backup/<old version>/` and the stage into place, writes
`pending.json`, persists the enabled entry without loading the new tree in the
old process, and restarts the editor. The new process hashes the live tree
against the marker before normal composition and records `success`,
`rolled_back` (the live tree goes to `quarantine/`, the backup is restored) or
`repair_required` (no backup to restore; the plugin stays inactive). The final
v3 line crosses once through a signed capsule whose bridge runs the same
installer; see [v4-migration.md](v4-migration.md).

No separate process, `uvx` invocation, journal, or lease is involved; `uvx`
runs the server, not the plugin. The live tree is only ever the old exact tree
or the new exact tree — the two renames are the whole swap — and nothing under
`addons/.godot_ai_update/` is deleted on a failure path.

Within v4, published `class_name` APIs remain explicit compatibility surface.
Do not keep private v3 shims or legacy wire/update branches merely to make the
new updater accept an old architecture.

---

## Session And Readiness Model

The session model exists so the server can distinguish live editor instances and refuse writes when the editor is in an unsafe state.

`SessionRegistry` has one `_entries` table. Each row owns its pending/active
phase, immutable `Session` snapshot, exact WebSocket peer, and pending response
futures. The ACK transition publishes a reserved row; disconnect removes that
same peer's row and fails its work. Public callers receive immutable snapshots
rather than mutable registry records, and no parallel session/peer/future map
can drift out of sync.

### Session Metadata

- session id, formatted `<project-slug>@<16hex>` (for example, `godot-ai@7f9c3a10d8e426b1`) — the slug identifies the project while the cryptographic 64-bit suffix disambiguates same-project editors
- name (project basename)
- Godot version, plugin version, server version
- project path
- editor PID
- current scene, play state, readiness state
- last_seen heartbeat, used by `session_list` and stale-session diagnostics
- server launch tier (`dev_venv`, `uvx`, `system`, or `unknown`) reported via
  `session_list`; managed/adopted ownership is a separate lifecycle fact

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
on Windows, Linux, and supported macOS versions just reparents the game's window into
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

The editor WebSocket always binds `127.0.0.1`; `--allow-host` never widens it.
Loopback is only the first layer. Every v4 backend also has an independent
32-byte WebSocket capability, published through the private per-port bootstrap
record.

The handshake is mutual. The editor sends only a random nonce, verifies a
server HMAC over the protocol/nonces/server version, and discloses project and
session metadata only after that proof succeeds. The editor then HMAC-binds all
metadata into its response. The server reserves the session ID, sends the final
ACK, and publishes the peer only after that send succeeds. Missing/wrong
capabilities, duplicate JSON keys, replayed nonces, protocol-1/v3 frames, and
Godot versions below 4.7 fail closed. There is no tokenless retry or downgrade.

Before authentication, frames and parser queues stay under small handshake
limits; authenticated peers receive the normal bounded command budget. Response
settlement is bound to the peer and request reservation that originated the
command, so an unsolicited or replacement peer cannot mutate a session snapshot
with a guessed request ID.

HTTP is separately bearer-authenticated and bounded. Status/lease routes do not
form an unauthenticated side channel. Private capability records are owner-only
on POSIX; caller-selected roots reject link traversal and unsafe ancestors. On
Windows, v4 uses fixed per-user roots and rejects detectable reparse traversal,
but does not claim secrecy or integrity against another local account or
malicious code already running as the same user.

---

## WebSocket Protocol Summary

### Handshake

Plugin to server (metadata-free hello):

```json
{
  "type": "auth_hello",
  "protocol_version": 2,
  "client_nonce": "<64 lowercase hex characters>"
}
```

Server to plugin (challenge):

```json
{
  "type": "auth_challenge",
  "protocol_version": 2,
  "client_nonce": "<same client nonce>",
  "server_nonce": "<64 lowercase hex characters>",
  "server_version": "4.0.0",
  "server_proof": "<transcript HMAC>"
}
```

Only after verifying `server_proof`, the plugin returns `auth_response` with
both nonces, `client_proof`, and the bounded metadata fields:

```json
{
  "type": "auth_response",
  "protocol_version": 2,
  "client_nonce": "<same client nonce>",
  "server_nonce": "<same server nonce>",
  "client_proof": "<metadata-bound transcript HMAC>",
  "session_id": "godot-ai@7f9c3a10d8e426b1",
  "godot_version": "4.7.stable.official",
  "project_path": "/path/to/project",
  "plugin_version": "4.0.0",
  "readiness": "ready",
  "editor_pid": 12345,
  "server_launch_mode": "managed"
}
```

The server replies with `handshake_ack` containing protocol and server version.
It derives `name` from the project path rather than accepting a peer-supplied
display name.

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
  "data": {},
  "readiness": "ready"
}
```

### Error Response

Plugin to server:

```json
{
  "request_id": "uuid",
  "status": "error",
  "readiness": "ready",
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

## Custom Tools (Third-Party Addons)

Other Godot addons can register their own MCP tools with the `custom_tools/`
registry. The design keeps every trust decision in the editor process and
every advertisement decision in the user's hands.

### Registering

```gdscript
var spec := McpCustomToolSpec.new()
spec.name = "gdunit_run"                       # ascii identifier, unique
spec.description = "Run the GdUnit4 suite"     # agent-facing, ≤600 chars
spec.params_schema = {"type": "object", ...}   # JSON Schema, ≤8 KB UTF-8
spec.script_path = "res://addons/my_addon/mcp_handler.gd"
spec.method = &"run_suite"                     # func(params: Dictionary, ctx: McpCallContext) -> Dictionary
spec.source_path = "res://addons/my_addon/plugin.cfg"
McpToolRegistry.get_instance().register(spec)  # or batch_register([...]) — atomic
```

Handlers are materialized lazily from `script_path` (hot-reload safe, #229);
`source_path` is a cooperative collision/ownership policy, NOT a security
boundary — same path replaces (hot reload), different path colliding on a
name is rejected. `spec.validate()` enforces the budgets at register time.

### The call context — stable surface

`McpCallContext` hands handlers `request_id`, `session_id`, `deadline_msec`,
`spec`, `is_expired()`, and `send_deferred(payload)` (for `deferred = true`
specs). Underscore-prefixed members are internal wiring — published
`class_name`s are permanent compat surface, so the addon-facing API is kept
deliberately narrow. Params arrive UNVALIDATED: `params_schema` is
advertised to agents, but the handler owns its own input validation.

### Exposure: custom_manage vs promoted

Every enabled tool is reachable through `custom_manage(op="list"/"invoke")`
and the `godot://custom-tools` resource ("active session only" — list and
invoke always resolve the same editor). A spec with `promoted = true` opts
into ALSO being registered as a first-class MCP tool named
`custom_<name>`, advertising the addon's `params_schema` verbatim so MCP
clients validate params natively. Promotion is capped server-side
(`MAX_PROMOTED_TOOLS` in `services/promoted_tools.py`) to protect the
repo's tool budget; overflow stays behind `custom_manage`, and the sync
follows every catalog change live via `tools/list_changed`.

### User control (dock)

The dock's Tools tab lists every registered custom tool with its source
addon and a per-tool checkbox. Toggles apply immediately: a disabled tool
is dropped from the catalog push (never advertised), rejected at dispatch
with `CUSTOM_TOOL_DISABLED` (covers stale client lists and
`batch_execute`), and its promotion is withdrawn. The choice persists
per-project via `EditorSettings` project metadata — deliberately not
machine-global, and not `project.godot` churn.

### Execution contract

`requires_writable` gates play/import on BOTH sides (plugin wrapper and
server handler). `deferred = true` tools must reply via
`ctx.send_deferred` within `timeout_ms` (500..120000 ms, honored by the
server-side future too); a handler that defers without declaring it is an
error, and deferred tools are rejected from `batch_execute` (their reply
would outlive the batch response). Only `undoable = true` tools may join
`batch_execute(undo=true)`.
