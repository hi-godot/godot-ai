@tool
extends Node

## Puts the final v3 add-on back when this Godot is below v4's floor. The
## user's own updater already overlaid the capsule over their v3 tree and
## discarded its per-file backups, so without this the plugin stays dead
## until they upgrade Godot. Parented outside the EditorPlugin so it survives
## the capsule being disabled. Leaves with the capsule once the fleet is on
## v4 (docs/self-update.md).

const PLUGIN_CFG := "res://addons/godot_ai/plugin.cfg"
const LIVE_ROOT := "res://addons/godot_ai"
const FALLBACK_ZIP := "res://addons/godot_ai/migration_payload/godot-ai-v3-plugin.zip"
const LIVE_PREFIX := "addons/godot_ai/"
## Every file is written and read back here before the live tree is touched.
## The update directory is hidden from Godot's scanner and from git exactly
## as utils/update_installer.gd hides it.
const UPDATE_ROOT := "res://addons/.godot_ai_update"
const STAGE_ROOT := UPDATE_ROOT + "/v3-restore"
const UPDATE_IGNORE_FILES := [[".gdignore", ""], [".gitignore", "*\n"]]
const MAX_FILES := 4096
const MAX_TOTAL_BYTES := 64 * 1024 * 1024
## Capsule-only files; the restored v3 tree must not carry them.
const CAPSULE_ONLY := [
	"migration_bridge.gd", "migration_bridge.gd.uid",
	"migration_coordinator.gd", "migration_coordinator.gd.uid",
	"migration_fallback.gd", "migration_fallback.gd.uid",
	"utils/release_verifier.gd", "utils/release_verifier.gd.uid",
	"utils/update_installer.gd", "utils/update_installer.gd.uid",
	"migration_payload",
]


static func available() -> bool:
	return FileAccess.file_exists(FALLBACK_ZIP)


func start() -> void:
	_restore.call_deferred()


func _restore() -> void:
	var entries: Array = []
	var error := _read_payload(entries)
	if error.is_empty():
		error = _prepare_update_root()
	if error.is_empty():
		error = _write_all(STAGE_ROOT, entries)
	if error.is_empty():
		error = _write_all(LIVE_ROOT, entries)
	if not error.is_empty():
		## The capsule payload and any stage stay for a retry; nothing is
		## removed until the restored plugin has been enabled.
		push_error("Godot AI v4 migration: could not restore the previous version: %s" % error)
		queue_free()
		return
	print(
		"MCP | v3 bridge restored Godot AI v%s; update again on Godot 4.7 or newer"
		% _restored_version()
	)
	## Disabling the capsule removed its dock; re-enabling after a scan loads
	## the restored plugin.gd, exactly as final v3's own updater re-enables.
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, false)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		_enable_after_scan.call_deferred()
		return
	filesystem.filesystem_changed.connect(_enable_after_scan, CONNECT_ONE_SHOT)
	filesystem.scan()


func _enable_after_scan() -> void:
	EditorInterface.set_plugin_enabled(PLUGIN_CFG, true)
	if not EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		push_error(
			"Godot AI v4 migration: the restored plugin could not be enabled;"
			+ " the capsule payload is kept for another attempt"
		)
		queue_free()
		return
	## Only a running restored plugin makes the capsule material disposable.
	_remove_capsule_only()
	_discard_stage()
	queue_free()


## Every entry must be a regular file under the live add-on path: no absolute
## paths, no `..`, nothing outside `addons/godot_ai/`. Read everything before
## writing anything, so a bad archive changes nothing.
func _read_payload(entries: Array) -> String:
	var reader := ZIPReader.new()
	if reader.open(FALLBACK_ZIP) != OK:
		return "cannot open %s" % FALLBACK_ZIP
	var files := reader.get_files()
	if files.size() > MAX_FILES:
		reader.close()
		return "too many entries"
	var total := 0
	for name in files:
		if name.ends_with("/"):
			continue
		var segments := name.split("/")
		if (
			not name.begins_with(LIVE_PREFIX)
			or name.contains("\\")
			or segments.has("..")
			or segments.has(".")
			or segments.has("")
		):
			reader.close()
			return "unsafe entry %s" % name
		var data := reader.read_file(name)
		total += data.size()
		if total > MAX_TOTAL_BYTES:
			reader.close()
			return "payload too large"
		entries.append([name, data])
	reader.close()
	if entries.is_empty():
		return "empty archive"
	return ""


static func _prepare_update_root() -> String:
	var root := ProjectSettings.globalize_path(UPDATE_ROOT)
	if DirAccess.make_dir_recursive_absolute(root) != OK:
		return "cannot create %s" % root
	for marker in UPDATE_IGNORE_FILES:
		var path := root.path_join(str(marker[0]))
		if FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return "cannot write %s" % path
		file.store_string(str(marker[1]))
		file.close()
	_remove_dir(ProjectSettings.globalize_path(STAGE_ROOT))
	return ""


## Drop the stage; when nothing but the ignore markers is left, drop the
## update directory too, so a refused or restored crossing leaves no trace.
static func _discard_stage() -> void:
	_remove_dir(ProjectSettings.globalize_path(STAGE_ROOT))
	var root := ProjectSettings.globalize_path(UPDATE_ROOT)
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.include_hidden = true
	dir.include_navigational = false
	if not dir.get_directories().is_empty():
		return
	var markers := PackedStringArray()
	for marker in UPDATE_IGNORE_FILES:
		markers.append(str(marker[0]))
	for name in dir.get_files():
		if not markers.has(name):
			return
	_remove_dir(root)


## Write every entry under `root`, checking each write and reading it back,
## so a full disk or a refused file stops before anything else is touched.
static func _write_all(root: String, entries: Array) -> String:
	for entry in entries:
		var relative: String = str(entry[0]).trim_prefix(LIVE_PREFIX)
		var error := _write_checked(root + "/" + relative, entry[1])
		if not error.is_empty():
			return error
	return ""


static func _write_checked(target: String, data: PackedByteArray) -> String:
	var parent := ProjectSettings.globalize_path(target.get_base_dir())
	if DirAccess.make_dir_recursive_absolute(parent) != OK:
		return "cannot create %s" % parent
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return "cannot write %s (%s)" % [target, error_string(FileAccess.get_open_error())]
	file.store_buffer(data)
	var error := file.get_error()
	file.close()
	if error != OK:
		return "write failed for %s (%s)" % [target, error_string(error)]
	var written := FileAccess.get_file_as_bytes(target)
	if written.size() != data.size():
		return "short write for %s (%d of %d bytes)" % [target, written.size(), data.size()]
	return ""


func _remove_capsule_only() -> void:
	for relative in CAPSULE_ONLY:
		var path := ProjectSettings.globalize_path(LIVE_ROOT + "/" + str(relative))
		if DirAccess.dir_exists_absolute(path):
			_remove_dir(path)
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


static func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	dir.include_navigational = false
	for name in dir.get_directories():
		_remove_dir(path.path_join(name))
	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	DirAccess.remove_absolute(path)


static func _restored_version() -> String:
	var config := ConfigFile.new()
	if config.load(PLUGIN_CFG) != OK:
		return "?"
	return str(config.get_value("plugin", "version", "?"))
