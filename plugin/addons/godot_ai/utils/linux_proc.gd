@tool
extends RefCounted

## Linux process and listener evidence from the editor's own PID/network
## namespace. Never run host commands across a Flatpak/Steam sandbox boundary.
## proc files report length zero: read bounded chunks, not get_as_text().

static func read_text(path: String, limit := 1024 * 1024) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"known": false, "text": ""}
	var bytes := PackedByteArray()
	while bytes.size() <= limit:
		var chunk := file.get_buffer(mini(4096, limit + 1 - bytes.size()))
		if chunk.is_empty():
			break
		bytes.append_array(chunk)
		if file.eof_reached():
			break
	var error := file.get_error()
	file.close()
	if bytes.size() > limit or error not in [OK, ERR_FILE_EOF]:
		return {"known": false, "text": ""}
	for index in range(bytes.size()):
		if bytes[index] == 0:
			bytes[index] = 32
	return {"known": true, "text": bytes.get_string_from_utf8()}


static func parse_stat(raw: String, expected_pid: int) -> Dictionary:
	## comm may contain spaces, parentheses and newlines. The final ')' is
	## the delimiter; field 22 (starttime) is index 19 after comm.
	var opening := raw.find(" (")
	var closing := raw.rfind(") ")
	if opening < 1 or closing <= opening:
		return {}
	var pid_text := raw.substr(0, opening)
	var fields := raw.substr(closing + 2).strip_edges().split(" ", false)
	if not pid_text.is_valid_int() or int(pid_text) != expected_pid or fields.size() < 20:
		return {}
	if fields[0] not in ["R", "S", "D", "T", "t", "Z", "X", "x", "K", "W", "P", "I"]:
		return {}
	if not fields[1].is_valid_int() or int(fields[1]) < 0 or not fields[19].is_valid_int() or int(fields[19]) < 0:
		return {}
	return {"state": fields[0], "parent_pid": int(fields[1]), "start": fields[19]}


static func process_stat(pid: int, root := "/proc") -> Dictionary:
	var read := read_text(root.path_join("%d/stat" % pid), 8192)
	return parse_stat(read.text, pid) if read.known else {}


static func is_alive(row: Dictionary) -> bool:
	return not row.is_empty() and row.state not in ["Z", "X", "x"]


static func commandline(pid: int, root := "/proc") -> String:
	var read := read_text(root.path_join("%d/cmdline" % pid))
	return str(read.text).strip_edges() if read.known else ""


static func process_snapshot(pid: int, root := "/proc") -> Dictionary:
	if DirAccess.open(root) == null:
		return {"capture_error": true}
	var snapshot := {}
	var current := pid
	for _depth in range(16):
		if current <= 1:
			break
		if snapshot.has(current):
			return {"capture_error": true}
		var first := process_stat(current, root)
		if first.is_empty():
			## A vanished process differs from an unreadable proc mount.
			return snapshot if not DirAccess.dir_exists_absolute(root.path_join(str(current))) else {"capture_error": true}
		if not is_alive(first):
			return snapshot
		var read := read_text(root.path_join("%d/cmdline" % current))
		var final := process_stat(current, root)
		if not read.known or not is_alive(final) or first.start != final.start or first.parent_pid != final.parent_pid:
			return {"capture_error": true}
		var command := str(read.text).strip_edges()
		snapshot[current] = {"pid": current, "parent_pid": first.parent_pid,
			"identity": "linux:" + str(first.start) + "|" + command, "commandline": command}
		current = int(first.parent_pid)
	return snapshot


static func parse_tcp(raw: String) -> Dictionary:
	var listeners := {}
	var lines := raw.strip_edges().split("\n", false)
	if lines.is_empty() or not lines[0].contains("local_address") or not lines[0].contains("inode"):
		return {"known": false, "listeners": {}}
	for line in lines.slice(1):
		var fields := line.replace("\t", " ").strip_edges().split(" ", false)
		if fields.size() < 10 or not fields[1].contains(":"):
			return {"known": false, "listeners": {}}
		if fields[3] != "0A":
			continue
		var port_hex := fields[1].get_slice(":", 1)
		if port_hex.length() != 4 or not port_hex.is_valid_hex_number() or not fields[9].is_valid_int() or int(fields[9]) <= 0:
			return {"known": false, "listeners": {}}
		var port := port_hex.hex_to_int()
		if not listeners.has(port):
			listeners[port] = []
		listeners[port].append(fields[9])
	return {"known": true, "listeners": listeners}


static func listener_snapshot(root := "/proc") -> Dictionary:
	var listeners := {}
	for name in ["tcp", "tcp6"]:
		var path := root.path_join("net/" + name)
		## IPv6 may be disabled at kernel build time; IPv4 must be readable.
		if name == "tcp6" and not FileAccess.file_exists(path):
			continue
		var read := read_text(path, 8 * 1024 * 1024)
		var parsed := parse_tcp(read.text) if read.known else {"known": false}
		if not parsed.known:
			return {"known": false, "listeners": {}}
		for port in parsed.listeners:
			if not listeners.has(port):
				listeners[port] = []
			listeners[port].append_array(parsed.listeners[port])
	return {"known": true, "listeners": listeners}


static func listener_pids(port: int, snapshot: Dictionary, root := "/proc") -> Array[int]:
	var result: Array[int] = []
	if not snapshot.get("known", false) or not snapshot.listeners.has(port):
		return result
	var wanted: Array = snapshot.listeners[port]
	var proc := DirAccess.open(root)
	if proc == null:
		return result
	for name in proc.get_directories():
		if not name.is_valid_int() or int(name) <= 1:
			continue
		var descriptors := DirAccess.open(root.path_join(name).path_join("fd"))
		if descriptors == null:
			continue
		## fd entries are symlinks; their socket targets need not exist as files.
		descriptors.list_dir_begin()
		var descriptor := descriptors.get_next()
		while not descriptor.is_empty():
			var target := descriptors.read_link(descriptor)
			if target.begins_with("socket:[") and target.ends_with("]") and wanted.has(target.substr(8, target.length() - 9)):
				result.append(int(name))
				break
			descriptor = descriptors.get_next()
		descriptors.list_dir_end()
	return result


static func available() -> bool:
	return (
		is_alive(process_stat(OS.get_process_id()))
		and DirAccess.open("/proc/self/fd") != null
		and listener_snapshot().known
	)
