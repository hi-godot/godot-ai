@tool
class_name McpPortResolver
extends RefCounted

## Port discovery + OS-specific scrapers extracted from plugin.gd.
## Pure static utility — no instance state, no editor dependencies.
##
## Houses the netstat / lsof / PowerShell scraping plus the parsers that
## decode their output. Originally lived in plugin.gd but tangled with
## that file's lifecycle state; pulled out as part of #297 / PR 5 so the
## logic is unit-testable in isolation and the plugin can shrink toward
## an orchestration role.
##
## plugin.gd preserves thin instance-method shims (`_is_port_in_use`,
## `_find_pid_on_port`, `_resolve_ws_port`, …) that delegate here. They
## remain on the plugin so:
##   1. Startup-trace counters (`_startup_trace_count("netstat")` etc.)
##      can wrap the OS calls without the resolver depending on plugin
##      state, and
##   2. The PR 4 characterization suite's `_ProofPlugin extends
##      GodotAiPlugin` overrides keep working — the lifecycle manager
##      reaches port queries through the host, so test stubs land.

## See plugin.gd::SERVER_PID_FILE — duplicated here so this file has no
## dependency on plugin.gd. plugin.gd's own `SERVER_PID_FILE` const is
## the public name for tests/external readers; both point at the same path.
const SERVER_PID_FILE := "user://godot_ai_server.pid"


static func can_bind_local_port(port: int) -> bool:
	var server := TCPServer.new()
	var err := server.listen(port, "127.0.0.1")
	if err == OK:
		server.stop()
		return true
	return false


## True when `port` is bound on 127.0.0.1. Tries a non-destructive
## TCPServer probe first; falls back to OS scraping (netstat / lsof) only
## when the probe fails. The scraping path is the slow one — callers that
## want to track its frequency should use `is_port_in_use_via_scrape`
## directly and bracket it with their own counter.
static func is_port_in_use(port: int) -> bool:
	if can_bind_local_port(port):
		return false
	return is_port_in_use_via_scrape(port)


## OS-scraping half of `is_port_in_use`. Extracted so callers that
## already paid the can_bind probe can reuse it without re-probing,
## and so plugin.gd's `_is_port_in_use` can drop a startup-trace
## counter increment between the two halves without re-implementing them.
static func is_port_in_use_via_scrape(port: int) -> bool:
	var output: Array = []
	if OS.get_name() == "Windows":
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and output.size() > 0:
			return parse_windows_netstat_listening(str(output[0]), port)
		return false
	var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
	return exit_code == 0 and output.size() > 0 and not output[0].strip_edges().is_empty()


## Return the PID currently listening on the given TCP port, or 0 if
## the port is free. See plugin.gd::_find_pid_on_port for the original
## docstring — same semantics, no behavior change.
static func find_pid_on_port(port: int) -> int:
	var output: Array = []
	if OS.get_name() == "Windows":
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and not output.is_empty():
			var netstat_pid := parse_windows_netstat_pid(str(output[0]), port)
			if netstat_pid > 0:
				return netstat_pid
		var listener_pids := find_listener_pids_windows(port)
		return listener_pids[0] if not listener_pids.is_empty() else 0
	var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
	if exit_code != 0 or output.is_empty():
		return 0
	var pids := parse_lsof_pids(str(output[0]))
	return pids[0] if not pids.is_empty() else 0


## Sibling of `find_pid_on_port` — returns every PID bound LISTEN on
## `port`. See plugin.gd::_find_all_pids_on_port for the original docstring.
static func find_all_pids_on_port(port: int) -> Array[int]:
	if OS.get_name() == "Windows":
		var output: Array = []
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and not output.is_empty():
			var netstat_pids := parse_windows_netstat_pids(str(output[0]), port)
			if not netstat_pids.is_empty():
				return netstat_pids
		return find_listener_pids_windows(port)
	var output: Array = []
	var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
	if exit_code != 0 or output.is_empty():
		var empty: Array[int] = []
		return empty
	return parse_lsof_pids(str(output[0]))


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


## Pure-parser for the `lsof -ti...` output shape: zero or more newline-
## separated decimal PIDs. See plugin.gd::_parse_lsof_pids docstring.
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


## Parse the LISTENING line for `port` in a Windows `netstat -ano`
## dump and return its PID, or 0 if no matching line is found.
## See plugin.gd::_parse_windows_netstat_pid for the row-shape docstring.
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
		## Minimum columns: proto, local, remote, state, pid
		if fields.size() < 5:
			continue
		if fields[3] != "LISTENING":
			continue
		if not fields[1].ends_with(port_suffix):
			continue
		var pid_str := fields[fields.size() - 1]
		if pid_str.is_valid_int():
			var pid := int(pid_str)
			if pid > 0 and not pids.has(pid):
				pids.append(pid)
	return pids


## True if any row in a Windows `netstat -ano` dump is a LISTENING
## entry for `port`.
static func parse_windows_netstat_listening(stdout: String, port: int) -> bool:
	return parse_windows_netstat_pid(stdout, port) > 0


static func split_on_whitespace(s: String) -> PackedStringArray:
	## `String.split(" ", false)` only splits on single spaces; netstat
	## columns are separated by runs of spaces (and sometimes tabs).
	## Collapse whitespace manually so PID-column extraction is robust.
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


## Read the integer PID from SERVER_PID_FILE, or 0 if the file is
## missing/empty/malformed.
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


## True if the given PID corresponds to a live (non-zombie) process.
## See plugin.gd::_pid_alive for the zombie-handling rationale.
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
static func wait_for_port_free(port: int, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while is_port_in_use(port):
		if Time.get_ticks_msec() >= deadline:
			push_warning("MCP | port %d still in use after %.1fs — proceeding anyway" % [port, timeout_s])
			return
		OS.delay_msec(100)


## Choose a non-Windows-reserved WS port. Returns the configured port
## when free; otherwise the first non-excluded port within `span` of it.
## `log_buffer` (optional) accepts an McpLogBuffer-like sink with a
## `log(msg: String)` method; when provided, a "remapped" message is
## written so the user sees why the port shifted.
static func resolve_ws_port(configured: int, max_port: int, log_buffer = null) -> int:
	var resolved := McpWindowsPortReservation.suggest_non_excluded_port(
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


## Choose the WS port to expect when a server is already bound to the
## HTTP port. See plugin.gd::_resolved_ws_port_for_existing_server.
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
	return McpWindowsPortReservation.suggest_non_excluded_port_from_output(
		netsh_output,
		configured_port,
		span,
		max_port
	)
