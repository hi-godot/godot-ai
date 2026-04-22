@tool
extends McpTestSuite

## Tests for the client configuration registry + strategies.
##
## Per-client production paths point at real config files on the user's
## machine — we never touch those here. Instead we build synthetic McpClient
## descriptors with path_templates pointing inside user:// and exercise the
## JSON / TOML / facade behaviour against scratch files.

var _handler: ClientHandler
var _scratch_dir: String


func suite_name() -> String:
	return "clients"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = ClientHandler.new()
	_scratch_dir = OS.get_user_data_dir().path_join("mcp_client_tests")
	DirAccess.make_dir_recursive_absolute(_scratch_dir)


func suite_teardown() -> void:
	# Best-effort cleanup of scratch files. user:// is writable so the dir
	# stays around for the next run; only the JSON / TOML files matter.
	for f in DirAccess.get_files_at(_scratch_dir):
		DirAccess.remove_absolute(_scratch_dir.path_join(f))


# ----- registry sanity -----

func test_registry_loads_all_clients() -> void:
	var ids := McpClientRegistry.ids()
	assert_gt(ids.size(), 10, "Expected at least 10 registered clients, got %d" % ids.size())
	# Each existing client must remain registered for behaviour parity.
	for required in ["claude_code", "claude_desktop", "codex", "antigravity"]:
		assert_true(McpClientRegistry.has_id(required), "Missing client: %s" % required)


func test_registry_ids_are_unique() -> void:
	var seen := {}
	for id in McpClientRegistry.ids():
		assert_false(seen.has(id), "Duplicate client id: %s" % id)
		seen[id] = true
	assert_gt(seen.size(), 0)


func test_every_client_has_required_fields() -> void:
	for client in McpClientRegistry.all():
		assert_true(not client.id.is_empty(), "Client missing id: %s" % client)
		assert_true(not client.display_name.is_empty(), "%s missing display_name" % client.id)
		assert_contains(["json", "toml", "cli"], client.config_type, "%s has unexpected config_type %s" % [client.id, client.config_type])
		if client.config_type == "json":
			assert_true(client.entry_builder.is_valid(), "%s json client missing entry_builder" % client.id)
			assert_gt(client.server_key_path.size(), 0, "%s missing server_key_path" % client.id)
		elif client.config_type == "cli":
			assert_gt(client.cli_names.size(), 0, "%s cli client missing cli_names" % client.id)
			assert_true(client.cli_register_args.is_valid(), "%s cli client missing cli_register_args" % client.id)


func test_every_client_has_manual_command() -> void:
	for client_id in McpClientConfigurator.client_ids():
		var cmd := McpClientConfigurator.manual_command(client_id)
		assert_true(not cmd.is_empty(), "%s missing manual command" % client_id)


# ----- server launch mode -----


func test_server_launch_mode_returns_known_string() -> void:
	## get_server_launch_mode() powers the handshake field agents read to
	## detect plugin/server version drift. Always returns one of four
	## documented values so callers can pattern-match without guessing.
	var mode := McpClientConfigurator.get_server_launch_mode()
	assert_contains(["dev_venv", "uvx", "system", "unknown"], mode, "Unexpected launch mode: %s" % mode)


func test_server_launch_mode_agrees_with_get_server_command() -> void:
	## The two accessors resolve the same tiers; if get_server_command
	## returns a non-empty command, get_server_launch_mode must not be
	## "unknown" (and vice versa). Keeps the pair in sync against future
	## refactors that add a fourth launcher to one but not the other.
	var cmd := McpClientConfigurator.get_server_command()
	var mode := McpClientConfigurator.get_server_launch_mode()
	if cmd.is_empty():
		assert_eq(mode, "unknown", "Empty command should map to unknown mode")
	else:
		assert_true(mode != "unknown", "Non-empty command must map to a concrete mode, got %s" % mode)


func test_find_worktree_src_dir_locates_sibling_src_godot_ai() -> void:
	var root := _scratch_dir.path_join("fake_worktree")
	var godot_ai := root.path_join("src/godot_ai")
	var nested := root.path_join("test_project/addons/deep")
	DirAccess.make_dir_recursive_absolute(godot_ai)
	DirAccess.make_dir_recursive_absolute(nested)

	var expected := root.path_join("src")
	assert_eq(McpClientConfigurator.find_worktree_src_dir(root.path_join("test_project")), expected)
	assert_eq(McpClientConfigurator.find_worktree_src_dir(nested), expected)
	assert_eq(McpClientConfigurator.find_worktree_src_dir(root), expected)

	DirAccess.remove_absolute(nested)
	DirAccess.remove_absolute(root.path_join("test_project/addons"))
	DirAccess.remove_absolute(root.path_join("test_project"))
	DirAccess.remove_absolute(godot_ai)
	DirAccess.remove_absolute(root.path_join("src"))
	DirAccess.remove_absolute(root)


func test_find_worktree_src_dir_returns_empty_when_no_src_on_path() -> void:
	var bare := OS.get_user_data_dir().path_join("mcp_worktree_tests/bare")
	DirAccess.make_dir_recursive_absolute(bare)
	assert_eq(McpClientConfigurator.find_worktree_src_dir(bare), "")
	DirAccess.remove_absolute(bare)
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("mcp_worktree_tests"))


func test_find_worktree_src_dir_ignores_unrelated_src_directory() -> void:
	## An unrelated project's `src/` (no `godot_ai/` child) must not match —
	## otherwise a worktree launched inside a polyglot repo would get a
	## spurious PYTHONPATH override pointing at the wrong tree.
	var root := _scratch_dir.path_join("fake_other_project")
	DirAccess.make_dir_recursive_absolute(root.path_join("src/other_package"))
	assert_eq(McpClientConfigurator.find_worktree_src_dir(root), "")
	DirAccess.remove_absolute(root.path_join("src/other_package"))
	DirAccess.remove_absolute(root.path_join("src"))
	DirAccess.remove_absolute(root)


func test_uvx_server_command_uses_exact_pin_not_tilde() -> void:
	## Regression guard for #133: the uvx branch of get_server_command must
	## pin godot-ai with `==<version>`, not `~=<minor>`. With the tilde
	## constraint, uvx would reuse a cached tool env that matched the
	## minor — so an install first-spawning 1.2.0 would keep using 1.2.0
	## after 1.2.1/1.2.2 landed. Exact pinning makes the cache key
	## version-specific.
	##
	## Positive assertion only fires when the test env actually resolves
	## to the uvx tier. In dev-venv environments (CI, most worktrees) the
	## loop still runs as a negative assertion — no ~= anywhere — so a
	## future regression that re-introduced the tilde would fail here too.
	var cmd := McpClientConfigurator.get_server_command()
	for arg in cmd:
		assert_false(str(arg).contains("~="), "uvx command must not use ~= pin (got: %s)" % str(arg))
	if McpClientConfigurator.get_server_launch_mode() == "uvx":
		var has_exact_pin := false
		for arg in cmd:
			if str(arg).contains("godot-ai==") and str(arg).contains(McpClientConfigurator.get_plugin_version()):
				has_exact_pin = true
				break
		assert_true(has_exact_pin, "uvx tier command should contain godot-ai==<plugin_version>; got %s" % str(cmd))


# ----- mode override + symlink safety -----

## Mode override has two sources (EditorSetting wins, env var is fallback).
## These tests sit on isolated env-var territory — each one clears the
## EditorSetting first so a stale UI selection in the editor running the
## tests can't make the env-var path invisible. Any real UI selection is
## saved + restored around the test body.

func _clear_mode_override_setting() -> Variant:
	## Save the current EditorSetting (if any), clear it, return the prior
	## value so the test can restore. Returns null when the setting was
	## unset entirely. Tests need the setting empty so the env var — which
	## they DO control — takes effect.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return null
	var prior: Variant = null
	if es.has_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING):
		prior = es.get_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING)
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "")
	return prior


func _restore_mode_override_setting(prior: Variant) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, prior if prior != null else "")


func test_mode_override_returns_empty_when_unset() -> void:
	var prior_setting: Variant = _clear_mode_override_setting()
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	OS.unset_environment("GODOT_AI_MODE")
	assert_eq(McpClientConfigurator.mode_override(), "")
	if not prior_env.is_empty():
		OS.set_environment("GODOT_AI_MODE", prior_env)
	_restore_mode_override_setting(prior_setting)


func test_mode_override_normalises_case_and_whitespace() -> void:
	var prior_setting: Variant = _clear_mode_override_setting()
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	OS.set_environment("GODOT_AI_MODE", "  USER  ")
	assert_eq(McpClientConfigurator.mode_override(), "user")
	OS.set_environment("GODOT_AI_MODE", "Dev")
	assert_eq(McpClientConfigurator.mode_override(), "dev")
	OS.set_environment("GODOT_AI_MODE", "whatever")
	assert_eq(McpClientConfigurator.mode_override(), "", "unknown values fall back to auto")
	if prior_env.is_empty():
		OS.unset_environment("GODOT_AI_MODE")
	else:
		OS.set_environment("GODOT_AI_MODE", prior_env)
	_restore_mode_override_setting(prior_setting)


func test_is_dev_checkout_forced_user_mode() -> void:
	## Without this override, the .venv-next-door heuristic would report
	## true in any worktree that inherits the repo's .venv, making the
	## update-check path untestable from dev. With the override, the flow
	## can be exercised end-to-end.
	var prior_setting: Variant = _clear_mode_override_setting()
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	OS.set_environment("GODOT_AI_MODE", "user")
	assert_false(McpClientConfigurator.is_dev_checkout(), "GODOT_AI_MODE=user must force user mode")
	if prior_env.is_empty():
		OS.unset_environment("GODOT_AI_MODE")
	else:
		OS.set_environment("GODOT_AI_MODE", prior_env)
	_restore_mode_override_setting(prior_setting)


func test_is_dev_checkout_forced_dev_mode() -> void:
	var prior_setting: Variant = _clear_mode_override_setting()
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	OS.set_environment("GODOT_AI_MODE", "dev")
	assert_true(McpClientConfigurator.is_dev_checkout(), "GODOT_AI_MODE=dev must force dev mode")
	if prior_env.is_empty():
		OS.unset_environment("GODOT_AI_MODE")
	else:
		OS.set_environment("GODOT_AI_MODE", prior_env)
	_restore_mode_override_setting(prior_setting)


func test_addons_dir_is_symlink_detects_canonical_layout() -> void:
	## `test_project/addons/godot_ai` is committed as a symlink
	## (git mode 120000) pointing at `plugin/addons/godot_ai`, so the
	## data-safety check must resolve that layout to `true`. If this
	## fails, either the symlink didn't survive the checkout (git not
	## preserving symlinks on the test platform) or DirAccess.is_link()
	## behaves unexpectedly — both are real bugs worth surfacing here.
	assert_true(McpClientConfigurator.addons_dir_is_symlink(), "res://addons/godot_ai is committed as a symlink; addons_dir_is_symlink() should report true")


func test_dropdown_flip_propagates_to_is_dev_checkout() -> void:
	## End-to-end mechanism: flipping the dropdown value (via EditorSetting)
	## must flip `is_dev_checkout()` regardless of what the .venv heuristic
	## would otherwise return. This is the concrete chain the install label
	## / update banner / `_check_for_updates` consume. The heuristic result
	## varies by env (dev worktree has a .venv; CI uses system Python with
	## no .venv in the repo root), so this test only asserts the overrides
	## — both flips must work whether auto resolves to dev or user.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorInterface.get_editor_settings() unavailable in test env")
		return
	var had_setting := es.has_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING)
	var prior_setting: Variant = es.get_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING) if had_setting else null
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	OS.unset_environment("GODOT_AI_MODE")

	# Dropdown=user → is_dev_checkout false (overrides heuristic in dev env,
	# matches heuristic in CI — either way, must be false).
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "user")
	assert_false(McpClientConfigurator.is_dev_checkout(), "Dropdown='user' must force is_dev_checkout=false")

	# Dropdown=dev → is_dev_checkout true (matches heuristic in dev env,
	# overrides in CI — either way, must be true).
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "dev")
	assert_true(McpClientConfigurator.is_dev_checkout(), "Dropdown='dev' must force is_dev_checkout=true")

	# Restore.
	if had_setting:
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, prior_setting)
	else:
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "")
	if not prior_env.is_empty():
		OS.set_environment("GODOT_AI_MODE", prior_env)


func test_editor_setting_beats_env_var() -> void:
	## When both an EditorSetting and the env var are set, the EditorSetting
	## wins — the UI dropdown always reflects the user's latest explicit
	## choice even if a stale env var was inherited at launch.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorInterface.get_editor_settings() unavailable in test env")
		return
	var had_setting := es.has_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING)
	var prior_setting: Variant = es.get_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING) if had_setting else null
	var prior_env := OS.get_environment("GODOT_AI_MODE")

	OS.set_environment("GODOT_AI_MODE", "dev")
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "user")
	assert_eq(McpClientConfigurator.mode_override(), "user", "EditorSetting=user must override env=dev")

	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "")
	assert_eq(McpClientConfigurator.mode_override(), "dev", "Empty EditorSetting falls through to env var")

	# Restore.
	if had_setting:
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, prior_setting)
	else:
		# No cross-platform "erase" on EditorSettings — leave an empty string
		# which `mode_override()` treats identically to unset.
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "")
	if prior_env.is_empty():
		OS.unset_environment("GODOT_AI_MODE")
	else:
		OS.set_environment("GODOT_AI_MODE", prior_env)


func test_is_symlink_detects_real_symlink() -> void:
	## Create a temp symlink under user:// and assert the helper reports it
	## as one. Skipped on Windows where `ln -s` requires admin privileges
	## and the fsutil path isn't exercisable in a unit test.
	if OS.get_name() == "Windows":
		skip("symlink creation requires admin on Windows")
		return
	var target := _scratch_dir.path_join("symlink_target.txt")
	var link := _scratch_dir.path_join("symlink_source")
	_remove_if_exists(target)
	_remove_if_exists(link)
	var f := FileAccess.open(target, FileAccess.WRITE)
	f.store_string("hello")
	f.close()
	var exit := OS.execute("ln", ["-s", target, link], [], true)
	assert_eq(exit, 0, "ln -s must succeed in writable user://")
	assert_true(McpClientConfigurator._is_symlink(link), "_is_symlink should detect freshly-created symlink")
	assert_false(McpClientConfigurator._is_symlink(target), "_is_symlink should reject regular file")
	# Cleanup
	DirAccess.remove_absolute(link)
	DirAccess.remove_absolute(target)


# ----- path template -----

func test_path_template_expands_home() -> void:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	if home.is_empty():
		assert_true(false, "HOME / USERPROFILE not set in test environment")
		return
	var resolved := McpPathTemplate.expand("~/foo/bar.json")
	assert_eq(resolved, home.path_join("foo/bar.json"))


func test_path_template_xdg_fallback() -> void:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		assert_true(false, "HOME not set")
		return
	var resolved := McpPathTemplate.expand("$XDG_CONFIG_HOME/foo")
	# Either uses XDG_CONFIG_HOME if set, or falls back to ~/.config
	assert_true(resolved.ends_with("/foo"))


# ----- JSON strategy round-trip -----

func test_json_strategy_round_trip() -> void:
	var path := _scratch_dir.path_join("json_round_trip.json")
	_remove_if_exists(path)
	var client := _make_test_json_client(path)

	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")
	assert_true(FileAccess.file_exists(path))

	var status := McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(status, McpClient.Status.CONFIGURED)

	# A wrong URL should not be reported as configured.
	var wrong_status := McpJsonStrategy.check_status(client, "godot-ai", "http://wrong/")
	assert_eq(wrong_status, McpClient.Status.NOT_CONFIGURED)

	var removed := McpJsonStrategy.remove(client, "godot-ai")
	assert_eq(removed.get("status"), "ok")
	assert_eq(McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"), McpClient.Status.NOT_CONFIGURED)


func test_json_strategy_preserves_other_servers() -> void:
	var path := _scratch_dir.path_join("preserve.json")
	# Pre-seed the file with another server entry that must survive.
	var seed := {"mcpServers": {"someone-else": {"url": "http://other/"}}}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(seed))
	f.close()

	var client := _make_test_json_client(path)
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")

	var content_file := FileAccess.open(path, FileAccess.READ)
	var content := content_file.get_as_text()
	content_file.close()
	var parsed = JSON.parse_string(content)
	assert_true(parsed.has("mcpServers"))
	assert_true(parsed["mcpServers"].has("someone-else"), "Existing entry was wiped")
	assert_true(parsed["mcpServers"].has("godot-ai"), "Our entry not added")


func test_json_strategy_supports_nested_key_path() -> void:
	var path := _scratch_dir.path_join("nested.json")
	_remove_if_exists(path)
	var client := McpClient.new()
	client.id = "nested_test"
	client.display_name = "Nested Test"
	client.config_type = "json"
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	# Mirror OpenCode's `mcp.<name>` shape.
	client.server_key_path = PackedStringArray(["mcp"])
	client.entry_builder = func(_n: String, u: String) -> Dictionary:
		return {"type": "remote", "url": u}

	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")
	var status := McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(status, McpClient.Status.CONFIGURED)


# ----- TOML strategy round-trip -----

func test_toml_strategy_round_trip() -> void:
	var path := _scratch_dir.path_join("config.toml")
	_remove_if_exists(path)
	var client := _make_test_toml_client(path)

	var result := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")

	var status := McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(status, McpClient.Status.CONFIGURED)

	var removed := McpTomlStrategy.remove(client, "godot-ai")
	assert_eq(removed.get("status"), "ok")
	assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"), McpClient.Status.NOT_CONFIGURED)


func test_toml_strategy_preserves_other_sections() -> void:
	var path := _scratch_dir.path_join("preserve.toml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[other_section]\nkey = \"value\"\n")
	f.close()

	var client := _make_test_toml_client(path)
	var result := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")

	var content_file := FileAccess.open(path, FileAccess.READ)
	var content := content_file.get_as_text()
	content_file.close()
	assert_contains(content, "[other_section]")
	assert_contains(content, "[mcp_servers.\"godot-ai\"]")


# ----- atomic write -----

func test_atomic_write_replaces_existing_content() -> void:
	var path := _scratch_dir.path_join("atomic.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("old content")
	f.close()

	assert_true(McpAtomicWrite.write(path, "new content"))
	var read_file := FileAccess.open(path, FileAccess.READ)
	var got := read_file.get_as_text()
	read_file.close()
	assert_eq(got, "new content")


func test_atomic_write_creates_parent_dir() -> void:
	var path := _scratch_dir.path_join("nested/dir/file.txt")
	assert_true(McpAtomicWrite.write(path, "hello"))
	assert_true(FileAccess.file_exists(path))


# ----- handler -----

func test_handler_rejects_unknown_client() -> void:
	var result := _handler.configure_client({"client": "nonexistent_client_xyz"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_handler_status_returns_array_of_clients() -> void:
	var result := _handler.check_client_status({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "clients")
	var clients = result.data.clients
	assert_true(clients is Array)
	assert_gt(clients.size(), 10)
	# Each entry must include id / display_name / status / installed.
	for entry in clients:
		assert_has_key(entry, "id")
		assert_has_key(entry, "display_name")
		assert_has_key(entry, "status")
		assert_has_key(entry, "installed")


# ----- entry-builder shape sanity for shipped clients -----

func test_cursor_entry_uses_url() -> void:
	var c := McpClientRegistry.get_by_id("cursor")
	var entry: Dictionary = c.entry_builder.call("godot-ai", "http://x")
	assert_eq(entry.get("url", ""), "http://x")


func test_antigravity_entry_uses_serverUrl() -> void:
	var c := McpClientRegistry.get_by_id("antigravity")
	var entry: Dictionary = c.entry_builder.call("godot-ai", "http://x")
	assert_eq(entry.get("serverUrl", ""), "http://x")
	assert_eq(entry.get("disabled", true), false)


func test_gemini_cli_entry_uses_httpUrl() -> void:
	var c := McpClientRegistry.get_by_id("gemini_cli")
	var entry: Dictionary = c.entry_builder.call("godot-ai", "http://x")
	assert_eq(entry.get("httpUrl", ""), "http://x")


func test_claude_desktop_bridges_via_npx() -> void:
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var entry: Dictionary = c.entry_builder.call("godot-ai", "http://x")
	assert_eq(entry.get("command", ""), "npx")
	var args = entry.get("args", [])
	assert_true(args is Array)
	assert_contains(args, "http://x")


func test_vscode_uses_servers_key_with_type_http() -> void:
	var c := McpClientRegistry.get_by_id("vscode")
	assert_eq(c.server_key_path.size(), 1)
	assert_eq(c.server_key_path[0], "servers")
	var entry: Dictionary = c.entry_builder.call("godot-ai", "http://x")
	assert_eq(entry.get("type", ""), "http")
	assert_eq(entry.get("url", ""), "http://x")


# ----- helpers -----

func _make_test_json_client(path: String) -> McpClient:
	var c := McpClient.new()
	c.id = "json_test"
	c.display_name = "JSON Test"
	c.config_type = "json"
	c.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	c.server_key_path = PackedStringArray(["mcpServers"])
	c.entry_builder = func(_n: String, u: String) -> Dictionary:
		return {"url": u}
	return c


func _make_test_toml_client(path: String) -> McpClient:
	var c := McpClient.new()
	c.id = "toml_test"
	c.display_name = "TOML Test"
	c.config_type = "toml"
	c.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	c.toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	c.toml_body_builder = func(u: String) -> PackedStringArray:
		return PackedStringArray(["url = \"%s\"" % u, "enabled = true"])
	return c


func _remove_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
