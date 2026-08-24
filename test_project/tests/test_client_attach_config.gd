@tool
extends McpTestSuite

## #816 rollout steps 5-6: launch discovery plus Codex's TOML command shape.

var _scratch_dir: String
var _saved_client_scope: Variant = null


func suite_name() -> String:
	return "client_attach_config"


func suite_setup(_ctx: Dictionary) -> void:
	_scratch_dir = OS.get_user_data_dir().path_join("mcp_attach_client_tests")
	DirAccess.make_dir_recursive_absolute(_scratch_dir)
	## #876: pin `godot_ai/mcp_client_scope` to the default for this suite.
	## `_claude_cli_clone()` copies the real descriptor's `{scope}` templates
	## (but deliberately not `cli_scope_status_template` — these tests prove
	## the JSON fallback file is authoritative), and that premise only holds
	## at the default `user` scope: at `project`/`local` the configurator
	## routes status away from the file and the clone's fake CLI spawn-fails
	## to NOT_CONFIGURED. The user's ambient editor setting must not decide
	## whether this suite passes.
	var es := EditorInterface.get_editor_settings()
	if es != null:
		if es.has_setting(McpSettings.SETTING_CLIENT_SCOPE):
			_saved_client_scope = es.get_setting(McpSettings.SETTING_CLIENT_SCOPE)
		es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, McpSettings.DEFAULT_CLIENT_SCOPE)


func suite_teardown() -> void:
	for file_name in DirAccess.get_files_at(_scratch_dir):
		DirAccess.remove_absolute(_scratch_dir.path_join(file_name))
	var es := EditorInterface.get_editor_settings()
	if es != null:
		if _saved_client_scope == null:
			es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, McpSettings.DEFAULT_CLIENT_SCOPE)
		else:
			es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, _saved_client_scope)


func test_codex_descriptor_declares_attach_shape_and_timeouts() -> void:
	var client := McpClientRegistry.get_by_id("codex")
	assert_true(client != null, "Codex descriptor must be registered")
	assert_eq(client.command_shape, McpClient.CommandShape.COMMAND_ARRAY)
	assert_true(client.command_legacy_keys.find("url") >= 0, "Codex migration must remove the legacy url key")
	assert_eq(client.command_initial_fields.get("enabled"), true)
	assert_eq(client.command_initial_fields.get("startup_timeout_sec"), 60)
	assert_eq(client.command_initial_fields.get("tool_timeout_sec"), 360)


func test_launch_resolver_dev_venv_shape() -> void:
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context("audio"),
		{
			"venv_python": "C:/repo/.venv/Scripts/python.exe",
			"uvx_path": "",
			"system_path": "",
			"consoleless_python": "C:/repo/.venv/Scripts/pythonw.exe",
		},
	)
	assert_true(bool(launch.get("ok", false)))
	assert_eq(launch.get("tier"), "dev_venv")
	assert_eq(launch.get("command"), "C:/repo/.venv/Scripts/pythonw.exe")
	assert_eq(
		launch.get("args"),
		["-m", "godot_ai", "attach", "--port", "8123", "--ws-port", "9623", "--exclude-domains", "audio"],
	)


func test_disabled_telemetry_renders_flag_and_participates_in_drift() -> void:
	## The editor's env-injection opt-out path never runs for a client-spawned
	## bridge/backend, so the preference must ride the attach argv (#838 smoke).
	var overrides := {
		"venv_python": "C:/repo/.venv/Scripts/python.exe",
		"uvx_path": "",
		"system_path": "",
		"consoleless_python": "C:/repo/.venv/Scripts/pythonw.exe",
	}
	var context := _context()
	context["telemetry_enabled"] = false
	var launch := McpClientConfigurator.resolve_attach_launch(context, overrides)
	assert_true(bool(launch.get("ok", false)))
	assert_eq(
		launch.get("args"),
		["-m", "godot_ai", "attach", "--port", "8123", "--ws-port", "9623", "--disable-telemetry"],
	)

	## Enabled AND absent (hand-built contexts, stale pre-upgrade snapshots)
	## must both render without the flag — send-by-default matches the server.
	var enabled_context := _context()
	enabled_context["telemetry_enabled"] = true
	for ctx in [enabled_context, _context()]:
		var clean := McpClientConfigurator.resolve_attach_launch(ctx, overrides)
		assert_eq(
			clean.get("args"),
			["-m", "godot_ai", "attach", "--port", "8123", "--ws-port", "9623"],
			"telemetry on (or unspecified) must not add the flag",
		)

	## A toggle is launch drift: distinct cache keys, so a stale resolution
	## cannot serve an argv rendered under the old preference.
	assert_ne(
		McpClientConfigurator._attach_launch_cache_key(context),
		McpClientConfigurator._attach_launch_cache_key(enabled_context),
		"telemetry preference must key the launch cache",
	)


func test_windows_dev_resolver_discovers_sibling_pythonw() -> void:
	var python := _scratch_dir.path_join("python.exe")
	var pythonw := _scratch_dir.path_join("pythonw.exe")
	_write(python, "")
	_write(pythonw, "")
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context(), {"venv_python": python, "uvx_path": "", "system_path": ""}
	)
	assert_true(bool(launch.get("ok", false)))
	assert_eq(launch.get("tier"), "dev_venv")
	assert_eq(launch.get("command"), pythonw)


func test_launch_resolver_uvx_is_strict_and_pinned() -> void:
	var launch := _uvx_launch("audio,particle")
	assert_true(bool(launch.get("ok", false)))
	assert_eq(launch.get("tier"), "uvx")
	assert_eq(launch.get("command"), "C:/Python313/pythonw.exe")
	assert_eq(launch.get("args", [])[0], "-c")
	assert_contains(str(launch.get("args", [])[1]), "creationflags=0x08000000")
	assert_eq(launch.get("args", [])[2], "C:/Tools/uv/uvx.exe")
	assert_eq(
		launch.get("args", []).slice(3),
		[
			"--link-mode", "copy",
			"--from", "godot-ai==3.0.6",
			"godot-ai", "attach",
			"--port", "8123",
			"--ws-port", "9623",
			"--exclude-domains", "audio,particle",
		],
	)


func test_launch_resolver_system_requires_exact_parseable_version() -> void:
	var compatible := McpClientConfigurator.resolve_attach_launch(
		_context(),
		{
			"venv_python": "",
			"uvx_path": "",
			"system_path": "C:/Tools/godot-ai.exe",
			"consoleless_python": "C:/Python313/pythonw.exe",
			"system_version_result": _probe("godot-ai 3.0.6\n"),
		},
	)
	assert_true(bool(compatible.get("ok", false)))
	assert_eq(compatible.get("tier"), "system")
	assert_eq(compatible.get("command"), "C:/Python313/pythonw.exe")
	assert_eq(compatible.get("args", [])[2], "C:/Tools/godot-ai.exe")
	assert_eq(
		compatible.get("args", []).slice(3),
		["attach", "--port", "8123", "--ws-port", "9623"],
	)

	for bad_probe in [
		_probe("godot-ai 3.0.5\n"),
		_probe("unexpected output\n"),
		{"exit_code": -1, "stdout": "", "timed_out": true},
	]:
		var failed := McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "",
				"uvx_path": "",
				"system_path": "C:/Tools/godot-ai.exe",
				"consoleless_python": "C:/Python313/pythonw.exe",
				"system_version_result": bad_probe,
			},
		)
		assert_false(bool(failed.get("ok", true)), "bad system probe must not configure: %s" % str(bad_probe))
		assert_false(str(failed.get("error", "")).is_empty())


func test_launch_resolver_no_tier_never_returns_bare_uvx() -> void:
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context(), {"venv_python": "", "uvx_path": "", "system_path": ""}
	)
	assert_false(bool(launch.get("ok", true)))
	assert_false(launch.has("command"), "failed discovery must not write a bare uvx command")
	assert_contains(str(launch.get("error", "")), "Install uv")


func test_windows_launch_requires_consoleless_python_without_writing_a_console_command() -> void:
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context(),
		{
			"venv_python": "C:/repo/.venv/Scripts/python.exe",
			"uvx_path": "",
			"system_path": "",
			"consoleless_python": "",
		},
	)
	assert_false(bool(launch.get("ok", true)))
	assert_false(launch.has("command"))
	assert_contains(str(launch.get("error", "")), "pythonw.exe")


func test_non_windows_launch_shape_stays_direct() -> void:
	var context := _context()
	context["platform"] = "Linux"
	var launch := McpClientConfigurator.resolve_attach_launch(
		context,
		{
			"venv_python": "",
			"uvx_path": "/home/agent/.local/bin/uvx",
			"system_path": "",
		},
	)
	assert_true(bool(launch.get("ok", false)))
	assert_eq(launch.get("command"), "/home/agent/.local/bin/uvx")
	assert_eq(launch.get("args", [])[0], "--link-mode")


func test_launch_for_client_unwraps_pythonw_for_opted_out_clients() -> void:
	## #863: Antigravity hangs stdio tool calls behind a GUI-subsystem
	## pythonw.exe, so its descriptor opts out of the consoleless launcher and
	## must receive the plain console command on Windows.
	var antigravity := McpClientRegistry.get_by_id("antigravity")
	assert_false(
		antigravity.needs_consoleless_launcher,
		"antigravity must opt out of the pythonw launcher (#863)",
	)
	var launch := _uvx_launch("audio")
	assert_eq(launch.get("command"), "C:/Python313/pythonw.exe")
	var console := McpClientConfigurator.launch_for_client(antigravity, launch)
	assert_eq(console.get("command"), "C:/Tools/uv/uvx.exe")
	assert_eq(console.get("args", [])[0], "--link-mode")
	assert_false(
		str(console.get("args", [])).contains("creationflags"),
		"console launch must not carry the pythonw bootstrap",
	)
	assert_false(console.has("console_command"), "console keys are internal-only")
	assert_eq(
		McpClientConfigurator.launch_for_client(antigravity, console),
		console,
		"launch_for_client must be idempotent",
	)


func test_launch_for_client_dev_venv_returns_console_python() -> void:
	var antigravity := McpClientRegistry.get_by_id("antigravity")
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context(),
		{
			"venv_python": "C:/repo/.venv/Scripts/python.exe",
			"uvx_path": "",
			"system_path": "",
			"consoleless_python": "C:/repo/.venv/Scripts/pythonw.exe",
		},
	)
	var console := McpClientConfigurator.launch_for_client(antigravity, launch)
	assert_eq(console.get("command"), "C:/repo/.venv/Scripts/python.exe")
	assert_eq(console.get("args"), launch.get("args"), "dev tier args are shared verbatim")


func test_launch_for_client_keeps_pythonw_for_default_clients() -> void:
	var codex := McpClientRegistry.get_by_id("codex")
	assert_true(
		codex.needs_consoleless_launcher,
		"codex needs the pythonw launcher — its terminal problem is why it exists (#827)",
	)
	var launch := _uvx_launch()
	var kept := McpClientConfigurator.launch_for_client(codex, launch)
	assert_eq(kept.get("command"), "C:/Python313/pythonw.exe")
	assert_eq(kept.get("args"), launch.get("args"))


func test_launch_for_client_non_windows_launch_is_untouched() -> void:
	var antigravity := McpClientRegistry.get_by_id("antigravity")
	var context := _context()
	context["platform"] = "Linux"
	var launch := McpClientConfigurator.resolve_attach_launch(
		context,
		{"venv_python": "", "uvx_path": "/home/agent/.local/bin/uvx", "system_path": ""},
	)
	assert_false(launch.has("console_command"), "non-Windows launches carry no console shape")
	assert_eq(McpClientConfigurator.launch_for_client(antigravity, launch), launch)


func test_launch_context_values_are_worker_safe_and_exclusions_are_canonical() -> void:
	var canonical_domains := McpClientConfigurator._canonicalize_excluded_domains(
		" particle, audio,particle,unknown "
	)
	assert_eq(canonical_domains, "audio,particle")
	var thread := Thread.new()
	var err := thread.start(
		Callable(self, "_resolve_on_worker").bind(
			_context(canonical_domains),
			{
				"venv_python": "",
				"uvx_path": "C:/Tools/uv/uvx.exe",
				"system_path": "",
				"consoleless_python": "C:/Python313/pythonw.exe",
			},
		)
	)
	assert_eq(err, OK, "launch resolver worker should start")
	var launch: Dictionary = thread.wait_to_finish()
	assert_true(bool(launch.get("ok", false)))
	assert_contains(launch.get("args", []), "audio,particle")


func test_attach_launch_session_cache_is_keyed_copied_and_invalidated() -> void:
	var context := _context("audio")
	var cache_key := McpClientConfigurator._attach_launch_cache_key(context)
	var changed := context.duplicate(true)
	changed["http_port"] = 8999
	assert_ne(
		cache_key,
		McpClientConfigurator._attach_launch_cache_key(changed),
		"settings that alter attach argv must produce a distinct cache key",
	)

	McpClientConfigurator.invalidate_uv_detection()
	McpClientConfigurator._attach_launch_cache_mutex.lock()
	McpClientConfigurator._attach_launch_cache[cache_key] = {
		"ok": true, "tier": "cached", "command": "cached-command", "args": ["attach"],
	}
	McpClientConfigurator._attach_launch_cache_mutex.unlock()
	var first := McpClientConfigurator.resolve_attach_launch(context)
	assert_eq(first.get("tier"), "cached", "production resolution must reuse the session cache")
	first["tier"] = "mutated-by-caller"
	first["args"][0] = "mutated-nested-arg"
	var second := McpClientConfigurator.resolve_attach_launch(context)
	assert_eq(second.get("tier"), "cached", "callers must receive an isolated cache copy")
	assert_eq(
		second.get("args", [])[0],
		"attach",
		"nested values returned from the cache must also be isolated copies",
	)
	McpClientConfigurator.invalidate_uv_detection()
	McpClientConfigurator._attach_launch_cache_mutex.lock()
	var still_cached := McpClientConfigurator._attach_launch_cache.has(cache_key)
	McpClientConfigurator._attach_launch_cache_mutex.unlock()
	assert_false(still_cached, "uv detection invalidation must also clear attach launch discovery")


func test_toml_encoder_matches_tomllib_fixture() -> void:
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context("audio,particle"),
		{
			"venv_python": "",
			"uvx_path": 'C:\\Users\\Agent "quoted"\\bin\\uvx.exe',
			"system_path": "",
			"consoleless_python": "C:/Python313/pythonw.exe",
		},
	)
	var command := str(launch.get("command", ""))
	var args: Array = launch.get("args", [])
	var rendered: Array[String] = [
		"[samples.uvx]",
		"command = %s" % McpTomlStrategy.encode_basic_string(command),
	]
	var encoded_args := McpTomlStrategy.encode_string_array(args)
	encoded_args[0] = "args = %s" % encoded_args[0]
	rendered.append_array(encoded_args)
	var fixture := FileAccess.open("res://tests/fixtures/attach_toml_samples.toml", FileAccess.READ)
	assert_true(fixture != null, "cross-language TOML fixture must be readable")
	## Git may check this fixture out with CRLF on Windows while the renderer
	## deliberately joins logical TOML lines with LF. Compare normalized text.
	var expected := fixture.get_as_text().replace("\r\n", "\n").strip_edges()
	fixture.close()
	assert_eq("\n".join(rendered), expected)


func test_codex_render_for_all_discovery_tiers() -> void:
	var launches := [
		McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "C:/repo/.venv/Scripts/python.exe",
				"uvx_path": "",
				"system_path": "",
				"consoleless_python": "C:/repo/.venv/Scripts/pythonw.exe",
			}
		),
		_uvx_launch(),
		McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "", "uvx_path": "", "system_path": "C:/Tools/godot-ai.exe",
				"consoleless_python": "C:/Python313/pythonw.exe",
				"system_version_result": _probe("godot-ai 3.0.6\n"),
			},
		),
	]
	for idx in range(launches.size()):
		var path := _scratch_dir.path_join("tier_%d.toml" % idx)
		var client := _codex_client(path)
		var result := McpTomlStrategy.configure(client, "godot-ai", "http://unused", launches[idx])
		assert_eq(result.get("status"), "ok")
		var content := _read(path)
		assert_contains(content, "command = ")
		assert_contains(content, "args = [")
		assert_contains(content, '"attach"')
		assert_contains(content, "startup_timeout_sec = 60")
		assert_contains(content, "tool_timeout_sec = 360")
		assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launches[idx]), McpClient.Status.CONFIGURED)
		if str(launches[idx].get("tier", "")) == "uvx":
			assert_contains(content, '"--link-mode"')
		else:
			assert_false(content.contains('"--link-mode"'))


func test_claude_json_render_for_all_discovery_tiers() -> void:
	var launches := [
		McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "C:/repo/.venv/Scripts/python.exe",
				"uvx_path": "",
				"system_path": "",
				"consoleless_python": "C:/repo/.venv/Scripts/pythonw.exe",
			}
		),
		_uvx_launch(),
		McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "", "uvx_path": "", "system_path": "C:/Tools/godot-ai.exe",
				"consoleless_python": "C:/Python313/pythonw.exe",
				"system_version_result": _probe("godot-ai 3.0.6\n"),
			},
		),
	]
	var client := McpClientRegistry.get_by_id("claude_desktop")
	for launch in launches:
		var entry := McpJsonStrategy.build_entry(client, "http://unused", null, launch)
		assert_eq(entry.get("command"), launch.get("command"))
		assert_eq(entry.get("args"), launch.get("args"))
		assert_true(McpJsonStrategy.verify_entry(client, entry, "http://unused", launch))


func test_json_encoder_matches_python_fixture() -> void:
	var launch := McpClientConfigurator.resolve_attach_launch(
		_context("audio,particle"),
		{
			"venv_python": "",
			"uvx_path": 'C:\\Users\\Agent "quoted"\\bin\\uvx.exe',
			"system_path": "",
			"consoleless_python": "C:/Python313/pythonw.exe",
		},
	)
	var client := McpClientRegistry.get_by_id("claude_desktop")
	var rendered := McpJsonStrategy.build_entry(client, "http://unused", null, launch)
	var fixture := FileAccess.open("res://tests/fixtures/attach_json_sample.json", FileAccess.READ)
	assert_true(fixture != null, "cross-language JSON fixture must be readable")
	var expected = JSON.parse_string(fixture.get_as_text())
	fixture.close()
	assert_eq(rendered, expected)


func test_codex_migration_preserves_multiline_values_and_renames_legacy_subtables() -> void:
	var path := _scratch_dir.path_join("legacy_migration.toml")
	var original_span := (
		"enabled_tools = [\n"
		+ "  \"scene_get_hierarchy\", # keep this comment\n"
		+ "  \"editor_state\",\n"
		+ "]\n"
		+ "description = \"\"\"\n"
		+ "user-owned multiline text\n"
		+ "must survive byte-for-byte\n"
		+ "\"\"\"\n"
		+ "# adjacent user comment"
	)
	_write(
		path,
		"[mcp_servers.godot_ai]\n"
		+ "url = \"http://127.0.0.1:8000/mcp\"\n"
		+ "enabled = false\n"
		+ "startup_timeout_sec = 75\n"
		+ "tool_timeout_sec = 420\n"
		+ original_span + "\n\n"
		+ "[mcp_servers.godot_ai.tools.test_run]\n"
		+ "approval_mode = \"approve\"\n",
	)
	var client := _codex_client(path)
	var result := McpTomlStrategy.configure(client, "godot-ai", "http://unused", _uvx_launch())
	assert_eq(result.get("status"), "ok")
	var content := _read(path)
	assert_false(content.contains("url ="), "legacy URL must be removed")
	assert_contains(content, "enabled = false")
	assert_contains(content, "startup_timeout_sec = 75")
	assert_contains(content, "tool_timeout_sec = 420")
	assert_contains(content, original_span, "complete multiline spans/comments must survive")
	assert_contains(content, '[mcp_servers."godot-ai".tools.test_run]')
	assert_false(content.contains("mcp_servers.godot_ai"), "legacy parent and descendants must be renamed")
	assert_contains(content, 'approval_mode = "approve"')


func test_codex_status_is_semantic_and_detects_each_launch_drift() -> void:
	var path := _scratch_dir.path_join("semantic_status.toml")
	var client := _codex_client(path)
	var launch := _uvx_launch("audio")
	var args: Array = launch.get("args", [])
	var formatted_args: Array[String] = []
	for idx in range(args.size()):
		formatted_args.append("  %s%s" % [
			McpTomlStrategy.encode_basic_string(str(args[idx])),
			", # comment" if str(args[idx]) == "--link-mode" else ",",
		])
	_write(
		path,
		'[mcp_servers."godot-ai"]\n'
		+ "command = '%s' # literal string formatting\n" % str(launch.get("command", ""))
		+ "args = [\n%s\n]\n" % "\n".join(formatted_args)
		+ "enabled = false\n"
		+ "unknown_user_key = \"ignored\"\n",
	)
	assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launch), McpClient.Status.CONFIGURED)

	var fresh := _read(path)
	var inline_args: Array[String] = []
	for arg in args:
		inline_args.append(McpTomlStrategy.encode_basic_string(str(arg)))
	_write(
		path,
		'[mcp_servers."godot-ai"]\ncommand = %s\nargs = [%s] # equivalent inline formatting\n'
		% [
			McpTomlStrategy.encode_basic_string(str(launch.get("command", ""))),
			", ".join(inline_args),
		],
	)
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "", launch),
		McpClient.Status.CONFIGURED,
		"single-line and multiline args must verify semantically",
	)
	_write(path, fresh)
	for replacement in [
		["godot-ai==3.0.6", "godot-ai==3.0.5"],
		['"8123"', '"8999"'],
		['"9623"', '"9999"'],
		['"audio"', '"particle"'],
		["C:/Tools/uv/uvx.exe", "C:/Other/uvx.exe"],
	]:
		_write(path, fresh.replace(replacement[0], replacement[1]))
		assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launch), McpClient.Status.CONFIGURED_MISMATCH)
	var without_link_mode := fresh.replace('  "--link-mode", # comment\n  "copy",', "")
	assert_ne(without_link_mode, fresh, "link-mode mutation must alter the fixture")
	_write(path, without_link_mode)
	assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launch), McpClient.Status.CONFIGURED_MISMATCH)
	_write(path, fresh.replace("args = [", "args = [\"unterminated"))
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "", launch),
		McpClient.Status.CONFIGURED_MISMATCH,
		"malformed launch values must not be treated as configured",
	)


func test_venv_and_system_entries_do_not_require_uvx_options() -> void:
	for launch in [
		McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "C:/repo/.venv/Scripts/python.exe",
				"uvx_path": "",
				"system_path": "",
				"consoleless_python": "C:/repo/.venv/Scripts/pythonw.exe",
			}
		),
		McpClientConfigurator.resolve_attach_launch(
			_context(),
			{
				"venv_python": "", "uvx_path": "", "system_path": "C:/Tools/godot-ai.exe",
				"consoleless_python": "C:/Python313/pythonw.exe",
				"system_version_result": _probe("godot-ai 3.0.6\n"),
			},
		),
	]:
		var path := _scratch_dir.path_join("non_uvx_%s.toml" % str(launch.get("tier", "")))
		var client := _codex_client(path)
		assert_eq(McpTomlStrategy.configure(client, "godot-ai", "", launch).get("status"), "ok")
		assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launch), McpClient.Status.CONFIGURED)
		assert_false(_read(path).contains("--link-mode"))


func test_legacy_url_is_mismatch_and_missing_launcher_is_error_without_write() -> void:
	var path := _scratch_dir.path_join("url_and_no_launcher.toml")
	var original := '[mcp_servers."godot-ai"]\nurl = "http://127.0.0.1:8123/mcp"\nenabled = false\n'
	_write(path, original)
	var client := _codex_client(path)
	var launch := _uvx_launch()
	assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launch), McpClient.Status.CONFIGURED_MISMATCH)

	var unavailable := {"ok": false, "error": "Install uv or use URL mode."}
	var details := McpTomlStrategy.check_status_details(client, "godot-ai", "", unavailable)
	assert_eq(details.get("status"), McpClient.Status.ERROR)
	assert_contains(str(details.get("error_msg", "")), "Install uv")
	var configured := McpTomlStrategy.configure(client, "godot-ai", "", unavailable)
	assert_eq(configured.get("status"), "error")
	assert_eq(_read(path), original, "failed discovery must leave the config byte-identical")


func test_codex_manual_command_shows_attach_and_advanced_url_fallback() -> void:
	var client := _codex_client("C:/Users/Agent/.codex/config.toml")
	var manual := McpManualCommand.build(
		client,
		"godot-ai",
		"http://127.0.0.1:8123/mcp",
		"C:/Users/Agent/.codex/config.toml",
		_uvx_launch(),
	)
	assert_contains(manual, "command = ")
	assert_contains(manual, '"attach"')
	assert_contains(manual, "Advanced fallback")
	assert_contains(manual, "replace the command/args block above")
	assert_contains(manual, "never configure both shapes together")
	assert_contains(manual, 'url = "http://127.0.0.1:8123/mcp"')


func test_toml_command_transport_rejects_unsupported_values() -> void:
	var client := _codex_client(_scratch_dir.path_join("bad_transport.toml"))
	client.command_transport_key = "transport"
	client.command_transport_value = null
	var rendered := McpTomlStrategy.render_body(client, "http://unused", _uvx_launch())
	assert_false(bool(rendered.get("ok", true)))
	assert_contains(str(rendered.get("error", "")), "Unsupported TOML transport")


func test_server_url_from_prefers_captured_snapshot() -> void:
	assert_eq(
		McpClientConfigurator.server_url_from({"server_url": "http://captured:8123/mcp"}),
		"http://captured:8123/mcp",
	)


func test_registry_wide_attach_shape_declarations() -> void:
	## One row per registered client — the #838 decision table, pinned. A new
	## client must take an explicit position here (shape + pin + legacy keys).
	var expectations := {
		"claude_code": [McpClient.CommandShape.FLAT, "stdio", ["url"]],
		"claude_desktop": [McpClient.CommandShape.FLAT, null, ["url"]],
		"codex": [McpClient.CommandShape.COMMAND_ARRAY, null, ["url"]],
		"cursor": [McpClient.CommandShape.FLAT, "stdio", ["url"]],
		"antigravity": [McpClient.CommandShape.FLAT, null, ["serverUrl"]],
		"gemini_cli": [McpClient.CommandShape.FLAT, null, ["httpUrl", "url"]],
		"qwen_code": [McpClient.CommandShape.FLAT, null, ["httpUrl", "url"]],
		"kiro": [McpClient.CommandShape.FLAT, null, ["url"]],
		"kimi_code": [McpClient.CommandShape.FLAT, null, ["url", "transport"]],
		"windsurf": [McpClient.CommandShape.FLAT, null, ["serverUrl"]],
		"zed": [McpClient.CommandShape.FLAT, null, ["url", "headers", "oauth"]],
		"cline": [McpClient.CommandShape.FLAT, "stdio", ["url", "headers"]],
		"roo_code": [McpClient.CommandShape.FLAT, "stdio", ["url", "headers"]],
		"zoo_code": [McpClient.CommandShape.FLAT, "stdio", ["url", "headers"]],
		"kilo_code": [McpClient.CommandShape.FLAT, null, ["url", "type", "headers"]],
		"trae": [McpClient.CommandShape.FLAT, null, ["url", "headers"]],
		"vscode": [McpClient.CommandShape.FLAT, "stdio", ["url", "headers"]],
		"vscode_insiders": [McpClient.CommandShape.FLAT, "stdio", ["url", "headers"]],
		"opencode": [McpClient.CommandShape.COMMAND_ARRAY, "local", ["url", "headers"]],
		"grok": [McpClient.CommandShape.COMMAND_ARRAY, null, ["url", "headers"]],
		"hermes": [McpClient.CommandShape.FLAT, null, ["url", "headers"]],
		## cherry_studio deliberately stays URL-mode: its mcp_servers.json is
		## not read by the app at all (SQLite-backed) — see #838 follow-up.
		"cherry_studio": [McpClient.CommandShape.NONE, null, []],
	}
	for id in McpClientRegistry.ids():
		assert_true(expectations.has(String(id)), "client %s has no #838 shape expectation — add one" % id)
		var client := McpClientRegistry.get_by_id(String(id))
		var expected: Array = expectations[String(id)]
		assert_eq(client.command_shape, expected[0], "%s shape" % id)
		if expected[1] == null:
			assert_true(client.command_transport_key.is_empty(), "%s must not pin a transport" % id)
		else:
			assert_eq(client.command_transport_value, expected[1], "%s transport pin" % id)
		for legacy_key in expected[2]:
			assert_true(
				client.command_legacy_keys.has(String(legacy_key)),
				"%s must scrub legacy key %s" % [id, legacy_key],
			)
		if client.command_shape != McpClient.CommandShape.NONE and String(id) != "claude_desktop":
			assert_true(client.command_supports_url_fallback, "%s keeps a URL fallback" % id)


func test_cli_format_args_expands_launch_tokens_whole_element_only() -> void:
	var launch := _uvx_launch("audio")
	var argv := McpCliStrategy.format_args(
		PackedStringArray(["mcp", "add", "--scope", "user", "{name}", "--", "{command}", "{args...}"]),
		"godot-ai",
		"http://unused",
		launch,
	)
	var expected: Array[String] = ["mcp", "add", "--scope", "user", "godot-ai", "--", str(launch.get("command"))]
	for launch_arg in launch.get("args", []):
		expected.append(str(launch_arg))
	assert_eq(argv, expected)
	## Whole-element contract: embedded token text is NOT expanded, while the
	## substring tokens {name}/{url} keep their historical replacement rule.
	var literal := McpCliStrategy.format_args(
		PackedStringArray(["prefix-{command}", "x{args...}y", "{name}-suffix"]), "godot-ai", "u", launch
	)
	assert_eq(literal, ["prefix-{command}", "x{args...}y", "godot-ai-suffix"])


func test_cli_configure_and_status_fail_closed_without_launcher() -> void:
	var client := _claude_cli_clone(_scratch_dir.path_join("unused_cli.json"))
	var unavailable := {"ok": false, "error": "Install uv (provides uvx), then retry Configure."}
	var result := McpCliStrategy.configure(client, "godot-ai", "http://unused", unavailable)
	assert_eq(result.get("status"), "error")
	assert_contains(str(result.get("message", "")), "Install uv")
	## The launch gate must precede any CLI probing — a bogus binary never
	## spawns, and the error names the launcher problem, not the binary.
	assert_false(str(result.get("message", "")).contains("not found"))
	var details := McpCliStrategy.check_status_details(
		client, "godot-ai", "http://unused", "/definitely/missing/claude", unavailable
	)
	assert_eq(details.get("status"), McpClient.Status.ERROR)
	assert_contains(str(details.get("error_msg", "")), "Install uv")


func test_claude_cli_json_fallback_migrates_legacy_http_entry() -> void:
	var path := _scratch_dir.path_join("claude_cli_fallback.json")
	var launch := _uvx_launch()
	_write(
		path,
		JSON.stringify({
			"mcpServers": {
				"godot-ai": {"type": "http", "url": "http://127.0.0.1:8000/mcp"},
				"someone-else": {"type": "http", "url": "http://other/"},
			}
		}),
	)
	var client := _claude_cli_clone(path)
	## Legacy HTTP entry reads as migration drift, with a "present" fake CLI —
	## proving the JSON file is authoritative for command-shape CLI clients.
	var before := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "http://127.0.0.1:8000/mcp", "/fake/claude-not-invoked", {}, launch
	)
	assert_eq(before.get("status"), McpClient.Status.CONFIGURED_MISMATCH)
	## The clone's cli_names never resolve, so dispatch takes the JSON
	## fallback write path with the launch threaded through.
	var result := McpClientConfigurator._dispatch_configure(client, "http://127.0.0.1:8000/mcp", launch)
	assert_eq(result.get("status"), "ok", str(result.get("message", "")))
	var written: Dictionary = JSON.parse_string(_read(path))
	var entry: Dictionary = written.get("mcpServers", {}).get("godot-ai", {})
	assert_eq(entry.get("type"), "stdio", "legacy http pin must flip to stdio")
	assert_false(entry.has("url"), "legacy url must be removed")
	assert_eq(entry.get("command"), launch.get("command"))
	assert_eq(entry.get("args"), launch.get("args"))
	assert_true(written.get("mcpServers", {}).has("someone-else"), "unrelated entries survive")
	var after := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "http://127.0.0.1:8000/mcp", "/fake/claude-not-invoked", {}, launch
	)
	assert_eq(after.get("status"), McpClient.Status.CONFIGURED)
	## An env: {} written by the real `claude mcp add` must not read as drift.
	entry["env"] = {}
	written["mcpServers"]["godot-ai"] = entry
	_write(path, JSON.stringify(written))
	var with_empty_env := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "http://127.0.0.1:8000/mcp", "/fake/claude-not-invoked", {}, launch
	)
	assert_eq(with_empty_env.get("status"), McpClient.Status.CONFIGURED)


func test_opencode_command_array_renders_and_migrates() -> void:
	var launch := _uvx_launch("audio")
	var client := McpClientRegistry.get_by_id("opencode")
	var legacy := {
		"type": "remote",
		"url": "http://127.0.0.1:8000/mcp",
		"enabled": false,
		"environment": {"KEEP": "1"},
	}
	var entry := McpJsonStrategy.build_entry(client, "http://unused", legacy, launch)
	var expected_argv: Array = [str(launch.get("command"))]
	expected_argv.append_array(launch.get("args", []))
	assert_eq(entry.get("command"), expected_argv, "command must be ONE argv array")
	assert_false(entry.has("args"), "OpenCode has no separate args key")
	assert_eq(entry.get("type"), "local", "schema-required discriminator must flip remote→local")
	assert_false(entry.has("url"))
	assert_eq(entry.get("enabled"), false, "user toggle survives")
	assert_eq(entry.get("environment", {}).get("KEEP"), "1", "user environment survives")
	assert_true(McpJsonStrategy.verify_entry(client, entry, "http://unused", launch))
	var stray_args := entry.duplicate(true)
	stray_args["args"] = ["stale"]
	assert_false(
		McpJsonStrategy.verify_entry(client, stray_args, "http://unused", launch),
		"a stale sibling args key is drift — ambiguous next to the argv array",
	)
	var argv_drift := entry.duplicate(true)
	argv_drift["command"] = expected_argv.slice(0, expected_argv.size() - 1)
	assert_false(McpJsonStrategy.verify_entry(client, argv_drift, "http://unused", launch))
	var fresh := McpJsonStrategy.build_entry(client, "http://unused", null, launch)
	assert_eq(fresh.get("enabled"), true, "fresh entries seed enabled: true")


func test_grok_renders_attach_toml_and_preserves_undocumented_enabled() -> void:
	var path := _scratch_dir.path_join("grok_attach.toml")
	_write(
		path,
		'[mcp_servers."godot-ai"]\n'
		+ 'url = "http://127.0.0.1:8000/mcp"\n'
		+ "enabled = false\n"
		+ "tool_timeout_sec = 420\n",
	)
	var client := _grok_clone(path)
	var launch := _uvx_launch()
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "", launch),
		McpClient.Status.CONFIGURED_MISMATCH,
		"legacy url section must read as migration drift",
	)
	var result := McpTomlStrategy.configure(client, "godot-ai", "http://unused", launch)
	assert_eq(result.get("status"), "ok", str(result.get("message", "")))
	var content := _read(path)
	assert_false(content.contains("url ="), "legacy url must be removed")
	assert_contains(content, "command = ")
	assert_contains(content, "args = [")
	assert_contains(content, "enabled = false", "undocumented user key must survive untouched")
	assert_false(content.contains("enabled = true"), "seeding must not overwrite the user's toggle")
	assert_contains(content, "tool_timeout_sec = 420", "user-tuned timeout must survive")
	## Initial seeding is per-key: the legacy entry had no startup override, so
	## migration seeds the uvx cold-start headroom (docs default 30s is too
	## tight for a first `uvx` package install).
	assert_contains(content, "startup_timeout_sec = 60")
	assert_eq(McpTomlStrategy.check_status(client, "godot-ai", "", launch), McpClient.Status.CONFIGURED)
	## A user-tuned startup value must survive a later reconfigure untouched.
	_write(path, _read(path).replace("startup_timeout_sec = 60", "startup_timeout_sec = 90"))
	assert_eq(McpTomlStrategy.configure(client, "godot-ai", "http://unused", launch).get("status"), "ok")
	assert_contains(_read(path), "startup_timeout_sec = 90")


func _claude_cli_clone(path: String) -> McpClient:
	var registered := McpClientRegistry.get_by_id("claude_code")
	var client := McpClient.new()
	client.id = "claude_code_test"
	client.display_name = "Claude Code Test"
	client.config_type = "cli"
	client.cli_names = PackedStringArray(["definitely-missing-claude-xyz"])
	client.cli_register_template = registered.cli_register_template
	client.cli_unregister_template = registered.cli_unregister_template
	client.cli_status_args = registered.cli_status_args
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	client.server_key_path = PackedStringArray(["mcpServers"])
	client.entry_extra_fields = registered.entry_extra_fields.duplicate(true)
	client.command_shape = registered.command_shape
	client.command_transport_key = registered.command_transport_key
	client.command_transport_value = registered.command_transport_value
	client.command_legacy_keys = registered.command_legacy_keys
	client.command_user_fields = registered.command_user_fields
	client.command_supports_url_fallback = registered.command_supports_url_fallback
	return client


func _grok_clone(path: String) -> McpClient:
	var registered := McpClientRegistry.get_by_id("grok")
	var client := McpClient.new()
	client.id = "grok_test"
	client.display_name = "Grok Test"
	client.config_type = "toml"
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	client.toml_section_path = registered.toml_section_path
	client.toml_legacy_section_aliases = registered.toml_legacy_section_aliases
	client.command_shape = registered.command_shape
	client.command_supports_url_fallback = registered.command_supports_url_fallback
	client.command_legacy_keys = registered.command_legacy_keys
	client.command_initial_fields = registered.command_initial_fields.duplicate(true)
	client.command_user_fields = registered.command_user_fields
	client.command_timeout_fields = registered.command_timeout_fields
	return client


func _context(exclusions: String = "") -> Dictionary:
	return {
		"http_port": 8123,
		"ws_port": 9623,
		"excluded_domains": exclusions,
		"plugin_version": "3.0.6",
		"allow_dev_venv": true,
		"platform": "Windows",
		"server_url": "http://127.0.0.1:8123/mcp",
	}


func _uvx_launch(exclusions: String = "") -> Dictionary:
	return McpClientConfigurator.resolve_attach_launch(
		_context(exclusions),
		{
			"venv_python": "",
			"uvx_path": "C:/Tools/uv/uvx.exe",
			"system_path": "",
			"consoleless_python": "C:/Python313/pythonw.exe",
		},
	)


func _probe(stdout: String) -> Dictionary:
	return {"exit_code": 0, "stdout": stdout, "timed_out": false, "spawn_failed": false}


func _resolve_on_worker(context: Dictionary, overrides: Dictionary) -> Dictionary:
	return McpClientConfigurator.resolve_attach_launch(context, overrides)


func _codex_client(path: String) -> McpClient:
	var registered := McpClientRegistry.get_by_id("codex")
	var client := McpClient.new()
	client.id = "codex_test"
	client.display_name = "Codex Test"
	client.config_type = "toml"
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	client.toml_section_path = registered.toml_section_path
	client.toml_legacy_section_aliases = registered.toml_legacy_section_aliases
	client.command_shape = registered.command_shape
	client.command_supports_url_fallback = registered.command_supports_url_fallback
	client.command_legacy_keys = registered.command_legacy_keys
	client.command_initial_fields = registered.command_initial_fields.duplicate(true)
	client.command_user_fields = registered.command_user_fields
	client.command_timeout_fields = registered.command_timeout_fields
	return client


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "could not write scratch config: %s" % path)
	file.store_string(content)
	file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	assert_true(file != null, "could not read scratch config: %s" % path)
	var content := file.get_as_text()
	file.close()
	return content
