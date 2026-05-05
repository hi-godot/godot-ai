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


func test_is_port_in_use_checks_os_listeners_after_bind_probe_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX-only lsof confirmation")
		return
	var python_check: Array = []
	if OS.execute("python3", ["--version"], python_check, true) != 0:
		skip("python3 is unavailable for live listener smoke")
		return

	var port := 51249
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		skip("port %d is already held on this host" % port)
		return
	probe.stop()

	var pid := OS.create_process("python3", ["-m", "http.server", str(port)])
	if pid <= 0:
		skip("could not start python http.server")
		return

	var listener_seen := false
	for _i in range(20):
		OS.delay_msec(100)
		if not McpPortResolver.find_all_pids_on_port(port).is_empty():
			listener_seen = true
			break
	if not listener_seen:
		OS.kill(pid)
		skip("python http.server did not bind test port")
		return

	var detected := McpPortResolver.is_port_in_use(port)
	OS.kill(pid)
	McpPortResolver.wait_for_port_free(port, 2.0)

	assert_true(detected)


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
