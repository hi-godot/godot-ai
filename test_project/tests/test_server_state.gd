@tool
extends McpTestSuite

## Direct unit coverage for `McpServerState`. The transition table is the
## contract between `McpServerLifecycleManager` and the dock; if any
## transition flips legality the manager's first-writer-wins guarantee
## stops protecting the dock from a spurious CRASHED clobber.

func suite_name() -> String:
	return "server_state"


func test_default_state_is_uninitialized() -> void:
	assert_eq(McpServerState.UNINITIALIZED, 0, "default constant must stay 0 for stable wire shape")


func test_name_of_returns_human_label() -> void:
	assert_eq(McpServerState.name_of(McpServerState.READY), "ready")
	assert_eq(McpServerState.name_of(McpServerState.INCOMPATIBLE), "incompatible")
	assert_eq(McpServerState.name_of(McpServerState.PORT_EXCLUDED), "port_excluded")


func test_name_of_handles_unknown_value() -> void:
	## Defensive: a future enum addition that the formatter doesn't know
	## yet must produce a readable diagnostic, not crash.
	assert_eq(McpServerState.name_of(999), "unknown(999)")


func test_is_terminal_diagnosis_covers_all_terminal_states() -> void:
	for terminal in [
		McpServerState.CRASHED,
		McpServerState.NO_COMMAND,
		McpServerState.PORT_EXCLUDED,
		McpServerState.INCOMPATIBLE,
		McpServerState.FOREIGN_PORT,
	]:
		assert_true(McpServerState.is_terminal_diagnosis(terminal),
			"%s must be terminal" % McpServerState.name_of(terminal))


func test_is_terminal_diagnosis_excludes_non_diagnostic_states() -> void:
	for non_terminal in [
		McpServerState.UNINITIALIZED,
		McpServerState.SPAWNING,
		McpServerState.AWAITING_VERSION,
		McpServerState.READY,
		McpServerState.GUARDED,
		McpServerState.STOPPING,
		McpServerState.STOPPED,
	]:
		assert_false(McpServerState.is_terminal_diagnosis(non_terminal),
			"%s must not be terminal" % McpServerState.name_of(non_terminal))


func test_is_healthy_only_for_ready() -> void:
	assert_true(McpServerState.is_healthy(McpServerState.READY))
	assert_false(McpServerState.is_healthy(McpServerState.AWAITING_VERSION))
	assert_false(McpServerState.is_healthy(McpServerState.SPAWNING))
	assert_false(McpServerState.is_healthy(McpServerState.UNINITIALIZED))


func test_blocks_client_health_only_for_incompatible() -> void:
	## Dock's `_server_blocks_client_health` gates the client-row red state
	## on this — narrowing it to only INCOMPATIBLE keeps SPAWNING / FOREIGN_PORT
	## from misclassifying the dock as broken.
	assert_true(McpServerState.blocks_client_health(McpServerState.INCOMPATIBLE))
	assert_false(McpServerState.blocks_client_health(McpServerState.READY))
	assert_false(McpServerState.blocks_client_health(McpServerState.FOREIGN_PORT))
	assert_false(McpServerState.blocks_client_health(McpServerState.CRASHED))


# ----- transition table coverage ----------------------------------------

func test_self_transition_is_legal() -> void:
	## Every state -> itself is legal so callers can re-assert without
	## branching on the current value.
	for s in [
		McpServerState.UNINITIALIZED,
		McpServerState.READY,
		McpServerState.INCOMPATIBLE,
	]:
		assert_true(McpServerState.can_transition(s, s),
			"%s -> self must be legal" % McpServerState.name_of(s))


func test_uninitialized_can_transition_to_any_diagnostic_state() -> void:
	for target in [
		McpServerState.SPAWNING,
		McpServerState.READY,
		McpServerState.CRASHED,
		McpServerState.NO_COMMAND,
		McpServerState.PORT_EXCLUDED,
		McpServerState.GUARDED,
		McpServerState.INCOMPATIBLE,
	]:
		assert_true(McpServerState.can_transition(McpServerState.UNINITIALIZED, target),
			"UNINITIALIZED -> %s must be legal at boot" % McpServerState.name_of(target))


func test_terminal_diagnoses_freeze_forward_transitions() -> void:
	## First-writer-wins: once we've latched a terminal diagnosis, the
	## manager refuses any non-stop transition out of it. This is the
	## contract that stops a late watch-loop CRASHED from clobbering an
	## earlier proactive PORT_EXCLUDED.
	for stuck in [
		McpServerState.CRASHED,
		McpServerState.NO_COMMAND,
		McpServerState.PORT_EXCLUDED,
		McpServerState.INCOMPATIBLE,
	]:
		for target in [
			McpServerState.READY,
			McpServerState.SPAWNING,
			McpServerState.AWAITING_VERSION,
		]:
			assert_false(McpServerState.can_transition(stuck, target),
				"%s -> %s must be rejected (first-writer-wins)" % [
					McpServerState.name_of(stuck),
					McpServerState.name_of(target),
				])


func test_terminal_diagnoses_allow_stop_transitions() -> void:
	## Stop is always legal — teardown / install reload short-circuits any
	## in-flight state, including terminal diagnoses.
	for stuck in [
		McpServerState.CRASHED,
		McpServerState.NO_COMMAND,
		McpServerState.PORT_EXCLUDED,
		McpServerState.INCOMPATIBLE,
	]:
		assert_true(McpServerState.can_transition(stuck, McpServerState.STOPPING),
			"%s -> STOPPING must be legal" % McpServerState.name_of(stuck))


func test_spawning_progresses_to_awaiting_or_crashed() -> void:
	assert_true(McpServerState.can_transition(
		McpServerState.SPAWNING, McpServerState.AWAITING_VERSION))
	assert_true(McpServerState.can_transition(
		McpServerState.SPAWNING, McpServerState.READY))
	assert_true(McpServerState.can_transition(
		McpServerState.SPAWNING, McpServerState.CRASHED))


func test_awaiting_version_resolves_to_ready_or_incompatible() -> void:
	assert_true(McpServerState.can_transition(
		McpServerState.AWAITING_VERSION, McpServerState.READY))
	assert_true(McpServerState.can_transition(
		McpServerState.AWAITING_VERSION, McpServerState.INCOMPATIBLE))


func test_foreign_port_clears_to_ready_after_handshake() -> void:
	assert_true(McpServerState.can_transition(
		McpServerState.FOREIGN_PORT, McpServerState.AWAITING_VERSION))
	assert_true(McpServerState.can_transition(
		McpServerState.FOREIGN_PORT, McpServerState.READY))
	assert_true(McpServerState.can_transition(
		McpServerState.FOREIGN_PORT, McpServerState.INCOMPATIBLE))


func test_guarded_is_sticky_until_stop() -> void:
	assert_false(McpServerState.can_transition(
		McpServerState.GUARDED, McpServerState.READY))
	assert_false(McpServerState.can_transition(
		McpServerState.GUARDED, McpServerState.SPAWNING))
	## Stop is always legal.
	assert_true(McpServerState.can_transition(
		McpServerState.GUARDED, McpServerState.STOPPING))


func test_stopped_can_restart() -> void:
	## A STOPPED -> SPAWNING transition is the recover-and-restart click
	## path; locking it in lets force_restart_server walk through STOPPED
	## without tripping the validator.
	assert_true(McpServerState.can_transition(
		McpServerState.STOPPED, McpServerState.SPAWNING))
	assert_true(McpServerState.can_transition(
		McpServerState.STOPPED, McpServerState.UNINITIALIZED))
