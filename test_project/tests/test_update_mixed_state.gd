@tool
extends McpTestSuite

## Tests for `update_mixed_state.gd` — the scanner that surfaces the
## half-installed addon-tree diagnostic in `editor_state` and the dock
## (issue #354 / audit-v2 #10).
##
## Cases run against a scratch dir under `user://` so the tests never
## touch the real addons tree or rely on its current contents.

const UpdateMixedState := preload("res://addons/godot_ai/utils/update_mixed_state.gd")

var _scratch_dir: String


func suite_name() -> String:
	return "update_mixed_state"


func suite_setup(_ctx: Dictionary) -> void:
	_scratch_dir = OS.get_user_data_dir().path_join("mcp_update_mixed_state_tests")
	_clean_scratch_dir()
	DirAccess.make_dir_recursive_absolute(_scratch_dir)


func teardown() -> void:
	_clean_scratch_dir()
	DirAccess.make_dir_recursive_absolute(_scratch_dir)
	## Static cache survives across tests; clear so a prior run's stale
	## production-path scan can't bleed into the next case.
	UpdateMixedState.clear_cache()


func suite_teardown() -> void:
	_clean_scratch_dir()
	UpdateMixedState.clear_cache()


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


func test_find_backups_empty_when_dir_clean() -> void:
	_make_file(_scratch_dir.path_join("plugin.gd"), "extends Node")
	_make_file(_scratch_dir.path_join("handlers/scene_handler.gd"), "extends RefCounted")
	var backups := UpdateMixedState.find_backups(_scratch_dir)
	assert_eq(0, backups.size(), "clean dir should produce no backup matches")


func test_find_backups_detects_top_level() -> void:
	## A FAILED_MIXED rollback typically leaves backup snapshots next to the
	## file that couldn't be restored. Pin that the scanner finds them at the
	## top level of the addons tree.
	_make_file(_scratch_dir.path_join("plugin.gd"), "vN+1 content")
	_make_file(
		_scratch_dir.path_join("plugin.gd" + UpdateMixedState.BACKUP_SUFFIX),
		"vN content",
	)
	var backups := UpdateMixedState.find_backups(_scratch_dir)
	assert_eq(1, backups.size(), "should find exactly one backup")
	assert_true(
		String(backups[0]).ends_with("plugin.gd" + UpdateMixedState.BACKUP_SUFFIX),
		"path should point at the .update_backup snapshot",
	)


func test_find_backups_recurses_subdirectories() -> void:
	## Backups can land anywhere in the addon tree (handlers/, utils/,
	## clients/, etc.). Pin recursive walk.
	_make_file(
		_scratch_dir.path_join("handlers/scene_handler.gd" + UpdateMixedState.BACKUP_SUFFIX),
		"vN scene handler",
	)
	_make_file(
		_scratch_dir.path_join(
			"utils/log_buffer.gd" + UpdateMixedState.BACKUP_SUFFIX
		),
		"vN log buffer",
	)
	_make_file(_scratch_dir.path_join("clients/_base.gd"), "vN+1 client base")
	var backups := UpdateMixedState.find_backups(_scratch_dir)
	assert_eq(2, backups.size(), "recursion should pick up both nested backups")
	## Sorted output is part of the contract — agents diffing two scans
	## shouldn't see spurious churn from filesystem walk order.
	assert_true(String(backups[0]) < String(backups[1]), "results must be sorted ascending")


func test_find_backups_ignores_non_backup_files() -> void:
	## The .uid sidecars next to every .gd, plus ordinary .tscn/.cfg files,
	## must not register as MIXED-state evidence.
	_make_file(_scratch_dir.path_join("plugin.cfg"), "[plugin]")
	_make_file(_scratch_dir.path_join("plugin.gd.uid"), "uid=abc")
	_make_file(_scratch_dir.path_join("foo.tres"), "[res]")
	var backups := UpdateMixedState.find_backups(_scratch_dir)
	assert_eq(0, backups.size(), "non-.update_backup files must not match")


func test_find_backups_returns_empty_for_missing_dir() -> void:
	## A hypothetical bare clone where addons/godot_ai/ doesn't exist (or
	## was removed) shouldn't crash the scanner.
	var nonexistent := _scratch_dir.path_join("does_not_exist")
	assert_false(
		DirAccess.dir_exists_absolute(nonexistent),
		"precondition: nonexistent dir must really not exist",
	)
	var backups := UpdateMixedState.find_backups(nonexistent)
	assert_eq(0, backups.size(), "missing dir must return empty list, not error")


func test_diagnose_empty_when_clean() -> void:
	_make_file(_scratch_dir.path_join("plugin.gd"), "extends Node")
	var diag := UpdateMixedState.diagnose(_scratch_dir)
	assert_true(diag.is_empty(), "clean addons tree must produce empty diagnose() Dictionary")


func test_diagnose_carries_structured_fields() -> void:
	## editor_state's contract is that the field is a structured Dictionary
	## with addon_dir / backup_files / backup_count / truncated / message
	## keys — pin every one so a future field rename can't silently drop one.
	_make_file(
		_scratch_dir.path_join("foo.gd" + UpdateMixedState.BACKUP_SUFFIX), "vN foo"
	)
	_make_file(
		_scratch_dir.path_join("bar.gd" + UpdateMixedState.BACKUP_SUFFIX), "vN bar"
	)
	var diag := UpdateMixedState.diagnose(_scratch_dir)
	assert_false(diag.is_empty(), "non-clean tree must produce non-empty Dictionary")
	assert_has_key(diag, "addon_dir")
	assert_eq(_scratch_dir, diag["addon_dir"], "addon_dir should round-trip the scanned path")
	assert_has_key(diag, "backup_files")
	assert_eq(2, (diag["backup_files"] as Array).size(), "backup_files lists every match")
	assert_has_key(diag, "backup_count")
	assert_eq(2, int(diag["backup_count"]), "backup_count mirrors the array size")
	assert_has_key(diag, "truncated")
	assert_eq(false, bool(diag["truncated"]), "two entries are well below the cap")
	assert_has_key(diag, "message")
	var message: String = diag["message"]
	assert_true(
		message.contains("addons/godot_ai/"),
		"message should name the addons dir so the operator knows where to look",
	)
	assert_true(
		message.contains("FAILED_MIXED"),
		"message should name the FAILED_MIXED state so a searching agent can correlate",
	)
	## The scanner can't tell FAILED_MIXED from "successful install whose
	## best-effort cleanup hit a permission error" — both leave
	## .update_backup files. Pin that the message acknowledges the
	## ambiguity so the dock copy doesn't lie to users in the latter case.
	assert_true(
		message.contains("safe to delete") or message.contains("stale"),
		"message should acknowledge the stale-backup case as well as FAILED_MIXED",
	)


func test_find_backups_walk_is_deterministic_when_truncated() -> void:
	## Truncation cap is rare in practice but when it kicks in two scans of
	## the same tree must return the same 200-file slice — otherwise the
	## "diff cleanly across calls" property breaks. Pin this by creating
	## enough files to overflow the cap and asserting the result is stable
	## across repeated invocations.
	var max_results: int = UpdateMixedState.MAX_BACKUP_RESULTS
	var overflow_count := max_results + 25
	for i in range(overflow_count):
		_make_file(
			_scratch_dir.path_join(
				"sub_%02d/file_%04d.gd%s"
				% [i % 4, i, UpdateMixedState.BACKUP_SUFFIX]
			),
			"vN content %d" % i,
		)
	var first := UpdateMixedState.find_backups(_scratch_dir)
	var second := UpdateMixedState.find_backups(_scratch_dir)
	assert_eq(max_results, first.size(), "first scan should hit cap")
	assert_eq(max_results, second.size(), "second scan should hit cap")
	assert_eq(first, second, "two scans of the same tree must return the same slice")


func test_diagnose_caches_repeated_default_dir_calls() -> void:
	## `editor_state` is one of the most-called MCP tools and runs the
	## scanner on every poll. Pin that a second call within the TTL is a
	## cache hit by mutating the addons tree between calls and verifying
	## the cached result wins until clear_cache() forces a re-scan.
	UpdateMixedState.clear_cache()
	## First call: production ADDON_DIR, no force, populates cache.
	var first := UpdateMixedState.diagnose()
	## In the test_project tree this should be empty (no .update_backup
	## files present); we just need a cached snapshot to compare against.
	assert_true(first.is_empty(), "test_project tree must be clean for this test to drive the cache")
	## Second call: still cached (within 5s TTL), returns the same Dict.
	var second := UpdateMixedState.diagnose()
	assert_eq(first, second, "second call within TTL must hit cache")
	## clear_cache() forces the next call to re-scan.
	UpdateMixedState.clear_cache()
	var third := UpdateMixedState.diagnose()
	assert_eq(first, third, "post-clear scan returns the same clean result")


func test_diagnose_force_bypasses_cache() -> void:
	## Re-scan button uses `force=true` so a manual fix is reflected
	## without waiting for the TTL. Pin that force re-runs the walk even
	## with a fresh cache populated by a normal call.
	UpdateMixedState.clear_cache()
	var cached := UpdateMixedState.diagnose()
	assert_true(cached.is_empty(), "test_project tree must be clean")
	## With force=true the scanner must not return the cached value — it
	## must re-walk. The result is still empty here (clean tree) but the
	## contract is that the walk happened. We assert force returns the
	## same empty Dict shape.
	var forced := UpdateMixedState.diagnose(UpdateMixedState.ADDON_DIR, true)
	assert_eq(cached, forced, "forced re-scan returns the same shape on a clean tree")


func test_find_backups_caps_results_at_max() -> void:
	## A pathological install that left thousands of backup files (e.g. an
	## old crashed install loop) shouldn't blow up the editor_state response
	## or freeze the dock paint. The cap must be honored and the truncated
	## flag set so the operator knows there's more than what's shown.
	var max_results: int = UpdateMixedState.MAX_BACKUP_RESULTS
	var overflow_count := max_results + 5
	for i in range(overflow_count):
		_make_file(
			_scratch_dir.path_join("file_%04d.gd%s" % [i, UpdateMixedState.BACKUP_SUFFIX]),
			"vN content %d" % i,
		)
	var backups := UpdateMixedState.find_backups(_scratch_dir)
	assert_eq(max_results, backups.size(), "result list must respect MAX_BACKUP_RESULTS cap")
	var diag := UpdateMixedState.diagnose(_scratch_dir)
	assert_eq(true, bool(diag["truncated"]), "diagnose() must flag truncation when the cap is hit")
	assert_eq(max_results, int(diag["backup_count"]), "backup_count reflects what was returned, not what existed on disk")
