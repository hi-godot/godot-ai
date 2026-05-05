@tool
extends McpTestSuite

## Tests for McpPathValidator — the resource-path traversal guard shared by
## script_handler and filesystem_handler. Issue #347 (audit-v2 #3): paths
## like `res://../etc/passwd.gd` were passing the bare prefix check.


func suite_name() -> String:
	return "path_validator"


# ----- happy path -----

func test_valid_simple_path_returns_empty() -> void:
	assert_eq(McpPathValidator.validate_resource_path("res://main.tscn"), "")


func test_valid_nested_path_returns_empty() -> void:
	assert_eq(McpPathValidator.validate_resource_path("res://addons/godot_ai/plugin.gd"), "")


func test_valid_root_path_returns_empty() -> void:
	## "res://" itself has no traversal and resolves exactly to the project
	## root, so the validator must not reject it on the boundary check.
	assert_eq(McpPathValidator.validate_resource_path("res://"), "")


# ----- empty + prefix -----

func test_empty_path_rejected() -> void:
	var err := McpPathValidator.validate_resource_path("")
	assert_false(err.is_empty(), "empty path must report an error")
	assert_contains(err, "Missing required param")


func test_missing_prefix_rejected() -> void:
	var err := McpPathValidator.validate_resource_path("/tmp/foo.gd")
	assert_false(err.is_empty(), "absolute path without res:// must be rejected")
	assert_contains(err, "res://")


func test_user_prefix_rejected() -> void:
	## user:// is a valid Godot scheme but it's outside the project — agents
	## must not be able to write to user:// via the same handlers (they have
	## different lifecycle and permission semantics).
	var err := McpPathValidator.validate_resource_path("user://save.dat")
	assert_false(err.is_empty(), "user:// path must be rejected")
	assert_contains(err, "res://")


# ----- traversal regressions (the actual security guard) -----

func test_rejects_dotdot_at_root() -> void:
	## The exact attack shape called out in issue #347.
	var err := McpPathValidator.validate_resource_path("res://../etc/passwd.gd")
	assert_false(err.is_empty(), "res://../etc/passwd.gd must be rejected")
	assert_contains(err, "..")


func test_rejects_dotdot_nested() -> void:
	var err := McpPathValidator.validate_resource_path("res://addons/../../etc/passwd")
	assert_false(err.is_empty(), "nested traversal must be rejected")
	assert_contains(err, "..")


func test_rejects_deep_dotdot_chain() -> void:
	## Defence in depth: even if a payload chains through legitimate-looking
	## subdirectories first, the substring check fires.
	var err := McpPathValidator.validate_resource_path("res://addons/godot_ai/../../../etc/passwd.gd")
	assert_false(err.is_empty(), "deep traversal chain must be rejected")


func test_rejects_dotdot_in_filename() -> void:
	## Per the audit's fix shape: reject any path containing `..`. A filename
	## like `my..backup.json` is unusual enough that we accept the false-
	## positive cost in exchange for a simpler, shorter security boundary.
	var err := McpPathValidator.validate_resource_path("res://data/my..backup.json")
	assert_false(err.is_empty(), "literal '..' anywhere in path must be rejected")


# ----- boundary check (defence in depth past the substring guard) -----

func test_well_formed_nested_path_passes_boundary_check() -> void:
	## Sanity: a path with no `..` substring still has to clear the
	## globalize_path → simplify_path → boundary check. This pins the safe
	## path so a regression in the boundary comparison (e.g. trailing-slash
	## handling) couldn't silently reject legitimate paths.
	##
	## Direct traversal payloads can't reach the boundary check — they're
	## caught by the `..` substring rejection above — so there's no
	## non-`..` traversal payload to assert rejection on. The boundary
	## check exists as defence-in-depth for any future encoding-bypass
	## that smuggles a `..` past the substring guard.
	var safe := McpPathValidator.validate_resource_path("res://addons/godot_ai")
	assert_eq(safe, "", "well-formed nested path must validate")
