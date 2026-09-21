@tool
extends McpTestSuite

## McpServerState is a stable presentation vocabulary only. Episode-transition
## behavior lives exclusively in test_server_lifecycle.gd.


func suite_name() -> String:
	return "server_state"


func test_wire_values_and_names_remain_stable() -> void:
	assert_eq(McpServerState.UNINITIALIZED, 0)
	assert_eq(McpServerState.READY, 3)
	assert_eq(McpServerState.UNSUPPORTED_CONFIG, 12)
	assert_eq(McpServerState.name_of(McpServerState.UNSUPPORTED_CONFIG), "unsupported_config")
	assert_eq(McpServerState.name_of(McpServerState.READY), "ready")
	assert_eq(McpServerState.name_of(McpServerState.INCOMPATIBLE), "incompatible")
	assert_eq(McpServerState.name_of(McpServerState.PORT_EXCLUDED), "port_excluded")
	assert_eq(McpServerState.name_of(999), "unknown(999)")


func test_diagnostic_projection_groups_only_dock_diagnoses() -> void:
	for diagnostic in [
		McpServerState.CRASHED,
		McpServerState.NO_COMMAND,
		McpServerState.PORT_EXCLUDED,
		McpServerState.INCOMPATIBLE,
		McpServerState.FOREIGN_PORT,
		McpServerState.UNSUPPORTED_CONFIG,
	]:
		assert_true(McpServerState.is_terminal_diagnosis(diagnostic))
	for ordinary in [
		McpServerState.UNINITIALIZED,
		McpServerState.SPAWNING,
		McpServerState.READY,
		McpServerState.STOPPING,
		McpServerState.STOPPED,
	]:
		assert_false(McpServerState.is_terminal_diagnosis(ordinary))


func test_incompatible_and_unsupported_config_block_client_health_projection() -> void:
	assert_true(McpServerState.blocks_client_health(McpServerState.UNSUPPORTED_CONFIG))
	assert_true(McpServerState.blocks_client_health(McpServerState.INCOMPATIBLE))
	assert_false(McpServerState.blocks_client_health(McpServerState.READY))
	assert_false(McpServerState.blocks_client_health(McpServerState.FOREIGN_PORT))
	assert_false(McpServerState.blocks_client_health(McpServerState.CRASHED))
