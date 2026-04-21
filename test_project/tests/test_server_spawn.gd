@tool
extends McpTestSuite

## Tests for McpServerSpawn — issue #146. Only the pure helper
## (`classify_error`) is covered here; the actual pipe capture + PID
## watching requires a real child process and is covered by the live
## smoke path in the PR.


func suite_name() -> String:
	return "server_spawn"


# ----- classify_error -----

func test_classify_error_recognises_winerror_10013() -> void:
	var text := (
		"[Errno 13] error while attempting to bind on address ('127.0.0.1', 8000):\n"
		+ "[winerror 10013] an attempt was made to access a socket in a way forbidden by its access permissions"
	)
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_WINERROR_10013)
	assert_contains(str(hint.get("text")), "8000")
	assert_contains(str(hint.get("text")), "winnat")


func test_classify_error_matches_forbidden_permissions_phrase() -> void:
	## The WinError 10013 hint also triggers on the English phrase alone,
	## since some error formatters render it without the numeric code.
	var text := "OSError: forbidden by its access permissions"
	var hint := McpServerSpawn.classify_error(text, 9000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_WINERROR_10013)
	assert_contains(str(hint.get("text")), "9000")


func test_classify_error_recognises_port_in_use_linux() -> void:
	var text := "OSError: [Errno 98] Address already in use"
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_PORT_IN_USE)
	assert_contains(str(hint.get("text")), "8000")


func test_classify_error_recognises_port_in_use_windows() -> void:
	var text := "OSError: [WinError 10048] Only one usage of each socket address ..."
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_PORT_IN_USE)


func test_classify_error_recognises_port_in_use_plain_text() -> void:
	## "address already in use" without an errno number (e.g. uvicorn's
	## own log formatter).
	var text := "ERROR: address already in use"
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_PORT_IN_USE)


func test_classify_error_recognises_missing_module() -> void:
	var text := "ModuleNotFoundError: No module named 'godot_ai'"
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_MISSING_MODULE)
	assert_contains(str(hint.get("text")), "uv cache clean")


func test_classify_error_recognises_no_module_named_phrase() -> void:
	## Python's traceback sometimes prints the "No module named" line
	## without the ModuleNotFoundError prefix.
	var text := "ImportError: No module named 'mcp'"
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_MISSING_MODULE)


func test_classify_error_returns_empty_for_unknown() -> void:
	var text := "INFO:     Started server process [29096]\nuvicorn running"
	var hint := McpServerSpawn.classify_error(text, 8000)
	assert_eq(hint.get("id"), "")
	assert_eq(str(hint.get("text")), "")


func test_classify_error_interpolates_correct_port() -> void:
	var text := "[winerror 10013] forbidden by its access permissions"
	var hint_8000 := McpServerSpawn.classify_error(text, 8000)
	var hint_9001 := McpServerSpawn.classify_error(text, 9001)
	assert_contains(str(hint_8000.get("text")), "8000")
	assert_contains(str(hint_9001.get("text")), "9001")
	assert_true(
		not str(hint_8000.get("text")).contains("9001"),
		"hint for port 8000 should not mention 9001",
	)


# ----- helper identity -----

func test_is_past_watch_window_false_before_start() -> void:
	## A freshly-constructed helper that was never spawned should not
	## claim to have passed its watch window — otherwise the plugin's
	## `_process` would drop the (never-used) spawn on the first tick.
	var spawn := McpServerSpawn.new()
	assert_true(
		not spawn.is_past_watch_window(),
		"fresh McpServerSpawn should not report past watch window",
	)
	assert_true(not spawn.is_exited(), "fresh spawn should not be exited")
	assert_eq(spawn.exit_info(8000), {}, "fresh spawn should have empty exit_info")


func test_exit_info_is_empty_until_exit_observed() -> void:
	var spawn := McpServerSpawn.new()
	## pid stays -1 without a real spawn; tick should be a no-op and
	## exit_info should stay empty.
	assert_true(not spawn.tick(), "tick with no pid should return false")
	assert_eq(spawn.exit_info(8000), {})


func test_classify_error_is_case_insensitive() -> void:
	## `classify_error` normalises to lowercase — capitalisation
	## differences across Python / OS formatters shouldn't matter.
	var text_mixed := "ErRnO 98 Address Already In Use"
	var hint := McpServerSpawn.classify_error(text_mixed, 8000)
	assert_eq(hint.get("id"), McpServerSpawn.HINT_PORT_IN_USE)
