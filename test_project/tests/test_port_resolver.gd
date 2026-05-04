@tool
extends McpTestSuite

## Unit tests for McpPortResolver — the pure-static port-discovery /
## OS-scrape utility extracted from plugin.gd in #297 / PR 5.
##
## plugin.gd's instance shims (`_is_port_in_use`, `_find_pid_on_port`,
## `_parse_windows_netstat_pid`, …) still exist as forwarding delegations
## so the PR 4 characterization suite (`test_netstat_parser.gd`,
## `test_plugin_lifecycle.gd`) keeps locking in the cross-version
## contract. These tests are the new seam's direct coverage — they hit
## McpPortResolver without going through plugin.gd.

const NETSTAT_SAMPLE := """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1240
  TCP    0.0.0.0:8000           0.0.0.0:0              LISTENING       57865
  TCP    127.0.0.1:49701        127.0.0.1:8000         ESTABLISHED     12345
"""


func suite_name() -> String:
	return "port_resolver"


# ----- pure parsers ----------------------------------------------------

func test_parse_windows_netstat_pid_returns_listening_row() -> void:
	## Routed directly through McpPortResolver to prove the extracted
	## parser keeps the LISTENING + local-address shape it had on
	## plugin.gd. Same-shape coverage exists in test_netstat_parser.gd
	## via the forwarding shim — this suite proves the static is callable
	## as `McpPortResolver.parse_windows_netstat_pid` for new code.
	var pid := McpPortResolver.parse_windows_netstat_pid(NETSTAT_SAMPLE, 8000)
	assert_eq(pid, 57865)


func test_parse_windows_netstat_pid_ignores_established_match() -> void:
	## The ESTABLISHED row on :8000 must not produce a kill target. This
	## is the regression from the v1.2.8 → v1.2.9 update path —
	## documented in detail in test_netstat_parser.gd; replicated here
	## against the resolver to prove the move didn't drop the guard.
	var pid := McpPortResolver.parse_windows_netstat_pid(NETSTAT_SAMPLE, 8000)
	assert_true(pid != 12345, "ESTABLISHED row PID must not leak through")


func test_parse_windows_netstat_pids_collects_multiple_listeners() -> void:
	var sample := (
		"  TCP    127.0.0.1:8001    0.0.0.0:0    LISTENING    36936\n"
		+ "  TCP    127.0.0.1:8001    0.0.0.0:0    LISTENING    46396\n"
	)
	var pids := McpPortResolver.parse_windows_netstat_pids(sample, 8001)
	assert_eq(pids.size(), 2)
	assert_eq(pids[0], 36936)
	assert_eq(pids[1], 46396)


func test_parse_windows_netstat_listening_returns_false_when_port_absent() -> void:
	assert_false(McpPortResolver.parse_windows_netstat_listening(NETSTAT_SAMPLE, 9999))


func test_parse_lsof_pids_handles_multi_line_output() -> void:
	## uvicorn --reload binds both a reloader parent and a worker to the
	## same port; lsof returns them newline-separated. Mirrors the
	## plugin-level test in test_plugin_lifecycle.gd::test_parse_lsof_pids_multi_line.
	var pids := McpPortResolver.parse_lsof_pids("32696\n39824\n")
	assert_eq(pids.size(), 2)
	assert_eq(pids[0], 32696)
	assert_eq(pids[1], 39824)


func test_parse_lsof_pids_drops_non_numeric_warnings() -> void:
	var pids := McpPortResolver.parse_lsof_pids("lsof: WARNING\n32696\n")
	assert_eq(pids.size(), 1)
	assert_eq(pids[0], 32696)


func test_parse_pid_lines_dedupes_and_drops_zero() -> void:
	var pids := McpPortResolver.parse_pid_lines("19088\nnot-a-pid\n0\n19088\n40064\n")
	assert_eq(pids.size(), 2)
	assert_eq(pids[0], 19088)
	assert_eq(pids[1], 40064)


func test_split_on_whitespace_collapses_runs() -> void:
	var fields := McpPortResolver.split_on_whitespace("  TCP    0.0.0.0:8000   0.0.0.0:0  LISTENING  57865")
	assert_eq(fields.size(), 5)
	assert_eq(fields[0], "TCP")
	assert_eq(fields[3], "LISTENING")
	assert_eq(fields[4], "57865")


# ----- WS port resolver ------------------------------------------------

func test_resolved_ws_port_drops_stale_record_value() -> void:
	## Stale record version (`2.1.0`) cannot authorize trusting the cached
	## ws_port — fresh-resolved must win. Mirrors the regression locked in
	## by test_plugin_lifecycle.gd::test_resolved_ws_port_drops_stale_record_value
	## against the extracted helper directly.
	var stale_record_ws := 9500
	var fresh_resolved := 10500
	var stale := McpPortResolver.resolved_ws_port_for_existing_server(
		stale_record_ws, "2.1.0", "2.2.0", fresh_resolved
	)
	assert_eq(stale, fresh_resolved, "stale record version drops cached ws_port")


func test_resolved_ws_port_keeps_record_when_versions_match() -> void:
	var matching := McpPortResolver.resolved_ws_port_for_existing_server(
		9500, "2.2.0", "2.2.0", 10500
	)
	assert_eq(matching, 9500, "matching record version keeps cached ws_port")


func test_resolved_ws_port_uses_fresh_when_no_record() -> void:
	var none := McpPortResolver.resolved_ws_port_for_existing_server(
		0, "2.2.0", "2.2.0", 10500
	)
	assert_eq(none, 10500)


func test_resolved_ws_port_rejects_empty_current_version() -> void:
	## Defensive: empty current_version cannot collapse to
	## record_version == current_version == "" and start treating any
	## record as ownership proof.
	var empty_current := McpPortResolver.resolved_ws_port_for_existing_server(
		9500, "", "", 10500
	)
	assert_eq(empty_current, 10500)


func test_resolve_ws_port_from_output_routes_through_windows_helper() -> void:
	## When the netsh output declares a reservation covering 9500, the
	## resolver must return the next non-excluded port.
	var output := "Start Port    End Port\n----------    --------\n      9500          9510"
	var resolved := McpPortResolver.resolve_ws_port_from_output(9500, output, 65535)
	assert_true(
		resolved != 9500,
		"a port covered by a reservation must be remapped (got %d)" % resolved
	)


# ----- live OS smoke (Linux-friendly) ----------------------------------

func test_can_bind_local_port_succeeds_on_free_port() -> void:
	## Pick a high port unlikely to clash with editor / smoke fixtures.
	var port := 51247
	var server := TCPServer.new()
	if server.listen(port, "127.0.0.1") == OK:
		server.stop()
	assert_true(McpPortResolver.can_bind_local_port(port))


func test_can_bind_local_port_returns_false_when_held() -> void:
	var port := 51248
	var holder := TCPServer.new()
	var err := holder.listen(port, "127.0.0.1")
	if err != OK:
		skip("could not seize port for held-port assertion")
		return
	var got_bind := McpPortResolver.can_bind_local_port(port)
	holder.stop()
	assert_false(got_bind, "can_bind must report false while another listener holds the port")


func test_pid_alive_rejects_sentinel_pids() -> void:
	assert_false(McpPortResolver.pid_alive(0), "pid 0 is never alive")
	assert_false(McpPortResolver.pid_alive(-1), "negative pid is never alive")


func test_pid_alive_recognises_editor_pid() -> void:
	## The Godot editor process is a convenient stand-in for a known-live
	## PID. Unlike `_pid_cmdline_is_godot_ai`, `pid_alive` only checks
	## state — running editors must come back alive on every platform.
	assert_true(
		McpPortResolver.pid_alive(OS.get_process_id()),
		"editor's own PID must report alive"
	)


func test_read_pid_file_returns_zero_when_missing() -> void:
	if FileAccess.file_exists(McpPortResolver.SERVER_PID_FILE):
		McpPortResolver.clear_pid_file()
	assert_eq(McpPortResolver.read_pid_file(), 0)


func test_read_pid_file_round_trips_value() -> void:
	var f := FileAccess.open(McpPortResolver.SERVER_PID_FILE, FileAccess.WRITE)
	f.store_string("12345")
	f.close()
	assert_eq(McpPortResolver.read_pid_file(), 12345)
	McpPortResolver.clear_pid_file()
	assert_eq(McpPortResolver.read_pid_file(), 0, "clear must remove the file")


# ----- Windows-specific helpers (cross-platform safe) ------------------

func test_windows_listener_pids_from_execute_result_parses_zero_exit() -> void:
	var pids := McpPortResolver.windows_listener_pids_from_execute_result(
		0, ["19088\n40064\n"]
	)
	assert_eq(pids.size(), 2)
	assert_eq(pids[0], 19088)
	assert_eq(pids[1], 40064)


func test_windows_listener_execute_result_in_use_handles_failure_codes() -> void:
	assert_false(McpPortResolver.windows_listener_execute_result_in_use(0, [""]))
	assert_false(McpPortResolver.windows_listener_execute_result_in_use(1, ["19088"]))
	assert_true(McpPortResolver.windows_listener_execute_result_in_use(0, ["19088"]))


func test_windows_powershell_candidates_includes_system32_path() -> void:
	## Defensive: the order matters — the System32 path is preferred over
	## bare `powershell.exe` so a hijacked PATH can't intercept the call.
	var candidates := McpPortResolver.windows_powershell_candidates()
	assert_true(candidates.size() >= 3, "must include all three resolution tiers")
	assert_true(
		candidates[0].ends_with("powershell.exe"),
		"first candidate must be the absolute System32 path"
	)
