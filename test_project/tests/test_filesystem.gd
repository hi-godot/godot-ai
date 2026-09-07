@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const FilesystemHandler := preload("res://addons/godot_ai/handlers/filesystem_handler.gd")

## Tests for FilesystemHandler — file read/write and reimport.

var _handler: FilesystemHandler

const TEST_FILE_PATH := "res://tests/_mcp_test_file.txt"
const TEST_FILE_CONTENT := "Hello from MCP test\nLine 2\nLine 3\n"

## #778 fixture: a file that looks imported to the editor. `.dat` has no
## importer, so the sidecar stays inert (no import runs, no import error is
## logged) while still exercising the sidecar-based classification.
const IMPORTED_ASSET_PATH := "res://tests/_mcp_test_imported.dat"

## Scratch script specimen for the mixed-batch reimport test. Written and
## removed by the test itself; listed in teardown as a safety net for an
## aborted run.
const SCRATCH_SCRIPT_PATH := "res://tests/_mcp_test_scratch_script.gd"


func suite_name() -> String:
	return "filesystem"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = FilesystemHandler.new()
	# Create a test file for read tests
	var file := FileAccess.open(TEST_FILE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(TEST_FILE_CONTENT)
		file.close()
	# Imported-asset fixture: source + its `.import` sidecar (#778).
	for path in [IMPORTED_ASSET_PATH, IMPORTED_ASSET_PATH + ".import"]:
		var asset := FileAccess.open(path, FileAccess.WRITE)
		if asset:
			asset.store_string("[remap]\n")
			asset.close()


func suite_teardown() -> void:
	# Clean up test files
	if FileAccess.file_exists(TEST_FILE_PATH):
		DirAccess.remove_absolute(TEST_FILE_PATH)
	var written_path := "res://tests/_mcp_test_written.txt"
	if FileAccess.file_exists(written_path):
		DirAccess.remove_absolute(written_path)
	for path in [IMPORTED_ASSET_PATH, IMPORTED_ASSET_PATH + ".import", SCRATCH_SCRIPT_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_fs_cleanup_move_fixtures()
	_fs_cleanup_dir_fixtures()


# ----- read_file -----

func test_read_file_basic() -> void:
	var result := _handler.read_file({"path": TEST_FILE_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.path, TEST_FILE_PATH)
	assert_eq(result.data.content, TEST_FILE_CONTENT)
	assert_gt(result.data.size, 0, "Size should be positive")
	assert_eq(result.data.line_count, 4, "Should have 4 lines (3 + trailing newline)")


func test_read_file_missing_path() -> void:
	var result := _handler.read_file({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_read_file_invalid_prefix() -> void:
	var result := _handler.read_file({"path": "/tmp/bad.txt"})
	assert_is_error(result)


func test_read_file_not_found() -> void:
	var result := _handler.read_file({"path": "res://nonexistent_file.txt"})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


func test_read_file_rejects_traversal_path() -> void:
	## Issue #347: traversal in read_file is the file-disclosure primitive.
	var result := _handler.read_file({"path": "res://../etc/passwd"})
	assert_is_error(result)
	assert_contains(result.error.message, "..")


# ----- write_file -----

func test_write_file_basic() -> void:
	var path := "res://tests/_mcp_test_written.txt"
	# Make sure no stale copy is on disk so this call is a fresh create.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var content := "Written by MCP\nSecond line\n"
	var result := _handler.write_file({"path": path, "content": content})
	assert_has_key(result, "data")
	assert_eq(result.data.path, path)
	assert_eq(result.data.size, content.length())
	assert_false(result.data.undoable, "File write should not be undoable")
	# Verify file was actually written
	assert_true(FileAccess.file_exists(path), "File should exist")
	var file := FileAccess.open(path, FileAccess.READ)
	assert_eq(file.get_as_text(), content)
	file.close()
	# Cleanup hint lists the freshly-written path (issue #82).
	assert_has_key(result.data, "cleanup")
	assert_eq(result.data.cleanup.rm, [path])


func test_write_file_gd_attaches_parse_diagnostics() -> void:
	## #714: a .gd written through the filesystem tool gets the same parse
	## diagnostics create_script attaches — a broken script must not
	## report plain success.
	var path := "res://tests/_mcp_test_written_broken.gd"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	## Same allowance count as test_script's _expect_invalid_if_parse_errors:
	## the validation reload + capture load each emit the parse error, and
	## Godot 4.7 adds one more logger-visible copy.
	expect_script_error_containing("Expected parameter name")
	expect_script_error_containing("Expected parameter name")
	expect_script_error_containing("Expected parameter name")
	var result := _handler.write_file({"path": path, "content": "func broken(:\n\tpass\n"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "diagnostics")
	assert_gt(result.data.diagnostics.size(), 0, "broken .gd must surface at least one diagnostic")
	assert_eq(result.data.diagnostics_scope, "this_file")
	DirAccess.remove_absolute(path)
	## Tell the editor filesystem the broken file is gone — leaving the
	## record behind makes later scans re-emit its parse error into other
	## suites' capture windows.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)


func test_write_file_gd_clean_script_reports_empty_diagnostics() -> void:
	var path := "res://tests/_mcp_test_written_clean.gd"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var result := _handler.write_file({"path": path, "content": "extends Node\n"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "diagnostics")
	assert_eq(result.data.diagnostics.size(), 0, "clean .gd must report zero diagnostics")
	DirAccess.remove_absolute(path)


func test_write_file_non_gd_has_no_diagnostics_field() -> void:
	var path := "res://tests/_mcp_test_written_plain.txt"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var result := _handler.write_file({"path": path, "content": "hello"})
	assert_has_key(result, "data")
	assert_false(result.data.has("diagnostics"), "non-.gd writes should stay diagnostics-free")
	DirAccess.remove_absolute(path)


func test_write_file_fresh_gd_reports_import_settle_fields() -> void:
	## #714: fresh .gd writes share create_script's import-settle contract.
	## In this unit context (no connection) the sync fallback replies
	## immediately with the not_waited marker; production defers until
	## ResourceLoader sees the resource (see McpResourceIO).
	var path := "res://tests/_mcp_test_written_settle.gd"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var result := _handler.write_file({"path": path, "content": "extends Node\n"})
	assert_has_key(result, "data")
	assert_eq(result.data.committed, true)
	assert_eq(result.data.import_settled, false)
	assert_eq(result.data.import_settle, "not_waited")
	DirAccess.remove_absolute(path)


func test_write_file_overwrite_gd_reports_already_known() -> void:
	## Overwrites reply synchronously — ResourceLoader already knows the
	## resource, so there is no import to wait for (#714).
	var path := "res://tests/_mcp_test_written_settle_overwrite.gd"
	var first := _handler.write_file({"path": path, "content": "extends Node\n"})
	assert_has_key(first, "data")
	var second := _handler.write_file({"path": path, "content": "extends Node\n# v2\n"})
	assert_has_key(second, "data")
	assert_eq(second.data.import_settled, true)
	assert_eq(second.data.import_settle, "already_known")
	DirAccess.remove_absolute(path)


func test_write_file_non_gd_has_no_import_settle_fields() -> void:
	## ResourceLoader never learns plain text files — claiming settle
	## semantics for them would be a lie, and deferring would burn the full
	## settle window on every fresh .txt (#714).
	var path := "res://tests/_mcp_test_written_plain_settle.txt"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var result := _handler.write_file({"path": path, "content": "hello"})
	assert_has_key(result, "data")
	assert_false(result.data.has("import_settle"), "non-.gd writes carry no settle contract")
	assert_false(result.data.has("import_settled"), "non-.gd writes carry no settle contract")
	assert_false(result.data.has("committed"), "committed is part of the .gd settle contract")
	DirAccess.remove_absolute(path)


func test_write_file_overwrite_omits_cleanup_hint() -> void:
	## Second write to the same path is an overwrite; dropping a cleanup hint
	## on overwrite would invite callers to rm files they already had.
	var path := "res://tests/_mcp_test_overwrite.txt"
	var first := _handler.write_file({"path": path, "content": "v1\n"})
	assert_has_key(first, "data")
	assert_has_key(first.data, "cleanup")
	var second := _handler.write_file({"path": path, "content": "v2\n"})
	assert_has_key(second, "data")
	assert_false(second.data.has("cleanup"), "Overwrite must not emit a cleanup hint")
	DirAccess.remove_absolute(path)


func test_write_file_missing_path() -> void:
	var result := _handler.write_file({"content": "hello"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_write_file_invalid_prefix() -> void:
	var result := _handler.write_file({"path": "/tmp/bad.txt", "content": "hello"})
	assert_is_error(result)


func test_write_file_rejects_traversal_path() -> void:
	## Issue #347: the actual arbitrary-disk-write primitive.
	## Use a synthetic target so a Unix host's pre-existing /etc/* doesn't
	## false-positive the disk-state assertion below. If a regression let
	## the write through, the file would land one dir above the project at
	## `<project_parent>/__mcp_traversal_test_target__`, which never
	## exists in a clean tree.
	var traversal_path := "res://../__mcp_traversal_test_target__.txt"
	var result := _handler.write_file({
		"path": traversal_path,
		"content": "owned\n",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "..")
	assert_false(FileAccess.file_exists(traversal_path), "traversal must not write to disk")


# ----- reimport -----

func test_reimport_missing_paths() -> void:
	var result := _handler.reimport({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_reimport_empty_paths() -> void:
	var result := _handler.reimport({"paths": []})
	assert_is_error(result)


func test_reimport_nonexistent_file() -> void:
	var result := _handler.reimport({"paths": ["res://nonexistent.png"]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.not_found_count, 1)
	# not_found entries now include reason suffix, so check the first entry contains the path
	assert_contains(result.data.not_found[0], "res://nonexistent.png")


func test_reimport_existing_file() -> void:
	## #778: a .txt is not an imported resource — it has no `.import` sidecar,
	## so it reports as refreshed-not-reimported rather than padding
	## `reimported` with a path no importer ever touched.
	var result := _handler.reimport({"paths": [TEST_FILE_PATH]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.skipped_non_imported_count, 1)
	assert_contains(result.data.skipped_non_imported, TEST_FILE_PATH)


func test_reimport_imported_asset_is_reported_as_reimported() -> void:
	## The `.import` sidecar is the signal, not the extension (#778).
	var result := _handler.reimport({"paths": [IMPORTED_ASSET_PATH]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 1)
	assert_contains(result.data.reimported, IMPORTED_ASSET_PATH)
	assert_eq(result.data.skipped_non_imported_count, 0)
	assert_false(
		result.data.has("skipped_non_imported_hint"),
		"an all-imported batch must not pay for the hint"
	)


func test_reimport_mixed_batch_splits_the_report() -> void:
	## The case #778 is about: one imported asset, one script, one missing
	## path in a single call. Each lands in its own bucket, and the script
	## never counts as reimported.
	##
	## The script specimen is a scratch fixture, never a live plugin script:
	## reimport() runs `efs.update_file()` on each path, and pointing that at
	## the handler's own script hot-reloads code that is on the call stack —
	## "Bad address index" script errors in a GUI editor, then a signal-11
	## editor crash on repeated runs (the #229-class reload race; found
	## during the #838 Windows verification).
	var script_path := SCRATCH_SCRIPT_PATH
	var scratch := FileAccess.open(script_path, FileAccess.WRITE)
	assert_true(scratch != null, "scratch script fixture must be writable")
	scratch.store_string("extends RefCounted\n## reimport specimen; never loaded by anything\n")
	scratch.close()
	var result := _handler.reimport({
		"paths": [IMPORTED_ASSET_PATH, script_path, "res://nonexistent.png"],
	})
	DirAccess.remove_absolute(script_path)
	assert_has_key(result, "data")
	assert_eq(result.data.reimported, [IMPORTED_ASSET_PATH])
	assert_eq(result.data.skipped_non_imported, [script_path])
	assert_eq(result.data.reimported_count, 1)
	assert_eq(result.data.skipped_non_imported_count, 1)
	assert_eq(result.data.not_found_count, 1)
	assert_contains(result.data.not_found[0], "res://nonexistent.png")
	assert_true(
		result.data.has("skipped_non_imported_hint"),
		"a batch carrying non-imported paths must say so"
	)


func test_reimport_sidecar_path_is_not_an_imported_resource() -> void:
	## `foo.png.import` is the record, not the resource — passing it must not
	## report an import that never ran.
	var result := _handler.reimport({"paths": [IMPORTED_ASSET_PATH + ".import"]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.skipped_non_imported, [IMPORTED_ASSET_PATH + ".import"])


func test_reimport_invalid_prefix() -> void:
	var result := _handler.reimport({"paths": ["/tmp/bad.png"]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.not_found_count, 1)


func test_reimport_rejects_traversal_path() -> void:
	## Issue #347: per-path validation in the loop must catch traversal too.
	var result := _handler.reimport({"paths": ["res://../etc/passwd"]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.not_found_count, 1)
	assert_contains(result.data.not_found[0], "..")


# ----- scan_filesystem -----

func test_scan_filesystem_sync_shape_and_coalesces_when_latch_set() -> void:
	## The test handler has no _connection, so scan_filesystem takes the
	## synchronous fallback. Pre-set the single-flight latch so the fallback
	## coalesces (was_already_scanning=true) instead of kicking a real editor
	## scan mid-suite — this also asserts the documented response shape, which
	## must match the deferred path's keys. The deferred settle path itself is
	## covered by the Python tests + live verification.
	FilesystemHandler._scan_in_flight = true
	var result := _handler.scan_filesystem({})
	FilesystemHandler._scan_in_flight = false
	assert_has_key(result, "data")
	assert_eq(result.data.scan_settle, "not_waited")
	assert_true(result.data.was_already_scanning, "latch set → coalesced, no new scan() kicked")
	assert_true(result.data.has("global_class_count"), "shape: global_class_count present")
	assert_true(
		result.data.has("global_classes_registered_delta"),
		"shape: delta present in both paths"
	)
	assert_false(result.data.undoable)


# ----- move / rename / remove (#907) -----

const FS_SRC_SCRIPT := "res://tests/" + "_mcp_fs_move_src.gd"
const FS_DST_SCRIPT := "res://tests/" + "_mcp_fs_move_dst.gd"
const FS_OWNER_SCENE := "res://tests/" + "_mcp_fs_owner.tscn"
const FS_OWNER_SCRIPT := "res://tests/" + "_mcp_fs_owner_script.gd"
const FS_PLAIN := "res://tests/" + "_mcp_fs_plain.txt"
const FS_PLAIN_2 := "res://tests/" + "_mcp_fs_plain_2.txt"
const FS_PLAIN_RENAMED := "res://tests/" + "_mcp_fs_plain_renamed.txt"
const FS_TRASH_PROBE := "res://tests/" + "_mcp_fs_trash_probe.txt"
const FS_DIR := "res://tests/" + "_mcp_fs_dir"
const FS_DIR_MOVED := "res://tests/" + "_mcp_fs_dir_moved"
const FS_OUTSIDE_SCENE := "res://tests/" + "_mcp_fs_outside.tscn"


func _fs_write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "fixture must be writable: %s" % path)
	if f == null:
		return
	f.store_string(content)
	f.close()
	## Register with the editor filesystem the way write_file does — the
	## owner search walks the EFS tree, not the disk.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)


## A script carrying a uid. Godot 4.4+ mints the `.uid` sidecar itself on
## `update_file`; older behaviour is covered by minting one here.
func _fs_write_script_with_uid(path: String) -> int:
	_fs_write(path, "extends Node\n")
	var id := ResourceLoader.get_resource_uid(path)
	if id == ResourceUID.INVALID_ID:
		id = ResourceUID.create_id()
		var f := FileAccess.open(path + ".uid", FileAccess.WRITE)
		if f != null:
			f.store_string(ResourceUID.id_to_text(id))
			f.close()
		ResourceUID.add_id(id, path)
	return id


func _fs_scene_text(script_path: String) -> String:
	return (
		"[gd_scene format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"%s\" id=\"1_s\"]\n\n" % script_path
		+ "[node name=\"Root\" type=\"Node\"]\nscript = ExtResource(\"1_s\")\n"
	)


func _fs_read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _fs_rm(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		FilesystemHandler._remove_dir_recursive(path)
	for candidate in [path, path + ".uid", path + ".import"]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)
	## Tell the editor filesystem the file is gone, so a stale entry can't
	## leak parse errors into later suites' capture windows.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)


func _fs_cleanup_move_fixtures() -> void:
	for path in [
		FS_SRC_SCRIPT, FS_DST_SCRIPT, FS_OWNER_SCENE, FS_OWNER_SCRIPT,
		FS_PLAIN, FS_PLAIN_2, FS_PLAIN_RENAMED, FS_TRASH_PROBE,
	]:
		_fs_rm(path)


func _fs_cleanup_dir_fixtures() -> void:
	for dir_path in [FS_DIR, FS_DIR_MOVED]:
		for rel in ["inner.gd", "inner.tscn", "a.txt", "sub/b.txt"]:
			_fs_rm(dir_path.path_join(rel))
		if DirAccess.dir_exists_absolute(dir_path):
			FilesystemHandler._remove_dir_recursive(dir_path)
	_fs_rm(FS_OUTSIDE_SCENE)


func test_move_file_rewrites_owner_scene_and_keeps_uid() -> void:
	_fs_cleanup_move_fixtures()
	var uid := _fs_write_script_with_uid(FS_SRC_SCRIPT)
	var had_sidecar := FileAccess.file_exists(FS_SRC_SCRIPT + ".uid")
	_fs_write(FS_OWNER_SCENE, _fs_scene_text(FS_SRC_SCRIPT))
	var result := _handler.move_file({"path": FS_SRC_SCRIPT, "new_path": FS_DST_SCRIPT})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.kind, "file")
		assert_eq(result.data.moved_count, 1)
		assert_eq(result.data.uids_updated, 1)
		assert_false(result.data.undoable)
		assert_contains(result.data.dependencies_updated, FS_OWNER_SCENE)
		assert_eq(result.data.script_references_unfixed, [])
	assert_false(FileAccess.file_exists(FS_SRC_SCRIPT), "source must be gone")
	assert_true(FileAccess.file_exists(FS_DST_SCRIPT), "destination must exist")
	assert_eq(FileAccess.file_exists(FS_DST_SCRIPT + ".uid"), had_sidecar, ".uid sidecar travels with the script")
	assert_eq(ResourceLoader.get_resource_uid(FS_DST_SCRIPT), uid, "uid is preserved across the move")
	assert_eq(ResourceUID.get_id_path(uid), FS_DST_SCRIPT, "ResourceUID points at the new path")
	var scene_text := _fs_read(FS_OWNER_SCENE)
	assert_contains(scene_text, "path=\"%s\"" % FS_DST_SCRIPT)
	assert_false(FS_SRC_SCRIPT in scene_text, "old path must not linger in the owner scene")
	_fs_cleanup_move_fixtures()


func test_move_file_reports_script_preload_references() -> void:
	## A script that preload()s the moved file by string path: the dock
	## doesn't rewrite those, so the response must point at it instead.
	_fs_cleanup_move_fixtures()
	_fs_write_script_with_uid(FS_SRC_SCRIPT)
	_fs_write(FS_OWNER_SCRIPT, "extends Node\nconst Dep := preload(\"%s\")\n" % FS_SRC_SCRIPT)
	var result := _handler.move_file({"path": FS_SRC_SCRIPT, "new_path": FS_DST_SCRIPT})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.script_references_unfixed.size(), 1, "the preloading script is reported")
		if result.data.script_references_unfixed.size() == 1:
			assert_eq(result.data.script_references_unfixed[0].script, FS_OWNER_SCRIPT)
			assert_contains(result.data.script_references_unfixed[0].references, FS_SRC_SCRIPT)
		assert_has_key(result.data, "script_references_hint")
		assert_eq(result.data.dependencies_updated, [], "a .gd owner is never rewritten")
	_fs_cleanup_move_fixtures()


func test_move_file_refuses_existing_destination() -> void:
	_fs_cleanup_move_fixtures()
	_fs_write(FS_PLAIN, "a\n")
	_fs_write(FS_PLAIN_2, "b\n")
	var result := _handler.move_file({"path": FS_PLAIN, "new_path": FS_PLAIN_2})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "already exists")
	assert_eq(_fs_read(FS_PLAIN_2), "b\n", "existing destination must be untouched")
	assert_true(FileAccess.file_exists(FS_PLAIN), "source untouched on refusal")
	_fs_cleanup_move_fixtures()


func test_move_file_refuses_when_sidecar_destination_is_taken() -> void:
	## A stray folder sitting where the `.uid` sidecar would land must be
	## refused up front — the file and its sidecar move as one unit, never
	## halfway.
	_fs_cleanup_move_fixtures()
	var uid := _fs_write_script_with_uid(FS_SRC_SCRIPT)
	if not FileAccess.file_exists(FS_SRC_SCRIPT + ".uid"):
		_fs_cleanup_move_fixtures()
		skip("no .uid sidecar was minted for the fixture")
		return
	DirAccess.make_dir_recursive_absolute(FS_DST_SCRIPT + ".uid")
	var result := _handler.move_file({"path": FS_SRC_SCRIPT, "new_path": FS_DST_SCRIPT})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "sidecar")
	assert_true(FileAccess.file_exists(FS_SRC_SCRIPT), "source untouched on refusal")
	assert_true(FileAccess.file_exists(FS_SRC_SCRIPT + ".uid"), "source sidecar untouched on refusal")
	assert_false(FileAccess.file_exists(FS_DST_SCRIPT), "nothing landed at the destination")
	assert_eq(ResourceUID.get_id_path(uid), FS_SRC_SCRIPT, "ResourceUID still points at the source")
	DirAccess.remove_absolute(FS_DST_SCRIPT + ".uid")
	_fs_cleanup_move_fixtures()


func test_move_file_missing_source() -> void:
	var result := _handler.move_file({
		"path": "res://tests/_mcp_fs_nope.txt", "new_path": "res://tests/_mcp_fs_nope_2.txt",
	})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


func test_move_file_rejects_traversal_destination() -> void:
	_fs_cleanup_move_fixtures()
	_fs_write(FS_PLAIN, "a\n")
	var result := _handler.move_file({"path": FS_PLAIN, "new_path": "res://../_mcp_fs_escaped.txt"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "..")
	assert_true(FileAccess.file_exists(FS_PLAIN), "source untouched on refusal")
	_fs_cleanup_move_fixtures()


func test_move_file_refuses_sidecar_plugin_ancestor_and_plugin_file() -> void:
	var sidecar := _handler.move_file({
		"path": "res://tests/test_filesystem.gd.uid", "new_path": "res://tests/_mcp_fs_x.uid",
	})
	assert_is_error(sidecar, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(sidecar.error.message, "sidecar")
	## `res://addons` is above the validator's blocked tree but contains it.
	var ancestor := _handler.move_file({"path": "res://addons", "new_path": "res://_mcp_fs_addons_moved"})
	assert_is_error(ancestor, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(ancestor.error.message, "plugin")
	assert_true(DirAccess.dir_exists_absolute("res://addons"), "addons must not move")
	var plugin_file := _handler.move_file({
		"path": "res://addons/godot_ai/plugin.gd", "new_path": "res://_mcp_fs_plugin.gd",
	})
	assert_is_error(plugin_file, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(FileAccess.file_exists("res://addons/godot_ai/plugin.gd"))


func test_rename_file_in_place() -> void:
	_fs_cleanup_move_fixtures()
	_fs_write(FS_PLAIN, "hello\n")
	var result := _handler.rename_file({"path": FS_PLAIN, "new_name": FS_PLAIN_RENAMED.get_file()})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.new_path, FS_PLAIN_RENAMED)
		assert_eq(result.data.kind, "file")
	assert_false(FileAccess.file_exists(FS_PLAIN))
	assert_eq(_fs_read(FS_PLAIN_RENAMED), "hello\n")
	_fs_cleanup_move_fixtures()


func test_rename_file_rejects_path_separators_and_missing_name() -> void:
	_fs_cleanup_move_fixtures()
	_fs_write(FS_PLAIN, "a\n")
	var slashed := _handler.rename_file({"path": FS_PLAIN, "new_name": "sub/other.txt"})
	assert_is_error(slashed, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(slashed.error.message, "bare name")
	var missing := _handler.rename_file({"path": FS_PLAIN})
	assert_is_error(missing, ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_true(FileAccess.file_exists(FS_PLAIN))
	_fs_cleanup_move_fixtures()


func test_move_directory_remaps_nested_and_outside_references() -> void:
	_fs_cleanup_dir_fixtures()
	var inner_script := FS_DIR + "/inner.gd"
	var inner_scene := FS_DIR + "/inner.tscn"
	_fs_write_script_with_uid(inner_script)
	_fs_write(inner_scene, _fs_scene_text(inner_script))
	_fs_write(FS_OUTSIDE_SCENE, _fs_scene_text(inner_script))
	## Suppress the post-move scan kick: a real scan mid-suite would race
	## other suites' capture windows. Same latch trick as the scan test.
	FilesystemHandler._scan_in_flight = true
	var result := _handler.move_file({"path": FS_DIR, "new_path": FS_DIR_MOVED})
	FilesystemHandler._scan_in_flight = false
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.kind, "directory")
		assert_eq(result.data.moved_count, 2)
		assert_false(result.data.scan_kicked, "latch set → no scan kicked")
		var moved_scene := FS_DIR_MOVED + "/inner.tscn"
		var moved_script := FS_DIR_MOVED + "/inner.gd"
		assert_contains(result.data.dependencies_updated, moved_scene)
		assert_contains(result.data.dependencies_updated, FS_OUTSIDE_SCENE)
		assert_contains(_fs_read(moved_scene), "path=\"%s\"" % moved_script)
		assert_contains(_fs_read(FS_OUTSIDE_SCENE), "path=\"%s\"" % moved_script)
		assert_true(FileAccess.file_exists(moved_script))
	assert_false(DirAccess.dir_exists_absolute(FS_DIR), "old folder must be gone")
	_fs_cleanup_dir_fixtures()


func test_remove_file_refuses_referenced_without_force() -> void:
	_fs_cleanup_move_fixtures()
	_fs_write_script_with_uid(FS_SRC_SCRIPT)
	_fs_write(FS_OWNER_SCENE, _fs_scene_text(FS_SRC_SCRIPT))
	var result := _handler.remove_file({"path": FS_SRC_SCRIPT, "permanent": true})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "force=true")
	assert_has_key(result.error, "data")
	if result.error.has("data"):
		assert_eq(result.error.data.referenced_by.size(), 1)
		assert_eq(result.error.data.referenced_by[0].path, FS_OWNER_SCENE)
		assert_contains(result.error.data.referenced_by[0].references, FS_SRC_SCRIPT)
	assert_true(FileAccess.file_exists(FS_SRC_SCRIPT), "refusal must leave the file alone")
	_fs_cleanup_move_fixtures()


func test_remove_file_refuses_script_string_reference_without_force() -> void:
	## A preload()ing script is an owner too, even though the loader's
	## dependency list never mentions it.
	_fs_cleanup_move_fixtures()
	_fs_write_script_with_uid(FS_SRC_SCRIPT)
	_fs_write(FS_OWNER_SCRIPT, "extends Node\nconst Dep := preload(\"%s\")\n" % FS_SRC_SCRIPT)
	var result := _handler.remove_file({"path": FS_SRC_SCRIPT, "permanent": true})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_has_key(result.error, "data")
	if result.error.has("data"):
		assert_eq(result.error.data.referenced_by.size(), 1)
		assert_eq(result.error.data.referenced_by[0].path, FS_OWNER_SCRIPT)
	assert_true(FileAccess.file_exists(FS_SRC_SCRIPT), "refusal must leave the file alone")
	_fs_cleanup_move_fixtures()


func test_remove_file_force_permanent_deletes_file_sidecar_and_uid() -> void:
	_fs_cleanup_move_fixtures()
	var uid := _fs_write_script_with_uid(FS_SRC_SCRIPT)
	_fs_write(FS_OWNER_SCENE, _fs_scene_text(FS_SRC_SCRIPT))
	var result := _handler.remove_file({"path": FS_SRC_SCRIPT, "force": true, "permanent": true})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.removed, [FS_SRC_SCRIPT])
		assert_false(result.data.trashed)
		assert_false(result.data.undoable)
		assert_eq(result.data.uids_released, 1)
		assert_has_key(result.data, "referenced_by")
		if result.data.has("referenced_by"):
			assert_eq(result.data.referenced_by.size(), 1, "forced removal still reports the dangling owner")
	assert_false(FileAccess.file_exists(FS_SRC_SCRIPT))
	assert_false(FileAccess.file_exists(FS_SRC_SCRIPT + ".uid"), "sidecar removed with the script")
	assert_false(ResourceUID.has_id(uid), "uid released")
	_fs_cleanup_move_fixtures()


func test_remove_unreferenced_file_permanent() -> void:
	_fs_cleanup_move_fixtures()
	_fs_write(FS_PLAIN, "bye\n")
	var result := _handler.remove_file({"path": FS_PLAIN, "permanent": true})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.removed_count, 1)
		assert_eq(result.data.kind, "file")
		assert_false(result.data.has("referenced_by"), "no dangling owners → no referenced_by field")
	assert_false(FileAccess.file_exists(FS_PLAIN))


func test_remove_file_default_uses_os_trash() -> void:
	## Probe the OS trash first: a headless box without a trash
	## implementation is an environment precondition, not a handler bug.
	_fs_cleanup_move_fixtures()
	_fs_write(FS_TRASH_PROBE, "probe\n")
	var probe_err := OS.move_to_trash(ProjectSettings.globalize_path(FS_TRASH_PROBE))
	if probe_err != OK:
		_fs_rm(FS_TRASH_PROBE)
		skip("OS trash unavailable here: %s" % error_string(probe_err))
		return
	_fs_write(FS_PLAIN, "trash me\n")
	var result := _handler.remove_file({"path": FS_PLAIN})
	assert_has_key(result, "data")
	if result.has("data"):
		assert_true(result.data.trashed, "default removal goes to the OS trash")
		assert_contains(result.data.reason, "trash")
	assert_false(FileAccess.file_exists(FS_PLAIN))


func test_remove_refuses_missing_root_sidecar_plugin_ancestor_and_manifest() -> void:
	var missing := _handler.remove_file({"path": "res://tests/_mcp_fs_nope.txt", "permanent": true})
	assert_is_error(missing, ErrorCodes.RESOURCE_NOT_FOUND)
	var root := _handler.remove_file({"path": "res://", "permanent": true, "force": true})
	assert_is_error(root, ErrorCodes.VALUE_OUT_OF_RANGE)
	var sidecar := _handler.remove_file({"path": "res://tests/test_filesystem.gd.uid", "permanent": true})
	assert_is_error(sidecar, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(FileAccess.file_exists("res://tests/test_filesystem.gd.uid"))
	var ancestor := _handler.remove_file({"path": "res://addons", "force": true, "permanent": true})
	assert_is_error(ancestor, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(DirAccess.dir_exists_absolute("res://addons"))
	var manifest := _handler.remove_file({"path": "res://project.godot", "force": true, "permanent": true})
	assert_is_error(manifest, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(FileAccess.file_exists("res://project.godot"))


func test_remove_directory_refuses_outside_owner_but_not_inside_owner() -> void:
	_fs_cleanup_dir_fixtures()
	var inner_script := FS_DIR + "/inner.gd"
	_fs_write_script_with_uid(inner_script)
	_fs_write(FS_DIR + "/inner.tscn", _fs_scene_text(inner_script))
	_fs_write(FS_OUTSIDE_SCENE, _fs_scene_text(inner_script))
	var result := _handler.remove_file({"path": FS_DIR, "permanent": true})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_has_key(result.error, "data")
	if result.error.has("data"):
		var owners: Array = result.error.data.referenced_by
		assert_eq(owners.size(), 1, "only the owner OUTSIDE the folder blocks removal")
		if owners.size() == 1:
			assert_eq(owners[0].path, FS_OUTSIDE_SCENE)
	assert_true(DirAccess.dir_exists_absolute(FS_DIR), "refusal leaves the folder alone")
	_fs_cleanup_dir_fixtures()


func test_remove_directory_permanent_removes_nested_files() -> void:
	_fs_cleanup_dir_fixtures()
	_fs_write(FS_DIR + "/a.txt", "a\n")
	_fs_write(FS_DIR + "/sub/b.txt", "b\n")
	FilesystemHandler._scan_in_flight = true
	var result := _handler.remove_file({"path": FS_DIR, "permanent": true})
	FilesystemHandler._scan_in_flight = false
	assert_has_key(result, "data")
	if result.has("data"):
		assert_eq(result.data.kind, "directory")
		assert_eq(result.data.removed_count, 2)
		assert_false(result.data.scan_kicked, "latch set → no scan kicked")
	assert_false(DirAccess.dir_exists_absolute(FS_DIR), "folder must be gone")
	_fs_cleanup_dir_fixtures()
