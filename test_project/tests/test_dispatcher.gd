@tool
extends McpTestSuite

## Tests for McpDispatcher — specifically the crash-detection guardrail
## that catches handlers returning malformed results (null, empty dict,
## or dicts missing both "data" and "error" keys).


func suite_name() -> String:
	return "dispatcher"


func _make_dispatcher() -> McpDispatcher:
	return McpDispatcher.new(McpLogBuffer.new())


# ----- crash detection -----

func test_dispatch_direct_converts_empty_dict_to_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("returns_empty", func(_p): return {})
	var result := d.dispatch_direct("returns_empty", {})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "returns_empty")
	assert_contains(result.error.message, "malformed result")


func test_dispatch_direct_converts_null_result_to_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	## GDScript coerces null Variant to {} for typed Dictionary returns, so
	## this ends up looking the same as the empty-dict case — still flagged.
	d.register("returns_null", func(_p): return {})
	var result := d.dispatch_direct("returns_null", {})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)


func test_dispatch_direct_rejects_dict_missing_data_and_error_keys() -> void:
	## A non-empty dict that still lacks the protocol-required keys is also
	## treated as a crash — e.g. a handler accidentally returns {"foo": 1}.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("malformed", func(_p): return {"foo": "bar", "baz": 42})
	var result := d.dispatch_direct("malformed", {})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "malformed")


func test_dispatch_direct_accepts_data_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("good_data", func(_p): return {"data": {"value": 1}})
	var result := d.dispatch_direct("good_data", {})
	assert_has_key(result, "data")
	assert_eq(result.data.value, 1)


func test_dispatch_direct_accepts_error_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("good_error", func(_p):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "bad input"))
	var result := d.dispatch_direct("good_error", {})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_eq(result.error.message, "bad input")


func test_dispatch_direct_unknown_command_unchanged() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var result := d.dispatch_direct("never_registered", {})
	assert_is_error(result, McpErrorCodes.UNKNOWN_COMMAND)


# ----- malformed-result error surfaces args + writes to log buffer (#210) -----


func test_malformed_result_message_includes_received_args() -> void:
	## When a handler crashes / returns junk, the agent has no way to inspect
	## Godot's console. Surface what the handler was called with so the
	## agent can spot a param type mismatch from outside the editor.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("crashy", func(_p): return {})
	var result := d.dispatch_direct("crashy", {"path": "/Main", "group": ["a", "b"]})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "crashy")
	assert_contains(result.error.message, "/Main")
	assert_contains(result.error.message, "group")


func test_malformed_result_message_strips_internal_request_id() -> void:
	## The dispatcher threads `_request_id` into the duplicated params dict
	## for handlers that need it (deferred responses); it must not leak back
	## into a user-facing error message.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("crashy", func(_p): return {})
	var result := d.dispatch_direct("crashy", {"_request_id": "secret-rid-123"})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_true(
		result.error.message.find("secret-rid-123") == -1,
		"_request_id must not appear in the user-facing error message",
	)


func test_malformed_result_writes_error_line_to_log_buffer() -> void:
	## logs_read is the only out-of-editor channel for post-crash context.
	## Confirm a line lands there alongside the protocol response.
	var buf := McpLogBuffer.new()
	var d := McpDispatcher.new(buf)
	d.mcp_logging = true
	d.register("crashy", func(_p): return {})
	d.dispatch_direct("crashy", {"path": "/Main"})
	var lines := buf.get_recent(20)
	var found := false
	for line in lines:
		if line.find("[error]") != -1 and line.find("crashy") != -1:
			found = true
			break
	assert_true(found, "malformed result should log an [error] line")


func test_malformed_result_truncates_long_args() -> void:
	## Avoid bloating responses with huge param dumps — a few hundred chars
	## is usually enough to identify the bad field.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("crashy", func(_p): return {})
	var big := ""
	for i in range(200):
		big += "x"
	var result := d.dispatch_direct("crashy", {"blob": big + big + big})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "...")
