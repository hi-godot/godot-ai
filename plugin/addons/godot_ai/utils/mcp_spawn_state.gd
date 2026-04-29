@tool
class_name McpSpawnState
extends RefCounted

## Outcome of the plugin's server-spawn attempt in `_enter_tree`.
##
## One field, one value — the dock switches on it to decide which
## diagnostic panel to render while the WebSocket is down. Replaces the
## boolean-salad (`_server_crashed`, `_server_port_excluded`, …) that
## needed a new flag + dock branch per failure mode.
##
## State is authored by `plugin.gd::_start_server` (once per plugin
## session) and `plugin.gd::_check_server_health` (on late spawn death).
## It does NOT track runtime connection health — that's `McpConnection`'s
## job and is reflected by the green/red status dot.

## Happy path: we spawned or adopted a managed server. The dock hides
## the diagnostic panel entirely; connection status tells the rest of
## the story (amber "Starting server…" / green "Connected").
const OK := "ok"

## Windows reserved the HTTP port before we even tried to bind. Caught
## proactively via `netsh interface ipv4 show excludedportrange`. The
## dock shows the port picker with a Hyper-V/WSL/Docker-aware hint.
const PORT_EXCLUDED := "port_excluded"

## HTTP port is held by a process we didn't spawn (no managed-server
## record matches). Connecting would fail because the foreign process
## doesn't speak MCP. Dock shows the port picker — same escape as
## PORT_EXCLUDED, just a different root cause.
const FOREIGN_PORT := "foreign_port"

## HTTP port is held by a godot-ai server or MCP-looking process whose
## live version could not be verified as compatible with this plugin.
## The plugin must not silently adopt it or mark client setup healthy.
const INCOMPATIBLE_SERVER := "incompatible_server"

## Our spawned process exited inside the startup grace window. Python
## stdout/stderr went to Godot's output log (no pipe capture), so the
## dock points the user there instead of rendering empty output.
const CRASHED := "crashed"

## No server command resolved: no .venv Python, no uvx on PATH, no
## system `godot-ai`. Dock surfaces install guidance instead of the
## silent `push_warning` the old code emitted only to the console.
const NO_COMMAND := "no_command"
