@tool
extends McpTestSuite

## Tests for the wall-clock-bounded CLI helper that backs every dock
## shell-out (issues #238 / #239 — a hung `claude mcp list` was wedging
## the worker thread for 6+ minutes; the Configure / Remove paths had the
## same root cause exposed on main).


func suite_name() -> String:
	return "cli_exec"


func test_run_returns_spawn_failed_for_empty_exe() -> void:
	## Empty `exe` is the cheap pre-flight check before we hand anything
	## to the OS. Asserting the dict shape here so callers in
	## `_cli_strategy.gd` can rely on the four keys without optional-key
	## defensiveness at every call site.
	var result := McpCliExec.run("", [])
	assert_true(bool(result.get("spawn_failed", false)),
		"Empty exe must short-circuit as spawn_failed=true")
	assert_false(bool(result.get("timed_out", false)),
		"Spawn failure is not a timeout")
	assert_eq(int(result.get("exit_code", 0)), -1,
		"Spawn failure must surface exit_code=-1 so callers don't read it as success")
	assert_eq(str(result.get("stdout", "x")), "",
		"Spawn failure must return empty stdout")


func test_run_captures_stdout_and_zero_exit_on_quick_command() -> void:
	## End-to-end: spawn `echo hello`, wait for it, capture stdout.
	## Skipped on Windows because the host's `echo` lives inside cmd.exe
	## and isn't reachable as a standalone exe via OS.execute_with_pipe.
	if OS.get_name() == "Windows":
		skip("echo is a cmd.exe builtin on Windows; covered by the Unix path")
		return
	var echo := "/bin/echo"
	if not FileAccess.file_exists(echo):
		echo = "/usr/bin/echo"
	if not FileAccess.file_exists(echo):
		skip("No /bin/echo or /usr/bin/echo on this host")
		return
	var result := McpCliExec.run(echo, ["hello-from-mcpcliexec"], 5000)
	assert_false(bool(result.get("spawn_failed", false)),
		"echo should spawn successfully on POSIX")
	assert_false(bool(result.get("timed_out", false)),
		"echo finishes well inside a 5s budget")
	assert_eq(int(result.get("exit_code", -1)), 0,
		"echo exits 0 on success")
	assert_contains(str(result.get("stdout", "")), "hello-from-mcpcliexec",
		"Captured stdout must include the echoed token")


func test_run_captures_stderr_by_default() -> void:
	var fixture := _stderr_fixture_command(7)
	if fixture.is_empty():
		skip("No shell available for stderr fixture")
		return
	var result := McpCliExec.run(
		fixture["exe"],
		fixture["args"],
		5000
	)
	assert_eq(int(result.get("exit_code", 0)), 7)
	assert_contains(str(result.get("stdout", "")), "stdout-token")
	assert_contains(str(result.get("stderr", "")), "stderr-token")
	assert_contains(str(result.get("output", "")), "stderr-token")


func test_run_can_skip_stderr_capture_for_status_probe() -> void:
	var fixture := _stderr_fixture_command(0)
	if fixture.is_empty():
		skip("No shell available for stderr fixture")
		return
	var result := McpCliExec.run(
		fixture["exe"],
		fixture["args"],
		5000,
		false
	)
	assert_eq(int(result.get("exit_code", -1)), 0)
	assert_contains(str(result.get("stdout", "")), "stdout-token")
	assert_eq(str(result.get("stderr", "")), "")
	assert_false(
		str(result.get("output", "")).find("stderr-token") >= 0,
		"status probes skip stderr drain to avoid expected empty-pipe noise"
	)


func test_run_kills_subprocess_when_budget_expires() -> void:
	## The headline behavior: a hung CLI no longer hangs the editor.
	## Spawn `sleep 5` with a 200ms budget — McpCliExec should kill it
	## and return timed_out=true. The whole assertion path must complete
	## in well under 5s; if it doesn't, the kill regressed and the test
	## suite itself surfaces the same wedge the issue describes.
	if OS.get_name() == "Windows":
		skip("Windows lacks `sleep` as a standalone exe; cover via Unix")
		return
	var sleep_exe := "/bin/sleep"
	if not FileAccess.file_exists(sleep_exe):
		sleep_exe = "/usr/bin/sleep"
	if not FileAccess.file_exists(sleep_exe):
		skip("No /bin/sleep or /usr/bin/sleep on this host")
		return
	var started_msec := Time.get_ticks_msec()
	var result := McpCliExec.run(sleep_exe, ["5"], 200)
	var elapsed_msec := Time.get_ticks_msec() - started_msec
	assert_true(bool(result.get("timed_out", false)),
		"sleep 5 with 200ms budget must surface timed_out=true")
	assert_eq(int(result.get("exit_code", 0)), -1,
		"timed_out runs must report exit_code=-1 — never a real exit code")
	assert_true(elapsed_msec < 3000,
		"Timeout kill must return within ~budget+poll, not wait for sleep to finish (elapsed=%dms)" % elapsed_msec)


func test_run_wraps_cmd_files_through_cmd_exe_on_windows() -> void:
	## Regression for #251: `McpCliFinder` resolving a Node-style CLI to
	## its `.cmd` wrapper used to trip CreateProcessW with
	## `ERROR: Could not create child process: <path> ...`.
	## `McpCliExec.run` now wraps `.cmd` paths via `cmd.exe /c`, so the
	## wrapper actually runs and we capture its stdout.
	if OS.get_name() != "Windows":
		skip(".cmd shell-out is Windows-only; the wrap path is a no-op elsewhere")
		return
	var script_path := OS.get_user_data_dir().path_join("mcp_cli_exec_smoke.cmd")
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	assert_true(f != null, "Should be able to write a temp .cmd fixture under user://")
	if f == null:
		return
	## `@echo off` keeps `claude.cmd`-style banners from polluting stdout —
	## the assertion below only cares that our explicit token came through.
	f.store_string("@echo off\r\necho cli-exec-cmd-token %1\r\n")
	f.close()
	var result := McpCliExec.run(script_path, ["arg-from-mcp"], 5000)
	assert_false(bool(result.get("spawn_failed", false)),
		".cmd files must spawn successfully via the cmd.exe wrap")
	assert_false(bool(result.get("timed_out", false)),
		"echo-only .cmd finishes well inside 5s")
	assert_eq(int(result.get("exit_code", -1)), 0,
		".cmd should exit 0 on success")
	assert_contains(str(result.get("stdout", "")), "cli-exec-cmd-token arg-from-mcp",
		"Captured stdout must include the echoed token and forwarded arg")
	DirAccess.remove_absolute(script_path)


func _stderr_fixture_command(exit_code: int) -> Dictionary:
	if OS.get_name() == "Windows":
		return {
			"exe": "cmd.exe",
			"args": [
				"/c",
				"echo stdout-token & echo stderr-token 1>&2 & exit /b %d" % exit_code
			]
		}
	var shell := _find_posix_shell()
	if shell.is_empty():
		return {}
	return {
		"exe": shell,
		"args": [
			"-c",
			"printf 'stdout-token'; printf 'stderr-token' >&2; exit %d" % exit_code
		]
	}


func _find_posix_shell() -> String:
	if FileAccess.file_exists("/bin/sh"):
		return "/bin/sh"
	if FileAccess.file_exists("/usr/bin/sh"):
		return "/usr/bin/sh"
	return ""
