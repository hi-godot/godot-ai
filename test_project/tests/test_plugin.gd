@tool
extends McpTestSuite

## Tests for the uvx stale-index self-heal in `_start_server` (see #172).
## The full retry path re-spawns via `OS.create_process`, which we can't
## cleanly intercept — so these tests target the pure decision helper
## `_retry_with_refresh_allowed` that gates the retry. Surface area that
## `_should_retry_with_refresh` exercises (static-cache reads, pid-file
## I/O) is deliberately kept out of the helper under test.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")


func suite_name() -> String:
	return "plugin"


func test_retry_fires_on_uvx_tier_with_no_pid_file() -> void:
	## Classic stale-index scenario: uvx resolved the release to nothing,
	## Python never ran (so no pid-file), and we haven't retried yet.
	assert_true(
		GodotAiPlugin._retry_with_refresh_allowed(false, "uvx", 0),
		"uvx tier + no pid-file + not retried must trigger the --refresh retry",
	)


func test_no_retry_on_dev_venv_tier() -> void:
	## `--refresh` is a uvx-only flag. Dev-venv spawns `python -m godot_ai`,
	## which has no resolve step to refresh — retrying would be a no-op.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(false, "dev_venv", 0),
		"dev_venv tier must not attempt a --refresh retry",
	)


func test_no_retry_on_system_tier() -> void:
	## System installs don't go through uvx either.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(false, "system", 0),
		"system tier must not attempt a --refresh retry",
	)


func test_no_retry_when_already_retried() -> void:
	## One-shot guard: once we've retried, subsequent spawn failures must
	## fall through to CRASHED instead of looping on --refresh.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(true, "uvx", 0),
		"already-retried must skip even on uvx with no pid-file",
	)


func test_no_retry_when_pid_file_present() -> void:
	## Python wrote its pid-file, then the process died — that's a real
	## Python-side crash, not a uvx resolve failure. `--refresh` won't
	## help; the user needs the traceback in Godot's output log.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(false, "uvx", 12345),
		"pid-file present means Python started — don't blame uvx",
	)


func test_get_server_command_with_refresh_inserts_flag_on_uvx_tier() -> void:
	## End-to-end sanity for the refresh param plumbed into
	## `get_server_command`. Only meaningful when the current env
	## actually resolves to the uvx tier.
	if McpClientConfigurator.get_server_launch_mode() != "uvx":
		skip("only meaningful on uvx tier")
		return
	var cmd_plain := McpClientConfigurator.get_server_command(false)
	var cmd_refresh := McpClientConfigurator.get_server_command(true)
	assert_false(cmd_plain.is_empty(), "uvx-tier plain command must be non-empty")
	assert_false(cmd_refresh.is_empty(), "uvx-tier refresh command must be non-empty")
	assert_eq(cmd_refresh[0], cmd_plain[0], "uvx executable must match between variants")
	assert_eq(cmd_refresh[1], "--refresh", "--refresh must land as cmd[1], before --from")
	assert_eq(cmd_refresh[2], "--from", "plain --from must follow --refresh")
	assert_eq(cmd_refresh.size(), cmd_plain.size() + 1, "refresh variant must add exactly one flag")


func test_get_server_command_default_omits_refresh() -> void:
	## Warm-path invariant: the default no-arg call never adds --refresh.
	## Covers every existing caller (start_dev_server, _start_server's
	## first spawn, etc.) that relies on the flag-free shape.
	var cmd := McpClientConfigurator.get_server_command()
	if cmd.is_empty():
		skip("no server command available in this env")
		return
	for token in cmd:
		assert_ne(token, "--refresh", "default get_server_command must never include --refresh")


func test_headless_launch_disables_mcp_by_default() -> void:
	assert_true(
		GodotAiPlugin._mcp_disabled_for_headless(PackedStringArray(["--headless", "--editor"]), "", ""),
		"--headless must disable MCP startup by default"
	)
	assert_true(
		GodotAiPlugin._mcp_disabled_for_headless(PackedStringArray(["--editor"]), "headless", ""),
		"headless DisplayServer must disable MCP startup by default"
	)


func test_headless_launch_allows_explicit_override() -> void:
	assert_false(
		GodotAiPlugin._mcp_disabled_for_headless(PackedStringArray(["--headless", "--editor"]), "headless", "1"),
		"GODOT_AI_ALLOW_HEADLESS=1 must preserve CI/headless MCP sessions"
	)
	assert_false(
		GodotAiPlugin._mcp_disabled_for_headless(PackedStringArray(["--headless", "--editor"]), "headless", "true"),
		"truthy GODOT_AI_ALLOW_HEADLESS values must preserve MCP startup"
	)


func test_display_driver_headless_args_disable_mcp() -> void:
	assert_true(
		GodotAiPlugin._mcp_disabled_for_headless(PackedStringArray(["--display-driver", "headless"]), "", ""),
		"--display-driver headless must disable MCP startup"
	)
	assert_true(
		GodotAiPlugin._mcp_disabled_for_headless(PackedStringArray(["--display-driver=headless"]), "", ""),
		"--display-driver=headless must disable MCP startup"
	)


func test_resolve_ws_port_from_output_skips_reserved_configured_port() -> void:
	var output := """
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
    9491          9590
    9591          9690
"""
	assert_eq(
		GodotAiPlugin._resolve_ws_port_from_output(9500, output),
		9691,
		"configured WS port inside adjacent excluded ranges should move to first clear port",
	)


func test_resolve_ws_port_from_output_keeps_unreserved_configured_port() -> void:
	var output := """
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
    9491          9590
"""
	assert_eq(
		GodotAiPlugin._resolve_ws_port_from_output(10500, output),
		10500,
		"unreserved configured WS port should stay stable",
	)


func test_pid_alive_rejects_zombie_children() -> void:
	## Regression guard for the zombie-blindness that defeated the first
	## draft of the retry wiring: `kill -0` returns success for BOTH
	## running and zombie processes, and Godot never `waitpid`s on its
	## `OS.create_process` children. A fast-failing uvx launcher would
	## linger as a zombie, `_pid_alive` would report true forever, and
	## the "launcher died" branch in `_check_server_health` (which
	## gates both CRASHED transitions and the --refresh retry) would
	## never fire. See #172.
	if OS.get_name() == "Windows":
		## Windows doesn't have POSIX zombies — `tasklist` shows the
		## process as gone the moment it exits.
		skip("zombie semantics are POSIX-specific")
		return
	var pid := OS.create_process("sleep", ["0"])
	assert_gt(pid, 0, "must successfully spawn the sleep child")
	## Give the child time to exit and enter zombie state (waiting for
	## its parent — us — to reap it). 300ms is generous for a `sleep 0`
	## that exits essentially instantly; under load 100ms can be flaky.
	OS.delay_msec(300)
	assert_false(
		GodotAiPlugin._pid_alive(pid),
		"zombie (exited, unreaped) child must NOT be reported as alive",
	)


func test_pid_alive_reports_running_process_as_alive() -> void:
	## Positive case: our own process PID must be reported alive. Pairs
	## with the zombie test — catches a regression where the ps-based
	## check became too strict (e.g. rejects normal sleeping processes).
	var own_pid := OS.get_process_id()
	assert_gt(own_pid, 0, "sanity: OS.get_process_id must return a positive pid")
	assert_true(
		GodotAiPlugin._pid_alive(own_pid),
		"the test runner's own process must be reported as alive",
	)


func test_pid_alive_returns_false_for_nonexistent_pid() -> void:
	## PID 1 (init/launchd) always exists on any running POSIX system, so
	## use a high PID that's essentially guaranteed free. `ps` exits non-zero
	## when the PID doesn't exist, which must map to false, not true.
	assert_false(
		GodotAiPlugin._pid_alive(2147483646),
		"a non-existent PID must be reported as dead",
	)
	assert_false(GodotAiPlugin._pid_alive(0), "pid <= 0 is never alive")
	assert_false(GodotAiPlugin._pid_alive(-1), "negative pid is never alive")
