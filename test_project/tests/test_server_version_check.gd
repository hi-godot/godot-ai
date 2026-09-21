@tool
extends McpTestSuite


func suite_name() -> String:
	return "server_version_check"


func test_exact_v4_version_is_compatible() -> void:
	var result := McpServerVersionCheck.evaluate("4.0.0", "4.0.0")
	assert_true(result.compatible)
	assert_eq(result.reason, "")


func test_version_tuple_and_older_same_major() -> void:
	assert_eq(McpServerVersionCheck.version_tuple("4.0.3"), [4, 0, 3])
	assert_eq(McpServerVersionCheck.version_tuple("4.1.0+local.1"), [4, 1, 0])
	assert_eq(McpServerVersionCheck.version_tuple("4.2.0-rc1"), [4, 2, 0])
	assert_eq(McpServerVersionCheck.version_tuple("older-client-pin"), [])
	assert_eq(McpServerVersionCheck.version_tuple(""), [])
	assert_eq(McpServerVersionCheck.version_tuple("4.0.3+"), [], "a dangling separator is not a version")
	assert_eq(McpServerVersionCheck.version_tuple("4.0"), [])
	assert_eq(McpServerVersionCheck.compare([4, 0, 3], [4, 1, 0]), -1)
	assert_eq(McpServerVersionCheck.compare([4, 1, 0], [4, 1, 0]), 0)
	assert_true(McpServerVersionCheck.is_older_same_major("4.0.2", "4.0.3"))
	assert_true(McpServerVersionCheck.is_older_same_major("4.0.9", "4.1.0"))
	assert_false(McpServerVersionCheck.is_older_same_major("4.0.3", "4.0.3"), "equal is not older")
	assert_false(McpServerVersionCheck.is_older_same_major("4.1.0", "4.0.3"), "never a newer server")
	assert_false(McpServerVersionCheck.is_older_same_major("3.2.5", "4.0.3"), "another major is not ours")
	assert_false(McpServerVersionCheck.is_older_same_major("weird", "4.0.3"))


func test_missing_or_different_version_fails_closed() -> void:
	assert_eq(McpServerVersionCheck.evaluate("", "4.0.0").reason, "missing_version")
	assert_eq(
		McpServerVersionCheck.evaluate("3.9.0", "4.0.0").reason,
		"version_mismatch",
	)
