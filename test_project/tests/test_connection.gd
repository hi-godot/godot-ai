@tool
extends McpTestSuite

## Tests for Connection._make_session_id / _slugify — session ID format.


func suite_name() -> String:
	return "connection"


# ----- slug format -----

func test_make_session_id_uses_project_directory_name() -> void:
	var sid := Connection._make_session_id("/Users/foo/My Game/")
	var parts := sid.split("@")
	assert_eq(parts.size(), 2, "SID should be '<slug>@<hex>'")
	assert_eq(parts[0], "my-game")
	assert_eq(parts[1].length(), 4, "suffix should be 4 hex chars")
	for c in parts[1]:
		assert_true(
			(c >= "0" and c <= "9") or (c >= "a" and c <= "f"),
			"suffix char %s is not hex" % c,
		)


func test_make_session_id_handles_no_trailing_slash() -> void:
	var sid := Connection._make_session_id("/Users/foo/My Game")
	var parts := sid.split("@")
	assert_eq(parts[0], "my-game")


func test_make_session_id_empty_path_falls_back_to_project() -> void:
	var sid := Connection._make_session_id("")
	var parts := sid.split("@")
	assert_eq(parts[0], "project")
	assert_eq(parts[1].length(), 4)


func test_make_session_id_only_slashes_falls_back_to_project() -> void:
	var sid := Connection._make_session_id("///")
	var parts := sid.split("@")
	assert_eq(parts[0], "project")


func test_make_session_id_randomizes_suffix() -> void:
	var seen := {}
	for i in range(32):
		var sid := Connection._make_session_id("/Users/x/game/")
		seen[sid] = true
	## Avoid a flaky two-sample comparison: collect many IDs and verify
	## the suffix is not constant across repeated calls for the same path.
	assert_true(seen.size() > 1, "suffix should vary across repeated calls")


# ----- slugify -----

func test_slugify_lowercases() -> void:
	assert_eq(Connection._slugify("MyGame"), "mygame")


func test_slugify_collapses_punctuation_to_dashes() -> void:
	assert_eq(Connection._slugify("My Awesome_Game!"), "my-awesome-game")


func test_slugify_strips_leading_and_trailing_punctuation() -> void:
	assert_eq(Connection._slugify("  Hello World  "), "hello-world")
	assert_eq(Connection._slugify("!!!game!!!"), "game")


func test_slugify_preserves_alphanumeric() -> void:
	assert_eq(Connection._slugify("level42"), "level42")


func test_slugify_empty_returns_empty() -> void:
	assert_eq(Connection._slugify(""), "")
	assert_eq(Connection._slugify("!!!"), "")
