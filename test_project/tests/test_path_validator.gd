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


# ----- null byte (truncation trap, audit GH-4) -----

func test_rejects_replacement_character() -> void:
	## A NUL can truncate a C string, so the path written could differ from the
	## one validated/reported. Godot cannot hold U+0000 in a String — it decodes
	## an attempted NUL (and any other malformed input) to U+FFFD — so U+FFFD is
	## what an embedded-null payload actually looks like by the time it reaches
	## the validator. Reject it.
	##
	## Deliberately does NOT build the payload with `String.chr(0)`: constructing
	## that string is itself what made the engine print "Unexpected NUL
	## character" on every validated path (issue #889).
	# No "..": the ONLY reason to reject this path is the bad codepoint.
	var err := McpPathValidator.validate_resource_path("res://safe\uFFFDname.gd")
	assert_false(err.is_empty(), "path with a replacement character must be rejected")
	assert_contains(err, "null")


func test_loadable_rejects_replacement_character() -> void:
	## The same guard must cover the ResourceLoader entry point.
	var err := McpPathValidator.validate_loadable_path("res://safe\uFFFDname.tscn")
	assert_false(err.is_empty(), "loadable path with a replacement character must be rejected")


func test_valid_path_survives_codepoint_scan() -> void:
	## Regression for #889: ordinary and non-ASCII paths must pass the scan
	## cleanly. Accented/CJK characters decode fine and must not be mistaken for
	## the replacement character.
	assert_eq(McpPathValidator.validate_resource_path("res://scripts/player.gd"), "",
		"plain ASCII path must validate")
	assert_eq(McpPathValidator.validate_resource_path("res://scènes/日本語.gd"), "",
		"valid non-ASCII path must validate")


# ----- write blocklist: project-critical files (audit GH-3) -----
#
# These pass every structural check (res://-rooted, no traversal, under root)
# but overwriting them corrupts the project. Blocked for writes, allowed for
# reads (inspecting config is legitimate).

func test_write_rejects_project_godot() -> void:
	var err := McpPathValidator.validate_resource_path("res://project.godot", true)
	assert_false(err.is_empty(), "writing res://project.godot must be rejected")
	assert_contains(err, "project.godot")


func test_write_rejects_godot_metadata_dir() -> void:
	var err := McpPathValidator.validate_resource_path("res://.godot/uid_cache.bin", true)
	assert_false(err.is_empty(), "writing under res://.godot/ must be rejected")
	assert_contains(err, ".godot")


func test_write_allows_import_sidecar() -> void:
	## .import sidecars are source-controlled import config; editing them then
	## reimporting is a legitimate, recoverable workflow, so writes are allowed.
	assert_eq(McpPathValidator.validate_resource_path("res://icon.svg.import", true), "")


func test_write_allows_normal_resource_path() -> void:
	## The blocklist must not catch ordinary writes.
	assert_eq(McpPathValidator.validate_resource_path("res://scenes/level.tscn", true), "")
	assert_eq(McpPathValidator.validate_resource_path("res://data/config.json", true), "")


func test_read_allows_project_critical_files() -> void:
	## for_write defaults to false — reading project config / import data is
	## legitimate and must not be blocked.
	assert_eq(McpPathValidator.validate_resource_path("res://project.godot"), "")
	assert_eq(McpPathValidator.validate_resource_path("res://.godot/uid_cache.bin"), "")
	assert_eq(McpPathValidator.validate_resource_path("res://icon.svg.import"), "")


func test_write_still_rejects_traversal() -> void:
	## The structural traversal check fires regardless of for_write.
	assert_false(McpPathValidator.validate_resource_path("res://../etc/passwd", true).is_empty())


# ----- write blocklist: separator normalization -----
#
# The segment-based clauses split on "/" only. A Windows-style separator would
# fuse the path into a single segment that matches neither, while Godot's own
# FileAccess resolves the backslash and performs the write — so the blocklist
# has to normalize before splitting.

func test_write_rejects_backslash_godot_metadata_dir() -> void:
	var err := McpPathValidator.validate_resource_path("res://.godot\\uid_cache.bin", true)
	assert_false(err.is_empty(),
		"a backslash-separated path into res://.godot/ must be refused for write "
		+ "just like the forward-slash form")
	assert_contains(err, ".godot")


func test_write_rejects_backslash_loaded_plugin_tree() -> void:
	var err := McpPathValidator.validate_resource_path("res://addons\\godot_ai\\plugin.gd", true)
	assert_false(err.is_empty(),
		"a backslash-separated path into the loaded plugin tree must be refused "
		+ "for write — overwriting a live .gd can crash the editor")
	assert_contains(err, "addons/godot_ai")


func test_write_rejects_mixed_separators_into_blocked_dirs() -> void:
	## Real callers on Windows produce mixed forms; both halves of the split
	## must survive normalization.
	assert_false(McpPathValidator.validate_resource_path(
		"res://addons/godot_ai\\utils\\path_validator.gd", true).is_empty(),
		"a mixed-separator path into the plugin tree must be refused")
	assert_false(McpPathValidator.validate_resource_path(
		"res://sub\\.godot\\x.bin", true).is_empty(),
		"a mixed-separator path into a nested .godot/ must be refused")


func test_write_rejects_dot_segments_into_loaded_plugin_tree() -> void:
	## The plugin-tree clause is ANCHORED on segments[0]/segments[1], so a `.`
	## segment shifts it out of position. `split("/", false)` only drops EMPTY
	## segments — `.` survives as a real one. The engine folds it away before
	## writing, so every form below reaches the live plugin script.
	assert_false(McpPathValidator.validate_resource_path(
		"res://./addons/godot_ai/plugin.gd", true).is_empty(),
		"a leading ./ must not shift the plugin-tree check out of position")
	assert_false(McpPathValidator.validate_resource_path(
		"res://addons/./godot_ai/plugin.gd", true).is_empty(),
		"an interior ./ must not shift the plugin-tree check out of position")
	assert_false(McpPathValidator.validate_resource_path(
		"res://.\\addons\\godot_ai\\plugin.gd", true).is_empty(),
		"the ./ and backslash bypasses must not compose into a hole")
	assert_false(McpPathValidator.validate_resource_path(
		"res://addons//godot_ai/plugin.gd", true).is_empty(),
		"a doubled separator must not shift the check either")


func test_write_rejects_backslash_before_the_project_manifest() -> void:
	## Manifest and override.cfg checks run on the normalized path, so a
	## backslash before the filename cannot hide it from get_file().
	assert_false(McpPathValidator.validate_resource_path(
		"res://sub\\project.godot", true).is_empty(),
		"normalization plus get_file() must still refuse the manifest")


func test_write_rejects_dot_suffixed_protected_files() -> void:
	## `res://project.godot/.` has get_file() == "." until simplify_path()
	## folds the trailing segment. The writer still opens project.godot.
	assert_false(McpPathValidator.validate_resource_path(
		"res://project.godot/.", true).is_empty(),
		"a trailing /. must not bypass the project.godot guard")
	assert_false(McpPathValidator.validate_resource_path(
		"res://override.cfg/.", true).is_empty(),
		"a trailing /. must not bypass the override.cfg guard")
	assert_false(McpPathValidator.validate_resource_path(
		"res://project.godot/./", true).is_empty(),
		"a trailing /./ must not bypass the project.godot guard")
	assert_false(McpPathValidator.validate_resource_path(
		"res://override.cfg\\.", true).is_empty(),
		"a trailing \\. must not bypass the override.cfg guard")


func test_write_rejects_windows_aliases_of_protected_files() -> void:
	## Windows opens one file under several spellings. Each of these reached
	## the protected file on NTFS through FileAccess while passing every check
	## that compares names: a `::$DATA` stream, an 8.3 short name, and the
	## `$INDEX_ALLOCATION` stream of a directory.
	for path in [
		"res://project.godot::$DATA",
		"res://project.godot:alt",
		"res://override.cfg::$DATA",
		"res://.godot::$INDEX_ALLOCATION/uid_cache.bin",
		"res://PROJEC~1.GOD",
		"res://projec~1.god",
		"res://OVERRI~1.CFG",
		"res://GODOT~1/uid_cache.bin",
		"res://addons/GODOT_~1/plugin.gd",
		"res://project.godot.",
		"res://project.godot ",
		"res://.godot./uid_cache.bin",
		"res://addons/godot_ai /plugin.gd",
	]:
		assert_false(McpPathValidator.validate_resource_path(path, true).is_empty(),
			"%s must be refused for write" % path)


func test_write_alias_guard_spares_ordinary_names() -> void:
	## Only alias shapes are refused: a tilde without the short-name form, or a
	## dot inside a name, is an ordinary path.
	for path in [
		"res://notes~draft.txt",
		"res://a~1b.txt",
		"res://backup~old/level.tscn",
		"res://v1.2/level.tscn",
		"res://scenes/level.tscn",
	]:
		assert_eq(McpPathValidator.validate_resource_path(path, true), "",
			"%s must stay writable" % path)
	## Reads are unaffected: the alias guard is part of the write blocklist.
	assert_eq(McpPathValidator.validate_resource_path("res://PROJEC~1.GOD"), "")


func test_write_still_allows_backslash_paths_outside_the_blocklist() -> void:
	## Normalization must not turn every backslash path into a rejection —
	## only the blocked prefixes are affected.
	assert_eq(McpPathValidator.validate_resource_path("res://scenes\\level.tscn", true), "")
	assert_eq(McpPathValidator.validate_resource_path("res://addons\\other_addon\\x.gd", true), "")


# ----- write blocklist: startup surface and the loaded plugin tree -----

func test_write_rejects_override_cfg() -> void:
	## override.cfg is applied over project.godot at startup — same takeover
	## surface as the manifest, so writes must be refused too.
	var err := McpPathValidator.validate_resource_path("res://override.cfg", true)
	assert_false(err.is_empty(), "writing res://override.cfg must be rejected")
	assert_contains(err, "override.cfg")


func test_write_blocklist_is_case_insensitive() -> void:
	## macOS/Windows default filesystems are case-insensitive, so a case-variant
	## spelling resolves to the same protected file and must be refused.
	assert_false(McpPathValidator.validate_resource_path("res://Project.godot", true).is_empty())
	assert_false(McpPathValidator.validate_resource_path("res://.GODOT/uid_cache.bin", true).is_empty())


func test_write_rejects_loaded_plugin_tree() -> void:
	## Overwriting a currently-loaded plugin script (plus the immediate
	## update_file() reimport) can SIGABRT the editor or corrupt the installed
	## plugin so the next enable fails to resolve scripts (#689).
	var err := McpPathValidator.validate_resource_path("res://addons/godot_ai/plugin.gd", true)
	assert_false(err.is_empty(), "writing under res://addons/godot_ai/ must be rejected")
	assert_contains(err, "addons/godot_ai")


func test_write_rejects_loaded_plugin_tree_nested() -> void:
	var err := McpPathValidator.validate_resource_path(
		"res://addons/godot_ai/handlers/new_handler.gd", true
	)
	assert_false(err.is_empty(), "writing anywhere under res://addons/godot_ai/ must be rejected")


func test_write_rejects_loaded_plugin_tree_case_insensitive() -> void:
	assert_false(
		McpPathValidator.validate_resource_path("res://Addons/Godot_AI/plugin.gd", true).is_empty()
	)


func test_write_allows_other_addons() -> void:
	## Only this plugin's own tree is blocked — other addons remain writable.
	assert_eq(McpPathValidator.validate_resource_path("res://addons/some_other_plugin/plugin.gd", true), "")


func test_read_allows_plugin_tree() -> void:
	## The block is write-only; reading the plugin's own source must still work.
	assert_eq(McpPathValidator.validate_resource_path("res://addons/godot_ai/plugin.gd"), "")


func test_loadable_accepts_uid() -> void:
	## uid:// is an opaque resource id ResourceLoader resolves to an in-project
	## resource — it cannot express traversal, so load handlers must accept it.
	assert_eq(McpPathValidator.validate_loadable_path("uid://b8x3k7q2vn1ya"), "")


func test_loadable_accepts_user() -> void:
	## user:// runtime assets were always loadable and must remain so.
	assert_eq(McpPathValidator.validate_loadable_path("user://recording.wav.tres"), "")


func test_loadable_rejects_user_traversal() -> void:
	## ...but a user:// path still can't escape the user data sandbox.
	assert_false(McpPathValidator.validate_loadable_path("user://../../etc/passwd").is_empty())


func test_loadable_still_rejects_res_traversal() -> void:
	assert_false(McpPathValidator.validate_loadable_path("res://../evil.gd").is_empty())


func test_loadable_rejects_unknown_scheme() -> void:
	assert_false(McpPathValidator.validate_loadable_path("/etc/passwd").is_empty())
