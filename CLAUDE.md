# CLAUDE.md — Godot AI

## What this project is

A production-grade MCP server for Godot. Python server (FastMCP v3) communicates over WebSocket with a GDScript editor plugin. AI clients call MCP tools → Python routes commands → Godot plugin executes against the editor API → results flow back.

## Architecture

```
AI Client → MCP (stdio/sse) → Python FastMCP server → WebSocket (port 9500) → Godot EditorPlugin
```

- **Python server**: `src/godot_ai/` — FastMCP v3, async, lifespan manages WebSocket server
- **GDScript plugin**: `plugin/addons/godot_ai/` — canonical source; copied into `test_project/addons/` for testing
- **Protocol**: JSON over WebSocket. Request/response with `request_id` correlation. Handshake on connect.
- **Session model**: Multiple Godot editors can connect. Tools route through active session.

## Key conventions

- **GDScript plugin is the canonical copy** in `plugin/`. `test_project/addons/godot_ai` is a symlink — no copy needed.
- **Error codes**: Defined in `protocol/errors.py` (Python) and `utils/error_codes.gd` (GDScript). Keep in sync.
- **Tools return `dict`**: `GodotClient.send()` returns `response.data` (a dict) or raises `GodotCommandError`. Tools just `return await app.client.send(...)`.
- **Plugin runs on main thread**: All GDScript executes in `_process()` with a 4ms frame budget. Never block. Use `call_deferred` for scene tree mutations.
- **Scene paths are clean**: `/Main/Camera3D` format, not raw Godot internal paths. Use `ScenePath.from_node(node, scene_root)` in GDScript.
- **MCP logging**: Plugin prints `MCP | [recv] command(params)` / `MCP | [send] command -> ok` to Godot console. Controlled by `mcp_logging` var.

## Dev workflow

```bash
cd ~/Documents/godot-ai
script/setup-dev             # creates .venv, installs deps, applies macOS .pth fix
source .venv/bin/activate
pytest -v                    # run tests
ruff check src/ tests/       # lint
ruff format src/ tests/      # format
```

**macOS + Python 3.13 note**: Files inside `.venv` inherit the macOS hidden flag (dot-prefix directory). Python 3.13 skips hidden `.pth` files (CPython gh-113659), breaking editable installs. `script/setup-dev` generates a `sitecustomize.py` in the venv that adds `src/` to `sys.path` via normal import (unaffected by hidden flags). No manual `chflags` needed.

### Server lifecycle in dev

The plugin manages the server process:
- **Reload Plugin** in the Godot dock kills the old server, starts a new one from `.venv/bin/python -m godot_ai`
- After Reload Plugin, do `/mcp` in Claude Code to reconnect

The plugin prefers the local `.venv` over system-installed `godot-ai` so dev checkouts always use source code.

For Python auto-reload during dev (no need to touch Godot):
```bash
python -m godot_ai --transport streamable-http --port 8000 --reload
```

## Testing

### Python tests
```bash
pytest -v                    # 81 unit + integration tests
```

### Godot-side tests
GDScript test suites in `test_project/tests/` exercise handlers inside the running editor. Run via MCP:
```
run_tests                    # run all suites
run_tests suite=scene        # run one suite
get_test_results             # review last results
```

Test suites extend `McpTestSuite` (assertion methods: `assert_true`, `assert_eq`, `assert_has_key`, `assert_contains`, `assert_is_error`, etc.). Drop `test_*.gd` files in `res://tests/` and they're auto-discovered.

## Testing against Godot

1. Open `test_project/` in Godot, enable plugin in Project Settings > Plugins
2. Open a scene (e.g. `main.tscn`)
3. Plugin starts the server automatically; logs should show `Session connected`
4. Use `/mcp` in Claude Code to connect

## Client configuration

The plugin can configure MCP clients via `client_configurator.gd`:
- **Claude Code**: uses `claude mcp add` CLI to register the server
- **Antigravity**: writes directly to `~/.gemini/antigravity/mcp_config.json`

MCP tools `client_configure` and `client_status` expose this to AI clients.

## Adding a new tool

1. Add a handler method in the appropriate `handlers/*.gd` file
2. Register it in `plugin.gd`: `_dispatcher.register("command_name", handler.method)`
3. Add a Python tool in `tools/<domain>.py` that calls `app.client.send("command_name", params)`
4. Register the tool module in `server.py` if it's a new file
5. Add tests: Python integration test in `tests/` AND GDScript test in `test_project/tests/`

## Write tools must be undoable

Every tool that mutates the scene (create, delete, reparent, set_property, etc.) must use `EditorUndoRedoManager`. No exceptions. The pattern:

```gdscript
_undo_redo.create_action("MCP: <description>")
_undo_redo.add_do_method(...)
_undo_redo.add_undo_method(...)
_undo_redo.add_do_reference(node)  # prevent GC of created nodes
_undo_redo.commit_action()
```

Response must include `"undoable": true`. If an operation genuinely can't be undone (file writes, scene open/close), include `"undoable": false` with a reason.

## Test coverage

100% code coverage for core features, always. Every tool, handler, and protocol path must have both:
- **Python tests** (`tests/unit/` and `tests/integration/`): protocol, WebSocket, client logic
- **Godot-side tests** (`test_project/tests/`): handlers exercised against the live editor

New features don't ship without tests. Regressions are caught before they merge.

## What NOT to do

- Don't call `EditorInterface` methods from WebSocket callbacks — always queue
- Don't cache `get_edited_scene_root()` across frames — it changes on scene switch
- Don't use `pop_front()` on arrays in hot paths — use index + slice
- Don't add error handling in individual tools — `GodotClient.send()` raises on errors
- Don't use Python-style `"""docstrings"""` in GDScript — use `##` comments
