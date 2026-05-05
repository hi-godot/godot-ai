@tool
extends McpTestSuite

## Tests for McpNodeValidator (audit-v2 #20 / issue #364) — the shared
## resolve-or-error helper that subsumed the 38+ inline EDITOR_NOT_READY +
## NODE_NOT_FOUND blocks across handlers.

const McpNodeValidator := preload("res://addons/godot_ai/handlers/_node_validator.gd")


func suite_name() -> String:
	return "node_validator"


# ----- resolve_or_error: error paths -----


func test_resolve_or_error_missing_path_emits_missing_required_param() -> void:
	var result := McpNodeValidator.resolve_or_error("")
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)
	assert_contains(result.error.message, "path")


func test_resolve_or_error_uses_param_name_in_missing_message() -> void:
	## Handlers pass "player_path" / "node_path" / "camera_path" — the
	## error message must echo the caller's name so agents see the same
	## param name they sent.
	var result := McpNodeValidator.resolve_or_error("", "player_path")
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)
	assert_contains(result.error.message, "player_path")


func test_resolve_or_error_unresolvable_path_emits_node_not_found() -> void:
	var result := McpNodeValidator.resolve_or_error("/Main/__definitely_nonexistent__")
	assert_is_error(result, McpErrorCodes.NODE_NOT_FOUND)


# ----- resolve_or_error: success paths -----


func test_resolve_or_error_resolves_root_path() -> void:
	var result := McpNodeValidator.resolve_or_error("/Main")
	assert_has_key(result, "node")
	assert_has_key(result, "scene_root")
	assert_has_key(result, "path")
	assert_eq(result.path, "/Main")
	assert_true(result.node is Node, "node field must be a Node")
	assert_eq(result.node, result.scene_root, "/Main IS the scene root")


func test_resolve_or_error_resolves_descendant_path() -> void:
	var result := McpNodeValidator.resolve_or_error("/Main/Camera3D")
	assert_has_key(result, "node")
	assert_eq(result.path, "/Main/Camera3D")
	assert_eq(String(result.node.name), "Camera3D")
	assert_true(result.node is Camera3D, "node must be the Camera3D")
	assert_ne(result.node, result.scene_root, "descendant != scene_root")


# ----- require_scene_or_error -----


func test_require_scene_or_error_returns_scene_root_when_open() -> void:
	## In CI the test runner ensures main.tscn is the open scene.
	var result := McpNodeValidator.require_scene_or_error()
	assert_has_key(result, "scene_root")
	assert_true(result.scene_root is Node, "scene_root must be a Node")


# ----- error dict shape parity -----


func test_error_dicts_match_McpErrorCodes_make_shape() -> void:
	## The handler call sites do `if resolved.has("error"): return resolved`
	## — that propagation only works if the error dict shape matches what
	## `McpErrorCodes.make()` produces. Pin the contract here so a refactor
	## can't subtly change the error envelope.
	var missing := McpNodeValidator.resolve_or_error("")
	assert_has_key(missing, "status")
	assert_eq(missing.status, "error")
	assert_has_key(missing, "error")
	assert_has_key(missing.error, "code")
	assert_has_key(missing.error, "message")

	var not_found := McpNodeValidator.resolve_or_error("/Main/nope_nope_nope")
	assert_has_key(not_found, "status")
	assert_eq(not_found.status, "error")
	assert_has_key(not_found, "error")
	assert_has_key(not_found.error, "code")
	assert_has_key(not_found.error, "message")
