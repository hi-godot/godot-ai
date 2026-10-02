@tool
class_name McpClientMutationLock
extends RefCounted

## Durable, atomic authority for all automatic client mutations.
##
## A POSIX exact-PID kill cannot prove that a timed-out CLI left no descendant
## behind. The lock directory therefore survives plugin reload, editor restart,
## and crashes. Only a sequence whose every direct child terminated without an
## ambiguous kill removes it. An existing or malformed lock always fails closed.

const ROOT_DIR_NAME := "godot-ai"
const LOCK_DIR_NAME := "client_mutation.lock"
const RECORD_NAME := "owner.json"
const SCHEMA := 1
const _POSIX_PERMISSION_MASK := 0x1ff  ## 0777
const _OWNER_DIRECTORY_MODE := (
	FileAccess.UNIX_READ_OWNER
	| FileAccess.UNIX_WRITE_OWNER
	| FileAccess.UNIX_EXECUTE_OWNER
)


static func lock_path() -> String:
	return _root_path().path_join(LOCK_DIR_NAME)


static func recovery_message() -> String:
	return (
		"Automatic MCP client mutations are safety-locked. Stop relevant client processes "
		+ "or reboot, then explicitly remove '%s' before retrying; restarting Godot alone "
		+ "does not prove an old descendant stopped."
	) % lock_path()


static func is_locked() -> bool:
	var path := lock_path()
	return DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path)


## Atomically claim the one global mutation slot. Creation wins ownership;
## failure for any reason is indistinguishable from an existing unsafe owner.
static func acquire(client_id: String, operation: String) -> Dictionary:
	var path := lock_path()
	if not _prepare_private_root():
		return {"ok": false, "error": recovery_message(), "path": path}
	if DirAccess.make_dir_absolute(path) != OK:
		return {"ok": false, "error": recovery_message(), "path": path}
	if not _has_private_mode(path):
		## The directory itself remains as the durable deny marker. Never
		## write ownership data into a location whose privacy is unproven.
		return {"ok": false, "error": recovery_message(), "path": path}
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var record := {
		"schema": SCHEMA,
		"token": token,
		"pid": OS.get_process_id(),
		"client_id": client_id,
		"operation": operation,
		"started_unix": int(Time.get_unix_time_from_system()),
	}
	var record_path := path.path_join(RECORD_NAME)
	var file := FileAccess.open(record_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": recovery_message(), "path": path}
	file.store_string(JSON.stringify(record))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return {"ok": false, "error": recovery_message(), "path": path}
	return {"ok": true, "path": path, "record_path": record_path, "token": token}


## Release only the exact claim this process wrote. Every failure leaves either
## the record or its parent directory in place, which keeps later mutations
## denied rather than guessing that cleanup succeeded.
static func release(claim: Dictionary) -> bool:
	var path := str(claim.get("path", ""))
	var record_path := str(claim.get("record_path", ""))
	var token := str(claim.get("token", ""))
	if (
		path != lock_path()
		or record_path != path.path_join(RECORD_NAME)
		or token.is_empty()
	):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(record_path))
	if (
		not parsed is Dictionary
		or int(parsed.get("schema", 0)) != SCHEMA
		or str(parsed.get("token", "")) != token
		or int(parsed.get("pid", 0)) != OS.get_process_id()
	):
		return false
	if DirAccess.remove_absolute(record_path) != OK:
		return false
	return DirAccess.remove_absolute(path) == OK


static func _root_path() -> String:
	## Unlike user://, the OS config directory is shared by every Godot
	## project owned by this account. User-scope client config is shared too,
	## so a project-specific lock would leave the real cross-editor race open.
	##
	## A Flatpak editor that shares the home directory writes the host's client
	## configs, the same files an editor outside the sandbox writes, while its
	## own OS config directory is the per-app ~/.var/app/<id>/config. It takes
	## the lock where those other editors look for it.
	var host_config_home := McpPathTemplate.flatpak_host_config_home()
	if not host_config_home.is_empty():
		return host_config_home.path_join(ROOT_DIR_NAME)
	return OS.get_config_dir().path_join(ROOT_DIR_NAME)


static func _prepare_private_root() -> bool:
	var root := _root_path()
	if FileAccess.file_exists(root) or _is_link(root):
		return false
	if not DirAccess.dir_exists_absolute(root):
		var created := DirAccess.make_dir_absolute(root)
		## Another editor may have won the benign root-creation race. Accept
		## that only after independently proving the resulting directory.
		if created != OK and not DirAccess.dir_exists_absolute(root):
			return false
	return not _is_link(root) and _has_private_mode(root)


static func _has_private_mode(path: String) -> bool:
	if OS.get_name() == "Windows":
		return true
	var permission_error := FileAccess.set_unix_permissions(path, _OWNER_DIRECTORY_MODE)
	var actual_mode := FileAccess.get_unix_permissions(path) & _POSIX_PERMISSION_MASK
	return permission_error == OK and actual_mode == _OWNER_DIRECTORY_MODE


static func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent == null or parent.is_link(path)
