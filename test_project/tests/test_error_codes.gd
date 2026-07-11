@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Tests for McpErrorCodes — focused on the #651 stage-1 EDITOR_NOT_READY
## sub-code payload (`make_not_ready`). The top-level code must stay
## EDITOR_NOT_READY (dashboards and callers key on it); the sub-code and
## retryable flag travel in `error.data` only.


func suite_name() -> String:
	return "error_codes"


# ----- make: baseline shape -----

func test_make_builds_status_error_shape() -> void:
	var err := ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "nope")
	assert_eq(err.status, "error")
	assert_eq(err.error.code, "NODE_NOT_FOUND")
	assert_eq(err.error.message, "nope")


# ----- make_not_ready: #651 stage-1 attribution payload -----

func test_make_not_ready_keeps_top_level_code_frozen() -> void:
	var err := ErrorCodes.make_not_ready(
		ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EditorFileSystem not available", false)
	## The sub-code must NEVER become the top-level code — existing callers
	## and dashboards key on the exact EDITOR_NOT_READY string.
	assert_is_error(err, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(err.error.message, "EditorFileSystem not available")


func test_make_not_ready_carries_sub_code_and_retryable() -> void:
	var err := ErrorCodes.make_not_ready(
		ErrorCodes.SUB_EDITOR_GAME_NOT_RUNNING, "Game is not running", false,
		"Start the game with project_run, then retry.")
	assert_has_key(err.error, "data")
	assert_eq(err.error.data.sub_code, "EDITOR_GAME_NOT_RUNNING")
	assert_eq(err.error.data.retryable, false)
	assert_contains(err.error.data.hint, "project_run")


func test_make_not_ready_omits_empty_hint() -> void:
	## When the message already IS the hint, callers pass no hint and the
	## data block must not carry an empty-string key (the server appends
	## every data key to the agent-visible error text).
	var err := ErrorCodes.make_not_ready(
		ErrorCodes.SUB_EDITOR_VIEWPORT_UNAVAILABLE, "No 3D viewport available", false)
	assert_eq(err.error.data.sub_code, "EDITOR_VIEWPORT_UNAVAILABLE")
	assert_false(err.error.data.has("hint"), "empty hint must be omitted from data")


func test_make_not_ready_retryable_true_passthrough() -> void:
	var err := ErrorCodes.make_not_ready(
		ErrorCodes.SUB_EDITOR_IMPORTING, "Editor is importing resources", true)
	assert_eq(err.error.data.retryable, true)


func test_sub_code_constants_name_editor_states() -> void:
	## Locks the wire values — these are telemetry dimensions; renaming one
	## silently splits its dashboard series. Mirror of
	## protocol/errors.py::EditorNotReadySubCode (sync is CI-enforced by
	## tests/unit/test_editor_not_ready_hint_contract.py).
	assert_eq(ErrorCodes.SUB_EDITOR_IMPORTING, "EDITOR_IMPORTING")
	assert_eq(ErrorCodes.SUB_EDITOR_PLAYING, "EDITOR_PLAYING")
	assert_eq(ErrorCodes.SUB_EDITOR_NO_SCENE, "EDITOR_NO_SCENE")
	assert_eq(ErrorCodes.SUB_EDITOR_GAME_NOT_RUNNING, "EDITOR_GAME_NOT_RUNNING")
	assert_eq(ErrorCodes.SUB_EDITOR_VIEWPORT_UNAVAILABLE, "EDITOR_VIEWPORT_UNAVAILABLE")
	assert_eq(ErrorCodes.SUB_EDITOR_VIEWPORT_NOT_3D, "EDITOR_VIEWPORT_NOT_3D")
	assert_eq(ErrorCodes.SUB_EDITOR_VIEWPORT_EMPTY, "EDITOR_VIEWPORT_EMPTY")
	assert_eq(ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EDITOR_UNAVAILABLE")


# ----- prefix_message: unchanged behavior guard -----

func test_prefix_message_preserves_code() -> void:
	var err := ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "busy")
	var prefixed := ErrorCodes.prefix_message(err, "Property 'x'")
	assert_is_error(prefixed, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(prefixed.error.message, "Property 'x': busy")
