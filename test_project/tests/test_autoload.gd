@tool
extends McpTestSuite

## Tests for AutoloadHandler — autoload listing, adding, and removing.

var _handler: AutoloadHandler
const TEST_AUTOLOAD_NAME := "_McpTestAutoload"


func suite_name() -> String:
	return "autoload"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = AutoloadHandler.new()


func suite_teardown() -> void:
	## Clean up any test autoload left behind
	var key := "autoload/%s" % TEST_AUTOLOAD_NAME
	if ProjectSettings.has_setting(key):
		ProjectSettings.clear(key)
		ProjectSettings.save()


# ----- list_autoloads -----

func test_list_autoloads() -> void:
	var result := _handler.list_autoloads({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "autoloads")
	assert_has_key(result.data, "count")


# ----- add_autoload -----

func test_add_autoload_missing_name() -> void:
	var result := _handler.add_autoload({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_add_autoload_missing_path() -> void:
	var result := _handler.add_autoload({"name": TEST_AUTOLOAD_NAME})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_add_autoload_invalid_path_prefix() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "/absolute/path/evil.gd",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_add_autoload_user_path_rejected() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "user://evil.gd",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_add_autoload_nonexistent_file() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "res://nonexistent_autoload_xyz.gd",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_add_and_remove_autoload() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "res://tests/test_autoload.gd",
		"singleton": true,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.name, TEST_AUTOLOAD_NAME)
	assert_eq(result.data.singleton, true)

	## Verify it shows up in the list
	var list_result := _handler.list_autoloads({})
	var found := false
	for al in list_result.data.autoloads:
		if al.name == TEST_AUTOLOAD_NAME:
			found = true
			break
	assert_true(found, "Autoload should appear in list after adding")

	## Remove it
	var remove_result := _handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})
	assert_has_key(remove_result, "data")
	assert_eq(remove_result.data.removed, true)


func test_add_autoload_duplicate() -> void:
	## Add once
	_handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "res://tests/test_autoload.gd",
	})
	## Add again should fail
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "res://tests/test_autoload.gd",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	## Cleanup
	_handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})


# ----- remove_autoload -----

func test_remove_autoload_missing_name() -> void:
	var result := _handler.remove_autoload({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_remove_autoload_not_found() -> void:
	var result := _handler.remove_autoload({"name": "_NoSuchAutoload"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
