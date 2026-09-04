@tool
class_name McpUpdateInstaller
extends RefCounted

## The in-editor half of the lean self-updater: stage a verified archive
## beside the live add-on, take the project-wide update lock, swap the two
## trees with two directory renames, and after the restart verify the live
## tree against the signed inventory, rolling back to the retained backup on
## any mismatch. See docs/self-update.md.
##
## Everything lives under `res://addons/.godot_ai_update/` (dot-prefixed so
## Godot's scanner ignores it; a `.gdignore` and a `.gitignore` are written
## on first use) plus the live root the caller passes in. No function writes
## anywhere else, no failure path deletes a backup, and every function fails
## closed with a specific error string instead of raising.

const UPDATE_ROOT := "res://addons/.godot_ai_update"
const STAGE_DIR := UPDATE_ROOT + "/stage"
const STAGE_PLUGIN_ROOT := STAGE_DIR + "/addons/godot_ai"
const BACKUP_DIR := UPDATE_ROOT + "/backup"
const QUARANTINE_DIR := UPDATE_ROOT + "/quarantine"
const PENDING_FILE := UPDATE_ROOT + "/pending.json"
const LOCK_FILE := UPDATE_ROOT + "/lock.json"
const DEFAULT_LIVE_ROOT := "res://addons/godot_ai"
const ENABLED_PLUGINS_SETTING := "editor_plugins/enabled"

const STATUS_SWAPPED := "swapped"
const STATUS_SUCCESS := "success"
const STATUS_ROLLED_BACK := "rolled_back"
const STATUS_REPAIR_REQUIRED := "repair_required"

const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const ReleaseVerifier := preload("res://addons/godot_ai/utils/release_verifier.gd")


# ----- staging ----------------------------------------------------------


## Extract `zip_path` into a fresh `stage/addons/godot_ai/` and prove the
## extracted tree hashes to exactly the signed inventory. Returns
## `{"ok", "error", "stage_root", "tree_sha256"}`; `stage_root` is the
## `res://` path of the staged plugin directory.
static func stage(zip_path: String, manifest: Dictionary) -> Dictionary:
	var result := {"ok": false, "error": "", "stage_root": "", "tree_sha256": ""}
	var validated := ReleaseVerifier.validate_manifest_dict(manifest)
	if not bool(validated.ok):
		result.error = "stage: %s" % str(validated.error)
		return result
	var normalised: Dictionary = validated.manifest
	var rooted := ensure_root()
	if not bool(rooted.ok):
		result.error = "stage: %s" % str(rooted.error)
		return result
	var stage_abs := _absolute(STAGE_DIR)
	if _exists(stage_abs):
		var removed := remove_under_update_root(STAGE_DIR)
		if not bool(removed.ok):
			result.error = "stage: cannot clear previous stage: %s" % str(removed.error)
			return result
	var reader := ZIPReader.new()
	var open_error := reader.open(_absolute(zip_path))
	if open_error != OK:
		result.error = "stage: cannot open archive %s: %s" % [zip_path, error_string(open_error)]
		return result
	var rows: Array = normalised["inventory"]
	var expected: Array = []
	for row in rows:
		expected.append(str(row["path"]))
	if Array(reader.get_files()) != expected:
		reader.close()
		result.error = "stage: archive entries do not match the signed inventory (run verify_archive for detail)"
		return result
	for row in rows:
		var path := str(row["path"])
		var target := stage_abs.path_join(path)
		var make_error := DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		if make_error != OK:
			reader.close()
			result.error = "stage: cannot create %s: %s" % [target.get_base_dir(), error_string(make_error)]
			return result
		var write_error := _write_bytes(target, reader.read_file(path))
		if write_error != OK:
			reader.close()
			result.error = "stage: cannot write %s: %s" % [target, error_string(write_error)]
			return result
	reader.close()
	var expected_hash := ReleaseVerifier.inventory_tree_hash(normalised)
	var hashed := ReleaseVerifier.hash_tree(STAGE_PLUGIN_ROOT)
	if not bool(hashed.ok):
		remove_under_update_root(STAGE_DIR)
		result.error = "stage: %s" % str(hashed.error)
		return result
	if expected_hash.is_empty() or str(hashed.tree_sha256) != expected_hash:
		remove_under_update_root(STAGE_DIR)
		result.error = "stage: staged tree hash %s differs from the signed inventory hash %s" % [
			str(hashed.tree_sha256), expected_hash,
		]
		return result
	result.stage_root = STAGE_PLUGIN_ROOT
	result.tree_sha256 = str(hashed.tree_sha256)
	result.ok = true
	return result


## Remove `stage/` if present (for example when quiescence is refused after
## staging). Never touches backups, quarantine, or the live tree.
static func discard_stage() -> void:
	if _exists(_absolute(STAGE_DIR)):
		remove_under_update_root(STAGE_DIR)


# ----- lock -------------------------------------------------------------


## Take `lock.json` for this editor. A lock whose recorded process is alive
## and carries a different fingerprint refuses; a dead or own lock is
## replaced. Returns `{"ok", "error"}`.
static func acquire_lock(pid: int, fingerprint: String) -> Dictionary:
	var result := {"ok": false, "error": ""}
	if pid <= 0 or fingerprint.is_empty():
		result.error = "lock: a positive pid and a non-empty fingerprint are required"
		return result
	var rooted := ensure_root()
	if not bool(rooted.ok):
		result.error = "lock: %s" % str(rooted.error)
		return result
	var existing := read_lock()
	if not existing.is_empty():
		var other_pid := int(existing.get("pid", 0))
		var other_fingerprint := str(existing.get("fingerprint", ""))
		if other_pid > 0 and other_fingerprint != fingerprint and PortResolver.pid_alive(other_pid):
			result.error = "lock: update lock is held by live process %d (%s) since %d" % [
				other_pid, other_fingerprint, int(existing.get("started_unix", 0)),
			]
			return result
	var write_error := _write_json(LOCK_FILE, {
		"pid": pid,
		"fingerprint": fingerprint,
		"started_unix": int(Time.get_unix_time_from_system()),
	})
	if write_error != OK:
		result.error = "lock: cannot write %s: %s" % [LOCK_FILE, error_string(write_error)]
		return result
	result.ok = true
	return result


## Drop `lock.json` when it belongs to this process or to a dead one. A
## lock held by another live process is left in place.
static func release_lock() -> void:
	var existing := read_lock()
	if existing.is_empty():
		if FileAccess.file_exists(_absolute(LOCK_FILE)):
			DirAccess.remove_absolute(_absolute(LOCK_FILE))
		return
	var pid := int(existing.get("pid", 0))
	if pid == OS.get_process_id() or not PortResolver.pid_alive(pid):
		DirAccess.remove_absolute(_absolute(LOCK_FILE))


## The current lock record, or `{}` when there is none or it is unreadable.
static func read_lock() -> Dictionary:
	return _read_json(LOCK_FILE)


# ----- swap -------------------------------------------------------------


## Replace the live tree with the staged one using two directory renames:
## live -> `backup/<from_version>/`, then stage -> live. If the second rename
## fails the first is undone. On success `pending.json` holds every key of
## `record` verbatim plus `status: "swapped"`, `backup_root`, `live_root`,
## `expected_tree_sha256` and `swapped_unix`. `record` must carry
## `from_version`, `to_version`, `manifest_sha256`, `expected_tree_sha256`
## and `editor_nonce`. Refuses when `backup/<from_version>/` already exists:
## backups are pruned only after a verified success, so a leftover one means
## an unresolved earlier update.
static func swap(stage_root: String, live_root: String, record: Dictionary) -> Dictionary:
	var result := {"ok": false, "error": ""}
	for key in ["from_version", "to_version", "manifest_sha256", "expected_tree_sha256", "editor_nonce"]:
		if not record.has(key) or not record[key] is String or str(record[key]).is_empty():
			result.error = "swap: record is missing %s" % key
			return result
	var from_version := str(record["from_version"])
	var to_version := str(record["to_version"])
	if not _is_safe_segment(from_version) or not _is_safe_segment(to_version):
		result.error = "swap: versions must be plain path segments, got %s -> %s" % [from_version, to_version]
		return result
	if not _is_hex(str(record["expected_tree_sha256"]), 64):
		result.error = "swap: expected_tree_sha256 must be 64 lowercase hex characters"
		return result
	var stage_abs := _absolute(stage_root)
	var live_abs := _absolute(live_root)
	if not DirAccess.dir_exists_absolute(stage_abs):
		result.error = "swap: stage root does not exist: %s" % stage_abs
		return result
	if not DirAccess.dir_exists_absolute(live_abs):
		result.error = "swap: live root does not exist: %s" % live_abs
		return result
	if stage_abs.simplify_path() == live_abs.simplify_path():
		result.error = "swap: stage and live roots are the same directory"
		return result
	var pending := read_pending()
	if not pending.is_empty() and str(pending.get("status", "")) == STATUS_SWAPPED:
		result.error = "swap: an earlier swap is still pending verification (%s)" % PENDING_FILE
		return result
	var rooted := ensure_root()
	if not bool(rooted.ok):
		result.error = "swap: %s" % str(rooted.error)
		return result
	var backup_root := BACKUP_DIR + "/" + from_version
	var backup_abs := _absolute(backup_root)
	if _exists(backup_abs):
		result.error = "swap: backup already exists at %s; an earlier update was never resolved" % backup_root
		return result
	var make_error := DirAccess.make_dir_recursive_absolute(_absolute(BACKUP_DIR))
	if make_error != OK:
		result.error = "swap: cannot create %s: %s" % [BACKUP_DIR, error_string(make_error)]
		return result
	var first := DirAccess.rename_absolute(live_abs, backup_abs)
	if first != OK:
		result.error = "swap: cannot move live tree %s to %s: %s" % [live_abs, backup_abs, error_string(first)]
		return result
	var second := DirAccess.rename_absolute(stage_abs, live_abs)
	if second != OK:
		var restore := DirAccess.rename_absolute(backup_abs, live_abs)
		result.error = "swap: cannot move stage %s into %s: %s" % [stage_abs, live_abs, error_string(second)]
		if restore != OK:
			result.error += "; restoring the backup failed too (%s): live tree is at %s" % [
				error_string(restore), backup_abs,
			]
		return result
	var marker := record.duplicate(true)
	marker["status"] = STATUS_SWAPPED
	marker["backup_root"] = backup_root
	marker["live_root"] = live_root
	marker["expected_tree_sha256"] = str(record["expected_tree_sha256"])
	marker["swapped_unix"] = int(Time.get_unix_time_from_system())
	## The editor that verifies the swap should be this same Godot. On macOS
	## the restart goes through LaunchServices, which has been seen to launch
	## another installed copy of Godot; recording the version lets the next
	## start explain that instead of silently refusing or verifying elsewhere.
	marker["godot_version"] = str(Engine.get_version_info().get("string", ""))
	var write_error := _write_json(PENDING_FILE, marker)
	if write_error != OK:
		var undo_stage := DirAccess.rename_absolute(live_abs, stage_abs)
		var undo_backup := DirAccess.rename_absolute(backup_abs, live_abs)
		result.error = "swap: cannot write %s: %s" % [PENDING_FILE, error_string(write_error)]
		if undo_stage != OK or undo_backup != OK:
			result.error += "; undoing the swap failed: new tree at %s, old tree at %s" % [
				live_abs if undo_stage != OK else stage_abs, backup_abs if undo_backup != OK else live_abs,
			]
		return result
	## The staged tree now lives; only its empty scaffold is left behind.
	discard_stage()
	result.ok = true
	return result


# ----- pending marker ---------------------------------------------------


## The `pending.json` record, `{}` when there is none. An unreadable marker
## is reported as `status: "repair_required"` rather than ignored.
static func read_pending() -> Dictionary:
	var absolute := _absolute(PENDING_FILE)
	if not FileAccess.file_exists(absolute):
		return {}
	var marker := _read_json(PENDING_FILE)
	if marker.is_empty():
		return {
			"status": STATUS_REPAIR_REQUIRED,
			"error": "pending marker %s exists but is not a JSON object; inspect it by hand" % PENDING_FILE,
		}
	return marker


## Record in the success marker that the plugin repinned client configuration,
## so later starts do not repeat the migration. No-op unless the marker
## records success.
static func record_clients_migrated() -> Error:
	var marker := read_pending()
	if str(marker.get("status", "")) != STATUS_SUCCESS:
		return ERR_UNAVAILABLE
	marker["clients_migrated"] = true
	return _write_json(PENDING_FILE, marker)


## Remove `pending.json`.
static func clear_pending() -> void:
	var absolute := _absolute(PENDING_FILE)
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)


## After the restart: settle a `swapped` marker. Hash the live tree and
## compare it to `expected_tree_sha256`. Equal: the marker becomes
## `success`. Different: the live tree is renamed to
## `quarantine/<to_version>/`, the backup is renamed back into place, and the
## marker becomes `rolled_back` with the reason. No backup: the marker becomes
## `repair_required` naming the exact paths and the live tree is left alone.
## Nothing is ever deleted. A marker in any other status is returned
## unchanged, and `{}` means there is nothing pending. Every marker key is
## preserved verbatim.
static func verify_after_restart(live_root: String) -> Dictionary:
	var marker := read_pending()
	if marker.is_empty():
		return {}
	if str(marker.get("status", "")) != STATUS_SWAPPED:
		## A success marker whose client migration already ran is the durable
		## record of the last update, not work for this start.
		if str(marker.get("status", "")) == STATUS_SUCCESS and bool(marker.get("clients_migrated", false)):
			return {}
		return marker
	var live_abs := _absolute(live_root)
	var expected := str(marker.get("expected_tree_sha256", ""))
	var hashed := ReleaseVerifier.hash_tree(live_abs)
	if bool(hashed.ok) and _is_hex(expected, 64) and str(hashed.tree_sha256) == expected:
		marker["status"] = STATUS_SUCCESS
		marker["error"] = ""
		marker["verified_unix"] = int(Time.get_unix_time_from_system())
		_write_json(PENDING_FILE, marker)
		return marker
	var reason := ""
	if not bool(hashed.ok):
		reason = "live tree could not be hashed: %s" % str(hashed.error)
	elif not _is_hex(expected, 64):
		reason = "pending marker carries no usable expected_tree_sha256"
	else:
		reason = "live tree hash %s does not match the expected %s" % [str(hashed.tree_sha256), expected]
	var backup_root := str(marker.get("backup_root", ""))
	var backup_abs := _absolute(backup_root) if not backup_root.is_empty() else ""
	if backup_abs.is_empty() or not DirAccess.dir_exists_absolute(backup_abs):
		return _settle_repair(marker, "%s; no backup exists at %s to restore, live tree left at %s" % [
			reason, backup_abs if not backup_abs.is_empty() else "(unrecorded)", live_abs,
		])
	var to_version := str(marker.get("to_version", ""))
	var quarantine_root := QUARANTINE_DIR + "/" + (to_version if _is_safe_segment(to_version) else "unknown")
	var quarantine_abs := _absolute(quarantine_root)
	if _exists(quarantine_abs):
		return _settle_repair(marker, "%s; quarantine already exists at %s, live tree left at %s, backup at %s" % [
			reason, quarantine_abs, live_abs, backup_abs,
		])
	if DirAccess.dir_exists_absolute(live_abs):
		var make_error := DirAccess.make_dir_recursive_absolute(_absolute(QUARANTINE_DIR))
		if make_error != OK:
			return _settle_repair(marker, "%s; cannot create %s (%s), live tree left at %s, backup at %s" % [
				reason, QUARANTINE_DIR, error_string(make_error), live_abs, backup_abs,
			])
		var quarantine_error := DirAccess.rename_absolute(live_abs, quarantine_abs)
		if quarantine_error != OK:
			return _settle_repair(marker, "%s; cannot move live tree %s to %s (%s), backup at %s" % [
				reason, live_abs, quarantine_abs, error_string(quarantine_error), backup_abs,
			])
	var restore_error := DirAccess.rename_absolute(backup_abs, live_abs)
	if restore_error != OK:
		var undo := DirAccess.rename_absolute(quarantine_abs, live_abs)
		return _settle_repair(marker, "%s; cannot restore backup %s to %s (%s); new tree is at %s" % [
			reason, backup_abs, live_abs, error_string(restore_error),
			live_abs if undo == OK else quarantine_abs,
		])
	marker["status"] = STATUS_ROLLED_BACK
	marker["error"] = reason
	marker["quarantine_root"] = quarantine_root
	marker["verified_unix"] = int(Time.get_unix_time_from_system())
	_write_json(PENDING_FILE, marker)
	return marker


# ----- retention --------------------------------------------------------


## Remove every `backup/<version>/` except `keep_version`. Call only after a
## verified success.
static func prune_backups(keep_version: String) -> void:
	var backups := DirAccess.open(_absolute(BACKUP_DIR))
	if backups == null:
		return
	backups.include_hidden = true
	backups.include_navigational = false
	for name in backups.get_directories():
		if name != keep_version:
			remove_under_update_root(BACKUP_DIR + "/" + name)


# ----- restart ----------------------------------------------------------


## Add `plugin_cfg` to `editor_plugins/enabled` and save project.godot so the
## next editor start loads the add-on, without enabling it in this process.
static func persist_next_start_enabled(plugin_cfg: String) -> Error:
	if plugin_cfg.is_empty():
		return ERR_INVALID_PARAMETER
	var enabled := PackedStringArray()
	if ProjectSettings.has_setting(ENABLED_PLUGINS_SETTING):
		var current: Variant = ProjectSettings.get_setting(ENABLED_PLUGINS_SETTING)
		if current is PackedStringArray:
			enabled = current
		elif current is Array:
			for item in current:
				enabled.append(str(item))
	if not enabled.has(plugin_cfg):
		enabled.append(plugin_cfg)
	ProjectSettings.set_setting(ENABLED_PLUGINS_SETTING, enabled)
	return ProjectSettings.save()


## Restart the editor, saving open scenes first.
static func request_restart() -> void:
	if Engine.is_editor_hint():
		EditorInterface.restart_editor(true)


# ----- update root ------------------------------------------------------


## Create `res://addons/.godot_ai_update/` with its `.gdignore` and
## `.gitignore` (`*`). Returns `{"ok", "error"}`.
static func ensure_root() -> Dictionary:
	var result := {"ok": false, "error": ""}
	var root_abs := _absolute(UPDATE_ROOT)
	var make_error := DirAccess.make_dir_recursive_absolute(root_abs)
	if make_error != OK:
		result.error = "cannot create %s: %s" % [UPDATE_ROOT, error_string(make_error)]
		return result
	for marker in [[".gdignore", ""], [".gitignore", "*\n"]]:
		var path := root_abs.path_join(str(marker[0]))
		if FileAccess.file_exists(path):
			continue
		var write_error := _write_bytes(path, str(marker[1]).to_utf8_buffer())
		if write_error != OK:
			result.error = "cannot write %s: %s" % [path, error_string(write_error)]
			return result
	result.ok = true
	return result


## Recursively remove a file or directory, refusing anything outside the
## update root. Returns `{"ok", "error"}`.
static func remove_under_update_root(path: String) -> Dictionary:
	var result := {"ok": false, "error": ""}
	var absolute := _absolute(path).simplify_path()
	var root_abs := _absolute(UPDATE_ROOT).simplify_path()
	if absolute == root_abs or not absolute.begins_with(root_abs + "/"):
		result.error = "refusing to remove %s: outside %s" % [absolute, UPDATE_ROOT]
		return result
	var remove_error := _remove_tree(absolute)
	if remove_error != OK:
		result.error = "cannot remove %s: %s" % [absolute, error_string(remove_error)]
		return result
	result.ok = true
	return result


# ----- helpers ----------------------------------------------------------


static func _settle_repair(marker: Dictionary, error: String) -> Dictionary:
	marker["status"] = STATUS_REPAIR_REQUIRED
	marker["error"] = error
	marker["verified_unix"] = int(Time.get_unix_time_from_system())
	_write_json(PENDING_FILE, marker)
	return marker


static func _remove_tree(absolute: String) -> Error:
	var parent := DirAccess.open(absolute.get_base_dir())
	if parent == null:
		return DirAccess.get_open_error()
	if not DirAccess.dir_exists_absolute(absolute) or parent.is_link(absolute):
		return DirAccess.remove_absolute(absolute)
	var directory := DirAccess.open(absolute)
	if directory == null:
		return DirAccess.get_open_error()
	directory.include_hidden = true
	directory.include_navigational = false
	for name in directory.get_files():
		var file_error := DirAccess.remove_absolute(absolute.path_join(name))
		if file_error != OK:
			return file_error
	for name in directory.get_directories():
		var child_error := _remove_tree(absolute.path_join(name))
		if child_error != OK:
			return child_error
	return DirAccess.remove_absolute(absolute)


static func _write_bytes(absolute: String, data: PackedByteArray) -> Error:
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(data)
	var error := file.get_error()
	file.close()
	return error


static func _write_json(path: String, data: Dictionary) -> Error:
	return _write_bytes(_absolute(path), (JSON.stringify(data, "\t") + "\n").to_utf8_buffer())


static func _read_json(path: String) -> Dictionary:
	var absolute := _absolute(path)
	if not FileAccess.file_exists(absolute):
		return {}
	var bytes := FileAccess.get_file_as_bytes(absolute)
	if bytes.is_empty() or not ReleaseVerifier.is_valid_utf8(bytes):
		return {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return {}
	return parsed


static func _exists(absolute: String) -> bool:
	return DirAccess.dir_exists_absolute(absolute) or FileAccess.file_exists(absolute)


static func _is_safe_segment(name: String) -> bool:
	if name.is_empty() or name.length() > 64 or name == "." or name == ".." or name.begins_with("."):
		return false
	for index in name.length():
		var code := name.unicode_at(index)
		var ok := (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or code == 45 or code == 46 or code == 95
		)
		if not ok:
			return false
	return true


static func _is_hex(text: String, length: int) -> bool:
	if text.length() != length:
		return false
	for index in text.length():
		var code := text.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


static func _absolute(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path
