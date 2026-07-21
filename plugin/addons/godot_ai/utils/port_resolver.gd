@tool
class_name McpPortResolver
extends RefCounted

## Pure-static port discovery / OS-specific scrapers. No instance state,
## no editor dependencies. plugin.gd has thin instance shims that wrap
## these and increment the cold-start trace counters.

## Canonical pid-file path. plugin.gd::SERVER_PID_FILE re-exports this so
## external readers and tests can use either name.
const SERVER_PID_FILE := "user://godot_ai_server.pid"
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")


static func can_bind_local_port(port: int) -> bool:
	var server := TCPServer.new()
	var err := server.listen(port, "127.0.0.1")
	if err == OK:
		server.stop()
		return true
	return false


## True when `port` is bound on 127.0.0.1. Probes via TCPServer first,
## falls back to OS scraping. Callers that want per-scraper trace
## counters should call `is_port_in_use_via_scrape` with a trace hook
## after their own `can_bind_local_port` probe.
static func is_port_in_use(port: int) -> bool:
	if can_bind_local_port(port):
		## On POSIX, an IPv6 wildcard listener can coexist with a
		## successful 127.0.0.1 bind probe. Confirm with lsof so startup
		## sees the same listener set that shutdown/recovery would see.
		if OS.get_name() != "Windows":
			return is_port_in_use_via_scrape(port)
		return false
	return is_port_in_use_via_scrape(port)


## `trace` mirrors `find_all_pids_on_port`'s hook: one call per OS
## invocation with the counter name of the scraper that actually ran, so
## a wrapping caller's startup trace sees a genuine PowerShell fallback
## as `powershell`, not as a silent extra second under `netstat`.
static func is_port_in_use_via_scrape(port: int, trace: Callable = Callable()) -> bool:
	var output: Array = []
	if OS.get_name() == "Windows":
		_trace(trace, "netstat")
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and output.size() > 0:
			var stdout := str(output[0])
			if parse_windows_netstat_listening(stdout, port):
				return true
			## A healthy dump with no listener row IS the answer — don't
			## pay the ~1.2s powershell.exe spawn to confirm "not in use"
			## (see find_all_pids_on_port for the cost rationale).
			if windows_netstat_dump_parseable(stdout):
				return false
		## Fallback: netstat can be absent or unparseable on
		## stripped/locale-odd Windows installs.
		_trace(trace, "powershell")
		return not find_listener_pids_windows(port).is_empty()
	_trace(trace, "lsof")
	var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
	return exit_code == 0 and output.size() > 0 and not output[0].strip_edges().is_empty()


## Return the PID currently listening on the given TCP port, or 0 if
## the port is free. Thin convenience wrapper around `find_all_pids_on_port`
## — the per-OS scraping logic lives in one place.
static func find_pid_on_port(port: int, trace: Callable = Callable()) -> int:
	var pids := find_all_pids_on_port(port, trace)
	return pids[0] if not pids.is_empty() else 0


## Returns every PID bound LISTEN on `port`. Used by the kill paths so
## both the uvicorn reloader parent AND its worker child are caught when
## both bind the same port.
##
## `trace` is an optional Callable that fires once per OS invocation with
## a counter name (`"netstat"` / `"powershell"` / `"lsof"`) so the plugin
## can keep its cold-start trace accurate. The Windows path may fall
## through netstat → PowerShell, and a wrapping caller can't see which
## scraper actually ran without the hook.
static func find_all_pids_on_port(port: int, trace: Callable = Callable()) -> Array[int]:
	if OS.get_name() == "Windows":
		var output: Array = []
		_trace(trace, "netstat")
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and not output.is_empty():
			var stdout := str(output[0])
			var netstat_pids := parse_windows_netstat_pids(stdout, port)
			if not netstat_pids.is_empty():
				return netstat_pids
			## An empty per-port parse from a healthy dump IS the answer
			## ("no listener"). Confirming it through the PowerShell probe
			## costs a powershell.exe spawn (~1.2s measured) against ~30ms
			## for the netstat scrape — two such confirmations dominated a
			## ~7s Windows startup walk. Only fall through when the dump
			## itself is unusable (netstat absent, or so format-odd that
			## zero TCP rows parse).
			if windows_netstat_dump_parseable(stdout):
				var no_listeners: Array[int] = []
				return no_listeners
		_trace(trace, "powershell")
		return find_listener_pids_windows(port)
	var output: Array = []
	_trace(trace, "lsof")
	var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
	if exit_code != 0 or output.is_empty():
		var empty: Array[int] = []
		return empty
	return parse_lsof_pids(str(output[0]))


static func _trace(trace: Callable, counter: String) -> void:
	if trace.is_valid():
		trace.call(counter)


static func find_listener_pids_windows(port: int) -> Array[int]:
	var script := (
		"Get-NetTCPConnection -LocalPort %d -State Listen "
		+ "-ErrorAction SilentlyContinue | "
		+ "Select-Object -ExpandProperty OwningProcess"
	) % port
	var output: Array = []
	var exit_code := execute_windows_powershell(script, output)
	return windows_listener_pids_from_execute_result(exit_code, output)


static func execute_windows_powershell(script: String, output: Array) -> int:
	var args := ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script]
	for exe in windows_powershell_candidates():
		output.clear()
		var exit_code := OS.execute(exe, args, output, true)
		if exit_code == 0:
			return exit_code
	return -1


static func windows_powershell_candidates() -> Array[String]:
	var candidates: Array[String] = []
	var system_root := OS.get_environment("SystemRoot")
	if system_root.is_empty():
		system_root = "C:/Windows"
	system_root = system_root.replace("\\", "/").trim_suffix("/")
	candidates.append(system_root + "/System32/WindowsPowerShell/v1.0/powershell.exe")
	candidates.append("powershell.exe")
	candidates.append("pwsh.exe")
	return candidates


static func windows_listener_pids_from_execute_result(exit_code: int, output: Array) -> Array[int]:
	var empty: Array[int] = []
	if exit_code == 0 and not output.is_empty():
		return parse_pid_lines(str(output[0]))
	return empty


static func windows_listener_execute_result_in_use(exit_code: int, output: Array) -> bool:
	return not windows_listener_pids_from_execute_result(exit_code, output).is_empty()


## Pure parser for `lsof -ti` output — newline-separated decimal PIDs.
## Empty lines and non-numeric tokens are dropped. Duplicates pass
## through (uvicorn reloader + worker can produce the same PID twice
## across runs but typically two distinct PIDs).
static func parse_lsof_pids(raw: String) -> Array[int]:
	var pids: Array[int] = []
	for line in raw.strip_edges().split("\n", false):
		var stripped := line.strip_edges()
		if stripped.is_valid_int():
			pids.append(int(stripped))
	return pids


static func parse_pid_lines(raw: String) -> Array[int]:
	var pids: Array[int] = []
	for line in raw.strip_edges().split("\n", false):
		var stripped := line.strip_edges()
		if stripped.is_valid_int():
			var pid := int(stripped)
			if pid > 0 and not pids.has(pid):
				pids.append(pid)
	return pids


## Parse a Windows `netstat -ano` dump and return PIDs of rows whose
## local address ends with `:port` AND state is `LISTENING`. Substring
## matching the whole dump is wrong: a remote address containing
## `:port` would false-positive against an unrelated ESTABLISHED row.
static func parse_windows_netstat_pid(stdout: String, port: int) -> int:
	var pids := parse_windows_netstat_pids(stdout, port)
	return pids[0] if not pids.is_empty() else 0


static func parse_windows_netstat_pids(stdout: String, port: int) -> Array[int]:
	var pids: Array[int] = []
	var port_suffix := ":%d" % port
	for line in stdout.split("\n"):
		var s := line.strip_edges()
		if s.is_empty():
			continue
		var fields := split_on_whitespace(s)
		if fields.size() < 5:  # proto, local, remote, state, pid
			continue
		## Locale-independent listener signal (mirrors script/_dev_env.py):
		## the state column is localized ("LISTENING"/"ABHÖREN"/"ÉCOUTE"...),
		## but a listener's FOREIGN address is always the wildcard ":0".
		if not fields[2].ends_with(":0"):
			continue
		if not fields[1].ends_with(port_suffix):
			continue
		var pid_str := fields[fields.size() - 1]
		if pid_str.is_valid_int():
			var pid := int(pid_str)
			if pid > 0 and not pids.has(pid):
				pids.append(pid)
	return pids


static func parse_windows_netstat_listening(stdout: String, port: int) -> bool:
	return parse_windows_netstat_pid(stdout, port) > 0


## True when `stdout` looks like a healthy `netstat -ano` dump: at least
## one row parses as a TCP connection (proto column literally "TCP", an
## address containing ":", an integer PID in the last column). Locale-
## independent — protocol names are never localized, unlike the state
## column. Gates whether an empty per-port parse can be trusted as "no
## listener": a live Windows host always carries TCP rows (svchost/RPC
## listen on 135 at minimum), so a dump with zero parseable rows means
## netstat itself is absent/broken and the PowerShell fallback must run.
static func windows_netstat_dump_parseable(stdout: String) -> bool:
	for line in stdout.split("\n"):
		var fields := split_on_whitespace(line.strip_edges())
		if fields.size() < 5:
			continue
		if fields[0].to_upper() != "TCP":
			continue
		if fields[1].find(":") < 0:
			continue
		if fields[fields.size() - 1].is_valid_int():
			return true
	return false


## `String.split(" ", false)` only splits on single spaces; netstat
## columns are separated by runs of spaces / tabs. Collapse manually.
static func split_on_whitespace(s: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur := ""
	for i in s.length():
		var c := s.substr(i, 1)
		if c == " " or c == "\t":
			if not cur.is_empty():
				out.append(cur)
				cur = ""
		else:
			cur += c
	if not cur.is_empty():
		out.append(cur)
	return out


static func read_pid_file() -> int:
	if not FileAccess.file_exists(SERVER_PID_FILE):
		return 0
	var f := FileAccess.open(SERVER_PID_FILE, FileAccess.READ)
	if f == null:
		return 0
	var content := f.get_as_text().strip_edges()
	f.close()
	if content.is_empty() or not content.is_valid_int():
		return 0
	var pid := int(content)
	return pid if pid > 0 else 0


static func clear_pid_file() -> void:
	if FileAccess.file_exists(SERVER_PID_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SERVER_PID_FILE))


## `kill -0` returns 0 for both running and zombie processes; Godot
## never `waitpid`s on `OS.create_process` children, so a fast-failing
## uvx launcher lingers as a zombie forever and `kill -0` would block
## the spawn-failure branch in check_server_health from firing. Use
## `ps -o stat=` instead. State codes: R/S/D/I/T (live), Z (zombie). #172.
static func pid_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if OS.get_name() == "Windows":
		var output: Array = []
		var exit_code := OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"], output, true)
		if exit_code != 0 or output.is_empty():
			return false
		for line in output:
			if str(line).find("\"%d\"" % pid) >= 0:
				return true
		return false
	var output: Array = []
	var exit_code := OS.execute("ps", ["-p", str(pid), "-o", "stat="], output, true)
	if exit_code != 0 or output.is_empty():
		return false
	var stat := str(output[0]).strip_edges()
	return not stat.is_empty() and not stat.begins_with("Z")


## Poll until the given port is no longer bound, or the timeout elapses.
## Used after `OS.kill` so we don't race the port-in-use check on rebind.
## NOTE: plugin.gd::_wait_for_port_free (and _is_port_in_use) is a
## deliberate line-for-line fork of this pair kept for _ProofPlugin
## isolation — keep the two in sync when editing either.
static func wait_for_port_free(port: int, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while is_port_in_use(port):
		if Time.get_ticks_msec() >= deadline:
			push_warning("MCP | port %d still in use after %.1fs — proceeding anyway" % [port, timeout_s])
			return
		OS.delay_msec(100)


## Choose a non-Windows-reserved WS port. Returns `configured` when free;
## otherwise the first non-excluded port within `span` of it. Optional
## `log_buffer` is a duck-typed sink (`log(String)`) that gets the
## remap notice so users see why the port shifted.
static func resolve_ws_port(configured: int, max_port: int, log_buffer = null) -> int:
	var resolved := WindowsPortReservation.suggest_non_excluded_port(
		configured,
		2048,
		max_port
	)
	if resolved != configured:
		var message := "WebSocket port %d is reserved by Windows; using %d" % [configured, resolved]
		print("MCP | %s" % message)
		if log_buffer != null:
			log_buffer.log(message)
	return resolved


## Trust the cached ws_port from the managed record only when the record
## is current ownership proof — i.e. record version matches the installed
## plugin. Otherwise a stale record from an older install (e.g. a 9500
## value pre-Windows-reservation collision) would mislead the
## compatibility check into killing an unrelated external process. #259.
static func resolved_ws_port_for_existing_server(
	record_ws_port: int,
	record_version: String,
	current_version: String,
	fresh_resolved: int
) -> int:
	if record_ws_port <= 0:
		return fresh_resolved
	if current_version.is_empty() or record_version != current_version:
		return fresh_resolved
	return record_ws_port


static func resolve_ws_port_from_output(
	configured_port: int,
	netsh_output: String,
	max_port: int,
	span: int = 2048
) -> int:
	return WindowsPortReservation.suggest_non_excluded_port_from_output(
		netsh_output,
		configured_port,
		span,
		max_port
	)
