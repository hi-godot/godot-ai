@tool
extends McpTestSuite

## Truth-table tests for McpDock's static dev-section button helpers:
##  - `_dev_primary_btn_state(has_managed, dev_running)` — adapts the
##    "Restart Dev Server" / "Start Dev Server" label + tooltip.
##  - `_dev_stop_btn_state(dev_running)` — gates the "✕" stop affordance.
## Static helpers so the truth table can be verified without a real plugin.

const McpDockScript = preload("res://addons/godot_ai/mcp_dock.gd")


func suite_name() -> String:
	return "dock_dev_server_btn"


# --- _dev_primary_btn_state ---------------------------------------------

func test_primary_label_says_restart_when_managed_running() -> void:
	var state: Dictionary = McpDockScript._dev_primary_btn_state(true, false)
	assert_eq(state["text"], "Restart Dev Server",
		"Managed running means click will kill+respawn — label says Restart")
	assert_contains(state["tooltip"], "Kill",
		"Tooltip discloses the kill+respawn action")


func test_primary_label_says_restart_when_dev_running() -> void:
	var state: Dictionary = McpDockScript._dev_primary_btn_state(false, true)
	assert_eq(state["text"], "Restart Dev Server",
		"Dev server running means click will kill+respawn — label says Restart")
	assert_contains(state["tooltip"], "Kill")


func test_primary_label_says_start_when_nothing_running() -> void:
	var state: Dictionary = McpDockScript._dev_primary_btn_state(false, false)
	assert_eq(state["text"], "Start Dev Server",
		"Nothing running means click is a fresh spawn — label adapts to Start")
	assert_contains(state["tooltip"], "--reload",
		"Tooltip explains the dev-server flavor")


func test_primary_label_prefers_restart_when_both_signals_true() -> void:
	## Defensive: is_dev_server_running()'s definition makes this combo
	## impossible (it requires _server_pid <= 0), but if it ever lands the
	## UI must read as Restart, not Start.
	var state: Dictionary = McpDockScript._dev_primary_btn_state(true, true)
	assert_eq(state["text"], "Restart Dev Server")


# --- _dev_stop_btn_state ------------------------------------------------

func test_stop_btn_enabled_when_dev_running() -> void:
	var state: Dictionary = McpDockScript._dev_stop_btn_state(true)
	assert_eq(state["enabled"], true,
		"Stop button enables only when there's a dev server to kill")
	assert_contains(state["tooltip"], "Stop")


func test_stop_btn_disabled_when_no_dev_server() -> void:
	var state: Dictionary = McpDockScript._dev_stop_btn_state(false)
	assert_eq(state["enabled"], false,
		"No dev server means nothing to stop — button stays disabled")
	assert_contains(state["tooltip"], "No --reload",
		"Tooltip explains why so the user isn't left guessing")
