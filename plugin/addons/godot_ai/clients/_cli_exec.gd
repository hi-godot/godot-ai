@tool
class_name McpCliExec
extends RefCounted

## Wall-clock-bounded CLI invocation. Every dock shell-out to a per-client
## CLI (`claude mcp list`, `claude mcp add ...`, etc.) goes through here so
## a hung subprocess can't trap the calling thread forever.
##
## Without the timeout, a contended `claude mcp list` has been observed to
## hang for 6+ minutes (issues #238, #239) — wedging the dock's status
## refresh worker, and on the Configure / Remove paths the editor main
## thread itself.
##
## Why poll/kill instead of `OS.execute(..., true)`: GDScript can't
## interrupt a blocking `OS.execute`, so a hung CLI takes its caller's
## thread with it. `OS.execute_with_pipe` returns immediately with a PID;
## we drive the wait ourselves and `OS.kill` the orphan if budget
## expires. CLI registry commands have bounded output (a few hundred
## bytes), so we don't bother draining the pipe during the poll loop —
## the kernel buffer absorbs it.
##
## Returns a Dictionary with:
##   exit_code:    process exit code (0 = success). -1 on timeout / spawn failure.
##   stdout:       captured stdout+stderr text. May be partial on timeout.
##   timed_out:    true if we killed the process at the wall-clock budget.
##   spawn_failed: true if `OS.execute_with_pipe` didn't return a usable PID.

const DEFAULT_TIMEOUT_MS := 8000
const _POLL_INTERVAL_MS := 50


static func run(exe: String, args: Array, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> Dictionary:
	if exe.is_empty():
		return _spawn_failed_result()

	var info := OS.execute_with_pipe(exe, args)
	if info.is_empty():
		return _spawn_failed_result()

	var pid: int = int(info.get("pid", -1))
	var stdio: Variant = info.get("stdio", null)
	var stderr_pipe: Variant = info.get("stderr", null)
	if pid <= 0:
		_close_pipes(stdio, stderr_pipe)
		return _spawn_failed_result()

	var deadline := Time.get_ticks_msec() + maxi(timeout_ms, _POLL_INTERVAL_MS)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() >= deadline:
			OS.kill(pid)
			_close_pipes(stdio, stderr_pipe)
			return {
				"exit_code": -1,
				"stdout": "",
				"timed_out": true,
				"spawn_failed": false,
			}
		OS.delay_msec(_POLL_INTERVAL_MS)

	var stdout := ""
	if stdio is FileAccess:
		stdout = (stdio as FileAccess).get_as_text()
	_close_pipes(stdio, stderr_pipe)

	return {
		"exit_code": OS.get_process_exit_code(pid),
		"stdout": stdout,
		"timed_out": false,
		"spawn_failed": false,
	}


static func _spawn_failed_result() -> Dictionary:
	return {
		"exit_code": -1,
		"stdout": "",
		"timed_out": false,
		"spawn_failed": true,
	}


static func _close_pipes(stdio: Variant, stderr_pipe: Variant) -> void:
	if stdio is FileAccess:
		(stdio as FileAccess).close()
	if stderr_pipe is FileAccess:
		(stderr_pipe as FileAccess).close()
