# Godot MCP Studio — Implementation Plan

*Generated 2026-04-11*

This is the actionable implementation plan for building Godot MCP Studio. It assumes a solo developer + Claude Code as AI pair, new to Godot (strong Unity background), targeting Godot 4.4+, with distribution via PyInstaller binary.

---

## 1. Project Setup

### 1.1 GitHub org and repo

1. Create a new GitHub org (or use an existing one).
2. Create repo: `godot-mcp-studio` (public, no template).
3. Add `.gitignore` combining Python and Godot ignores.
4. Add a placeholder `LICENSE` (decide later — MIT or Apache-2.0 are the safe defaults for open-source dev tools).
5. Add a minimal `README.md` with project name, one-liner, and "under construction" notice.

### 1.2 Python project scaffolding

```text
godot-mcp-studio/
├── pyproject.toml          # uv/pip, Python 3.11+, fastmcp dependency
├── src/
│   └── godot_mcp_studio/
│       ├── __init__.py
│       ├── server.py        # FastMCP server entrypoint
│       ├── protocol/
│       │   ├── __init__.py
│       │   ├── envelope.py  # request/response envelope types
│       │   └── errors.py    # structured error codes
│       ├── transport/
│       │   ├── __init__.py
│       │   └── websocket.py # WebSocket server for Godot plugin
│       ├── sessions/
│       │   ├── __init__.py
│       │   └── registry.py  # session tracking + routing
│       ├── godot_client/
│       │   ├── __init__.py
│       │   └── client.py    # typed async client for plugin commands
│       ├── tools/
│       │   ├── __init__.py
│       │   └── session.py   # first tool module
│       └── resources/
│           ├── __init__.py
│           └── sessions.py  # first resource module
├── tests/
│   ├── __init__.py
│   ├── unit/
│   └── integration/
├── plugin/                  # Godot editor plugin (separate from Python)
│   └── addons/godot_mcp_studio/
│       ├── plugin.cfg
│       ├── plugin.gd
│       ├── connection.gd
│       └── handlers/
└── docs/
```

### 1.3 Godot test project

Create a minimal Godot 4.4 project at `test_project/` in the repo root:

- One scene with a few nodes (Node3D, MeshInstance3D, Camera3D, DirectionalLight3D).
- The plugin symlinked or copied into `test_project/addons/`.
- This project is used for manual testing and later for e2e CI.

### 1.4 Dev environment

- Python 3.11+ with `uv` for dependency management
- `pytest` + `pytest-asyncio` for tests
- `ruff` for linting/formatting
- Godot 4.4 stable installed
- Claude Code as AI pair for implementation

---

## 2. This Weekend: Phase 0 Sprint Plan

The goal is to prove the full vertical: AI client → MCP server → WebSocket → Godot plugin → editor API → response back. Two parallel tracks that meet in the middle.

### Track A: Python server skeleton (Saturday morning, ~3-4 hours)

**Hour 1: Project bootstrap**
- `uv init` the Python project with `pyproject.toml`
- Add dependencies: `fastmcp`, `websockets`, `pydantic`
- Create the package structure under `src/godot_mcp_studio/`
- Write `server.py` — bare FastMCP server that starts and accepts MCP connections
- Verify: `python -m godot_mcp_studio` starts and responds to MCP inspector

**Hour 2: Protocol envelope + WebSocket transport**
- Define `protocol/envelope.py`: `CommandRequest` and `CommandResponse` Pydantic models
  - `request_id: str` (UUID)
  - `command: str` (e.g., `"get_scene_tree"`)
  - `params: dict`
  - Response: `request_id`, `status`, `data`, `error`
- Write `transport/websocket.py`: async WebSocket server (default port 9500)
  - Accept connections from Godot plugin
  - Parse incoming messages as `CommandResponse`
  - Send outgoing `CommandRequest` messages
- Verify: WebSocket server starts, accepts a test connection from `websocat` or a Python test client

**Hour 3: Session registry + mock tool**
- Write `sessions/registry.py`:
  - `register_session(session_id, ws_connection, metadata)`
  - `get_session(session_id) -> Session`
  - `list_sessions() -> list[Session]`
  - Session metadata: `session_id`, `godot_version`, `project_path`, `plugin_version`
- Write `godot_client/client.py`:
  - `send_command(session_id, command, params) -> response`
  - Correlates `request_id` to pending futures
  - Timeout handling (5s default)
- Write first tool: `tools/session.py` — `session.list` that returns registered sessions
- Write first resource: `resources/sessions.py` — `godot://sessions`
- Verify: `session.list` returns empty list; registering a mock session makes it appear

**Hour 4: Integration test with mock**
- Write `tests/unit/test_session_registry.py`
- Write `tests/unit/test_protocol.py` (envelope serialization roundtrip)
- Write `tests/integration/test_mock_session.py` — mock WebSocket client that pretends to be a Godot plugin, registers, receives a command, sends a response
- All tests green

### Track B: Godot plugin spike (Saturday afternoon, ~3-4 hours)

**Hour 5: Plugin bootstrap**
- Create `plugin/addons/godot_mcp_studio/plugin.cfg`:
  ```ini
  [plugin]
  name="Godot MCP Studio"
  description="MCP server bridge for AI-assisted Godot development"
  author="Godot MCP Studio"
  version="0.0.1"
  script="plugin.gd"
  ```
- Create `plugin.gd` extending `EditorPlugin`:
  - `_enter_tree()`: print "Godot MCP Studio loaded", start connection
  - `_exit_tree()`: disconnect, cleanup
- Copy plugin into `test_project/addons/`, enable it in Project Settings
- Verify: plugin loads, prints message in Godot output

**Hour 6: WebSocket connection**
- Create `connection.gd`:
  - Uses `WebSocketPeer` (Godot 4.x API)
  - Connects to `ws://127.0.0.1:9500`
  - Handles `STATE_OPEN`, `STATE_CLOSING`, `STATE_CLOSED`
  - Auto-reconnect with backoff (1s, 2s, 4s, max 10s)
  - Sends handshake on connect: `{"type": "handshake", "session_id": "<generated>", "godot_version": "4.4", "project_path": "<project_path>", "plugin_version": "0.0.1"}`
- Wire `connection.gd` into `plugin.gd` — create on `_enter_tree`, poll in `_process`
- Verify: start Python server, open Godot project, see handshake arrive in Python logs

**Hour 7: Command dispatch skeleton**
- Add command receive loop to `connection.gd`:
  - Parse incoming JSON as `{request_id, command, params}`
  - Match `command` string to a handler function
  - Send response JSON: `{request_id, status, data, error}`
- Implement first handler: `get_editor_state`
  - Returns: `{godot_version, project_name, current_scene, is_playing}`
  - Uses `EditorInterface.get_edited_scene_root()`, `Engine.get_version_info()`
- Verify: Python server sends `get_editor_state` command, Godot plugin responds with real data

**Hour 8: First real scene tree read**
- Implement handler: `get_scene_tree`
  - Walks `EditorInterface.get_edited_scene_root()` recursively
  - Returns array of `{name, type, path, children_count}` per node
  - Depth limit parameter (default 10)
- Verify: scene tree data arrives in Python server from a real Godot scene

### Meet in the middle (Saturday evening or Sunday morning, ~2 hours)

**Hour 9: Wire the first MCP tool to real Godot data**
- In Python: implement `editor.state` tool that calls `get_editor_state` on the active session
- In Python: implement `scene.get_hierarchy` tool that calls `get_scene_tree`
- Test manually with MCP inspector or Claude Desktop:
  - `editor.state` → returns Godot version, project name, current scene
  - `scene.get_hierarchy` → returns real node tree from the open scene

**Hour 10: Polish and commit**
- Add proper error handling for disconnected sessions
- Add `--port` CLI flag for the WebSocket server
- Write a `CONTRIBUTING.md` stub with dev setup instructions
- Commit everything, push to GitHub
- Celebrate: you have a working MCP-to-Godot bridge

### Weekend exit criteria
- [ ] Python MCP server starts and accepts MCP client connections
- [ ] Godot plugin connects to Python server over WebSocket
- [ ] `session.list` returns the connected Godot session with metadata
- [ ] `editor.state` returns real Godot editor state
- [ ] `scene.get_hierarchy` returns real scene tree data
- [ ] At least 5 passing tests
- [ ] Code pushed to GitHub

---

## 3. Post-Sprint Hardening (before adding more tools)

The weekend sprint proved the vertical slice works. Before adding tools, fix the structural issues identified in review.

### 3.1 Refactor plugin to planned architecture — DONE

Split `connection.gd` god-object into:

```text
addons/godot_ai/
├── plugin.gd              # EditorPlugin lifecycle, wires handlers
├── connection.gd          # WebSocket only: connect, reconnect, send, receive
├── dispatcher.gd          # Command queue, frame-budget dispatch, handler routing
├── mcp_dock.gd            # Editor dock panel
├── handlers/
│   ├── editor_handler.gd  # editor_state, selection, logs, reload_plugin
│   ├── scene_handler.gd   # scene tree reading
│   ├── node_handler.gd    # node create (with undo)
│   ├── project_handler.gd # project settings, filesystem search
│   └── client_handler.gd  # client configure/status
└── utils/
    ├── scene_path.gd       # from_node(), resolve()
    ├── error_codes.gd      # shared error constants + make()
    ├── log_buffer.gd       # ring buffer for log capture
    └── client_configurator.gd  # Client config (Claude Code, Antigravity)
```

### 3.2 Make client configuration opt-in — DONE

- Removed `_auto_configure_clients()` from `_enter_tree()`
- Client config is now in the dock panel: detected status + "Configure" button per client
- MCP tools `client_configure` / `client_status` still available for AI clients

### 3.3 Add undo integration for write tools — DONE

`node_create` uses `EditorUndoRedoManager`. All future write tools must follow this pattern. Response includes `"undoable": true`.

### 3.4 Fix session state freshness — DONE

Plugin polls for scene and play state changes each frame, sends events over WebSocket. Server updates session registry on receipt. `session_list` returns live data.

### 3.5 Build the dock panel — DONE

Editor dock panel with:
- Connection status (green/red + port info)
- Reconnect + Reload Plugin buttons
- Client config (per-client status + Configure buttons)
- MCP log (scrolling RichTextLabel with toggle to hide)

### 3.6 Symlink test_project plugin — DONE

`test_project/addons/godot_ai` → `plugin/addons/godot_ai`

### 3.7 Add integration tests — DONE

- Mock WebSocket client that connects, handshakes, receives commands, sends responses
- Contract test: handshake sequence, error responses, timeout behavior
- 32 passing tests (18 unit + 14 integration)

### Hardening exit criteria
- [x] connection.gd split into connection, dispatcher, handlers
- [x] Client config is opt-in (dock button, not auto-fire)
- [x] node_create uses EditorUndoRedoManager
- [x] Session state updates on scene switch and play/stop
- [x] Dock panel shows connection status and MCP log
- [x] test_project uses symlink to plugin/
- [x] 25+ passing tests including integration

---

## 4. Phase 0 Full (Weeks 1-2)

Build on the hardened foundation.

### Week 1

**Protocol hardening:**
- Version negotiation in handshake (protocol version field)
- Structured error codes (enum: `SESSION_NOT_FOUND`, `COMMAND_TIMEOUT`, `EDITOR_NOT_READY`, `INVALID_PARAMS`, etc.)
- Request timeout with configurable default (5s)
- Message size limits

**Connection reliability:**
- Plugin auto-reconnect with exponential backoff
- Server-side heartbeat ping/pong (every 5s)
- Stale session cleanup (no heartbeat for 30s → mark disconnected)
- Graceful disconnect on plugin unload
- Scene switch notification (plugin sends event when scene changes)

**Session model:**
- Full session metadata: `session_id`, `godot_version`, `project_path`, `plugin_version`, `protocol_version`, `current_scene`, `play_state`, `capability_flags`
- Session event stream: `connected`, `disconnected`, `scene_changed`, `play_state_changed`
- Multi-session support in registry (list, route by ID)

### Week 2

**Plugin command queue architecture:**
- Implement the concurrency model from proposal Section 6.9:
  - Inbound command queue (Array-based)
  - `_process()` dispatcher with frame budget (4ms default)
  - `call_deferred()` for scene tree mutations
  - Response correlation via `request_id`
- Test with rapid-fire commands to verify no editor stalls

**Readiness system:**
- Plugin reports readiness state: `ready`, `scene_switching`, `importing`, `playing`, `error`
- Server gates write operations on readiness
- `editor.state` includes readiness in response

**Basic headless path:**
- `godot --headless --script` runner for CI scenarios
- One headless command: `get_project_info` (project name, Godot version, scene list)

**Testing:**
- Unit tests for protocol serialization, session registry, error handling
- Integration tests with mock WebSocket client
- Contract test: handshake sequence, version mismatch rejection, heartbeat

### Phase 0 exit criteria
- [ ] Plugin survives reconnects and scene switches without data loss
- [ ] Server handles multiple sessions concurrently
- [ ] Protocol has version negotiation and structured errors
- [ ] Command queue doesn't stall the Godot editor
- [ ] Readiness gating prevents writes during unsafe states
- [ ] Headless path can extract project info
- [ ] 15+ passing tests

---

## 4. Phase 0.5: Distribution (Week 2, parallel track)

### PyInstaller spike

**Goal:** A user downloads one file, runs it, and the MCP server starts. No Python required.

**Steps:**
1. Create `build/pyinstaller.spec` or use `pyinstaller` CLI:
   ```bash
   pyinstaller --onefile --name godot-mcp-studio src/godot_mcp_studio/__main__.py
   ```
2. Test on macOS first (your platform), then cross-compile or test in CI for Windows/Linux.
3. Verify the binary:
   - Starts the MCP server
   - Opens WebSocket listener
   - Accepts Godot plugin connections
   - Responds to MCP tool calls
4. Measure binary size (target: < 30MB).
5. Test startup time (target: < 3s).

**Install flow design:**
1. User downloads binary from GitHub Releases.
2. User runs binary (or adds it to their MCP client config).
3. User copies `plugin/addons/godot_mcp_studio/` into their Godot project's `addons/` folder.
4. User enables the plugin in Godot Project Settings.
5. Plugin connects to the running server automatically.

**Claude Desktop / Cursor config:**
```json
{
  "mcpServers": {
    "godot-mcp-studio": {
      "command": "/path/to/godot-mcp-studio",
      "args": []
    }
  }
}
```

**CI pipeline (later):**
- GitHub Actions workflow: build on push to `main` or tag
- Matrix: `{macos-latest, ubuntu-latest, windows-latest}`
- Upload artifacts to GitHub Releases on tag

### Phase 0.5 exit criteria
- [ ] Single binary builds on macOS
- [ ] Binary starts MCP server without Python installed
- [ ] End-to-end test: binary → Godot plugin → MCP tool call → response
- [ ] Install instructions documented

---

## 5. Phase 1: Read-First Tools (Weeks 2-4)

The product should be useful for inspection and navigation before any write tools ship.

### Tool implementation order

**Batch 1 — Session and editor — DONE:**
| Tool | Plugin handler | Notes |
|------|---------------|-------|
| `session.list` | — | Server-side only, reads registry |
| `session.activate` | — | Sets default session for subsequent calls |
| `editor.state` | `get_editor_state` | Already done in Phase 0 |
| `editor.selection.get` | `get_selection` | `EditorInterface.get_selection().get_selected_nodes()` |

**Batch 2 — Scene reads — DONE:**
| Tool | Plugin handler | Notes |
|------|---------------|-------|
| `scene.get_hierarchy` | `get_scene_tree` | Already done in Phase 0; add pagination |
| `scene.get_roots` | `get_open_scenes` | `EditorInterface.get_open_scenes()` |
| `node.find` | `find_nodes` | By name, type, group, or property |
| `node.get_properties` | `get_node_properties` | `Object.get_property_list()` + values |
| `node.get_children` | `get_children` | Direct children of a node path |
| `node.get_groups` | `get_groups` | `Node.get_groups()` |

**Batch 3 — Project reads (Week 3-4):**
| Tool | Plugin handler | Notes |
|------|---------------|-------|
| `project_settings.get` | `get_project_setting` | `ProjectSettings.get_setting()` |
| `logs.read` | `get_logs` | Ring buffer in plugin, last N lines — already done |
| `filesystem.search` | `search_filesystem` | `EditorFileSystem` scan |

**Batch 4 — MCP Resources (Week 4):**
| Resource URI | Data source |
|-------------|-------------|
| `godot://sessions` | Session registry |
| `godot://scene/current` | Current scene path + root node |
| `godot://scene/hierarchy` | Full tree (paginated) |
| `godot://selection/current` | Selected nodes |
| `godot://project/info` | Project name, Godot version, paths |
| `godot://project/settings` | Common settings subset |
| `godot://logs/recent` | Last 100 log lines |

**Batch 5 — Editor dock panel — DONE:**

| Component | Implementation | Notes |
|-----------|---------------|-------|
| Connection status | Green/red indicator | Updates on connect/disconnect |
| Server ports | WS + HTTP port display | From constants |
| MCP command log | Scrolling `RichTextLabel` | Fed from `_log_buffer` |
| Logging toggle | `CheckButton` | Controls `mcp_logging` var |
| Reconnect button | `Button` | Calls `_attempt_reconnect()` |
| Reload Plugin button | `Button` | Toggles plugin off/on |
| Setup status | Dev mode / uv version | Auto-detected |
| Client config | Configure buttons per client | Claude Code, Codex, Antigravity |

### Pagination design

Large results (scene trees with 1000+ nodes, long log buffers) need pagination:
- `offset` + `limit` parameters on relevant tools
- Default limit: 100 nodes / 50 log lines
- Response includes `total_count` and `has_more`

**Batch 6 — Test harness — DONE:**

| Component | Implementation | Notes |
|-----------|---------------|-------|
| `McpTestRunner` | `testing/test_runner.gd` | Discovers test_* methods, collects results |
| `McpTestSuite` | `testing/test_suite.gd` | Base class with assertions |
| Test suites | `test_project/tests/test_*.gd` | 3 suites: scene, node, editor |
| `run_tests` | MCP tool + handler | Auto-discovers suites, hot-reloads test files |
| `get_test_results` | MCP tool + handler | Returns last run results |

### Phase 1 progress
- [x] Batch 1: Session and editor tools
- [x] Batch 2: Scene read tools (6 tools)
- [x] Batch 3: Project reads (project_settings.get, filesystem.search)
- [x] Batch 4: MCP Resources (7 resources: sessions, scene/current, scene/hierarchy, selection/current, project/info, project/settings, logs/recent)
- [x] Batch 5: Editor dock panel with setup status
- [x] Batch 6: Test harness (44 Godot-side + 140 Python = 184 total tests)
- [x] Pagination for large results (offset/limit on scene_get_hierarchy, logs_read, node_find, filesystem_search)
- [x] Handler/runtime abstraction layer (shared handlers depend on Runtime protocol, not FastMCP context)
- [x] Codex client configurator (TOML config at `~/.codex/config.toml`)
- [x] `reload_plugin` tool — triggers live plugin reload, waits for new session via Future-based waiter
- [x] ASGI reloadable entrypoint (`--reload` uses uvicorn factory path for Python auto-reload)
- [x] Dev server start/stop controls in Godot dock panel
- [x] Reload smoke test in CI (creates node, reloads plugin, verifies log buffer fresh + scene tree survived)
- [ ] Manual test: Claude describes the open scene

---

## 5b. Distribution & User Install Flow

Ship the user install path before adding more features. Everything above is dev-tested; this makes it user-ready.

### PyPI publishing
- [ ] Choose package name (verify `godot-ai` is available on PyPI)
- [ ] Add project metadata to `pyproject.toml` (description, URLs, classifiers, license)
- [ ] Publish to PyPI: `uv build && uv publish`
- [ ] Verify: `uvx godot-ai --help` works on a clean machine

### End-to-end user flow testing
- [ ] Test on clean macOS (no `.venv`, just uv + Godot): install plugin, enable, server starts via uvx
- [ ] Test on Windows: uvx discovery, server start, plugin connection
- [ ] Test on Linux: same
- [ ] Test server update: bump version, re-publish, verify uvx picks up new version

### Plugin distribution
- [ ] Submit to Godot Asset Library (or decide on distribution channel)
- [ ] First-run UX: dock panel shows "Install uv" if missing, one-click install
- [ ] Document install flow in README for each platform

### CI pipeline (GitHub Actions)

Run on every push and PR. Three-tier matrix:

**Tier 1 — Python tests (fast, all platforms):**
- Matrix: `{ubuntu-latest, macos-latest, windows-latest}` x `{python 3.11, 3.13}`
- Steps: `pip install -e ".[dev]"` → `pytest -v` → `ruff check`
- These are the 32 unit + integration tests (WebSocket mock, protocol, registry)
- No Godot needed — runs in ~3 seconds

**Tier 2 — Godot-side tests (headless, all platforms):**
- Matrix: `{ubuntu-latest, macos-latest, windows-latest}` x `{godot 4.4+}`
- Steps: install Godot headless → install server → start server → enable plugin → `run_tests` via MCP → assert 0 failures
- These are the 35 handler tests running inside the actual editor
- Requires headless Godot (`--headless` flag) + Xvfb on Linux

**Tier 3 — User install flow (smoke test, all platforms):**
- Matrix: `{ubuntu-latest, macos-latest, windows-latest}`
- Steps: install uv → `uvx godot-ai --help` (verify package installs from PyPI) → start server → health check HTTP endpoint
- No Godot needed — just verifies the server starts and responds
- Runs on release tags only (not every push)

**Setup tasks:**
- [x] Create `.github/workflows/ci.yml` with Tier 1 (Python tests) — 6 jobs: 3 OS x 2 Python versions
- [x] Add Tier 2 with Godot headless — 3 jobs: Linux (Docker), macOS, Windows using `chickensoft-games/setup-godot`
- [x] Add reload smoke test to Tier 2 (reload_plugin e2e on all 3 OSes)
- [x] Add Codecov integration with patch coverage check
- [x] Add status badges to README
- [ ] Add Tier 3 for release smoke tests (uvx install path)

---

## 6. Phase 2: Safe Write Path (Weeks 4-7)

### Tool implementation order

**Batch 5 — Scene writes (Week 4-5):**
| Tool | Plugin handler | Undo? | Notes |
|------|---------------|-------|-------|
| `scene.create` | `create_scene` | N/A | Creates + opens new scene |
| `scene.open` | `open_scene` | N/A | `EditorInterface.open_scene_from_path()` |
| `scene.save` | `save_scene` | N/A | `EditorInterface.save_scene()` |
| `scene.save_as` | `save_scene_as` | N/A | Save to new path |
| `scene.close` | `close_scene` | N/A | Close tab |

**Batch 6 — Node writes (Week 5-6):**
| Tool | Plugin handler | Undo? | Notes |
|------|---------------|-------|-------|
| `node.create` | `create_node` | Yes | Type + parent path + name |
| `node.delete` | `delete_node` | Yes | By node path |
| `node.reparent` | `reparent_node` | Yes | Move node to new parent |
| `node.set_property` | `set_property` | Yes | Simple types only in Phase 2 |
| `node.duplicate` | `duplicate_node` | Yes | Deep copy |
| `node.move` | `move_node` | Yes | Reorder among siblings |
| `node.add_to_group` | `add_to_group` | Yes | `Node.add_to_group()` |
| `node.remove_from_group` | `remove_from_group` | Yes | `Node.remove_from_group()` |
| `editor.selection.set` | `set_selection` | No | Select nodes by path |

**Batch 7 — Script and resource writes (Week 6-7):**
| Tool | Plugin handler | Undo? | Notes |
|------|---------------|-------|-------|
| `script.create` | `create_script` | N/A | Write GDScript file to disk |
| `script.read` | `read_script` | N/A | Read script contents |
| `script.attach` | `attach_script` | Yes | Assign script to node |
| `script.detach` | `detach_script` | Yes | Remove script from node |
| `script.find_symbols` | `find_symbols` | N/A | Functions, signals, exports in a script |
| `resource.search` | `search_resources` | N/A | By type, path pattern |
| `resource.load` | `load_resource` | N/A | Inspect resource properties |
| `resource.assign` | `assign_resource` | Yes | Set resource on a node property |
| `filesystem.read_text` | `read_file` | N/A | Read any text file in project |
| `filesystem.write_text` | `write_file` | N/A | Write + trigger reimport |
| `import.reimport` | `reimport` | N/A | Force reimport of specific files |

### Undo integration pattern

Every undoable operation follows this GDScript pattern:

```gdscript
var undo_redo = get_undo_redo()  # EditorPlugin method
undo_redo.create_action("MCP: Create Node")
undo_redo.add_do_method(self, "_do_create_node", parent_path, node_type, node_name)
undo_redo.add_undo_method(self, "_undo_create_node", parent_path, node_name)
undo_redo.commit_action()
```

Non-undoable operations (file writes, scene open/close) document this in their tool response:
```json
{"undoable": false, "reason": "File system operations cannot be undone via editor undo"}
```

### Readiness gating

All write tools check readiness before executing:
- If `importing`: reject with `EDITOR_NOT_READY` error
- If `playing`: allow only safe reads and `project.stop`
- If `scene_switching`: queue and retry after scene load

### Phase 2 exit criteria
- [ ] All Batch 5-7 tools implemented and tested
- [ ] Undo works for node operations (create, delete, reparent, set_property)
- [ ] Write operations are gated on readiness
- [ ] Manual test: ask Claude to create a scene with 5 nodes and a script — it can
- [ ] 60+ passing tests

---

## 7. Phase 3: Godot-Native Depth (Weeks 7-10)

### Tools to implement

**Signals and project config:**
- `signal.list` — list signals on a node (including custom)
- `signal.connect` — connect signal to method
- `signal.disconnect` — disconnect signal
- `autoload.list`, `autoload.add`, `autoload.remove`
- `input_map.list`, `input_map.add_action`, `input_map.remove_action`, `input_map.bind_event`
- `project_settings.set`
- `uid.get`, `uid.update`

**Runtime and diagnostics:**
- `project.run` — start the game (`EditorInterface.play_main_scene()` or `play_current_scene()`)
- `project.stop` — stop the game (`EditorInterface.stop_playing_scene()`)
- `logs.clear` — clear log buffer
- `editor.screenshot` — viewport capture via `get_viewport().get_texture().get_image()`
- `editor.command.execute` — run editor commands by name
- `performance.get_monitors` — `Performance.get_monitor()` values

**Batch execution:**
- `batch.execute` — ordered execution of multiple commands with per-step results
- Optional undo grouping (all steps in one undo action)
- Partial failure: execute until first error, return results so far

**Deferred from Phase 2:**
- `node.rename` — with UID/reference awareness
- `node.set_property` — complex types (`Resource`, `NodePath`, `Array`, `Dictionary`)
- `script.patch` — research spike: can we reliably patch GDScript? If not, document why and keep full-file writes.

**Multi-instance support:**
- Multiple Godot editors connected simultaneously
- Session selection UI or tool parameter
- Session metadata includes enough info to distinguish (project path, window title)

### Phase 3 exit criteria
- [ ] Signal, autoload, input_map tools work
- [ ] Project run/stop cycle works reliably
- [ ] Batch execution handles partial failures
- [ ] Multi-instance: two Godot editors connected, commands route correctly
- [ ] `script.patch` spike completed (shipped or documented as not viable)
- [ ] 90+ passing tests

---

## 8. Phase 4: Hardening and Launch (Weeks 10-13)

Extended to 3 weeks (was 2) to account for solo developer + Godot learning curve.

### Install flow polish
- PyInstaller binaries for macOS (arm64 + x86_64), Windows, Linux
- GitHub Releases with checksums
- One-command plugin install: download + copy to addons
- Clear README with screenshots and quickstart video (or GIF)

### Documentation
- `docs/install.md` — step-by-step install for each MCP client (Claude Desktop, Cursor, Windsurf, etc.)
- `docs/tool-reference.md` — auto-generated from tool docstrings
- `docs/protocol.md` — WebSocket protocol spec for plugin developers
- `docs/compatibility.md` — Godot version matrix (4.3, 4.4, 4.5-dev)
- `docs/contributor-guide.md` — how to add a new tool, test it, build the binary

### CI pipeline
- GitHub Actions:
  - `test.yml`: run pytest on every push/PR
  - `lint.yml`: ruff check + format
  - `build.yml`: PyInstaller builds on tag (3 platforms)
  - `e2e.yml`: headless Godot e2e tests (stretch goal — Godot in CI is possible but fiddly)

### Telemetry and diagnostics
- Structured logging (JSON) with configurable verbosity
- `cli/status` command: show connected sessions, server uptime, recent errors
- `cli/test-connection` command: verify plugin can connect
- Optional anonymous usage telemetry (off by default, opt-in)

### Compatibility testing
- Test against Godot 4.3 stable, 4.4 stable
- Document any 4.3 limitations (no UID tools, etc.)
- Test with Claude Desktop, Cursor, and at least one other MCP client

### Phase 4 exit criteria
- [ ] A new user can go from zero to working MCP in under 10 minutes
- [ ] Binaries available for macOS, Windows, Linux
- [ ] All docs written and accurate
- [ ] CI green on all platforms
- [ ] Compatibility matrix published
- [ ] GitHub repo has proper description, topics, and social preview image

---

## 9. GDScript Plugin Architecture

### File structure

```text
addons/godot_mcp_studio/
├── plugin.cfg
├── plugin.gd                 # EditorPlugin — lifecycle, owns Connection + Dispatcher + Dock
├── connection.gd             # WebSocketPeer wrapper — connect, reconnect, send, receive
├── mcp_dock.gd               # Editor dock panel — status, log viewer, controls
├── dispatcher.gd             # Command queue + frame-budget dispatch
├── state/
│   ├── session_state.gd      # Tracks session metadata, readiness
│   └── log_buffer.gd         # Ring buffer for output log capture
├── handlers/
│   ├── editor_handler.gd     # editor.state, selection, screenshot
│   ├── scene_handler.gd      # scene.*, node.*
│   ├── script_handler.gd     # script.*
│   ├── resource_handler.gd   # resource.*, filesystem.*
│   ├── project_handler.gd    # project.run/stop, project_settings.*, signals, autoloads
│   └── batch_handler.gd      # batch.execute
└── utils/
    ├── serializer.gd         # Node/Resource → Dictionary conversion
    └── node_finder.gd        # find by name, type, group, path pattern
```

### Concurrency model (detail)

```
WebSocket receive
       │
       ▼
   command_queue: Array[Dictionary]      ← append on receive, never block
       │
       ▼
   _process(delta)
       │
       ├─ budget_ms = 4.0
       ├─ start = Time.get_ticks_msec()
       │
       ├─ while queue not empty AND elapsed < budget_ms:
       │      command = queue.pop_front()
       │      result = dispatch(command)    ← call_deferred for tree mutations
       │      send_response(result)
       │
       └─ remaining commands wait for next frame
```

**Key rules:**
1. Never call `EditorInterface` methods directly from WebSocket callbacks — always queue.
2. Scene tree mutations (`add_child`, `remove_child`, `reparent`) must use `call_deferred`.
3. Long operations (filesystem scan, deep tree walk) must yield across frames using `await get_tree().process_frame`.
4. Undo operations go through `EditorUndoRedoManager` (Godot 4.x), obtained via `get_undo_redo()`.

### Plugin lifecycle

```
_enter_tree():
    1. Create Connection (WebSocket)
    2. Create Dispatcher
    3. Register handlers
    4. Start connection attempt
    5. Hook into editor signals:
       - EditorInterface.get_edited_scene_root() change
       - EditorPlugin.main_screen_changed
       - EditorInterface play/stop signals

_process(delta):
    1. Connection.poll()           ← WebSocket needs manual polling in Godot
    2. Dispatcher.tick(delta)      ← Drain command queue
    3. LogBuffer.flush()           ← Forward captured output

_exit_tree():
    1. Disconnect WebSocket cleanly
    2. Free resources
```

---

## 10. PyInstaller Packaging Pipeline

### Build command

```bash
# From repo root
pip install pyinstaller
pyinstaller --onefile \
    --name godot-mcp-studio \
    --add-data "src/godot_mcp_studio:godot_mcp_studio" \
    src/godot_mcp_studio/__main__.py
```

### `__main__.py` entrypoint

```python
"""Godot MCP Studio — entry point for both development and packaged binary."""
import sys
from godot_mcp_studio.server import create_server

def main():
    server = create_server()
    server.run()

if __name__ == "__main__":
    main()
```

### Platform matrix

| Platform | Build env | Output | Notes |
|----------|-----------|--------|-------|
| macOS arm64 | macOS runner | `godot-mcp-studio` | Primary dev platform |
| macOS x86_64 | macOS runner | `godot-mcp-studio` | For Intel Macs |
| Windows | Windows runner | `godot-mcp-studio.exe` | |
| Linux x86_64 | Ubuntu runner | `godot-mcp-studio` | |

### GitHub Actions build workflow (sketch)

```yaml
name: Build Release
on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        os: [macos-latest, macos-13, ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install -e ".[build]"
      - run: pyinstaller --onefile --name godot-mcp-studio src/godot_mcp_studio/__main__.py
      - uses: actions/upload-artifact@v4
        with:
          name: godot-mcp-studio-${{ matrix.os }}
          path: dist/godot-mcp-studio*
```

### Testing the binary

After build, verify:
1. Binary starts without Python installed (test in clean Docker container or fresh VM)
2. `./godot-mcp-studio --version` prints version
3. `./godot-mcp-studio` starts MCP server and WebSocket listener
4. Godot plugin can connect to the binary-launched server
5. At least one MCP tool call roundtrips successfully

---

## 11. Must-Prove Milestones (Go/No-Go Gates)

These are points where you should honestly evaluate whether to continue, pivot, or adjust scope.

### Gate 1: Weekend spike (end of Day 2)

**Must prove:** A real MCP tool call can travel from an AI client through the Python server, over WebSocket, to the Godot plugin, execute against the Godot editor API, and return a real response.

**Go if:** The full vertical works, even if janky.
**No-go if:** WebSocket communication with Godot's `WebSocketPeer` is fundamentally broken or the editor plugin can't access the APIs you need. Pivot: evaluate TCP socket or HTTP polling instead of WebSocket.

### Gate 2: End of Phase 0 (Week 2)

**Must prove:** The connection is reliable enough that you're not fighting reconnects and protocol bugs every time you want to test a new tool.

**Go if:** You can open Godot, start the server, and interact via MCP inspector without things falling apart within 5 minutes.
**No-go if:** Connection reliability is consuming all your time. Pivot: simplify to HTTP request/response before investing in more tools.

### Gate 3: End of Phase 1 (Week 4)

**Must prove:** The read tools are actually useful. Claude can inspect a Godot project, understand its structure, and provide meaningful assistance.

**Go if:** You personally find it useful for your own Godot work. The "describe this scene" workflow feels magical.
**No-go if:** The tool responses are too noisy, too slow, or don't give Claude enough context. Pivot: focus on response quality and tool design before adding write tools.

### Gate 4: End of Phase 2 (Week 7)

**Must prove:** Write operations are safe and reliable. Claude can create scenes, add nodes, and write scripts without corrupting the project.

**Go if:** You'd trust it to make changes in a project you care about (with undo available).
**No-go if:** Write operations are flaky, undo doesn't work, or the readiness gating isn't catching unsafe states. Pivot: reduce write scope further, invest in safety.

### Gate 5: Pre-launch (Week 12)

**Must prove:** A person who isn't you can install it and use it successfully.

**Go if:** You hand the install instructions to someone and they get it working without your help.
**No-go if:** The install flow requires too much manual configuration or platform-specific debugging. Pivot: simplify distribution, add troubleshooting docs.

---

## 12. Risk Register

### R1: Godot learning curve

**Risk:** You're new to Godot. The GDScript plugin, editor APIs, and Godot idioms will be unfamiliar.
**Likelihood:** Certain.
**Impact:** Medium — slows development, may lead to non-idiomatic plugin code.
**Mitigation:**
- Budget extra time in each phase (already reflected in timeline).
- Use Claude Code to accelerate Godot learning — ask it to explain APIs, review GDScript.
- Keep `test_project/` in repo — iterate quickly against a real project.
- Read the Godot `EditorPlugin` and `EditorInterface` docs before starting Track B.

### R2: WebSocketPeer limitations in Godot

**Risk:** Godot's `WebSocketPeer` may have quirks: manual polling requirement, buffer size limits, no built-in reconnect, potential issues with binary frames.
**Likelihood:** Medium.
**Impact:** High if it blocks the core communication path.
**Mitigation:**
- The weekend spike specifically targets this risk.
- Fallback: TCP socket with JSON-line protocol (simpler, less feature-rich).
- Fallback: HTTP polling (worst performance, but guaranteed to work).

### R3: Editor API gaps

**Risk:** Some operations may not be possible through `EditorInterface` / `EditorPlugin` APIs. Godot's editor API is good but not as exhaustive as Unity's.
**Likelihood:** Medium — likely for some advanced operations.
**Impact:** Medium — limits specific tool capabilities, not the overall project.
**Mitigation:**
- Phase 1 read tools will quickly reveal API coverage gaps.
- `code.execute` escape hatch for operations not covered by typed tools.
- Document gaps honestly in compatibility docs.

### R4: GDScript performance for large scenes

**Risk:** Walking a 5000+ node scene tree in GDScript may be too slow for the frame budget.
**Likelihood:** Low-Medium.
**Impact:** Medium — slow responses for large projects.
**Mitigation:**
- Pagination (already in design).
- Yielding across frames for large operations.
- GDExtension (C++) contingency for hot paths.
- Cache scene tree data, invalidate on change.

### R5: PyInstaller packaging issues

**Risk:** PyInstaller can be fragile with complex dependencies, especially cross-platform.
**Likelihood:** Medium.
**Impact:** Medium — doesn't block development, but blocks easy distribution.
**Mitigation:**
- Phase 0.5 specifically spikes this early.
- Fallback: `pipx install` for users who have Python.
- Fallback: Docker image.
- Fallback: Nuitka or cx_Freeze as alternative packagers.

### R6: Solo developer burnout

**Risk:** 13-week plan is ambitious for a solo developer with a day job.
**Likelihood:** Medium.
**Impact:** High — project stalls.
**Mitigation:**
- Go/no-go gates allow honest scope adjustment.
- Phase 1 alone (read tools) is a useful product — ship it if momentum stalls.
- Claude Code as AI pair significantly accelerates implementation.
- The weekend sprint creates early momentum and a working demo.

### R7: Scope creep from the proposal

**Risk:** The proposal describes 80+ tools. Trying to build them all before shipping anything.
**Likelihood:** Medium.
**Impact:** High — nothing ships.
**Mitigation:**
- This plan explicitly phases and defers tools.
- Phase 1 ships a useful read-only product.
- Phase 2 ships core writes.
- Everything else can wait for real user demand.
- Resist adding tools not in the current phase.

---

## Appendix: Quick Reference

### Key files to know

| File | Purpose |
|------|---------|
| `src/godot_mcp_studio/server.py` | MCP server entrypoint |
| `src/godot_mcp_studio/transport/websocket.py` | WebSocket server for Godot |
| `src/godot_mcp_studio/sessions/registry.py` | Session tracking |
| `src/godot_mcp_studio/godot_client/client.py` | Typed client for plugin commands |
| `plugin/addons/godot_mcp_studio/plugin.gd` | Editor plugin main script |
| `plugin/addons/godot_mcp_studio/connection.gd` | WebSocket client in GDScript |
| `plugin/addons/godot_mcp_studio/dispatcher.gd` | Command queue + dispatch |

### Key commands

```bash
# Start dev server
python -m godot_mcp_studio

# Run tests
pytest tests/

# Build binary
pyinstaller --onefile --name godot-mcp-studio src/godot_mcp_studio/__main__.py

# Lint
ruff check src/ tests/
ruff format src/ tests/
```

### WebSocket protocol (summary)

**Handshake (plugin → server):**
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

**Command (server → plugin):**
```json
{
  "request_id": "uuid",
  "command": "get_scene_tree",
  "params": {"depth": 10}
}
```

**Response (plugin → server):**
```json
{
  "request_id": "uuid",
  "status": "ok",
  "data": { ... }
}
```

**Error response (plugin → server):**
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
