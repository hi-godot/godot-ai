@tool
class_name McpClientRefreshState
extends RefCounted

## State machine for the dock's client-status refresh sweep. Single
## source of truth — supersedes the seven booleans + deadline previously
## scattered across `mcp_dock.gd` (`_client_status_refresh_in_flight`,
## `_client_status_refresh_pending`, `_client_status_refresh_pending_force`,
## `_client_status_refresh_timed_out`, `_client_status_refresh_started_msec`,
## `_client_status_refresh_deferred_until_filesystem_ready`,
## `_client_status_refresh_deferred_force`,
## `_client_status_refresh_deferred_initial`,
## `_client_status_refresh_shutdown_requested`).
##
## The ints are stable for tests; reordering is a breaking change.

## No worker running, no pending request. Default state.
const IDLE := 0
## A refresh request landed but the editor filesystem is busy
## (`EditorInterface.get_resource_filesystem().is_scanning()` is true);
## the dock parks the request and retries on the next `_process` after
## the scan settles. Held alongside two flags (force / initial) for
## what kind of refresh to retry; those live next to the state, not
## inside it, because they're requests not state.
const DEFERRED_FOR_FILESYSTEM := 1
## Worker thread is alive and probing client status off-main. The
## dock paints "(checking...)" in the clients summary and accepts
## additional requests as `pending`.
const RUNNING := 2
## Worker has been alive past CLIENT_STATUS_REFRESH_TIMEOUT_MSEC. The
## dock paints "(client probe still running)" and a forced refresh is
## allowed to abandon the worker into the orphan list and start a new
## sweep. The state stays RUNNING after a forced abandon-and-restart.
const RUNNING_TIMED_OUT := 3
## `_exit_tree` / `_install_update` is draining workers. New refresh
## requests are rejected outright. Set once and not cleared (the dock
## instance is being torn down).
const SHUTTING_DOWN := 4

const _NAMES := {
	IDLE: "idle",
	DEFERRED_FOR_FILESYSTEM: "deferred_for_filesystem",
	RUNNING: "running",
	RUNNING_TIMED_OUT: "running_timed_out",
	SHUTTING_DOWN: "shutting_down",
}


static func name_of(state: int) -> String:
	return _NAMES.get(state, "unknown(%d)" % state)


## True when a worker thread should be alive in this state. Combined
## state — RUNNING or RUNNING_TIMED_OUT both have a worker running, but
## the timed-out flavor allows a force-refresh to abandon it.
static func has_worker_alive(state: int) -> bool:
	return state == RUNNING or state == RUNNING_TIMED_OUT


## True when the dock should reject new refresh spawns. Used by the
## focus-in / manual button / cooldown-timer entrypoints.
static func is_blocked_for_spawn(state: int) -> bool:
	return state == SHUTTING_DOWN


## True when the summary label should show the in-flight badge.
static func should_show_checking_badge(state: int) -> bool:
	return state == RUNNING or state == RUNNING_TIMED_OUT


## Transition table. Same shape as McpServerState — illegal transitions
## return false; callers `push_warning` and no-op.
static func can_transition(from: int, to: int) -> bool:
	if from == to:
		return true
	## Shutdown is sticky.
	if from == SHUTTING_DOWN:
		return false
	## Anything → SHUTTING_DOWN is legal (drain on _exit_tree / install).
	if to == SHUTTING_DOWN:
		return true
	match from:
		IDLE:
			return to == RUNNING or to == DEFERRED_FOR_FILESYSTEM
		DEFERRED_FOR_FILESYSTEM:
			## When the filesystem scan settles we either spawn a worker
			## (RUNNING) or roll back to IDLE if no rows need probing.
			return to == RUNNING or to == IDLE
		RUNNING:
			## Worker finishes -> IDLE. Worker outlives budget ->
			## RUNNING_TIMED_OUT. Forced respawn after orphan abandon
			## stays in RUNNING (covered by from == to above).
			return to == IDLE or to == RUNNING_TIMED_OUT
		RUNNING_TIMED_OUT:
			## Late-arriving worker result drops back to IDLE; forced
			## abandon-and-respawn drops back to RUNNING.
			return to == IDLE or to == RUNNING
	return false
