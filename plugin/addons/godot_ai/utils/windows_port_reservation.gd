@tool
class_name WindowsPortReservation
extends RefCounted

## Detects whether Windows has reserved a TCP port range that covers the
## plugin's server port. Hyper-V, WSL2, Docker Desktop, and Windows
## Sandbox all grab port ranges at boot via the winnat service. When a
## user's chosen port sits inside a reserved range, bind(2) fails with
## WinError 10013 ("forbidden by its access permissions") rather than
## 10048 ("address in use") — `netstat` shows nothing because no process
## owns the port, making the failure invisible. See issue #146.

const NETSH_ARGS := ["interface", "ipv4", "show", "excludedportrange", "protocol=tcp"]


## Returns true if `port` falls inside a currently-reserved range on this
## Windows host. No-op on non-Windows (returns false).
static func is_port_excluded(port: int) -> bool:
	if OS.get_name() != "Windows":
		return false
	var output: Array = []
	var exit_code := OS.execute("netsh", NETSH_ARGS, output, true)
	if exit_code != 0 or output.is_empty():
		return false
	return parse_excluded(str(output[0]), port)


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
		if port >= start_p and port <= end_p:
			return true
	return false


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
