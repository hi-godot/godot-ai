@tool
extends McpTestSuite

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")


func suite_name() -> String:
	return "plugin"


func test_v4_requires_godot_4_7_or_newer_within_4_x() -> void:
	assert_false(GodotAiPlugin._supports_godot_version({"major": 4, "minor": 5}))
	assert_false(GodotAiPlugin._supports_godot_version({"major": 4, "minor": 6}))
	assert_true(GodotAiPlugin._supports_godot_version({"major": 4, "minor": 7}))
	assert_true(GodotAiPlugin._supports_godot_version({"major": 4, "minor": 8}))
	assert_false(GodotAiPlugin._supports_godot_version({"major": 5, "minor": 0}))
	assert_false(GodotAiPlugin._supports_godot_version({}))


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
		PortResolver.resolve_ws_port_from_output(9500, output, McpClientConfigurator.MAX_PORT),
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
		PortResolver.resolve_ws_port_from_output(10500, output, McpClientConfigurator.MAX_PORT),
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
		McpPortResolver.pid_alive(pid),
		"zombie (exited, unreaped) child must NOT be reported as alive",
	)


func test_pid_alive_reports_running_process_as_alive() -> void:
	## Positive case: our own process PID must be reported alive. Pairs
	## with the zombie test — catches a regression where the ps-based
	## check became too strict (e.g. rejects normal sleeping processes).
	var own_pid := OS.get_process_id()
	assert_gt(own_pid, 0, "sanity: OS.get_process_id must return a positive pid")
	assert_true(
		McpPortResolver.pid_alive(own_pid),
		"the test runner's own process must be reported as alive",
	)


func test_pid_alive_returns_false_for_nonexistent_pid() -> void:
	## PID 1 (init/launchd) always exists on any running POSIX system, so
	## use a high PID that's essentially guaranteed free. `ps` exits non-zero
	## when the PID doesn't exist, which must map to false, not true.
	assert_false(
		McpPortResolver.pid_alive(2147483646),
		"a non-existent PID must be reported as dead",
	)
	assert_false(McpPortResolver.pid_alive(0), "pid <= 0 is never alive")
	assert_false(McpPortResolver.pid_alive(-1), "negative pid is never alive")
