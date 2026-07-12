@tool
class_name McpDebuggerPlugin
extends EditorDebuggerPlugin

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Editor-side half of the game-process capture bridge.
##
## The game-side counterpart (`plugin/addons/godot_ai/runtime/game_helper.gd`,
## registered as autoload `_mcp_game_helper`) listens on EngineDebugger's
## message channel. This plugin sends "mcp:take_screenshot" requests and
## routes the replies back through the WebSocket McpConnection using the
## request_id the MCP dispatcher threaded through params.
##
## Why this exists: the game always runs as a separate OS process. Even
## "Embed Game Mode" on Windows/Linux (and macOS 4.5+) just reparents the
## game's window into the editor — the game's framebuffer is never reachable
## from the editor's Viewport. The debugger channel is the engine's own
## supported IPC and works identically regardless of embed mode.

const CAPTURE_PREFIX := "mcp"
## CI runners under xvfb can be slow to spin up the game subprocess and
## register the autoload's capture. 8s keeps the message responsive for
## interactive users while still covering slow-CI startup.
const DEFAULT_TIMEOUT_SEC := 8.0
## How long to wait for the game-side autoload to beacon mcp:hello
## before sending the screenshot request. Godot's debugger drops
## messages whose prefix has no registered capture, so sending
## take_screenshot before the game registers its "mcp" capture is a
## silent black hole. On CI the game subprocess has been observed
## taking ~15s to boot + register.
const GAME_READY_WAIT_SEC := 20.0
## #500: how long to wait for the game-side autoload to beacon mcp:hello before
## issuing a game_eval. This is deliberately MUCH shorter than the 20s
## screenshot wait above: the eval path's total editor-side budget is this wait
## plus the 10s eval backstop (request_game_eval's timeout_sec), and that total
## MUST stay below the 15s game_eval timeout enforced at two layers: the Python
## server's send_command budget (src/godot_ai/handlers/editor.py::game_eval) and
## this plugin's own deferred budget (dispatcher.gd's 15000ms game_eval entry,
## editor/plugin-side — not server-side). Either firing produces the opaque tail.
## With the 20s screenshot wait, a not-yet-ready game made the editor poll past
## the 15s deadline, so the server gave up first with an opaque
## ~15s TimeoutError instead of the actionable "Is the game actually running?"
## error below ever reaching the client (#500's residual TimeoutError bucket).
## 3s wait + 10s backstop = 13s, comfortably under the 15s server timeout, so
## the actionable error always wins. A game launched moments before the eval
## still has the 3s grace to register; if it needs longer, the user gets a fast,
## clear "is it running?" rather than a 15s hang.
const EVAL_READY_WAIT_SEC := 3.0
## #490: how long to wait for the game's mcp:eval_compiled beacon before
## concluding the eval source failed to compile. A parse error aborts the
## game-side handler before it can reply, so without this we'd wait the
## full eval timeout for a syntax mistake. reload() of valid source is
## sub-millisecond, so 3s is comfortably clear of false positives.
const EVAL_COMPILE_GRACE_SEC := 3.0
## #490: once an eval compiles, the editor polls the game every this many
## seconds with mcp:eval_check. A backgrounded play-in-editor game has a
## frozen idle loop (no _process / SceneTreeTimer ticks) so it can't
## self-report a runtime error that aborted the eval — but its debugger
## capture callback still answers a probe. The editor's own loop keeps
## ticking, so it drives the poll. 0.35s keeps detection well under a second
## without flooding the channel; most evals reply before the first probe.
const EVAL_PROBE_INTERVAL_SEC := 0.35

var _log_buffer: McpLogBuffer
var _game_log_buffer: McpGameLogBuffer
var _editor_log_buffer: McpEditorLogBuffer
var _surfaced_error_tracker

## Pending request_id -> {connection, timer, timeout_callable}.
## We retain the bound timeout lambda so `_clear_pending` can disconnect
## it on success/error; otherwise the SceneTreeTimer pins the captured
## request_id until `timeout_sec` elapses (8s default).
var _pending: Dictionary = {}

## Flipped true when the game-side autoload sends its "mcp:hello" boot
## beacon for the current project_run. Reset as soon as a new run is
## requested, before Godot has attached the fresh debugger session, so
## editor_state cannot leak readiness from the previous game process.
var _game_ready := false
var _game_run_token := 0
var _ready_run_token := -1
var _game_session_id := -1
var _game_run_active := false
var _manual_run_armed := false
var _game_run_started_msec := 0
var _game_run_started_editor_cursor := 0
var _game_run_started_debugger_cursor := 0
var _game_helper_expected := true

## #645: a GDScript parse error hit while an editor-launched game boots calls
## GDScriptLanguage::debug_break_parse — the game parks in a remote-debugger
## break BEFORE the helper's mcp:hello and before any record reaches the
## Errors tab, the editor Logger, or the game log. The only editor-side traces
## are the debugger break signals; the stack frames land in the Stack Trace
## panel a few frames later. Track the break here so game_status can report
## status="break" and a synthesized error record can name the failure.
var _break_active := false
var _break_can_debug := false
var _break_reason := ""
var _break_pre_live := false
var _break_run_token := -1
var _break_record_synthesized := false

## #645: how long after the break signal to scrape the Stack Trace panel for
## frames. The editor requests the stack dump from the game separately, so the
## panel is empty at signal time; ~0.5s has it populated. The late tick
## synthesizes with whatever is available so a scrape failure still yields a
## record carrying the break reason.
const BREAK_FRAME_SCRAPE_DELAYS_SEC: Array[float] = [0.5, 2.0]



func _init(log_buffer: McpLogBuffer = null, game_log_buffer: McpGameLogBuffer = null, editor_log_buffer: McpEditorLogBuffer = null, surfaced_error_tracker = null) -> void:
	_log_buffer = log_buffer
	_game_log_buffer = game_log_buffer
	_editor_log_buffer = editor_log_buffer
	_surfaced_error_tracker = surfaced_error_tracker


func _has_capture(prefix: String) -> bool:
	return prefix == CAPTURE_PREFIX


## Fires when a debugger session attaches — once for the editor's own
## self-session at startup, and again each time the user hits Play and a
## new game subprocess connects. Reset _game_ready so the next capture
## request waits for the (new) game's mcp:hello beacon before sending,
## avoiding stale-flag timeouts across Play→Stop→Play cycles.
##
## Do NOT log here: add_debugger_plugin() triggers this virtual before
## plugin.gd's _enter_tree logs "plugin loaded", and ci-reload-test
## asserts "plugin loaded" is the first line after a plugin reload.
func _setup_session(session_id: int) -> void:
	_connect_session_stopped(session_id)
	_connect_session_break_signals(session_id)
	if EditorInterface.is_playing_scene() and not _game_run_active:
		_begin_game_run_tracking(_editor_log_cursor(), true, true, true, true, true)
	else:
		_game_ready = false
		_ready_run_token = -1
	_game_session_id = session_id


func begin_game_run(editor_log_cursor: int = 0, helper_expected: bool = true) -> void:
	_begin_game_run_tracking(editor_log_cursor, helper_expected, true, true)


func _begin_game_run_tracking(
	editor_log_cursor: int = 0,
	helper_expected: bool = true,
	rotate_game_log: bool = true,
	sticky_debugger_scan: bool = true,
	quiet: bool = false,
	manual_armed: bool = false,
) -> void:
	_game_run_token += 1
	_game_run_active = true
	_manual_run_armed = manual_armed
	_game_ready = false
	_ready_run_token = -1
	_game_session_id = -1
	clear_debug_break()
	_game_run_started_msec = Time.get_ticks_msec()
	_game_run_started_editor_cursor = maxi(0, editor_log_cursor)
	if _surfaced_error_tracker != null:
		_surfaced_error_tracker.note_game_run_started(sticky_debugger_scan)
		_game_run_started_debugger_cursor = _surfaced_error_tracker.debugger_promoted_total()
	else:
		_game_run_started_debugger_cursor = 0
	_game_helper_expected = helper_expected
	var run_id := ""
	if _game_log_buffer and rotate_game_log:
		run_id = _game_log_buffer.clear_for_new_run()
	if _log_buffer and not quiet:
		var log_text := "[debug] game capture pending run token %d" % _game_run_token
		if not run_id.is_empty():
			log_text += " (run %s)" % run_id
		_log_buffer.log(log_text)


func _editor_log_cursor() -> int:
	return _editor_log_buffer.appended_total() if _editor_log_buffer != null else 0


func end_game_run() -> void:
	_game_run_active = false
	_manual_run_armed = false
	_game_ready = false
	_ready_run_token = -1
	_game_session_id = -1
	clear_debug_break()
	if _surfaced_error_tracker != null:
		_surfaced_error_tracker.note_game_run_stopped()


## Authoritative fallback for runs whose debugger `stopped` signal never
## fired or was never connected: the editor's play state falling to stopped
## means the game process is gone. A game that exits on its own
## (get_tree().quit(), crash) has no MCP stop op to run the bookkeeping, and
## without this game_status stayed "live" until the next run (#642 smoke).
## Called on the playing→stopped edge only, so the pre-play launch window
## (run tracking begun, is_playing_scene() not yet true) is never clipped.
func note_editor_play_stopped() -> void:
	if not _game_run_active:
		return
	end_game_run()


func _connect_session_stopped(session_id: int) -> void:
	var session = get_session(session_id)
	if session == null:
		return
	var stopped := Callable(self, "_on_debugger_session_stopped").bind(session_id)
	if not session.stopped.is_connected(stopped):
		session.stopped.connect(stopped)


func _on_debugger_session_stopped(session_id: int) -> void:
	if _game_session_id != -1 and session_id != _game_session_id:
		return
	## MCP-started runs normally end via project_manage(op="stop"), but a game
	## that exits on its own (get_tree().quit(), crash) emits only this signal.
	## Without ending the run here, game_status stays "live" until the next
	## run's bookkeeping rewrites it (#642 live smoke). Before the game session
	## attaches (_game_session_id == -1) only manual runs may end on this
	## signal — a foreign session's stop must not cancel a launching MCP run.
	if not _manual_run_armed and _game_session_id == -1:
		return
	end_game_run()


## --- #645: boot-time debugger breaks ---------------------------------------

func _connect_session_break_signals(session_id: int) -> void:
	var session = get_session(session_id)
	if session != null:
		var breaked_cb := Callable(self, "_on_debugger_session_breaked").bind(session_id)
		if not session.breaked.is_connected(breaked_cb):
			session.breaked.connect(breaked_cb)
		var continued_cb := Callable(self, "_on_debugger_session_continued").bind(session_id)
		if not session.continued.is_connected(continued_cb):
			session.continued.connect(continued_cb)
	_connect_script_debugger_breaked()


## The session-level `breaked` signal carries only can_debug; the underlying
## ScriptEditorDebugger's own `breaked` also carries the human-readable break
## reason ("Parser Error: ..."), which is otherwise visible only in the
## Debugger UI. EditorDebuggerSession does not expose its debugger node, so
## locate ScriptEditorDebugger instances by walking the editor UI — the same
## approach as the tracker's Errors-tab scrape.
func _connect_script_debugger_breaked() -> void:
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var debuggers: Array[Node] = []
	_collect_nodes_of_class(base, "ScriptEditorDebugger", debuggers)
	for dbg in debuggers:
		if not dbg.has_signal("breaked"):
			continue
		var cb := Callable(self, "_on_script_debugger_breaked")
		if not dbg.is_connected("breaked", cb):
			dbg.connect("breaked", cb)


static func _collect_nodes_of_class(node: Node, klass: String, out: Array[Node]) -> void:
	if node.get_class() == klass:
		out.append(node)
	for child in node.get_children():
		_collect_nodes_of_class(child, klass, out)


func _on_debugger_session_breaked(can_debug: bool, session_id: int) -> void:
	if _game_session_id != -1 and session_id != _game_session_id:
		return
	note_debug_break(can_debug, "")


func _on_debugger_session_continued(session_id: int) -> void:
	if _game_session_id != -1 and session_id != _game_session_id:
		return
	clear_debug_break()


## reallydid=false is Godot's "left the break" notification (debug_exit).
func _on_script_debugger_breaked(reallydid: bool, can_debug: bool, reason: String, _has_stackdump: bool) -> void:
	if not reallydid:
		clear_debug_break()
		return
	note_debug_break(can_debug, reason)


## Record that the game process is parked in a remote-debugger break. Fires
## once per break from the session signal (no reason text) and again moments
## later from the ScriptEditorDebugger signal (with reason) — the notices
## merge into one break. Public so tests can drive break state directly.
func note_debug_break(can_debug: bool, reason: String) -> void:
	var first_notice := not _break_active
	_break_active = true
	_break_can_debug = can_debug
	if not reason.is_empty():
		_break_reason = reason
	if not first_notice:
		return
	_break_run_token = _game_run_token
	_break_pre_live = _game_run_active and not is_game_capture_ready()
	_break_record_synthesized = false
	if _log_buffer:
		_log_buffer.log("[debug] debugger break (pre_live=%s can_debug=%s)" % [str(_break_pre_live), str(can_debug)])
	if _break_pre_live:
		_schedule_break_record_synthesis()


func clear_debug_break() -> void:
	_break_active = false
	_break_can_debug = false
	_break_reason = ""
	_break_pre_live = false
	_break_run_token = -1
	_break_record_synthesized = false


## Stack frames land in the Stack Trace panel a few frames after the break
## signal (the editor requests the stack dump separately), so the record is
## synthesized on short timers rather than at signal time.
func _schedule_break_record_synthesis() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var token := _break_run_token
	for i in BREAK_FRAME_SCRAPE_DELAYS_SEC.size():
		var final := i == BREAK_FRAME_SCRAPE_DELAYS_SEC.size() - 1
		var timer := tree.create_timer(BREAK_FRAME_SCRAPE_DELAYS_SEC[i])
		timer.timeout.connect(func() -> void: _on_break_scrape_tick(token, final))


func _on_break_scrape_tick(run_token: int, final: bool) -> void:
	if not _break_active or _break_record_synthesized or run_token != _break_run_token:
		return
	var frames := _scrape_break_stack_frames()
	if frames.is_empty() and not final:
		return
	synthesize_break_error_record(frames)


## Read the debugger's Stack Trace panel rows. Row metadata is a Dictionary
## {frame, file, function, line} regardless of editor locale, so stack trees
## are identified by metadata shape rather than the translated column title.
func _scrape_break_stack_frames() -> Array[Dictionary]:
	var base := EditorInterface.get_base_control()
	if base == null:
		return []
	var debuggers: Array[Node] = []
	_collect_nodes_of_class(base, "ScriptEditorDebugger", debuggers)
	for dbg in debuggers:
		var trees: Array[Node] = []
		_collect_nodes_of_class(dbg, "Tree", trees)
		for t in trees:
			var frames := _frames_from_stack_tree(t as Tree)
			if not frames.is_empty():
				return frames
	return []


static func _frames_from_stack_tree(tree: Tree) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	var root := tree.get_root()
	if root == null:
		return frames
	var item := root.get_first_child()
	while item != null:
		var meta = item.get_metadata(0)
		if not (meta is Dictionary and meta.has("file") and meta.has("frame")):
			return []
		frames.append({
			"path": str(meta.get("file", "")),
			"line": int(meta.get("line", 0)),
			"function": str(meta.get("function", "")),
		})
		item = item.get_next()
	return frames


## Build the Errors-tab-shaped record for a boot-time break and promote it via
## the tracker so recent_editor_errors_since / logs_read / the watermark all
## surface it — the break itself produces no record anywhere else (#645).
## Public so tests can synthesize without waiting on scrape timers.
func synthesize_break_error_record(frames: Array[Dictionary]) -> void:
	if _break_record_synthesized:
		return
	_break_record_synthesized = true
	if _surfaced_error_tracker == null:
		return
	var reason := _break_reason
	if reason.is_empty():
		reason = "Game process broke into the debugger during startup (script parse/load error; reason not captured)"
	var top: Dictionary = frames[0] if not frames.is_empty() else {}
	var location := {
		"path": str(top.get("path", "")),
		"line": int(top.get("line", 0)),
		"function": str(top.get("function", "")),
	}
	var entry := {
		"source": "editor",
		"level": "error",
		"text": reason,
		"path": location["path"],
		"line": location["line"],
		"function": location["function"],
		"details": {
			"debugger_tab": "Stack Trace",
			"message": reason,
			"error_type_name": "debugger_break",
			"source": location.duplicate(true),
			"resolved": location.duplicate(true),
			"frames": frames.duplicate(true),
		},
	}
	_surfaced_error_tracker.record_synthetic_error(entry)
	if _log_buffer:
		_log_buffer.log("[debug] synthesized boot-break error record: %s" % McpSurfacedErrorTracker.format_editor_error_summary(entry))


## --- end #645 ---------------------------------------------------------------


func is_game_capture_ready() -> bool:
	return _game_run_active and _game_ready and _ready_run_token == _game_run_token


static func with_liveness_flags(status: Dictionary) -> Dictionary:
	var enriched := status.duplicate(true)
	var state := str(enriched.get("status", "stopped"))
	enriched["helper_live"] = state == "live"
	enriched["session_active"] = not state in ["not_live", "stopped"]
	return enriched


func get_game_status(now_msec: int = -1, ready_wait_sec: float = GAME_READY_WAIT_SEC) -> Dictionary:
	var resolved_now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var ready_wait_msec := maxi(0, int(ready_wait_sec * 1000.0))
	var elapsed_msec := maxi(0, resolved_now - _game_run_started_msec) if _game_run_active else 0
	## "stopped" also covers idle/never-ran; no game run is currently active.
	var status := "stopped"
	if _game_run_active:
		## #645: a parked process takes precedence over "live" — a game frozen
		## in a remote-debugger break cannot service game-side tools even when
		## its helper registered before the break.
		if _break_active:
			status = "break"
		elif is_game_capture_ready():
			status = "live"
		elif not _game_helper_expected:
			status = "no_helper"
		elif elapsed_msec >= ready_wait_msec:
			status = "not_live"
		else:
			status = "launching"
	var out := {
		"status": status,
		"run_token": _game_run_token,
		"active": _game_run_active,
		"ready": is_game_capture_ready(),
		"helper_expected": _game_helper_expected,
		"run_started_msec": _game_run_started_msec,
		"elapsed_msec": elapsed_msec,
		"ready_wait_msec": ready_wait_msec,
		"editor_log_cursor": _game_run_started_editor_cursor,
	}
	if status == "break":
		out["break"] = {
			"reason": _break_reason,
			"can_debug": _break_can_debug,
			"pre_live": _break_pre_live,
		}
	return with_liveness_flags(out)


func _explain_not_live(status: Dictionary, code: String = ErrorCodes.INTERNAL_ERROR) -> Dictionary:
	var state := str(status.get("status", "stopped"))
	var errors_info := recent_editor_errors_since(int(status.get("editor_log_cursor", 0)))
	var recent_errors: Array = errors_info.get("errors", [])
	var recent_errors_scope := str(errors_info.get("scope", "none"))
	var truncated := bool(errors_info.get("truncated", false))
	var data := {
		"game_status": status.duplicate(true),
		"recent_errors": recent_errors,
		"recent_errors_scope": recent_errors_scope,
		"recent_errors_may_predate_run": recent_errors_scope == "retained_recent",
		"recent_errors_truncated": truncated,
	}
	data.merge(split_errors_by_scope(recent_errors, recent_errors_scope), true)
	var message := ""
	match state:
		"not_live":
			if not recent_errors.is_empty() and recent_errors_scope == "run":
				message = "The game failed to load or crashed before the Godot AI game helper registered: %s. Check logs_read(source='editor', include_details=true)." % _format_editor_error_summary(recent_errors[0])
				if truncated:
					message += " Editor logs since this run may be truncated; showing retained errors."
			elif not recent_errors.is_empty():
				message = "The game is not responding and reported no load errors during this run. A recent editor error may be related, but may predate this run: %s. Check logs_read(source='editor', include_details=true)." % _format_editor_error_summary(recent_errors[0])
			else:
				message = "The game is not responding and reported no load errors before the helper-ready window elapsed. It may still be booting or may have failed silently; check logs_read(source='editor', include_details=true) and retry."
		"break":
			var break_info: Dictionary = status.get("break", {})
			var break_reason := str(break_info.get("reason", ""))
			var reason_suffix := (": %s" % break_reason) if not break_reason.is_empty() else ""
			if bool(break_info.get("pre_live", true)):
				message = "The game hit a script error during startup and is frozen at a debugger break%s. It cannot become live; call project_manage(op='stop') to end the run, fix the error, and relaunch. Check logs_read(source='editor', include_details=true)." % reason_suffix
			else:
				message = "The game is paused at a debugger break%s. Resume it from the editor's Debugger panel or call project_manage(op='stop')." % reason_suffix
		"no_helper":
			message = "The running game has no _mcp_game_helper autoload, so game-side tools cannot connect. If this is a headless or custom-main-loop project, use editor_screenshot(source='viewport') where applicable. Otherwise, re-enable the plugin and relaunch the game."
		"launching":
			message = "The game is still starting (%.1fs elapsed); the Godot AI game helper has not registered yet. Retry shortly." % (float(status.get("elapsed_msec", 0)) / 1000.0)
		"stopped":
			message = "The game is not running. Start the project and retry the game-side tool."
		_:
			message = "The game-side tool could not confirm the game is live (status=%s). Check logs_read(source='editor', include_details=true) and retry." % state
	var err := ErrorCodes.make(code, message)
	var inner: Dictionary = err.get("error", {})
	inner["data"] = data
	err["error"] = inner
	return err


static func split_errors_by_scope(recent_errors: Array, scope: String) -> Dictionary:
	var current_run_errors: Array = []
	var retained_errors: Array = []
	if scope == "run":
		current_run_errors = recent_errors
	elif scope == "retained_recent":
		retained_errors = recent_errors
	return {
		"current_run_errors": current_run_errors,
		"retained_errors": retained_errors,
	}


## `force_debugger_scan` bypasses the tracker's scan gate for one read. Keep it
## false on per-frame polling paths (the run-liveness loop) — a forced scan
## walks the Debugger dock UI — and pass true only for one-shot reads that must
## see rows which landed after the last gated scan (#641).
func recent_editor_errors_since(cursor: int, force_debugger_scan: bool = false) -> Dictionary:
	return _recent_editor_errors_since(cursor, force_debugger_scan)


func _recent_editor_errors_since(cursor: int, force_debugger_scan: bool = false) -> Dictionary:
	var out: Array[Dictionary] = []
	var truncated := false
	if _surfaced_error_tracker != null:
		var captured_by_tracker: Dictionary = _surfaced_error_tracker.editor_entries_since(
			maxi(0, cursor),
			_game_run_started_debugger_cursor,
			force_debugger_scan,
		)
		truncated = bool(captured_by_tracker.get("truncated", false))
		for raw_entry in captured_by_tracker.get("entries", []):
			var compact := _compact_editor_error(raw_entry)
			if compact.is_empty():
				continue
			out.append(compact)
			if out.size() >= 5:
				break
		if not out.is_empty():
			return {"errors": out, "truncated": truncated, "scope": "run"}
		for raw_entry in _surfaced_error_tracker.retained_recent_editor_entries():
			var compact := _compact_editor_error(raw_entry, true)
			if compact.is_empty():
				continue
			out.append(compact)
			if out.size() >= 5:
				break
		if not out.is_empty():
			return {"errors": out, "truncated": false, "scope": "retained_recent"}
		return {"errors": out, "truncated": false, "scope": "none"}
	if _editor_log_buffer == null:
		return {"errors": out, "truncated": false, "scope": "none"}
	var captured: Dictionary = _editor_log_buffer.get_since(maxi(0, cursor), -1)
	truncated = bool(captured.get("truncated", false))
	for raw_entry in captured.get("entries", []):
		var compact := _compact_editor_error(raw_entry)
		if compact.is_empty():
			continue
		out.append(compact)
		if out.size() >= 5:
			break
	if not out.is_empty():
		return {"errors": out, "truncated": truncated, "scope": "run"}

	for raw_entry in _reversed_entries(_editor_log_buffer.get_recent(McpEditorLogBuffer.MAX_LINES)):
		var compact := _compact_editor_error(raw_entry, true)
		if compact.is_empty():
			continue
		out.append(compact)
		if out.size() >= 5:
			break
	if not out.is_empty():
		return {"errors": out, "truncated": false, "scope": "retained_recent"}
	return {"errors": out, "truncated": false, "scope": "none"}


func _compact_editor_error(raw_entry: Variant, fallback_recent: bool = false) -> Dictionary:
	if not raw_entry is Dictionary:
		return {}
	var entry := raw_entry as Dictionary
	if str(entry.get("level", "info")) != "error":
		return {}
	var path := str(entry.get("path", ""))
	if fallback_recent and _is_diagnostic_noise_path(path):
		return {}
	var compact := {
		"source": "editor",
		"level": "error",
		"text": str(entry.get("text", "")),
		"path": path,
		"line": int(entry.get("line", 0)),
		"function": str(entry.get("function", "")),
	}
	if entry.has("details"):
		compact["details"] = entry["details"].duplicate(true)
	return compact


func _is_diagnostic_noise_path(path: String) -> bool:
	return path.begins_with("res://addons/godot_ai/") or path.begins_with("res://tests/")


func _reversed_entries(entries: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(entries.size() - 1, -1, -1):
		out.append(entries[i])
	return out


func _format_editor_error_summary(entry: Dictionary) -> String:
	return McpSurfacedErrorTracker.format_editor_error_summary(entry)


func _capture(message: String, data: Array, session_id: int) -> bool:
	## Godot passes the full "prefix:tail" string as `message`.
	match message:
		"mcp:screenshot_response":
			_on_screenshot_response(data)
			return true
		"mcp:screenshot_error":
			_on_screenshot_error(data)
			return true
		"mcp:log_batch":
			_on_log_batch(data)
			return true
		"mcp:hello":
			if not _game_run_active:
				if _log_buffer:
					_log_buffer.log("[debug] ignored mcp:hello with no active game run")
				return true
			if _game_session_id != -1 and session_id != _game_session_id:
				if _log_buffer:
					_log_buffer.log("[debug] ignored stale mcp:hello from debugger session %d (current %d)" % [session_id, _game_session_id])
				return true
			## Boot beacon from the game-side autoload. Tells us the
			## game has registered its "mcp" capture and is safe to send
			## take_screenshot to — before this, Godot's debugger would
			## drop our message silently.
			_game_ready = true
			_ready_run_token = _game_run_token
			## #641: boot-time parse errors race the hello beacon — both ride
			## the same debugger channel, and the editor inserts Errors-tab
			## rows with a per-frame throttle, so rows can land moments after
			## the run is declared live. Arm forced scans so those rows get
			## promoted into the watermark even if no tool call follows.
			if _surfaced_error_tracker != null:
				_surfaced_error_tracker.schedule_deferred_scans()
			if _log_buffer:
				if _game_log_buffer:
					_log_buffer.log("[debug] <- mcp:hello from game_helper (run %s)" % _game_log_buffer.run_id())
				else:
					_log_buffer.log("[debug] <- mcp:hello from game_helper")
			return true
		"mcp:eval_response":
			_on_eval_response(data)
			return true
		"mcp:eval_error":
			_on_eval_error(data)
			return true
		"mcp:eval_ack":
			_on_eval_ack(data)
			return true
		"mcp:eval_compiled":
			_on_eval_compiled(data)
			return true
		"mcp:eval_runtime_error":
			_on_eval_runtime_error(data)
			return true
		"mcp:game_command_response":
			_on_game_command_response(data)
			return true
		"mcp:game_command_error":
			_on_game_command_error(data)
			return true
	return false


func _on_log_batch(data: Array) -> void:
	if _game_log_buffer == null:
		return
	## data layout: [[[level, text, details?], ...]]
	if data.is_empty() or not (data[0] is Array):
		return
	var entries: Array = data[0]
	for entry in entries:
		if entry is Dictionary:
			var dict_details: Dictionary = {}
			var raw_dict_details = entry.get("details", {})
			if raw_dict_details is Dictionary:
				dict_details = raw_dict_details
			_game_log_buffer.append(str(entry.get("level", "info")), str(entry.get("text", "")), dict_details)
			continue
		if not (entry is Array) or entry.size() < 2:
			continue
		var details: Dictionary = {}
		if entry.size() > 2 and entry[2] is Dictionary:
			details = entry[2]
		_game_log_buffer.append(str(entry[0]), str(entry[1]), details)


## Request a game-process framebuffer capture over the debugger channel.
## Reply is pushed back through `connection` out-of-band because the MCP
## dispatcher has already returned a deferred-response marker for this
## request_id. Synchronous from the caller's perspective — if the
## game-side autoload hasn't beaconed yet, the wait + send run as a
## fire-and-forget coroutine kicked off from here. Structured this way
## so the call site in EditorHandler stays a plain non-await invocation.
func request_game_screenshot(
	request_id: String,
	max_resolution: int,
	connection: McpConnection,
	timeout_sec: float = DEFAULT_TIMEOUT_SEC,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: screenshot request missing request_id")
		return

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree — cannot schedule capture")
		return

	if is_game_capture_ready():
		_send_take_screenshot(tree, request_id, max_resolution, connection, timeout_sec)
		return

	## Not ready yet — run the wait-then-send flow as a detached
	## coroutine. It keeps itself alive via the signal subscription on
	## tree.process_frame; the caller doesn't need to (and shouldn't)
	## await this entrypoint.
	if _log_buffer:
		_log_buffer.log("[debug] waiting for game_helper hello (%s)" % request_id)
	_wait_then_send(tree, request_id, max_resolution, connection, timeout_sec)


## Coroutine: poll each editor frame until the mcp:hello beacon arrives
## (flipping _game_ready true) or the deadline elapses. Once resolved,
## either dispatch the capture or return an actionable timeout error.
func _wait_then_send(
	tree: SceneTree,
	request_id: String,
	max_resolution: int,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var deadline := Time.get_ticks_msec() + int(GAME_READY_WAIT_SEC * 1000.0)
	## #645: always yield at least one frame — the dispatcher registers the
	## deferred request only after the handler returns DEFERRED_RESPONSE, so a
	## same-frame error reply would be dropped as an expired request. The break
	## check then bails out with the actionable break error instead of waiting
	## out the full window (a game parked in a debugger break never beacons).
	await tree.process_frame
	while not is_game_capture_ready() and not _break_active and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not is_game_capture_ready():
		_send_error_response(connection, request_id,
			_explain_not_live(get_game_status(-1, GAME_READY_WAIT_SEC), ErrorCodes.INTERNAL_ERROR))
		return
	_send_take_screenshot(tree, request_id, max_resolution, connection, timeout_sec)


## Send the mcp:take_screenshot message and arm the reply timeout.
## Assumes _game_ready is true.
func _send_take_screenshot(
	tree: SceneTree,
	request_id: String,
	max_resolution: int,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"No active debugger session — is the game actually running and started from this editor?")
		return

	var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
	var timeout_callable := func() -> void: _on_timeout(request_id)
	timer.timeout.connect(timeout_callable)
	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
	}

	session.send_message("mcp:take_screenshot", [request_id, max_resolution])
	if _log_buffer:
		_log_buffer.log("[debug] -> mcp:take_screenshot (%s)" % request_id)


func _first_active_session() -> EditorDebuggerSession:
	for s in get_sessions():
		if s is EditorDebuggerSession and s.is_active():
			return s
	return null


func _on_screenshot_response(data: Array) -> void:
	if data.size() < 6:
		push_warning("MCP debugger: malformed screenshot response (expected 6 fields, got %d)" % data.size())
		return
	var request_id: String = data[0]
	var pending = _pending.get(request_id)
	if pending == null:
		## Timed out or unknown — silently drop.
		return
	_clear_pending(request_id)

	var connection: McpConnection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return

	connection.send_deferred_response(request_id, {
		"data": {
			"source": "game",
			"width": int(data[2]),
			"height": int(data[3]),
			"original_width": int(data[4]),
			"original_height": int(data[5]),
			"format": "png",
			"image_base64": data[1],
		}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:screenshot_response (%s)" % request_id)


func _on_screenshot_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending = _pending.get(request_id)
	if pending == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, message)


func _on_timeout(request_id: String) -> void:
	var pending = _pending.get(request_id)
	if pending == null:
		return
	_pending.erase(request_id)
	var connection: McpConnection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return
	var status := get_game_status(-1, GAME_READY_WAIT_SEC)
	var err := ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
		"Game screenshot timed out after reaching the game helper. The game may be busy or unable to render a frame. Check logs_read(source='game') and retry.")
	if status.get("status", "") != "live":
		err = _explain_not_live(status, ErrorCodes.INTERNAL_ERROR)
	_send_error_response(connection, request_id, err)
	if _log_buffer:
		_log_buffer.log("[debug] !! screenshot timeout (%s)" % request_id)


func _send_error(connection: McpConnection, request_id: String, code: String, message: String) -> void:
	_send_error_response(connection, request_id, ErrorCodes.make(code, message))


func _send_error_response(connection: McpConnection, request_id: String, err: Dictionary) -> void:
	if connection == null or not is_instance_valid(connection):
		return
	connection.send_deferred_response(request_id, err)


func _clear_pending(request_id: String) -> void:
	var pending: Dictionary = _pending.get(request_id, {})
	var timer: SceneTreeTimer = pending.get("timer")
	var cb: Callable = pending.get("timeout_callable", Callable())
	if timer != null and timer.timeout.is_connected(cb):
		timer.timeout.disconnect(cb)
	## #490: eval requests also carry a compile-grace timer and a runtime probe.
	var grace: SceneTreeTimer = pending.get("grace_timer")
	var gcb: Callable = pending.get("grace_callable", Callable())
	if grace != null and grace.timeout.is_connected(gcb):
		grace.timeout.disconnect(gcb)
	var probe: SceneTreeTimer = pending.get("probe_timer")
	var pcb: Callable = pending.get("probe_callable", Callable())
	if probe != null and probe.timeout.is_connected(pcb):
		probe.timeout.disconnect(pcb)
	_pending.erase(request_id)


## --- game_eval: execute arbitrary GDScript in the running game ---

## Editor-side fallback timer for game_eval. MUST stay above the game-side
## EVAL_TIMEOUT_SEC (8.0) in runtime/game_helper.gd and below the dispatcher's
## game_eval budget (15000 ms) in dispatcher.gd — i.e. game 8s < editor 10s <
## dispatcher 15s. This timer only fires when the game never replies at all;
## _on_eval_timeout then attributes the failure (game not live vs never-acked
## vs started-and-hung, #518). Drop timeout_sec at/below 8s and it pre-empts
## the game's more specific "Eval exceeded 8s" message — see the TIMEOUT
## ORDERING note on EVAL_TIMEOUT_SEC.
##
## #500: the *not-ready* path adds EVAL_READY_WAIT_SEC (3s) on top of this 10s
## backstop. That sum (13s) must also stay below the dispatcher/server 15s
## budget, or a not-yet-ready game makes the server time out opaquely before
## the editor's actionable error returns — which is exactly the residual ~15s
## TimeoutError bucket #500 tracked down. Keep EVAL_READY_WAIT_SEC + timeout_sec
## < 15s if you tune either.
func request_game_eval(
	code: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float = 10.0,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: eval request missing request_id")
		return

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree — cannot schedule eval")
		return

	if is_game_capture_ready():
		_send_eval(tree, code, request_id, connection, timeout_sec)
		return

	if _log_buffer:
		_log_buffer.log("[debug] waiting for game_helper hello before eval (%s)" % request_id)
	_wait_then_eval(tree, code, request_id, connection, timeout_sec)


func _wait_then_eval(
	tree: SceneTree,
	code: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	## #500: eval uses EVAL_READY_WAIT_SEC (not the 20s GAME_READY_WAIT_SEC) so
	## the not-ready path returns its actionable error before the 15s server-side
	## command timeout fires an opaque TimeoutError. See EVAL_READY_WAIT_SEC.
	var deadline := Time.get_ticks_msec() + int(EVAL_READY_WAIT_SEC * 1000.0)
	## #645: the leading yield guarantees the dispatcher has registered the
	## deferred request before any reply (a same-frame reply is dropped as
	## expired); the break check bails out early because a parked game never
	## registers its capture.
	await tree.process_frame
	while not is_game_capture_ready() and not _break_active and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not is_game_capture_ready():
		## #518: EVAL_GAME_NOT_READY (not INTERNAL_ERROR) — the play session is up
		## but the game-side capture didn't register within the short wait. Fast
		## and caller-actionable; classifying it apart from the opaque 10s hang
		## keeps the INTERNAL_ERROR telemetry bucket meaning "the eval truly hung".
		_send_error_response(connection, request_id,
			_explain_not_live(get_game_status(-1, EVAL_READY_WAIT_SEC), ErrorCodes.EVAL_GAME_NOT_READY))
		return
	_send_eval(tree, code, request_id, connection, timeout_sec)


func _send_eval(
	tree: SceneTree,
	code: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		## #518: capture reported ready but the debugger session is no longer live
		## (the game just stopped / is restarting) — a not-ready race, so the same
		## caller-actionable EVAL_GAME_NOT_READY rather than the opaque hang bucket.
		_send_error(connection, request_id, ErrorCodes.EVAL_GAME_NOT_READY,
			"Game-side capture registered but its debugger session is no longer active — the game likely just stopped or is restarting. Confirm it's running and retry.")
		return

	var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
	var timeout_callable := func() -> void: _on_eval_timeout(request_id, timeout_sec)
	timer.timeout.connect(timeout_callable)

	## #490: arm the compile-grace timer. _on_eval_grace concludes a parse error
	## only when the game acked the eval (it received the message and started
	## reload()) but never sent mcp:eval_compiled — see there for why a missing
	## ack must NOT be read as a compile error.
	var grace: SceneTreeTimer = tree.create_timer(EVAL_COMPILE_GRACE_SEC)
	var grace_callable := func() -> void: _on_eval_grace(request_id)
	grace.timeout.connect(grace_callable)

	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
		"grace_timer": grace,
		"grace_callable": grace_callable,
		"acked": false,
		"compiled": false,
	}

	session.send_message("mcp:eval", [request_id, code])
	if _log_buffer:
		_log_buffer.log("[debug] -> mcp:eval (%s)" % request_id)


## #518: the 10s editor-side backstop fired — the game never replied at all.
## Attribute the failure instead of emitting a one-size-fits-all INTERNAL_ERROR:
##
## - game not live anymore (parked in a debugger break, stopped, crashed):
##   the eval couldn't run/finish for a *game-state* reason. Reply with the
##   same caller-actionable EVAL_GAME_NOT_READY + `_explain_not_live` payload
##   the pre-hello break path already uses — a break freezes the game's idle
##   loop, so any awaiting eval parks here even though sync evals still work.
## - game live but never acked the eval: its main thread never serviced the
##   debugger message (long frame/load, CPU-bound prior eval, or a
##   backgrounded window whose idle loop is frozen).
## - game live, acked, compiled: the eval genuinely started and never
##   finished, and the game couldn't even self-report via its own 8s guard
##   (which needs a ticking idle loop) — hung await, CPU-bound loop, or a
##   reply the debugger channel dropped.
##
## The live branches reply EVAL_HUNG: the eval code never finished. That code
## plus the game-side 8s guard (also EVAL_HUNG, via mcp:eval_error's code
## element) empties the former INTERNAL_ERROR bucket on this path.
func _on_eval_timeout(request_id: String, timeout_sec: float) -> void:
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var conn: McpConnection = pending_entry.connection
	if conn == null or not is_instance_valid(conn):
		return
	var status := get_game_status(-1, EVAL_READY_WAIT_SEC)
	if str(status.get("status", "")) != "live":
		_send_error_response(conn, request_id,
			_explain_not_live(status, ErrorCodes.EVAL_GAME_NOT_READY))
		if _log_buffer:
			_log_buffer.log("[debug] !! eval timeout, game not live (%s, status=%s)"
				% [request_id, str(status.get("status", ""))])
		return
	var message: String
	if not bool(pending_entry.get("acked", false)):
		message = ("Game eval was sent but the game never picked it up within %.0fs — "
			+ "its main thread is busy or frozen (a long frame/load, a CPU-bound "
			+ "prior eval, or a backgrounded game window whose loop is throttled). "
			+ "Check logs_read(source='game') and retry.") % timeout_sec
	else:
		message = ("Game eval compiled and started running but never returned within "
			+ "%.0fs — the code is likely stuck in an infinite loop or awaiting a "
			+ "signal/timer that never fires (a backgrounded game window also freezes "
			+ "awaits). Check logs_read(source='game').") % timeout_sec
	_send_error(conn, request_id, ErrorCodes.EVAL_HUNG, message)
	if _log_buffer:
		_log_buffer.log("[debug] !! eval timeout (%s)" % request_id)


func _on_eval_response(data: Array) -> void:
	if data.size() < 2:
		push_warning("MCP debugger: malformed eval response (expected 2 fields, got %d)" % data.size())
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)

	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return

	var result_json: String = data[1] if data.size() > 1 else "null"
	var json := JSON.new()
	var parse_err := json.parse(result_json)
	connection.send_deferred_response(request_id, {
		"data": {
			"result": json.data if parse_err == OK else result_json,
			"source": "game",
		}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_response (%s)" % request_id)


## #518: codes the game side may attach as mcp:eval_error's optional third
## payload element. Allowlisted so a game process can't mint arbitrary
## top-level error codes over the debugger channel; anything else (including
## the legacy two-element payload from an older game helper mid-update)
## falls back to INTERNAL_ERROR exactly as before.
const _GAME_EVAL_ERROR_CODES: Array[String] = [
	ErrorCodes.EVAL_HUNG,
	ErrorCodes.EVAL_RESULT_TOO_LARGE,
]


func _on_eval_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	var code := ErrorCodes.INTERNAL_ERROR
	if data.size() > 2 and str(data[2]) in _GAME_EVAL_ERROR_CODES:
		code = str(data[2])
	_send_error(connection, request_id, code, message)
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_error (%s): %s" % [request_id, message])


## #490: the game sends this at the top of _handle_eval, BEFORE reload() (so it
## survives a parse-error abort). It positively signals "the game received this
## eval and started compiling it" — letting _on_eval_grace tell a real parse
## error (acked, never compiled) apart from a message the game hasn't serviced
## yet (never acked — main thread blocked by a long frame/load or a CPU-bound
## prior eval).
func _on_eval_ack(data: Array) -> void:
	if data.is_empty():
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	pending_entry["acked"] = true
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_ack (%s)" % request_id)


## #490: compile-grace timer fired. Conclude a parse error ONLY when the game
## acked the eval (started reload()) but never sent mcp:eval_compiled. If it
## never acked, the game simply hasn't serviced the message yet — NOT a parse
## error — so leave _pending intact and let the normal eval timeout handle it
## rather than false-failing a valid eval and dropping its eventual real reply.
func _on_eval_grace(request_id: String) -> void:
	var pending_entry = _pending.get(request_id)
	if pending_entry == null or pending_entry.get("compiled", false):
		return
	if not pending_entry.get("acked", false):
		if _log_buffer:
			_log_buffer.log("[debug] eval grace: no ack yet, deferring to timeout (%s)" % request_id)
		return
	_clear_pending(request_id)
	var conn: McpConnection = pending_entry.connection
	if conn == null or not is_instance_valid(conn):
		return
	_send_error(conn, request_id, ErrorCodes.EVAL_COMPILE_ERROR,
		"Game eval failed to compile — likely a GDScript syntax/parse error. The parse error text is in the editor's Output/Debugger panel; it is not capturable from the running game. Check your eval code's syntax.")
	if _log_buffer:
		_log_buffer.log("[debug] !! eval compile error (%s)" % request_id)


## #490: the game sends this the instant reload() of the eval source
## succeeds. Flips the pending entry's `compiled` flag so the compile-grace
## timer won't fire a false EVAL_COMPILE_ERROR.
func _on_eval_compiled(data: Array) -> void:
	if data.is_empty():
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	pending_entry["compiled"] = true
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_compiled (%s)" % request_id)
	## #490: compiled OK — start polling for a runtime error that may have
	## aborted execute(). A backgrounded game can't self-report it, so the
	## editor probes via mcp:eval_check until the eval resolves.
	_arm_eval_probe(request_id)


## #490: the game reported a runtime error that aborted the eval — either
## from its _process fast path (focused game) or in answer to an editor
## eval_check probe (backgrounded game). Reply fast with the real error text
## instead of waiting for the hang timeout.
func _on_eval_runtime_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	var msg := "Game eval raised a runtime error: %s" % message if not message.is_empty() else "Game eval raised a runtime error (no message captured). Check logs_read(source='game')."
	_send_error(connection, request_id, ErrorCodes.EVAL_RUNTIME_ERROR, msg)
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_runtime_error (%s): %s" % [request_id, message])


## #490: arm one probe tick for an in-flight eval. Re-arms itself each tick
## until the request resolves — eval_response / eval_runtime_error /
## eval_compile_error / hang-timeout all call _clear_pending, which erases the
## entry and stops the chain. Uses the editor's own SceneTreeTimer because the
## editor loop keeps ticking even while a backgrounded game's loop is frozen.
func _arm_eval_probe(request_id: String) -> void:
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var probe_timer: SceneTreeTimer = tree.create_timer(EVAL_PROBE_INTERVAL_SEC)
	var probe_callable := func() -> void: _on_eval_probe_tick(request_id)
	pending_entry["probe_timer"] = probe_timer
	pending_entry["probe_callable"] = probe_callable
	probe_timer.timeout.connect(probe_callable)


## #490: poke the game for a runtime-error verdict, then re-arm. The game's
## _handle_eval_check answers with mcp:eval_runtime_error if a script error
## aborted this eval, else stays silent and we poll again next interval.
func _on_eval_probe_tick(request_id: String) -> void:
	if not _pending.has(request_id):
		return  ## resolved — stop probing
	var session: EditorDebuggerSession = _first_active_session()
	if session != null and session.is_active():
		session.send_message("mcp:eval_check", [request_id])
	_arm_eval_probe(request_id)


## --- game_command: curated runtime game operations ---

func request_game_command(
	op: String,
	params: Dictionary,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float = 10.0,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: game command request missing request_id")
		return

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree — cannot schedule game command")
		return

	if is_game_capture_ready():
		_send_game_command(tree, op, params, request_id, connection, timeout_sec)
		return

	if _log_buffer:
		_log_buffer.log("[debug] waiting for game_helper hello before game_command (%s)" % request_id)
	_wait_then_game_command(tree, op, params, request_id, connection, timeout_sec)


func _wait_then_game_command(
	tree: SceneTree,
	op: String,
	params: Dictionary,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var deadline := Time.get_ticks_msec() + int(GAME_READY_WAIT_SEC * 1000.0)
	## #645: the leading yield guarantees the dispatcher has registered the
	## deferred request before any reply (a same-frame reply is dropped as
	## expired); the break check bails out early because a parked game never
	## registers its capture.
	await tree.process_frame
	while not is_game_capture_ready() and not _break_active and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not is_game_capture_ready():
		_send_error_response(connection, request_id,
			_explain_not_live(get_game_status(-1, GAME_READY_WAIT_SEC), ErrorCodes.INTERNAL_ERROR))
		return
	_send_game_command(tree, op, params, request_id, connection, timeout_sec)


func _send_game_command(
	tree: SceneTree,
	op: String,
	params: Dictionary,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"No active debugger session — is the game actually running?")
		return

	var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
	var timeout_callable := func() -> void:
		var pending_entry = _pending.get(request_id)
		if pending_entry == null:
			return
		_pending.erase(request_id)
		var conn: McpConnection = pending_entry.connection
		if conn == null or not is_instance_valid(conn):
			return
		_send_error(conn, request_id, ErrorCodes.INTERNAL_ERROR,
			"Game command '%s' timed out after %.0fs" % [op, timeout_sec])
		if _log_buffer:
			_log_buffer.log("[debug] !! game_command timeout (%s)" % request_id)
	timer.timeout.connect(timeout_callable)
	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
	}

	session.send_message("mcp:game_command", [request_id, op, JSON.stringify(params)])
	if _log_buffer:
		_log_buffer.log("[debug] -> mcp:game_command %s (%s)" % [op, request_id])


func _on_game_command_response(data: Array) -> void:
	if data.size() < 2:
		push_warning("MCP debugger: malformed game_command response (expected 2 fields, got %d)" % data.size())
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)

	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return

	var result_json: String = data[1] if data.size() > 1 else "{}"
	var json := JSON.new()
	var parse_err := json.parse(result_json)
	connection.send_deferred_response(request_id, {
		"data": json.data if parse_err == OK else {"source": "game", "result": result_json}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:game_command_response (%s)" % request_id)


func _on_game_command_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, message)
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:game_command_error (%s): %s" % [request_id, message])
