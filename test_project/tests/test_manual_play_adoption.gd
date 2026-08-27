@tool
extends McpTestSuite

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
	var plugin := McpDebuggerPlugin.new()
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
