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

	# Decide the permission mode the final file (and its backup) must carry
	# BEFORE we replace anything. A rewrite must preserve the prior file's
	# mode: the Claude CLI creates ~/.claude.json as 0600 (it holds OAuth
	# creds + history), and a naive FileAccess write + DirAccess copy would
	# silently relax that to the umask default (0644) and leak it on shared
	# machines. A brand-new config defaults to owner-only 0600 since these
	# files routinely carry tokens. On platforms without POSIX permissions
	# (Windows) the get/set calls no-op and this logic is inert. See #297
	# finding TC-1.
	var had_original := FileAccess.file_exists(path)
	var target_mode := _resolve_target_mode(path, had_original)

	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	# Lock the temp inode down BEFORE writing any bytes. FileAccess.open creates
	# it at the umask default (often 0644); chmod'ing the still-empty file first
	# means the config contents are never on disk under a world-readable mode in
	# the create->chmod gap. rename preserves the inode mode, so the swapped-in
	# file lands correct and is never briefly world-readable under the target name.
	_apply_mode(tmp_path, target_mode)
	file.store_string(content)
	# Push Godot's internal buffer out to the OS before the rename. Godot
	# exposes no fsync, so the bytes aren't guaranteed durable on the physical
	# disk until the OS flushes its own cache — a power loss in that window can
	# still lose the data. But flush() ensures the rename can't be ordered ahead
	# of the write at the application layer, which is the failure this guards.
	file.flush()
	file.close()
	# Re-assert the mode on the closed inode. The pre-write chmod above closes
	# the world-readable window; this second apply is the authoritative one
	# (a chmod issued while the FileAccess handle is still open doesn't reliably
	# stick inside the editor) and guarantees the final mode before the rename,
	# which preserves it.
	_apply_mode(tmp_path, target_mode)

	# Best-effort: snapshot the prior file before we touch the target so we
	# can restore on a failed swap. The backup is also kept on success as a
	# one-shot rollback aid for the user — give it the same (preserved) mode
	# so a 0600 config's backup isn't itself a world-readable copy.
	#
	# copy_absolute creates the backup at the umask default and we can only
	# chmod it afterward, so there's a sub-millisecond window where the backup
	# carries default perms. Accepted: it duplicates bytes already sitting at
	# `path` (which the caller created 0600) inside the user's own config dir,
	# and Godot exposes no API to create the copy pre-chmod'd. Not worth
	# reimplementing copy by hand to shave that window.
	var backup_path := path + ".backup"
	var backup_made := false
	if had_original:
		DirAccess.remove_absolute(backup_path)
		if DirAccess.copy_absolute(path, backup_path) == OK:
			backup_made = true
			_apply_mode(backup_path, target_mode)

	if DirAccess.rename_absolute(tmp_path, path) == OK:
		return true

	# Rename-over-existing rejected (Windows + AV / lock timing, some SMB
	# shares). Use overwrite-copy as the recovery path: copy_absolute never
	# removes the original before writing the new bytes, so a failure here
	# leaves the user's prior config in place rather than nuking it.
	if DirAccess.copy_absolute(tmp_path, path) == OK and _written_size_matches(path, content):
		# copy_absolute creates the destination with the default mode, so
		# re-apply the preserved/owner-only mode after the copy lands.
		_apply_mode(path, target_mode)
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
		_apply_mode(path, target_mode)
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


static func _resolve_target_mode(path: String, had_original: bool) -> int:
	# Preserve the prior file's POSIX mode on a rewrite; default a brand-new
	# config (or any case we can't read a mode for) to owner read+write (0600).
	#
	# get_unix_permissions returns 0 both on Windows (no POSIX perms) and for a
	# genuine 0000 file. Treating 0 as "use the 0600 floor" is deliberate, not a
	# missed case: these are config files the plugin must read and write, 0000 is
	# unusable, and re-applying 0000 would lock the owner out next run. 0600 is
	# still owner-only so this never widens access. (A genuinely-0000 file can't
	# reach a rewrite through the config strategies anyway — their read-first
	# guard fails to open it and refuses the write before we get here.)
	if had_original:
		var existing := FileAccess.get_unix_permissions(path)
		if existing > 0:
			return existing
	return FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER


static func _apply_mode(path: String, mode: int) -> void:
	# Best-effort. set_unix_permissions returns ERR_UNAVAILABLE on platforms
	# without POSIX permissions (Windows); that's expected and ignored so the
	# write still works there. mode <= 0 should never happen (resolve always
	# returns >0) but is guarded so a future caller can't chmod a file to nothing.
	if mode <= 0:
		return
	var err := FileAccess.set_unix_permissions(path, mode)
	# Surface a real chmod failure (not the Windows no-op) so permission
	# hardening on a sensitive config doesn't fail completely silently.
	if err != OK and err != ERR_UNAVAILABLE:
		push_warning("MCP | could not set permissions on %s (error %d)" % [path, err])


static func _written_size_matches(path: String, content: String) -> bool:
	# `store_string` writes UTF-8 bytes with no BOM and no newline translation,
	# so the byte length on disk must match `to_utf8_buffer().size()` exactly.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var on_disk := f.get_length()
	f.close()
	return on_disk == content.to_utf8_buffer().size()
