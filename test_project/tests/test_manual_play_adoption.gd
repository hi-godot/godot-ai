@tool
extends McpTestSuite

const StubSessionPlugin := preload("res://tests/stub_debugger_session_plugin.gd")

## Repro for the manual-play adoption gap (observed live 2026-08-26).
##
## Pressing Play (F5/F6) in the editor can leave the MCP runtime bridge dead:
## game_eval, game logs and runtime inspection silently never work for that
## run. `begin_game_run()` has exactly ONE caller -- project_handler.gd's
## `project_run` -- so an editor-started play depends entirely on the adoption
## branch in `_setup_session`, which fires only when
## `EditorInterface.is_playing_scene()` is ALREADY true at the instant the
## debugger session attaches. When the session attaches first, the run is
## never adopted and the game helper's boot beacon is discarded, while
## game_eval waits forever for the hello that was thrown away:
##
##     MCP | [event] play_state_changed -> playing
##     MCP | [debug] ignored mcp:hello with no active game run
##     MCP | [debug] ignored mcp:hello with no active game run
##     MCP | [debug] waiting for game_helper hello before eval

func suite_name() -> String:
	return "manual_play_adoption"


func _plugin_with_log() -> McpDebuggerPlugin:
	var plugin := StubSessionPlugin.new()
	plugin._log_buffer = McpLogBuffer.new()
	return plugin


func test_manual_play_adopted_when_play_state_lands_before_hello() -> void:
	## The reported ordering: session attaches first (adoption gate declines
	## because is_playing_scene() is not yet true), the editor then flips play
	## state, and only afterwards does the game announce itself.
	var plugin := _plugin_with_log()
	assert_false(EditorInterface.is_playing_scene(),
		"precondition: suite runs with no game playing, matching the pre-play-state instant")
	plugin._setup_session(1)
	assert_false(plugin._game_run_active,
		"characterization: _setup_session cannot adopt before the play-state flip")
	plugin.note_editor_play_started()
	assert_true(plugin._game_run_active,
		"the play-state edge adopts the run the session attach could not")
	var consumed := plugin._capture("mcp:hello", [], 1)
	assert_true(consumed, "the hello is consumed off the debugger wire")
	assert_true(plugin.is_game_capture_ready(),
		"a manually started play must be adopted so game_eval / game logs work")


func test_manual_play_hello_arriving_before_adoption_is_replayed() -> void:
	## The reverse ordering: the beacon beats the play-state edge. It is a
	## one-shot, so it must be held and replayed on adoption rather than
	## dropped -- the game never sends a second one.
	var plugin := _plugin_with_log()
	plugin._setup_session(1)
	var consumed := plugin._capture("mcp:hello", [], 1)
	assert_true(consumed, "the early hello is consumed off the wire")
	assert_false(plugin.is_game_capture_ready(),
		"the bridge cannot be ready before the run is adopted")
	plugin.note_editor_play_started()
	assert_true(plugin.is_game_capture_ready(),
		"the held beacon must be replayed on adoption, not discarded")


func test_held_hello_is_not_carried_into_a_later_run() -> void:
	## A beacon held for an adoption that never happened must not make some
	## later, unrelated run look live without its own hello.
	var plugin := _plugin_with_log()
	plugin._setup_session(1)
	plugin._capture("mcp:hello", [], 1)
	plugin.note_editor_play_stopped()
	plugin.note_editor_play_started()
	assert_false(plugin.is_game_capture_ready(),
		"a stale held beacon must be cleared when the play session ends")


func test_play_started_edge_does_not_disturb_an_mcp_started_run() -> void:
	## project_run adopts via begin_game_run(); the play-state edge then fires
	## for the same launch and must be inert -- re-adopting would bump the run
	## token and invalidate the hello that already landed.
	var plugin := _plugin_with_log()
	plugin._setup_session(1)
	plugin.begin_game_run(0, true)
	plugin._capture("mcp:hello", [], 1)
	var token_before: int = plugin._game_run_token
	plugin.note_editor_play_started()
	assert_eq(plugin._game_run_token, token_before,
		"an already-adopted run must not be re-adopted by the play-state edge")
	assert_true(plugin.is_game_capture_ready(),
		"the MCP-started run stays live across the play-state edge")


func test_mcp_started_run_accepts_the_same_hello() -> void:
	## Control: identical to the case above except for begin_game_run(), the one
	## call project_run makes. This is why launching through MCP always works.
	var plugin := _plugin_with_log()
	plugin._setup_session(1)
	plugin.begin_game_run(0, true)
	var consumed := plugin._capture("mcp:hello", [], 1)
	assert_true(consumed, "the hello is consumed off the debugger wire")
	assert_true(plugin.is_game_capture_ready(),
		"project_run's begin_game_run() makes the identical hello land")


func test_hello_from_another_debugger_session_is_never_held() -> void:
	## #891 review: the beacon must be rejected on ARRIVAL, not at replay time.
	## Adoption clears _game_session_id, so a beacon validated only on replay
	## could never be rejected -- another game's hello would mark this run ready
	## before its own helper had registered, letting runtime tools skip the
	## readiness wait.
	var plugin := _plugin_with_log()
	plugin._setup_session(1)
	var consumed := plugin._capture("mcp:hello", [], 2)
	assert_true(consumed, "the foreign hello is still consumed off the wire")
	assert_eq(plugin._pending_hello_session_id, -1,
		"a beacon from a session other than the attached one must not be held")
	plugin.note_editor_play_started()
	assert_false(plugin.is_game_capture_ready(),
		"adoption must not go ready on another debugger session's beacon")


func test_accepted_hello_binds_the_run_to_its_debugger_session() -> void:
	## Adoption clears _game_session_id; accepting a beacon re-binds the run to
	## the game that announced itself, so later staleness checks have something
	## to compare against instead of silently passing.
	var plugin := _plugin_with_log()
	plugin._setup_session(7)
	plugin._capture("mcp:hello", [], 7)
	plugin.note_editor_play_started()
	assert_true(plugin.is_game_capture_ready(), "precondition: held beacon replayed")
	assert_eq(plugin._game_session_id, 7,
		"the replayed beacon must bind the run to its own debugger session")


## Counts the adoption calls the production play-state poll makes.
class _SpyDebugger extends McpDebuggerPlugin:
	var started := 0
	var stopped := 0

	func note_editor_play_started() -> void:
		started += 1

	func note_editor_play_stopped() -> void:
		stopped += 1


func test_connection_play_state_edge_drives_adoption() -> void:
	## #891 review: without this, deleting the start-edge call in connection.gd
	## -- the half that actually makes F5/F6 work -- leaves every other test in
	## this suite passing. Drives the real McpConnection poll, not the plugin
	## method directly.
	var conn := McpConnection.new()
	var spy := _SpyDebugger.new()
	conn.debugger_plugin = spy
	conn._last_play_state_for_run = false

	conn._check_game_run_play_state(true)
	assert_eq(spy.started, 1, "the stopped -> playing edge must adopt the run")
	conn._check_game_run_play_state(true)
	assert_eq(spy.started, 1, "a level, not an edge: no repeat adoption while play continues")
	conn._check_game_run_play_state(false)
	assert_eq(spy.stopped, 1, "the playing -> stopped edge must still end the run")
	assert_eq(spy.started, 1, "the stop edge must not adopt")
	conn.free()


func test_adoption_keeps_the_attached_debugger_session() -> void:
	## #891 review: clearing _game_session_id at adoption left every staleness
	## guard comparing against -1, so a foreign session's `stopped` could end a
	## live manual run (_on_debugger_session_stopped lets a manual-armed run end
	## on any session while the id is unknown).
	var plugin := _plugin_with_log()
	plugin._setup_session(5)
	plugin.note_editor_play_started()
	assert_eq(plugin._game_session_id, 5,
		"adoption must keep the session the game is already attached on")
	plugin._on_debugger_session_stopped(9)
	assert_true(plugin._game_run_active,
		"a foreign session's stop must not end the adopted run")
	plugin._on_debugger_session_stopped(5)
	assert_false(plugin._game_run_active,
		"the run's own session stopping still ends it")


func test_adoption_preserves_a_pre_adoption_debugger_break() -> void:
	## #891 review: a boot parse error breaks the game before the play-state
	## edge. Adoption used to clear that break, losing the actionable #645
	## diagnosis -- and the beacon never arrives for a game parked at a break,
	## so nothing restored it.
	var plugin := _plugin_with_log()
	plugin._setup_session(1)
	plugin.note_debug_break(true, "Parse error in res://broken.gd")
	plugin.note_editor_play_started()
	assert_true(plugin._break_active, "the break must survive adoption")
	assert_eq(plugin._break_reason, "Parse error in res://broken.gd",
		"the break reason must survive adoption")
	assert_true(plugin._break_pre_live,
		"the break must be re-evaluated as pre-live for the adopted run")


func test_boot_output_stays_visible_under_the_adopted_run_id() -> void:
	## #891 review: the helper flushes boot/main-scene output immediately after
	## its beacon. If adoption rotated the run id afterwards, those lines stayed
	## tagged with the superseded id -- and logs_read(source="game") returns the
	## CURRENT run only, so a game whose only output happens in _ready() read as
	## an empty log while the bridge reported live.
	var plugin := _plugin_with_log()
	var game_log := McpGameLogBuffer.new()
	plugin._game_log_buffer = game_log
	var run_before := game_log.run_id()

	plugin._setup_session(1)
	plugin._capture("mcp:hello", [], 1)
	plugin._capture("mcp:log_batch", [[["info", "boot line from _ready"]]], 1)
	var run_at_boot := game_log.run_id()
	assert_true(run_at_boot != run_before,
		"holding the beacon must start this game's run identity")

	plugin.note_editor_play_started()
	assert_eq(game_log.run_id(), run_at_boot,
		"adoption must not rotate again and orphan the boot output")

	var page := game_log.get_run_page(game_log.run_id(), 0, 10)
	var entries: Array = page.get("entries", [])
	assert_eq(entries.size(), 1,
		"the boot line must be readable in the current run, the way logs_read returns it")
	assert_eq(str(entries[0].get("text", "")), "boot line from _ready")
