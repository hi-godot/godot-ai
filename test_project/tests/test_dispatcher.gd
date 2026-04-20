@tool
extends McpTestSuite

## Tests for McpDispatcher — the crash-detection guardrail that catches
## handlers returning malformed results, plus coroutine-handler support.


func suite_name() -> String:
	return "dispatcher"


func _make_dispatcher() -> McpDispatcher:
	return McpDispatcher.new(McpLogBuffer.new())


# ----- crash detection -----

func test_dispatch_direct_converts_empty_dict_to_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("returns_empty", func(_p): return {})
	var result: Dictionary = await d.dispatch_direct("returns_empty", {})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "returns_empty")
	assert_contains(result.error.message, "likely crashed")


func test_dispatch_direct_converts_null_result_to_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	## GDScript coerces null Variant to {} for typed Dictionary returns, so
	## this ends up looking the same as the empty-dict case — still flagged.
	d.register("returns_null", func(_p): return {})
	var result: Dictionary = await d.dispatch_direct("returns_null", {})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)


func test_dispatch_direct_rejects_dict_missing_data_and_error_keys() -> void:
	## A non-empty dict that still lacks the protocol-required keys is also
	## treated as a crash — e.g. a handler accidentally returns {"foo": 1}.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("malformed", func(_p): return {"foo": "bar", "baz": 42})
	var result: Dictionary = await d.dispatch_direct("malformed", {})
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "malformed")


func test_dispatch_direct_accepts_data_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("good_data", func(_p): return {"data": {"value": 1}})
	var result: Dictionary = await d.dispatch_direct("good_data", {})
	assert_has_key(result, "data")
	assert_eq(result.data.value, 1)


func test_dispatch_direct_accepts_error_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("good_error", func(_p):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "bad input"))
	var result: Dictionary = await d.dispatch_direct("good_error", {})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_eq(result.error.message, "bad input")


func test_dispatch_direct_unknown_command_unchanged() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var result: Dictionary = await d.dispatch_direct("never_registered", {})
	assert_is_error(result, McpErrorCodes.UNKNOWN_COMMAND)


# ----- coroutine handler support (#29) -----

func _sync_handler(_p: Dictionary) -> Dictionary:
	return {"data": {"kind": "sync"}}


func _async_handler(_p: Dictionary) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	return {"data": {"kind": "async", "yielded": true}}


func test_dispatch_direct_awaits_synchronous_handler() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("sync", _sync_handler)
	var result: Dictionary = await d.dispatch_direct("sync", {})
	assert_has_key(result, "data")
	assert_eq(result.data.kind, "sync")


func test_dispatch_direct_awaits_coroutine_handler() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("async", _async_handler)
	var result: Dictionary = await d.dispatch_direct("async", {})
	assert_has_key(result, "data")
	assert_eq(result.data.kind, "async")
	assert_eq(result.data.yielded, true)


func test_tick_delivers_coroutine_response_via_sink() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("async", _async_handler)
	var received: Array[Dictionary] = []
	d.set_response_sink(func(resp): received.append(resp))
	d.enqueue({"request_id": "r1", "command": "async", "params": {}})
	d.tick()
	## Handler yields one frame inside _dispatch; yield two here to let the
	## drain loop unwind and push through the sink.
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	await tree.process_frame
	assert_eq(received.size(), 1)
	assert_eq(received[0].request_id, "r1")
	assert_eq(received[0].status, "ok")
	assert_eq(received[0].data.kind, "async")


func test_tick_delivers_sync_response_via_sink() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("sync", _sync_handler)
	var received: Array[Dictionary] = []
	d.set_response_sink(func(resp): received.append(resp))
	d.enqueue({"request_id": "r2", "command": "sync", "params": {}})
	d.tick()
	assert_eq(received.size(), 1)
	assert_eq(received[0].request_id, "r2")
	assert_eq(received[0].status, "ok")
	assert_eq(received[0].data.kind, "sync")
