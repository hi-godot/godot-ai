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
  `entry_uvx_bridge`, `command_shape`, `command_initial_fields`). Adding a client
  means exactly two things: write
  `clients/<name>.gd` extending `McpClient`, then append one `preload` to
  `_registry.gd`. No edits to the dock, the facade, or the strategies.

MCP tools `client_configure`, `client_remove`, and `client_status` expose this to
AI clients.

Client-owned attach entries carry a launch command rather than only an HTTP
URL. The dock captures ports, canonical excluded domains, plugin version, and
dev/user mode on the main thread, then workers resolve the same three launch
tiers used by server startup (dev venv → exact-version uvx → matching system
install). Package pins, command paths, ports, exclusions, and required uv
options are verified as launch drift; **Configure all** is the repair path after
a self-update, port change, or tool-domain change. Never silently fall back to a
bare `uvx` command for these entries—report ERROR and leave the config untouched
when no verified tier exists.

Launch resolution intentionally fails **closed**: Configure returns ERROR and
leaves the config untouched if no valid launch tier exists on any platform, or
if `_finalize_attach_launch()` cannot resolve a consoleless interpreter on
Windows. Non-Windows platforms succeed as soon as a valid launch tier is
available; a missing entry is better than one known to be broken. Backend spawn
intentionally fails **open**: `backend_python_executable()` prefers a sibling
`pythonw.exe` on Windows but falls back to the current executable when it is
absent, because a visible console is better than a dead backend at runtime.

`client_status` returns `{"clients": [{id, display_name, status, installed},
…]}`. The dock renders one row per client with a status dot, Configure/Remove
buttons, and a per-row "Run this manually" fallback for cases when
auto-configure cannot find a CLI.
