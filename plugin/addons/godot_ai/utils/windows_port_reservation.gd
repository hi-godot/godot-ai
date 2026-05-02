@tool
class_name McpWindowsPortReservation
extends RefCounted

## Detects whether Windows has reserved a TCP port range that covers the
## plugin's server port. Hyper-V, WSL2, Docker Desktop, and Windows
## Sandbox all grab port ranges at boot via the winnat service. When a
## user's chosen port sits inside a reserved range, bind(2) fails with
## WinError 10013 ("forbidden by its access permissions") rather than
## 10048 ("address in use") — `netstat` shows nothing because no process
## owns the port, making the failure invisible. See issue #146.

const NETSH_ARGS := ["interface", "ipv4", "show", "excludedportrange", "protocol=tcp"]
const NETSH_CACHE_TTL_MS := 2000

static var _netsh_cache_text := ""
static var _netsh_cache_msec := 0
static var _netsh_cache_valid := false
static var _netsh_query_count := 0


## Returns true if `port` falls inside a currently-reserved range on this
## Windows host. No-op on non-Windows (returns false).
static func is_port_excluded(port: int) -> bool:
	if OS.get_name() != "Windows":
		return false
	var now_ms := Time.get_ticks_msec()
	var cached := _get_cached_excluded_output(now_ms)
	if bool(cached.get("hit", false)):
		return parse_excluded(str(cached.get("text", "")), port)
	var output: Array = []
	var exit_code := _execute_netsh_excluded_ranges(output)
	if exit_code != 0 or output.is_empty():
		return false
	var text := str(output[0])
	_store_excluded_output(text, now_ms)
	return parse_excluded(text, port)


static func _store_excluded_output(text: String, now_ms: int) -> void:
	_netsh_cache_text = text
	_netsh_cache_msec = now_ms
	_netsh_cache_valid = true


static func _get_cached_excluded_output(now_ms: int) -> Dictionary:
	if not _netsh_cache_valid:
		return {"hit": false, "text": ""}
	if now_ms - _netsh_cache_msec > NETSH_CACHE_TTL_MS:
		return {"hit": false, "text": ""}
	return {"hit": true, "text": _netsh_cache_text}


static func _clear_cache_for_tests() -> void:
	_netsh_cache_text = ""
	_netsh_cache_msec = 0
	_netsh_cache_valid = false


static func netsh_query_count() -> int:
	return _netsh_query_count


static func _execute_netsh_excluded_ranges(output: Array) -> int:
	_netsh_query_count += 1
	return OS.execute("netsh", NETSH_ARGS, output, true)


## Parse the `netsh` excluded-port-range output and return true if `port`
## sits inside any reserved range. Exposed for testing; the live check
## uses `is_port_excluded`. Expected input format:
##
##   Protocol tcp Port Exclusion Ranges
##
##   Start Port    End Port
##   ----------    --------
##          80            80
##        5040          5040
##        8000          8099
##
##   * - Administered port exclusions.
static func parse_excluded(text: String, port: int) -> bool:
	return _ranges_contain(parse_excluded_ranges(text), port)


## Parse the `netsh` excluded-port-range output once into inclusive ranges.
static func parse_excluded_ranges(text: String) -> Array[Vector2i]:
	var ranges: Array[Vector2i] = []
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("-") or trimmed.begins_with("*"):
			continue
		var parts: PackedStringArray = trimmed.split(" ", false)
		if parts.size() < 2:
			continue
		if not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		var start_p := int(parts[0])
		var end_p := int(parts[1])
		ranges.append(Vector2i(start_p, end_p))
	return ranges


static func _ranges_contain(ranges: Array[Vector2i], port: int) -> bool:
	for r in ranges:
		if port >= r.x and port <= r.y:
			return true
	return false


## Return the first port in `start`..`start+span-1` that is not excluded by
## Windows' port reservation table. Runs `netsh` once, unlike probing every
## candidate with `is_port_excluded`, which keeps fallback port selection cheap
## when Hyper-V / WSL2 / Docker reserve many adjacent ranges.
static func suggest_non_excluded_port(start: int, span: int = 2048, max_port: int = 65535) -> int:
	if OS.get_name() != "Windows":
		return start
	var now_ms := Time.get_ticks_msec()
	var cached := _get_cached_excluded_output(now_ms)
	if bool(cached.get("hit", false)):
		return suggest_non_excluded_port_from_output(str(cached.get("text", "")), start, span, max_port)
	var output: Array = []
	var exit_code := _execute_netsh_excluded_ranges(output)
	if exit_code != 0 or output.is_empty():
		return start
	var text := str(output[0])
	_store_excluded_output(text, now_ms)
	return suggest_non_excluded_port_from_output(text, start, span, max_port)


## Pure parser-backed helper for tests and for `suggest_non_excluded_port`.
static func suggest_non_excluded_port_from_output(text: String, start: int, span: int = 2048, max_port: int = 65535) -> int:
	var ranges := parse_excluded_ranges(text)
	var limit := mini(start + span - 1, max_port)
	var p := start
	while p <= limit:
		var advanced := false
		for r in ranges:
			if p >= r.x and p <= r.y:
				p = r.y + 1
				advanced = true
				break
		if not advanced:
			return p
	return start


## User-facing hint for the proactive port-reservation detection path —
## rendered when `is_port_excluded(port)` returns true *before* we even
## try to bind. Same copy as the post-crash WinError-10013 branch in
## `hint_from_output` so the two entry points agree.
static func port_excluded_hint(port: int) -> String:
	return "Port %d is reserved by Windows (often Hyper-V / WSL2 / Docker Desktop). In an admin PowerShell: `net stop winnat; net start winnat`, then click Reconnect." % port


## Scan captured server output for known failure signatures and return a
## short, user-facing hint. Empty string means no match.
static func hint_from_output(lines: PackedStringArray, port: int) -> String:
	var joined := "\n".join(lines).to_lower()
	if joined.find("winerror 10013") >= 0 or joined.find("forbidden by its access permissions") >= 0:
		return port_excluded_hint(port)
	if joined.find("errno 98") >= 0 or joined.find("winerror 10048") >= 0 or joined.find("address already in use") >= 0:
		return "Port %d is already in use by another process. Stop the conflicting process, then click Reconnect." % port
	if joined.find("modulenotfounderror") >= 0 or joined.find("no module named") >= 0:
		return "The `godot-ai` Python package didn't load. Try `uv cache clean`, then Reconnect."
	return ""
