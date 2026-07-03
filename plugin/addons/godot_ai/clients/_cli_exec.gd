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
##   stderr:       captured stderr text. May be partial on timeout. Empty when
##                 `capture_stderr` is false.
##   output:       stdout + (newline + stderr if non-empty). Convenience for
##                 the common case of "show whatever the CLI said when it
##                 failed" — `claude mcp add` writes its real diagnostics to
##                 stderr, so callers that only read `stdout` would surface
##                 a generic "exit code 1" instead.
##   timed_out:    true if we killed the process at the wall-clock budget.
##   spawn_failed: true if `OS.execute_with_pipe` didn't return a usable PID.

const DEFAULT_TIMEOUT_MS := 8000
const _POLL_INTERVAL_MS := 50
const _KILL_GRACE_MS := 500


static func run(
	exe: String,
	args: Array,
	timeout_ms: int = DEFAULT_TIMEOUT_MS,
	capture_stderr: bool = true
) -> Dictionary:
	if exe.is_empty():
		return _spawn_failed_result()
	return _run_piped(exe, args, timeout_ms, capture_stderr)


static func _run_piped(
	exe: String,
	args: Array,
	timeout_ms: int,
	capture_stderr: bool,
) -> Dictionary:

	var spawn_exe := exe
	var spawn_args := args
	if OS.get_name() == "Windows":
		var lower := exe.to_lower()
		if lower.ends_with(".cmd") or lower.ends_with(".bat"):
			## CreateProcessW can't launch `.cmd` / `.bat` scripts on its
			## own — they're cmd.exe input, not PE binaries. Without this
			## wrap, the moment `McpCliFinder` resolves a Node-style shim
			## (npm's `claude.cmd`, pnpm's wrappers, …) the next
			## `OS.execute_with_pipe` surfaces "Could not create child
			## process: <path> ..." in Godot's output log (#251). Passing
			## `exe` as a separate argv element keeps spaces in the path
			## quoted by Godot's standard quoter — no manual escaping.
			spawn_exe = "cmd.exe"
			spawn_args = ["/c", exe]
			spawn_args.append_array(args)

	var info := OS.execute_with_pipe(spawn_exe, spawn_args)
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
			## Kill before draining: a pipe read can block while the child is
			## still alive. Once it exits, drain any buffered partial output.
			OS.kill(pid)
			var kill_deadline := Time.get_ticks_msec() + _KILL_GRACE_MS
			while OS.is_process_running(pid) and Time.get_ticks_msec() < kill_deadline:
				OS.delay_msec(_POLL_INTERVAL_MS)

			var partial_stdout := ""
			var partial_stderr := ""
			if not OS.is_process_running(pid):
				partial_stdout = _drain_pipe(stdio)
				partial_stderr = _drain_pipe(stderr_pipe) if capture_stderr else ""
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
	var stderr_text := _drain_pipe(stderr_pipe) if capture_stderr else ""
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
	if not (pipe is FileAccess):
		return ""
	var f := pipe as FileAccess
	var bytes := PackedByteArray()
	var max_bytes := 1 << 20  # 1 MiB, far above expected client CLI output.
	while bytes.size() < max_bytes:
		var chunk := f.get_buffer(mini(4096, max_bytes - bytes.size()))
		if chunk.is_empty():
			break
		bytes.append_array(chunk)
		if f.eof_reached():
			break
	return bytes.get_string_from_utf8()


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
