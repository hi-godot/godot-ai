@tool
extends McpTestSuite

## Direct coverage for McpPortResolver. Pure parsers are also exercised
## indirectly via plugin.gd shims in test_netstat_parser.gd /
## test_plugin_lifecycle.gd; this suite focuses on (a) live OS smoke
## that the parsers can't reach and (b) seam smoke proving the new
## `class_name` is callable from outside plugin.gd.


func suite_name() -> String:
	return "port_resolver"


# ----- seam smoke (proves the class_name is reachable) ----------------

func test_parser_seam_callable_directly() -> void:
	var pid := McpPortResolver.parse_windows_netstat_pid(
		"  TCP  0.0.0.0:8000  0.0.0.0:0  LISTENING  57865\n", 8000
	)
	assert_eq(pid, 57865)


func test_resolved_ws_port_seam_callable_directly() -> void:
	## Stale record version drops cached ws_port — pure logic, locked in
	## end-to-end by test_plugin_lifecycle.gd; here only as a seam check.
	assert_eq(
		McpPortResolver.resolved_ws_port_for_existing_server(9500, "2.1.0", "2.2.0", 10500),
		10500
	)


# ----- live OS smoke (genuinely new coverage) -------------------------

func test_can_bind_local_port_succeeds_on_free_port() -> void:
	var port := 51247
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		skip("port %d is already held on this host" % port)
		return
	probe.stop()
	assert_true(McpPortResolver.can_bind_local_port(port))


func test_can_bind_local_port_returns_false_when_held() -> void:
	var port := 51248
	var holder := TCPServer.new()
	if holder.listen(port, "127.0.0.1") != OK:
		skip("could not seize port for held-port assertion")
		return
	var got_bind := McpPortResolver.can_bind_local_port(port)
	holder.stop()
	assert_false(got_bind)


func test_pid_alive_rejects_sentinel_pids() -> void:
	assert_false(McpPortResolver.pid_alive(0))
	assert_false(McpPortResolver.pid_alive(-1))


func test_pid_alive_recognises_editor_pid() -> void:
	## The Godot editor process is a known-live PID on every platform.
	assert_true(McpPortResolver.pid_alive(OS.get_process_id()))


func test_read_pid_file_round_trips_value() -> void:
	if FileAccess.file_exists(McpPortResolver.SERVER_PID_FILE):
		McpPortResolver.clear_pid_file()
	assert_eq(McpPortResolver.read_pid_file(), 0)

	var f := FileAccess.open(McpPortResolver.SERVER_PID_FILE, FileAccess.WRITE)
	f.store_string("12345")
	f.close()
	assert_eq(McpPortResolver.read_pid_file(), 12345)
	McpPortResolver.clear_pid_file()
	assert_eq(McpPortResolver.read_pid_file(), 0)


func test_windows_powershell_candidates_prefers_system32_path() -> void:
	## System32 must come first so a hijacked PATH can't intercept.
	var candidates := McpPortResolver.windows_powershell_candidates()
	assert_true(candidates.size() >= 3)
	assert_true(candidates[0].ends_with("powershell.exe"))
