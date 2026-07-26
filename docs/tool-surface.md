# The MCP tool surface — shape, naming, and adding a tool

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


Why the surface is shaped the way it is, how plugin command names differ from MCP
tool names, and the checklist for adding a new tool.

## Tool-search friendliness + tool-count caps

The MCP tool surface is shaped to satisfy two pressures at once:

1. **Anthropic tool-search clients** (`tool_search_tool_bm25_20251119` / `tool_search_tool_regex_20251119`) — non-core tools are tagged `meta={"defer_loading": True}` so the client only loads schemas it searches for.
2. **Tool-count caps in non-search clients** (Antigravity, etc., that ignore `defer_loading` and refuse to start past ~40 tools) — long-tail verbs collapse into per-domain `<domain>_manage` rollups (`op="<verb>"` + `params` dict). Schema-aware clients still see every op via the dynamic `Literal[...]` enum built by `register_manage_tool` in `tools/_meta_tool.py`.

Result: ~43 MCP tools (4 core + 15 named verbs + 24 rollups), down from a flat surface that crossed 100. Plugin command names over WebSocket stay independent — they're documented in `tool_catalog.gd` and unchanged by the rollup refactor.

- All tools follow `domain_action` namespacing — no ambiguous prefixes
- Core tools loaded upfront (no `meta=`): `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`
- Descriptions include natural-language keywords users would search for (e.g. "screenshot", "keybinding", "asset", "event / callback") so tool-search BM25 hits them
- `server.py` `instructions=` includes a tool categories blurb listing the rollup map, so tool-search clients have a discovery map without reading every schema
- Read-only `godot://...` resources mirror the cheap reads (`godot://editor/state`, `godot://node/{path}/properties`, `godot://script/{path}`, etc.) — they don't count against the tool cap, and aware clients prefer them. Tool form remains for `session_id`-pinned reads.

For tool-capped clients without tool-search support, the server accepts `--exclude-domains audio,particle,...` (CLI flag and `EditorSettings`-backed dock UI) to drop entire domains' rollups and named tools while keeping the core 4 alive.

When adding a new verb, prefer adding it as an op on the domain's existing `register_manage_tool(...)` call rather than registering a new top-level tool — only the highest-traffic verbs warrant a named tool (see "Adding a new tool" below).

## Plugin command vs MCP tool names

The plugin (GDScript) uses short command names over WebSocket (`run_tests`, `reload_plugin`, `reimport`, `set_selection`, `search_filesystem`, `get_performance_monitors`, `create_node`, `set_property`, `delete_node`, etc.). These are internal — `plugin.gd::_register_handlers` is the authoritative list (`tool_catalog.gd` mirrors the MCP tool surface, not the plugin command names). They are independent of the MCP tool names. The Python handler in `src/godot_ai/handlers/<domain>.py` is the authoritative MCP-name → plugin-command map.

When using `batch_execute`'s `commands[].command` field, use the **plugin command name** (`create_node`, `set_property`) — not the MCP tool name (`node_create`, `node_set_property`). The same rule applies inside a `<domain>_manage` op (`node_manage(op="delete", ...)` delegates to the plugin's `delete_node`, not `node_delete`).

`batch_execute` is a meta-tool that invokes other plugin commands in a single call. Execution stops on first error; when `undo=True` (default), successful sub-commands are rolled back via scene UndoRedo on failure. Implemented via `McpDispatcher.dispatch_direct()` and `has_command()`. Unknown plugin commands return `INVALID_PARAMS` with fuzzy `data.suggestions`.

## Adding a new tool

1. Add a handler method in the appropriate GDScript `handlers/*.gd` file
2. Register it in `plugin.gd`: `_dispatcher.register_lazy("command_name", "<handler_key>", &"method")` (for a brand-new handler file, also add one `register_lazy_handler("<handler_key>", HANDLERS_DIR + "<file>.gd", [ctor args])` line — handlers are load()ed lazily at first dispatch, #736)
3. Add a shared Python handler in `handlers/<domain>.py` that calls `runtime.send_command("command_name", params)`
4. **Decide the MCP tool surface**:
   - **High-traffic verb (top-20)** → register as a named tool in `tools/<domain>.py` with `@mcp.tool(meta=DEFER_META)` (import `DEFER_META` from `godot_ai.tools`; omit `meta` if it's one of the ~4 always-loaded core tools: `editor_state`, `scene_get_hierarchy`, `node_get_properties`, `session_activate`). Add `session_id: str = ""` as the last parameter and pass it in: `DirectRuntime.from_context(ctx, session_id=session_id or None)`.
   - **Long-tail verb (default)** → add it to the `ops={}` dict for the existing `register_manage_tool(...)` call. The `<domain>_manage` rollup picks it up automatically; the meta-tool helper handles `session_id` extraction, JSON-string param coercion, and unknown-op error suggestions. No new tool registration needed.
5. Update `tool_catalog.gd` to mirror the new tool list — `tests/unit/test_tool_domains.py` will fail with a paste-over-ready diff if you forget.
6. Update the tool-surface blurb in `server.py` `instructions=` if the new verb is named (rollups are listed by tool, not by op).
7. For write tools: add an `await require_writable_async(runtime)` call at the top of the Python handler.
8. Write a description with natural-language keywords a user would search for (e.g. `screenshot`, `keybinding`, `asset`) alongside the Godot term. For ops inside a rollup, edit the `_DESCRIPTION` block of the domain's tool file so the rolled-up tool's docstring stays exhaustive.
9. **Consider a resource form**: pure reads with no `session_id` filtering benefit from a matching `godot://...` resource (or template) in `src/godot_ai/resources/`. The tool form remains for `session_id`-pinned reads; clients that surface resources prefer the URI. When you add a resource form, append `Resource form: godot://...` to the tool's description so aware clients can route reads through the URI.
10. Add tests: handler unit test, Python integration test, AND GDScript test in `test_project/tests/`. Migrate any integration tests for an existing verb when you move it under a rollup — the form changes from `client.call_tool("domain_verb", {...})` to `client.call_tool("domain_manage", {"op": "verb", "params": {...}, "session_id": ...})`.
