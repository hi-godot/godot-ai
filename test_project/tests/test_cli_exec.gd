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
