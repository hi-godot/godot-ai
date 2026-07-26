# Client configuration (19+ MCP clients)

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


The registry + strategy system that auto-configures MCP clients.

## Client configuration

The plugin auto-configures 19+ MCP clients via a registry + strategy system in
`plugin/addons/godot_ai/clients/`. Read that directory for the mechanics; two
rules are not visible in the code:

- **Descriptors are data only** — no `Callable` fields, no control flow. Strategies
  interpret the data. `test_descriptors_are_data_only` enforces this (issue #229:
  hot-reloaded per-client lambdas raced with worker threads).
- **No per-client branching inside strategies.** Non-standard entry shapes are
  expressed declaratively on the descriptor (`entry_url_field`, `entry_extra_fields`,
  `entry_uvx_bridge`). Adding a client means exactly two things: write
  `clients/<name>.gd` extending `McpClient`, then append one `preload` to
  `_registry.gd`. No edits to the dock, the facade, or the strategies.

MCP tools `client_configure`, `client_remove`, and `client_status` expose this to
AI clients.
