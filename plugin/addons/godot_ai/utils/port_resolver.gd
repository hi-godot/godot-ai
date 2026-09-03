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
static var _process_spawn_mutex := Mutex.new()


## Serialize plugin-owned subprocess creation across the brief process-global
## environment override used for server capabilities. Callers must keep this
## window to environment mutation + one spawn and release it immediately.
static func lock_process_spawn() -> void:
	_process_spawn_mutex.lock()


static func unlock_process_spawn() -> void:
	_process_spawn_mutex.unlock()


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
	if exit_code == 0 and output.size() > 0 and not output[0].strip_edges().is_empty():
		return true
	if OS.get_name() != "Linux":
		return false
	_trace(trace, "ss")
	output.clear()
	return (
		OS.execute("ss", ["-H", "-ltnp"], output, true) == 0
		and not parse_linux_ss_pids(str(output[0]) if not output.is_empty() else "", port).is_empty()
	)


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
## a counter name (`"netstat"` / `"powershell"` / `"lsof"` / `"ss"`) so the plugin
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
	if exit_code == 0 and not output.is_empty():
		var lsof_pids := parse_lsof_pids(str(output[0]))
		if not lsof_pids.is_empty() or OS.get_name() != "Linux":
			return lsof_pids
	elif OS.get_name() != "Linux":
		var empty: Array[int] = []
		return empty
	_trace(trace, "ss")
	output.clear()
	if OS.execute("ss", ["-H", "-ltnp"], output, true) != 0 or output.is_empty():
		var empty: Array[int] = []
		return empty
	return parse_linux_ss_pids(str(output[0]), port)


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
## Empty lines, non-positive values, non-numeric tokens, and duplicate
## IPv4/IPv6 rows for the same listener are dropped.
static func parse_lsof_pids(raw: String) -> Array[int]:
	return parse_pid_lines(raw)


## Parse Linux `ss -H -ltnp` without trusting process names or localized
## state text. The local endpoint is the fourth whitespace-delimited field;
## every `pid=` value on an exact-port row is retained for later brand,
## lineage, and fingerprint checks.
static func parse_linux_ss_pids(raw: String, port: int) -> Array[int]:
	var result: Array[int] = []
	if port < 1 or port > 65535:
		return result
	var expression := RegEx.new()
	if expression.compile("(?:^|,)pid=([0-9]+)(?:,|\\))") != OK:
		return result
	for line in raw.split("\n", false):
		var fields := line.split(" ", false)
		if fields.size() < 4 or not str(fields[3]).ends_with(":%d" % port):
			continue
		for matched in expression.search_all(line):
			var pid := int(matched.get_string(1))
			if pid > 0 and not result.has(pid):
				result.append(pid)
	return result


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


static func read_pid_file(path := SERVER_PID_FILE) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
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


## Read-only process identity helpers.  Lifecycle authority is granted only
## after capturing a fingerprint and every later stop re-reads the fingerprint
## before acting, so PID reuse fails closed.
static func process_commandline(pid: int) -> String:
	if pid <= 1:
		return ""
	if OS.get_name() == "Windows":
		var output: Array = []
		var script := (
			"Get-CimInstance Win32_Process -Filter 'ProcessId = %d' | "
			+ "Select-Object -ExpandProperty CommandLine"
		) % pid
		if execute_windows_powershell(script, output) != 0 or output.is_empty():
			return ""
		return str(output[0]).strip_edges()
	var proc_path := "/proc/%d/cmdline" % pid
	if FileAccess.file_exists(proc_path):
		var file := FileAccess.open(proc_path, FileAccess.READ)
		if file != null:
			var bytes := PackedByteArray()
			while bytes.size() < (1 << 20):
				var chunk := file.get_buffer(4096)
				if chunk.is_empty():
					break
				bytes.append_array(chunk)
				if file.eof_reached():
					break
			file.close()
			for index in range(bytes.size()):
				if bytes[index] == 0:
					bytes[index] = 0x20
			return bytes.get_string_from_utf8().strip_edges()
	var output: Array = []
	if OS.execute("ps", ["-ww", "-p", str(pid), "-o", "args="], output, true) != 0:
		return ""
	return str(output[0]).strip_edges() if not output.is_empty() else ""


static func process_parent(pid: int) -> int:
	if pid <= 1:
		return 0
	var output: Array = []
	if OS.get_name() == "Windows":
		var script := (
			"Get-CimInstance Win32_Process -Filter 'ProcessId = %d' | "
			+ "Select-Object -ExpandProperty ParentProcessId"
		) % pid
		if execute_windows_powershell(script, output) != 0 or output.is_empty():
			return 0
	else:
		if OS.execute("ps", ["-o", "ppid=", "-p", str(pid)], output, true) != 0 or output.is_empty():
			return 0
	var raw := str(output[0]).strip_edges()
	return int(raw) if raw.is_valid_int() else 0


## One PowerShell spawn that walks a process's ancestry and returns one
## record per hop, the process itself first: `{pid, parent, commandline}`.
## Every Windows proof used to pay a ~1.2 s powershell.exe spawn per field
## per hop: an ancestry check of depth three plus a brand check walked up
## to ten spawns, twice per adoption, which is most of why a Windows editor
## start ran 3-5x slower than Linux in the updater regression. Inside one
## already-running PowerShell each Get-CimInstance costs tens of ms. The
## walk stops exactly where the per-hop callers stopped: a parent of 0/1,
## a self-parent, a missing record, or `max_depth` hops.
const WINDOWS_PROCESS_CHAIN_DEPTH := 16


static func windows_process_chain(
	pid: int, max_depth := WINDOWS_PROCESS_CHAIN_DEPTH
) -> Array[Dictionary]:
	if pid <= 1 or max_depth <= 0:
		return []
	var script := (
		"$current = %d; $depth = 0; "
		+ "while ($current -gt 1 -and $depth -lt %d) { "
		+ "$p = Get-CimInstance Win32_Process -Filter \"ProcessId = $current\" "
		+ "-ErrorAction SilentlyContinue; "
		+ "if (-not $p) { break }; "
		+ "\"$($p.ProcessId)|$($p.ParentProcessId)|$($p.CommandLine)\"; "
		+ "if ($p.ParentProcessId -le 1 -or $p.ParentProcessId -eq $p.ProcessId) { break }; "
		+ "$current = $p.ParentProcessId; $depth++ }"
	) % [pid, max_depth]
	var output: Array = []
	if execute_windows_powershell(script, output) != 0:
		return []
	return parse_windows_process_chain(output, pid, max_depth)


## Pure parser for `windows_process_chain` output: `pid|parent|commandline`
## per line, command line last because it may itself contain `|`. Parsing
## stops at the first malformed line, at a line whose pid is not the hop
## the previous line's parent promised, or at `max_depth` records, so a
## partial or garbled dump can only shorten the chain, never invent
## ancestry.
static func parse_windows_process_chain(
	output: Array, root_pid: int, max_depth := WINDOWS_PROCESS_CHAIN_DEPTH
) -> Array[Dictionary]:
	var chain: Array[Dictionary] = []
	var expected := root_pid
	for raw in output:
		for line in str(raw).split("\n"):
			var trimmed: String = line.strip_edges()
			if trimmed.is_empty():
				continue
			if chain.size() >= max_depth:
				return chain
			var parts := trimmed.split("|", true, 2)
			if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
				return chain
			var record_pid := int(parts[0])
			if record_pid != expected:
				return chain
			var parent := int(parts[1])
			chain.append(
				{
					"pid": record_pid,
					"parent": parent,
					"commandline": parts[2].strip_edges() if parts.size() > 2 else "",
				}
			)
			if parent <= 1 or parent == record_pid:
				return chain
			expected = parent
	return chain


## `process_descends_from` over a fetched chain. Mirrors the per-hop walk:
## the process itself counts, then each ancestor the chain resolved. The
## last record's parent also counts, exactly as the per-hop walk compared
## the parent id it had just read before fetching that parent's record.
static func chain_descends_from(chain: Array[Dictionary], pid: int, ancestor_pid: int) -> bool:
	if pid <= 1 or ancestor_pid <= 1:
		return false
	if pid == ancestor_pid:
		return true
	for record in chain:
		if int(record.get("pid", 0)) == ancestor_pid:
			return true
		if int(record.get("parent", 0)) == ancestor_pid:
			return true
	return false


## `pid_cmdline_is_godot_ai` over a fetched chain: the brand may sit on the
## process or on one of its first `max_depth - 1` ancestors (a wrapper shell
## or launcher owns the branded server).
static func chain_has_godot_ai_brand(chain: Array[Dictionary], max_depth := 5) -> bool:
	var depth := 0
	for record in chain:
		if depth >= max_depth:
			return false
		if commandline_is_godot_ai_server(str(record.get("commandline", ""))):
			return true
		depth += 1
	return false


static func process_descends_from(pid: int, ancestor_pid: int) -> bool:
	if pid <= 1 or ancestor_pid <= 1:
		return false
	if OS.get_name() == "Windows":
		return chain_descends_from(windows_process_chain(pid), pid, ancestor_pid)
	var current := pid
	for _depth in range(16):
		if current == ancestor_pid:
			return true
		var parent := process_parent(current)
		if parent <= 1 or parent == current:
			return false
		current = parent
	return false


static func commandline_is_godot_ai_server(commandline: String) -> bool:
	if commandline.is_empty():
		return false
	var lower := commandline.to_lower()
	var expression := RegEx.new()
	var brand_search := lower
	if expression.compile("--pid-file(?:=|\\s+)\\S+") == OK:
		brand_search = expression.sub(lower, "--pid-file ", true)
	var branded := brand_search.contains("godot-ai") or brand_search.contains("godot_ai")
	return branded and (lower.contains("--pid-file") or lower.contains("--transport"))


static func pid_cmdline_is_godot_ai(pid: int) -> bool:
	if OS.get_name() == "Windows":
		return chain_has_godot_ai_brand(windows_process_chain(pid, 5), 5)
	var current := pid
	for _depth in range(5):
		if current <= 1:
			return false
		if commandline_is_godot_ai_server(process_commandline(current)):
			return true
		current = process_parent(current)
	return false


static func process_fingerprint(pid: int) -> String:
	if not pid_alive(pid):
		return ""
	var output: Array = []
	var identity := ""
	if OS.get_name() == "Windows":
		var script := (
			"Get-CimInstance Win32_Process -Filter 'ProcessId = %d' | "
			+ "ForEach-Object { \"$($_.CreationDate)|$($_.CommandLine)\" }"
		) % pid
		if execute_windows_powershell(script, output) == 0 and not output.is_empty():
			identity = str(output[0]).strip_edges()
		if identity.is_empty():
			## Some restricted Windows hosts expose process start time through
			## Get-Process while CIM returns no Win32_Process projection. PID +
			## creation time is the reuse-resistant identity; command-line brand
			## is checked independently before destructive authority is minted.
			output.clear()
			script = (
				"(Get-Process -Id %d -ErrorAction Stop).StartTime.ToFileTimeUtc()"
			) % pid
			if execute_windows_powershell(script, output) == 0 and not output.is_empty():
				identity = str(output[0]).strip_edges()
	else:
		if OS.execute(
			"ps", ["-ww", "-p", str(pid), "-o", "lstart=", "-o", "args="], output, true
		) == 0 and not output.is_empty():
			identity = str(output[0]).strip_edges()
	if identity.is_empty():
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update((str(pid) + "|" + identity).to_utf8_buffer())
	return context.finish().hex_encode()


## Capture the process identity that a later destructive call must present.
## A PID or command-line brand alone is never kill authority: either can refer
## to a different process by the time a worker reaches the effect boundary.
static func capture_process_kill_grant(pid: int, require_brand := false) -> Dictionary:
	if pid <= 1 or pid == OS.get_process_id() or not pid_alive(pid):
		return {}
	if require_brand and not pid_cmdline_is_godot_ai(pid):
		return {}
	var fingerprint := process_fingerprint(pid)
	if fingerprint.is_empty():
		return {}
	## Close the capture window: both identity and optional lineage/brand must
	## still describe the same process after the fingerprint read.
	if process_fingerprint(pid) != fingerprint:
		return {}
	if require_brand and not pid_cmdline_is_godot_ai(pid):
		return {}
	return {"pid": pid, "fingerprint": fingerprint}


## Kill only exact process grants and re-read identity immediately before the
## OS call. On Windows, taskkill /T already handles real descendants; do not
## append command-line lookalikes such as spoofed multiprocessing children.
static func kill_exact_processes(
	grants: Array[Dictionary], require_brand := false, require_tree_proof := false
) -> Array[int]:
	var killed: Array[int] = []
	var seen: Array[int] = []
	for grant in grants:
		if grant.keys().size() != 2 or not grant.has("pid") or not grant.has("fingerprint"):
			continue
		var pid := int(grant.get("pid", 0))
		var fingerprint := str(grant.get("fingerprint", ""))
		if (
			pid <= 1
			or pid == OS.get_process_id()
			or seen.has(pid)
			or fingerprint.is_empty()
			or process_fingerprint(pid) != fingerprint
			or (require_brand and not pid_cmdline_is_godot_ai(pid))
		):
			continue
		seen.append(pid)
		if OS.get_name() == "Windows":
			var output: Array = []
			var code := OS.execute("taskkill", ["/PID", str(pid), "/T", "/F"], output, true)
			## A vanished direct PID is enough for ordinary exact-process callers.
			## Timeout safety needs stronger evidence: only taskkill /T success
			## proves that Windows accepted termination of the whole child tree.
			if code == 0 or (not require_tree_proof and not pid_alive(pid)):
				killed.append(pid)
		elif OS.kill(pid) == OK or not pid_alive(pid):
			killed.append(pid)
	return killed


## Poll until the given port is no longer bound, or the timeout elapses.
## Used after `OS.kill` so we don't race the port-in-use check on rebind.
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
