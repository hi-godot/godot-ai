@tool
class_name McpServerState
extends RefCounted

## State machine for the plugin's server-spawn / adopt / version-verify
## lifecycle. Single source of truth — supersedes the boolean-flag thicket
## (`_server_started_this_session`, `_awaiting_server_version`,
## `_server_version_deadline_ms`, `_connection_blocked`,
## `_can_recover_incompatible`, `_server_dev_version_mismatch_allowed`,
## `_refresh_retried`, `_adoption_watch_deadline_ms`) and the older
## terminal-only McpSpawnState string union.
##
## The integer values matter — they're what `get_server_status()`
## surfaces, what the dock pattern-matches on, and what the test suites
## assert against. Reordering the enum is a breaking change.
##
## The transitions are documented in `can_transition()`. The lifecycle
## manager calls `set_state()` which:
##   1. Validates the transition (logs a warning + no-ops on illegal).
##   2. Preserves first-writer-wins among terminal diagnoses so a late
##      CRASHED from the watch loop can't clobber an earlier
##      PORT_EXCLUDED from the proactive Windows reservation check.

## Fresh plugin instance, `_start_server` has not run yet. Default state.
const UNINITIALIZED := 0
## Process spawned via OS.create_process; watch loop is observing the
## SPAWN_GRACE_MS window. Transitions directly to READY (handshake_ack
## verifies a compatible version), CRASHED (process died early), or
## INCOMPATIBLE (handshake reported a mismatch).
const SPAWNING := 1
## (slot 2 reserved — keep wire-compat for clients pattern-matching
## numeric `editor_state.state` values; do not reuse.)
## Server is healthy and version-verified. Happy path. Includes both
## "spawned fresh" and "adopted compatible existing server" flavors —
## adoption flavor is recorded separately via `McpAdoptionLabel`.
const READY := 3
## Live server on the HTTP port returned a version that doesn't match
## what this plugin expects, OR returned no `handshake_ack` inside the
## timeout. Connection is blocked; recovery requires a kill+respawn
## click via `recover_incompatible_server`.
const INCOMPATIBLE := 4
## Spawned process exited inside the SPAWN_GRACE_MS window. Python
## traceback went to Godot's output log. Terminal — reload the plugin
## or restart the editor to retry.
const CRASHED := 5
## No server command resolved: no `.venv` Python, no `uvx` on PATH, no
## system `godot-ai`. Terminal — install guidance shown in dock.
const NO_COMMAND := 6
## Windows reserved the HTTP port via Hyper-V / WSL2 / Docker exclusion
## range. Caught proactively before bind. Terminal — port picker shown.
const PORT_EXCLUDED := 7
## HTTP port held by a process we didn't spawn (no matching managed
## record). Plugin armed an adoption-confirmation watcher; if the foreign
## occupant turns out to be a compatible godot-ai server,
## `handle_server_version_verified` transitions to READY. If the
## adoption deadline expires without a connection, the watcher self-
## disarms but the state stays at FOREIGN_PORT — the dock keeps showing
## "port held by another process" until the user reloads. The version-
## check seam (separate from the adoption deadline) is what fires
## INCOMPATIBLE on a positive-but-mismatched handshake.
const FOREIGN_PORT := 8
## Static re-entrancy guard fired (`_server_started_this_session` was
## already true). The plugin is being re-enabled within the same editor
## session; the previous instance still owns the spawn. Terminal — does
## NOT block READY paths, just records that this enable cycle no-op'd.
const GUARDED := 9
## stop_server / prepare_for_update_reload in progress. Transitional —
## next state is STOPPED.
const STOPPING := 10
## stop_server completed; `_server_pid` reset to -1, port may or may
## not be free. From here a fresh `start_server` call moves back through
## SPAWNING / READY.
const STOPPED := 11

const _NAMES := {
	UNINITIALIZED: "uninitialized",
	SPAWNING: "spawning",
	READY: "ready",
	INCOMPATIBLE: "incompatible",
	CRASHED: "crashed",
	NO_COMMAND: "no_command",
	PORT_EXCLUDED: "port_excluded",
	FOREIGN_PORT: "foreign_port",
	GUARDED: "guarded",
	STOPPING: "stopping",
	STOPPED: "stopped",
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
	)


## True only for READY. Other "ok-ish" states (SPAWNING) are still in
## flight; READY is the only state where the plugin can treat the server
## as fully healthy.
static func is_healthy(state: int) -> bool:
	return state == READY


## True when the dock should consider the server unsuitable for client
## health checks (incompatible tool surface). Currently just INCOMPATIBLE
## — FOREIGN_PORT is transitional and may resolve to READY if the
## foreign occupant turns out to speak our handshake.
static func blocks_client_health(state: int) -> bool:
	return state == INCOMPATIBLE


## Transition validation table. Returns true when `from -> to` is a
## legal transition the lifecycle manager should accept. Illegal
## transitions are silently no-op'd at the call site (with a
## `push_warning` log) — this preserves the first-writer-wins contract
## that prevents a late CRASHED from the watch loop overwriting an
## earlier PORT_EXCLUDED diagnosis.
static func can_transition(from: int, to: int) -> bool:
	if from == to:
		return true
	## Stop is always legal — teardown / install reload short-circuits
	## any in-flight state.
	if to == STOPPING:
		return true
	if to == STOPPED and from == STOPPING:
		return true
	## STOPPED can also be reached directly when `_server_pid <= 0` and
	## stop_server early-returns; treat it as legal from any state to
	## keep the teardown path forgiving.
	if to == STOPPED:
		return true
	## STOPPED -> any (re-arm via restart paths).
	if from == STOPPED:
		return true
	## GUARDED is sticky for the rest of this enable cycle; only stop is
	## legal out of it. Already covered by the stop checks above.
	if from == GUARDED:
		return false
	## Terminal diagnoses freeze further forward transitions. Recovery
	## goes through STOPPING (covered above), so any other target is
	## rejected — this is the first-writer-wins contract.
	if (
		from == CRASHED
		or from == NO_COMMAND
		or from == PORT_EXCLUDED
		or from == INCOMPATIBLE
	):
		return false
	## UNINITIALIZED is the boot state — any target except STOPPING is
	## reachable directly (start_server's early branches set
	## terminal states without going through SPAWNING).
	if from == UNINITIALIZED:
		return true
	## In-flight forward transitions.
	match from:
		SPAWNING:
			return (
				to == READY
				or to == CRASHED
				or to == FOREIGN_PORT
				or to == INCOMPATIBLE
			)
		FOREIGN_PORT:
			return to == READY or to == INCOMPATIBLE
		READY:
			## Late incompatibility detection (e.g. version verifier
			## re-arms after a foreign-port reconnect that turns out
			## to be incompatible after all).
			return to == INCOMPATIBLE or to == CRASHED
		STOPPING:
			## Recovery rollback: kill-then-respawn paths that fail to
			## free the port re-latch INCOMPATIBLE (so the dock keeps
			## the diagnostic UI) or fall back to UNINITIALIZED (clean
			## baseline for a follow-up `_set_incompatible_server`).
			## STOPPING -> STOPPED is handled by the early checks above.
			return to == INCOMPATIBLE or to == UNINITIALIZED
	return false
