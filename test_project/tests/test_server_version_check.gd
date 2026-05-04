@tool
extends McpTestSuite

## Direct seam coverage for `McpServerVersionCheck`. The state machine
## was previously inlined in plugin.gd as four overlapping booleans
## (`_awaiting_server_version`, `_server_version_deadline_ms`, plus
## `_on_server_version_verified` / `_on_server_version_unverified`);
## PR 6 (#297) extracted it into its own class and the manager owns
## the result transitions.

const McpServerVersionCheckScript := preload(
	"res://addons/godot_ai/utils/server_version_check.gd"
)
const McpServerLifecycleManagerScript := preload(
	"res://addons/godot_ai/utils/server_lifecycle.gd"
)


## Stub manager — exposes the two callbacks the version check fires
## (handle_server_version_verified / handle_server_version_unverified)
## without dragging in the rest of the lifecycle plumbing. State is the
## raw `_server_state` int so transition_state() asserts are testable.
class _ManagerStub extends RefCounted:
	var verified_calls: Array[Dictionary] = []
	var unverified_calls: Array[String] = []
	var transitions: Array[int] = []
	var _server_state: int = McpServerState.UNINITIALIZED

	func handle_server_version_verified(expected: String, actual: String) -> void:
		verified_calls.append({"expected": expected, "actual": actual})

	func handle_server_version_unverified(expected: String) -> void:
		unverified_calls.append(expected)

	func transition_state(target: int) -> bool:
		transitions.append(target)
		_server_state = target
		return true


class _FakeConnection extends RefCounted:
	var is_connected := false
	var server_version := ""


func suite_name() -> String:
	return "server_version_check"


func test_arm_marks_active_without_transitioning_state() -> void:
	## Arming must NOT change the manager's state — the version check runs
	## concurrently with whatever spawn-state was latched (e.g. FOREIGN_PORT
	## during adoption confirmation). Result transitions land on
	## handle_server_version_verified / _unverified once the handshake (or
	## its deadline) arrives.
	var manager := _ManagerStub.new()
	var conn := _FakeConnection.new()
	var check = McpServerVersionCheckScript.new(manager)

	check.arm(conn, "2.3.0")

	assert_true(check.is_active(), "arm() must mark the check active")
	assert_eq(manager.transitions.size(), 0,
		"arm() must not transition manager state — that would clobber "
		+ "FOREIGN_PORT during adoption-confirmation")


func test_disarm_resets_active_without_transitioning_state() -> void:
	## Disarm is "I'm done watching, but the manager already moved on";
	## the seam must not fire a redundant state transition. It must
	## also drop the connection reference — the plugin can spend most
	## of its life with the version check disarmed, and `_connection`
	## is a Node that may be queue_free'd by `_exit_tree`.
	var manager := _ManagerStub.new()
	var conn := _FakeConnection.new()
	var check = McpServerVersionCheckScript.new(manager)

	check.arm(conn, "2.3.0")

	check.disarm()

	assert_false(check.is_active())
	assert_eq(manager.transitions.size(), 0,
		"disarm must not transition state — caller already did")
	## Tick after disarm must not crash on the released connection
	## reference. With `_connection` nulled, the early-return in
	## `tick()` keeps the seam dormant until the next arm() reseats it.
	var fired := check.tick(Time.get_ticks_msec())
	assert_false(fired, "disarmed seam must stay dormant on tick")


func test_tick_noop_until_connection_opens() -> void:
	## The deadline only starts when the WebSocket actually opens — uvx
	## cold-starts can take 30s to bind, and we can't count that against
	## the handshake budget.
	var manager := _ManagerStub.new()
	var conn := _FakeConnection.new()
	var check = McpServerVersionCheckScript.new(manager)

	check.arm(conn, "2.3.0")
	var fired := check.tick(Time.get_ticks_msec() + 60 * 1000)

	assert_false(fired, "tick must not fire while connection is closed")
	assert_eq(manager.verified_calls.size(), 0)
	assert_eq(manager.unverified_calls.size(), 0)
	assert_true(check.is_active(), "still waiting — must stay armed")


func test_tick_completes_with_version_when_handshake_arrives() -> void:
	var manager := _ManagerStub.new()
	var conn := _FakeConnection.new()
	var check = McpServerVersionCheckScript.new(manager)

	check.arm(conn, "2.3.0")
	conn.is_connected = true
	conn.server_version = "2.3.0"
	var fired := check.tick(Time.get_ticks_msec())

	assert_true(fired, "tick must fire on first version-available frame")
	assert_eq(manager.verified_calls.size(), 1)
	assert_eq(manager.verified_calls[0]["expected"], "2.3.0")
	assert_eq(manager.verified_calls[0]["actual"], "2.3.0")
	assert_false(check.is_active(), "completion must auto-disarm")


func test_tick_fires_unverified_after_deadline() -> void:
	var manager := _ManagerStub.new()
	var conn := _FakeConnection.new()
	var check = McpServerVersionCheckScript.new(manager)

	check.arm(conn, "2.3.0")
	conn.is_connected = true
	## First tick latches the deadline at now + TIMEOUT_MS.
	check.tick(0)
	## Second tick well past the deadline triggers the timeout.
	var fired := check.tick(McpServerVersionCheckScript.TIMEOUT_MS + 1000)

	assert_true(fired, "tick must fire on deadline expiry")
	assert_eq(manager.unverified_calls.size(), 1)
	assert_eq(manager.unverified_calls[0], "2.3.0")
	assert_false(check.is_active())


func test_arm_with_mismatched_version_drives_through_manager() -> void:
	## The version mismatch decision is the manager's responsibility — the
	## seam just hands the verified version through. This test pins the
	## hand-off direction so a future refactor can't sneak in a bypass.
	var manager := _ManagerStub.new()
	var conn := _FakeConnection.new()
	var check = McpServerVersionCheckScript.new(manager)

	check.arm(conn, "2.3.0")
	conn.is_connected = true
	conn.server_version = "1.2.10"
	check.tick(0)

	assert_eq(manager.verified_calls.size(), 1,
		"all verified handshakes go through handle_server_version_verified, "
		+ "even mismatched ones — the manager decides compatibility")
	assert_eq(manager.verified_calls[0]["actual"], "1.2.10")


func test_lifecycle_manager_arm_version_check_attaches_seam() -> void:
	## End-to-end seam wiring on the real manager: arming via the manager
	## must construct the version check lazily and register it for tick().
	## The manager's spawn-state stays at whatever the caller had — arming
	## doesn't transition state, only the result handlers do.
	var host = _make_minimal_host()
	var manager = McpServerLifecycleManagerScript.new(host)
	var conn := _FakeConnection.new()

	assert_eq(manager.get_version_check(), null,
		"version check must be lazily constructed")

	manager.arm_version_check(conn, "2.3.0")

	assert_true(manager.get_version_check() != null,
		"arm_version_check must construct the seam")
	assert_true(manager.is_awaiting_server_version(),
		"manager must report awaiting after arm")
	assert_eq(manager.get_state(), McpServerState.UNINITIALIZED,
		"arm must not change the spawn-state — concurrent with whatever "
		+ "the caller had latched")
	host.free()


func _make_minimal_host():
	var GodotAiPlugin := load("res://addons/godot_ai/plugin.gd")
	return GodotAiPlugin.new()
