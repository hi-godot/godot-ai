@tool
class_name McpServerSpawn
extends RefCounted

## Spawns the MCP server via `OS.execute_with_pipe` and captures
## stdout/stderr so the dock can surface crashes instead of spinning
## in "reconnecting…" forever. See issue #146.
##
## Usage:
##   var spawn := McpServerSpawn.new()
##   var pid := spawn.start(cmd, args)
##   # every frame while watching:
##   if spawn.tick():
##       var info := spawn.exit_info(port)
##       # info.output, info.output_text, info.hint, info.elapsed_msec
##
## The watch window (SPAWN_WATCH_MSEC) exists to catch startup crashes
## without tying the editor to the child process for its entire life —
## a healthy server living 60+ seconds is considered "up" and the helper
## releases the pipes.

## Watch window after spawn, in ms. Anything that survives this long
## without exiting is considered a healthy startup and we stop draining.
const SPAWN_WATCH_MSEC := 15 * 1000

## Cap on retained output lines (ring buffer). Errors are usually small
## (< 30 lines); the cap exists to bound memory if someone misconfigures
## the server to spew before exiting.
const MAX_OUTPUT_LINES := 60

## How often `tick()` actually probes liveness / drains pipes. `tick()`
## can be called every frame, but `_is_pid_alive` shells out to `kill -0`
## / `tasklist` which is too expensive to run at 60 Hz.
const POLL_INTERVAL_MSEC := 500

## Safety cap on lines pulled from a single pipe in one drain pass, so a
## chatty child can't monopolise the frame. Any remaining lines are
## picked up on the next tick (or the final post-exit drain).
const MAX_LINES_PER_DRAIN := 200

## Hint ID constants. Returned in the "id" field of classify_error so
## callers/tests can match without stringly-typed comparisons.
const HINT_WINERROR_10013 := "winerror_10013"
const HINT_PORT_IN_USE := "port_in_use"
const HINT_MISSING_MODULE := "missing_module"

var pid: int = -1
var _stdio: FileAccess
var _stderr: FileAccess
var _output_lines: Array[String] = []
var _spawn_msec: int = 0
var _exited := false
var _exit_observed_msec: int = 0
var _last_poll_msec: int = 0


## Pure helper: turn captured server output into a one-liner hint the
## dock can display above the raw output. Returns {"id": String, "text": String};
## `id` is "" when no pattern matched. Public-static so it's easily tested.
static func classify_error(output_text: String, port: int) -> Dictionary:
	var lower := output_text.to_lower()
	## Windows port reservation (Hyper-V / WSL2 / Docker Desktop) —
	## different code from plain "in use". See issue #146 motivating case.
	if lower.find("winerror 10013") >= 0 or lower.find("forbidden by its access permissions") >= 0:
		return {
			"id": HINT_WINERROR_10013,
			"text": (
				"Port %d is reserved by Windows (often Hyper-V / WSL2 / Docker Desktop). "
				+ "In an admin PowerShell: `net stop winnat; net start winnat`, then click Restart."
			) % port,
		}
	if (lower.find("winerror 10048") >= 0
			or lower.find("errno 98") >= 0
			or lower.find("address already in use") >= 0):
		return {
			"id": HINT_PORT_IN_USE,
			"text": (
				"Port %d is already in use. Stop the process holding it, or configure a different MCP port."
			) % port,
		}
	if lower.find("modulenotfounderror") >= 0 or lower.find("no module named") >= 0:
		return {
			"id": HINT_MISSING_MODULE,
			"text": "Python module missing — the uv cache may be corrupt. Try `uv cache clean`, then click Restart.",
		}
	return {"id": "", "text": ""}


## Spawn the server. Returns the child PID on success, -1 on failure.
## If `OS.execute_with_pipe` returns an empty Dictionary (unsupported or
## failed spawn), falls back to fire-and-forget `OS.create_process` — the
## crash banner can't light up for that fallback spawn (no pipes), so the
## helper is unusable for monitoring and the caller should drop it.
## `was_piped()` reports which path was taken.
func start(cmd: String, args: PackedStringArray) -> int:
	_reset()
	var result := OS.execute_with_pipe(cmd, args, false)
	if result.is_empty():
		pid = OS.create_process(cmd, args)
		return pid
	pid = int(result.get("pid", -1))
	_stdio = result.get("stdio", null)
	_stderr = result.get("stderr", null)
	_spawn_msec = Time.get_ticks_msec()
	return pid


## True iff the last `start()` successfully opened pipes and we can
## monitor the child. False after the `OS.create_process` fallback —
## callers use this to skip registering the spawn for ticking.
func was_piped() -> bool:
	return _spawn_msec != 0


## Poll the child once. Drains any available stdout/stderr into the
## ring buffer and checks whether the process has exited. Returns true
## on the first tick where the exit is observed; false otherwise.
##
## Call repeatedly (e.g. from the dock's `_process`) until either the
## exit is detected or `is_past_watch_window()` returns true — at which
## point call `release()` to drop the pipes.
func tick() -> bool:
	if _exited or pid <= 0:
		return false
	var now := Time.get_ticks_msec()
	if now - _last_poll_msec < POLL_INTERVAL_MSEC:
		return false
	_last_poll_msec = now
	_drain()
	if not _is_pid_alive(pid):
		_exited = true
		_exit_observed_msec = now
		## One final drain: the child has closed its pipe ends, so any
		## last bytes are now readable without blocking.
		_drain()
		return true
	return false


## True once the spawn-watch window has elapsed. Used by the owner to
## decide when to stop polling a server that started cleanly.
func is_past_watch_window() -> bool:
	if _spawn_msec == 0:
		return false
	return Time.get_ticks_msec() - _spawn_msec > SPAWN_WATCH_MSEC


func is_exited() -> bool:
	return _exited


## Snapshot of exit state for the dock. Empty when the child is still
## alive (or was never spawned). `OS.execute_with_pipe` doesn't expose a
## real exit code to the parent, so we omit it — the captured output is
## the actionable signal.
func exit_info(port: int) -> Dictionary:
	if not _exited:
		return {}
	var output_text := "\n".join(_output_lines)
	var hint := classify_error(output_text, port)
	var elapsed_msec := _exit_observed_msec - _spawn_msec
	return {
		"output": _output_lines.duplicate(),
		"output_text": output_text,
		"hint": hint,
		"elapsed_msec": elapsed_msec,
	}


## Drop the pipes so the FileAccess handles close. Safe to call
## multiple times.
func release() -> void:
	_stdio = null
	_stderr = null


func _reset() -> void:
	pid = -1
	_stdio = null
	_stderr = null
	_output_lines.clear()
	_spawn_msec = 0
	_exited = false
	_exit_observed_msec = 0
	_last_poll_msec = 0


func _drain() -> void:
	var pipes: Array[FileAccess] = [_stdio, _stderr]
	for pipe in pipes:
		if pipe == null:
			continue
		for _i in MAX_LINES_PER_DRAIN:
			if pipe.eof_reached():
				break
			var line := pipe.get_line()
			## `get_line()` on a non-blocking pipe returns "" when no
			## data is ready. It also returns "" for a real empty line
			## in the stream; we accept that minor noise (a blank line
			## is rarely load-bearing in Python tracebacks) rather than
			## risk blocking the editor with a byte-at-a-time read.
			if line.is_empty():
				break
			_output_lines.append(line)
			if _output_lines.size() > MAX_OUTPUT_LINES:
				_output_lines.remove_at(0)


## Duplicated from `plugin.gd::_pid_alive` on purpose — keeps this
## helper self-contained. Keep the two implementations in sync if
## either one grows.
static func _is_pid_alive(p: int) -> bool:
	if p <= 0:
		return false
	if OS.get_name() == "Windows":
		var output: Array = []
		var exit_code := OS.execute("tasklist", ["/FI", "PID eq %d" % p, "/NH", "/FO", "CSV"], output, true)
		if exit_code != 0 or output.is_empty():
			return false
		for line in output:
			if str(line).find("\"%d\"" % p) >= 0:
				return true
		return false
	var exit_code := OS.execute("kill", ["-0", str(p)], [], true)
	return exit_code == 0
