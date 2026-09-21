@tool
class_name McpTransportCapability
extends RefCounted

## Reads Python's atomic, private capability record as one indivisible value.
## This is a static boundary, not another state owner.

const CAPABILITY_DIR_ENV := "GODOT_AI_CAPABILITY_DIR"
const RECORD_VERSION := 1
const MAX_RECORD_BYTES := 1024
const _POSIX_PERMISSION_MASK := 0x1ff  ## 0777
const _GROUP_OTHER_PERMISSION_MASK := 0x3f  ## 0077
const _GROUP_OTHER_WRITE_MASK := 0x12  ## 0022
const _MAX_LINK_HOPS := 8
const _SYSTEM_TEMP_ROOTS: Array[String] = ["/tmp", "/private/tmp", "/var/tmp"]
const _KEYS: Array[String] = [
	"version", "http", "websocket", "instance_nonce",
]


static func read_for_http_port(http_port: int, captured_path := "") -> Dictionary:
	var path := str(captured_path)
	if not path.is_empty() and path.get_file() != "http-%d.json" % http_port:
		return {}
	return _read_path(path if not path.is_empty() else path_for_http_port(http_port))


static func _read_path(path: String) -> Dictionary:
	if path.is_empty() or not path.is_absolute_path():
		return {}
	var resolved := _resolve_trusted_path(path)
	if resolved.is_empty():
		return {}
	var directory := resolved.get_base_dir()
	if (
		not _safe_posix_ancestors(directory)
		or not _private_path(directory, true)
		or not _private_path(resolved, false)
	):
		return {}
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		return {}
	var length := file.get_length()
	if length < 1 or length > MAX_RECORD_BYTES + 1:
		return {}
	var bytes := file.get_buffer(length)
	if bytes.size() != length:
		return {}
	if bytes[bytes.size() - 1] == 10:
		bytes.resize(bytes.size() - 1)
	if bytes.is_empty() or bytes.size() > MAX_RECORD_BYTES:
		return {}
	for byte in bytes:
		if byte > 127:
			return {}
	var raw := bytes.get_string_from_ascii()
	## Godot resolves duplicate JSON keys. Tokens need no escapes, so reject
	## escaping and require each literal key exactly once before parsing.
	if raw.contains("\\"):
		return {}
	for key in _KEYS:
		if raw.count("\"%s\"" % key) != 1:
			return {}
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary) or parsed.size() != _KEYS.size():
		return {}
	for key in _KEYS:
		if not parsed.has(key):
			return {}
	var version: Variant = parsed["version"]
	if not (version is int or version is float) or float(version) != RECORD_VERSION:
		return {}
	if (
		not (parsed["http"] is String)
		or not (parsed["websocket"] is String)
		or not (parsed["instance_nonce"] is String)
	):
		return {}
	var http: String = parsed["http"]
	var websocket: String = parsed["websocket"]
	var nonce: String = parsed["instance_nonce"]
	if not is_http_capability(http) or not is_lower_hex(websocket, 64):
		return {}
	if not is_lower_hex(nonce, 32) or http == websocket:
		return {}
	return {
		"http": http,
		"websocket": websocket,
		"instance_nonce": nonce.to_lower(),
	}


static func _private_path(path: String, directory: bool) -> bool:
	if directory:
		if DirAccess.open(path) == null:
			return false
	elif not FileAccess.file_exists(path):
		return false
	if OS.get_name() == "Windows":
		## Godot's detectable link/reparse surface was checked by _path_has_link.
		## v4 deliberately makes no Windows DACL secrecy/integrity claim.
		return true
	## Godot exposes POSIX mode bits but not the owning UID. This proves only
	## that group/other access is closed; it is not an owner-identity proof.
	var mode := FileAccess.get_unix_permissions(path) & _POSIX_PERMISSION_MASK
	return mode != 0 and (mode & _GROUP_OTHER_PERMISSION_MASK) == 0


## Walk `path` from its root and return it with every accepted link component
## replaced by its target, or "" when the path must not be trusted. A link is
## followed only when the directory holding it is closed to group and other
## writes, so only that directory's owner or root could have placed it; ostree
## distributions need this for `/home -> /var/home` (#993). Godot exposes no
## owning UID, so this is the strongest proof available here; Python, which
## publishes the record, additionally requires such a link to be root-owned.
## The record file itself is never followed, and a chain longer than
## `_MAX_LINK_HOPS` fails closed. Windows keeps rejecting every detectable
## link or reparse point.
static func _resolve_trusted_path(path: String) -> String:
	if OS.get_name() == "Windows":
		return "" if _path_has_link(path) else path
	var remaining := path.simplify_path().split("/", false)
	var current := "/"
	var hops := 0
	while not remaining.is_empty():
		var part := remaining[0]
		remaining.remove_at(0)
		var candidate := current.path_join(part)
		var parent := DirAccess.open(current)
		if parent == null:
			return ""
		if parent.is_link(candidate):
			if (
				remaining.is_empty()
				or hops >= _MAX_LINK_HOPS
				or not _closed_to_group_and_other(current)
			):
				return ""
			hops += 1
			var target := parent.read_link(candidate)
			if target.is_empty():
				return ""
			if not target.is_absolute_path():
				target = current.path_join(target)
			var target_parts := target.simplify_path().split("/", false)
			target_parts.append_array(remaining)
			remaining = target_parts
			current = "/"
			continue
		current = candidate
	return current


static func _closed_to_group_and_other(directory: String) -> bool:
	var mode := FileAccess.get_unix_permissions(directory) & _POSIX_PERMISSION_MASK
	return mode != 0 and (mode & _GROUP_OTHER_WRITE_MASK) == 0


static func _path_has_link(path: String) -> bool:
	var current := path
	while not current.is_empty():
		var parent := current.get_base_dir()
		if parent.is_empty() or parent == current:
			return false
		var directory := DirAccess.open(parent)
		if directory == null or directory.is_link(current):
			return true
		current = parent
	return false


static func _safe_posix_ancestors(path: String) -> bool:
	if OS.get_name() == "Windows":
		return true
	var current := path.simplify_path()
	while not current.is_empty():
		if DirAccess.open(current) != null:
			var permissions := FileAccess.get_unix_permissions(current)
			if not _safe_posix_ancestor_mode(current, permissions):
				return false
		var parent := current.get_base_dir()
		if parent.is_empty() or parent == current:
			break
		current = parent
	return true


static func _safe_posix_ancestor_mode(path: String, permissions: int) -> bool:
	var mode := permissions & _POSIX_PERMISSION_MASK
	if mode == 0:
		return false
	if (mode & _GROUP_OTHER_WRITE_MASK) == 0:
		return true
	## Godot exposes no UID. Accept the conventional system temp boundary only
	## when its sticky bit is present; Python additionally proves root ownership
	## before it publishes a record below the same canonical roots.
	return (
		path.simplify_path() in _SYSTEM_TEMP_ROOTS
		and (permissions & FileAccess.UNIX_RESTRICTED_DELETE) != 0
	)


static func is_http_capability(value: String) -> bool:
	var bytes := value.to_ascii_buffer()
	if bytes.size() < 32 or bytes.size() > 128:
		return false
	for byte in bytes:
		if not (
			(byte >= 48 and byte <= 57)
			or (byte >= 65 and byte <= 90)
			or (byte >= 97 and byte <= 122)
			or byte in [43, 45, 46, 47, 61, 95, 126]
		):
			return false
	return true


static func is_hex(value: String, length: int) -> bool:
	if value.length() != length:
		return false
	for index in range(length):
		var code := value.unicode_at(index)
		if not (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 70)
			or (code >= 97 and code <= 102)
		):
			return false
	return true


static func is_lower_hex(value: String, length: int) -> bool:
	return is_hex(value, length) and value == value.to_lower()


## Windows only: "" when this account can create and write the capability
## directory, else a repair message. Python creates the directory with
## ``mode=0o700`` on POSIX, but on Windows that mode yields a DACL of SYSTEM,
## Administrators and OWNER RIGHTS alone; a directory first created by an
## elevated process is then owned by Administrators and unusable from the
## user's own unelevated editor, server and bridge (#988). Creating it here
## first inherits the per-user %LOCALAPPDATA% DACL, and probing it before the
## spawn turns a silent "proof timed out at capability_record" into a message
## that names the directory and the fix.
static func directory_write_problem(http_port: int) -> String:
	if OS.get_name() != "Windows":
		return ""
	var record := path_for_http_port(http_port)
	if record.is_empty():
		return ""
	return directory_write_problem_for(record.get_base_dir())


static func directory_write_problem_for(directory: String) -> String:
	if DirAccess.open(directory) == null:
		var created := DirAccess.make_dir_recursive_absolute(directory)
		if created != OK:
			return windows_repair_hint(directory, error_string(created))
	var probe := directory.path_join(".access-probe-%d-%s" % [
		OS.get_process_id(), Crypto.new().generate_random_bytes(4).hex_encode(),
	])
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if file == null:
		return windows_repair_hint(directory, error_string(FileAccess.get_open_error()))
	file.close()
	DirAccess.remove_absolute(probe)
	return ""


static func windows_repair_hint(directory: String, detail: String) -> String:
	return (
		"Godot AI cannot use the directory %s (%s): this Windows account cannot "
		+ "access it. This can happen when an elevated (Run as administrator) "
		+ "process created it. Check this directory's permissions and grant your "
		+ "Windows account access, then reopen Godot and your AI clients without "
		+ "Run as administrator."
	) % [directory, detail]


static func path_for_http_port(http_port: int) -> String:
	if http_port < 1 or http_port > 65535:
		return ""
	var override := OS.get_environment(CAPABILITY_DIR_ENV).strip_edges()
	if OS.get_name() == "Windows" and not override.is_empty():
		return ""
	var directory := override
	if directory.is_empty():
		if OS.get_name() == "Windows":
			directory = OS.get_environment("LOCALAPPDATA").strip_edges()
			if directory.is_empty():
				return ""
			directory = directory.path_join("godot-ai/capabilities")
		elif OS.get_name() == "macOS":
			directory = OS.get_environment("HOME").path_join(
				"Library/Application Support/godot-ai/capabilities"
			)
		else:
			directory = OS.get_environment("XDG_CONFIG_HOME").strip_edges()
			if directory.is_empty():
				directory = OS.get_environment("HOME").path_join(".config")
			directory = directory.path_join("godot-ai/capabilities")
	if directory.is_empty() or not directory.is_absolute_path():
		return ""
	return directory.simplify_path().path_join("http-%d.json" % http_port)
