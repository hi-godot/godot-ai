@tool
extends McpTestSuite

## Tests for FilesystemHandler — file read/write and reimport.

var _handler: FilesystemHandler

const TEST_FILE_PATH := "res://tests/_mcp_test_file.txt"
const TEST_FILE_CONTENT := "Hello from MCP test\nLine 2\nLine 3\n"


func suite_name() -> String:
	return "filesystem"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = FilesystemHandler.new()
	# Create a test file for read tests
	var file := FileAccess.open(TEST_FILE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(TEST_FILE_CONTENT)
		file.close()


func suite_teardown() -> void:
	# Clean up test files
	if FileAccess.file_exists(TEST_FILE_PATH):
		DirAccess.remove_absolute(TEST_FILE_PATH)
	var written_path := "res://tests/_mcp_test_written.txt"
	if FileAccess.file_exists(written_path):
		DirAccess.remove_absolute(written_path)


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
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_read_file_invalid_prefix() -> void:
	var result := _handler.read_file({"path": "/tmp/bad.txt"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_read_file_not_found() -> void:
	var result := _handler.read_file({"path": "res://nonexistent_file.txt"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


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
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_write_file_invalid_prefix() -> void:
	var result := _handler.write_file({"path": "/tmp/bad.txt", "content": "hello"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- reimport -----

func test_reimport_missing_paths() -> void:
	var result := _handler.reimport({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_reimport_empty_paths() -> void:
	var result := _handler.reimport({"paths": []})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_reimport_nonexistent_file() -> void:
	var result := _handler.reimport({"paths": ["res://nonexistent.png"]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.not_found_count, 1)
	# not_found entries now include reason suffix, so check the first entry contains the path
	assert_contains(result.data.not_found[0], "res://nonexistent.png")


func test_reimport_existing_file() -> void:
	# Use the test file we created in setup
	var result := _handler.reimport({"paths": [TEST_FILE_PATH]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 1)
	assert_contains(result.data.reimported, TEST_FILE_PATH)


func test_reimport_invalid_prefix() -> void:
	var result := _handler.reimport({"paths": ["/tmp/bad.png"]})
	assert_has_key(result, "data")
	assert_eq(result.data.reimported_count, 0)
	assert_eq(result.data.not_found_count, 1)
