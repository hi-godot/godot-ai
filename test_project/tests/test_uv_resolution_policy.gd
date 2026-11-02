@tool
extends McpTestSuite

const Policy := preload("res://addons/godot_ai/utils/uv_resolution_policy.gd")


func suite_name() -> String:
	return "uv_resolution_policy"


func test_fixed_cutoff_and_only_own_package_exemption() -> void:
	var config := ConfigFile.new()
	assert_eq(config.load("res://addons/godot_ai/plugin.cfg"), OK)
	var cutoff: String = config.get_value("plugin", "dependency_cutoff", "")
	assert_false(cutoff.is_empty())
	assert_eq(Policy.validated_cutoff(cutoff), cutoff)
	var args := Policy.args()
	var index := args.find("--exclude-newer")
	assert_true(index >= 0 and index + 1 < args.size())
	if index < 0 or index + 1 >= args.size():
		return
	assert_eq(args[index + 1], cutoff)
	assert_eq(args.count("--exclude-newer"), 1)
	index = args.find("--exclude-newer-package")
	assert_true(index >= 0 and index + 1 < args.size())
	if index < 0 or index + 1 >= args.size():
		return
	assert_eq(args[index + 1], "godot-ai=false")
	assert_eq(args.count("--exclude-newer-package"), 1)


func test_cutoff_requires_complete_utc_calendar_time() -> void:
	assert_eq(Policy.validated_cutoff("2024-02-29T12:34:56Z"), "2024-02-29T12:34:56Z")
	for value in [null, 1, "0000-01-01T00:00:00Z", "", "2026-11-01", "2026-11-01T19:00:00", "2026-11-01T19:00:00+00:00", "2026-11-01T19:00:00Z extra", "2026-02-29T12:34:56Z", "2026-11-01T24:00:00Z"]:
		assert_eq(Policy.validated_cutoff(value), "", "reject %s" % str(value))


func test_old_public_commands_still_get_environment_isolation() -> void:
	var command := ["uvx", "--index", Policy.PUBLIC_INDEX, "--default-index", Policy.PUBLIC_INDEX, "--find-links", Policy.PUBLIC_FLAT_INDEX]
	assert_true(Policy.is_production_command(command), "existing client commands retain environment isolation")


func test_previous_policy_binds_success_backup_path_and_metadata_version() -> void:
	var version := "0.0.0-cutoff-fixture"
	var root := "res://addons/.godot_ai_update/backup/" + version
	var path := root.path_join("plugin.cfg")
	assert_false(FileAccess.file_exists(path), "fixture must not overwrite an existing backup")
	if FileAccess.file_exists(path):
		return
	var outcome := {"outcome": "success", "from_version": version, "backup_root": root}
	assert_eq(Policy.previous_policy(outcome), {}, "missing backup grants no old policy")
	assert_eq(DirAccess.make_dir_recursive_absolute(root), OK)
	var config := ConfigFile.new()
	config.set_value("plugin", "version", version)
	assert_eq(config.save(path), OK)
	assert_eq(Policy.previous_policy(outcome), {"known": true, "cutoff": ""}, "legacy backup explicitly proves absence")
	config.set_value("plugin", "dependency_cutoff", "2025-01-02T03:04:05Z")
	assert_eq(config.save(path), OK)
	assert_eq(Policy.previous_policy(outcome), {"known": true, "cutoff": "2025-01-02T03:04:05Z"})
	for changed in [{"outcome": "rollback"}, {"backup_root": root + "/other"}, {"from_version": "../escape"}, {"from_version": 3}]:
		var wrong := outcome.duplicate()
		wrong.merge(changed, true)
		assert_eq(Policy.previous_policy(wrong), {})
	config.set_value("plugin", "version", "another-version")
	assert_eq(config.save(path), OK)
	assert_eq(Policy.previous_policy(outcome), {})
	config.set_value("plugin", "version", version)
	for cutoff in ["", "2025-01-02", 123, "0000-01-01T00:00:00Z"]:
		config.set_value("plugin", "dependency_cutoff", cutoff)
		assert_eq(config.save(path), OK)
		assert_eq(Policy.previous_policy(outcome), {}, "present invalid cutoff is never legacy absence")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("[malformed\n")
	file.close()
	assert_eq(Policy.previous_policy(outcome), {})
	assert_eq(DirAccess.remove_absolute(path), OK)
	assert_eq(DirAccess.remove_absolute(root), OK)


func test_previous_policy_rejects_untyped_or_missing_version_metadata() -> void:
	var config := ConfigFile.new()
	assert_eq(Policy.previous_policy_from_config(config, ""), {})
	config.set_value("plugin", "version", 3)
	assert_eq(Policy.previous_policy_from_config(config, "3"), {})
	config.set_value("plugin", "version", "3")
	assert_eq(Policy.previous_policy_from_config(config, "3"), {"known": true, "cutoff": ""})


func test_previous_launch_is_readback_only_and_does_not_mutate_live_policy() -> void:
	var launch := {"ok": true, "tier": "uvx", "command": "uvx", "args": Policy.args()}
	launch.args.append_array(["--from", "godot-ai==4.0.0", "godot-ai", "attach", "--port", "8123"])
	var original := launch.duplicate(true)
	var legacy := Policy.previous_launch_for_verification(launch, {"known": true, "cutoff": ""})
	assert_false(legacy.args.has("--exclude-newer"))
	assert_false(legacy.args.has("--exclude-newer-package"))
	assert_eq(legacy.args[legacy.args.find("--from") + 1], "godot-ai==4.0.0")
	assert_eq(legacy.args[legacy.args.find("--index") + 1], Policy.PUBLIC_INDEX)
	var old := Policy.previous_launch_for_verification(launch, {"known": true, "cutoff": "2025-01-02T03:04:05Z"})
	assert_eq(old.args[old.args.find("--exclude-newer") + 1], "2025-01-02T03:04:05Z")
	assert_eq(old.args[old.args.find("--exclude-newer-package") + 1], "godot-ai=false")
	assert_eq(launch, original, "constructing old expectation cannot mutate an actual launch")
	assert_eq(Policy.args(), original.args.slice(0, Policy.args().size()), "current production policy remains fixed")
	assert_eq(Policy.previous_launch_for_verification(launch, {}), launch, "unknown backup cannot remove current policy")
	for invalid in [{"known": true}, {"known": "true", "cutoff": ""}, {"known": true, "cutoff": 0}, {"known": true, "cutoff": "invalid"}]:
		assert_eq(Policy.previous_launch_for_verification(launch, invalid), {})
	var duplicate_option := launch.duplicate(true)
	duplicate_option.args.append_array(["--exclude-newer", "2025-01-02T03:04:05Z"])
	assert_eq(Policy.previous_launch_for_verification(duplicate_option, {"known": true, "cutoff": ""}), {})


func test_config_file_cutoff_requires_quoted_string() -> void:
	var cutoff := "2026-11-01T19:00:00Z"
	var quoted := ConfigFile.new()
	assert_eq(quoted.parse('[plugin]\nversion="4.0.0"\ndependency_cutoff="%s"\n' % cutoff), OK)
	assert_eq(quoted.get_value("plugin", "dependency_cutoff"), cutoff)
	var bare := ConfigFile.new()
	var parse_error := bare.parse('[plugin]\nversion="4.0.0"\ndependency_cutoff=%s\n' % cutoff)
	var value: Variant = bare.get_value("plugin", "dependency_cutoff", null)
	print("CUTOFF_BARE_TIMESTAMP_PROBE ", JSON.stringify({"error": parse_error, "error_string": error_string(parse_error), "type": type_string(typeof(value)), "value": value}))
	assert_true(parse_error != OK or not value is String or value != cutoff, "unquoted timestamp must not become valid string metadata")


func test_previous_windows_console_policy_matches_real_client_readback() -> void:
	var client := preload("res://addons/godot_ai/clients/antigravity.gd").new()
	assert_false(client.needs_consoleless_launcher)
	var path := ProjectSettings.globalize_path("user://previous-policy-console.json")
	client.path_template = {"unix": path, "windows": path}
	var console_args: Array = Policy.args()
	console_args.append_array(["--from", "godot-ai==4.0.0", "godot-ai", "attach", "--port", "8123"])
	var launch := {"ok": true, "tier": "uvx", "command": "C:/Python/pythonw.exe", "args": ["-c", "bootstrap", "C:/Tools/uvx.exe"] + console_args, "console_command": "C:/Tools/uvx.exe", "console_args": console_args, "metadata": {"preserve": true}}
	var original := launch.duplicate(true)
	for cutoff in ["", "2025-01-02T03:04:05Z"]:
		var expected := console_args.duplicate()
		for option in ["--exclude-newer", "--exclude-newer-package"]:
			var index := expected.find(option)
			if cutoff.is_empty():
				expected.remove_at(index + 1)
				expected.remove_at(index)
			elif option == "--exclude-newer":
				expected[index + 1] = cutoff
		var prior := Policy.previous_launch_for_verification(launch, {"known": true, "cutoff": cutoff})
		assert_eq(prior.args.slice(0, 3), ["-c", "bootstrap", "C:/Tools/uvx.exe"])
		assert_eq(prior.args.slice(3), expected)
		assert_eq(prior.console_args, expected)
		assert_eq(prior.metadata, original.metadata)
		var selected := McpClientConfigurator.launch_for_client(client, prior)
		assert_eq(selected.command, launch.console_command)
		assert_eq(selected.args, expected)
		var stored := {"ok": true, "command": launch.console_command, "args": expected}
		assert_eq(McpJsonStrategy.configure(client, "godot-ai", "", stored).get("status"), "ok")
		assert_eq(McpJsonStrategy.check_status(client, "godot-ai", "", selected), McpClient.Status.CONFIGURED, "previous policy must match the actual console-client file")
	assert_eq(launch, original)
	DirAccess.remove_absolute(path)


func test_previous_policy_preserves_absent_argv_and_refuses_invalid_console_args() -> void:
	var policy := {"known": true, "cutoff": ""}
	var launch := {"ok": true, "tier": "uvx", "args": Policy.args()}
	var prior := Policy.previous_launch_for_verification(launch, policy)
	assert_false(prior.has("console_args"))
	var console_only := {"ok": true, "tier": "uvx", "console_args": Policy.args()}
	prior = Policy.previous_launch_for_verification(console_only, policy)
	assert_false(prior.has("args"))
	assert_false(prior.console_args.has("--exclude-newer"))
	for invalid in ["invalid", [], ["--exclude-newer", "2025-01-02T03:04:05Z"]]:
		var malformed := launch.duplicate(true)
		malformed.console_args = invalid
		assert_eq(Policy.previous_launch_for_verification(malformed, policy), {})
	assert_true(launch.args.has("--exclude-newer"))
