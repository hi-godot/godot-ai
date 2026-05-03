@tool
class_name McpAtomicWrite
extends RefCounted

## Write text to a file via temp + rename so a crash mid-write never leaves
## the user's MCP config truncated. Creates the parent dir if needed and
## keeps a one-shot `.backup` of the prior file.
##
## On filesystems where rename-over-existing fails (Windows under AV / lock
## pressure, some SMB shares), falls back to overwrite-copy plus a
## backup-restore on failure. The original file is never removed before the
## new bytes are verified on disk — if both the rename and the copy fail,
## the user's prior config is restored from the `.backup` snapshot. See
## issue #297 finding #10 for the data-loss scenario this guards against.


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

	# Best-effort: snapshot the prior file before we touch the target so we
	# can restore on a failed swap. The backup is also kept on success as a
	# one-shot rollback aid for the user.
	var backup_path := path + ".backup"
	var had_original := FileAccess.file_exists(path)
	var backup_made := false
	if had_original:
		DirAccess.remove_absolute(backup_path)
		if DirAccess.copy_absolute(path, backup_path) == OK:
			backup_made = true

	if DirAccess.rename_absolute(tmp_path, path) == OK:
		return true

	# Rename-over-existing rejected (Windows + AV / lock timing, some SMB
	# shares). Use overwrite-copy as the recovery path: copy_absolute never
	# removes the original before writing the new bytes, so a failure here
	# leaves the user's prior config in place rather than nuking it.
	if DirAccess.copy_absolute(tmp_path, path) == OK and _written_size_matches(path, content):
		DirAccess.remove_absolute(tmp_path)
		return true

	# Copy didn't land cleanly. Restore the destination to its pre-call state.
	if backup_made:
		# Restore the snapshot we took before the swap. `copy_absolute`
		# overwrites the destination, so we don't pre-remove `path` — the
		# pre-remove created a window where `path` was gone if the
		# subsequent copy itself failed. If the restore copy fails now the
		# user's prior bytes are still in `.backup` for manual recovery
		# and the false return value tells the caller the swap didn't
		# complete.
		DirAccess.copy_absolute(backup_path, path)
	elif not had_original and FileAccess.file_exists(path):
		# No prior file existed but copy_absolute landed partial bytes at
		# `path`. Remove them so the failure leaves nothing on disk rather
		# than a truncated/invalid new file. The `file_exists` guard keeps
		# us off non-file destinations (a path that points at a directory
		# yields `had_original=false` too, but we must not try to delete
		# the directory). Issue #297 PR review.
		DirAccess.remove_absolute(path)
	# (If `had_original` is true but the snapshot couldn't be taken, the
	# original on disk is whatever copy_absolute managed to write before
	# failing. This is a best-effort path — the false return value tells the
	# caller the swap didn't complete; recovery beyond that requires a
	# backup we couldn't take.)
	DirAccess.remove_absolute(tmp_path)
	return false


static func _written_size_matches(path: String, content: String) -> bool:
	# `store_string` writes UTF-8 bytes with no BOM and no newline translation,
	# so the byte length on disk must match `to_utf8_buffer().size()` exactly.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var on_disk := f.get_length()
	f.close()
	return on_disk == content.to_utf8_buffer().size()
