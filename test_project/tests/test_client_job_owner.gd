@tool
extends McpTestSuite

## Lifecycle coverage for `ClientJobOwner`'s processing gate.
##
## `_process` is the only place a finished worker Thread is ever joined:
## `_poll_refresh` is the sole exit from RUNNING, `_poll_actions` the sole exit
## from an in-flight client action, and `_check_action_timeouts` the sole
## watchdog. If processing is off while a worker is alive, that worker runs to
## completion and is never realised — the status sweep stays RUNNING forever
## (which also disables Configure all) and a Configure row keeps its last
## published phase label. Nothing recovers short of an editor restart, which
## lands in the same state.
##
## The ordering that matters is not obvious: the composition root adds this
## node, wires it, and calls `activate()` all inside the plugin's
## `_enter_tree`, and Godot defers a child's `_ready` until the parent's tree
## entry returns. `_ready` therefore runs LAST, after activation — so a
## `_ready` that recomputes the gate from in-flight work alone silently
## cancels the activation that already happened.

const ClientJobOwner := preload("res://addons/godot_ai/utils/client_job_owner.gd")


func suite_name() -> String:
	return "client_job_owner"


## Reproduce the real startup order: the owner is parented while the parent is
## still outside the tree (so `_ready` is deferred exactly as it is inside
## `EditorPlugin._enter_tree`), activated, and only then does the tree entry
## complete and fire `_ready`.
func _enter_tree_like_the_plugin(activate_before_ready: bool) -> Dictionary:
	var parent := Node.new()
	var owner: Node = ClientJobOwner.new()
	## Parent is out of tree, so this does NOT fire `_ready` yet.
	parent.add_child(owner)
	if activate_before_ready:
		owner.activate()
	var root := (Engine.get_main_loop() as SceneTree).root
	## Tree entry completes here; `_ready` fires during this call.
	root.add_child(parent)
	return {"parent": parent, "owner": owner, "root": root}


func _tear_down(context: Dictionary) -> void:
	var parent: Node = context["parent"]
	(context["root"] as Node).remove_child(parent)
	parent.free()


func test_ready_after_activate_keeps_processing() -> void:
	## Regression: `_ready` used to recompute the gate from in-flight work only,
	## so an owner activated during `_enter_tree` had processing switched back
	## off the moment its deferred `_ready` ran. Every later refresh and client
	## action then completed on its worker and was never joined.
	var context := _enter_tree_like_the_plugin(true)
	var owner: Node = context["owner"]
	assert_true(
		owner.is_processing(),
		"activate() ran before the deferred _ready(); _ready must not cancel the poll loop"
	)
	_tear_down(context)


func test_ready_without_activation_stays_inert() -> void:
	## The other half of the contract: construction is inert. A script that
	## defines `_process` is processing by default, so an owner that was never
	## activated and has no work in flight still has to switch it off.
	var context := _enter_tree_like_the_plugin(false)
	var owner: Node = context["owner"]
	assert_false(
		owner.is_processing(),
		"An unactivated owner with no work in flight must not poll"
	)
	_tear_down(context)


func test_ready_with_work_in_flight_keeps_processing() -> void:
	## The post-update migration path: `begin_post_update_repin` starts its
	## worker before this node is ready, so `_ready` must not cancel the poll
	## for a thread that is already running. This case was already correct and
	## is why the bug only reproduced on ordinary starts.
	var parent := Node.new()
	var owner: Node = ClientJobOwner.new()
	parent.add_child(owner)
	## Stand in for a live action slot without spawning a real Thread —
	## `_has_work_in_flight()` only asks whether the slot table is populated.
	owner._action_threads["claude_code"] = null
	var root := (Engine.get_main_loop() as SceneTree).root
	root.add_child(parent)
	assert_true(
		owner.is_processing(),
		"_ready() must keep polling for work that was admitted before it ran"
	)
	owner._action_threads.clear()
	root.remove_child(parent)
	parent.free()


func test_activate_is_inert_after_shutdown() -> void:
	## `quiesce()` makes SHUTTING_DOWN sticky; a late activate() must not
	## reopen the owner or restart its poll loop behind a drained worker pool.
	var owner: Node = ClientJobOwner.new()
	owner.quiesce()
	owner.activate()
	assert_false(
		owner.is_processing(),
		"activate() must stay inert once the owner has been quiesced"
	)
	assert_false(owner.snapshot().get("accepting_work", true))
	owner.free()


class ControlledOwner:
	extends "res://addons/godot_ai/utils/client_job_owner.gd"
	var release := Semaphore.new()
	var outcome := {"status": "ok"}
	func _run_action(client_id: String, action: String, _url: String, _context: Dictionary, _prewarm: bool) -> Dictionary:
		release.wait()
		return {"client_id": client_id, "action": action, "result": outcome.duplicate(true), "prewarm": {}}


func _wait_for_completions(owner: Node, results: Array, count: int) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while results.size() < count and Time.get_ticks_msec() < deadline:
		owner._process(0.0)
		OS.delay_usec(100)


func test_ui_actions_queue_and_mcp_busy_never_joins_the_queue() -> void:
	if McpClientMutationLock.is_locked():
		skip("a real client mutation safety claim already exists")
		return
	var owner := ControlledOwner.new()
	var results: Array = []
	owner.action_completed.connect(func(id: String, action: String, result: Dictionary, _prewarm: Dictionary) -> void:
		results.append({"id": id, "action": action, "result": result})
	)
	(Engine.get_main_loop() as SceneTree).root.add_child(owner)
	owner.activate()
	assert_true(owner.request_action("codex", "configure"), "first action must be admitted: " + str(owner.snapshot()))
	assert_true(owner.request_action("cursor", "remove"), "second action must be queued: " + str(owner.snapshot()))
	assert_false(owner.request_action("cursor", "configure"), "duplicate queued client is refused")
	assert_eq(owner._action_threads.size(), 1)
	assert_eq(owner.snapshot().action_phases.get("cursor"), "queued")
	var busy := owner.request_mcp_action("not-admitted", "grok", "configure")
	assert_false(busy.ok)
	assert_contains(str(busy.error), "Retry")
	assert_false(busy.has("deferred_timeout_ms"))
	owner._report_action_timeout("codex", 75000)
	assert_eq(owner._action_threads.size(), 1, "timeout cannot release an unjoined worker")
	assert_eq(owner.snapshot().action_phases.get("cursor"), "queued")
	owner.release.post()
	_wait_for_completions(owner, results, 1)
	owner.release.post()
	_wait_for_completions(owner, results, 2)
	owner.quiesce()
	owner.free()
	assert_eq(results.size(), 2)
	if results.size() == 2:
		assert_eq(results[0].id, "codex")
		assert_eq(results[1].id, "cursor")
		assert_eq(results[1].action, "remove")
		assert_eq(results[1].result.status, "ok")


func test_quiesce_discards_queued_actions_without_running_them_after_resume() -> void:
	if McpClientMutationLock.is_locked():
		skip("a real client mutation safety claim already exists")
		return
	var owner := ControlledOwner.new()
	var results: Array = []
	owner.action_completed.connect(func(id: String, _action: String, result: Dictionary, _prewarm: Dictionary) -> void:
		results.append({"id": id, "result": result})
	)
	(Engine.get_main_loop() as SceneTree).root.add_child(owner)
	owner.activate()
	assert_true(owner.request_action("codex", "configure"), "first action must be admitted: " + str(owner.snapshot()))
	assert_true(owner.request_action("cursor", "remove"), "second action must be queued: " + str(owner.snapshot()))
	owner.release.post()
	var drained := owner.quiesce()
	assert_true(drained.ok, "controlled worker must drain safely: " + str(drained))
	assert_eq(owner.snapshot().busy_actions, [])
	owner.resume_after_quiesce()
	owner._process(0.0)
	assert_eq(owner.snapshot().busy_actions, [])
	owner.quiesce()
	owner.free()
	assert_eq(results.size(), 1)
	if results.size() == 1:
		assert_eq(results[0].id, "cursor")
		assert_eq(results[0].result.status, "error")
		assert_contains(str(results[0].result.message), "cancelled before it started")


func test_unproven_worker_blocks_queued_and_other_client_mutations() -> void:
	_assert_unsafe_result_blocks_queue("termination_failed")


func test_failed_lock_release_blocks_queued_and_other_client_mutations() -> void:
	_assert_unsafe_result_blocks_queue("mutation_lock_release_failed")


func _assert_unsafe_result_blocks_queue(unsafe_flag: String) -> void:
	if McpClientMutationLock.is_locked():
		skip("a real client mutation safety claim already exists")
		return
	var previous: Variant = Engine.get_meta(ClientJobOwner.MUTATION_UNPROVEN_META, {})
	var owner := ControlledOwner.new()
	var results: Array = []
	owner.outcome = {"status": "error", unsafe_flag: true, "message": "unsafe worker"}
	owner.action_completed.connect(func(id: String, _action: String, result: Dictionary, _prewarm: Dictionary) -> void:
		results.append({"id": id, "result": result})
	)
	(Engine.get_main_loop() as SceneTree).root.add_child(owner)
	owner.activate()
	assert_true(owner.request_action("codex", "configure"), "first action must be admitted: " + str(owner.snapshot()))
	assert_true(owner.request_action("cursor", "remove"), "second action must be queued: " + str(owner.snapshot()))
	owner.release.post()
	_wait_for_completions(owner, results, 2)
	var blocked := owner.request_mcp_action("also-blocked", "grok", "configure")
	owner.release.post()
	var drained := owner.quiesce()
	owner.free()
	Engine.set_meta(ClientJobOwner.MUTATION_UNPROVEN_META, previous)
	assert_false(blocked.ok)
	assert_true(bool(blocked.get("termination_failed", false)))
	assert_false(drained.ok)
	assert_eq(results.size(), 2)
	if results.size() == 2:
		assert_eq(results[0].id, "codex")
		assert_eq(results[1].id, "cursor")
		assert_eq(results[1].result.status, "error")
		assert_contains(str(results[1].result.message), "safety-locked")
