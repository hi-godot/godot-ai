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
##   stdout:       captured stdout text. May be partial on timeout.
##   stderr:       captured stderr text. May be partial on timeout.
##   output:       stdout + (newline + stderr if non-empty). Convenience for
##                 the common case of "show whatever the CLI said when it
##                 failed" — `claude mcp add` writes its real diagnostics to
##                 stderr, so callers that only read `stdout` would surface
##                 a generic "exit code 1" instead.
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
			## Read whatever made it to the pipes before we kill the
			## process — partial output beats blank "timed out" when the
			## CLI was emitting useful diagnostics on its way to hanging.
			var partial_stdout := _drain_pipe(stdio)
			var partial_stderr := _drain_pipe(stderr_pipe)
			OS.kill(pid)
			_close_pipes(stdio, stderr_pipe)
			return {
				"exit_code": -1,
				"stdout": partial_stdout,
				"stderr": partial_stderr,
				"output": _join_streams(partial_stdout, partial_stderr),
				"timed_out": true,
				"spawn_failed": false,
			}
		OS.delay_msec(_POLL_INTERVAL_MS)

	var stdout := _drain_pipe(stdio)
	var stderr_text := _drain_pipe(stderr_pipe)
	_close_pipes(stdio, stderr_pipe)

	return {
		"exit_code": OS.get_process_exit_code(pid),
		"stdout": stdout,
		"stderr": stderr_text,
		"output": _join_streams(stdout, stderr_text),
		"timed_out": false,
		"spawn_failed": false,
	}


static func _spawn_failed_result() -> Dictionary:
	return {
		"exit_code": -1,
		"stdout": "",
		"stderr": "",
		"output": "",
		"timed_out": false,
		"spawn_failed": true,
	}


static func _drain_pipe(pipe: Variant) -> String:
	if pipe is FileAccess:
		return (pipe as FileAccess).get_as_text()
	return ""


static func _join_streams(stdout: String, stderr_text: String) -> String:
	## Most CLIs write their actionable diagnostics to one stream or the
	## other, never both — so concatenation gives "the message" without
	## the caller having to guess which key to read. Newline-separate so
	## callers that grep don't see two lines run together.
	if stderr_text.is_empty():
		return stdout
	if stdout.is_empty():
		return stderr_text
	return "%s\n%s" % [stdout, stderr_text]


static func _close_pipes(stdio: Variant, stderr_pipe: Variant) -> void:
	if stdio is FileAccess:
		(stdio as FileAccess).close()
	if stderr_pipe is FileAccess:
		(stderr_pipe as FileAccess).close()
