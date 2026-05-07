@tool
extends McpTestSuite

## Tests for McpDock._dev_server_btn_state — the three-state label/tooltip
## for the dev-server toggle button. Before this fix, the button only keyed
## on is_dev_server_running() (which returns false when the plugin's own
## managed server is up), so it said "Start Dev Server" while actually
## replacing the managed server with a --reload one. See Windows friction
## from #159/#147 live testing.

const McpDockScript = preload("res://addons/godot_ai/mcp_dock.gd")


func suite_name() -> String:
	return "dock_dev_server_btn"


func test_state_managed_server_running() -> void:
	var state: Dictionary = McpDockScript._dev_server_btn_state(true, false)
	assert_contains(state["text"], "Switch to dev mode", "Managed-running state must not say 'Start'")
	assert_contains(state["tooltip"], "replaces it", "Tooltip must disclose that the managed server is replaced")


func test_state_foreign_dev_server_running() -> void:
	var state: Dictionary = McpDockScript._dev_server_btn_state(false, true)
	assert_contains(state["text"], "Exit dev mode")
	assert_contains(state["tooltip"], "external dev server")


func test_state_nothing_running() -> void:
	var state: Dictionary = McpDockScript._dev_server_btn_state(false, false)
	assert_eq(state["text"], "Start dev server")
	assert_contains(state["tooltip"], "--reload")


func test_state_both_true_prefers_managed() -> void:
	## Defensive: if both signals are somehow true (shouldn't happen given the
	## is_dev_server_running() definition — it requires _server_pid <= 0 — but
	## don't let the UI lie if it does). Managed wins, so clicking swaps rather
	## than claiming to "exit" a dev server that the user's managed server
	## would actually replace.
	var state: Dictionary = McpDockScript._dev_server_btn_state(true, true)
	assert_contains(state["text"], "Switch to dev mode")


## --- _restart_server_btn_state -----------------------------------------

func test_restart_btn_enabled_when_managed_server_running() -> void:
	var state: Dictionary = McpDockScript._restart_server_btn_state(true, false)
	assert_eq(state["enabled"], true,
		"Managed server running must enable the Restart Server button")
	assert_contains(state["tooltip"], "current source",
		"Tooltip must explain the button picks up source changes")


func test_restart_btn_enabled_when_dev_server_running() -> void:
	var state: Dictionary = McpDockScript._restart_server_btn_state(false, true)
	assert_eq(state["enabled"], true,
		"External --reload dev server running must enable the Restart Server button")
	assert_contains(state["tooltip"], "current source")


func test_restart_btn_disabled_when_nothing_running() -> void:
	var state: Dictionary = McpDockScript._restart_server_btn_state(false, false)
	assert_eq(state["enabled"], false,
		"With no godot-ai server on the port, the button must be disabled")
	assert_contains(state["tooltip"], "No godot-ai server is running",
		"Disabled tooltip must explain why so the user isn't left guessing")
