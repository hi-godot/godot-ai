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
	for path in [IMPORTED_ASSET_PATH, IMPORTED_ASSET_PATH + ".import"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


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
	var script_path := "res://addons/godot_ai/handlers/filesystem_handler.gd"
	var result := _handler.reimport({
		"paths": [IMPORTED_ASSET_PATH, script_path, "res://nonexistent.png"],
	})
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
	assert_eq(result.data.skipped_non_imported_count, 1)


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
