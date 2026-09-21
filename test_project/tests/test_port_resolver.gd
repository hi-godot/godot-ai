@tool
extends McpTestSuite

## Direct coverage for the static OS/process boundary.


func suite_name() -> String:
	return "port_resolver"


# ----- seam smoke (proves the class_name is reachable) ----------------

func test_parser_seam_callable_directly() -> void:
	var pid := McpPortResolver.parse_windows_netstat_pid(
		"  TCP  0.0.0.0:8000  0.0.0.0:0  LISTENING  57865\n", 8000
	)
	assert_eq(pid, 57865)


func test_lsof_parser_deduplicates_ipv4_and_ipv6_listener_rows() -> void:
	assert_eq(McpPortResolver.parse_lsof_pids("4242\n4242\n0\nnope\n"), [4242])


func test_linux_ss_parser_pins_exact_port_and_deduplicates_pids() -> void:
	var dump := (
		"LISTEN 0 2048 127.0.0.1:8000 0.0.0.0:* users:((\"python\",pid=4242,fd=6))\n"
		+ "LISTEN 0 2048 [::1]:8000 [::]:* users:((\"python\",pid=4242,fd=7))\n"
		+ "LISTEN 0 2048 127.0.0.1:18000 0.0.0.0:* users:((\"python\",pid=9999,fd=8))\n"
	)
	assert_eq(McpPortResolver.parse_linux_ss_pids(dump, 8000), [4242])
	assert_eq(McpPortResolver.parse_linux_ss_pids(dump, 18000), [9999])
	assert_eq(McpPortResolver.parse_linux_ss_pids(dump, 0), [])


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

	var bind_still_succeeds := McpPortResolver.can_bind_local_port(port)
	if not bind_still_succeeds:
		OS.kill(pid)
		McpPortResolver.wait_for_port_free(port, 2.0)
		skip("python http.server also held IPv4 loopback; POSIX fallback precondition unavailable")
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
	assert_true(McpPortResolver.process_descends_from(OS.get_process_id(), OS.get_process_id()))
	assert_false(McpPortResolver.process_descends_from(OS.get_process_id(), 1))


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


func test_windows_powershell_candidates_prefers_installed_path_and_preserves_fallbacks() -> void:
	var saved := {}
	for key in ["ProgramW6432", "ProgramFiles"]:
		saved[key] = {"present": OS.has_environment(key), "value": OS.get_environment(key)}
		OS.unset_environment(key)
	var absent := McpPortResolver.windows_powershell_candidates()
	var root := "user://_test_pwsh_candidates"
	var native := ProjectSettings.globalize_path(root + "/native")
	var x86 := ProjectSettings.globalize_path(root + "/x86")
	for path in [native, x86]:
		DirAccess.make_dir_recursive_absolute(path.path_join("PowerShell/7"))
		var file := FileAccess.open(path.path_join("PowerShell/7/pwsh.exe"), FileAccess.WRITE)
		file.close()
	OS.set_environment("ProgramW6432", native)
	OS.set_environment("ProgramFiles", x86)
	var candidates := McpPortResolver.windows_powershell_candidates()
	OS.set_environment("ProgramFiles", native)
	var duplicate := McpPortResolver.windows_powershell_candidates()
	OS.set_environment("ProgramW6432", "")
	OS.set_environment("ProgramFiles", "")
	var empty := McpPortResolver.windows_powershell_candidates()
	for key in saved:
		if saved[key].present:
			OS.set_environment(key, saved[key].value)
		else:
			OS.unset_environment(key)
	for path in [native, x86]:
		DirAccess.remove_absolute(path.path_join("PowerShell/7/pwsh.exe"))
		DirAccess.remove_absolute(path.path_join("PowerShell/7"))
		DirAccess.remove_absolute(path.path_join("PowerShell"))
		DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(root)
	assert_eq(empty, absent, "empty environment cannot add a relative executable")
	assert_eq(candidates.slice(0, 2), [native.path_join("PowerShell/7/pwsh.exe"), x86.path_join("PowerShell/7/pwsh.exe")])
	assert_eq(candidates.slice(2), absent, "all previous fallbacks remain")
	assert_eq(duplicate.size(), absent.size() + 1, "the same installation occurs once")
	assert_eq(absent.slice(-2), ["powershell.exe", "pwsh.exe"])


func test_windows_failed_powershell7_query_uses_existing_powershell5_fallback() -> void:
	if OS.get_name() != "Windows":
		skip("Windows PowerShell execution boundary")
		return
	var candidates := McpPortResolver.windows_powershell_candidates()
	if not candidates[0].ends_with("/PowerShell/7/pwsh.exe"):
		skip("Optional PowerShell 7 is not installed at the configured ProgramFiles path")
		return
	var output: Array = []
	var exit_code := McpPortResolver.execute_windows_powershell(
		"if ($PSVersionTable.PSVersion.Major -ge 7) { exit 7 }; $PSVersionTable.PSVersion.Major", output
	)
	assert_eq(exit_code, 0, "nonzero PS7 exit must continue to the existing shell fallback")
	assert_eq(str(output[0]).strip_edges() if not output.is_empty() else "", "5",
		"the fallback must actually run Windows PowerShell 5")


func test_netstat_parse_is_locale_independent() -> void:
	## The state column is localized ("ABHÖREN", "ÉCOUTE", ...); the
	## listener signal is the wildcard ":0" FOREIGN address, which is
	## locale-independent (mirrors script/_dev_env.py).
	var german := "  TCP  0.0.0.0:8000  0.0.0.0:0  ABHÖREN  4242\n"
	var pids := McpPortResolver.parse_windows_netstat_pids(german, 8000)
	assert_eq(pids.size(), 1, "localized state must still parse via the :0 foreign addr")
	assert_eq(pids[0], 4242)


func test_netstat_parse_still_skips_established_rows() -> void:
	## An ESTABLISHED row's foreign address carries a real port — it must
	## not be mistaken for a listener even when the local port matches.
	var established := "  TCP  10.0.0.5:8000  10.0.0.9:51515  HERGESTELLT  777\n"
	var pids := McpPortResolver.parse_windows_netstat_pids(established, 8000)
	assert_eq(pids.size(), 0, "non-listener rows must be skipped regardless of locale")


# ----- netstat dump health check (gates the PowerShell fallback) ------

func test_netstat_dump_parseable_accepts_realistic_dump() -> void:
	var dump := (
		"Active Connections\n\n"
		+ "  Proto  Local Address      Foreign Address    State        PID\n"
		+ "  TCP    0.0.0.0:135        0.0.0.0:0          LISTENING    1240\n"
		+ "  UDP    0.0.0.0:500        *:*                             892\n"
	)
	assert_true(McpPortResolver.windows_netstat_dump_parseable(dump))


func test_netstat_dump_parseable_accepts_localized_state_column() -> void:
	## German netstat: header words and state are localized, but "TCP" and
	## the address/PID columns are not — the health check must pass.
	var dump := "  TCP  0.0.0.0:8000  0.0.0.0:0  ABHÖREN  4242\n"
	assert_true(McpPortResolver.windows_netstat_dump_parseable(dump))


func test_netstat_dump_parseable_accepts_established_only_dump() -> void:
	## A dump can legitimately contain zero LISTENING rows for the probed
	## port; any parseable TCP row proves netstat works.
	var dump := "  TCP  127.0.0.1:49701  127.0.0.1:8000  ESTABLISHED  12345\n"
	assert_true(McpPortResolver.windows_netstat_dump_parseable(dump))


func test_netstat_dump_parseable_rejects_empty_and_garbage() -> void:
	assert_false(McpPortResolver.windows_netstat_dump_parseable(""))
	assert_false(McpPortResolver.windows_netstat_dump_parseable("oops something went wrong\n"))
	## Header-only output (no TCP rows at all) must not be trusted as a
	## "no listener" answer — that shape is indistinguishable from a
	## broken netstat, so the PowerShell fallback stays reachable.
	var header_only := (
		"Active Connections\n\n"
		+ "  Proto  Local Address      Foreign Address    State        PID\n"
	)
	assert_false(McpPortResolver.windows_netstat_dump_parseable(header_only))


func test_netstat_dump_parseable_rejects_rows_without_pid_column() -> void:
	## `netstat -an` (no -o) has no PID column; trusting it would make
	## every per-port PID parse return empty. 4-field TCP rows must not
	## count as healthy for the -ano contract.
	var dump := "  TCP  0.0.0.0:8000  0.0.0.0:0  LISTENING\n"
	assert_false(McpPortResolver.windows_netstat_dump_parseable(dump))


# ----- Windows live smoke: netstat-first, PowerShell only as fallback --

func test_find_all_pids_on_free_port_skips_powershell_windows() -> void:
	## Perf contract for the startup walk: on a healthy Windows host, a
	## free port's empty netstat answer is trusted as-is. The PowerShell
	## confirmation probe costs a ~1.2s powershell.exe spawn (~40x the
	## netstat scrape) and must not run.
	if OS.get_name() != "Windows":
		skip("Windows-only netstat trust path")
		return
	var port := 51251
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		skip("port %d is already held on this host" % port)
		return
	probe.stop()
	var counters: Array = []
	var pids := McpPortResolver.find_all_pids_on_port(port, func(c: String) -> void: counters.append(c))
	assert_eq(pids.size(), 0, "freshly-freed port should have no listener")
	assert_true(counters.has("netstat"), "netstat scrape should have run")
	assert_false(
		counters.has("powershell"),
		"a healthy netstat dump must not fall through to the PowerShell probe"
	)


func test_scrape_free_port_skips_powershell_windows() -> void:
	if OS.get_name() != "Windows":
		skip("Windows-only netstat trust path")
		return
	var port := 51252
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		skip("port %d is already held on this host" % port)
		return
	probe.stop()
	var counters: Array = []
	var in_use := McpPortResolver.is_port_in_use_via_scrape(port, func(c: String) -> void: counters.append(c))
	assert_false(in_use, "freshly-freed port should scrape as not in use")
	assert_true(counters.has("netstat"), "netstat scrape should have run")
	assert_false(
		counters.has("powershell"),
		"a healthy netstat dump must not fall through to the PowerShell probe"
	)


func test_scrape_held_port_reports_in_use_windows() -> void:
	## Companion to the free-port trust test: a live listener must still
	## scrape as in-use via the netstat-first path, with no PowerShell
	## fallback needed.
	if OS.get_name() != "Windows":
		skip("Windows-only netstat trust path")
		return
	var port := 51254
	var holder := TCPServer.new()
	if holder.listen(port, "127.0.0.1") != OK:
		skip("could not seize port for held-port scrape smoke")
		return
	var counters: Array = []
	var in_use := McpPortResolver.is_port_in_use_via_scrape(port, func(c: String) -> void: counters.append(c))
	holder.stop()
	assert_true(in_use, "held port must scrape as in use")
	assert_false(counters.has("powershell"), "netstat saw the listener; PowerShell must not run")


func test_find_all_pids_sees_live_listener_via_netstat_windows() -> void:
	## Companion to the free-port trust tests: a live listener must still
	## be found by the netstat-first path (no fallback needed).
	if OS.get_name() != "Windows":
		skip("Windows-only netstat trust path")
		return
	var port := 51253
	var holder := TCPServer.new()
	if holder.listen(port, "127.0.0.1") != OK:
		skip("could not seize port for listener smoke")
		return
	var counters: Array = []
	var pids := McpPortResolver.find_all_pids_on_port(port, func(c: String) -> void: counters.append(c))
	holder.stop()
	assert_true(pids.has(OS.get_process_id()), "the editor's own listener should be reported")
	assert_false(counters.has("powershell"), "netstat found the listener; PowerShell must not run")


# ----- command-line brand ----------------------------------------------

func test_brand_ignores_paths_the_plugin_chose_itself() -> void:
	## The pid-file and startup-report values live under user:// and carry our
	## name; a foreign command must not pass the brand because of them.
	var unbranded := (
		"C:/tools/python.exe -I C:/scratch/selector.py --transport streamable-http "
		+ "--pid-file C:/u/godot_ai_server.pid --startup-report C:/u/godot_ai_server_startup.json"
	)
	assert_false(McpPortResolver.commandline_is_godot_ai_server(unbranded))
	var branded := (
		"C:/tools/python.exe -m godot_ai --transport streamable-http "
		+ "--pid-file C:/u/godot_ai_server.pid --startup-report C:/u/godot_ai_server_startup.json"
	)
	assert_true(McpPortResolver.commandline_is_godot_ai_server(branded))
	assert_true(McpPortResolver.commandline_is_godot_ai_server(
		"/opt/venv/bin/godot-ai --transport streamable-http --startup-report=/tmp/r.json"
	))
	assert_false(McpPortResolver.commandline_is_godot_ai_server("python -m something --transport x"))


func test_kill_grant_capture_names_the_check_that_refused() -> void:
	var diagnostics: Array = []
	assert_true(McpPortResolver.capture_process_kill_grant(0, true, diagnostics).is_empty())
	assert_eq(diagnostics, ["invalid_pid"])
	diagnostics.clear()
	## The editor's own pid is refused before any probe runs.
	assert_true(McpPortResolver.capture_process_kill_grant(OS.get_process_id(), true, diagnostics).is_empty())
	assert_eq(diagnostics, ["invalid_pid"])
	diagnostics.clear()
	## An implausible pid is not alive.
	assert_true(McpPortResolver.capture_process_kill_grant(2147480000, true, diagnostics).is_empty())
	assert_eq(diagnostics, ["not_alive"])


func _snapshot_rows() -> Array:
	var command := "python -m godot_ai --transport streamable-http"
	return [
		{"pid": 4242, "parent_pid": 4241, "identity": "09/09/2026 12:00:00|" + command, "commandline": command},
		{"pid": 4241, "parent_pid": 0, "identity": "09/09/2026 11:59:59|launcher", "commandline": "launcher"},
	]


func test_process_snapshot_preserves_fingerprint_brand_and_lineage() -> void:
	var rows := _snapshot_rows()
	var snapshot := McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)
	assert_eq(snapshot.size(), 2)
	assert_true(McpPortResolver.pid_alive(4242, snapshot))
	assert_eq(McpPortResolver.process_parent(4242, snapshot), 4241)
	assert_eq(McpPortResolver.process_commandline(4242, snapshot), rows[0].commandline)
	assert_eq(McpPortResolver.process_fingerprint(4242, snapshot), ("4242|" + str(rows[0].identity)).sha256_text())
	assert_true(McpPortResolver.pid_cmdline_is_godot_ai(4242, snapshot))
	assert_true(McpPortResolver.process_descends_from(4242, 4241, snapshot))
	assert_true(McpPortResolver.process_descends_from(4242, 4242, snapshot))
	assert_false(McpPortResolver.process_descends_from(4242, 9999, snapshot))


func test_process_snapshot_changed_identity_brand_and_parent_do_not_preserve_proof() -> void:
	var rows := _snapshot_rows()
	var original := McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)
	rows[0].identity = "09/09/2026 12:01:00|" + str(rows[0].commandline)
	var reused := McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)
	assert_ne(McpPortResolver.process_fingerprint(4242, original), McpPortResolver.process_fingerprint(4242, reused))
	rows[0].commandline = "python -m unrelated --transport streamable-http"
	rows[0].identity = "09/09/2026 12:01:00|" + str(rows[0].commandline)
	var unbranded := McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)
	assert_false(McpPortResolver.pid_cmdline_is_godot_ai(4242, unbranded))
	rows[0].parent_pid = 9999
	rows.resize(1)
	var moved := McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)
	assert_false(McpPortResolver.process_descends_from(4242, 4241, moved))
	assert_false(McpPortResolver.process_descends_from(4242, 9999, moved), "an omitted ancestor is not proof")


func test_process_snapshot_rejects_missing_malformed_and_tampered_records() -> void:
	for raw in ["{}", "null", "not json", JSON.stringify([{"pid": 4242}])]:
		assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(raw, 4242)))
	var rows := _snapshot_rows()
	assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 5555)))
	rows[0].commandline = "changed without changing fingerprint identity"
	assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)))
	rows = _snapshot_rows()
	rows[1].pid = 5555
	assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)))
	rows = _snapshot_rows()
	rows[1].parent_pid = 4242
	assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)), "a cycle truncated by the collector is still invalid")
	rows.resize(1)
	rows[0].parent_pid = 4242
	assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 4242)), "self-parent cycles are invalid")
	for invalid in [{}, [], {4242: {"pid": 4242}}]:
		assert_false(McpPortResolver.pid_alive(OS.get_process_id(), invalid), "explicit empty snapshots never query the live editor")
		assert_eq(McpPortResolver.process_fingerprint(OS.get_process_id(), invalid), "")
		assert_false(McpPortResolver.pid_cmdline_is_godot_ai(4242, invalid))
		assert_false(McpPortResolver.process_descends_from(4242, 4242, invalid))


func test_process_snapshot_fallback_keeps_start_time_identity_without_inventing_brand() -> void:
	var snapshot := McpPortResolver.parse_process_snapshot(JSON.stringify([
		{"pid": 4242, "parent_pid": 0, "identity": "134019180000000000", "commandline": ""},
	]), 4242)
	assert_eq(McpPortResolver.process_fingerprint(4242, snapshot), "4242|134019180000000000".sha256_text())
	assert_false(McpPortResolver.pid_cmdline_is_godot_ai(4242, snapshot))
	assert_false(McpPortResolver.process_descends_from(4242, 4241, snapshot))


func test_process_snapshot_keeps_the_sixteen_process_lineage_limit() -> void:
	var rows: Array = []
	for index in range(16):
		rows.append({"pid": 5000 + index, "parent_pid": 5001 + index, "identity": "time|launcher", "commandline": "launcher"})
	var snapshot := McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 5000)
	assert_eq(snapshot.size(), 16)
	assert_true(McpPortResolver.process_descends_from(5000, 5015, snapshot))
	assert_false(McpPortResolver.process_descends_from(5000, 5016, snapshot))
	rows.append({"pid": 5016, "parent_pid": 0, "identity": "time|launcher", "commandline": "launcher"})
	assert_true(McpPortResolver.capture_failed(McpPortResolver.parse_process_snapshot(JSON.stringify(rows), 5000)))


func test_windows_process_snapshot_matches_live_editor_fingerprint() -> void:
	if OS.get_name() != "Windows":
		skip("Windows process snapshot boundary")
		return
	var pid := OS.get_process_id()
	var snapshot: Variant = McpPortResolver.capture_process_snapshot(pid)
	var fingerprint := McpPortResolver.process_fingerprint(pid, snapshot)
	assert_false(fingerprint.is_empty(), "the editor must have a captured process identity")
	assert_eq(fingerprint, McpPortResolver.process_fingerprint(pid), "batched identity must match existing grant representation")


func test_process_snapshot_pair_preserves_both_independent_identities() -> void:
	var rows := _snapshot_rows()
	var first := JSON.stringify(rows)
	rows[0].identity = "09/09/2026 12:01:00|" + str(rows[0].commandline)
	var final := JSON.stringify(rows)
	var pair := McpPortResolver._parse_process_snapshot_pair(JSON.stringify([first, final]), 4242)
	assert_eq(pair[0], McpPortResolver.parse_process_snapshot(first, 4242))
	assert_eq(pair[1], McpPortResolver.parse_process_snapshot(final, 4242))
	assert_eq(McpPortResolver.process_fingerprint(4242, pair[0]), ("4242|09/09/2026 12:00:00|" + str(rows[0].commandline)).sha256_text())
	assert_eq(McpPortResolver.process_fingerprint(4242, pair[1]), ("4242|" + str(rows[0].identity)).sha256_text())


func test_process_snapshot_pair_rejects_invalid_envelopes_and_members() -> void:
	var valid := JSON.stringify(_snapshot_rows())
	for raw in ["{}", "[]", JSON.stringify([valid]), JSON.stringify([valid, valid, valid]), JSON.stringify([{}, valid]), " ".repeat(4 * 1024 * 1024 + 17)]:
		assert_eq(McpPortResolver._parse_process_snapshot_pair(raw, 4242), [{"capture_error": true}, {"capture_error": true}])
	assert_eq(McpPortResolver._parse_process_snapshot_pair(JSON.stringify([valid, valid]), 9999), [{"capture_error": true}, {"capture_error": true}])
	for invalid in ["{}", JSON.stringify([{"pid": 4242}]), " ".repeat(1024 * 1024 + 1)]:
		var pair := McpPortResolver._parse_process_snapshot_pair(JSON.stringify([valid, invalid]), 4242)
		assert_eq(McpPortResolver.process_commandline(4242, pair[0]), str(_snapshot_rows()[0].commandline))
		assert_true(McpPortResolver.capture_failed(pair[1]), "an invalid final member cannot reuse the first snapshot")
		assert_eq(McpPortResolver.process_fingerprint(4242, pair[1]), "")
		pair = McpPortResolver._parse_process_snapshot_pair(JSON.stringify([invalid, valid]), 4242)
		assert_true(McpPortResolver.capture_failed(pair[0]))
		assert_eq(McpPortResolver.process_commandline(4242, pair[1]), str(_snapshot_rows()[0].commandline))


func test_process_snapshot_pair_accepts_escaped_members_near_the_inner_limit() -> void:
	var command := String.chr(34).repeat(250000)
	var inner := JSON.stringify([{"pid": 4242, "parent_pid": 0, "identity": "time|" + command, "commandline": command}])
	var outer := JSON.stringify([inner, inner])
	assert_true(inner.length() <= 1024 * 1024)
	assert_true(outer.length() > 2 * 1024 * 1024, "escaping expands two valid inner snapshots beyond the old outer limit")
	var pair := McpPortResolver._parse_process_snapshot_pair(outer, 4242)
	assert_eq(McpPortResolver.process_commandline(4242, pair[0]), command)
	assert_eq(McpPortResolver.process_commandline(4242, pair[1]), command)


func test_listener_tool_preflight_is_inert_outside_linux() -> void:
	if OS.get_name() == "Linux":
		skip("Isolated Linux PATH cases run in the integration fixture")
		return
	assert_eq(McpPortResolver.listener_tools_problem(), "")


func test_process_capture_distinguishes_absence_from_unavailable_evidence() -> void:
	var absent := McpPortResolver.parse_process_snapshot("[]", 4242)
	assert_eq(absent, {})
	assert_false(McpPortResolver.capture_failed(absent))
	for raw in ["", "null", "not JSON", "{}", "[{bad", JSON.stringify([{"pid": 4242}])]:
		var failed := McpPortResolver.parse_process_snapshot(raw, 4242)
		assert_true(McpPortResolver.capture_failed(failed), raw)
		assert_false(McpPortResolver.pid_alive(OS.get_process_id(), failed))
		assert_eq(McpPortResolver.process_fingerprint(OS.get_process_id(), failed), "")
		assert_false(McpPortResolver.pid_cmdline_is_godot_ai(OS.get_process_id(), failed))
		assert_false(McpPortResolver.process_descends_from(OS.get_process_id(), OS.get_process_id(), failed))
	var mixed := McpPortResolver.parse_process_snapshot(JSON.stringify(_snapshot_rows()), 4242)
	mixed["capture_error"] = true
	assert_eq(McpPortResolver.process_fingerprint(4242, mixed), "", "failure cannot carry usable rows")


func test_windows_capture_distinguishes_get_process_not_found_and_permission_error() -> void:
	if OS.get_name() != "Windows":
		skip("Windows PowerShell process collector")
		return
	for category in ["ObjectNotFound", "PermissionDenied"]:
		var output: Array = []
		var script := (
			"function Get-CimInstance { throw 'CIM unavailable' }; "
			+ "function Get-Process { [CmdletBinding()]param($Id); Write-Error -Message 'unavailable' -Category %s -ErrorAction Stop }; "
		) % category + McpPortResolver._windows_process_snapshot_script(4242)
		assert_eq(McpPortResolver.execute_windows_powershell(script, output), 0)
		assert_false(output.is_empty())
		var captured := McpPortResolver.parse_process_snapshot(str(output[0]), 4242)
		assert_eq(McpPortResolver.capture_failed(captured), category == "PermissionDenied", category)
		assert_false(McpPortResolver.pid_alive(4242, captured))
	var diagnostics: Array = []
	assert_eq(McpPortResolver.capture_process_kill_grant(2147483000, false, diagnostics), {})
	assert_eq(diagnostics, ["not_alive"], "a successfully observed absent PID is distinct from query failure")
