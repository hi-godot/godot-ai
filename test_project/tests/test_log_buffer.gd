@tool
extends McpTestSuite

## Coverage for McpLogBuffer's console-echo gating. The ring buffer must keep
## recording lines (so content-asserting tests stay valid) whether or not the
## console echo is muted — the test runner mutes it for the whole run.

const McpLogBufferScript := preload("res://addons/godot_ai/utils/log_buffer.gd")


func suite_name() -> String:
	return "log_buffer"


## NOTE: there is intentionally no "console_echo defaults to true" test — the
## test runner sets it false for the duration of every run, so the flag is
## never true mid-run. The production default lives in the declaration
## (`static var console_echo := true`) and the runner restores the prior value
## on exit.


func test_log_records_to_ring_when_echo_muted() -> void:
	var prev: bool = McpLogBufferScript.console_echo
	McpLogBufferScript.console_echo = false
	var buffer = McpLogBufferScript.new()
	buffer.log("quiet line a")
	buffer.log("quiet line b")
	McpLogBufferScript.console_echo = prev

	## Muting the console must not drop ring entries — the contract that lets
	## negative-path tests assert on buffer contents during a muted run.
	assert_eq(buffer.total_logged(), 2, "both lines recorded despite muted echo")
	var recent: Array = buffer.get_recent(10)
	assert_eq(recent.size(), 2, "ring holds both muted lines")
	assert_true(String(recent[-1]).ends_with("quiet line b"), "last line preserved verbatim")


func test_per_instance_enabled_gates_recording_independently() -> void:
	## `enabled` gates the console print per instance; recording still happens.
	var prev: bool = McpLogBufferScript.console_echo
	McpLogBufferScript.console_echo = false
	var buffer = McpLogBufferScript.new()
	buffer.enabled = false
	buffer.log("still recorded")
	McpLogBufferScript.console_echo = prev

	assert_eq(buffer.total_logged(), 1, "line recorded even with enabled=false")
