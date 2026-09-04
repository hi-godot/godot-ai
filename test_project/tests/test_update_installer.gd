@tool
extends McpTestSuite

## McpUpdateInstaller against a fake live root under the update directory.
## The real `res://addons/godot_ai` is never swapped: in a dev checkout it is
## a symlink into plugin/, and moving it would break the running editor.
## Fixture builders (key pair, manifest, stored-ZIP writer) come from
## test_release_verifier.gd.

const Fixtures := preload("res://tests/test_release_verifier.gd")

const TEST_DIR := "res://addons/.godot_ai_update/_test_installer"
const LIVE_ROOT := TEST_DIR + "/live"
const FROM_VERSION := "4.0.0"
const TO_VERSION := Fixtures.VERSION
const PREFIX := Fixtures.PREFIX
const DEAD_PID := 2000000000
const OLD_PLUGIN_GD := "@tool\nextends EditorPlugin\n# old\n"

var _entries := {}
var _zip_bytes := PackedByteArray()
var _zip_path := TEST_DIR + "/fixture.zip"
var _manifest := {}


func suite_name() -> String:
	return "update_installer"


func suite_setup(_ctx: Dictionary) -> void:
	_entries = Fixtures.fixture_entries()
	_zip_bytes = Fixtures.build_zip(_entries)
	_manifest = Fixtures.build_manifest(_entries, _zip_bytes)
	var rooted := McpUpdateInstaller.ensure_root()
	if not bool(rooted.ok):
		fail_setup("cannot create update root: %s" % str(rooted.error))
		return
	if not Fixtures.write_fixture(_zip_path, _zip_bytes):
		fail_setup("cannot write fixture zip")


func setup() -> void:
	_reset_update_state()
	_write_old_live_tree()


func teardown() -> void:
	_reset_update_state()


func suite_teardown() -> void:
	_reset_update_state()
	Fixtures.clean_fixture_dir(TEST_DIR)


# ----- helpers ----------------------------------------------------------


func _reset_update_state() -> void:
	for path in [
		McpUpdateInstaller.STAGE_DIR,
		McpUpdateInstaller.BACKUP_DIR,
		McpUpdateInstaller.QUARANTINE_DIR,
		LIVE_ROOT,
	]:
		Fixtures.clean_fixture_dir(path)
	McpUpdateInstaller.clear_pending()
	var lock := ProjectSettings.globalize_path(McpUpdateInstaller.LOCK_FILE)
	if FileAccess.file_exists(lock):
		DirAccess.remove_absolute(lock)


func _write_old_live_tree() -> void:
	Fixtures.write_tree(LIVE_ROOT, {
		"plugin.cfg": ('[plugin]\nname="Godot AI"\nversion="%s"\nscript="plugin.gd"\n' % FROM_VERSION).to_utf8_buffer(),
		"plugin.gd": OLD_PLUGIN_GD.to_utf8_buffer(),
		"utils/old_only.gd": "extends RefCounted\n".to_utf8_buffer(),
	})


func _exists(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	return DirAccess.dir_exists_absolute(absolute) or FileAccess.file_exists(absolute)


func _text(path: String) -> String:
	return Fixtures.read_fixture(path).get_string_from_utf8()


func _record(extra: Dictionary = {}, expected_tree_sha256: String = "") -> Dictionary:
	var record := {
		"from_version": FROM_VERSION,
		"to_version": TO_VERSION,
		"manifest_sha256": McpReleaseVerifier.sha256_bytes(Fixtures.canonical_bytes(_manifest)),
		"expected_tree_sha256": expected_tree_sha256,
		"editor_nonce": "nonce-1234",
		"replace_owned_mismatches": true,
	}
	for key in extra:
		record[key] = extra[key]
	return record


func _stage() -> Dictionary:
	var staged := McpUpdateInstaller.stage(_zip_path, _manifest)
	assert_true(bool(staged.ok), str(staged.error))
	return staged


## Stage and swap the fixture over the fake live root; returns the swap record.
func _stage_and_swap() -> Dictionary:
	var staged := _stage()
	var record := _record({}, str(staged.tree_sha256))
	var swapped := McpUpdateInstaller.swap(str(staged.stage_root), LIVE_ROOT, record)
	assert_true(bool(swapped.ok), str(swapped.error))
	return record


# ----- update root ------------------------------------------------------


func test_ensure_root_writes_ignore_markers() -> void:
	var rooted := McpUpdateInstaller.ensure_root()
	assert_true(bool(rooted.ok), str(rooted.error))
	assert_true(_exists(McpUpdateInstaller.UPDATE_ROOT + "/.gdignore"))
	assert_eq(_text(McpUpdateInstaller.UPDATE_ROOT + "/.gitignore"), "*\n")


func test_remove_under_update_root_refuses_outside_paths() -> void:
	var live := McpUpdateInstaller.remove_under_update_root("res://addons/godot_ai")
	assert_false(bool(live.ok), "the live plugin must never be removable")
	assert_contains(str(live.error), "outside")
	var root := McpUpdateInstaller.remove_under_update_root(McpUpdateInstaller.UPDATE_ROOT)
	assert_false(bool(root.ok), "the update root itself is not removable")
	var sibling := McpUpdateInstaller.remove_under_update_root("res://addons/.godot_ai_update_other")
	assert_false(bool(sibling.ok), "a sibling sharing the prefix is outside")
	var escaped := McpUpdateInstaller.remove_under_update_root(McpUpdateInstaller.UPDATE_ROOT + "/../godot_ai")
	assert_false(bool(escaped.ok), "dot-dot escapes are outside")
	assert_true(_exists("res://addons/godot_ai/plugin.cfg"), "live plugin untouched")


# ----- stage ------------------------------------------------------------


func test_stage_extracts_and_hashes_against_the_inventory() -> void:
	var staged := _stage()
	assert_eq(str(staged.stage_root), McpUpdateInstaller.STAGE_PLUGIN_ROOT)
	assert_eq(str(staged.tree_sha256), McpReleaseVerifier.inventory_tree_hash(_manifest))
	assert_eq(str(staged.error), "")
	assert_eq(_text(McpUpdateInstaller.STAGE_PLUGIN_ROOT + "/plugin.cfg"), _entries[PREFIX + "plugin.cfg"].get_string_from_utf8())
	assert_true(_exists(McpUpdateInstaller.STAGE_PLUGIN_ROOT + "/utils/helper.gd"))
	var rehashed := McpReleaseVerifier.hash_tree(str(staged.stage_root))
	assert_true(bool(rehashed.ok), str(rehashed.error))
	assert_eq(str(rehashed.tree_sha256), str(staged.tree_sha256))


func test_stage_replaces_a_previous_stage() -> void:
	_stage()
	assert_true(Fixtures.write_fixture(McpUpdateInstaller.STAGE_PLUGIN_ROOT + "/leftover.gd", "x".to_utf8_buffer()))
	var staged := _stage()
	assert_false(_exists(McpUpdateInstaller.STAGE_PLUGIN_ROOT + "/leftover.gd"), "a fresh stage carries no leftovers")
	assert_eq(str(staged.tree_sha256), McpReleaseVerifier.inventory_tree_hash(_manifest))


func test_stage_rejects_archive_content_that_differs_from_the_inventory() -> void:
	var entries := _entries.duplicate()
	entries[PREFIX + "plugin.gd"] = "@tool\nextends EditorPlugiX\n".to_utf8_buffer()
	var zip := Fixtures.build_zip(entries)
	var path := TEST_DIR + "/tampered.zip"
	assert_true(Fixtures.write_fixture(path, zip))
	var staged := McpUpdateInstaller.stage(path, Fixtures.build_manifest(_entries, zip))
	assert_false(bool(staged.ok), "a tampered entry must not stage")
	assert_contains(str(staged.error), "differs from the signed inventory hash")
	assert_false(_exists(McpUpdateInstaller.STAGE_DIR), "a failed stage is discarded")


func test_stage_rejects_entry_list_mismatch_and_bad_manifest() -> void:
	var entries := _entries.duplicate()
	entries[PREFIX + "zzz_extra.gd"] = "extra".to_utf8_buffer()
	var zip := Fixtures.build_zip(entries)
	var path := TEST_DIR + "/extra.zip"
	assert_true(Fixtures.write_fixture(path, zip))
	var extra := McpUpdateInstaller.stage(path, Fixtures.build_manifest(_entries, zip))
	assert_false(bool(extra.ok))
	assert_contains(str(extra.error), "entries do not match")
	var bad := McpUpdateInstaller.stage(_zip_path, {"inventory": []})
	assert_false(bool(bad.ok))
	assert_contains(str(bad.error), "exactly keys")
	var absent := McpUpdateInstaller.stage(TEST_DIR + "/absent.zip", _manifest)
	assert_false(bool(absent.ok))
	assert_contains(str(absent.error), "cannot open archive")


func test_tampered_staged_file_is_detected_by_hash_tree() -> void:
	var staged := _stage()
	assert_true(Fixtures.write_fixture(McpUpdateInstaller.STAGE_PLUGIN_ROOT + "/plugin.gd", "evil".to_utf8_buffer()))
	var rehashed := McpReleaseVerifier.hash_tree(str(staged.stage_root))
	assert_true(bool(rehashed.ok), str(rehashed.error))
	assert_ne(str(rehashed.tree_sha256), str(staged.tree_sha256), "a tampered staged file changes the tree hash")


func test_discard_stage_removes_only_the_stage() -> void:
	_stage()
	assert_true(_exists(McpUpdateInstaller.STAGE_DIR))
	McpUpdateInstaller.discard_stage()
	assert_false(_exists(McpUpdateInstaller.STAGE_DIR))
	McpUpdateInstaller.discard_stage()
	assert_false(_exists(McpUpdateInstaller.STAGE_DIR), "discarding twice is harmless")
	assert_true(_exists(LIVE_ROOT + "/plugin.gd"), "live tree untouched")


# ----- lock -------------------------------------------------------------


func test_acquire_lock_replaces_a_dead_process_lock() -> void:
	assert_true(Fixtures.write_fixture(
		McpUpdateInstaller.LOCK_FILE,
		JSON.stringify({"pid": DEAD_PID, "fingerprint": "ghost", "started_unix": 1}).to_utf8_buffer(),
	))
	assert_false(McpPortResolver.pid_alive(DEAD_PID), "the fixture pid must be dead")
	var acquired := McpUpdateInstaller.acquire_lock(OS.get_process_id(), "mine")
	assert_true(bool(acquired.ok), str(acquired.error))
	var lock := McpUpdateInstaller.read_lock()
	assert_eq(int(lock.get("pid", 0)), OS.get_process_id())
	assert_eq(str(lock.get("fingerprint", "")), "mine")
	assert_gt(int(lock.get("started_unix", 0)), 1)
	McpUpdateInstaller.release_lock()
	assert_false(_exists(McpUpdateInstaller.LOCK_FILE), "release drops our own lock")


func test_acquire_lock_refuses_a_live_lock_with_another_fingerprint() -> void:
	var pid := OS.get_process_id()
	var first := McpUpdateInstaller.acquire_lock(pid, "editor-a")
	assert_true(bool(first.ok), str(first.error))
	var foreign := McpUpdateInstaller.acquire_lock(pid, "editor-b")
	assert_false(bool(foreign.ok), "a live lock with a different fingerprint must refuse")
	assert_contains(str(foreign.error), "held by live process")
	assert_eq(str(McpUpdateInstaller.read_lock().get("fingerprint", "")), "editor-a", "the refused caller did not overwrite it")
	var own := McpUpdateInstaller.acquire_lock(pid, "editor-a")
	assert_true(bool(own.ok), "our own lock is re-taken: %s" % str(own.error))
	var invalid := McpUpdateInstaller.acquire_lock(0, "editor-a")
	assert_false(bool(invalid.ok))
	assert_contains(str(invalid.error), "positive pid")


func test_release_lock_leaves_a_foreign_live_lock() -> void:
	if OS.get_name() == "Windows":
		skip("pid 1 is the POSIX init process")
		return
	assert_true(McpPortResolver.pid_alive(1), "pid 1 is alive on POSIX")
	assert_true(Fixtures.write_fixture(
		McpUpdateInstaller.LOCK_FILE,
		JSON.stringify({"pid": 1, "fingerprint": "init", "started_unix": 1}).to_utf8_buffer(),
	))
	McpUpdateInstaller.release_lock()
	assert_true(_exists(McpUpdateInstaller.LOCK_FILE), "another live process's lock is not ours to drop")
	var refused := McpUpdateInstaller.acquire_lock(OS.get_process_id(), "mine")
	assert_false(bool(refused.ok))
	assert_contains(str(refused.error), "held by live process 1")


# ----- swap -------------------------------------------------------------


func test_swap_moves_trees_and_writes_the_marker_verbatim() -> void:
	var record := _stage_and_swap()
	var backup := McpUpdateInstaller.BACKUP_DIR + "/" + FROM_VERSION
	assert_eq(_text(backup + "/plugin.gd"), OLD_PLUGIN_GD, "old tree retained as backup")
	assert_true(_exists(backup + "/utils/old_only.gd"))
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), _entries[PREFIX + "plugin.gd"].get_string_from_utf8(), "new tree is live")
	assert_true(_exists(LIVE_ROOT + "/utils/helper.gd"))
	assert_false(_exists(LIVE_ROOT + "/utils/old_only.gd"), "no file-by-file overlay")
	assert_false(_exists(McpUpdateInstaller.STAGE_PLUGIN_ROOT), "stage moved into place")
	var marker := McpUpdateInstaller.read_pending()
	assert_eq(str(marker.get("status", "")), "swapped")
	assert_eq(str(marker.get("backup_root", "")), backup)
	assert_eq(str(marker.get("live_root", "")), LIVE_ROOT)
	for key in record:
		assert_eq(marker.get(key), record[key], "record key %s preserved verbatim" % key)
	assert_eq(marker.get("replace_owned_mismatches"), true)
	assert_gt(int(marker.get("swapped_unix", 0)), 0)


func test_swap_refuses_an_existing_backup() -> void:
	var staged := _stage()
	var backup := McpUpdateInstaller.BACKUP_DIR + "/" + FROM_VERSION
	assert_true(Fixtures.write_fixture(backup + "/plugin.gd", "earlier backup".to_utf8_buffer()))
	var swapped := McpUpdateInstaller.swap(str(staged.stage_root), LIVE_ROOT, _record({}, str(staged.tree_sha256)))
	assert_false(bool(swapped.ok), "a leftover backup means an unresolved earlier update")
	assert_contains(str(swapped.error), "backup already exists")
	assert_eq(_text(backup + "/plugin.gd"), "earlier backup", "the earlier backup is never overwritten")
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), OLD_PLUGIN_GD, "live untouched")
	assert_true(_exists(McpUpdateInstaller.STAGE_PLUGIN_ROOT + "/plugin.gd"), "stage untouched")
	assert_true(McpUpdateInstaller.read_pending().is_empty(), "no marker written")


func test_swap_validates_the_record_and_roots_before_touching_anything() -> void:
	var staged := _stage()
	var hash := str(staged.tree_sha256)
	var missing := _record({}, hash)
	missing.erase("editor_nonce")
	var no_nonce := McpUpdateInstaller.swap(str(staged.stage_root), LIVE_ROOT, missing)
	assert_false(bool(no_nonce.ok))
	assert_contains(str(no_nonce.error), "missing editor_nonce")
	var bad_hash := McpUpdateInstaller.swap(str(staged.stage_root), LIVE_ROOT, _record({}, "nope"))
	assert_false(bool(bad_hash.ok))
	assert_contains(str(bad_hash.error), "expected_tree_sha256")
	var traversal := McpUpdateInstaller.swap(str(staged.stage_root), LIVE_ROOT, _record({"from_version": "../x"}, hash))
	assert_false(bool(traversal.ok))
	assert_contains(str(traversal.error), "path segments")
	var no_live := McpUpdateInstaller.swap(str(staged.stage_root), TEST_DIR + "/absent", _record({}, hash))
	assert_false(bool(no_live.ok))
	assert_contains(str(no_live.error), "live root does not exist")
	var no_stage := McpUpdateInstaller.swap(TEST_DIR + "/absent", LIVE_ROOT, _record({}, hash))
	assert_false(bool(no_stage.ok))
	assert_contains(str(no_stage.error), "stage root does not exist")
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), OLD_PLUGIN_GD, "live untouched")
	assert_false(_exists(McpUpdateInstaller.BACKUP_DIR + "/" + FROM_VERSION), "no backup created")
	assert_true(McpUpdateInstaller.read_pending().is_empty())


func test_swap_refuses_while_an_earlier_swap_is_pending() -> void:
	var staged := _stage()
	assert_true(Fixtures.write_fixture(
		McpUpdateInstaller.PENDING_FILE,
		JSON.stringify({"status": "swapped", "from_version": "3.9.9", "to_version": FROM_VERSION}).to_utf8_buffer(),
	))
	var swapped := McpUpdateInstaller.swap(str(staged.stage_root), LIVE_ROOT, _record({}, str(staged.tree_sha256)))
	assert_false(bool(swapped.ok))
	assert_contains(str(swapped.error), "pending verification")
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), OLD_PLUGIN_GD, "live untouched")


# ----- verify after restart ---------------------------------------------


func test_verify_after_restart_success_keeps_backup_until_pruned() -> void:
	var record := _stage_and_swap()
	var settled := McpUpdateInstaller.verify_after_restart(LIVE_ROOT)
	assert_eq(str(settled.get("status", "")), "success")
	assert_eq(str(settled.get("from_version", "")), FROM_VERSION)
	assert_eq(str(settled.get("to_version", "")), TO_VERSION)
	assert_eq(str(settled.get("error", "x")), "")
	assert_eq(settled.get("replace_owned_mismatches"), true, "extra record keys survive")
	assert_eq(str(settled.get("editor_nonce", "")), str(record["editor_nonce"]))
	assert_eq(str(McpUpdateInstaller.read_pending().get("status", "")), "success", "marker rewritten on disk")
	var backup := McpUpdateInstaller.BACKUP_DIR + "/" + FROM_VERSION
	assert_true(_exists(backup + "/plugin.gd"), "success never deletes the backup")
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), _entries[PREFIX + "plugin.gd"].get_string_from_utf8())
	McpUpdateInstaller.prune_backups(FROM_VERSION)
	assert_true(_exists(backup + "/plugin.gd"), "the kept version survives pruning")
	assert_true(Fixtures.write_fixture(McpUpdateInstaller.BACKUP_DIR + "/3.9.9/plugin.gd", "older".to_utf8_buffer()))
	McpUpdateInstaller.prune_backups(FROM_VERSION)
	assert_false(_exists(McpUpdateInstaller.BACKUP_DIR + "/3.9.9"), "other versions are pruned")
	assert_true(_exists(backup + "/plugin.gd"))
	McpUpdateInstaller.clear_pending()
	assert_true(McpUpdateInstaller.read_pending().is_empty())


func test_verify_after_restart_rolls_back_a_tampered_live_tree() -> void:
	_stage_and_swap()
	assert_true(Fixtures.write_fixture(LIVE_ROOT + "/plugin.gd", "tampered after swap".to_utf8_buffer()))
	var settled := McpUpdateInstaller.verify_after_restart(LIVE_ROOT)
	assert_eq(str(settled.get("status", "")), "rolled_back")
	assert_contains(str(settled.get("error", "")), "does not match")
	assert_eq(str(settled.get("from_version", "")), FROM_VERSION)
	assert_eq(str(settled.get("to_version", "")), TO_VERSION)
	assert_eq(settled.get("replace_owned_mismatches"), true)
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), OLD_PLUGIN_GD, "backup restored into place")
	assert_true(_exists(LIVE_ROOT + "/utils/old_only.gd"))
	var quarantine := McpUpdateInstaller.QUARANTINE_DIR + "/" + TO_VERSION
	assert_eq(str(settled.get("quarantine_root", "")), quarantine)
	assert_eq(_text(quarantine + "/plugin.gd"), "tampered after swap", "mismatching tree kept for inspection")
	assert_true(_exists(quarantine + "/utils/helper.gd"))
	assert_false(_exists(McpUpdateInstaller.BACKUP_DIR + "/" + FROM_VERSION), "backup was moved, not copied")
	assert_eq(str(McpUpdateInstaller.read_pending().get("status", "")), "rolled_back")


func test_verify_after_restart_requires_repair_when_backup_is_missing() -> void:
	_stage_and_swap()
	var backup := McpUpdateInstaller.BACKUP_DIR + "/" + FROM_VERSION
	var removed := McpUpdateInstaller.remove_under_update_root(backup)
	assert_true(bool(removed.ok), str(removed.error))
	assert_true(Fixtures.write_fixture(LIVE_ROOT + "/plugin.gd", "tampered, no backup".to_utf8_buffer()))
	var settled := McpUpdateInstaller.verify_after_restart(LIVE_ROOT)
	assert_eq(str(settled.get("status", "")), "repair_required")
	var error := str(settled.get("error", ""))
	assert_contains(error, ProjectSettings.globalize_path(backup))
	assert_contains(error, ProjectSettings.globalize_path(LIVE_ROOT))
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), "tampered, no backup", "live tree left untouched")
	assert_false(_exists(McpUpdateInstaller.QUARANTINE_DIR), "nothing quarantined without a backup to restore")
	assert_eq(str(McpUpdateInstaller.read_pending().get("status", "")), "repair_required")


func test_verify_after_restart_returns_a_settled_marker_unchanged() -> void:
	var marker := {"status": "success", "from_version": "4.0.0", "to_version": "4.0.1", "custom": "kept"}
	assert_true(Fixtures.write_fixture(McpUpdateInstaller.PENDING_FILE, JSON.stringify(marker).to_utf8_buffer()))
	var before := Fixtures.read_fixture(McpUpdateInstaller.PENDING_FILE)
	var settled := McpUpdateInstaller.verify_after_restart(LIVE_ROOT)
	assert_eq(settled, marker)
	assert_eq(Fixtures.read_fixture(McpUpdateInstaller.PENDING_FILE), before, "a settled marker is not rewritten")
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), OLD_PLUGIN_GD, "nothing on disk moves")
	assert_true(McpUpdateInstaller.verify_after_restart(TEST_DIR + "/absent").has("status"), "any non-swapped status is returned as-is")


func test_verify_after_restart_with_nothing_pending() -> void:
	assert_true(McpUpdateInstaller.read_pending().is_empty())
	assert_true(McpUpdateInstaller.verify_after_restart(LIVE_ROOT).is_empty())
	assert_eq(_text(LIVE_ROOT + "/plugin.gd"), OLD_PLUGIN_GD)


func test_read_pending_reports_a_corrupt_marker_as_repair_required() -> void:
	assert_true(Fixtures.write_fixture(McpUpdateInstaller.PENDING_FILE, "not json".to_utf8_buffer()))
	var marker := McpUpdateInstaller.read_pending()
	assert_eq(str(marker.get("status", "")), "repair_required")
	assert_contains(str(marker.get("error", "")), "pending.json")
	assert_eq(McpUpdateInstaller.verify_after_restart(LIVE_ROOT), marker, "not acted on")
	McpUpdateInstaller.clear_pending()
	assert_true(McpUpdateInstaller.read_pending().is_empty())


# ----- restart ----------------------------------------------------------


func test_persist_next_start_enabled_keeps_the_live_plugin_enabled_once() -> void:
	## Uses the real plugin.cfg (already enabled) so the saved project.godot
	## does not gain a phantom add-on; the assertion is idempotence.
	var cfg := "res://addons/godot_ai/plugin.cfg"
	assert_eq(McpUpdateInstaller.persist_next_start_enabled(cfg), OK)
	var enabled: Variant = ProjectSettings.get_setting(McpUpdateInstaller.ENABLED_PLUGINS_SETTING)
	assert_true(enabled is PackedStringArray, "setting keeps its PackedStringArray type")
	assert_eq((enabled as PackedStringArray).count(cfg), 1)
	assert_eq(McpUpdateInstaller.persist_next_start_enabled(""), ERR_INVALID_PARAMETER)
