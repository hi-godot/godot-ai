@tool
extends Node

## Runs the self-update after the visible plugin has handed off control.
##
## This node is deliberately tiny and not parented under the EditorPlugin:
## it survives `set_plugin_enabled(false)`, extracts the downloaded release,
## waits for Godot's filesystem scan, then enables the plugin again. The old
## dock is detached before this runner starts, kept alive while deferred
## Callables drain, and freed only after the new plugin instance is loaded.

const PLUGIN_CFG_PATH := "res://addons/godot_ai/plugin.cfg"
const PRE_DISABLE_DRAIN_FRAMES := 8
const POST_DISABLE_DRAIN_FRAMES := 2
const POST_ENABLE_FREE_FRAMES := 8
const INSTALL_BASE_PATH := "res://"
const ZIP_ADDON_PREFIX := "addons/godot_ai/"
const TEMP_FILE_SUFFIX := ".godot_ai_update_tmp"
const INSTALL_BACKUP_SUFFIX := ".update_backup"

## Outcome of `_install_zip_paths`. `OK` means all listed files were replaced.
## `FAILED_CLEAN` means a write/rename failed mid-batch but every previously
## written file was rolled back to its vN content (or removed, if the file
## was new in vN+1). `FAILED_MIXED` means rollback itself failed: the addons
## tree contains a mix of vN and vN+1 files. The runner MUST NOT re-enable
## the plugin in the MIXED case — see issue #297 finding #9 for the data-loss
## scenario this guards against.
enum InstallStatus { OK, FAILED_CLEAN, FAILED_MIXED }

var _zip_path := ""
var _temp_dir := ""
var _detached_dock = null
var _started := false
var _next_step := ""
var _frames_remaining := 0
var _waiting_for_scan := false
var _scan_next_step := ""
## Watchdog for `_start_filesystem_scan`: if Godot's `filesystem_changed`
## signal never fires (slow disk, NFS, AV holding the just-extracted addon
## files open), the runner used to hang in `_waiting_for_scan = true`
## forever and the dock stayed disabled. After this timeout we disconnect
## the signal and proceed anyway — worst case the new files aren't visible
## on the first frame, but they get picked up on the next scan. See
## audit-v2 finding #9 (issue #353). Untyped to match the codebase's
## defensive pattern for state that survives `fs.scan()` during update.
const SCAN_WATCHDOG_SECS := 30.0
var _scan_watchdog_timer = null
## Sticky flag set by `_on_scan_watchdog_timeout`. Subsequent
## `_start_filesystem_scan` calls in the same update bypass connect+scan
## so a delayed `filesystem_changed` emission from the timed-out scan
## can't fire on a freshly-armed listener for the next scan and falsely
## settle it before that scan actually completed. See PR #381 review for
## the cross-scan race this guards against.
var _scan_timed_out := false
## Keep Array fields untyped: this runner survives fs.scan() during update,
## and typed Variant storage is part of the hot-reload crash class.
var _new_file_paths = []
var _existing_file_paths = []
## Per-file install records accumulated across batches so a failure in the
## second batch can roll back files already replaced in the first batch.
## Each entry is an untyped Dictionary with target_path / backup_path /
## had_original keys. Cleared by `_finalize_install_success` on full success
## and by `_rollback_paths_written` on failure.
var _paths_written = []
## Set true if `_install_zip_file`'s inner restore-from-backup couldn't
## complete (backup gone, copy failed). The failed file is NOT recorded in
## `_paths_written` because the function bails at that point — without this
## flag, `_rollback_paths_written` would walk only the prior records, all
## restore cleanly, and report FAILED_CLEAN even though the current target
## is missing or stale on disk. Surfaces FAILED_MIXED so the runner refuses
## to re-enable the plugin against a half-installed tree.
var _restore_failed := false


func start(zip_path: String, temp_dir: String, detached_dock) -> void:
	if _started:
		return
	_started = true
	_zip_path = zip_path
	_temp_dir = temp_dir
	_detached_dock = detached_dock
	_wait_frames(PRE_DISABLE_DRAIN_FRAMES, "_disable_old_plugin")


func _process(_delta: float) -> void:
	if _frames_remaining <= 0:
		set_process(false)
		return

	_frames_remaining -= 1
	if _frames_remaining <= 0:
		var step := _next_step
		_next_step = ""
		set_process(false)
		call(step)


func _wait_frames(frame_count: int, next_step: String) -> void:
	_next_step = next_step
	_frames_remaining = max(1, frame_count)
	set_process(true)


func _disable_old_plugin() -> void:
	## Disable before writing or scanning new scripts. This avoids both the
	## Dict/Array field-storage hot-reload crash (#245) and cached handler
	## constructor shape mismatches (#247) for plugin-owned instances.
	print("MCP | update runner disabling old plugin")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, false)
	_wait_frames(POST_DISABLE_DRAIN_FRAMES, "_extract_and_scan")


func _extract_and_scan() -> void:
	if not _read_update_manifest():
		EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
		_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")
		return

	var status := _install_zip_paths(_new_file_paths)
	if status != InstallStatus.OK:
		_handle_install_failure(status)
		return

	if _new_file_paths.is_empty():
		_install_existing_files_and_scan.call_deferred()
	else:
		## Register newly added class_name/base scripts while all old plugin
		## files are still intact. Updating plugin.gd or handler preloads
		## before this scan can make Godot parse a new dependency graph
		## before its new global classes exist.
		_start_filesystem_scan("_install_existing_files_and_scan")


func _start_filesystem_scan(next_step: String = "_enable_new_plugin") -> void:
	var fs := EditorInterface.get_resource_filesystem()
	var deferred_step := next_step if not next_step.is_empty() else "_enable_new_plugin"
	if fs == null:
		call_deferred(deferred_step)
		return

	## Bypass: a previous scan in this update already watchdog'd, so the
	## editor's filesystem is unresponsive. Re-arming a `filesystem_changed`
	## listener now would race with a delayed emission from the timed-out
	## scan: that single emission would fire whichever listener is currently
	## connected to the shared signal, falsely settling this scan before it
	## actually completed. Skip the wait; Godot's normal background scan
	## catches up after the plugin re-enables. See PR #381 review.
	if _scan_timed_out:
		push_warning(
			"MCP | skipping filesystem_changed wait after previous timeout (next_step=%s)"
			% deferred_step
		)
		call_deferred(deferred_step)
		return

	_waiting_for_scan = true
	_scan_next_step = deferred_step
	if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed, CONNECT_ONE_SHOT)
	_arm_scan_watchdog()
	fs.scan()


func _arm_scan_watchdog() -> void:
	if _scan_watchdog_timer == null:
		_scan_watchdog_timer = Timer.new()
		_scan_watchdog_timer.one_shot = true
		_scan_watchdog_timer.timeout.connect(_on_scan_watchdog_timeout)
		add_child(_scan_watchdog_timer)
	_scan_watchdog_timer.start(SCAN_WATCHDOG_SECS)


func _stop_scan_watchdog() -> void:
	if _scan_watchdog_timer != null:
		_scan_watchdog_timer.stop()


func _on_scan_watchdog_timeout() -> void:
	## Signal didn't fire within SCAN_WATCHDOG_SECS — most likely the
	## filesystem scan is blocked behind a slow disk / NFS / AV scanner
	## still reading the just-extracted addon files.
	## Set the sticky `_scan_timed_out` flag so any subsequent
	## `_start_filesystem_scan` in this update skips its connect+scan
	## (otherwise a delayed emission from this scan would falsely settle
	## the next scan's listener — see PR #381 review).
	## Disconnect the current listener too, so this scan's listener can't
	## double-call `_finish_scan_wait` if the signal arrives quickly after
	## the timeout fires. `_finish_scan_wait` is idempotent on
	## `_waiting_for_scan == false`.
	if not _waiting_for_scan:
		return
	push_warning(
		"MCP | filesystem_changed didn't fire within %ds; proceeding without scan confirmation"
		% int(SCAN_WATCHDOG_SECS)
	)
	_scan_timed_out = true
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)
	_finish_scan_wait()


func _read_update_manifest() -> bool:
	var zip_path := ProjectSettings.globalize_path(_zip_path)
	var install_base := ProjectSettings.globalize_path(INSTALL_BASE_PATH)

	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		print("MCP | update extract failed: could not open %s" % zip_path)
		return false

	_new_file_paths.clear()
	_existing_file_paths.clear()
	var has_plugin_cfg := false
	var has_plugin_script := false
	var files := reader.get_files()
	for file_path in files:
		if not file_path.begins_with(ZIP_ADDON_PREFIX):
			continue
		var rel_path := file_path.trim_prefix(ZIP_ADDON_PREFIX)
		## Many zip builders (`zip -r` without `-D`, AssetLib uploads, hand-
		## built archives) emit zero-byte directory entries like
		## `addons/godot_ai/`. Skip those before the safety check; the
		## empty-segment guard in `_is_safe_zip_addon_file` would otherwise
		## flag the bare prefix as unsafe and abort the extract. Current
		## release.yml passes `-D` to strip them, but installed runners must
		## still tolerate older or manually built zips.
		if rel_path.is_empty() or file_path.ends_with("/"):
			continue
		if not _is_safe_zip_addon_file(file_path):
			print("MCP | update extract failed: unsafe zip path %s" % file_path)
			reader.close()
			return false
		if rel_path == "plugin.cfg":
			has_plugin_cfg = true
		elif rel_path == "plugin.gd":
			has_plugin_script = true
		var target_path := install_base.path_join(file_path)
		if FileAccess.file_exists(target_path):
			_existing_file_paths.append(file_path)
		else:
			_new_file_paths.append(file_path)
	reader.close()
	if not has_plugin_cfg:
		print("MCP | update extract failed: zip is missing plugin.cfg")
		return false
	if not has_plugin_script:
		print("MCP | update extract failed: zip is missing plugin.gd")
		return false
	return true


func _install_existing_files_and_scan() -> void:
	var status := _install_zip_paths(_existing_file_paths)
	if status != InstallStatus.OK:
		_handle_install_failure(status)
		return

	_finalize_install_success()
	_cleanup_update_temp()
	_start_filesystem_scan("_enable_new_plugin")


func _handle_install_failure(status: int) -> void:
	if status == InstallStatus.FAILED_MIXED:
		## Half-installed addon tree on disk: re-enabling the plugin would
		## load a mix of vN and vN+1 files. Print a load-bearing diagnostic
		## and bail without re-enabling — user must restore manually. See
		## issue #297 finding #9 for the data-loss scenario.
		push_error(
			"MCP | self-update failed mid-install AND rollback could not"
			+ " restore the previous addons/godot_ai/ contents. The plugin"
			+ " is left disabled. Inspect addons/godot_ai/ for"
			+ " *.update_backup / *.godot_ai_update_tmp files and restore"
			+ " manually before re-enabling the plugin."
		)
		print(
			"MCP | self-update aborted: addons/godot_ai/ is in a mixed state;"
			+ " plugin left disabled (manual intervention required)."
		)
		_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")
		return
	## FAILED_CLEAN: rollback restored every previously-written file. Safe
	## to re-enable the previous plugin version.
	print("MCP | self-update rolled back; re-enabling previous plugin version")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
	_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")


func _is_safe_zip_addon_file(file_path: String) -> bool:
	if file_path.is_absolute_path() or file_path.contains("\\"):
		return false
	if not file_path.begins_with(ZIP_ADDON_PREFIX):
		return false
	var rel_path := file_path.trim_prefix(ZIP_ADDON_PREFIX)
	if rel_path.is_empty() or rel_path.ends_with("/"):
		return false
	for segment in rel_path.split("/", true):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


func _install_zip_paths(paths: Array) -> int:
	if paths.is_empty():
		return InstallStatus.OK

	var zip_path := ProjectSettings.globalize_path(_zip_path)
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		print("MCP | update extract failed: could not reopen %s" % zip_path)
		## Nothing in this batch was written, but a previous batch may have
		## left files on disk; roll those back too.
		return _rollback_paths_written()

	var install_base := ProjectSettings.globalize_path(INSTALL_BASE_PATH)
	for file_path in paths:
		var record := _install_zip_file(reader, String(file_path), install_base)
		if record.is_empty():
			reader.close()
			return _rollback_paths_written()
		_paths_written.append(record)
	reader.close()
	return InstallStatus.OK


func _install_zip_file(
	reader: ZIPReader, file_path: String, install_base: String
) -> Dictionary:
	var target_path := install_base.path_join(file_path)
	var dir := target_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		print("MCP | update extract failed: could not create %s" % dir)
		return {}

	var temp_path := target_path + TEMP_FILE_SUFFIX
	DirAccess.remove_absolute(temp_path)
	var content := reader.read_file(file_path)
	var f := FileAccess.open(temp_path, FileAccess.WRITE)
	if f == null:
		print("MCP | update extract failed: could not write %s (error %d)" % [
			temp_path,
			FileAccess.get_open_error(),
		])
		return {}
	f.store_buffer(content)
	var write_error := f.get_error()
	f.close()
	if write_error != OK:
		print("MCP | update extract failed: write error %d for %s" % [
			write_error,
			temp_path,
		])
		DirAccess.remove_absolute(temp_path)
		return {}

	## Back up the original via COPY (not rename) so the source of truth
	## stays in place if a later step fails. Rolled back via
	## `_rollback_paths_written` if a subsequent file in this batch — or a
	## later batch — can't be installed.
	var had_original := FileAccess.file_exists(target_path)
	var backup_path := target_path + INSTALL_BACKUP_SUFFIX
	if had_original:
		DirAccess.remove_absolute(backup_path)
		if DirAccess.copy_absolute(target_path, backup_path) != OK:
			DirAccess.remove_absolute(temp_path)
			print("MCP | update extract failed: could not back up %s" % target_path)
			return {}

	if DirAccess.rename_absolute(temp_path, target_path) != OK:
		## POSIX and APFS replace atomically. Some filesystems reject
		## rename-over-existing; keep a fallback so the update can still
		## proceed, but the common path never exposes a truncated target.
		DirAccess.remove_absolute(target_path)
		if DirAccess.rename_absolute(temp_path, target_path) != OK:
			DirAccess.remove_absolute(temp_path)
			## Target was removed above; restore from the COPY backup so the
			## addons dir is left in its vN state before we surface failure.
			## Only delete the backup if the restore copy actually succeeded
			## — if it didn't, target_path is missing, and `_restore_failed`
			## tells `_rollback_paths_written` to surface FAILED_MIXED so the
			## runner refuses to re-enable the plugin. Leaving the backup on
			## disk also gives the user a manual recovery path. Without this
			## guard the failed file isn't tracked anywhere (we return `{}`,
			## not appended to `_paths_written`) and the caller would
			## erroneously see FAILED_CLEAN.
			if had_original:
				if (
					FileAccess.file_exists(backup_path)
					and DirAccess.copy_absolute(backup_path, target_path) == OK
				):
					DirAccess.remove_absolute(backup_path)
				else:
					_restore_failed = true
			print("MCP | update extract failed: could not replace %s" % target_path)
			return {}
	return {
		"target_path": target_path,
		"backup_path": backup_path,
		"had_original": had_original,
	}


## Restore (or remove) every file already touched in this update. Safe to
## call after a partial install — entries are processed in reverse so a
## given target is restored before the next earlier write of the same path
## could resurrect a stale value. Returns FAILED_CLEAN if every entry was
## restored AND no in-flight `_install_zip_file` left a target stranded
## (`_restore_failed`); FAILED_MIXED otherwise. The caller MUST NOT
## re-enable the plugin in the MIXED case.
func _rollback_paths_written() -> int:
	var any_failed := false
	var i := _paths_written.size() - 1
	while i >= 0:
		var record = _paths_written[i]
		var target := String(record.get("target_path", ""))
		var backup := String(record.get("backup_path", ""))
		var had_original := bool(record.get("had_original", false))
		if had_original:
			if not FileAccess.file_exists(backup):
				print("MCP | update rollback failed: backup missing for %s" % target)
				any_failed = true
			else:
				DirAccess.remove_absolute(target)
				if DirAccess.copy_absolute(backup, target) != OK:
					print("MCP | update rollback failed: could not restore %s" % target)
					any_failed = true
				else:
					DirAccess.remove_absolute(backup)
		else:
			if FileAccess.file_exists(target):
				if DirAccess.remove_absolute(target) != OK:
					print(
						"MCP | update rollback failed: could not delete %s" % target
					)
					any_failed = true
		i -= 1
	_paths_written.clear()
	if any_failed or _restore_failed:
		return InstallStatus.FAILED_MIXED
	return InstallStatus.FAILED_CLEAN


## Discard accumulated backups after both install batches succeed. Backups
## are best-effort: a failure here doesn't compromise the new install, just
## leaves stray *.update_backup files for the user to clean up.
func _finalize_install_success() -> void:
	for record in _paths_written:
		if record.get("had_original", false):
			DirAccess.remove_absolute(String(record.get("backup_path", "")))
	_paths_written.clear()


func _cleanup_update_temp() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_zip_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_temp_dir))


func _on_filesystem_changed() -> void:
	_finish_scan_wait()


func _finish_scan_wait() -> void:
	if not _waiting_for_scan:
		return
	_waiting_for_scan = false
	_stop_scan_watchdog()
	var next_step := _scan_next_step
	_scan_next_step = ""
	set_process(false)
	if next_step.is_empty():
		next_step = "_enable_new_plugin"
	call_deferred(next_step)


func _enable_new_plugin() -> void:
	print("MCP | update runner enabling new plugin")
	EditorInterface.set_plugin_enabled(PLUGIN_CFG_PATH, true)
	_wait_frames(POST_ENABLE_FREE_FRAMES, "_cleanup_and_finish")


func _cleanup_and_finish() -> void:
	_cleanup_detached_dock()
	queue_free()


func _cleanup_detached_dock() -> void:
	if _detached_dock != null and is_instance_valid(_detached_dock):
		_detached_dock.queue_free()
	_detached_dock = null
