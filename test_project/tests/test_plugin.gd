@tool
extends McpTestSuite

## Tests for the uvx stale-index self-heal in `_start_server` (see #172).
## The full retry path re-spawns via `OS.create_process`, which we can't
## cleanly intercept — so these tests target the pure decision helper
## `_retry_with_refresh_allowed` that gates the retry. Surface area that
## `_should_retry_with_refresh` exercises (static-cache reads, pid-file
## I/O) is deliberately kept out of the helper under test.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")


func suite_name() -> String:
	return "plugin"


func test_retry_fires_on_uvx_tier_with_no_pid_file() -> void:
	## Classic stale-index scenario: uvx resolved the release to nothing,
	## Python never ran (so no pid-file), and we haven't retried yet.
	assert_true(
		GodotAiPlugin._retry_with_refresh_allowed(false, "uvx", 0),
		"uvx tier + no pid-file + not retried must trigger the --refresh retry",
	)


func test_no_retry_on_dev_venv_tier() -> void:
	## `--refresh` is a uvx-only flag. Dev-venv spawns `python -m godot_ai`,
	## which has no resolve step to refresh — retrying would be a no-op.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(false, "dev_venv", 0),
		"dev_venv tier must not attempt a --refresh retry",
	)


func test_no_retry_on_system_tier() -> void:
	## System installs don't go through uvx either.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(false, "system", 0),
		"system tier must not attempt a --refresh retry",
	)


func test_no_retry_when_already_retried() -> void:
	## One-shot guard: once we've retried, subsequent spawn failures must
	## fall through to CRASHED instead of looping on --refresh.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(true, "uvx", 0),
		"already-retried must skip even on uvx with no pid-file",
	)


func test_no_retry_when_pid_file_present() -> void:
	## Python wrote its pid-file, then the process died — that's a real
	## Python-side crash, not a uvx resolve failure. `--refresh` won't
	## help; the user needs the traceback in Godot's output log.
	assert_false(
		GodotAiPlugin._retry_with_refresh_allowed(false, "uvx", 12345),
		"pid-file present means Python started — don't blame uvx",
	)


func test_get_server_command_with_refresh_inserts_flag_on_uvx_tier() -> void:
	## End-to-end sanity for the refresh param plumbed into
	## `get_server_command`. Only meaningful when the current env
	## actually resolves to the uvx tier.
	if McpClientConfigurator.get_server_launch_mode() != "uvx":
		skip("only meaningful on uvx tier")
		return
	var cmd_plain := McpClientConfigurator.get_server_command(false)
	var cmd_refresh := McpClientConfigurator.get_server_command(true)
	assert_false(cmd_plain.is_empty(), "uvx-tier plain command must be non-empty")
	assert_false(cmd_refresh.is_empty(), "uvx-tier refresh command must be non-empty")
	assert_eq(cmd_refresh[0], cmd_plain[0], "uvx executable must match between variants")
	assert_eq(cmd_refresh[1], "--refresh", "--refresh must land as cmd[1], before --from")
	assert_eq(cmd_refresh[2], "--from", "plain --from must follow --refresh")
	assert_eq(cmd_refresh.size(), cmd_plain.size() + 1, "refresh variant must add exactly one flag")


func test_get_server_command_default_omits_refresh() -> void:
	## Warm-path invariant: the default no-arg call never adds --refresh.
	## Covers every existing caller (start_dev_server, _start_server's
	## first spawn, etc.) that relies on the flag-free shape.
	var cmd := McpClientConfigurator.get_server_command()
	if cmd.is_empty():
		skip("no server command available in this env")
		return
	for token in cmd:
		assert_ne(token, "--refresh", "default get_server_command must never include --refresh")
