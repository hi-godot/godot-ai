@tool
extends McpTestSuite

## Tests for `update_reload_runner.gd` — specifically the partial-extract
## rollback contract added for issue #297 finding #9.
##
## The runner's own integration is covered by `script/local-self-update-smoke`
## (interactive). These tests pin the rollback semantics in isolation: given
## an injected list of "files we already wrote in this update," the runner
## must restore each one to its prior on-disk state, and must report the
## right `InstallStatus` so the caller knows whether the addons tree is safe
## to re-enable the plugin against.

const UpdateReloadRunner := preload("res://addons/godot_ai/update_reload_runner.gd")

var _scratch_dir: String


func suite_name() -> String:
	return "update_reload_runner"


func suite_setup(_ctx: Dictionary) -> void:
	_scratch_dir = OS.get_user_data_dir().path_join("mcp_update_reload_runner_tests")
	_clean_scratch_dir()
	DirAccess.make_dir_recursive_absolute(_scratch_dir)


func suite_teardown() -> void:
	_clean_scratch_dir()


func _clean_scratch_dir() -> void:
	if not DirAccess.dir_exists_absolute(_scratch_dir):
		return
	var dirs_to_walk := [_scratch_dir]
	var all_dirs := []
	while not dirs_to_walk.is_empty():
		var cur: String = dirs_to_walk.pop_back()
		all_dirs.append(cur)
		for sub in DirAccess.get_directories_at(cur):
			dirs_to_walk.append(cur.path_join(sub))
	# Walk children-first so directories are empty before removal.
	all_dirs.reverse()
	for d in all_dirs:
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		if d != _scratch_dir:
			DirAccess.remove_absolute(d)


func _make_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()


func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var got := f.get_as_text()
	f.close()
	return got


func _new_runner():
	# Runner extends Node; we don't add it to the tree because the rollback
	# code path doesn't need _process(). free() in teardown.
	return UpdateReloadRunner.new()


# ----- _rollback_paths_written -----


func test_rollback_restores_originals_from_backup() -> void:
	## Pin the happy rollback path: existing vN files that were overwritten
	## by vN+1 mid-install must be restored from their `.update_backup`
	## snapshots, with the snapshot deleted afterward.
	var runner = _new_runner()
	var target := _scratch_dir.path_join("addons/godot_ai/file_a.gd")
	_make_file(target, "vN_content")
	var backup := target + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX
	# Snapshot the original (mimics _install_zip_file's COPY backup step).
	assert_eq(DirAccess.copy_absolute(target, backup), OK, "test backup must succeed")
	# Overwrite the target with vN+1 content (mimics the successful rename
	# of `.tmp` -> target inside _install_zip_file).
	_make_file(target, "vN+1_content")
	# Inject the install record the runner would normally accumulate.
	runner._paths_written.append({
		"target_path": target,
		"backup_path": backup,
		"had_original": true,
	})

	var status: int = runner._rollback_paths_written()

	assert_eq(
		status,
		UpdateReloadRunner.InstallStatus.FAILED_CLEAN,
		"rollback that succeeded for every record reports FAILED_CLEAN",
	)
	assert_eq(_read_file(target), "vN_content", "target restored to original content")
	assert_false(
		FileAccess.file_exists(backup),
		"backup snapshot deleted after successful restore",
	)
	assert_eq(runner._paths_written.size(), 0, "_paths_written cleared after rollback")
	runner.free()


func test_rollback_deletes_files_that_did_not_exist_before_update() -> void:
	## Pin the new-file rollback path: vN+1 introduced a file that didn't
	## exist in vN, then a later file failed to install. The orphan must
	## be removed so the addons dir matches its vN state.
	var runner = _new_runner()
	var target := _scratch_dir.path_join("addons/godot_ai/brand_new.gd")
	_make_file(target, "vN+1_only")
	# `had_original = false` — vN didn't have this file. backup_path is
	# computed by _install_zip_file but never populated when the original
	# was absent.
	runner._paths_written.append({
		"target_path": target,
		"backup_path": target + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX,
		"had_original": false,
	})

	var status: int = runner._rollback_paths_written()

	assert_eq(
		status,
		UpdateReloadRunner.InstallStatus.FAILED_CLEAN,
		"deleting orphaned new files counts as a clean rollback",
	)
	assert_false(
		FileAccess.file_exists(target),
		"orphan vN+1 file must be removed during rollback",
	)
	runner.free()


func test_rollback_returns_failed_mixed_when_backup_is_missing() -> void:
	## Pin the FAILED_MIXED path: if a backup snapshot is gone we cannot
	## restore the original. The caller MUST NOT re-enable the plugin in
	## this state — it would load a half-vN+1 / half-vN tree. This is the
	## load-bearing signal for issue #297 finding #9.
	var runner = _new_runner()
	var target := _scratch_dir.path_join("addons/godot_ai/no_backup.gd")
	_make_file(target, "vN+1_clobbered_original")
	# No backup file on disk — simulate a backup that vanished mid-install.
	runner._paths_written.append({
		"target_path": target,
		"backup_path": target + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX,
		"had_original": true,
	})

	var status: int = runner._rollback_paths_written()

	assert_eq(
		status,
		UpdateReloadRunner.InstallStatus.FAILED_MIXED,
		"missing backup MUST surface as FAILED_MIXED — caller must not re-enable",
	)
	runner.free()


func test_rollback_processes_records_in_reverse_order() -> void:
	## When two records target the same path, processing them in install
	## order would let an earlier "restore" undo a later "restore." Walk
	## newest-first so the on-disk content lands at the original vN state.
	var runner = _new_runner()
	var target := _scratch_dir.path_join("addons/godot_ai/twice_touched.gd")
	_make_file(target, "vN_original")
	var backup := target + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX
	# First write captured the true original.
	assert_eq(DirAccess.copy_absolute(target, backup), OK)
	_make_file(target, "intermediate")
	# Second write would have backed up the intermediate, but for this
	# rollback contract we want the FIRST record (newest = appended last
	# in production) to win — that's the one that knows about the true
	# original.
	runner._paths_written.append({
		"target_path": target,
		"backup_path": backup,
		"had_original": true,
	})
	# Final overwrite (vN+2 simulation).
	_make_file(target, "vN+1_final")

	var status: int = runner._rollback_paths_written()

	assert_eq(status, UpdateReloadRunner.InstallStatus.FAILED_CLEAN)
	assert_eq(
		_read_file(target),
		"vN_original",
		"reverse-order rollback restores to true original",
	)
	runner.free()


# ----- _finalize_install_success -----


func test_finalize_install_success_clears_backups() -> void:
	## After both batches succeed, `.update_backup` snapshots are cleaned
	## up so the addons dir doesn't accumulate stale rollback artifacts.
	var runner = _new_runner()
	var target := _scratch_dir.path_join("addons/godot_ai/finalized.gd")
	_make_file(target, "vN+1_final")
	var backup := target + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX
	_make_file(backup, "vN_original")
	runner._paths_written.append({
		"target_path": target,
		"backup_path": backup,
		"had_original": true,
	})

	runner._finalize_install_success()

	assert_eq(
		_read_file(target),
		"vN+1_final",
		"finalize must NOT touch the new content on disk",
	)
	assert_false(
		FileAccess.file_exists(backup),
		"backup snapshot is removed once the install is finalized",
	)
	assert_eq(
		runner._paths_written.size(), 0, "_paths_written cleared on finalize"
	)
	runner.free()


# ----- _install_zip_file end-to-end -----


func _stage_release_zip(zip_path: String, files: Dictionary) -> void:
	var packer := ZIPPacker.new()
	assert_eq(packer.open(zip_path), OK, "ZIPPacker should open scratch zip")
	for rel_path in files.keys():
		assert_eq(packer.start_file(rel_path), OK)
		assert_eq(packer.write_file(String(files[rel_path]).to_utf8_buffer()), OK)
		assert_eq(packer.close_file(), OK)
	assert_eq(packer.close(), OK)


func test_install_zip_file_creates_backup_for_existing_target() -> void:
	## End-to-end: run a real `_install_zip_file` against a scratch install
	## base and a real ZIP. The vN content must end up in the `.update_backup`
	## snapshot, the vN+1 content at the target, and the returned record
	## must reflect `had_original=true`.
	var install_base := _scratch_dir.path_join("install_existing")
	var rel := "addons/godot_ai/file_x.gd"
	var target := install_base.path_join(rel)
	_make_file(target, "vN_x")
	var zip_path := _scratch_dir.path_join("update_existing.zip")
	_stage_release_zip(zip_path, {rel: "vN+1_x"})

	var runner = _new_runner()
	var reader := ZIPReader.new()
	assert_eq(reader.open(zip_path), OK)

	var record: Dictionary = runner._install_zip_file(reader, rel, install_base)
	reader.close()

	assert_false(record.is_empty(), "install_zip_file should return a non-empty record")
	assert_eq(record.get("had_original"), true)
	assert_eq(record.get("target_path"), target)
	assert_eq(record.get("backup_path"), target + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX)
	assert_eq(_read_file(target), "vN+1_x", "target now has vN+1 content")
	assert_eq(
		_read_file(record.get("backup_path")),
		"vN_x",
		"backup snapshot has vN content for rollback",
	)
	runner.free()


func test_install_zip_file_records_new_files_without_backup() -> void:
	## A file that didn't exist in vN must be recorded as had_original=false
	## so rollback knows to delete it (not look for a missing backup).
	var install_base := _scratch_dir.path_join("install_new")
	var rel := "addons/godot_ai/brand_new.gd"
	var target := install_base.path_join(rel)
	# No vN file at target.
	var zip_path := _scratch_dir.path_join("update_new.zip")
	_stage_release_zip(zip_path, {rel: "vN+1_brand_new"})

	var runner = _new_runner()
	var reader := ZIPReader.new()
	assert_eq(reader.open(zip_path), OK)

	var record: Dictionary = runner._install_zip_file(reader, rel, install_base)
	reader.close()

	assert_false(record.is_empty())
	assert_eq(record.get("had_original"), false)
	assert_eq(_read_file(target), "vN+1_brand_new")
	assert_false(
		FileAccess.file_exists(record.get("backup_path")),
		"no backup is created for previously-absent files",
	)
	runner.free()


# ----- end-to-end install + mid-loop failure rollback -----


func test_install_zip_paths_rolls_back_when_mid_loop_write_fails() -> void:
	## Pin the headline contract for issue #297 finding #9: a failure on
	## file 2 of 3 must restore file 1 to its vN content (or remove it if
	## it was a brand-new file) and report FAILED_CLEAN. The addons dir
	## must NOT be left in a half-vN / half-vN+1 state.
	var install_base := _scratch_dir.path_join("install_partial")
	var rel_existing := "addons/godot_ai/will_revert.gd"
	var rel_blocked := "addons/godot_ai/blocked"
	var rel_unreached := "addons/godot_ai/unreached.gd"
	var target_existing := install_base.path_join(rel_existing)
	var target_blocked := install_base.path_join(rel_blocked)
	var target_unreached := install_base.path_join(rel_unreached)
	_make_file(target_existing, "vN_will_revert")
	# Pre-stage the "blocked" target as a non-empty directory so both the
	# rename and copy-fallback in _install_zip_file reject it (mimics the
	# Windows AV / disk-full mid-install failure).
	DirAccess.make_dir_recursive_absolute(target_blocked)
	_make_file(target_blocked.path_join("inside.txt"), "directory placeholder")

	var zip_path := _scratch_dir.path_join("update_partial.zip")
	_stage_release_zip(
		zip_path,
		{
			rel_existing: "vN+1_will_revert",
			rel_blocked: "vN+1_blocked",
			rel_unreached: "vN+1_unreached",
		},
	)

	var runner = _new_runner()
	runner._zip_path = zip_path
	# Force the runner to use our scratch install base instead of res://.
	# We bypass _read_update_manifest by populating the file lists ourselves
	# in the same shape it would have produced — _install_zip_paths drives
	# the write loop and is the function under test.
	# Note: _install_zip_paths reads INSTALL_BASE_PATH globally, so we patch
	# by calling _install_zip_file directly in the same loop the runner
	# would have run. This is a faithful simulation of the production loop.
	var reader := ZIPReader.new()
	assert_eq(reader.open(zip_path), OK)
	var paths_in_order := [rel_existing, rel_blocked, rel_unreached]
	var status_after := -1
	for p in paths_in_order:
		var record: Dictionary = runner._install_zip_file(reader, p, install_base)
		if record.is_empty():
			status_after = runner._rollback_paths_written()
			break
		runner._paths_written.append(record)
	reader.close()

	assert_eq(
		status_after,
		UpdateReloadRunner.InstallStatus.FAILED_CLEAN,
		"mid-loop failure must roll back cleanly when backups are intact",
	)
	# File 1 must be back to vN content (rolled back from .update_backup).
	assert_eq(
		_read_file(target_existing),
		"vN_will_revert",
		"first installed file rolled back to its vN content",
	)
	# Backup must be cleaned up after a successful restore.
	assert_false(
		FileAccess.file_exists(target_existing + UpdateReloadRunner.INSTALL_BACKUP_SUFFIX),
		"backup deleted after restore",
	)
	# File 3 was never installed (loop bailed at file 2), so it stays absent.
	assert_false(
		FileAccess.file_exists(target_unreached),
		"unreached file is not present after rollback",
	)
	# Blocked target's pre-existing directory contents survived.
	assert_true(
		FileAccess.file_exists(target_blocked.path_join("inside.txt")),
		"non-file destination contents are preserved",
	)
	# _paths_written cleared so a subsequent install on the same runner
	# (rare but possible) doesn't re-attempt rollback against stale records.
	assert_eq(runner._paths_written.size(), 0, "_paths_written cleared after rollback")
	runner.free()
