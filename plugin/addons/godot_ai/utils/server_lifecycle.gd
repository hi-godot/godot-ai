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
var _server_spawn_ms: int = 0
var _server_exit_ms: int = 0

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
## and must bail at its next staleness check, so callers assign the
## result to an untyped local BEFORE the staleness check (a typed
## assignment would trip on the null first).
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
	}


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

func _set_incompatible_server(live: Dictionary, expected_version: String, port: int) -> void:
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
	## arrive with the worker. Sync callers (handshake verdicts, the
	## force-restart failure arm) fire-and-forget the tail; the startup
	## walk awaits it so `_run_blocking`'s single-active-worker tracking
	## keeps one owner at a time.
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
	if _async_stale(async_gen):
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
		if _async_stale(async_gen):
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
	if not version.is_empty():
		if actual_ws_port > 0 and actual_ws_port != expected_ws_port:
			return (
				"Port %d is occupied by godot-ai server v%s using WS port %d%s; "
				+ "plugin expects v%s with WS port %d. Stop the old server or "
				+ "change both HTTP and WS ports."
			) % [port, version, actual_ws_port, path_suffix, expected_version, expected_ws_port]
		return (
			"Port %d is occupied by godot-ai server v%s%s; plugin expects v%s. "
			+ "Stop the old server or change both HTTP and WS ports."
		) % [port, version, path_suffix, expected_version]
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
	_conflict_port = 0

	var port := ClientConfigurator.http_port()
	var ws_port := ClientConfigurator.ws_port()
	var current_version := _expected_server_version()
	_server_expected_version = current_version

	## The worker closures re-check the host: the plugin can be freed while
	## a bounded shell probe is still running, and the generation check only
	## protects state after resume, not calls inside the task (#682 review).
	var port_in_use := bool(await _run_blocking(func() -> Variant:
		return is_instance_valid(_host) and _host._is_port_in_use(port)
	))
	if _async_stale(async_gen):
		return
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
		if _async_stale(async_gen):
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
			var owner := int(_host._find_managed_pid(port))
			var owner_label := adopt_compatible_server(record_version, current_version, owner)
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
		if not recovered:
			_host._server_started_this_session = true
			var post_recovery_result: Variant = await _run_blocking(func() -> Variant:
				if not is_instance_valid(_host):
					return {}
				return _host._probe_live_server_status_for_port(port)
			)
			if _async_stale(async_gen):
				return
			var post_recovery_live: Dictionary = post_recovery_result
			## Awaited (#712): the diagnosis tail runs its own _run_blocking
			## proof, and the walk must stay the single owner of the
			## active-worker slot until that lands. The status message is
			## latched before the tail's first await, so the push_warning
			## below reads the final text either way.
			await _set_incompatible_server(post_recovery_live, current_version, port)
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
	if _async_stale(async_gen):
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
	var ws_token := _set_ws_token_env()

	_server_pid = OS.create_process(cmd, args)
	var spawned_pid := int(_server_pid)

	if owner_env_set:
		OS.unset_environment("GODOT_AI_OWNER_PID")
	OS.unset_environment("GODOT_AI_PLUGIN_SPAWNED")
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
		_host._server_started_this_session = true
		transition_state(McpServerStateScript.SPAWNING)
		## The child copied the env, so this token is what the server will
		## verify handshakes against — adopt it BEFORE writing the record
		## (the record write persists _ws_auth_token).
		_host._set_ws_auth_token(ws_token)
		## Record the launcher PID so same-session
		## prepare_for_update_reload has something to kill. The next
		## editor start's adopt branch heals it to the real port owner.
		_host._write_managed_server_record(spawned_pid, current_version)
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
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		_startup_path = McpStartupPathScript.CRASHED
		push_warning("MCP | failed to start server")


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
		_server_pid = real_pid
	elif not PortResolver.pid_alive(spawn_pid):
		if elapsed >= int(_host.SPAWN_GRACE_MS) and not McpServerStateScript.is_terminal_diagnosis(_server_state):
			## #647: the server died inside the grace window. If a foreign
			## (non-godot-ai) process holds the HTTP or WS port, the server
			## exited fast with its "port already in use" stderr message and
			## EXIT_PORT_IN_USE — but we can't read the child's stderr, so
			## re-probe the ports and surface FOREIGN_PORT with an actionable
			## message instead of a bare CRASHED pointing at the output log.
			## Checked before the --refresh retry: respawning against an
			## occupied port can only fail the same way.
			var conflict := _diagnose_spawn_port_conflict()
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
			set_terminal_diagnosis(McpServerStateScript.CRASHED)
			disarm_version_check()
			_host._update_process_enabled()
			_host._log_buffer.log("server exited after %dms — see Godot output log" % int(_server_exit_ms))
			_host._stop_server_watch()
		return
	if elapsed >= int(_host.SERVER_WATCH_MS):
		## Survived startup — mid-session crashes surface via WebSocket disconnect.
		_host._stop_server_watch()


## #647: post-crash port-conflict probe. Returns `{}` when no foreign
## conflict is detected (fall through to the CRASHED / retry path), or
## `{"message": String, "port": int}` when the HTTP or WS port is held by
## a process we can't identify as godot-ai. An occupant that *does*
## identify as godot-ai is deliberately not diagnosed here — that's the
## stale-server / adoption territory handled by the next `start_server`
## walk, not a foreign conflict.
func _diagnose_spawn_port_conflict() -> Dictionary:
	var http_port := ClientConfigurator.http_port()
	if bool(_host._is_port_in_use(http_port)):
		var live: Dictionary = _host._probe_live_server_status_for_port(http_port)
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
	var ws_token := _set_ws_token_env()
	_server_pid = OS.create_process(cmd, args)
	if owner_env_set:
		OS.unset_environment("GODOT_AI_OWNER_PID")
	OS.unset_environment("GODOT_AI_PLUGIN_SPAWNED")
	OS.unset_environment("GODOT_AI_WS_TOKEN")
	if injected_telemetry_env:
		OS.unset_environment("GODOT_AI_DISABLE_TELEMETRY")
	var spawn_pid := int(_server_pid)
	if spawn_pid > 0:
		_server_spawn_ms = Time.get_ticks_msec()
		_server_exit_ms = 0
		var current_version := _expected_server_version()
		_host._set_ws_auth_token(ws_token)
		_host._write_managed_server_record(spawn_pid, current_version)
		print("MCP | retried server (PID %d, v%s): %s %s" % [spawn_pid, current_version, cmd, " ".join(args)])
	else:
		## OS.create_process returned -1 on the retry — surface CRASHED
		## rather than loop. `_refresh_retried` is already true.
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		disarm_version_check()
		_host._update_process_enabled()
		_host._log_buffer.log("refresh retry failed to spawn — see Godot output log")
		_host._stop_server_watch()


func adopt_compatible_server(record_version: String, current_version: String, owner: int) -> String:
	_server_actual_name = "godot-ai"
	_can_recover_incompatible = false
	if record_version == current_version and owner > 0:
		## Managed adoption keeps the record's token (loaded into
		## _ws_auth_token at plugin startup) — the running server was
		## spawned with it and still verifies against it (#690).
		_server_pid = owner
		_host._write_managed_server_record(owner, current_version)
		return McpAdoptionLabelScript.MANAGED
	_server_pid = -1
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
	if _async_stale(async_gen):
		return false
	var proof: Dictionary = proof_result
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false

	print("MCP | strong proof: %s" % str(proof.get("proof", "")))
	var freed := bool(await _run_blocking(func() -> Variant:
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
	))
	if _async_stale(async_gen):
		return false
	if not freed:
		return false

	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return true


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
	_host._wait_for_port_free(port, 2.0)
	## Preserve record/pid-file when port is still held — the drift
	## branch on the next start_server retries the kill (#159 follow-up).
	_host._finalize_stop_if_port_free(port)
	transition_state(McpServerStateScript.STOPPED)

	## Server's `_pydantic_core.pyd` hard-link is now released — sweep
	## stale uvx builds before they trip the next `uvx mcp-proxy`.
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
	if _async_stale(async_gen):
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
	var freed_result: Variant = await _run_blocking(func() -> Variant:
		if not is_instance_valid(_host):
			return false
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
	if _async_stale(async_gen):
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
	## Sweep before respawning so the upcoming `uvx mcp-proxy` build doesn't
	## inherit the same cleanup-failure path that triggered the restart.
	UvCacheCleanup.purge_stale_builds()
	reset_for_force_restart()
	start_server()
