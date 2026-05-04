@tool
extends McpTestSuite

## Direct unit coverage for `McpClientRefreshState`. The dock collapsed
## seven booleans into this enum + a pair of pending-request flags;
## the transition table is the only thing keeping a forced refresh from
## skipping the timeout-abandon path.

func suite_name() -> String:
	return "client_refresh_state"


func test_default_state_is_idle() -> void:
	assert_eq(McpClientRefreshState.IDLE, 0,
		"IDLE constant must stay 0 — dock fields default-initialise to it")


func test_name_of_returns_human_label() -> void:
	assert_eq(McpClientRefreshState.name_of(McpClientRefreshState.RUNNING), "running")
	assert_eq(
		McpClientRefreshState.name_of(McpClientRefreshState.RUNNING_TIMED_OUT),
		"running_timed_out"
	)
	assert_eq(
		McpClientRefreshState.name_of(McpClientRefreshState.DEFERRED_FOR_FILESYSTEM),
		"deferred_for_filesystem"
	)


func test_has_worker_alive_only_for_running_states() -> void:
	assert_true(McpClientRefreshState.has_worker_alive(McpClientRefreshState.RUNNING))
	assert_true(McpClientRefreshState.has_worker_alive(McpClientRefreshState.RUNNING_TIMED_OUT))
	assert_false(McpClientRefreshState.has_worker_alive(McpClientRefreshState.IDLE))
	assert_false(McpClientRefreshState.has_worker_alive(
		McpClientRefreshState.DEFERRED_FOR_FILESYSTEM))
	assert_false(McpClientRefreshState.has_worker_alive(McpClientRefreshState.SHUTTING_DOWN))


func test_is_blocked_for_spawn_only_during_shutdown() -> void:
	## SHUTTING_DOWN is sticky; no spawn paths should fire while it's set.
	assert_true(McpClientRefreshState.is_blocked_for_spawn(McpClientRefreshState.SHUTTING_DOWN))
	assert_false(McpClientRefreshState.is_blocked_for_spawn(McpClientRefreshState.IDLE))
	assert_false(McpClientRefreshState.is_blocked_for_spawn(McpClientRefreshState.RUNNING))


func test_should_show_checking_badge_during_running_states() -> void:
	assert_true(McpClientRefreshState.should_show_checking_badge(McpClientRefreshState.RUNNING))
	assert_true(McpClientRefreshState.should_show_checking_badge(
		McpClientRefreshState.RUNNING_TIMED_OUT))
	assert_false(McpClientRefreshState.should_show_checking_badge(McpClientRefreshState.IDLE))


# ----- transition table -------------------------------------------------

func test_idle_can_start_or_defer() -> void:
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.IDLE, McpClientRefreshState.RUNNING))
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.IDLE, McpClientRefreshState.DEFERRED_FOR_FILESYSTEM))


func test_running_can_complete_or_time_out() -> void:
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.RUNNING, McpClientRefreshState.IDLE))
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.RUNNING, McpClientRefreshState.RUNNING_TIMED_OUT))


func test_timed_out_can_drop_back_to_running_or_idle() -> void:
	## Drop to RUNNING when a force-refresh abandons the orphan and starts
	## a new sweep; drop to IDLE when the late result lands.
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.RUNNING_TIMED_OUT, McpClientRefreshState.RUNNING))
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.RUNNING_TIMED_OUT, McpClientRefreshState.IDLE))


func test_deferred_can_resume_or_collapse_back_to_idle() -> void:
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.DEFERRED_FOR_FILESYSTEM, McpClientRefreshState.RUNNING))
	assert_true(McpClientRefreshState.can_transition(
		McpClientRefreshState.DEFERRED_FOR_FILESYSTEM, McpClientRefreshState.IDLE))


func test_shutting_down_is_sticky() -> void:
	for target in [
		McpClientRefreshState.IDLE,
		McpClientRefreshState.RUNNING,
		McpClientRefreshState.DEFERRED_FOR_FILESYSTEM,
	]:
		assert_false(McpClientRefreshState.can_transition(
			McpClientRefreshState.SHUTTING_DOWN, target),
			"SHUTTING_DOWN -> %s must be rejected"
				% McpClientRefreshState.name_of(target))


func test_anything_can_transition_to_shutting_down() -> void:
	## Drain happens from any state when the dock is being torn down or a
	## self-update install starts.
	for source in [
		McpClientRefreshState.IDLE,
		McpClientRefreshState.RUNNING,
		McpClientRefreshState.RUNNING_TIMED_OUT,
		McpClientRefreshState.DEFERRED_FOR_FILESYSTEM,
	]:
		assert_true(McpClientRefreshState.can_transition(
			source, McpClientRefreshState.SHUTTING_DOWN),
			"%s -> SHUTTING_DOWN must be legal"
				% McpClientRefreshState.name_of(source))


func test_self_transition_is_legal() -> void:
	for s in [
		McpClientRefreshState.IDLE,
		McpClientRefreshState.RUNNING,
		McpClientRefreshState.SHUTTING_DOWN,
	]:
		assert_true(McpClientRefreshState.can_transition(s, s))
