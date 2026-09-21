@tool
class_name McpServerState
extends RefCounted
## Stable presentation values consumed by the Dock and editor-status API.
## McpServerLifecycleManager's tagged episode is the only transition owner.
const UNINITIALIZED := 0
const SPAWNING := 1
# Slot 2 stays unused so existing status consumers keep stable values.
const READY := 3
const INCOMPATIBLE := 4
const CRASHED := 5
const NO_COMMAND := 6
const PORT_EXCLUDED := 7
const FOREIGN_PORT := 8
const STOPPING := 10
const STOPPED := 11
const UNSUPPORTED_CONFIG := 12

const _NAMES := {
	UNINITIALIZED: "uninitialized",
	SPAWNING: "spawning",
	READY: "ready",
	INCOMPATIBLE: "incompatible",
	CRASHED: "crashed",
	NO_COMMAND: "no_command",
	PORT_EXCLUDED: "port_excluded",
	FOREIGN_PORT: "foreign_port",
	STOPPING: "stopping",
	STOPPED: "stopped",
	UNSUPPORTED_CONFIG: "unsupported_config",
}


## Human-readable label. Used in startup-trace logs and transition
## warnings. Falls back to `unknown(<int>)` for unrecognised values so
## a future enum addition won't crash the formatter.
static func name_of(state: int) -> String:
	return _NAMES.get(state, "unknown(%d)" % state)


## True for any state the dock should render as a non-OK diagnostic
## panel. Used as the "should we hide the spawn-failure panel?" gate.
static func is_terminal_diagnosis(state: int) -> bool:
	return (
		state == CRASHED
		or state == NO_COMMAND
		or state == PORT_EXCLUDED
		or state == INCOMPATIBLE
		or state == FOREIGN_PORT
		or state == UNSUPPORTED_CONFIG
	)


## True when the dock should skip interpreting client health (incompatible
## tool surface). This must NOT block Configure writes — those take an
## explicit url and the live plugin version (#916). Currently just
## INCOMPATIBLE and UNSUPPORTED_CONFIG — FOREIGN_PORT may resolve to READY
## if the foreign occupant turns out to speak our handshake.
static func blocks_client_health(state: int) -> bool:
	return state in [INCOMPATIBLE, UNSUPPORTED_CONFIG]
