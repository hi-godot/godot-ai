@tool
class_name McpServerLifecycleManager
extends RefCounted

## Server spawn / stop / respawn / adopt / recover orchestration plus the
## update-reload handoff. Owns the server-state machine
## (`McpServerState`), version-check seam (`McpServerVersionCheck`),
## adoption metadata, and connection-blocked / dev-mismatch flags.
##
## State previously lived on plugin.gd; PR 6 (#297) moved it here so
## PR 7 (UpdateManager extraction) can absorb the same encapsulation
## pattern. The plugin still owns the physical editor surfaces
## (Connection, Dock, Timer, EditorSettings I/O) and exposes them via
## `_host.<method>()` shims; the test fixtures override those shims to
## drive the manager without touching the editor.
##
## `_host` is untyped to honor the self-update field-storage policy
## plugin.gd calls out near `_connection`.
var _host

const UvCacheCleanup := preload("res://addons/godot_ai/utils/uv_cache_cleanup.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")
const McpServerStateScript := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const McpStartupPathScript := preload("res://addons/godot_ai/utils/mcp_startup_path.gd")
const McpAdoptionLabelScript := preload("res://addons/godot_ai/utils/mcp_adoption_label.gd")
const McpServerVersionCheckScript := preload("res://addons/godot_ai/utils/server_version_check.gd")

# ---- State (owned here, was on plugin.gd through PR 5) ---------------

## Single source of truth for the server-spawn/adopt/version lifecycle.
## See `McpServerState` for the transition table.
var _server_state: int = McpServerStateScript.UNINITIALIZED

## OS-level state populated only when WE spawned the process.
var _server_pid: int = -1
## keep_server_on_exit (#800): whether the RUNNING server was launched with
## the keep-alive env opt-outs (no owner pid, NO_IDLE_EXIT staged). Editor
## teardown routes on this, never on the live setting — a server spawned
## without the opt-outs must die with the editor even if the user enabled
## the setting mid-session, or the owner-PID watchdog reaps it seconds
## later and the preserved record goes stale (the #774 scenario). Set at
## spawn, recovered from the managed-server record on adoption.
var _server_keep_alive := false
var _server_spawn_ms: int = 0
var _server_exit_ms: int = 0
## Elapsed-since-spawn at the first watch tick that saw the spawn PID dead, or
## 0 when it is alive / has been healed onto the real PID. Only meaningful
## while a Windows trampoline handoff is being waited out (#797): it preserves
## the true exit time so a diagnosis raised after the wait still reports when
## the process actually died. Reset per spawn alongside `_server_spawn_ms`.
var _spawn_dead_since_ms: int = 0

## Version metadata. `expected_version` is what the plugin shipped with;
## `actual_version` is what the live server reported via handshake_ack.
var _server_expected_version: String = ""
var _server_actual_version: String = ""
var _server_actual_name: String = ""

## Diagnostic + recovery flags surfaced to the dock via `get_status()`.
var _server_status_message: String = ""
## #647: when a post-crash probe pins the failure on a specific port held
## by a foreign process, this names that port (HTTP or WS) so the dock's
## status line and port-picker gating don't blame the wrong one. Zero when
## no conflict was diagnosed.
var _conflict_port: int = 0
var _can_recover_incompatible: bool = false
var _connection_blocked: bool = false

## One-shot guard for the stale-uvx-index recovery (#172). Reset at the
## top of `start_server` so each fresh spawn attempt gets its own
## refresh budget.
var _refresh_retried: bool = false

## One-shot guard for the spawn-lost-port-race re-adoption (see
## `_diagnose_spawn_fast_exit`). #805: the budget is per RECOVERY, not per
## walk — a walk the re-adopt arm itself triggered must NOT refresh it
## (`_readopt_walk_pending` skips the top-of-walk reset), or a flapping
## godot-ai occupant sustains spawn → fast-exit → re-walk forever. The
## budget refreshes on the paths that prove recovery: a fresh
## user/plugin-initiated walk, a successful `adopt_compatible_server`,
## or a spawn that survives to publish its pid-file.
var _readopt_after_spawn_exit_retried: bool = false

## #805: set by the re-adopt arm just before it re-runs `start_server`,
## consumed by the top of `_start_server_impl` to skip that walk's
## `_readopt_after_spawn_exit_retried` reset. Never true outside that
## one triggered walk.
var _readopt_walk_pending: bool = false

## Rounds of weak-proof (`status_name`-tier) recovery available against a
## brand-verified stale-VERSION godot-ai occupant. Zero by default: the
## startup walk may only kill via strong ownership proof. Armed by an
## explicit user action that already authorizes replacing the old backend —
## the post-self-update startup (`authorize_stale_recovery` from plugin.gd,
## consented by the Update click) and the dock's recovery click. This is
## what lets the walk finish an update against an attach-bridge-owned old
## server: bridges pinned to the previous version respawn it the moment it
## is killed, and each respawn is an external server with no strong proof,
## so without this budget every lost port race dead-ends in INCOMPATIBLE
## and the user is left toggling the plugin by hand. Never spent on a
## same-version or foreign occupant; each spent round re-proves brand at
## kill time. Reset on the proven recoveries — adoption and the verified
## compatible handshake — so leftover rounds can't authorize a kill in a
## later, unrelated episode. Pid-file publication deliberately does NOT
## reset it: the server writes that file before binding either port, so a
## bridge respawn can still steal the bind afterwards and the fast-exit
## needs its remaining rounds (#890 review P1).
var _stale_recovery_budget: int = 0

## Bounded deadline for the foreign-port adoption-confirmation watcher.
## Zero when disarmed.
var _adoption_watch_deadline_ms: int = 0

## Branch-tag from the most recent `start_server` walk. See
## `McpStartupPath`. Drives the startup-trace log.
var _startup_path: String = McpStartupPathScript.UNSET

## Version-check seam. Lazily constructed on `arm_version_check` so
## tests that exercise the manager without a connection don't have to
## stub it out.
var _version_check

## #678: when true, the blocking primitives on the startup path (port
## scrapes, per-PID brand shells, the HTTP status probe, kill + port-drain
## waits) run on a WorkerThreadPool thread while the main thread keeps
## pumping frames — the editor stays responsive during plugin init/reload
## on a contended port; the dock panel just arrives a beat later. The
## plugin enables this in production. Default false: unit tests (and any
## legacy caller) keep the historical fully-synchronous behavior, where
## the startup coroutines never actually suspend and call-then-assert
## still works.
var defer_blocking_work: bool = false

## Cancellation for in-flight async startup work: bumped by `stop_server`
## (and therefore by `_exit_tree` and update-reload prep), checked after
## every await so a suspended `start_server` can't resurrect state — or
## spawn a server — after teardown started.
var _async_generation: int = 0

## Re-entrancy guard: with startup a coroutine, a second `start_server`
## call (respawn watch, dock button) can land mid-flight.
var _start_in_flight: bool = false


func _init(host) -> void:
	_host = host


## The worker thread of the walk's current `_run_blocking` call, while it
## runs. `_invalidate_async_startup` JOINS it (bounded by the blocking
## op's own timeout) so no worker can still be executing a plugin method
## when `_exit_tree` frees the plugin — a mid-call free is use-after-free
## on the worker, which wedged the editor on macOS during rapid reload
## churn (main CI, post-#682). Null when no blocking work is in flight.
var _active_blocking_thread: Thread = null


## Run `work` off the main thread and suspend until it completes (#678).
## Falls back to inline execution when `defer_blocking_work` is off, or
## when no SceneTree is available to pump frames against.
##
## Uses a dedicated Thread (the dock's #238/#239 worker pattern) rather
## than WorkerThreadPool: `wait_to_finish()` hands the return value back
## without a shared mutable container, and this plugin has already seen
## WorkerThreadPool tasks SIGABRT under concurrency (see the notes in
## script_handler.gd / filesystem_handler.gd). `wait_to_finish` after
## `is_alive()` goes false joins an already-dead thread, so it never
## blocks the main thread.
##
## Returns null (without joining) when `_invalidate_async_startup` took
## ownership of the thread mid-flight — the walk is stale at that point
## and must bail. Callers therefore assign the result to an untyped
## local and bail on `_async_stale(...) or result == null` BEFORE any
## typed use — a typed assignment (or a bool()/int() constructor, both
## of which have no Nil form) trips on the null first. The null check is
## not redundant with the generation check: a caller that loses the slot
## without a generation bump — an invariant violation, but exactly what
## a concurrent fire-and-forget `_run_blocking` user produces — must
## still unwind instead of crashing on the Nil.
func _run_blocking(work: Callable) -> Variant:
	if not defer_blocking_work:
		return work.call()
	var tree := Engine.get_main_loop()
	if not (tree is SceneTree):
		return work.call()
	var thread := Thread.new()
	if thread.start(work) != OK:
		return work.call()
	_active_blocking_thread = thread
	while thread.is_alive():
		await (tree as SceneTree).process_frame
		if _active_blocking_thread != thread:
			## Teardown/invalidation already joined this thread; the
			## result belongs to a cancelled walk. All resumes and joins
			## happen on the main thread, so this check cannot race.
			return null
	if _active_blocking_thread != thread:
		return null
	_active_blocking_thread = null
	return thread.wait_to_finish()


func _async_stale(generation: int) -> bool:
	return generation != _async_generation


## Cancel any in-flight async startup walk AND release the re-entrancy
## guard so the very next `start_server()` call walks fresh (#682 review).
## Every one-shot kill-and-restart path must call this before its
## follow-up start: without the generation bump the suspended walk
## resumes against post-kill reality (stale live-status snapshots), and
## without releasing the guard the follow-up start is silently swallowed.
## The cancelled walk unwinds via its post-await staleness checks and
## must NOT clear the guard itself — a newer walk may already own it
## (see the generation check in `start_server`).
##
## Also JOINS the walk's in-flight worker thread (bounded by that op's
## own timeout: lsof/netstat scrape, ≤800ms status probe, or kill +
## port-drain wait). `stop_server` runs this from `_exit_tree`, so once
## it returns no worker thread can still be executing a method of the
## plugin that is about to be freed — the macOS reload-churn wedge.
func _invalidate_async_startup() -> void:
	_async_generation += 1
	_start_in_flight = false
	var thread := _active_blocking_thread
	_active_blocking_thread = null
	if thread != null:
		thread.wait_to_finish()


# ---- Public state accessors --------------------------------------------

func get_state() -> int:
	return _server_state


func get_status_dict() -> Dictionary:
	return {
		"state": _server_state,
		"exit_ms": _server_exit_ms,
		"actual_name": _server_actual_name,
		"actual_version": _server_actual_version,
		"expected_version": _server_expected_version,
		"message": _server_status_message,
		"can_recover_incompatible": _can_recover_incompatible,
		"connection_blocked": _connection_blocked,
		"conflict_port": _conflict_port,
		"keep_alive": _server_keep_alive,
		"stale_recovery_budget": _stale_recovery_budget,
	}


## Arm the bounded stale-occupant recovery (see `_stale_recovery_budget`).
## Called before the startup walk when a completed self-update is detected
## (plugin.gd) and by the dock recovery click — both are user actions that
## already authorize replacing the previous-version backend. `max()` so a
## click landing on an already-armed post-update episode never shrinks the
## remaining rounds.
func authorize_stale_recovery(rounds: int = 2) -> void:
	_stale_recovery_budget = maxi(_stale_recovery_budget, rounds)


## True when a spent round of stale-occupant recovery may target the live
## occupant: budget remains and the occupant is a VERIFIED godot-ai whose
## version differs from ours. An empty version (foreign or unverified
## occupant) never qualifies — those stay on the strong-proof-only path.
func _stale_recovery_available(live_version: String, expected_version: String) -> bool:
	if _stale_recovery_budget <= 0:
		return false
	if live_version.is_empty():
		return false
	return live_version != expected_version


func get_server_pid() -> int:
	return _server_pid


func get_startup_path() -> String:
	return _startup_path


func get_adoption_watch_deadline_ms() -> int:
	return _adoption_watch_deadline_ms


func is_awaiting_server_version() -> bool:
	return _version_check != null and _version_check.is_active()


func is_connection_blocked() -> bool:
	return _connection_blocked


# ---- State-machine entry points ---------------------------------------

## Validated transition. Returns true on success; false (and logs a
## warning) when the transition is illegal under `McpServerState`'s
## table. Callers that need first-writer-wins among terminal diagnoses
## use `set_terminal_diagnosis` instead — that helper silently no-ops
## without warning when the diagnosis would be a regression.
func transition_state(target: int) -> bool:
	if _server_state == target:
		return true
	if not McpServerStateScript.can_transition(_server_state, target):
		push_warning(
			"MCP | rejected illegal state transition %s -> %s"
			% [
				McpServerStateScript.name_of(_server_state),
				McpServerStateScript.name_of(target),
			]
		)
		return false
	_server_state = target
	return true


## First-writer-wins mutator for terminal diagnoses (CRASHED,
## NO_COMMAND, PORT_EXCLUDED, INCOMPATIBLE, FOREIGN_PORT). Used during
## spawn to make sure a late watch-loop CRASHED doesn't clobber an
## earlier proactive PORT_EXCLUDED. Silent no-op when the current state
## is already a terminal diagnosis — the existing diagnosis is kept.
func set_terminal_diagnosis(target: int) -> bool:
	if not McpServerStateScript.is_terminal_diagnosis(target):
		push_warning(
			"MCP | set_terminal_diagnosis called with non-terminal %s"
			% McpServerStateScript.name_of(target)
		)
		return false
	if McpServerStateScript.is_terminal_diagnosis(_server_state):
		return false
	_server_state = target
	return true


# ---- Adoption confirmation watcher -------------------------------------

## Arm the FOREIGN_PORT adoption-confirmation watcher. SPAWN_GRACE_MS
## ahead of `now`; `tick_adoption_watch` self-disarms after this expires
## so per-frame cost drops back to zero on a permanent foreign occupant.
func arm_adoption_watch() -> void:
	_adoption_watch_deadline_ms = (
		Time.get_ticks_msec() + int(_host.SPAWN_GRACE_MS)
	)


func tick_adoption_watch(now_msec: int) -> void:
	if _adoption_watch_deadline_ms > 0 and now_msec >= _adoption_watch_deadline_ms:
		_adoption_watch_deadline_ms = 0


# ---- Server version-check seam ----------------------------------------

func arm_version_check(connection, expected_version: String) -> void:
	if _version_check == null:
		_version_check = McpServerVersionCheckScript.new(self)
	var expected := _resolve_expected_version(expected_version)
	_server_expected_version = expected
	_version_check.arm(connection, expected)


func disarm_version_check() -> void:
	if _version_check != null:
		_version_check.disarm()


func get_version_check():
	return _version_check


## Resolves a possibly-empty expected version to the plugin's shipping
## version. Manager methods that are called via test fixtures may
## receive an empty string when the test never seeded
## `_server_expected_version`, so this is the one place that fallback
## lives.
func _resolve_expected_version(supplied: String) -> String:
	if not supplied.is_empty():
		return supplied
	return _expected_server_version()


func _expected_server_version() -> String:
	return ClientConfigurator.get_plugin_version()


## Called by McpServerVersionCheck when handshake_ack carries a version
## string. Decides compatible vs incompatible and transitions the state.
func handle_server_version_verified(expected_version: String, version: String) -> void:
	_server_actual_name = "godot-ai"
	_server_actual_version = version
	var expected := _resolve_expected_version(expected_version)
	_server_expected_version = expected
	var compatibility := _server_version_compatibility(version, expected)
	if compatibility.get("compatible", false):
		_can_recover_incompatible = false
		## A verified compatible handshake ends any stale-recovery episode —
		## leftover authorized rounds must not survive into a later walk.
		_stale_recovery_budget = 0
		## Foreign-port and post-spawn handshakes both clear to READY
		## on a successful handshake. Late re-arms from READY also land
		## here and self-confirm.
		transition_state(McpServerStateScript.READY)
		_host._update_process_enabled()
		return
	var live := {"version": version, "status_code": 200, "name": "godot-ai"}
	## Connection propagation + version-check disarm + process re-evaluation
	## all live inside _set_incompatible_server now (#691) so the startup-walk
	## recovery-failure and force-restart-failure paths get them too.
	_set_incompatible_server(live, expected, ClientConfigurator.http_port())
	## Post-update the WebSocket usually reaches the OLD backend before the
	## startup walk finishes its probes — this verdict then cancels the walk
	## (the `_invalidate_async_startup` in `_set_incompatible_server`'s
	## fire-and-forget arm) and used to strand the update at INCOMPATIBLE
	## even though the Update click already authorized replacing that
	## backend. With authorized rounds left and a VERIFIED stale version,
	## spend one and fire the same recovery flow the dock's Restart click
	## runs — via the plugin wrapper so the connection unblocks on success,
	## with `user_initiated=false` so the trigger can only spend, never
	## re-arm. The INCOMPATIBLE latch it gates on is synchronous: the
	## `_set_incompatible_server` head above runs before its first await.
	if _stale_recovery_available(version, expected) and _host.has_method("recover_incompatible_server"):
		_stale_recovery_budget -= 1
		print(
			"MCP | stale godot-ai v%s answered the WS handshake — replacing it (update/recovery authorized, %d retry round(s) left)"
			% [version, _stale_recovery_budget]
		)
		## Fire-and-forget coroutine: this verdict lands on the main thread
		## from `_process`, and the recovery owns the flow from here
		## (mirroring the recovery click).
		_host.recover_incompatible_server(false)


func handle_server_version_unverified(expected_version: String) -> void:
	var expected := _resolve_expected_version(expected_version)
	_server_expected_version = expected
	var live := {"version": "", "status_code": 0, "error": "missing_handshake_ack"}
	_set_incompatible_server(live, expected, ClientConfigurator.http_port())


# ---- Compatibility / version helpers (pure) ---------------------------

## Plugin and server speak a single, version-coupled protocol — new commands
## and response fields are added together. Treating dev-mode mismatches as
## "compatible" silently adopts a stale server whose code may differ from the
## live source tree (e.g. another worktree on a different branch holding
## port 8000). Strict match in all modes routes mismatches through
## `recover_strong_port_occupant`, which kills the branded port-holder and
## lets `start_server` spawn fresh against the current source.
static func _server_version_compatibility(
	actual_version: String,
	expected_version: String
) -> Dictionary:
	if actual_version.is_empty():
		return {"compatible": false, "reason": "unknown"}
	if actual_version == expected_version:
		return {"compatible": true, "reason": "exact"}
	return {"compatible": false, "reason": "version_mismatch"}


static func _server_status_compatibility(
	actual_version: String,
	expected_version: String,
	actual_ws_port: int,
	expected_ws_port: int,
) -> Dictionary:
	var version_result := _server_version_compatibility(actual_version, expected_version)
	if not bool(version_result.get("compatible", false)):
		return version_result
	if actual_ws_port != expected_ws_port:
		return {"compatible": false, "reason": "ws_port_mismatch"}
	return version_result


static func _managed_record_has_version_drift(record_version: String, current_version: String) -> bool:
	return not record_version.is_empty() and record_version != current_version


# ---- Incompatible-server bookkeeping ----------------------------------

func _set_incompatible_server(
	live: Dictionary,
	expected_version: String,
	port: int,
	caller_owns_worker_slot := false
) -> void:
	## Latches the incompatible diagnosis into manager state and asks
	## the dock to re-sweep client rows so they don't show stale green.
	## Threads the caller's `live` snapshot through the recovery proof
	## helper so we don't double-probe the port (~500ms each).
	##
	## Coroutine (#712): the recovery-proof evaluation (port scrapes +
	## per-PID brand shells) and the free-port bind probes run via
	## `_run_blocking` — these fire in exactly the contended/crashed
	## scenarios #678 de-blocked, so they must not stall the main thread
	## either. Everything user-visible (status message, connection block,
	## version-check disarm) is latched synchronously before the first
	## await; only the recovery verdict and the suggested-port diagnostic
	## arrive with the worker.
	##
	## `_run_blocking` tracks a single active worker, so the tail below
	## needs exclusive ownership of that slot. The startup walk awaits
	## this call with `caller_owns_worker_slot=true` — it already owns the
	## slot and serializes the tail behind its own blocking ops. Sync
	## callers (the handshake verdicts via `handle_server_version_*`, the
	## force-restart failure arm) fire-and-forget the tail and leave the
	## flag false, so the head takes ownership for them: a handshake
	## verdict lands from `_process` while a startup walk can still be
	## suspended in `_run_blocking`, and starting the tail's worker then
	## would steal the slot — the walk's op is orphaned from the
	## `_invalidate_async_startup` join guarantee and its resume gets a
	## null without a generation bump (the Nil-into-Dictionary crash on
	## the incompatible-occupant walk). Cancelling the walk first mirrors
	## the recovery click (#712): the diagnosis in hand supersedes
	## whatever the walk was still probing for.
	if not caller_owns_worker_slot:
		_invalidate_async_startup()
	transition_state(McpServerStateScript.INCOMPATIBLE)
	_connection_blocked = true
	_server_expected_version = expected_version
	_server_actual_name = str(live.get("name", ""))
	_server_actual_version = _live_version_for_message(live)
	_server_status_message = _incompatible_server_message(
		live, expected_version, port, int(_host._resolved_ws_port)
	)
	## Conservative default until the off-thread proof lands: the dock
	## paints "not recoverable" rather than offering a kill we have not
	## yet proven ownership for.
	_can_recover_incompatible = false
	_host._refresh_dock_client_statuses()
	## Propagate the verdict to the live connection (#691). Pre-#678 the
	## startup walk finished synchronously before `_connection` existed, so
	## plugin.gd captured the INCOMPATIBLE verdict when constructing it.
	## Post-#678 the walk suspends at its first `_run_blocking` and the
	## plugin snapshots the pre-walk defaults (`connect_blocked=false`) — so
	## a verdict landing later (startup-walk recovery failure, handshake
	## mismatch, force-restart failure) must reach the connection here, or
	## it keeps dialing the WS port forever. Also disarm the version check:
	## the diagnosis already landed, so leaving the check armed keeps
	## per-frame `_process` on for the plugin's whole lifetime.
	if _host._connection != null:
		_host._connection.connect_blocked = true
		_host._connection.connect_block_reason = _server_status_message
		_host._connection.disconnect_from_server()
	disarm_version_check()
	_host._update_process_enabled()

	## Off-thread recovery proof (#712), mirroring recover_strong_port_occupant:
	## the EditorSettings record is read on the main thread up front and
	## injected as record_override — EditorSettings is main-thread-only.
	var async_gen := _async_generation
	var record: Dictionary = _host._read_managed_server_record()
	var proof_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return {"proof": "", "pids": []}
		return _host._evaluate_recovery_port_occupant_proof(port, live, record)
	)
	if _async_stale(async_gen) or proof_result == null:
		return
	var proof: Dictionary = proof_result
	var proof_name := str(proof.get("proof", ""))
	_can_recover_incompatible = not proof_name.is_empty()
	print("MCP | proof: %s" % (proof_name if _can_recover_incompatible else "(none)"))
	if not _can_recover_incompatible:
		## Non-recoverable: a foreign / unprovable occupant holds the port and
		## we have no ownership proof, so we must NOT kill it — surface a
		## concrete free port the user can switch to instead (the same hint
		## the dock crash body renders). Logging it to the editor output also
		## lets `ci-stale-server-smoke --mode foreign` assert this upstream
		## classification from CI. Reservation-aware on Windows; the bind
		## probes behind suggest_free_port also run off-thread (#712).
		var suggested_result: Variant = await _run_blocking(func() -> Variant:
			return ClientConfigurator.suggest_free_port(port + 1)
		)
		if _async_stale(async_gen) or suggested_result == null:
			return
		print("MCP | port %d occupant not recoverable (no ownership proof); suggested free port %d (set godot_ai/http_port)" % [port, int(suggested_result)])
	## Second sweep so the dock's recovery affordance reflects the verdict
	## that just landed.
	_host._refresh_dock_client_statuses()


static func _incompatible_server_message(
	live: Dictionary,
	expected_version: String,
	port: int,
	expected_ws_port: int
) -> String:
	var version := _live_version_for_message(live)
	var actual_ws_port := _live_ws_port_for_message(live)
	## `package_path` is a v2.4.4+ field — older servers omit it. Suffix
	## the message with "(loaded from <path>)" when present so the user
	## can tell *which* `src/godot_ai/` is serving the port without
	## walking the process tree. See #416.
	var package_path := _live_package_path_for_message(live)
	var path_suffix := " (loaded from %s)" % package_path if not package_path.is_empty() else ""
	## After a plugin update, the usual occupant is a backend kept alive by
	## AI-client attach bridges still pinned to the previous version (their
	## leases outrank us — #669/#839, we must not kill it). Name that repair
	## first; "stop the old server" alone reads as a dead end when the server
	## respawns the moment the user kills it.
	var repair := (
		"If AI-client attach bridges are keeping it alive, run Configure all to "
		+ "repin them, then restart those client apps — the old server exits on "
		+ "its own. Otherwise stop it manually or change both HTTP and WS ports."
	)
	if not version.is_empty():
		if actual_ws_port > 0 and actual_ws_port != expected_ws_port:
			return (
				"Port %d is occupied by godot-ai server v%s using WS port %d%s; "
				+ "plugin expects v%s with WS port %d. %s"
			) % [port, version, actual_ws_port, path_suffix, expected_version, expected_ws_port, repair]
		return (
			"Port %d is occupied by godot-ai server v%s%s; plugin expects v%s. %s"
		) % [port, version, path_suffix, expected_version, repair]
	var status_code := int(live.get("status_code", 0))
	if status_code > 0:
		return (
			"Port %d is occupied by an unverified server (status endpoint returned HTTP %d); "
			+ "plugin expects godot-ai v%s. Stop the other server or change both HTTP and WS ports."
		) % [port, status_code, expected_version]
	return (
		"Port %d is occupied by another process; plugin expects godot-ai v%s. "
		+ "Stop the other process or change both HTTP and WS ports."
	) % [port, expected_version]


static func _live_status_identifies_godot_ai(live: Dictionary) -> bool:
	return str(live.get("name", "")) == "godot-ai"


static func _live_version_for_message(live: Dictionary) -> String:
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return ""
	return str(live.get("version", ""))


static func _live_ws_port_for_message(live: Dictionary) -> int:
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return 0
	return int(live.get("ws_port", 0))


static func _live_package_path_for_message(live: Dictionary) -> String:
	## Only trust the path when the live snapshot confirms a godot-ai
	## server — a probe of some unrelated HTTP service could in theory
	## return a `package_path` JSON field, and we don't want to mislabel
	## that as "godot-ai loaded from …" in the incompatible banner.
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return ""
	return str(live.get("package_path", ""))


# ---- start_server / spawn watch / respawn -----------------------------


## Sets GODOT_AI_DISABLE_TELEMETRY in the process environment for the
## upcoming OS.create_process call if: (a) neither GODOT_AI_DISABLE_TELEMETRY
## nor DISABLE_TELEMETRY is already set to a *truthy* value (a falsey "0" does
## NOT count — it must not suppress a dock UI opt-out), and (b) the effective
## McpSettings.telemetry_enabled() is false. Returns true if the var was
## injected so the caller can unset it after spawning.
func _inject_telemetry_env() -> bool:
	## If telemetry is already disabled by a *truthy* env var, leave the env as
	## the user/CI set it — the post-spawn cleanup unsets what we inject, so
	## injecting here would strip their own var from the editor process. A
	## *falsey* value (e.g. DISABLE_TELEMETRY=0) must NOT count as "handled":
	## fall through so a dock UI opt-out still reaches the spawned server. The
	## truthy test mirrors McpSettings.telemetry_enabled() and the Python server.
	if McpSettings.env_truthy("GODOT_AI_DISABLE_TELEMETRY") or McpSettings.env_truthy("DISABLE_TELEMETRY"):
		return false
	if not McpSettings.telemetry_enabled():
		OS.set_environment("GODOT_AI_DISABLE_TELEMETRY", "true")
		return true
	return false


## Set GODOT_AI_OWNER_PID to this editor's PID for the next OS.create_process,
## so the spawned server can self-reap if this editor crashes. Returns true if
## set (caller must unset right after spawning — keep it out of the persistent
## editor env). No-op on Windows, where the server's reaper is disabled.
func _set_owner_pid_env() -> bool:
	if OS.get_name() == "Windows":
		return false
	## keep_server_on_exit (#800): a server meant to outlive editors must not
	## self-reap when this editor dies — don't hand it an owner pid at all.
	if ClientConfigurator.keep_server_on_exit():
		return false
	OS.set_environment("GODOT_AI_OWNER_PID", str(OS.get_process_id()))
	return true


## Mark the next OS.create_process as plugin-spawned so the server arms its
## session-idle self-terminate backstop (#498): with zero editor sessions for
## a grace window, it exits on its own. Unlike the owner-PID reaper this is
## pure session-count on the server side, so it is set on EVERY platform —
## including Windows, where owner-PID is skipped; this marker is what finally
## gives Windows orphan coverage (#497). Same env-channel rationale and same
## tight scoping as _set_owner_pid_env: callers unset it right after spawning
## so a later manually-started dev server can never inherit it and idle-kill
## itself.
func _set_plugin_spawned_env() -> void:
	OS.set_environment("GODOT_AI_PLUGIN_SPAWNED", "1")


## keep_server_on_exit (#800): opt the spawned server out of the
## session-idle self-terminate backstop (#498) via its existing
## GODOT_AI_NO_IDLE_EXIT escape hatch — a keep-alive server sits at zero
## sessions between editor runs by design, which is exactly what the
## backstop reaps. Returns true if set (same tight scoping as
## _set_owner_pid_env: callers unset right after spawning, and only when
## WE set it, so a user's own NO_IDLE_EXIT env is never stripped).
func _set_keep_alive_env() -> bool:
	if not ClientConfigurator.keep_server_on_exit():
		return false
	OS.set_environment("GODOT_AI_NO_IDLE_EXIT", "1")
	return true


## Generate a fresh per-launch WS handshake auth token (#690) and stage it
## in the env for the next OS.create_process, same channel and same tight
## scoping as _set_owner_pid_env (callers unset right after spawning — the
## secret must not linger in the editor env). The caller hands the returned
## token to the host on successful spawn so the connection echoes it in the
## handshake and the managed-server record persists it across reloads.
func _set_ws_token_env() -> String:
	var token := Crypto.new().generate_random_bytes(32).hex_encode()
	OS.set_environment("GODOT_AI_WS_TOKEN", token)
	return token


## Branch table (recorded version is the "is this ours?" signal — uvx
## launcher PIDs go stale; #135/#137):
##   port free                                -> spawn fresh, record PID
##   port in use, record matches + live ok   -> adopt port owner (heals PID)
##   port in use, record drifts              -> kill owner + respawn
##   port in use, no verified live match     -> block adoption + warn
##
## #678: this is a coroutine in production (`defer_blocking_work`) — the
## port scrapes, status probes, and kill-drain waits run off the main
## thread and the state machine resumes between frames, so the editor
## stays responsive when the port is contended. With the flag off (unit
## tests) nothing suspends and the call completes synchronously.
func start_server() -> void:
	if _start_in_flight:
		return
	_start_in_flight = true
	var gen := _async_generation
	await _start_server_impl(gen)
	## Only release the guard if this walk is still the current one — a
	## cancelled (stale) walk unwinding here must not clobber the guard a
	## newer walk armed after `_invalidate_async_startup`.
	if gen == _async_generation:
		_start_in_flight = false
		## Walk-completion continuation lives HERE — on the RefCounted
		## manager, kept alive by its own suspended state — never on the
		## plugin: resuming a coroutine of a freed Node errors out, and
		## reload churn frees plugin instances while walks are suspended.
		if is_instance_valid(_host) and _host.has_method("_finish_startup_trace_after_walk"):
			_host._finish_startup_trace_after_walk()


func _start_server_impl(async_gen: int) -> void:
	if _host._server_started_this_session:
		## Static flag persists across disable/enable cycles in one editor
		## session — re-entrant spawn guard for plugin-reload-during-update.
		_startup_path = McpStartupPathScript.GUARDED
		transition_state(McpServerStateScript.GUARDED)
		return

	_refresh_retried = false
	if _readopt_walk_pending:
		## #805: this walk was triggered by the fast-exit re-adopt arm.
		## Keep the spent budget: if this walk ends up spawning and that
		## spawn fast-exits against a live godot-ai again, the occupant is
		## flapping and the diagnosis must latch terminal instead of
		## re-walking forever. Recovery paths (adoption, healthy spawn)
		## refresh the budget explicitly.
		_readopt_walk_pending = false
	else:
		_readopt_after_spawn_exit_retried = false
	_conflict_port = 0

	var port := ClientConfigurator.http_port()
	var ws_port := ClientConfigurator.ws_port()
	var current_version := _expected_server_version()
	_server_expected_version = current_version

	## The worker closures re-check the host: the plugin can be freed while
	## a bounded shell probe is still running, and the generation check only
	## protects state after resume, not calls inside the task (#682 review).
	var port_in_use_result: Variant = await _run_blocking(func() -> Variant:
		return is_instance_valid(_host) and _host._is_port_in_use(port)
	)
	if _async_stale(async_gen) or port_in_use_result == null:
		return
	var port_in_use := bool(port_in_use_result)
	if not port_in_use:
		## #745: after an editor crash (or under multi-editor churn) the
		## managed server keeps running, yet the bind probe can still say
		## "free" (Windows lets a SO_REUSEADDR bind succeed over a live
		## listener; the scrape fallback can fail transiently). The HTTP
		## status probe is the authoritative tie-breaker and runs
		## UNCONDITIONALLY: the pid-file evidence gate that used to guard it
		## goes stale exactly when it's needed most — same-named test
		## projects share one app_userdata dir, so another editor's walk can
		## clear or overwrite the pid-file, and blind-spawning here produced
		## the reproduced duplicate-spawn + 4003 token loop. A live godot-ai
		## answer forces the adopt/recover branch below; an unresponsive
		## port falls through to the normal spawn path at the cost of one
		## fast connection-refused probe (off-thread in production).
		var evidence_result: Variant = await _run_blocking(func() -> Variant:
			if not is_instance_valid(_host):
				return {}
			return _host._probe_live_server_status_for_port(port)
		)
		if _async_stale(async_gen) or evidence_result == null:
			return
		var evidence: Dictionary = evidence_result
		if _live_status_identifies_godot_ai(evidence):
			port_in_use = true
	if port_in_use:
		var record: Dictionary = _host._read_managed_server_record()
		var record_version := str(record.get("version", ""))
		var record_ws_port := int(record.get("ws_port", 0))
		_host._set_resolved_ws_port(PortResolver.resolved_ws_port_for_existing_server(
			record_ws_port,
			record_version,
			current_version,
			int(_host._resolve_ws_port())
		))
		ws_port = int(_host._resolved_ws_port)
		## Untyped first: a cancelled walk gets null back (see _run_blocking)
		## and must reach the staleness check before any typed cast.
		var live_result: Variant = await _run_blocking(func() -> Variant:
			if not is_instance_valid(_host):
				return {}
			return _host._probe_live_server_status_for_port(port)
		)
		if _async_stale(async_gen) or live_result == null:
			return
		var live: Dictionary = live_result
		var live_version := str(_host._verified_status_version(live))
		var live_ws_port := int(_host._verified_status_ws_port(live))
		var compatibility: Dictionary = _server_status_compatibility(
			live_version,
			current_version,
			live_ws_port,
			ws_port,
		)
		if compatibility.get("compatible", false):
			_server_actual_name = "godot-ai"
			_server_actual_version = live_version
			_can_recover_incompatible = false
			## A matching version is compatibility evidence, not ownership
			## evidence (#759/#764). A stale EditorSettings record can name a
			## dead PID while an unrelated compatible server owns the port.
			## Retain managed ownership only when the recorded PID is itself
			## the live, branded listener.
			var adoption_proof_result: Variant = await _run_blocking(func() -> Variant:
				if not is_instance_valid(_host):
					return {"proof": "", "pids": []}
				return _host._evaluate_strong_port_occupant_proof(port, live, record)
			)
			if _async_stale(async_gen) or adoption_proof_result == null:
				return
			var adoption_proof: Dictionary = adoption_proof_result
			var proof_pids: Array[int] = []
			proof_pids.assign(adoption_proof.get("pids", []))
			var owner := int(proof_pids[0]) if not proof_pids.is_empty() else 0
			var record_owns_listener := str(adoption_proof.get("proof", "")) == "managed_record"
			var owner_label := adopt_compatible_server(
				record_version,
				current_version,
				owner,
				record_owns_listener
			)
			_host._server_started_this_session = true
			_startup_path = McpStartupPathScript.ADOPTED
			transition_state(McpServerStateScript.READY)
			print(_compatible_adoption_log_message(
				owner_label,
				int(_server_pid),
				owner,
				str(_server_actual_version),
				live_ws_port,
				current_version
			))
			return
		if bool(_managed_record_has_version_drift(record_version, current_version)):
			print("MCP | managed server v%s does not match plugin v%s, restarting"
				% [record_version, current_version])
		## Forward `live` so the recovery proof helper reuses our snapshot.
		## The kill invalidates it, so the failure arm re-probes below.
		var recovered: bool = await recover_strong_port_occupant(port, 3.0, live)
		if _async_stale(async_gen):
			return
		if not recovered and _stale_recovery_available(live_version, current_version):
			## Post-update / recovery-click episode: the occupant is a verified
			## stale-VERSION godot-ai (typically the previous release kept alive
			## — or just respawned — by attach bridges still pinned to it) and a
			## user action already authorized replacing it. Strong proof cannot
			## exist for that server (external adoption dropped record and
			## pid-file by design), so spend one bounded round of weak-proof
			## recovery instead of latching INCOMPATIBLE and asking the user to
			## click through the replacement by hand.
			_stale_recovery_budget -= 1
			print(
				"MCP | stale godot-ai v%s holds port %d — replacing it (update/recovery authorized, %d retry round(s) left)"
				% [live_version, port, _stale_recovery_budget]
			)
			recovered = await recover_stale_port_occupant(port, 3.0)
			if _async_stale(async_gen):
				return
		if not recovered:
			_host._server_started_this_session = true
			var post_recovery_result: Variant = await _run_blocking(func() -> Variant:
				if not is_instance_valid(_host):
					return {}
				return _host._probe_live_server_status_for_port(port)
			)
			if _async_stale(async_gen) or post_recovery_result == null:
				return
			var post_recovery_live: Dictionary = post_recovery_result
			## Awaited with caller_owns_worker_slot=true (#712): the
			## diagnosis tail runs its own _run_blocking proof, and the walk
			## stays the single owner of the active-worker slot by
			## serializing that tail behind this await instead of letting it
			## re-take the slot. The status message is latched before the
			## tail's first await, so the push_warning below reads the final
			## text either way.
			await _set_incompatible_server(post_recovery_live, current_version, port, true)
			if _async_stale(async_gen):
				return
			_startup_path = McpStartupPathScript.INCOMPATIBLE
			push_warning(str(_server_status_message))
			return
	else:
		_startup_path = McpStartupPathScript.FREE

	_host._set_resolved_ws_port(_host._resolve_ws_port())
	ws_port = _host._resolved_ws_port

	_host._startup_trace_count("server_command_discovery")
	## CLI-finder discovery shells out (which/where, login shell) on cache
	## misses — the same #238/#239 family the dock already runs off-thread.
	var server_cmd_result: Variant = await _run_blocking(func() -> Variant:
		return ClientConfigurator.get_server_command()
	)
	if _async_stale(async_gen) or server_cmd_result == null:
		return
	var server_cmd: Array = server_cmd_result
	if server_cmd.is_empty():
		set_terminal_diagnosis(McpServerStateScript.NO_COMMAND)
		_startup_path = McpStartupPathScript.NO_COMMAND
		push_warning("MCP | could not find server command")
		return

	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array(_host._build_server_flags(port, ws_port))

	## Wipe any stale pid-file so a failed launch can't leave last
	## session's PID for `_find_managed_pid` to read.
	_host._clear_pid_file()

	## Proactive Windows port-reservation check (#146) — bind would
	## fail silently with WinError 10013 inside a Hyper-V / WSL2 /
	## Docker exclusion range; netstat shows nothing.
	if WindowsPortReservation.is_port_excluded(port):
		_host._server_started_this_session = true
		set_terminal_diagnosis(McpServerStateScript.PORT_EXCLUDED)
		_startup_path = McpStartupPathScript.RESERVED
		push_warning("MCP | port %d is reserved by Windows (Hyper-V / WSL2 / Docker)" % port)
		return

	## ---- Spawn-time env-mutation window (#691) -------------------------
	## From here to the post-spawn unsets below, the editor's process-global
	## environment is mutated around OS.create_process (which has no
	## per-child env parameter). Two invariants keep this safe:
	## 1. The window is SYNCHRONOUS main-thread code — no `await` between
	##    the first setenv and the last unsetenv — and worker dispatch also
	##    only happens on the main thread, so no new worker can start inside
	##    the window.
	## 2. Already-running workers never call OS.get_environment: every env
	##    read reachable from a worker (path templates, config_home_override,
	##    CLI finder, mode_override/startup-trace) routes through
	##    McpPathTemplate.env_lookup, which serves worker threads from a
	##    main-thread-warmed snapshot. A concurrent glibc getenv during
	##    setenv can return a freed pointer — process-fatal.
	## Residual (accepted): a worker's own OS.execute child (CLI status
	## probe) launched while this window is open inherits the temp vars —
	## rare, and tame next to the crash class above.
	var injected_telemetry_env := _inject_telemetry_env()

	## PYTHONPATH handling for dev checkouts: when the editor is launched
	## against a worktree whose `src/godot_ai/__version__` differs from the
	## root repo's editable install, the dev-venv python's `sitecustomize`
	## adds the *root repo's* `src/` to `sys.path`. The spawned server then
	## reports the root repo's version, the plugin's compatibility check
	## flags it as incompatible, and the user gets a Restart-Server loop
	## with no exit. `start_dev_server` already prepends the worktree's
	## `src/` for its --reload spawn; mirror that here for the auto-spawn
	## path so the same worktree-vs-root version skew is impossible. Gated
	## on `is_dev_checkout()` so production user installs (no nearby `src/`)
	## are untouched. See #418.
	var worktree_src := ""
	var prev_pythonpath := ""
	var pythonpath_set := false
	if ClientConfigurator.is_dev_checkout():
		worktree_src = ClientConfigurator.find_worktree_src_dir(
			ProjectSettings.globalize_path("res://")
		)
		if not worktree_src.is_empty():
			prev_pythonpath = OS.get_environment("PYTHONPATH")
			var sep := ";" if OS.get_name() == "Windows" else ":"
			var new_pp := (
				worktree_src
				if prev_pythonpath.is_empty()
				else worktree_src + sep + prev_pythonpath
			)
			OS.set_environment("PYTHONPATH", new_pp)
			pythonpath_set = true

	## Tell the spawned server which editor owns it so it can self-reap if we
	## die without a clean stop_server (crash / hard-kill). Passed via env, not
	## a CLI flag, so an older server (staggered user-mode upgrade) silently
	## ignores an unknown var instead of failing argparse. Scoped tightly around
	## create_process and unset right after (like PYTHONPATH below): the child
	## inherits it, but it must NOT linger in the editor env, or a later
	## non-reload `godot-ai` subprocess (dev server, future spawn) would inherit
	## it and wrongly arm a reaper keyed to this editor.
	## Skipped on Windows: the server's reaper is POSIX-only for now (Windows
	## process-liveness/self-shutdown isn't live-validated yet). The server
	## gates on this too.
	var owner_env_set := _set_owner_pid_env()
	_set_plugin_spawned_env()
	var keep_alive_env_set := _set_keep_alive_env()
	var ws_token := _set_ws_token_env()

	_server_pid = OS.create_process(cmd, args)
	var spawned_pid := int(_server_pid)

	if owner_env_set:
		OS.unset_environment("GODOT_AI_OWNER_PID")
	OS.unset_environment("GODOT_AI_PLUGIN_SPAWNED")
	if keep_alive_env_set:
		OS.unset_environment("GODOT_AI_NO_IDLE_EXIT")
	OS.unset_environment("GODOT_AI_WS_TOKEN")

	## Restore PYTHONPATH immediately — the spawned child has already
	## copied the env, so the editor's own process state returns to
	## baseline. Leaving it set would leak to any later OS.create_process
	## from unrelated paths.
	if pythonpath_set:
		if prev_pythonpath.is_empty():
			OS.unset_environment("PYTHONPATH")
		else:
			OS.set_environment("PYTHONPATH", prev_pythonpath)

	if injected_telemetry_env:
		OS.unset_environment("GODOT_AI_DISABLE_TELEMETRY")

	if spawned_pid > 0:
		_server_spawn_ms = Time.get_ticks_msec()
		_server_exit_ms = 0
		_spawn_dead_since_ms = 0
		_server_keep_alive = keep_alive_env_set
		_host._server_started_this_session = true
		transition_state(McpServerStateScript.SPAWNING)
		## The child copied the env, so this token is what the server will
		## verify handshakes against — adopt it BEFORE writing the record
		## (the record write persists _ws_auth_token).
		_host._set_ws_auth_token(ws_token)
		## Record the launcher PID so same-session
		## prepare_for_update_reload has something to kill. The next
		## editor start's adopt branch heals it to the real port owner.
		_host._write_managed_server_record(spawned_pid, current_version, _server_keep_alive)
		_startup_path = McpStartupPathScript.SPAWNED
		## Log "PYTHONPATH prefix=" rather than "PYTHONPATH=" so the line
		## isn't misleading when an existing PYTHONPATH was present —
		## we prepended `worktree_src`, not replaced. Keeps the log
		## compact (worktree_src is the actionable piece; the full
		## prev_pythonpath can be 5+ entries long on dev machines).
		var suffix := " (PYTHONPATH prefix=%s)" % worktree_src if not worktree_src.is_empty() else ""
		print("MCP | started server (PID %d, v%s): %s %s%s" % [spawned_pid, current_version, cmd, " ".join(args), suffix])
		_host._start_server_watch()
	else:
		_server_status_message = ""
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		_startup_path = McpStartupPathScript.CRASHED
		push_warning("MCP | failed to start server")


## Is the watched spawn PID's death still explainable as a launcher handoff
## rather than a server exit? (#797)
##
## Observed on Windows 11 with a uv-created venv: one boot in four logged
## "server exited after 5146ms" while the real server kept running and was
## then adopted. The watched PID had died on a healthy boot, and because the
## server had not yet written its pid-file there was nothing to heal onto, so
## the watch crossed SPAWN_GRACE_MS and reported an exit — rescued only by the
## crash-survivor adoption path.
##
## A uv venv's `python.exe` is a shim rather than the interpreter, and the real
## server does run under a *different* PID than the one `OS.create_process`
## hands back. But the original report's suspected mechanism — that the shim
## exits once its child is up — is **disproven**, not merely unconfirmed. A
## 12-boot run on Windows 11 with a uv venv found the spawned trampoline alive
## on every boot, with the child owning both the pid-file and the listener; a
## CI runner showed the same. The shim is a live parent for the process's whole
## life, so it is not what kills the watched PID.
##
## Two consequences worth keeping straight. First, this gate is keyed to the
## observable condition — watched PID dead, no pid-file yet — not to any theory
## of why it died, so it stays correct whatever the cause. Second, and less
## comfortable: in that same 12-boot run the false "server exited" line never
## appeared AND the watched PID never died, so the guard never fired. Those
## clean boots are evidence the symptom did not reproduce, NOT evidence this
## guard fixes it. The true cause of the original 1-in-4 report is still
## unknown; if it resurfaces, start from that rather than from the trampoline.
##
## `real_pid <= 0` means no pid-file exists yet, and that reliably means "this
## server has not published one" rather than "stale leftover": `start_server`
## wipes the pid-file immediately before every spawn. So an absent pid-file
## plus a dead spawn PID inside the window is the handoff signature.
##
## Deliberately gated to Windows. POSIX uv venvs exec rather than trampoline,
## so a dead spawn PID there really is a dead server, and delaying its
## diagnosis would only slow down honest crash reporting on the platforms
## where this cannot happen. `os_name` is a parameter rather than an
## `OS.get_name()` call so the Windows path is exercisable from any host.
static func is_spawn_handoff_pending(
	os_name: String, real_pid: int, elapsed_ms: int, window_ms: int
) -> bool:
	if os_name != "Windows":
		return false
	if real_pid > 0:
		return false
	return elapsed_ms < window_ms


## First-write-wins stamp for the elapsed time at which the spawn PID was first
## observed dead (#797).
##
## A diagnosis raised after waiting out a handoff must still report when the
## process actually exited, not when the wait gave up — the point of #797 is an
## honest log line. Returns the existing stamp once one is set, so later ticks
## in the same wait cannot overwrite it; `<= 0` means "not yet stamped",
## matching how the field is cleared per spawn.
static func first_death_stamp(current_stamp_ms: int, elapsed_ms: int) -> int:
	return current_stamp_ms if current_stamp_ms > 0 else elapsed_ms


## One-line forensic snapshot taken the moment a spawn is judged to have
## fast-exited (#797).
##
## #797 reported `server exited after 5146ms` on a healthy Windows boot, once
## in four. It is still unexplained: a 12-boot run on the reported
## configuration reproduced neither the symptom nor its suspected mechanism —
## the uv trampoline was alive on every boot, with the child owning the
## pid-file and the listener, so the shim's exit is ruled out as the cause.
## What killed that watched PID is unknown, and the log line at the time
## carried no evidence to answer it with.
##
## So capture the state at the moment of judgement rather than asking the next
## person to reproduce a 1-in-4 bug under observation. Everything here is read
## through seams the surrounding diagnosis already uses, on a path that only
## runs when a spawn is being declared dead, so it costs nothing in the
## healthy case.
## Deliberately does NOT scrape the port for listener PIDs. This runs from the
## 1 Hz watch loop, on a live frame, so a `_find_all_pids_on_port` subprocess
## here would stall the editor for a diagnostic. Deferring it via
## `_run_blocking` was the alternative and is worse: that helper is
## `await`-based, so it would turn this, `_diagnose_spawn_fast_exit` and
## `check_server_health` into coroutines — making the watch callback resume
## across arbitrary frames while its branches set terminal state and trigger
## re-adoption walks. That is the teardown-ordering hazard
## `_invalidate_async_startup` exists to contain, and it is not worth taking
## on for a log line.
##
## Little is lost: the probe on the very next line already establishes whether
## a godot-ai server answers on the port, and `_diagnose_spawn_port_conflict`
## names a foreign occupant when there is one. If you are tempted to add the
## PID list back, put it behind that existing conflict path rather than here.
func _log_spawn_exit_forensics() -> void:
	var spawn_pid := int(_server_pid)
	var pid_file_pid := int(_host._read_pid_file_for_proof())
	## Computed here rather than accepted as a parameter. The caller's
	## `elapsed` IS `_spawn_dead_since_ms` — #837 passes the true death time so
	## the user-facing "server exited after Nms" line stays honest — so taking
	## it would make these two fields report the same number, collapsing the
	## exact distinction they exist to record.
	var diagnosed_at_ms := 0
	if int(_server_spawn_ms) > 0:
		diagnosed_at_ms = Time.get_ticks_msec() - int(_server_spawn_ms)
	_host._log_buffer.log(format_spawn_exit_forensics({
		"os": OS.get_name(),
		"launch_mode": ClientConfigurator.get_server_launch_mode(),
		"elapsed_ms": diagnosed_at_ms,
		## Differs from elapsed_ms when a Windows handoff window was waited out
		## (#824/#837): the true death time versus when we gave up on it.
		"first_dead_ms": int(_spawn_dead_since_ms),
		"spawn_pid": spawn_pid,
		## Re-read rather than trusted from the watch tick: if the spawn PID is
		## alive HERE, the death that triggered this was transient, which is a
		## different bug from a process that really exited.
		"spawn_alive": spawn_pid > 0 and bool(_host._pid_alive_for_proof(spawn_pid)),
		"pid_file_pid": pid_file_pid,
		"pid_file_alive": pid_file_pid > 0 and bool(_host._pid_alive_for_proof(pid_file_pid)),
	}))


## Render the forensic snapshot. Pure so the format is testable without a live
## editor, and kept to one line so it survives log truncation in a bug report.
static func format_spawn_exit_forensics(facts: Dictionary) -> String:
	var spawn_pid := int(facts.get("spawn_pid", 0))
	var pid_file_pid := int(facts.get("pid_file_pid", 0))
	## The single most diagnostic bit, stated rather than left to be inferred:
	## a live pid-file process while the watched one is gone is the launcher
	## handoff shape; both gone is a real crash.
	var shape := "unknown"
	var spawn_alive := bool(facts.get("spawn_alive", false))
	var file_alive := bool(facts.get("pid_file_alive", false))
	if spawn_alive:
		shape = "watched_pid_still_alive"
	elif file_alive and pid_file_pid != spawn_pid:
		shape = "handoff_child_alive"
	elif not file_alive and pid_file_pid <= 0:
		shape = "no_pid_file_published"
	else:
		shape = "all_dead"
	return (
		"#797 spawn-exit forensics: shape=%s os=%s launch=%s elapsed=%dms "
		+ "first_dead=%dms spawn_pid=%d(alive=%s) pid_file_pid=%d(alive=%s)"
	) % [
		shape,
		str(facts.get("os", "")),
		str(facts.get("launch_mode", "")),
		int(facts.get("elapsed_ms", 0)),
		int(facts.get("first_dead_ms", 0)),
		spawn_pid,
		str(spawn_alive),
		pid_file_pid,
		str(file_alive),
	]


## Watch-loop callback (1 Hz, capped by SERVER_WATCH_MS).
## `--pid-file` is the source of truth on Windows / uvx where the
## launcher PID dies quickly after spawning the real interpreter.
func check_server_health() -> void:
	if int(_server_pid) <= 0:
		_host._stop_server_watch()
		return
	var elapsed := Time.get_ticks_msec() - int(_server_spawn_ms)
	var real_pid := PortResolver.read_pid_file()
	var spawn_pid := int(_server_pid)
	if real_pid > 0 and real_pid != spawn_pid and PortResolver.pid_alive(real_pid):
		_spawn_dead_since_ms = 0
		_server_pid = real_pid
		## The spawn record initially contains the launcher PID so same-session
		## teardown can kill it. Heal it as soon as the server publishes its
		## authoritative PID; future adoption requires the recorded PID to be
		## the actual live listener (#759).
		_host._write_managed_server_record(real_pid, _expected_server_version(), _server_keep_alive)
		## #805: the spawn survived to publish its pid-file — proven
		## recovery, so the fast-exit re-adopt budget refreshes.
		##
		## The stale-recovery budget is deliberately NOT reset here (#890
		## review P1): the Python server writes its pid-file during import,
		## BEFORE uvicorn binds HTTP or the WebSocket listener starts
		## (src/godot_ai/__init__.py) — publication proves the child reached
		## that line, not that it owns either port. A bridge respawn can
		## still steal the bind after the pid-file lands, and zeroing here
		## left that fast-exit with no recovery round. The budget resets on
		## the genuinely proven recoveries: adoption and the verified
		## compatible handshake.
		_readopt_after_spawn_exit_retried = false
	elif not PortResolver.pid_alive(spawn_pid):
		_spawn_dead_since_ms = first_death_stamp(_spawn_dead_since_ms, elapsed)
		if is_spawn_handoff_pending(
			OS.get_name(), real_pid, elapsed, int(_host.SPAWN_HANDOFF_MS)
		):
			return
		if elapsed >= int(_host.SPAWN_GRACE_MS) and not McpServerStateScript.is_terminal_diagnosis(_server_state):
			_diagnose_spawn_fast_exit(_spawn_dead_since_ms)
		return
	if elapsed >= int(_host.SERVER_WATCH_MS):
		## Survived startup — mid-session crashes surface via WebSocket disconnect.
		_host._stop_server_watch()


## The spawned server died inside the SPAWN_GRACE_MS window. Decide what
## that means, in order:
##   1. A live godot-ai server answers on the HTTP port -> our spawn lost
##      a port race the bind probe never saw (#745 bind-trap: the walk
##      thought the port was free, the duplicate exited unable to bind,
##      and the token it staged in the record is now stale). Re-run the
##      startup walk so the adopt/recover branch handles the survivor —
##      latching CRASHED here left the connection redialing forever with
##      a token the surviving server rejects (close code 4003). One
##      re-adopt per recovery via `_readopt_after_spawn_exit_retried`
##      (#805): the triggered walk preserves the spent budget, so a
##      flapping occupant (alive at each fast-exit probe, gone by each
##      walk's probes — sustained multi-editor churn) latches a specific
##      CRASHED diagnosis on the second round instead of re-walking
##      forever. Exception: a verified stale-VERSION occupant with
##      `_stale_recovery_budget` rounds left keeps re-walking (each walk
##      spends one round in its recovery arm), so a bridge-respawn race
##      after a self-update converges instead of latching.
##   2. #647: foreign process on the HTTP or WS port -> FOREIGN_PORT with
##      an actionable message (we can't read the child's "port already in
##      use" stderr). Checked before the --refresh retry: respawning
##      against an occupied port can only fail the same way.
##   3. #172: stale uvx index -> one `--refresh` respawn.
##   4. Otherwise -> CRASHED, pointing at the Godot output log.
func _diagnose_spawn_fast_exit(elapsed: int) -> void:
	_log_spawn_exit_forensics()
	var live: Dictionary = _host._probe_live_server_status_for_port(
		ClientConfigurator.http_port()
	)
	if _live_status_identifies_godot_ai(live):
		## Stale-version occupant with authorized recovery rounds left: allow
		## another re-adopt walk even after the #805 one-shot is spent. This is
		## the attach-bridge respawn race — a bridge pinned to the previous
		## version respawns its cached backend the instant the old server is
		## killed, and can beat our (possibly cold) spawn to the bind. Each
		## extra walk spends one `_stale_recovery_budget` round in its recovery
		## arm, so this stays bounded; the #805 flapping diagnosis below still
		## latches for same-version/unverified occupants and once the budget is
		## exhausted.
		var stale_retry := _stale_recovery_available(
			str(_host._verified_status_version(live)), _expected_server_version()
		)
		if not _readopt_after_spawn_exit_retried or stale_retry:
			if _readopt_after_spawn_exit_retried:
				## Second and later rounds ride the stale budget — spend HERE,
				## not only in the walk's recovery arm: an occupant that flaps
				## out of existence before each walk's probe (the #805 shape)
				## would otherwise re-walk without ever spending, and the
				## terminal latch below would never be reached.
				_stale_recovery_budget -= 1
			_readopt_after_spawn_exit_retried = true
			_readopt_walk_pending = true
			_host._log_buffer.log(
				"server exited after %dms but a live godot-ai server answers on port %d — re-running adoption"
				% [elapsed, ClientConfigurator.http_port()]
			)
			_host._stop_server_watch()
			_server_pid = -1
			## Clear the spawn guard so the re-walk isn't GUARDED away. The
			## walk's adopt arm re-sets it and fixes the stale token/record
			## (external adoption drops both; managed adoption re-records).
			_host._server_started_this_session = false
			## Fire-and-forget (mirrors force_restart_server): the walk is a
			## coroutine in production; its continuation lives on the manager.
			start_server()
			return
		## #805: the re-adopt budget is spent and a live godot-ai still
		## answers while our spawns keep dying — a flapping occupant
		## (another editor's server starting/stopping under it). Re-walking
		## or respawning can only repeat the cycle; latch a terminal
		## diagnosis that names the actual conflict. Reload Plugin (a fresh
		## walk) refreshes the budget for a deliberate retry.
		_server_exit_ms = elapsed
		_server_status_message = (
			"The spawned server keeps exiting while another godot-ai server "
			+ "answers on port %d, and re-adoption was already attempted. "
			+ "Another editor may be repeatedly starting/stopping a server on "
			+ "this port. Stop the other process or pick a different port, "
			+ "then click Reload Plugin."
		) % ClientConfigurator.http_port()
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		disarm_version_check()
		_host._update_process_enabled()
		_host._log_buffer.log(str(_server_status_message))
		push_warning("MCP | %s" % _server_status_message)
		_host._stop_server_watch()
		return
	var conflict := _diagnose_spawn_port_conflict(live)
	if not conflict.is_empty():
		_server_exit_ms = elapsed
		_server_status_message = str(conflict.get("message", ""))
		_conflict_port = int(conflict.get("port", 0))
		set_terminal_diagnosis(McpServerStateScript.FOREIGN_PORT)
		disarm_version_check()
		_host._update_process_enabled()
		_host._log_buffer.log(str(_server_status_message))
		push_warning("MCP | %s" % _server_status_message)
		_host._stop_server_watch()
		return
	if bool(_host._should_retry_with_refresh()):
		_refresh_retried = true
		respawn_with_refresh()
		return
	_server_exit_ms = elapsed
	## Generic crash: clear any stale per-state message so the dock's
	## CRASHED body falls back to its launch-mode copy instead of text
	## from an earlier diagnosis.
	_server_status_message = ""
	set_terminal_diagnosis(McpServerStateScript.CRASHED)
	disarm_version_check()
	_host._update_process_enabled()
	_host._log_buffer.log("server exited after %dms — see Godot output log" % int(_server_exit_ms))
	_host._stop_server_watch()


## #647: post-crash port-conflict probe. Returns `{}` when no foreign
## conflict is detected (fall through to the CRASHED / retry path), or
## `{"message": String, "port": int}` when the HTTP or WS port is held by
## a process we can't identify as godot-ai. An occupant that *does*
## identify as godot-ai is deliberately not diagnosed here — that's the
## stale-server / adoption territory handled by `_diagnose_spawn_fast_exit`'s
## re-adopt arm (or the next `start_server` walk), not a foreign conflict.
## `pre_probed_live`: an HTTP status snapshot the caller already has on
## hand; non-empty skips the internal ~500ms probe (the probe helper never
## returns a bare `{}`, so the sentinel is unambiguous).
func _diagnose_spawn_port_conflict(pre_probed_live: Dictionary = {}) -> Dictionary:
	var http_port := ClientConfigurator.http_port()
	if bool(_host._is_port_in_use(http_port)):
		var live: Dictionary = (
			pre_probed_live
			if not pre_probed_live.is_empty()
			else _host._probe_live_server_status_for_port(http_port)
		)
		if _live_status_identifies_godot_ai(live):
			return {}
		return {
			"message": (
				"Port %d is in use by another application. Stop it or change "
				+ "the port in Editor Settings (godot_ai/http_port)."
			) % http_port,
			"port": http_port,
		}
	var ws_port := int(_host._resolved_ws_port)
	if ws_port > 0 and bool(_host._is_port_in_use(ws_port)):
		return {
			"message": (
				"WebSocket port %d is in use by another application. Stop it "
				+ "or change the port in Editor Settings (godot_ai/ws_port)."
			) % ws_port,
			"port": ws_port,
		}
	return {}


## Retry the spawn with uvx `--refresh` prepended (PyPI index can lag a
## fresh publish ~10 min — #172). One-shot per session via _refresh_retried.
func respawn_with_refresh() -> void:
	_host._startup_trace_count("server_command_discovery")
	var server_cmd := ClientConfigurator.get_server_command(true)
	if server_cmd.is_empty():
		return
	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array(_host._build_server_flags(ClientConfigurator.http_port(), int(_host._resolved_ws_port)))
	_host._clear_pid_file()
	_host._log_buffer.log("retrying with --refresh (PyPI index may be stale)")
	var injected_telemetry_env := _inject_telemetry_env()
	## Set owner PID for THIS spawn too (don't rely on it lingering from
	## start_server) — and unset right after, same scoping as start_server.
	var owner_env_set := _set_owner_pid_env()
	_set_plugin_spawned_env()
	var keep_alive_env_set := _set_keep_alive_env()
	var ws_token := _set_ws_token_env()
	_server_pid = OS.create_process(cmd, args)
	if owner_env_set:
		OS.unset_environment("GODOT_AI_OWNER_PID")
	OS.unset_environment("GODOT_AI_PLUGIN_SPAWNED")
	if keep_alive_env_set:
		OS.unset_environment("GODOT_AI_NO_IDLE_EXIT")
	OS.unset_environment("GODOT_AI_WS_TOKEN")
	if injected_telemetry_env:
		OS.unset_environment("GODOT_AI_DISABLE_TELEMETRY")
	var spawn_pid := int(_server_pid)
	if spawn_pid > 0:
		_server_spawn_ms = Time.get_ticks_msec()
		_server_exit_ms = 0
		_spawn_dead_since_ms = 0
		_server_keep_alive = keep_alive_env_set
		var current_version := _expected_server_version()
		_host._set_ws_auth_token(ws_token)
		_host._write_managed_server_record(spawn_pid, current_version, _server_keep_alive)
		print("MCP | retried server (PID %d, v%s): %s %s" % [spawn_pid, current_version, cmd, " ".join(args)])
	else:
		## OS.create_process returned -1 on the retry — surface CRASHED
		## rather than loop. `_refresh_retried` is already true.
		_server_status_message = ""
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		disarm_version_check()
		_host._update_process_enabled()
		_host._log_buffer.log("refresh retry failed to spawn — see Godot output log")
		_host._stop_server_watch()


func adopt_compatible_server(
	record_version: String,
	current_version: String,
	owner: int,
	record_owns_listener: bool = false
) -> String:
	_server_actual_name = "godot-ai"
	_can_recover_incompatible = false
	## #805: adoption (managed or external) is a proven recovery — the
	## session now has a live compatible server. Refresh the fast-exit
	## re-adopt budget so a later, unrelated port race can heal again.
	_readopt_after_spawn_exit_retried = false
	## The stale-recovery episode (if any) is over: leftover authorized
	## rounds must not carry into a later, unrelated walk where they could
	## weak-proof-kill a server the user deliberately started.
	_stale_recovery_budget = 0
	if record_version == current_version and owner > 0 and record_owns_listener:
		## Managed adoption keeps the record's token (loaded into
		## _ws_auth_token at plugin startup) — the running server was
		## spawned with it and still verifies against it (#690). Version
		## equality alone is deliberately insufficient: the record must also
		## identify the live branded listener (#759/#764).
		_server_pid = owner
		## Recover the keep-alive launch flag from the record the spawning
		## session persisted — a keep-alive survivor adopted here must
		## detach again on THIS session's exit, and only the record knows
		## how the process was actually launched.
		_server_keep_alive = bool(_host._read_managed_server_record().get("keep_alive", false))
		_host._write_managed_server_record(owner, current_version, _server_keep_alive)
		return McpAdoptionLabelScript.MANAGED
	_server_pid = -1
	_server_keep_alive = false
	## External server: we didn't spawn it and don't know its token (it
	## most likely has none — dev servers aren't launched with one). Drop
	## ours so the handshake omits the field instead of sending a stale
	## token the server would reject.
	_host._set_ws_auth_token("")
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return McpAdoptionLabelScript.EXTERNAL


static func _compatible_adoption_log_message(
	owner_label: String,
	owned_pid: int,
	observed_owner_pid: int,
	live_version: String,
	live_ws_port: int,
	current_version: String
) -> String:
	if owner_label == McpAdoptionLabelScript.MANAGED:
		return "MCP | adopted managed server (PID %d, live v%s, WS %d, plugin v%s)" % [
			owned_pid,
			live_version,
			live_ws_port,
			current_version
		]
	return "MCP | adopted external server owner_pid=%d (live v%s, WS %d, plugin v%s)" % [
		observed_owner_pid,
		live_version,
		live_ws_port,
		current_version
	]


## `pre_kill_live` is forwarded into the proof helper so it doesn't
## re-probe a port the caller already probed. The kill invalidates the
## snapshot — callers MUST re-probe before consuming live-status data
## after this returns.
##
## #678: coroutine in production — the proof evaluation (port scrapes +
## per-PID brand shells) and the kill + port-drain wait run off the main
## thread. The EditorSettings record is read on the main thread up front
## and injected into the proof helper; record/pid-file clears stay on the
## main thread after the awaits.
func recover_strong_port_occupant(port: int, wait_s: float, pre_kill_live: Dictionary = {}) -> bool:
	var async_gen := _async_generation
	var record: Dictionary = _host._read_managed_server_record()
	var proof_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return {"proof": "", "pids": []}
		return _host._evaluate_strong_port_occupant_proof(port, pre_kill_live, record)
	)
	if _async_stale(async_gen) or proof_result == null:
		return false
	var proof: Dictionary = proof_result
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false

	print("MCP | strong proof: %s" % str(proof.get("proof", "")))
	var freed_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return false
		## verify_brand=true: the proof above ran in a separate _run_blocking
		## task with main-thread frames in between — re-check each target at
		## kill time so a PID recycled inside that gap isn't killed (#686).
		var killed: Array = _host._kill_processes_and_windows_spawn_children(targets, true)
		if not killed.is_empty():
			print("MCP | killed pids %s on port %d" % [str(killed), port])
		_host._wait_for_port_free(port, wait_s)
		return not bool(_host._is_port_in_use(port))
	)
	if _async_stale(async_gen) or freed_result == null:
		return false
	if not bool(freed_result):
		return false

	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return true


## Weak-proof sibling of `recover_strong_port_occupant`, reserved for the
## bounded stale-version episode (`_stale_recovery_budget` — callers gate on
## `_stale_recovery_available` and spend a round BEFORE calling). Uses the
## recovery-tier proof (`status_name` allowed) because the target is an
## external previous-version server with no managed record or pid-file to
## prove strong ownership with — the same authority the dock's recovery
## click exercises, here spent under an equally explicit user action (the
## Update click / a recovery click's retry). The kill still brand-verifies
## every PID at kill time (#686), so a recycled or unrelated PID on the
## port is never killed. No pre-probed `live` parameter on purpose: a prior
## failed strong recovery may have partially changed the port's state, so
## the worker re-probes — and re-verifies STALENESS on that fresh snapshot
## (#890 CodeRabbit): the caller's version gate ran on an earlier probe,
## and a same-version server that took the port in the interval must abort
## this recovery, not be killed by it.
func recover_stale_port_occupant(port: int, wait_s: float) -> bool:
	var async_gen := _async_generation
	var record: Dictionary = _host._read_managed_server_record()
	## Resolved on the main thread: the worker must not touch EditorSettings.
	var expected_version := _expected_server_version()
	var proof_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return {"proof": "", "pids": []}
		var live: Dictionary = _host._probe_live_server_status_for_port(port)
		var live_version := str(_host._verified_status_version(live))
		if live_version.is_empty() or live_version == expected_version:
			return {"proof": "", "pids": []}
		return _host._evaluate_recovery_port_occupant_proof(port, live, record)
	)
	if _async_stale(async_gen) or proof_result == null:
		return false
	var proof: Dictionary = proof_result
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false

	print("MCP | stale-occupant proof: %s" % str(proof.get("proof", "")))
	var freed_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return false
		## Warm the current-version uv env in parallel with the kill + port
		## drain below (#890 review P1): on the release that first ships this
		## code the OLD updater ran the update, so no click-time pre-warm
		## happened and the respawn would resolve cold — exactly the race
		## this episode exists to win. Detached fire-and-forget via the host
		## seam (stubbed in tests); worker-safe (CliFinder is mutex-guarded,
		## no EditorSettings access).
		_host._prewarm_server_package(expected_version)
		var killed: Array = _host._kill_processes_and_windows_spawn_children(targets, true)
		if not killed.is_empty():
			print("MCP | killed pids %s on port %d" % [str(killed), port])
		_host._wait_for_port_free(port, wait_s)
		return not bool(_host._is_port_in_use(port))
	)
	if _async_stale(async_gen) or freed_result == null:
		return false
	if not bool(freed_result):
		return false

	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return true


## Editor-exit teardown chooser (#800): detach only when the RUNNING
## server was launched keep-alive (_server_keep_alive, set at spawn /
## recovered on adoption) — never on the live setting, which may have
## been toggled after spawn. Flag clear → stop_server kills as always,
## so enabling the setting mid-session takes effect on the next server
## start instead of leaving a record that points at a soon-reaped PID.
func teardown_for_editor_exit() -> void:
	if _server_keep_alive:
		detach_server()
		return
	## #824: a backend we spawned may be keeping one or more MCP clients alive
	## through their `godot-ai attach` bridges. Killing it because *this* editor
	## is closing takes the server out from under them: an in-flight call can
	## become TRANSPORT_OUTCOME_UNKNOWN, and every bridge has to establish a new
	## backend before the next editor can reconnect. A live lease means the
	## backend has consumers beyond this editor, so hand it over instead.
	var leased := active_lease_count_at_exit()
	if leased > 0:
		## Give up kill authority along with the process: dropping the managed
		## record means the next editor adopts it through the external branch
		## rather than as a managed server it may kill. The server's own
		## pid-file is deliberately left in place — it is the backend's
		## publication, not our claim on it, and adoption reads it.
		##
		## The Python side remains the reaper of record: a plugin-spawned
		## backend keeps its idle backstop armed (only keep_server_on_exit
		## disarms it) and that backstop is lease-aware, so this defers the
		## stop to "no editors AND no leases AND grace elapsed" rather than
		## leaking the process.
		_host._clear_managed_server_record()
		detach_server(
			"detaching server: %d attach lease(s) still held, leaving it to the "
			% leased
			+ "server's own idle reaper"
		)
		return
	stop_server()


## Active attach-bridge leases on the backend this editor manages, or 0 when
## there is nothing to consult (#824).
##
## Returns 0 — preserving the historical kill-on-exit behavior — for every
## uncertain case: no managed PID, a probe that fails or times out, a server
## that does not identify as godot-ai, or one too old to publish the field.
## That direction is deliberate. A false 0 costs what today already costs
## (the backend is stopped and bridges reconnect); a false positive would
## leave a process running on a guess.
##
## Bounded by the status probe's own timeout (SERVER_STATUS_PROBE_TIMEOUT_MS),
## which is what keeps editor exit from hanging on a wedged HTTP server.
func active_lease_count_at_exit() -> int:
	var pid := int(_server_pid)
	if pid <= 0:
		return 0
	## Only a process we can still prove is our godot-ai server earns the
	## benefit of the doubt. The lease count comes from whoever answers on the
	## port, which is not by itself proof that it IS the process we are about
	## to stop — another editor's backend, or an attach-owned one, could hold
	## the port after ours died. Requiring the same alive+branded proof
	## `stop_server` uses before its kill closes that gap: without it, a
	## stranger's leases could talk this editor out of stopping its own server.
	##
	## Failing this check is harmless either way. A dead PID has nothing to
	## kill, and a recycled-but-unbranded PID is rejected by stop_server's own
	## gate (#686) — both land on the historical path.
	if not _host._pid_alive_for_proof(pid):
		return 0
	if not _host._pid_cmdline_is_godot_ai_for_proof(pid):
		return 0
	return active_lease_count(
		_host._probe_live_server_status_for_port(ClientConfigurator.http_port())
	)


## Read the advisory lease count out of a `/godot-ai/status` payload.
##
## Gated on the payload identifying as godot-ai, so an unrelated process
## answering on the port cannot talk this editor out of a clean stop. A
## missing field means an older backend that predates #824; it reads as 0,
## which keeps that pairing on today's behavior.
static func active_lease_count(live: Dictionary) -> int:
	if not _live_status_identifies_godot_ai(live):
		return 0
	var raw: Variant = live.get("active_lease_count")
	if raw == null:
		return 0
	return maxi(0, int(raw))


## keep_server_on_exit (#800): editor teardown that leaves the server
## running. Mirrors stop_server's bookkeeping — cancel in-flight async
## startup, stop the watch, settle on STOPPED — but kills nothing and
## PRESERVES the managed-server record + pid-file, so the next editor
## session's start_server walk adopts the survivor through the existing
## record-matches branch (#758/#774). Explicit stops (dock Restart,
## update reload) still route through stop_server and kill as before.
## `log_reason` names why the server is being left alive; the default is the
## keep_server_on_exit wording this function was written for. #824 reuses the
## same bookkeeping for the active-lease handover, and a shared log line would
## have reported the wrong cause for it.
func detach_server(
	log_reason: String = "keep_server_on_exit: leaving server running"
) -> void:
	_invalidate_async_startup()
	_host._stop_server_watch()
	var detached_pid := int(_server_pid)
	_server_pid = -1
	transition_state(McpServerStateScript.STOPPED)
	if detached_pid > 0:
		print("MCP | %s (PID %d)" % [log_reason, detached_pid])


func stop_server() -> void:
	## Cancel any in-flight async startup (#678): a suspended start_server
	## resuming after teardown must not resurrect state or spawn a server.
	_invalidate_async_startup()
	_host._stop_server_watch()
	if int(_server_pid) <= 0:
		transition_state(McpServerStateScript.STOPPED)
		return
	transition_state(McpServerStateScript.STOPPING)
	## Kill the tracked PID AND the real Python PID — they differ for the
	## uvx tier (the launcher exits before its child) and on Windows
	## `OS.kill` is `TerminateProcess` which doesn't walk the child tree.
	var port := ClientConfigurator.http_port()
	var killed: Array = []
	var candidates: Array[int] = []
	## Re-verify the tracked PID at kill time (#686): nothing clears
	## `_server_pid` when the server dies mid-session (`check_server_health`
	## stops watching after SERVER_WATCH_MS), so hours later the kernel may
	## have recycled this PID to an unrelated process. Every other candidate
	## in this function is brand-gated; the tracked seed must be too. A false
	## negative is fail-safe: the port stays held and the record is preserved,
	## so the next start_server's drift branch retries the kill.
	var tracked_pid := int(_server_pid)
	if (
		tracked_pid > 0
		and _host._pid_alive_for_proof(tracked_pid)
		and _host._pid_cmdline_is_godot_ai_for_proof(tracked_pid)
	):
		candidates.append(tracked_pid)
	var real_pid := int(_host._find_managed_pid(port))
	## Add the real Python PID only if it isn't already tracked and proves out
	## as ours — re-appending an already-present PID just produces a duplicate
	## kill candidate.
	if real_pid > 0 and not candidates.has(real_pid) and _host._pid_cmdline_is_godot_ai_for_proof(real_pid):
		candidates.append(real_pid)
	var listener_pids: Array = _host._find_all_pids_on_port(port)
	for pid in listener_pids:
		var listener_pid := int(pid)
		if candidates.has(listener_pid):
			continue
		if _host._pid_cmdline_is_godot_ai_for_proof(listener_pid):
			candidates.append(listener_pid)
	killed = _host._kill_processes_and_windows_spawn_children(candidates)
	if not killed.is_empty():
		print("MCP | stopped server (PID %s)" % str(killed))
	_server_pid = -1
	_server_keep_alive = false
	_host._wait_for_port_free(port, 2.0)
	## Preserve record/pid-file when port is still held — the drift
	## branch on the next start_server retries the kill (#159 follow-up).
	_host._finalize_stop_if_port_free(port)
	transition_state(McpServerStateScript.STOPPED)

	## Server's `_pydantic_core.pyd` hard-link is now released — sweep
	## stale uvx builds before they trip the next attach launcher.
	UvCacheCleanup.purge_stale_builds()


## Kill the server, reset the re-entrancy guard so the re-enabled plugin
## spawns fresh (#132). User-mode only kills via strong proof.
func prepare_for_update_reload() -> void:
	stop_server()
	_host._server_started_this_session = false
	if ClientConfigurator.is_dev_checkout():
		return

	var port := ClientConfigurator.http_port()
	if not bool(_host._is_port_in_use(port)):
		return

	var proof: Dictionary = _host._evaluate_strong_port_occupant_proof(port)
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return

	_host._kill_processes_and_windows_spawn_children(targets)
	_host._wait_for_port_free(port, 3.0)
	if not bool(_host._is_port_in_use(port)):
		_host._clear_managed_server_record()
		_host._clear_pid_file()


# ---- Recovery click ----------------------------------------------------

## Returns true when a pure-state probe says recovery is allowed:
## current state is INCOMPATIBLE, the port is still held, and the
## incompatible diagnosis latched an ownership proof. Pure-state in the
## sense that nothing is killed — that's `recover_incompatible_server`.
##
## Consults the `_can_recover_incompatible` verdict that
## `_set_incompatible_server` computed off-thread instead of re-running
## the proof's port scrapes + per-PID brand shells on the main thread
## (#712): the dock polls this on refresh, and
## `recover_incompatible_server` re-proves at kill time anyway, so a
## stale latch can never kill an unproven occupant — worst case is a
## recovery click that comes back false. The port liveness re-check is
## a single local bind probe, cheap enough to stay synchronous.
func can_recover_incompatible_server() -> bool:
	if _server_state != McpServerStateScript.INCOMPATIBLE:
		return false
	if not _can_recover_incompatible:
		return false
	return bool(_host._is_port_in_use(ClientConfigurator.http_port()))


func recover_incompatible_server() -> bool:
	if _server_state != McpServerStateScript.INCOMPATIBLE:
		return false

	var port := ClientConfigurator.http_port()
	## Cancel any suspended contended-port walk BEFORE the off-thread proof
	## (#712): `_run_blocking` tracks a single active worker for the
	## teardown join, so starting ours while another walk's worker is alive
	## would orphan that thread from the join guarantee. This also releases
	## the guard so the respawn at the bottom isn't silently swallowed
	## (#682 review). The user's recovery click owns the flow from here.
	_invalidate_async_startup()
	var async_gen := _async_generation
	## EditorSettings record read on the main thread, injected so the
	## worker never touches EditorSettings (#712, mirroring
	## recover_strong_port_occupant).
	var record: Dictionary = _host._read_managed_server_record()
	var proof_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return {"proof": "", "pids": []}
		return _host._evaluate_recovery_port_occupant_proof(port, {}, record)
	)
	if _async_stale(async_gen) or proof_result == null:
		return false
	var proof: Dictionary = proof_result
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false
	print("MCP | proof: %s" % str(proof.get("proof", "")))

	## Move into STOPPING so the post-kill respawn passes the
	## first-writer-wins guards.
	transition_state(McpServerStateScript.STOPPING)
	## Main-thread read for the worker below (EditorSettings-backed).
	var recovery_expected_version := _expected_server_version()
	var freed_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return false
		## Warm the current-version uv env in parallel with the kill + drain
		## so the respawn below wins the bind race even when no click-time
		## pre-warm ran (#890 review P1 — the transition release's update runs
		## the OLD updater). Same rationale and seam as
		## recover_stale_port_occupant.
		_host._prewarm_server_package(recovery_expected_version)
		## verify_brand=true: the proof above ran in a separate
		## _run_blocking task with main-thread frames in between — re-check
		## each target at kill time so a PID recycled inside that gap isn't
		## killed (#686, mirroring recover_strong_port_occupant).
		var killed: Array = _host._kill_processes_and_windows_spawn_children(targets, true)
		if not killed.is_empty():
			print("MCP | killed pids %s on port %d" % [str(killed), port])
		_host._wait_for_port_free(port, 5.0)
		return not bool(_host._is_port_in_use(port))
	)
	if _async_stale(async_gen) or freed_result == null:
		return false
	if not bool(freed_result):
		## Kill failed; re-latch INCOMPATIBLE so the dock keeps the
		## diagnostic UI.
		transition_state(McpServerStateScript.INCOMPATIBLE)
		return false

	UvCacheCleanup.purge_stale_builds()
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	transition_state(McpServerStateScript.STOPPED)
	_connection_blocked = false
	_server_status_message = ""
	_conflict_port = 0
	_server_actual_version = ""
	_server_actual_name = ""
	_can_recover_incompatible = false
	_host._server_started_this_session = false
	_server_pid = -1
	## Await the respawn walk: the plugin gates its connection unblock on
	## the post-walk state (SPAWNING/READY), so returning true while the
	## walk is still suspended would leave the connection blocked forever
	## after a successful recovery click (#682 review).
	## NOTE: arming the stale-recovery budget for the click lives in the
	## plugin wrapper (`plugin.gd::recover_incompatible_server`), NOT here —
	## the automatic handshake-mismatch trigger reuses this manager flow and
	## must only SPEND budget; re-arming inside it would unbound the
	## kill/respawn loop against a persistent bridge respawner.
	await start_server()
	return true


## Restart authorisation — a live PID means we spawned/adopted, a
## non-empty managed record is the cross-session proof used by the
## drift branch.
func can_restart_managed_server() -> bool:
	if _server_pid > 0:
		return true
	var record: Dictionary = _host._read_managed_server_record()
	return not str(record.get("version", "")).is_empty()


func has_managed_server() -> bool:
	return _server_pid > 0


## Reset state for a force-restart. Drops the managed record, clears
## the pid-file, and resets the spawn guard so the follow-up
## `start_server()` walks the spawn arm.
func reset_for_force_restart() -> void:
	## The user's explicit restart takes over: cancel any suspended
	## contended-port walk and release the re-entrancy guard so the
	## follow-up start isn't silently swallowed (#682 review).
	_invalidate_async_startup()
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	_host._server_started_this_session = false
	_server_pid = -1
	transition_state(McpServerStateScript.UNINITIALIZED)


## Ownership-checked kill of the port occupant + respawn. Driven from
## the dock's "Restart Server" button when the plugin adopted a foreign
## server whose version drifted from the plugin.
func force_restart_server() -> void:
	if not can_restart_managed_server():
		push_warning("MCP | refusing to kill server on port %d without managed-server ownership proof"
			% ClientConfigurator.http_port())
		return
	var port := ClientConfigurator.http_port()
	## Kill every LISTENER on the port, not just the first one. A dev
	## server run via `uvicorn --reload` owns port 8000 through both a
	## reloader parent AND a worker child — killing only one (or zero,
	## if the single-pid parse fell over on multi-line lsof output) leaves
	## the other holding the port past `_wait_for_port_free`'s window.
	##
	## Brand-gate each raw listener PID (#686): `can_restart_managed_server()`
	## only proves we once managed *a* server, not that the port's current
	## occupants are ours — an adopted server that exited on its own can be
	## replaced on the port by an unrelated dev tool before the user clicks
	## Restart. Unbranded PIDs fall through to `_set_incompatible_server`
	## below instead of being killed.
	transition_state(McpServerStateScript.STOPPING)
	var restart_targets: Array[int] = []
	for pid in _host._find_all_pids_on_port(port):
		var listener_pid := int(pid)
		if _host._pid_cmdline_is_godot_ai_for_proof(listener_pid):
			restart_targets.append(listener_pid)
	_host._kill_processes_and_windows_spawn_children(restart_targets)
	_host._wait_for_port_free(port, 5.0)
	if _host._is_port_in_use(port):
		## Kill failed; clean baseline for the follow-up
		## `_set_incompatible_server`.
		transition_state(McpServerStateScript.UNINITIALIZED)
		_set_incompatible_server(
			_host._probe_live_server_status_for_port(port),
			_expected_server_version(),
			port
		)
		return
	## Same rationale as `stop_server`: the server child python just
	## released its `pydantic_core` mapping, so this is the only window in
	## which the hard-linked copies under `builds-v0\.tmp*` are deletable.
	## Sweep before respawning so the next uvx attach build doesn't
	## inherit the same cleanup-failure path that triggered the restart.
	UvCacheCleanup.purge_stale_builds()
	reset_for_force_restart()
	start_server()
