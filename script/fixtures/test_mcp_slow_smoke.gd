@tool
extends McpTestSuite

## Transport-starvation regression fixture — NOT part of the normal corpus.
## Lives in script/fixtures/ and is copied into test_project/tests/ only by
## script/ci-slow-suite-smoke, which removes it again on exit.
##
## Each test blocks the editor main thread for ~BLOCK_MS; the whole suite
## runs ~50 s — well past the websockets heartbeat window (~20-40 s) that
## used to kill the editor session mid-run (see
## docs/test-run-transport-starvation-plan.md). The blocks sit BETWEEN
## runner checkpoints, so cooperative transport servicing gets a chance to
## answer pings 25 times across the run; on pre-fix plugins the suite
## reliably reproduces the 1011 keepalive disconnect instead.

const BLOCK_MS := 2000


func suite_name() -> String:
	return "mcp_slow_smoke"


func _block_main_thread() -> void:
	var end := Time.get_ticks_msec() + BLOCK_MS
	while Time.get_ticks_msec() < end:
		pass


func _blocked_ok() -> void:
	_block_main_thread()
	assert_true(true, "blocked ~%dms on the main thread" % BLOCK_MS)


func test_block_01() -> void: _blocked_ok()
func test_block_02() -> void: _blocked_ok()
func test_block_03() -> void: _blocked_ok()
func test_block_04() -> void: _blocked_ok()
func test_block_05() -> void: _blocked_ok()
func test_block_06() -> void: _blocked_ok()
func test_block_07() -> void: _blocked_ok()
func test_block_08() -> void: _blocked_ok()
func test_block_09() -> void: _blocked_ok()
func test_block_10() -> void: _blocked_ok()
func test_block_11() -> void: _blocked_ok()
func test_block_12() -> void: _blocked_ok()
func test_block_13() -> void: _blocked_ok()
func test_block_14() -> void: _blocked_ok()
func test_block_15() -> void: _blocked_ok()
func test_block_16() -> void: _blocked_ok()
func test_block_17() -> void: _blocked_ok()
func test_block_18() -> void: _blocked_ok()
func test_block_19() -> void: _blocked_ok()
func test_block_20() -> void: _blocked_ok()
func test_block_21() -> void: _blocked_ok()
func test_block_22() -> void: _blocked_ok()
func test_block_23() -> void: _blocked_ok()
func test_block_24() -> void: _blocked_ok()
func test_block_25() -> void: _blocked_ok()
