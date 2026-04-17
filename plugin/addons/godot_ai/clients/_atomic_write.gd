@tool
class_name McpAtomicWrite
extends RefCounted

## Write text to a file via temp + rename so a crash mid-write never leaves
## the user's MCP config truncated. Creates the parent dir if needed and
## keeps a one-shot `.backup` of the prior file.


static func write(path: String, content: String) -> bool:
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
			return false

	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()

	# Best-effort: keep a one-shot backup of the prior file if it existed.
	if FileAccess.file_exists(path):
		var backup := path + ".backup"
		DirAccess.remove_absolute(backup)
		DirAccess.copy_absolute(path, backup)

	if DirAccess.rename_absolute(tmp_path, path) != OK:
		# Fallback for filesystems where rename-over-existing fails: remove + rename.
		DirAccess.remove_absolute(path)
		if DirAccess.rename_absolute(tmp_path, path) != OK:
			DirAccess.remove_absolute(tmp_path)
			return false
	return true
