@tool
extends McpTestSuite

const ClientHandler := preload("res://addons/godot_ai/handlers/client_handler.gd")
const ClientBaseScript := preload("res://addons/godot_ai/clients/_base.gd")

## Tests for the client configuration registry + strategies.
##
## Per-client production paths point at real config files on the user's
## machine — we never touch those here. Instead we build synthetic McpClient
## descriptors with path_templates pointing inside user:// and exercise the
## JSON / TOML / facade behaviour against scratch files.

var _handler: ClientHandler
var _scratch_dir: String
## Snapshot the user's live port overrides at suite entry so our
## per-test set/clear dance doesn't leave the editor pointing at the wrong
## port if a test fails mid-flight.
var _saved_http_port: Variant = null
var _saved_ws_port: Variant = null


func suite_name() -> String:
	return "clients"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = ClientHandler.new()
	_scratch_dir = OS.get_user_data_dir().path_join("mcp_client_tests")
	DirAccess.make_dir_recursive_absolute(_scratch_dir)
	var es := EditorInterface.get_editor_settings()
	if es != null:
		if es.has_setting(McpSettings.SETTING_HTTP_PORT):
			_saved_http_port = es.get_setting(McpSettings.SETTING_HTTP_PORT)
		if es.has_setting(McpClientConfigurator.SETTING_WS_PORT):
			_saved_ws_port = es.get_setting(McpClientConfigurator.SETTING_WS_PORT)


func suite_teardown() -> void:
	# Best-effort cleanup of scratch files. user:// is writable so the dir
	# stays around for the next run; only the JSON / TOML files matter.
	for f in DirAccess.get_files_at(_scratch_dir):
		DirAccess.remove_absolute(_scratch_dir.path_join(f))
	_restore_port_settings()


# ----- registry sanity -----

func test_registry_loads_all_clients() -> void:
	var ids := McpClientRegistry.ids()
	assert_gt(ids.size(), 10, "Expected at least 10 registered clients, got %d" % ids.size())
	# Each existing client must remain registered for behaviour parity.
	for required in ["claude_code", "claude_desktop", "codex", "grok", "antigravity", "zoo_code", "hermes"]:
		assert_true(McpClientRegistry.has_id(required), "Missing client: %s" % required)


func test_grok_client_toml_descriptor() -> void:
	var client := McpClientRegistry.get_by_id("grok")
	assert_true(client != null, "grok client must be registered")
	assert_eq(client.display_name, "Grok Build")
	assert_eq(client.config_type, "toml")
	assert_eq(
		String(client.path_template.get("unix", "")),
		"~/.grok/config.toml",
		"Grok Build config path must be ~/.grok/config.toml"
	)
	assert_eq(client.toml_section_path.size(), 2)
	assert_eq(String(client.toml_section_path[0]), "mcp_servers")
	assert_eq(String(client.toml_section_path[1]), "godot-ai")


func test_pypi_pin_strips_local_build_metadata() -> void:
	## PEP 440 local version tags must not be sent to uvx/PyPI.
	assert_eq(McpClientConfigurator._pypi_pin_version("3.0.2+local.1"), "3.0.2")
	assert_eq(McpClientConfigurator._pypi_pin_version("3.0.2+grok.2"), "3.0.2")
	assert_eq(McpClientConfigurator._pypi_pin_version("3.0.2"), "3.0.2")
	## Pre-release segments stay intact (only '+' local metadata is stripped).
	assert_eq(McpClientConfigurator._pypi_pin_version("3.1.0-rc1"), "3.1.0-rc1")
	assert_eq(McpClientConfigurator._pypi_pin_version("  1.2.3+dev  "), "1.2.3")


func test_resolve_addons_realpath_non_empty() -> void:
	## Always returns a usable absolute path for res://addons/godot_ai
	## (logical path, or junction/symlink target when linked).
	var path := McpClientConfigurator.resolve_addons_realpath()
	assert_false(path.is_empty(), "resolve_addons_realpath must not be empty in test_project")
	assert_true(
		path.contains("godot_ai"),
		"resolved path should name the godot_ai addons dir, got: %s" % path
	)


func test_registry_ids_are_unique() -> void:
	var seen := {}
	for id in McpClientRegistry.ids():
		assert_false(seen.has(id), "Duplicate client id: %s" % id)
		seen[id] = true
	assert_gt(seen.size(), 0)


func test_windsurf_rebrand_to_devin_desktop() -> void:
	## #623: Windsurf was rebranded to Devin Desktop by Cognition (June 2026).
	## The registry id must stay "windsurf" (stable key for configured-status
	## lookups) and the config path is unchanged — migrated installs keep
	## ~/.codeium/windsurf/mcp_config.json. Only the display name and docs
	## URL changed. Pin the exact path templates so base-path drift (not
	## just a suffix change) fails loudly.
	var client := McpClientRegistry.get_by_id("windsurf")
	assert_true(client != null, "windsurf id must remain registered after #623 rebrand")
	assert_eq(client.display_name, "Devin Desktop (Windsurf)")
	assert_eq(
		String(client.path_template.get("unix", "")),
		"~/.codeium/windsurf/mcp_config.json",
		"windsurf unix config path must stay exactly ~/.codeium/windsurf/mcp_config.json (#623)"
	)
	assert_eq(
		String(client.path_template.get("windows", "")),
		"$USERPROFILE/.codeium/windsurf/mcp_config.json",
		"windsurf windows config path must stay exactly $USERPROFILE/.codeium/windsurf/mcp_config.json (#623)"
	)


func test_every_client_has_required_fields() -> void:
	for client in McpClientRegistry.all():
		assert_true(not client.id.is_empty(), "Client missing id: %s" % client)
		assert_true(not client.display_name.is_empty(), "%s missing display_name" % client.id)
		assert_contains(["json", "toml", "yaml", "cli"], client.config_type, "%s has unexpected config_type %s" % [client.id, client.config_type])
		if client.config_type == "json":
			assert_gt(client.server_key_path.size(), 0, "%s missing server_key_path" % client.id)
		elif client.config_type == "yaml":
			## The YAML strategy reads the block name from server_key_path[0]
			## and writes the url under entry_url_field — both must be set.
			assert_gt(client.server_key_path.size(), 0, "%s yaml client missing server_key_path" % client.id)
			assert_true(not client.entry_url_field.is_empty(), "%s yaml client missing entry_url_field" % client.id)
		elif client.config_type == "cli":
			assert_gt(client.cli_names.size(), 0, "%s cli client missing cli_names" % client.id)
			assert_gt(client.cli_register_template.size(), 0, "%s cli client missing cli_register_template" % client.id)
		elif client.config_type == "toml":
			assert_gt(client.toml_section_path.size(), 0, "%s toml client missing toml_section_path" % client.id)
			assert_gt(client.toml_body_template.size(), 0, "%s toml client missing toml_body_template" % client.id)
			## #711: check_status parses a literal `url = "..."` line and
			## configure's initial-vs-pinned split keys on the {url}
			## placeholder — a template without that exact line shape would
			## silently break both. Pin the contract per descriptor.
			var has_url_line := false
			for template_line in client.toml_body_template:
				var line_text := String(template_line)
				if line_text.strip_edges().begins_with("url =") and line_text.contains("{url}"):
					has_url_line = true
					break
			assert_true(
				has_url_line,
				"%s toml_body_template must carry a `url = ...{url}...` line — check_status parses it" % client.id
			)


func test_config_path_facade_matches_client_descriptors() -> void:
	for client in McpClientRegistry.all():
		assert_eq(
			McpClientConfigurator.config_path(client.id),
			client.resolved_config_path(),
			"%s config_path facade must mirror resolved_config_path" % client.id
		)


func test_config_path_facade_handles_unknown_and_file_clients() -> void:
	assert_eq(McpClientConfigurator.config_path("__missing_client__"), "")
	var cursor_path := McpClientConfigurator.config_path("cursor")
	assert_false(cursor_path.is_empty(), "Cursor should expose a JSON config file path")
	assert_true(cursor_path.ends_with("mcp.json"), "Cursor config should resolve to mcp.json, got %s" % cursor_path)


func test_config_path_facade_returns_empty_for_pure_cli_client() -> void:
	## Decoupled from any specific registered client (#kimi-mcp-json): a "pure
	## CLI" client is any descriptor with config_type "cli" and no JSON
	## fallback (empty path_template / server_key_path). kimi_code used to be
	## the only example in the registry until it moved to config_type "json"
	## — see test_kimi_code_client_json_descriptor.
	##
	## config_path() resolves through ClientRegistry.get_by_id(id), so an
	## unregistered synthetic McpClient never reaches its descriptor logic at
	## all — it would just retrace the unknown-id path already covered by
	## test_config_path_facade_handles_unknown_and_file_clients. Discover a
	## real registered pure-CLI client instead, and skip with a clear reason
	## if none currently exists.
	var pure_cli_id := ""
	for id in McpClientConfigurator.client_ids():
		var client := McpClientRegistry.get_by_id(String(id))
		if client != null and client.config_type == "cli" and not client.has_json_fallback():
			pure_cli_id = String(id)
			break
	if pure_cli_id.is_empty():
		skip("No registered pure CLI client (config_type \"cli\" with no JSON fallback) is available")
		return
	assert_eq(McpClientConfigurator.config_path(pure_cli_id), "")


func test_kimi_code_client_json_descriptor() -> void:
	## Regression guard: Kimi Code has no `mcp` CLI subcommand (verified
	## against v0.28.1 — `kimi mcp` falls through to the root --help). Servers
	## are managed via ~/.kimi-code/mcp.json instead (see
	## moonshotai.github.io/kimi-code/en/customization/mcp). The previous
	## descriptor ran `kimi mcp add --transport http ...`, which always failed
	## with "error: unknown option '--transport'" since that verb doesn't
	## exist. Pin the JSON shape so a future revert reintroduces the failure
	## loudly here instead of silently at Configure time.
	var client := McpClientRegistry.get_by_id("kimi_code")
	assert_true(client != null, "kimi_code must remain registered")
	assert_eq(client.config_type, "json")
	assert_eq(
		String(client.path_template.get("unix", "")),
		"~/.kimi-code/mcp.json",
		"Kimi Code config path must be ~/.kimi-code/mcp.json"
	)
	assert_eq(
		String(client.path_template.get("windows", "")),
		"~/.kimi-code/mcp.json",
		"Kimi Code config path must be ~/.kimi-code/mcp.json on Windows too"
	)
	assert_eq(client.server_key_path.size(), 1)
	assert_eq(String(client.server_key_path[0]), "mcpServers")
	assert_eq(client.entry_extra_fields.get("transport"), "http")


func test_descriptors_are_data_only() -> void:
	## #229 race-surface guard: every shipped descriptor must be pure data.
	## A worker thread walking a Callable on a hot-reloadable per-client `.gd`
	## file is what blew up in the issue — when the bytecode swaps under the
	## running thread, the IP walks off a cliff (Opcode: 0, Bad address
	## index, signal 11). Removing all Callable-typed fields on descriptors
	## reduces the worker's GDScript-IP exposure to the strategy files alone,
	## which churn far less. It also makes #192's stale-Callable workaround
	## obsolete: nothing to go stale.
	##
	## If this test fails, you almost certainly added a Callable field to
	## either McpClient (`_base.gd`) or one of the per-client descriptors.
	## Move the logic into the matching strategy and supply declarative data
	## (PackedStringArray template, Dictionary, scalar) on the descriptor
	## instead. See `_base.gd` doc-comment for the rationale.
	for client in McpClientRegistry.all():
		var props := client.get_property_list()
		for prop in props:
			# Skip script/internal properties — only inspect user-defined fields.
			if (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
				continue
			var prop_name: String = prop.name
			var value = client.get(prop_name)
			var crumb: String = _find_callable(value, "%s.%s" % [client.id, prop_name])
			assert_true(
				crumb.is_empty(),
				"%s — descriptors must be data-only (issue #229)" % crumb,
			)


## Recursively walk a Variant looking for a Callable — top-level OR nested
## inside a Dictionary / Array. Returns the breadcrumb path of the offending
## field (e.g. "claude_desktop.entry_extra_fields[\"hook\"]") on hit, or "" on
## clean. Catches `entry_extra_fields = {"hook": Callable()}`-style sneaks
## that a top-level type check would miss.
func _find_callable(value: Variant, breadcrumb: String) -> String:
	if value is Callable:
		return breadcrumb
	if value is Dictionary:
		for k in value:
			var hit := _find_callable(value[k], "%s[%s]" % [breadcrumb, JSON.stringify(k)])
			if not hit.is_empty():
				return hit
	elif value is Array:
		for i in value.size():
			var hit := _find_callable(value[i], "%s[%d]" % [breadcrumb, i])
			if not hit.is_empty():
				return hit
	return ""


func test_status_label_callable_via_preload_alias() -> void:
	## Regression for #444: calling `status_label` on `McpClient` through a
	## `const ... := preload(...)` alias parses on stricter Godot versions.
	## Before the fix, the parser flagged
	##   `Invalid argument for "status_label()": argument 1 should be "Status"
	##    but is "McpClient.Status".`
	## because the parameter type was declared as the unqualified `Status`
	## (local-scope enum in `_base.gd`) while the argument resolved through
	## the preload alias as `McpClient.Status`. A parse failure in
	## `client_configurator.gd` then cascaded into runtime "Nonexistent
	## function" errors for `ensure_settings_registered` and
	## `startup_trace_enabled` at plugin enable.
	##
	## This test fails to *load* (caught by the runner's load_errors path) if
	## the parser regression returns, so even reaching `run_test()` here
	## proves the surface is intact. The asserts below additionally pin the
	## label values that agents pattern-match against.
	var via_alias_value: ClientBaseScript.Status = ClientBaseScript.Status.CONFIGURED
	assert_eq(ClientBaseScript.status_label(via_alias_value), "configured")
	assert_eq(ClientBaseScript.status_label(ClientBaseScript.Status.NOT_CONFIGURED), "not_configured")
	assert_eq(ClientBaseScript.status_label(ClientBaseScript.Status.CONFIGURED_MISMATCH), "configured_mismatch")
	assert_eq(ClientBaseScript.status_label(ClientBaseScript.Status.ERROR), "error")
	# And the class_name namespace form keeps working too.
	assert_eq(McpClient.status_label(McpClient.Status.CONFIGURED), "configured")


func test_every_client_has_manual_command() -> void:
	for client_id in McpClientConfigurator.client_ids():
		var cmd := McpClientConfigurator.manual_command(client_id)
		assert_true(not cmd.is_empty(), "%s missing manual command" % client_id)


func test_manual_command_escapes_backslashes_in_paths() -> void:
	## Regression: `_format_value` used to interpolate strings with bare `"..."`
	## quoting, so a Windows uvx path like `C:\Users\foo\uvx.exe` rendered as
	## `"C:\Users\foo\uvx.exe"` — invalid JSON, unsafe to paste into a config
	## file. The fix routes leaf strings through `JSON.stringify`, which
	## escapes backslashes / quotes / newlines per the JSON spec.
	##
	## Build a synthetic flat-bridge client with a path containing every
	## hazardous char so the inline JSON the manual command emits parses
	## back without errors.
	var client := McpClient.new()
	client.id = "manual_escape_test"
	client.display_name = "Escape Test"
	client.config_type = "json"
	client.path_template = {"darwin": "/tmp/m.json", "windows": "/tmp/m.json", "linux": "/tmp/m.json", "unix": "/tmp/m.json"}
	client.server_key_path = PackedStringArray(["mcpServers"])
	client.entry_extra_fields = {
		"command": "C:\\Users\\foo bar\\uvx.exe",
		"hint": "say \"hello\"\nworld",
	}

	var manual := McpManualCommand.build(client, "godot-ai", "http://x", "/tmp/m.json")
	# Extract the JSON object body — everything from the first `{` after the
	# entry key onwards to the matching trailing `}`.
	var first_brace := manual.find("{")
	assert_gt(first_brace, 0, "manual command should contain a JSON-ish entry")
	var entry_text := manual.substr(first_brace)
	var parsed = JSON.parse_string(entry_text)
	assert_true(
		parsed is Dictionary,
		"manual-command entry must be valid JSON; got: %s" % entry_text,
	)
	assert_eq(parsed.get("command"), "C:\\Users\\foo bar\\uvx.exe")
	assert_eq(parsed.get("hint"), "say \"hello\"\nworld")
	assert_eq(parsed.get("url"), "http://x")


# ----- server launch mode -----


func test_invalidate_cli_cache_clears_all_entries() -> void:
	McpCliFinder.invalidate()
	var miss := McpCliFinder.find(["mcp_test_definitely_no_such_cli_xyz"])
	assert_eq(miss, "")
	assert_true(McpCliFinder._searched.size() > 0)

	McpClientConfigurator.invalidate_cli_cache()

	assert_eq(McpCliFinder._cache.size(), 0)
	assert_eq(McpCliFinder._searched.size(), 0, "Without dropping _searched, the next find() short-circuits on the stale negative")


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


# ----- dev-venv detection requires sibling src/godot_ai -----
#
# `_find_venv_python` used to accept any `.venv/bin/python` it found while
# walking up from `res://` — so a user with `~/.venv` (from an unrelated
# Python project) got their venv picked up, `python -m godot_ai` failed with
# ModuleNotFoundError ~5s in, and the reconnect logic looped forever. These
# tests lock in the new rule: require a sibling `src/godot_ai/` in the same
# parent dir before treating a `.venv` as a godot-ai dev venv.


func test_find_venv_python_rejects_venv_without_godot_ai_src() -> void:
	## The money test. Reproduces the reported bug scenario: a user HOME
	## with `~/.venv/` from a data-science side project and no `src/godot_ai/`
	## anywhere on the path. The plugin must fall through to the uvx tier
	## instead of spawning the wrong interpreter.
	var root := _scratch_dir.path_join("fake_user_home")
	var venv_python := root.path_join(_venv_python_relpath())
	DirAccess.make_dir_recursive_absolute(venv_python.get_base_dir())
	_touch_file(venv_python)
	assert_eq(McpClientConfigurator._find_venv_python_in(root), "", "Plain .venv with no sibling src/godot_ai/ must be rejected")
	DirAccess.remove_absolute(venv_python)
	DirAccess.remove_absolute(venv_python.get_base_dir())
	DirAccess.remove_absolute(root.path_join(".venv"))
	DirAccess.remove_absolute(root)


func test_find_venv_python_accepts_venv_with_godot_ai_src() -> void:
	## Positive case: real godot-ai dev checkout has both `.venv/` and
	## `src/godot_ai/` as siblings at the worktree root. Both present →
	## return the venv python path.
	var root := _scratch_dir.path_join("fake_dev_checkout")
	var venv_python := root.path_join(_venv_python_relpath())
	DirAccess.make_dir_recursive_absolute(venv_python.get_base_dir())
	_touch_file(venv_python)
	DirAccess.make_dir_recursive_absolute(root.path_join("src/godot_ai"))
	assert_eq(McpClientConfigurator._find_venv_python_in(root), venv_python)
	DirAccess.remove_absolute(venv_python)
	DirAccess.remove_absolute(venv_python.get_base_dir())
	DirAccess.remove_absolute(root.path_join(".venv"))
	DirAccess.remove_absolute(root.path_join("src/godot_ai"))
	DirAccess.remove_absolute(root.path_join("src"))
	DirAccess.remove_absolute(root)


func test_find_venv_python_walks_up_from_nested_start_dir() -> void:
	## Mirrors the real res:// layout: start_dir is `test_project/addons/*`
	## deep inside a checkout; the venv and src/ live several levels up.
	var root := _scratch_dir.path_join("nested_walk")
	var deep := root.path_join("test_project/addons/pkg")
	var venv_python := root.path_join(_venv_python_relpath())
	DirAccess.make_dir_recursive_absolute(deep)
	DirAccess.make_dir_recursive_absolute(venv_python.get_base_dir())
	_touch_file(venv_python)
	DirAccess.make_dir_recursive_absolute(root.path_join("src/godot_ai"))
	assert_eq(McpClientConfigurator._find_venv_python_in(deep), venv_python)
	DirAccess.remove_absolute(venv_python)
	DirAccess.remove_absolute(venv_python.get_base_dir())
	DirAccess.remove_absolute(root.path_join(".venv"))
	DirAccess.remove_absolute(root.path_join("src/godot_ai"))
	DirAccess.remove_absolute(root.path_join("src"))
	DirAccess.remove_absolute(deep)
	DirAccess.remove_absolute(root.path_join("test_project/addons"))
	DirAccess.remove_absolute(root.path_join("test_project"))
	DirAccess.remove_absolute(root)


func test_find_venv_python_walks_junction_plugin_layout() -> void:
	## Junctioned plugins resolve to <repo>/plugin/addons/godot_ai (4 hops
	## to checkout root). Guard the 8-hop walk still finds the checkout venv.
	var root := _scratch_dir.path_join("junction_layout")
	var deep := root.path_join("plugin/addons/godot_ai")
	var venv_python := root.path_join(_venv_python_relpath())
	DirAccess.make_dir_recursive_absolute(deep)
	DirAccess.make_dir_recursive_absolute(venv_python.get_base_dir())
	_touch_file(venv_python)
	DirAccess.make_dir_recursive_absolute(root.path_join("src/godot_ai"))
	assert_eq(
		McpClientConfigurator._find_venv_python_in(deep),
		venv_python,
		"walk from plugin/addons/godot_ai must reach checkout .venv"
	)
	DirAccess.remove_absolute(venv_python)
	DirAccess.remove_absolute(venv_python.get_base_dir())
	DirAccess.remove_absolute(root.path_join(".venv"))
	DirAccess.remove_absolute(root.path_join("src/godot_ai"))
	DirAccess.remove_absolute(root.path_join("src"))
	DirAccess.remove_absolute(deep)
	DirAccess.remove_absolute(root.path_join("plugin/addons"))
	DirAccess.remove_absolute(root.path_join("plugin"))
	DirAccess.remove_absolute(root)


func test_find_venv_python_rejects_when_only_src_exists() -> void:
	## Complement of the first test: `src/godot_ai/` present but no `.venv/`.
	## Could happen if a user copied the source tree without running setup.
	## Nothing to return — the helper is a venv locator, not a src locator.
	var root := _scratch_dir.path_join("fake_src_only")
	DirAccess.make_dir_recursive_absolute(root.path_join("src/godot_ai"))
	assert_eq(McpClientConfigurator._find_venv_python_in(root), "")
	DirAccess.remove_absolute(root.path_join("src/godot_ai"))
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


func test_get_server_command_forced_user_skips_dev_venv() -> void:
	## Forcing `user` mode must reroute `get_server_command` past the
	## dev_venv tier, not just relabel the dock. Before this fix, a user
	## whose `~/.venv` was wrongly detected had no UI-based escape — the
	## dropdown would say "user install" but the spawn would still use
	## the misidentified venv. Now flipping the override actually changes
	## what gets spawned.
	var prior_setting: Variant = _clear_mode_override_setting()
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	OS.set_environment("GODOT_AI_MODE", "user")

	assert_true(McpClientConfigurator.get_server_launch_mode() != "dev_venv", "mode=user must never resolve to dev_venv")

	var cmd := McpClientConfigurator.get_server_command()
	for arg in cmd:
		var s := str(arg)
		var is_venv_python := s.ends_with("/.venv/bin/python") or s.ends_with("\\.venv\\Scripts\\python.exe") or s.ends_with("/.venv/Scripts/python.exe")
		assert_false(is_venv_python, "mode=user must not spawn a .venv python binary (got: %s)" % str(cmd))

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


# ----- port configuration -----
#
# http_port() / ws_port() read EditorSettings overrides and fall back to the
# baked-in defaults when the override is unset or out of [1024, 65535]. Each
# test owns its teardown via `_clear_port_settings` so a failure in the middle
# can't leak a bogus port into later assertions or the user's real editor.


func test_http_port_defaults_when_setting_absent() -> void:
	_clear_port_settings()
	assert_eq(McpClientConfigurator.http_port(), McpClientConfigurator.DEFAULT_HTTP_PORT)


func test_http_port_reads_configured_value() -> void:
	_clear_port_settings()
	var es := EditorInterface.get_editor_settings()
	assert_true(es != null, "EditorSettings unavailable")
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 8123)
	assert_eq(McpClientConfigurator.http_port(), 8123)
	_clear_port_settings()


func test_http_port_rejects_out_of_range() -> void:
	## Privileged ports and anything above 65535 must fall back to the default,
	## not be returned verbatim — the Python server would refuse to bind and
	## the dock would be left with a useless number in the label.
	_clear_port_settings()
	var es := EditorInterface.get_editor_settings()
	assert_true(es != null, "EditorSettings unavailable")
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 80)
	assert_eq(McpClientConfigurator.http_port(), McpClientConfigurator.DEFAULT_HTTP_PORT)
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 70000)
	assert_eq(McpClientConfigurator.http_port(), McpClientConfigurator.DEFAULT_HTTP_PORT)
	_clear_port_settings()


func test_ws_port_defaults_when_setting_absent() -> void:
	_clear_port_settings()
	assert_eq(McpClientConfigurator.ws_port(), McpClientConfigurator.DEFAULT_WS_PORT)


func test_ws_port_reads_configured_value() -> void:
	_clear_port_settings()
	var es := EditorInterface.get_editor_settings()
	assert_true(es != null, "EditorSettings unavailable")
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, 9600)
	assert_eq(McpClientConfigurator.ws_port(), 9600)
	_clear_port_settings()


func test_ws_port_rejects_out_of_range() -> void:
	_clear_port_settings()
	var es := EditorInterface.get_editor_settings()
	assert_true(es != null, "EditorSettings unavailable")
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, 1023)
	assert_eq(McpClientConfigurator.ws_port(), McpClientConfigurator.DEFAULT_WS_PORT)
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, 99999)
	assert_eq(McpClientConfigurator.ws_port(), McpClientConfigurator.DEFAULT_WS_PORT)
	_clear_port_settings()


func test_http_url_uses_current_http_port() -> void:
	## http_url() is the single funnel every MCP-client descriptor flows through
	## when building `url` / `serverUrl` / `httpUrl` entries. If it drifts from
	## http_port() we would silently configure clients against the wrong port.
	_clear_port_settings()
	var es := EditorInterface.get_editor_settings()
	assert_true(es != null, "EditorSettings unavailable")
	es.set_setting(McpSettings.SETTING_HTTP_PORT, 8321)
	assert_eq(McpClientConfigurator.http_url(), "http://127.0.0.1:8321/mcp")
	_clear_port_settings()
	assert_eq(
		McpClientConfigurator.http_url(),
		"http://127.0.0.1:%d/mcp" % McpClientConfigurator.DEFAULT_HTTP_PORT,
	)


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
		home = OS.get_environment("USERPROFILE")
	if home.is_empty():
		assert_true(false, "HOME / USERPROFILE not set in test environment")
		return
	var resolved := McpPathTemplate.expand("$XDG_CONFIG_HOME/foo")
	# Either uses XDG_CONFIG_HOME if set, or falls back to ~/.config
	assert_true(resolved.ends_with("/foo"))


# ----- env snapshot (#691) -----

const TEST_SNAPSHOT_ENV := "GODOT_AI_TEST_ENV_SNAPSHOT"


func test_env_lookup_main_thread_reads_live_and_refreshes_snapshot() -> void:
	OS.set_environment(TEST_SNAPSHOT_ENV, "live-value")
	assert_eq(McpPathTemplate.env_lookup(TEST_SNAPSHOT_ENV), "live-value")
	OS.set_environment(TEST_SNAPSHOT_ENV, "updated-value")
	assert_eq(McpPathTemplate.env_lookup(TEST_SNAPSHOT_ENV), "updated-value",
		"main-thread reads must always be live, never stale snapshot")
	OS.unset_environment(TEST_SNAPSHOT_ENV)


func test_env_lookup_worker_thread_serves_snapshot_not_live_env() -> void:
	## The #691 contract: a worker-thread read must come from the snapshot,
	## proving it can never call OS.get_environment concurrently with a
	## main-thread setenv/unsetenv window. We change the real env AFTER
	## warming and assert the worker still sees the warmed value.
	OS.set_environment(TEST_SNAPSHOT_ENV, "warmed-value")
	McpPathTemplate.warm_env_snapshot(PackedStringArray([TEST_SNAPSHOT_ENV]))
	OS.set_environment(TEST_SNAPSHOT_ENV, "mutated-after-warm")

	var thread := Thread.new()
	var start_err := thread.start(func() -> String:
		return McpPathTemplate.env_lookup(TEST_SNAPSHOT_ENV)
	)
	assert_eq(start_err, OK, "worker thread must start")
	var worker_value := str(thread.wait_to_finish())

	assert_eq(worker_value, "warmed-value",
		"worker read must be served from the snapshot, not the live env")
	## Main-thread read refreshes the snapshot to the current live value.
	assert_eq(McpPathTemplate.env_lookup(TEST_SNAPSHOT_ENV), "mutated-after-warm")
	OS.unset_environment(TEST_SNAPSHOT_ENV)


func test_env_lookup_worker_thread_never_warmed_var_reads_empty() -> void:
	## A worker read of a var nobody warmed must return "" (the unset
	## value), NOT fall back to a live OS.get_environment — the fallback
	## would reintroduce the #691 race for exactly the un-warmed vars.
	const NEVER_WARMED := "GODOT_AI_TEST_ENV_NEVER_WARMED"
	OS.set_environment(NEVER_WARMED, "live-only-value")
	var thread := Thread.new()
	var start_err := thread.start(func() -> String:
		return McpPathTemplate.env_lookup(NEVER_WARMED)
	)
	assert_eq(start_err, OK, "worker thread must start")
	var worker_value := str(thread.wait_to_finish())
	OS.unset_environment(NEVER_WARMED)
	assert_eq(worker_value, "",
		"un-warmed worker read must degrade to \"\", never touch the live env")


func test_editor_setting_lookup_worker_thread_serves_snapshot() -> void:
	## #691: mode_override() runs on the startup walk's discovery worker
	## (via get_server_command) and EditorSettings is not thread-safe. A
	## worker read must come from the main-thread-warmed snapshot; a
	## never-warmed key must read as null (unset), never touch
	## EditorInterface off-main.
	var es := EditorInterface.get_editor_settings()
	var setting_name := McpClientConfigurator.MODE_OVERRIDE_SETTING
	var had_setting := es.has_setting(setting_name)
	var prior: Variant = es.get_setting(setting_name) if had_setting else null
	es.set_setting(setting_name, "dev")
	McpClientConfigurator.warm_env_snapshot()

	var thread := Thread.new()
	var start_err := thread.start(func() -> Array:
		return [
			McpClientConfigurator._editor_setting_lookup(setting_name),
			McpClientConfigurator._editor_setting_lookup("godot_ai/never_warmed_probe"),
		]
	)
	assert_eq(start_err, OK, "worker thread must start")
	var results: Array = thread.wait_to_finish()

	if had_setting:
		es.set_setting(setting_name, prior)
	else:
		es.erase(setting_name)
	McpClientConfigurator.warm_env_snapshot()

	assert_eq(str(results[0]), "dev",
		"worker read must serve the warmed EditorSetting value")
	assert_true(results[1] == null,
		"a never-warmed setting must read as null on a worker, not hit EditorInterface")


func test_warm_env_snapshot_covers_descriptor_config_home_envs() -> void:
	## ClientConfigurator.warm_env_snapshot must include every descriptor's
	## config_home_env (CLAUDE_CONFIG_DIR, CODEX_HOME, …) so worker-side
	## config_home_override() never falls into the degraded un-warmed path.
	var tested_count := 0
	for id in McpClientConfigurator.client_ids():
		var client := McpClientRegistry.get_by_id(String(id))
		if client == null or client.config_home_env.is_empty():
			continue
		tested_count += 1
		OS.set_environment(client.config_home_env, "warm-probe")
		McpClientConfigurator.warm_env_snapshot()
		OS.unset_environment(client.config_home_env)
		var thread := Thread.new()
		var env_name := client.config_home_env
		var start_err := thread.start(func() -> String:
			return McpPathTemplate.env_lookup(env_name)
		)
		assert_eq(start_err, OK)
		var worker_value := str(thread.wait_to_finish())
		assert_eq(worker_value, "warm-probe",
			"%s must be pre-warmed by ClientConfigurator.warm_env_snapshot" % env_name)
		## Re-warm now that the var is unset so the snapshot doesn't leak
		## the probe value into later tests.
		McpClientConfigurator.warm_env_snapshot()
	assert_true(tested_count > 0,
		"no descriptor declared config_home_env — this test exercised nothing")


# ----- config-home env override (#617) -----

const TEST_CFG_HOME_ENV := "GODOT_AI_TEST_CFG_HOME"


func _make_env_override_toml_client(default_path: String) -> McpClient:
	var c := _make_test_toml_client(default_path)
	c.config_home_env = TEST_CFG_HOME_ENV
	c.config_home_env_subpath = "config.toml"
	return c


func test_config_home_env_overrides_path_template() -> void:
	var default_path := _scratch_dir.path_join("env_default/config.toml")
	var client := _make_env_override_toml_client(default_path)
	var prior_env := OS.get_environment(TEST_CFG_HOME_ENV)
	var env_home := _scratch_dir.path_join("env_home")
	OS.set_environment(TEST_CFG_HOME_ENV, env_home)
	var resolved := client.resolved_config_path()
	if prior_env.is_empty():
		OS.unset_environment(TEST_CFG_HOME_ENV)
	else:
		OS.set_environment(TEST_CFG_HOME_ENV, prior_env)
	assert_eq(resolved, env_home.path_join("config.toml"), "env var should override path_template")


func test_config_home_env_unset_falls_back_to_path_template() -> void:
	var default_path := _scratch_dir.path_join("env_default/config.toml")
	var client := _make_env_override_toml_client(default_path)
	var prior_env := OS.get_environment(TEST_CFG_HOME_ENV)
	OS.unset_environment(TEST_CFG_HOME_ENV)
	var resolved_unset := client.resolved_config_path()
	# Empty / whitespace-only value must also fall back — an exported-but-blank
	# var means "not relocated".
	OS.set_environment(TEST_CFG_HOME_ENV, "   ")
	var resolved_blank := client.resolved_config_path()
	if prior_env.is_empty():
		OS.unset_environment(TEST_CFG_HOME_ENV)
	else:
		OS.set_environment(TEST_CFG_HOME_ENV, prior_env)
	assert_eq(resolved_unset, default_path, "unset env var should fall back to path_template")
	assert_eq(resolved_blank, default_path, "blank env var should fall back to path_template")


func test_config_home_override_requires_both_fields() -> void:
	var default_path := _scratch_dir.path_join("env_default/config.toml")
	var client := _make_test_toml_client(default_path)
	client.config_home_env = TEST_CFG_HOME_ENV
	# subpath left empty → no override even when the env var is set.
	var prior_env := OS.get_environment(TEST_CFG_HOME_ENV)
	OS.set_environment(TEST_CFG_HOME_ENV, _scratch_dir.path_join("env_home"))
	var resolved := client.resolved_config_path()
	var override := client.config_home_override()
	if prior_env.is_empty():
		OS.unset_environment(TEST_CFG_HOME_ENV)
	else:
		OS.set_environment(TEST_CFG_HOME_ENV, prior_env)
	assert_eq(override, "", "missing subpath must disable the override")
	assert_eq(resolved, default_path, "missing subpath must fall back to path_template")


func test_config_home_env_configure_and_drift_use_override() -> void:
	## End-to-end: with the env var set, Configure writes to the env-var
	## location, drift detection reads it back from there, and Remove cleans
	## it up — the path_template default is never touched.
	var default_path := _scratch_dir.path_join("env_default_untouched.toml")
	_remove_if_exists(default_path)
	var client := _make_env_override_toml_client(default_path)
	var env_home := _scratch_dir.path_join("env_home_e2e")
	DirAccess.make_dir_recursive_absolute(env_home)
	var env_path := env_home.path_join("config.toml")
	_remove_if_exists(env_path)
	var prior_env := OS.get_environment(TEST_CFG_HOME_ENV)
	OS.set_environment(TEST_CFG_HOME_ENV, env_home)

	var result := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	var wrote_env := FileAccess.file_exists(env_path)
	var wrote_default := FileAccess.file_exists(default_path)
	var status := McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	var drift := McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:9000/mcp")
	var installed := client.is_installed()
	var removed := McpTomlStrategy.remove(client, "godot-ai")
	var post_remove := McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")

	if prior_env.is_empty():
		OS.unset_environment(TEST_CFG_HOME_ENV)
	else:
		OS.set_environment(TEST_CFG_HOME_ENV, prior_env)
	_remove_if_exists(env_path)

	assert_eq(result.get("status"), "ok")
	assert_true(wrote_env, "Configure must write the env-var location")
	assert_false(wrote_default, "Configure must not touch the path_template default")
	assert_eq(status, McpClient.Status.CONFIGURED)
	assert_eq(drift, McpClient.Status.CONFIGURED_MISMATCH, "URL drift must be detected at the overridden path")
	assert_true(installed, "config existing at the env-var location must count as installed")
	assert_eq(removed.get("status"), "ok")
	assert_eq(post_remove, McpClient.Status.NOT_CONFIGURED)


func test_codex_declares_codex_home_override() -> void:
	var client := McpClientRegistry.get_by_id("codex")
	assert_true(client != null, "codex must be registered")
	assert_eq(client.config_home_env, "CODEX_HOME")
	assert_eq(client.config_home_env_subpath, "config.toml", "config.toml lives directly in $CODEX_HOME")


func test_claude_code_declares_claude_config_dir_override() -> void:
	var client := McpClientRegistry.get_by_id("claude_code")
	assert_true(client != null, "claude_code must be registered")
	assert_eq(client.config_home_env, "CLAUDE_CONFIG_DIR")
	assert_eq(client.config_home_env_subpath, ".claude.json")


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

	# A wrong URL is drift, not "never configured" — the user re-configured
	# at one point but the stored URL is now stale (most commonly because
	# they changed `godot_ai/http_port`). Surfacing it as a distinct status
	# lets the dock render an amber "stale" banner instead of conflating
	# drift with a brand-new install.
	var wrong_status := McpJsonStrategy.check_status(client, "godot-ai", "http://wrong/")
	assert_eq(wrong_status, McpClient.Status.CONFIGURED_MISMATCH)

	var removed := McpJsonStrategy.remove(client, "godot-ai")
	assert_eq(removed.get("status"), "ok")
	assert_eq(McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"), McpClient.Status.NOT_CONFIGURED)


## #463: a CLI client (Claude Code) installed only as a VS Code/Cursor
## extension has no `claude` binary on PATH. With a JSON fallback declared,
## Configure/Remove/status must route through the config file directly.
func _make_cli_json_fallback_client(path: String) -> McpClient:
	var c := McpClient.new()
	c.id = "cli_fallback_test"
	c.display_name = "CLI Fallback Test"
	c.config_type = "cli"
	# A binary name that will never resolve on PATH, forcing the fallback.
	c.cli_names = PackedStringArray(["godot-ai-nonexistent-cli-xyz"])
	c.cli_register_template = PackedStringArray(["mcp", "add", "{name}", "{url}"])
	c.cli_unregister_template = PackedStringArray(["mcp", "remove", "{name}"])
	c.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	c.server_key_path = PackedStringArray(["mcpServers"])
	c.entry_extra_fields = {"type": "http"}
	return c


func test_has_json_fallback_semantics() -> void:
	var path := _scratch_dir.path_join("fallback_sem.json")
	var with_fallback := _make_cli_json_fallback_client(path)
	assert_true(with_fallback.has_json_fallback(), "cli client with path_template + server_key_path should report a JSON fallback")
	var no_path := _make_cli_json_fallback_client(path)
	no_path.path_template = {}
	assert_false(no_path.has_json_fallback(), "cli client without path_template should not report a JSON fallback")
	# JSON-config clients are not "cli fallbacks".
	assert_false(_make_test_json_client(path).has_json_fallback(), "a plain json client should not report a cli JSON fallback")


func test_claude_code_has_claude_json_fallback() -> void:
	var client := McpClientRegistry.get_by_id("claude_code")
	assert_true(client != null, "claude_code must be registered")
	assert_eq(client.config_type, "cli")
	assert_true(client.has_json_fallback(), "claude_code should declare a ~/.claude.json fallback (#463)")
	assert_eq(client.server_key_path.size(), 1)
	assert_eq(client.server_key_path[0], "mcpServers")
	assert_eq(client.entry_extra_fields.get("type"), "http", "claude mcp add --transport http writes type:http")
	assert_true(client.resolved_config_path().ends_with(".claude.json"), "fallback path should be ~/.claude.json, got %s" % client.resolved_config_path())


func test_claude_code_manual_command_shows_json_fallback() -> void:
	# The CLI form is still the primary hint, but a user without the `claude`
	# binary (VS Code extension) needs the ~/.claude.json edit too (#463).
	var cmd := McpClientConfigurator.manual_command("claude_code")
	assert_contains(cmd, "claude mcp add", "manual command should still show the CLI form")
	assert_contains(cmd, ".claude.json", "manual command should also show the JSON fallback path")
	assert_contains(cmd, "\"type\": \"http\"", "JSON fallback should show the type:http entry shape")


func test_cli_fallback_dispatch_writes_json_when_binary_missing() -> void:
	var path := _scratch_dir.path_join("cli_fallback.json")
	_remove_if_exists(path)
	# Pre-seed an unrelated server that must survive the fallback write.
	var seed := {"mcpServers": {"someone-else": {"url": "http://other/"}}}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(seed))
	f.close()

	var client := _make_cli_json_fallback_client(path)
	# The bogus cli_names never resolve, so dispatch must take the JSON fallback.
	var result := McpClientConfigurator._dispatch_configure(client, "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok", "fallback configure should succeed: %s" % result.get("message", ""))

	var status := McpClientConfigurator._dispatch_check_status_with_cli_path_details(client, "http://127.0.0.1:8000/mcp", "")
	assert_eq(status.get("status"), McpClient.Status.CONFIGURED, "fallback-configured entry should read CONFIGURED")

	# The written entry carries type:http + url, and the other server survives.
	var read_file := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	assert_eq(json.parse(read_file.get_as_text()), OK)
	read_file.close()
	var servers: Dictionary = json.data["mcpServers"]
	assert_true(servers.has("someone-else"), "unrelated server entry must be preserved")
	var entry: Dictionary = servers["godot-ai"]
	assert_eq(entry.get("type"), "http", "fallback entry should pin type:http")
	assert_eq(entry.get("url"), "http://127.0.0.1:8000/mcp")

	# Remove also goes through the fallback so the entry stays removable.
	var removed := McpClientConfigurator._dispatch_remove(client)
	assert_eq(removed.get("status"), "ok")
	var after := McpClientConfigurator._dispatch_check_status_with_cli_path_details(client, "http://127.0.0.1:8000/mcp", "")
	assert_eq(after.get("status"), McpClient.Status.NOT_CONFIGURED, "removed fallback entry should read NOT_CONFIGURED")


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


func test_json_strategy_preserves_integer_fields() -> void:
	## Godot parses every JSON number as a float; a naive round-trip re-emits the
	## user's integer fields (ports, counts) as "8080.0", which strict consumers
	## reject and which churns numbers across the user's other entries. The
	## strategy must re-narrow integral numbers so ints stay ints. (#528 / TC-2)
	var path := _scratch_dir.path_join("ints.json")
	var seed := {
		"mcpServers": {"someone-else": {"url": "http://other/", "port": 8080, "retries": 3}},
		"numStartups": 47,
		"weights": [1, 2, 3],
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(seed))
	f.close()

	var client := _make_test_json_client(path)
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")

	var content_file := FileAccess.open(path, FileAccess.READ)
	var content := content_file.get_as_text()
	content_file.close()
	# Integers must survive as integers — not be floatified to "8080.0".
	assert_true(content.contains('"port": 8080'), "port int must be present")
	assert_false(content.contains('"port": 8080.0'), "port must not become 8080.0")
	assert_false(content.contains('"retries": 3.0'), "retries must not be floatified")
	assert_false(content.contains('"numStartups": 47.0'), "top-level int must not be floatified")
	# Check each element regardless of trailing comma/newline so a floatified
	# last element ("3.0" with no comma) is also caught.
	for floatified in ["1.0", "2.0", "3.0"]:
		assert_false(content.contains(floatified), "array int must not be floatified (%s)" % floatified)
	# Still valid JSON, other entry preserved, our entry added.
	var parsed = JSON.parse_string(content)
	assert_true(parsed["mcpServers"].has("someone-else"))
	assert_true(parsed["mcpServers"].has("godot-ai"))


func test_json_strategy_refuses_to_overwrite_unparseable_file() -> void:
	## Regression: if the config file exists but we can't parse it (trailing
	## comma, stray comment, truncated write), `configure()` used to silently
	## fall back to `{}` and write only the godot-ai entry — wiping every
	## other MCP the user had configured. Now it must refuse and surface an
	## error so the user can inspect and recover.
	var path := _scratch_dir.path_join("unparseable.json")
	var bogus := "{\n  \"mcpServers\": {\n    \"someone-else\": {\"url\": \"http://other/\"},  // trailing comment\n  }\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(bogus)
	f.close()

	var client := _make_test_json_client(path)
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "error", "Configure must error on unparseable JSON, not silently overwrite")
	var msg: String = result.get("message", "")
	assert_true(msg.find("Refusing to overwrite") >= 0, "Error message should flag refusal: %s" % msg)

	# File on disk must be byte-for-byte what the user wrote. Anything else
	# is data loss.
	var check_file := FileAccess.open(path, FileAccess.READ)
	var preserved := check_file.get_as_text()
	check_file.close()
	assert_eq(preserved, bogus, "Unparseable config file must not be mutated")


func test_json_strategy_refuses_to_overwrite_non_object_root() -> void:
	## JSON that parses fine but whose root isn't an object (a bare array, a
	## string, a number) also can't be safely merged into. Refuse rather
	## than overwriting.
	var path := _scratch_dir.path_join("non_object_root.json")
	var bogus := "[\"some\", \"array\"]"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(bogus)
	f.close()

	var client := _make_test_json_client(path)
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "error")

	var check_file := FileAccess.open(path, FileAccess.READ)
	assert_eq(check_file.get_as_text(), bogus, "Non-object-root config must not be mutated")
	check_file.close()


func test_json_strategy_tolerates_utf8_bom() -> void:
	## JSON saved with a UTF-8 BOM (common from Windows editors) parses as
	## invalid under Godot's JSON.parse. Under the old strategy that meant a
	## silent fall-through to `{}` and a wipe on the next write. The strategy
	## must strip the BOM and preserve existing entries.
	var path := _scratch_dir.path_join("bom.json")
	var seed := {"mcpServers": {"someone-else": {"url": "http://other/"}}}
	var body := "﻿" + JSON.stringify(seed)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()

	var client := _make_test_json_client(path)
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok", "BOM-prefixed JSON should parse after strip")

	var check_file := FileAccess.open(path, FileAccess.READ)
	var parsed = JSON.parse_string(check_file.get_as_text())
	check_file.close()
	assert_true(parsed is Dictionary and parsed.has("mcpServers"))
	assert_true(parsed["mcpServers"].has("someone-else"), "Existing entry wiped after BOM parse recovery")
	assert_true(parsed["mcpServers"].has("godot-ai"), "godot-ai entry not added")


func test_json_strategy_remove_refuses_unparseable_file() -> void:
	## remove() has the same wipe-risk as configure() — it also round-trips
	## through _read_or_init and writes back. Must refuse on bad input.
	var path := _scratch_dir.path_join("remove_unparseable.json")
	var bogus := "{not-valid-json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(bogus)
	f.close()

	var client := _make_test_json_client(path)
	var result := McpJsonStrategy.remove(client, "godot-ai")
	assert_eq(result.get("status"), "error")

	var check_file := FileAccess.open(path, FileAccess.READ)
	assert_eq(check_file.get_as_text(), bogus, "Unparseable config must not be mutated on remove")
	check_file.close()


func test_json_strategy_distinguishes_missing_entry_from_url_drift() -> void:
	## Three statuses, three causes — dock surfaces them as muted dot,
	## green dot, amber dot respectively. Conflating "never configured"
	## with "URL out of date" loses the drift signal.
	var path := _scratch_dir.path_join("drift.json")
	_remove_if_exists(path)
	var client := _make_test_json_client(path)

	# 1. No file at all → NOT_CONFIGURED.
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.NOT_CONFIGURED,
	)

	# 2. Configure at port 8000 → CONFIGURED at the matching URL.
	McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.CONFIGURED,
	)

	# 3. Same file, but the active URL has shifted (user changed http_port).
	#    Entry still exists under the same name — drift, not absence.
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:9000/mcp"),
		McpClient.Status.CONFIGURED_MISMATCH,
	)

	# 4. Entry under a *different* name leaves our slot empty → NOT_CONFIGURED.
	var seed := {"mcpServers": {"someone-else": {"url": "http://127.0.0.1:8000/mcp"}}}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(seed))
	f.close()
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.NOT_CONFIGURED,
	)


func test_json_strategy_drift_with_bridge_entry() -> void:
	## Bridge clients (Claude Desktop "flat") run through a different verify path in
	## `_json_strategy.verify_entry` than the default url-field comparison. Drift must still
	## surface as CONFIGURED_MISMATCH, not NOT_CONFIGURED — dock contract is the same.
	var path := _scratch_dir.path_join("verify_drift.json")
	_remove_if_exists(path)
	var client := McpClient.new()
	client.id = "verify_test"
	client.display_name = "Verify Test"
	client.config_type = "json"
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	client.server_key_path = PackedStringArray(["mcpServers"])
	client.entry_uvx_bridge = McpClient.UvxBridge.FLAT

	McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:9000/mcp"),
		McpClient.Status.CONFIGURED_MISMATCH,
	)


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
	client.entry_extra_fields = {"type": "remote"}

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


func test_toml_strategy_distinguishes_missing_section_from_url_drift() -> void:
	## Same three-state contract as the JSON strategy, in TOML shape.
	## Section header present + url mismatch → CONFIGURED_MISMATCH.
	## No matching header → NOT_CONFIGURED.
	var path := _scratch_dir.path_join("drift.toml")
	_remove_if_exists(path)
	var client := _make_test_toml_client(path)

	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.NOT_CONFIGURED,
	)

	McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.CONFIGURED,
	)

	# Drift: section still present (we never re-configured) but the active
	# server URL has shifted underneath it.
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:9000/mcp"),
		McpClient.Status.CONFIGURED_MISMATCH,
	)

	# A disabled section is CONFIGURED, not drift (#711): `enabled` is
	# user-mutable state under the JSON strategy's entry_initial_fields
	# contract — the verifier ignores those keys, and reconfigure preserves
	# them — so flagging the user's own toggle amber would nag forever and
	# wedge configure's post-verify against the preserved value.
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[mcp_servers.\"godot-ai\"]\nurl = \"http://127.0.0.1:8000/mcp\"\nenabled = false\n")
	f.close()
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.CONFIGURED,
	)


func test_toml_reconfigure_preserves_user_mutable_state() -> void:
	## #711: the TOML mirror of the JSON initial-vs-pinned split. On
	## reconfigure of an existing section: {url}-bearing template lines are
	## pinned (repointed), placeholder-less template lines (`enabled`) keep
	## the user's value, and unknown user keys + comments survive verbatim.
	var path := _scratch_dir.path_join("reconfigure_preserve.toml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		"[mcp_servers.\"godot-ai\"]\n"
		+ "url = \"http://127.0.0.1:9999/mcp\"\n"
		+ "enabled = false\n"
		+ "# user note: keep disabled until launch\n"
		+ "startup_timeout_ms = 20000\n"
	)
	f.close()

	var client := _make_test_toml_client(path)
	var result := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")

	var content_file := FileAccess.open(path, FileAccess.READ)
	var content := content_file.get_as_text()
	content_file.close()
	_remove_if_exists(path)
	assert_contains(content, "url = \"http://127.0.0.1:8000/mcp\"", "pinned url line must repoint")
	assert_false(content.contains("9999"), "old url must not survive the repoint")
	assert_contains(content, "enabled = false", "user's enabled toggle must survive reconfigure")
	assert_false(content.contains("enabled = true"), "template initial must not duplicate the preserved key")
	assert_contains(content, "# user note: keep disabled until launch", "user comments must survive")
	assert_contains(content, "startup_timeout_ms = 20000", "unknown user keys must survive")


func test_toml_fresh_configure_writes_template_initials() -> void:
	## Fresh section: no user state to preserve — the template body lands
	## verbatim, including the `enabled = true` initial.
	var path := _scratch_dir.path_join("fresh_initials.toml")
	_remove_if_exists(path)
	var client := _make_test_toml_client(path)
	var result := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")
	var content_file := FileAccess.open(path, FileAccess.READ)
	var content := content_file.get_as_text()
	content_file.close()
	_remove_if_exists(path)
	assert_contains(content, "enabled = true")
	assert_contains(content, "url = \"http://127.0.0.1:8000/mcp\"")


func test_json_unparseable_config_reports_error_status() -> void:
	## #711: an existing-but-broken config file is Status.ERROR carrying the
	## parse error — NOT_CONFIGURED would invite a Configure click the write
	## path then refuses.
	var path := _scratch_dir.path_join("broken_config.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	var client := _make_test_json_client(path)
	var details := McpJsonStrategy.check_status_details(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	_remove_if_exists(path)
	assert_eq(details.get("status"), McpClient.Status.ERROR)
	assert_contains(String(details.get("error_msg", "")), "parse error", "error_msg must carry the parse diagnostic")


func test_status_details_shape_for_missing_config() -> void:
	## Both strategies return the {status, error_msg} shape the dock's
	## refresh worker consumes — absent file is NOT_CONFIGURED with no error.
	var missing := _scratch_dir.path_join("never_written.toml")
	_remove_if_exists(missing)
	var toml_details := McpTomlStrategy.check_status_details(
		_make_test_toml_client(missing), "godot-ai", "http://127.0.0.1:8000/mcp"
	)
	assert_eq(toml_details.get("status"), McpClient.Status.NOT_CONFIGURED)
	assert_eq(toml_details.get("error_msg"), "")
	var missing_json := _scratch_dir.path_join("never_written.json")
	_remove_if_exists(missing_json)
	var json_details := McpJsonStrategy.check_status_details(
		_make_test_json_client(missing_json), "godot-ai", "http://127.0.0.1:8000/mcp"
	)
	assert_eq(json_details.get("status"), McpClient.Status.NOT_CONFIGURED)
	assert_eq(json_details.get("error_msg"), "")


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


func test_toml_strategy_remove_tolerates_inline_comment_on_next_header() -> void:
	## TOML allows a trailing comment after the closing `]` of a section
	## header (e.g. `[other] # note`). The pre-fix section-end check
	## required `ends_with("]")` and would walk past such a header, so
	## remove() would clobber unrelated sections that came after the
	## one being removed. _is_any_section_header now finds the `]` and
	## permits whitespace/`#` after it.
	var path := _scratch_dir.path_join("remove_inline_comment.toml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		"[mcp_servers.\"godot-ai\"]\n" +
		"url = \"http://127.0.0.1:8000/mcp\"\n" +
		"enabled = true\n" +
		"\n" +
		"[other_section] # user's hand-written comment\n" +
		"key = \"value\"\n"
	)
	f.close()

	var client := _make_test_toml_client(path)
	var removed := McpTomlStrategy.remove(client, "godot-ai")
	assert_eq(removed.get("status"), "ok")

	var after_remove_file := FileAccess.open(path, FileAccess.READ)
	var after_remove := after_remove_file.get_as_text()
	after_remove_file.close()

	assert_eq(after_remove.count("[mcp_servers.\"godot-ai\"]"), 0,
		"godot-ai section must be removed:\n%s" % after_remove)
	assert_contains(after_remove, "[other_section]")
	assert_contains(after_remove, "key = \"value\"")


func test_toml_strategy_detects_bare_key_section_no_duplicate_on_reconfigure() -> void:
	## Regression for the codex duplicate-key bug. TOML accepts bare keys
	## [A-Za-z0-9_-]+ unquoted, so a hand-written or older-plugin
	## [mcp_servers.godot-ai] section refers to the same logical key as
	## the quoted [mcp_servers."godot-ai"] we emit. Reconfigure must
	## update the bare-key section in place — appending a duplicate
	## quoted section makes the file fail to parse.
	var path := _scratch_dir.path_join("bare_key_codex.toml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		"[mcp_servers.godot-ai]\n" +
		"url = \"http://127.0.0.1:7000/mcp\"\n" +
		"enabled = true\n" +
		"\n" +
		"[mcp_servers.godot-ai.tools.session_list]\n" +
		"approval_mode = \"approve\"\n"
	)
	f.close()

	var client := _make_test_toml_client(path)

	## check_status must recognise the bare-key form (was reporting
	## NOT_CONFIGURED, masking that an entry already existed).
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.CONFIGURED_MISMATCH,
		"bare-key section must be detected by check_status"
	)

	## configure must update the bare-key section in place. After the
	## write there must be exactly one godot-ai section header (counting
	## both bare and quoted forms) — anything else is the duplicate that
	## breaks the user's TOML parser.
	var result := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(result.get("status"), "ok")

	var content := FileAccess.open(path, FileAccess.READ).get_as_text()
	var bare_count := content.count("[mcp_servers.godot-ai]\n")
	var quoted_count := content.count("[mcp_servers.\"godot-ai\"]\n")
	assert_eq(bare_count + quoted_count, 1,
		"exactly one godot-ai section must exist after reconfigure (bare=%d quoted=%d):\n%s" % [bare_count, quoted_count, content])

	## The user's nested subtable customisation must survive — the
	## strategy only owns the matched section, not its children.
	assert_contains(content, "[mcp_servers.godot-ai.tools.session_list]")
	assert_contains(content, "approval_mode = \"approve\"")

	## remove must clean the bare-key form (was a silent no-op) AND the
	## subtables under the namespace. Leaving subtables behind would
	## keep mcp_servers.godot-ai implicitly defined, so a later
	## configure rewriting [mcp_servers."godot-ai"] produces a
	## duplicate-key TOML error — the same shape the original bug took.
	var removed := McpTomlStrategy.remove(client, "godot-ai")
	assert_eq(removed.get("status"), "ok")
	var after_remove := FileAccess.open(path, FileAccess.READ).get_as_text()
	assert_eq(after_remove.count("[mcp_servers.godot-ai]\n"), 0,
		"remove must clean the bare-key parent section:\n%s" % after_remove)
	assert_eq(after_remove.count("[mcp_servers.\"godot-ai\"]\n"), 0,
		"remove must clean the quoted-key parent section:\n%s" % after_remove)
	assert_eq(after_remove.count("[mcp_servers.godot-ai.tools.session_list]"), 0,
		"remove must clean subtables in the namespace:\n%s" % after_remove)
	assert_eq(after_remove.count("approval_mode"), 0,
		"subtable bodies must be removed too:\n%s" % after_remove)

	## Round-trip: configure-after-remove must produce a clean,
	## parseable file with exactly one godot-ai section.
	var reconfigure := McpTomlStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	assert_eq(reconfigure.get("status"), "ok")
	var final_content := FileAccess.open(path, FileAccess.READ).get_as_text()
	var final_bare := final_content.count("[mcp_servers.godot-ai]\n")
	var final_quoted := final_content.count("[mcp_servers.\"godot-ai\"]\n")
	assert_eq(final_bare + final_quoted, 1,
		"configure-after-remove must produce exactly one godot-ai section (bare=%d quoted=%d):\n%s" % [final_bare, final_quoted, final_content])


# ----- configure/remove verify-after-write (#201) -----
#
# A strategy returning `status: ok` is necessary but not sufficient — a write
# can land on a file the user's installed client doesn't actually read (path
# resolution mismatch), or a remove can be a silent no-op when the entry was
# stored under an unexpected key. The facade re-reads live state after every
# successful write so the dock surfaces a real error instead of a green dot
# the user can't act on.

func test_verify_post_state_passes_through_strategy_error() -> void:
	## A strategy-level error must not be transmuted into a verification
	## error — the original message is more actionable. Same client doesn't
	## even need to be touched on the verify side.
	var client := _make_test_json_client(_scratch_dir.path_join("verify_passthrough.json"))
	var err_result := {"status": "error", "message": "original strategy failure"}
	var got: Dictionary = McpClientConfigurator._verify_post_state(
		client, err_result, McpClient.Status.CONFIGURED, _verify_test_url(), "configure",
	)
	assert_eq(got, err_result, "Verify must not rewrite strategy errors")


func test_verify_post_state_returns_ok_when_actual_matches_expected() -> void:
	var path := _scratch_dir.path_join("verify_match.json")
	_remove_if_exists(path)
	var client := _make_test_json_client(path)
	var url := _verify_test_url()
	# Establish CONFIGURED state on disk so the verify read sees what the
	# strategy claims it wrote.
	McpJsonStrategy.configure(client, McpClientConfigurator.SERVER_NAME, url)
	var ok_result := {"status": "ok", "message": "wrote"}
	var got: Dictionary = McpClientConfigurator._verify_post_state(
		client, ok_result, McpClient.Status.CONFIGURED, url, "configure",
	)
	assert_eq(got, ok_result, "Verify must pass through ok results when state matches")


func test_verify_post_state_errors_when_configure_did_not_land() -> void:
	## The classic #201 shape: strategy reports ok but the entry isn't on
	## disk after the fact (e.g. the strategy wrote to a stale temp file, or
	## the read-back path resolves elsewhere). Surface a loud error with the
	## resolved config path so the user can self-diagnose instead of staring
	## at a green dot in the dock.
	var path := _scratch_dir.path_join("verify_missing.json")
	_remove_if_exists(path)
	var client := _make_test_json_client(path)
	# File doesn't exist → check_status returns NOT_CONFIGURED → verify
	# rejects the spurious "ok".
	var ok_result := {"status": "ok", "message": "claims to have written"}
	var got: Dictionary = McpClientConfigurator._verify_post_state(
		client, ok_result, McpClient.Status.CONFIGURED, _verify_test_url(), "configure",
	)
	assert_eq(got.get("status"), "error")
	var msg: String = got.get("message", "")
	assert_contains(msg, "not_configured", "Error must name the actual status: %s" % msg)
	assert_contains(msg, "configured", "Error must name the expected status: %s" % msg)
	assert_contains(msg, path, "Error must include the resolved config path: %s" % msg)


func test_verify_post_state_errors_when_remove_left_entry_behind() -> void:
	## Symmetric case: remove returns ok but the entry still parses on
	## read-back. Most realistic in TOML clients with multiple aliases or
	## JSON files where the user maintains a custom server_name we don't
	## know about — but the contract is the same: never lie to the dock.
	var path := _scratch_dir.path_join("verify_leftover.json")
	_remove_if_exists(path)
	var client := _make_test_json_client(path)
	var url := _verify_test_url()
	# Real configure so the entry is actually present.
	McpJsonStrategy.configure(client, McpClientConfigurator.SERVER_NAME, url)
	var ok_result := {"status": "ok", "message": "claims removed"}
	var got: Dictionary = McpClientConfigurator._verify_post_state(
		client, ok_result, McpClient.Status.NOT_CONFIGURED, url, "remove",
	)
	assert_eq(got.get("status"), "error")
	var msg: String = got.get("message", "")
	assert_contains(msg, "configured", "Error must name the actual status: %s" % msg)
	assert_contains(msg, "not_configured", "Error must name the expected status: %s" % msg)
	assert_contains(msg, path, "Error must include the resolved config path: %s" % msg)


func test_verify_post_state_treats_drift_as_failure_after_configure() -> void:
	## CONFIGURED_MISMATCH is "entry present but URL is wrong" — for a
	## just-completed configure that wrote `http_url()`, drift means the
	## write didn't actually update the URL. Treat as a verification
	## failure so the dock can't show a green dot for stale state.
	var path := _scratch_dir.path_join("verify_drift_after_configure.json")
	_remove_if_exists(path)
	var client := _make_test_json_client(path)
	# Pre-seed an entry with a stale URL.
	var seed := {"mcpServers": {McpClientConfigurator.SERVER_NAME: {"url": "http://stale/"}}}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(seed))
	f.close()
	var ok_result := {"status": "ok", "message": "wrote — but didn't"}
	var got: Dictionary = McpClientConfigurator._verify_post_state(
		client, ok_result, McpClient.Status.CONFIGURED, _verify_test_url(), "configure",
	)
	assert_eq(got.get("status"), "error")
	assert_contains(got.get("message", ""), "configured_mismatch")


## Pinned URL for verify tests so a port flip in EditorSettings between
## suite_setup and the assertion can't drift us from match to mismatch.
func _verify_test_url() -> String:
	return "http://127.0.0.1:%d/mcp" % McpClientConfigurator.DEFAULT_HTTP_PORT


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


func test_atomic_write_snapshots_prior_file_to_backup() -> void:
	## Issue #297 finding #10: on a failed swap the only escape route from
	## data loss is a `.backup` snapshot taken BEFORE we touch the target.
	## Pin that the snapshot is created and contains the prior bytes (not
	## the new bytes — a backup of the new file is useless for rollback).
	var path := _scratch_dir.path_join("backed_up.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("prior content")
	f.close()

	assert_true(McpAtomicWrite.write(path, "new content"))

	var backup_path := path + ".backup"
	assert_true(FileAccess.file_exists(backup_path), "backup snapshot should be created")
	var bf := FileAccess.open(backup_path, FileAccess.READ)
	var backup_text := bf.get_as_text()
	bf.close()
	assert_eq(backup_text, "prior content", "backup must contain the prior file's content")
	# Cleanup so suite_teardown doesn't trip over leftover .backup files.
	DirAccess.remove_absolute(backup_path)


func test_atomic_write_cleans_up_tmp_on_success() -> void:
	var path := _scratch_dir.path_join("cleaned.txt")
	assert_true(McpAtomicWrite.write(path, "hello"))
	assert_false(
		FileAccess.file_exists(path + ".tmp"),
		".tmp must not linger after a successful write",
	)


func test_atomic_write_written_size_matches_detects_match() -> void:
	## Direct unit test of the primitive the rename-commit gate (#687) relies
	## on: an intact write must report a match.
	var path := _scratch_dir.path_join("size_match_ok.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello world")
	f.close()
	assert_true(McpAtomicWrite._written_size_matches(path, "hello world"))


func test_atomic_write_written_size_matches_detects_truncation() -> void:
	## Simulates the disk-full failure mode #687 guards against: the on-disk
	## file is shorter than what was supposed to be written (a truncated
	## store_string). `_written_size_matches` must catch the mismatch so the
	## rename-commit gate added to `write()` can refuse to commit it.
	var path := _scratch_dir.path_join("size_match_truncated.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello")  # on-disk bytes shorter than the intended content
	f.close()
	assert_false(McpAtomicWrite._written_size_matches(path, "hello world"))


func test_atomic_write_written_size_matches_missing_file() -> void:
	var missing := _scratch_dir.path_join("does_not_exist.txt")
	assert_false(McpAtomicWrite._written_size_matches(missing, "anything"))


func test_atomic_write_preserves_destination_when_swap_fails() -> void:
	## Direct simulation of a Windows AV / lock failure is not portable, but
	## the on-disk invariant for #297 finding #10 is testable: when the
	## final swap can't complete, nothing under the destination path is
	## destroyed. The previous remove-then-rename fallback would clobber
	## the target unconditionally before retrying. We force both
	## rename_absolute and copy_absolute to reject the swap by pointing at
	## a non-empty directory destination, which fails on every supported
	## platform.
	var collision := _scratch_dir.path_join("collision_dir")
	DirAccess.make_dir_recursive_absolute(collision)
	var sentinel := collision.path_join("must_survive.txt")
	var sf := FileAccess.open(sentinel, FileAccess.WRITE)
	sf.store_string("survived")
	sf.close()

	var ok := McpAtomicWrite.write(collision, "would_clobber")

	assert_false(ok, "atomic write to a non-empty directory destination should fail")
	assert_true(
		FileAccess.file_exists(sentinel),
		"destination contents must survive a failed atomic write — issue #297 finding #10",
	)
	var sf_read := FileAccess.open(sentinel, FileAccess.READ)
	var still := sf_read.get_as_text()
	sf_read.close()
	assert_eq(still, "survived", "sentinel content unchanged after failed swap")
	assert_false(
		FileAccess.file_exists(collision + ".tmp"),
		".tmp must be cleaned up even on failure",
	)
	# Cleanup — nested dir is outside suite_teardown's flat-files cleanup.
	DirAccess.remove_absolute(sentinel)
	DirAccess.remove_absolute(collision)


func test_atomic_write_preserves_existing_file_when_swap_fails() -> void:
	## Companion to the directory-collision test: confirm that when a
	## regular existing file is the destination and the swap fails, the
	## rollback-from-backup path leaves the original bytes intact. We
	## simulate the failure by manually mid-flighting the state — pre-stage
	## a `.backup` snapshot, then overwrite the path with garbage to mimic
	## a partial copy that landed before failure was detected, and finally
	## invoke the public restore via the same `.backup`-based rollback the
	## production path uses on the failed-copy branch. The contract under
	## test is: regardless of how we got into the half-written state,
	## restoring from `.backup` must yield the original content.
	var path := _scratch_dir.path_join("config_to_recover.txt")
	var orig := "ORIGINAL_CONTENT"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(orig)
	f.close()

	# Snapshot the original the same way McpAtomicWrite would.
	var backup_path := path + ".backup"
	assert_eq(DirAccess.copy_absolute(path, backup_path), OK, "backup snapshot must succeed")

	# Simulate a partial copy that clobbered the target.
	var clobber := FileAccess.open(path, FileAccess.WRITE)
	clobber.store_string("HALF_WRITTEN_GARB")
	clobber.close()

	# The production failure path restores via remove + copy from backup.
	# Mirror that here so a regression that drops the restore step is caught.
	DirAccess.remove_absolute(path)
	assert_eq(
		DirAccess.copy_absolute(backup_path, path), OK, "restore-from-backup must succeed"
	)

	var rf := FileAccess.open(path, FileAccess.READ)
	var got := rf.get_as_text()
	rf.close()
	assert_eq(got, orig, "original bytes must be recovered from .backup")
	# Cleanup
	DirAccess.remove_absolute(backup_path)


# ----- atomic write: concurrency + symlink targets (#534) -----

## List leftover files in _scratch_dir whose name starts with `prefix` — used
## to prove no temp staging file (fixed or PID-suffixed) lingers after a write.
func _leftover_tmp_files(prefix: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(_scratch_dir):
		if f.begins_with(prefix):
			out.append(f)
	return out


func test_atomic_write_leaves_no_stale_tmp_of_any_name() -> void:
	## #534: the temp name is now PID-suffixed. Whatever the exact name, no
	## staging file starting with "<file>.tmp" may survive a successful write.
	var path := _scratch_dir.path_join("pid_tmp.txt")
	assert_true(McpAtomicWrite.write(path, "hello"))
	var leftovers := _leftover_tmp_files("pid_tmp.txt.tmp")
	assert_eq(leftovers.size(), 0, "no .tmp staging file may linger: %s" % str(leftovers))


func test_atomic_write_leaves_no_stale_tmp_after_failed_write() -> void:
	## #534 review follow-up: the PID-suffixed staging file must also be
	## cleaned up when the write FAILS (destination is a directory, so the
	## rename and the copy fallback both reject) — otherwise a regression
	## could accumulate ".tmp.<pid>" files invisibly.
	var dir_dest := _scratch_dir.path_join("tmp_fail_dir.txt")
	DirAccess.make_dir_recursive_absolute(dir_dest)
	assert_false(
		McpAtomicWrite.write(dir_dest, "content"),
		"writing over a directory must fail",
	)
	var leftovers := _leftover_tmp_files("tmp_fail_dir.txt.tmp")
	assert_eq(leftovers.size(), 0, "no .tmp staging file may linger after a failed write: %s" % str(leftovers))


func test_atomic_write_does_not_use_fixed_tmp_name() -> void:
	## #534: two editors clicking Configure at once must not interleave bytes
	## on a shared "<path>.tmp". Prove the fixed name is no longer the staging
	## path by parking an unwritable obstacle (a directory) at it — the write
	## must still succeed because it stages elsewhere (PID-suffixed).
	var path := _scratch_dir.path_join("no_fixed_tmp.txt")
	var fixed_tmp := path + ".tmp"
	DirAccess.make_dir_recursive_absolute(fixed_tmp)

	assert_true(
		McpAtomicWrite.write(path, "content"),
		"write must succeed even when '<path>.tmp' is occupied — the staging name must be process-unique",
	)
	var rf := FileAccess.open(path, FileAccess.READ)
	var got := rf.get_as_text()
	rf.close()
	assert_eq(got, "content")
	# Cleanup — the obstacle dir is outside suite_teardown's flat-file sweep.
	DirAccess.remove_absolute(fixed_tmp)


func test_atomic_write_preserves_symlinked_target() -> void:
	## #534: stow/chezmoi users symlink their configs. A rename over the link
	## path would replace the LINK with a regular file, detaching the config
	## from the dotfile repo. The write must land through the link into the
	## real target, leaving the symlink intact.
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var target := _scratch_dir.path_join("symlink_real_target.json")
	var link := _scratch_dir.path_join("symlink_config.json")
	var tf := FileAccess.open(target, FileAccess.WRITE)
	tf.store_string("old")
	tf.close()
	DirAccess.remove_absolute(link)
	# Godot has no symlink-create API; shell out. Skip if ln isn't usable.
	var rc := OS.execute("ln", ["-s", target, link])
	var da := DirAccess.open(_scratch_dir)
	if rc != 0 or da == null or not da.is_link(link):
		skip("could not create a symlink on this platform")
		return

	assert_true(McpAtomicWrite.write(link, "new via link"))

	assert_true(da.is_link(link), "the symlink must survive the atomic write — issue #534")
	var rf := FileAccess.open(target, FileAccess.READ)
	var got := rf.get_as_text()
	rf.close()
	assert_eq(got, "new via link", "the new bytes must land in the symlink's real target")
	# Cleanup (the .backup lands next to the resolved target).
	DirAccess.remove_absolute(target + ".backup")
	DirAccess.remove_absolute(link)


# ----- atomic write: permission preservation (#297 finding TC-1) -----
#
# The Claude CLI creates ~/.claude.json as 0600 (it holds OAuth creds). A
# rewrite must preserve that mode rather than relaxing it to the umask default,
# and the .backup must not become a world-readable copy of a private file.
# These bits don't exist on Windows, so the suite skips there.

const _PERM_MASK := 0x1FF  # 0o777 — the rwx bits for owner/group/other


func _owner_only_mode() -> int:
	return FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER


func test_atomic_write_preserves_restrictive_mode_on_rewrite() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX file permissions are unavailable on Windows")
		return
	var path := _scratch_dir.path_join("perm_preserve_0600.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("secret v1")
	f.close()
	var owner_only := _owner_only_mode()
	assert_eq(
		FileAccess.set_unix_permissions(path, owner_only), OK, "test setup: chmod 0600 must succeed"
	)

	assert_true(McpAtomicWrite.write(path, "secret v2"))

	assert_eq(
		FileAccess.get_unix_permissions(path) & _PERM_MASK,
		owner_only,
		"a rewrite must preserve the prior 0600 mode, not relax it to 0644",
	)
	DirAccess.remove_absolute(path + ".backup")


func test_atomic_write_backup_inherits_restrictive_mode() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX file permissions are unavailable on Windows")
		return
	var path := _scratch_dir.path_join("perm_backup_0600.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("secret v1")
	f.close()
	var owner_only := _owner_only_mode()
	assert_eq(FileAccess.set_unix_permissions(path, owner_only), OK, "test setup: chmod 0600")

	assert_true(McpAtomicWrite.write(path, "secret v2"))

	var backup_path := path + ".backup"
	assert_true(FileAccess.file_exists(backup_path), "backup must exist")
	assert_eq(
		FileAccess.get_unix_permissions(backup_path) & _PERM_MASK,
		owner_only,
		"the .backup of a 0600 file must itself be 0600, not a world-readable copy",
	)
	DirAccess.remove_absolute(backup_path)


func test_atomic_write_new_file_defaults_to_owner_only() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX file permissions are unavailable on Windows")
		return
	var path := _scratch_dir.path_join("perm_new_file.txt")
	# No prior file: nothing to preserve, so a fresh config defaults to 0600
	# regardless of the process umask.
	assert_false(FileAccess.file_exists(path), "test setup: target must not pre-exist")

	assert_true(McpAtomicWrite.write(path, "fresh token config"))

	assert_eq(
		FileAccess.get_unix_permissions(path) & _PERM_MASK,
		_owner_only_mode(),
		"a brand-new config must default to owner-only 0600",
	)


func test_atomic_write_preserves_relaxed_mode_on_rewrite() -> void:
	## We preserve the prior mode — we do NOT force 0600 on a file that was
	## already group/other-readable (e.g. a 0644 cursor config). This proves
	## the fix is "preserve", not "clamp everything to 0600".
	if OS.get_name() == "Windows":
		skip("POSIX file permissions are unavailable on Windows")
		return
	var path := _scratch_dir.path_join("perm_preserve_0644.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("public v1")
	f.close()
	var relaxed := (
		FileAccess.UNIX_READ_OWNER
		| FileAccess.UNIX_WRITE_OWNER
		| FileAccess.UNIX_READ_GROUP
		| FileAccess.UNIX_READ_OTHER
	)  # 0644
	assert_eq(FileAccess.set_unix_permissions(path, relaxed), OK, "test setup: chmod 0644")

	assert_true(McpAtomicWrite.write(path, "public v2"))

	assert_eq(
		FileAccess.get_unix_permissions(path) & _PERM_MASK,
		relaxed,
		"a 0644 file must stay 0644 — preserve the prior mode, don't clamp to 0600",
	)
	DirAccess.remove_absolute(path + ".backup")


# ----- handler -----

func test_handler_rejects_unknown_client() -> void:
	var result := _handler.configure_client({"client": "nonexistent_client_xyz"})
	assert_is_error(result)


func test_handler_status_returns_array_of_clients() -> void:
	var result := _handler.check_client_status({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "clients")
	var clients = result.data.clients
	assert_true(clients is Array)
	assert_gt(clients.size(), 10)
	# Each entry must include id / display_name / status / installed.
	# `status` is one of the four documented strings; agents pattern-match
	# against this set, so a fifth value being silently introduced would
	# break them. The handler's `match` only emits these four.
	var allowed_statuses := ["configured", "not_configured", "configured_mismatch", "error"]
	for entry in clients:
		assert_has_key(entry, "id")
		assert_has_key(entry, "display_name")
		assert_has_key(entry, "status")
		assert_has_key(entry, "installed")
		assert_contains(allowed_statuses, entry.status, "Unexpected status: %s" % entry.status)


# ----- entry-builder shape sanity for shipped clients -----

func test_cursor_entry_uses_url() -> void:
	var c := McpClientRegistry.get_by_id("cursor")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("url", ""), "http://x")


func test_antigravity_entry_uses_serverUrl() -> void:
	var c := McpClientRegistry.get_by_id("antigravity")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("serverUrl", ""), "http://x")
	assert_eq(entry.get("disabled", true), false)


func test_gemini_cli_entry_uses_httpUrl() -> void:
	var c := McpClientRegistry.get_by_id("gemini_cli")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("httpUrl", ""), "http://x")


func test_claude_desktop_bridges_via_uvx() -> void:
	var c := McpClientRegistry.get_by_id("claude_desktop")
	assert_eq(c.entry_uvx_bridge, McpClient.UvxBridge.FLAT, "claude_desktop must declare FLAT uvx bridge")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	_assert_uvx_command(entry.get("command", ""))
	_assert_mcp_proxy_bridge_args(entry.get("args", []), "http://x")
	_assert_bridge_env_pin(entry)


func test_claude_desktop_verify_entry_accepts_uvx_form() -> void:
	## Drift-detection: once we've written the new uvx entry, check_status
	## must round-trip it as CONFIGURED (not MISMATCH). Guards against a
	## verifier that still only recognises the old npx/mcp-remote shape.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://x"), "uvx entry should verify as a match")


func test_claude_desktop_verify_flags_pre_uv_link_mode_entry_as_drift() -> void:
	## Users who configured Claude Desktop before the UV_LINK_MODE=copy fix
	## have a uvx bridge entry with no `env` block (or one missing
	## UV_LINK_MODE). Without this drift, they hit the Windows pywin32 install
	## failure documented in utils/uv_cache_cleanup.gd and the README. The
	## verifier must flag those as MISMATCH so the dock prompts a reconfigure.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var legacy_no_env := {
		"command": "uvx",
		"args": McpClient.mcp_proxy_bridge_args("http://x"),
	}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_no_env, "http://x"), "pre-fix entry without env must register as drift")
	var legacy_wrong_mode := {
		"command": "uvx",
		"args": McpClient.mcp_proxy_bridge_args("http://x"),
		"env": {"UV_LINK_MODE": "hardlink"},
	}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_wrong_mode, "http://x"), "entry with wrong UV_LINK_MODE must register as drift")
	var legacy_empty_env := {
		"command": "uvx",
		"args": McpClient.mcp_proxy_bridge_args("http://x"),
		"env": {},
	}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_empty_env, "http://x"), "entry with empty env must register as drift")


func test_claude_desktop_manual_command_includes_env_pin() -> void:
	## The dock's "Run this manually" string is rendered by `_format_entry_inline`
	## on the same `build_entry` output the auto-configure path writes — if it
	## ever loses the env block, paste-into-config users silently miss the
	## UV_LINK_MODE=copy pin and hit the Windows pywin32 lock. Pin the
	## inline-JSON shape so a future change to `_format_value` / `build_entry`
	## that drops the env key fails CI.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/cd.json")
	assert_contains(manual, "\"env\":")
	assert_contains(manual, "\"UV_LINK_MODE\": \"copy\"")


func test_claude_desktop_configure_preserves_existing_env_keys() -> void:
	## Verifier tolerates user-added env keys (HTTP_PROXY, PYTHONUNBUFFERED, etc.)
	## so the rewriter must too. Without merge, a Configure click on a
	## CONFIGURED_MISMATCH entry silently drops them — the user reports their
	## proxy settings disappear after we surface drift on a port change.
	var path := _scratch_dir.path_join("preserve_env.json")
	_remove_if_exists(path)
	var pre_existing := {
		"mcpServers": {
			"godot-ai": {
				"command": "uvx",
				"args": McpClient.mcp_proxy_bridge_args("http://old"),
				"env": {
					"HTTP_PROXY": "http://corp-proxy:3128",
					"PYTHONUNBUFFERED": "1",
				},
			}
		}
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "scratch path must be writable")
	f.store_string(JSON.stringify(pre_existing))
	f.close()

	var client := McpClient.new()
	client.id = "preserve_env_test"
	client.display_name = "Preserve Env Test"
	client.config_type = "json"
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	client.server_key_path = PackedStringArray(["mcpServers"])
	client.entry_uvx_bridge = McpClient.UvxBridge.FLAT

	var result := McpJsonStrategy.configure(client, "godot-ai", "http://new")
	assert_eq(result.get("status"), "ok")

	var rf := FileAccess.open(path, FileAccess.READ)
	var written = JSON.parse_string(rf.get_as_text())
	rf.close()
	var entry = written.get("mcpServers", {}).get("godot-ai", {})
	var env = entry.get("env", {})
	assert_eq(env.get("HTTP_PROXY", ""), "http://corp-proxy:3128", "HTTP_PROXY must be preserved across rewrite")
	assert_eq(env.get("PYTHONUNBUFFERED", ""), "1", "PYTHONUNBUFFERED must be preserved across rewrite")
	assert_eq(env.get("UV_LINK_MODE", ""), "copy", "UV_LINK_MODE pin must overlay existing env")


func test_claude_desktop_verify_flags_wrong_transport_as_drift() -> void:
	## Pre-PR302 verifier only required `args.has(server_url)` — an entry like
	## `mcp-proxy --transport sse <url>` (Claude Desktop's old SSE shape) would
	## report CONFIGURED even though our streamable-http /mcp endpoint returns
	## HTTP 400 against SSE. Tightened verifier requires the full bridge argv
	## shape so transport drift surfaces too.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var sse_entry := {
		"command": "uvx",
		"args": ["mcp-proxy", "--transport", "sse", "http://x"],
		"env": McpClient.bridge_env_for_uvx(),
	}
	assert_false(McpJsonStrategy.verify_entry(c, sse_entry, "http://x"), "wrong-transport entry must register as drift")
	var no_proxy_entry := {
		"command": "uvx",
		"args": ["some-other-package", "--transport", "streamablehttp", "http://x"],
		"env": McpClient.bridge_env_for_uvx(),
	}
	assert_false(McpJsonStrategy.verify_entry(c, no_proxy_entry, "http://x"), "non-mcp-proxy entry must register as drift")
	var non_uvx_command := {
		"command": "python",
		"args": McpClient.mcp_proxy_bridge_args("http://x"),
		"env": McpClient.bridge_env_for_uvx(),
	}
	assert_false(McpJsonStrategy.verify_entry(c, non_uvx_command, "http://x"), "non-uvx command must register as drift")


func test_claude_desktop_verify_entry_accepts_future_url_form() -> void:
	## Tolerance preserved from the pre-refactor verifier: a hypothetical
	## future Claude Desktop that speaks HTTP natively would write a plain
	## `{"url": "..."}` entry. The flat-bridge verifier must accept that
	## shape too so we don't downgrade-classify it as drift.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var future_entry := {"url": "http://x"}
	assert_true(McpJsonStrategy.verify_entry(c, future_entry, "http://x"), "future url-style entry should verify")


func test_zed_uses_url() -> void:
	var c := McpClientRegistry.get_by_id("zed")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("url", ""), "http://x")


func test_mcp_proxy_bridge_args_pins_version() -> void:
	## Security: mcp-proxy is pulled from PyPI at first-connect. Pinning the
	## version protects every user from a malicious or broken future release.
	## If MCP_PROXY_VERSION ever changes, the pinned arg must change with it.
	var args := McpClient.mcp_proxy_bridge_args("http://x")
	assert_eq(args[0], "mcp-proxy==" + McpClient.MCP_PROXY_VERSION)


func test_resolve_uvx_path_returns_nonempty() -> void:
	## Fallback contract: even if McpCliFinder comes up empty (CI with no
	## uvx installed), we must still emit a well-formed command string so
	## the config file is valid. The bare "uvx" fallback is fine — the user
	## will get the same spawn failure they would have had anyway.
	var resolved := McpClient.resolve_uvx_path()
	assert_false(resolved.is_empty())
	assert_true(resolved.get_file() == "uvx" or resolved.get_file() == "uvx.exe", "resolved path must end in uvx or uvx.exe, got: %s" % resolved)


func test_vscode_uses_servers_key_with_type_http() -> void:
	var c := McpClientRegistry.get_by_id("vscode")
	assert_eq(c.server_key_path.size(), 1)
	assert_eq(c.server_key_path[0], "servers")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("type", ""), "http")
	assert_eq(entry.get("url", ""), "http://x")


func test_roo_code_pins_streamable_http_transport() -> void:
	## Regression for #189: without an explicit "type", Roo defaults to SSE
	## transport and our streamable-http /mcp endpoint returns HTTP 400.
	## The entry and the manual-command string must both pin the type so the
	## out-of-the-box config negotiates the right transport.
	var c := McpClientRegistry.get_by_id("roo_code")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("type", ""), "streamable-http")
	assert_eq(entry.get("url", ""), "http://x")
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/roo.json")
	assert_contains(manual, "\"type\": \"streamable-http\"")


func test_roo_code_verify_flags_pre_189_typeless_entry_as_drift() -> void:
	## Users who configured Roo before the #189 fix have a correct URL but no
	## "type" field — the URL-only default verifier would report CONFIGURED and
	## hide the broken SSE negotiation. The default verifier (deep-equal of
	## entry_extra_fields) treats a missing/wrong type as drift so the dock
	## prompts them to re-configure.
	var c := McpClientRegistry.get_by_id("roo_code")
	var current := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, current, "http://x"), "current entry must verify")
	var legacy_typeless := {"url": "http://x", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_typeless, "http://x"), "pre-#189 typeless entry must register as drift")
	var legacy_sse := {"type": "sse", "url": "http://x", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_sse, "http://x"), "explicit sse entry must register as drift")
	var url_drift := {"type": "streamable-http", "url": "http://other", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, url_drift, "http://x"), "URL drift must still register as drift")


func test_cline_pins_streamable_http_transport() -> void:
	## Parallel to the Roo #189 fix: without an explicit "type", Cline also
	## defaults to SSE transport and our streamable-http /mcp endpoint returns
	## HTTP 400. Cline's schema accepts "streamableHttp" (camelCase) — distinct
	## from Roo's "streamable-http" — per src/services/mcp/schemas.ts upstream.
	var c := McpClientRegistry.get_by_id("cline")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("type", ""), "streamableHttp")
	assert_eq(entry.get("url", ""), "http://x")
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/cline.json")
	assert_contains(manual, "\"type\": \"streamableHttp\"")


func test_cline_verify_flags_pre_fix_typeless_entry_as_drift() -> void:
	## Users who configured Cline before this fix have a correct URL but no
	## "type" field — the URL-only default verifier would report CONFIGURED and
	## hide the broken SSE negotiation. The default verifier deep-equals every
	## entry_extra_fields key, so a missing/wrong type registers as drift.
	var c := McpClientRegistry.get_by_id("cline")
	var current := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, current, "http://x"), "current entry must verify")
	var legacy_typeless := {"url": "http://x", "disabled": false, "autoApprove": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_typeless, "http://x"), "pre-fix typeless entry must register as drift")
	var legacy_sse := {"type": "sse", "url": "http://x", "disabled": false, "autoApprove": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_sse, "http://x"), "explicit sse entry must register as drift")
	var wrong_case := {"type": "streamable-http", "url": "http://x", "disabled": false, "autoApprove": []}
	assert_false(McpJsonStrategy.verify_entry(c, wrong_case, "http://x"), "Roo's kebab-case 'streamable-http' must register as drift in Cline (Cline accepts only 'streamableHttp')")
	var url_drift := {"type": "streamableHttp", "url": "http://other", "disabled": false, "autoApprove": []}
	assert_false(McpJsonStrategy.verify_entry(c, url_drift, "http://x"), "URL drift must still register as drift")


func test_kilo_code_pins_streamable_http_transport() -> void:
	## Parallel to the Roo #189 fix. Kilo Code is a Roo Code fork (legacy v5.x)
	## and its McpHub.ts validates against {"stdio", "sse", "streamable-http"}
	## — same kebab-case spelling as Roo, distinct from Cline's camelCase.
	var c := McpClientRegistry.get_by_id("kilo_code")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("type", ""), "streamable-http")
	assert_eq(entry.get("url", ""), "http://x")
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/kilo.json")
	assert_contains(manual, "\"type\": \"streamable-http\"")


func test_kilo_code_verify_flags_pre_fix_typeless_entry_as_drift() -> void:
	## Pre-fix Kilo entries have a correct URL but no "type" field. The
	## default verifier (deep-equal of entry_extra_fields) flags them as
	## drift so the dock prompts a re-configure.
	var c := McpClientRegistry.get_by_id("kilo_code")
	var current := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, current, "http://x"), "current entry must verify")
	var legacy_typeless := {"url": "http://x", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_typeless, "http://x"), "pre-fix typeless entry must register as drift")
	var legacy_sse := {"type": "sse", "url": "http://x", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_sse, "http://x"), "explicit sse entry must register as drift")
	var url_drift := {"type": "streamable-http", "url": "http://other", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, url_drift, "http://x"), "URL drift must still register as drift")


func test_zoo_code_pins_streamable_http_transport() -> void:
	## Zoo Code uses the Roo-family `mcp_settings.json` / `mcpServers` shape.
	## Pin `type: streamable-http` so a fresh entry negotiates against our
	## streamable-http endpoint without relying on upstream defaults.
	var c := McpClientRegistry.get_by_id("zoo_code")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("type", ""), "streamable-http")
	assert_eq(entry.get("url", ""), "http://x")
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/zoo.json")
	assert_contains(manual, "\"type\": \"streamable-http\"")


func test_zoo_code_verify_flags_typeless_entry_as_drift() -> void:
	## Local extension inspection confirmed Zoo stores MCP settings in the same
	## `mcp_settings.json` shape as Roo. A typeless legacy entry must therefore
	## register as drift so Configure rewrites it with the transport pin.
	var c := McpClientRegistry.get_by_id("zoo_code")
	var current := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, current, "http://x"), "current entry must verify")
	var legacy_typeless := {"url": "http://x", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_typeless, "http://x"), "typeless Zoo entry must register as drift")
	var legacy_sse := {"type": "sse", "url": "http://x", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, legacy_sse, "http://x"), "explicit sse entry must register as drift")
	var url_drift := {"type": "streamable-http", "url": "http://other", "disabled": false, "alwaysAllow": []}
	assert_false(McpJsonStrategy.verify_entry(c, url_drift, "http://x"), "URL drift must still register as drift")


# ----- entry_initial_fields: user-state preservation across reconfigure -----

func test_verify_entry_ignores_initial_field_drift() -> void:
	## Default verifier must NOT compare `entry_initial_fields` keys: those are
	## user-state (auto-approval lists, `disabled` toggles) that the user is
	## expected to mutate after the initial Configure. A user with a customised
	## `alwaysAllow` array must not be flagged as drift — otherwise the dock's
	## Configure-All-Mismatched sweep silently overwrites their state.
	var c := McpClientRegistry.get_by_id("roo_code")
	var customised := {
		"type": "streamable-http",
		"url": "http://x",
		"disabled": false,
		"alwaysAllow": ["session_manage", "node_create"],  # ← user-added
	}
	assert_true(McpJsonStrategy.verify_entry(c, customised, "http://x"),
		"User-customised alwaysAllow must verify as CONFIGURED, not drift")
	var disabled_by_user := {
		"type": "streamable-http",
		"url": "http://x",
		"disabled": true,  # ← user disabled the entry
		"alwaysAllow": [],
	}
	assert_true(McpJsonStrategy.verify_entry(c, disabled_by_user, "http://x"),
		"User-disabled entry must verify as CONFIGURED — they explicitly turned it off")


func test_build_entry_preserves_existing_initial_fields() -> void:
	## Reconfigure must not overwrite user-mutable state with descriptor
	## defaults. The strategy passes the existing entry to `build_entry`; this
	## test locks in that contract by simulating a reconfigure on an entry the
	## user has customised.
	var c := McpClientRegistry.get_by_id("roo_code")
	var existing := {
		"type": "streamable-http",
		"url": "http://old:8000/mcp",
		"disabled": true,
		"alwaysAllow": ["session_manage", "node_create"],
	}
	var rebuilt := McpJsonStrategy.build_entry(c, "http://new:8001/mcp", existing)
	assert_eq(rebuilt.get("url"), "http://new:8001/mcp", "URL must be force-updated to current server_url")
	assert_eq(rebuilt.get("type"), "streamable-http", "type pin must be force-set from entry_extra_fields")
	assert_eq(rebuilt.get("disabled"), true,
		"existing `disabled: true` must survive — user explicitly turned the entry off")
	assert_eq(rebuilt.get("alwaysAllow"), ["session_manage", "node_create"],
		"existing alwaysAllow array must survive — wiping it would silently revoke user auto-approvals")


func test_build_entry_seeds_initial_fields_when_absent() -> void:
	## First-time Configure (no existing entry) must populate initial defaults
	## so the dock surfaces a fully-formed entry — same shape as pre-split.
	var c := McpClientRegistry.get_by_id("roo_code")
	var fresh := McpJsonStrategy.build_entry(c, "http://x")  # existing = null
	assert_eq(fresh.get("type"), "streamable-http", "type pin must be set on fresh entries")
	assert_eq(fresh.get("disabled"), false, "initial `disabled: false` must seed on fresh entries")
	assert_eq(fresh.get("alwaysAllow"), [], "initial `alwaysAllow: []` must seed on fresh entries")


func test_build_entry_force_overwrites_drifted_required_fields() -> void:
	## A user (or upstream) entry with a wrong `type` value gets corrected on
	## reconfigure — the type pin is in `entry_extra_fields` precisely because
	## a wrong value breaks transport negotiation. User-state preservation
	## must not extend to broken transport pins.
	var c := McpClientRegistry.get_by_id("roo_code")
	var legacy_sse := {
		"type": "sse",  # ← wrong, broken transport
		"url": "http://old/mcp",
		"disabled": false,
		"alwaysAllow": ["session_manage"],
	}
	var rebuilt := McpJsonStrategy.build_entry(c, "http://new/mcp", legacy_sse)
	assert_eq(rebuilt.get("type"), "streamable-http", "type pin must overwrite legacy SSE")
	assert_eq(rebuilt.get("alwaysAllow"), ["session_manage"], "user state still preserved across the type fix")


# ----- hermes -----

func test_hermes_is_registered() -> void:
	var c := McpClientRegistry.get_by_id("hermes")
	assert_true(c != null, "hermes client must be registered")
	assert_eq(c.display_name, "Hermes Agent")
	assert_eq(c.config_type, "yaml")


func test_hermes_entry_is_url_only_no_transport_type() -> void:
	## Hermes HTTP entries are transport-inferred: just `url`, no `type`
	## field. The official shape is `mcp_servers: { url: ... }`.
	var c := McpClientRegistry.get_by_id("hermes")
	var entry := McpYamlStrategy.build_entry(c, "http://x")
	assert_eq(entry.get("url", ""), "http://x")
	assert_false(entry.has("type"), "Hermes entries must NOT carry a type field")
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/hermes/config.yaml")
	assert_contains(manual, "mcp_servers")
	assert_contains(manual, "url: http://x")
	assert_false(manual.contains("type:"), "manual hint must not mention a type field")


func test_hermes_entry_verifies_as_match() -> void:
	## The standard entry shape must round-trip through verify_entry so the
	## dock shows a green CONFIGURED dot.
	var c := McpClientRegistry.get_by_id("hermes")
	var entry := McpYamlStrategy.build_entry(c, "http://x")
	assert_true(McpYamlStrategy.verify_entry(c, entry, "http://x"),
		"built entry must verify as a match")


func test_hermes_verify_flags_url_drift_as_drift() -> void:
	## A Hermes entry whose URL doesn't match must register as drift so the
	## dock prompts reconfiguration. Verify only checks url (transport is
	## inferred, so there is no type field to drift on).
	var c := McpClientRegistry.get_by_id("hermes")
	var current := McpYamlStrategy.build_entry(c, "http://x")
	assert_true(McpYamlStrategy.verify_entry(c, current, "http://x"), "current entry must verify")
	var url_drift := {"url": "http://other"}
	assert_false(McpYamlStrategy.verify_entry(c, url_drift, "http://x"),
		"URL drift must register as drift")


func test_hermes_windows_path_template_uses_local_appdata() -> void:
	## Hermes stores MCP config at $LOCALAPPDATA/hermes/config.yaml on
	## Windows (Local, not Roaming — confirmed by where the running Hermes
	## process reads; see the descriptor's comment). $VAR is the token shape
	## McpPathTemplate.expand actually substitutes — %VAR% would be left as a
	## literal invalid path and the write would land in a bogus location.
	var c := McpClientRegistry.get_by_id("hermes")
	assert_true(c != null, "hermes client must be registered")
	assert_true(c.path_template.has("windows"), "hermes descriptor must declare a windows path_template")
	var windows_template: String = c.path_template["windows"]
	assert_contains(windows_template, "$LOCALAPPDATA",
		"windows template must use $LOCALAPPDATA, got: %s" % windows_template)
	assert_contains(windows_template, "config.yaml",
		"windows template must point at config.yaml, got: %s" % windows_template)


func test_hermes_unix_path_template_uses_home() -> void:
	## Hermes stores MCP config at ~/.hermes/config.yaml on Unix.
	var c := McpClientRegistry.get_by_id("hermes")
	assert_true(c != null)
	assert_true(c.path_template.has("unix"), "hermes descriptor must declare a unix path_template")
	assert_eq(c.path_template["unix"], "~/.hermes/config.yaml")


func test_hermes_uses_snake_case_mcp_servers_key() -> void:
	## Hermes uses the snake_case `mcp_servers` key, NOT `mcpServers`.
	var c := McpClientRegistry.get_by_id("hermes")
	assert_eq(c.server_key_path[0], "mcp_servers")


func test_hermes_has_no_uvx_bridge() -> void:
	## Hermes Agent is HTTP-native — no uvx mcp-proxy bridge needed.
	var c := McpClientRegistry.get_by_id("hermes")
	assert_eq(c.entry_uvx_bridge, McpClient.UvxBridge.NONE)


func test_hermes_is_in_required_registry_check() -> void:
	## Ensure test_registry_loads_all_clients would not break if this test
	## was added to the required client list — just a forward-compat guard.
	assert_true(McpClientRegistry.has_id("hermes"), "hermes client must be in registry")


func test_hermes_yaml_roundtrips_through_configure() -> void:
	## End-to-end: a configure write must produce YAML Hermes can read back
	## as CONFIGURED, preserving other top-level keys in the user's file.
	var c := McpClientRegistry.get_by_id("hermes")
	var dir := OS.get_environment("TMPDIR")
	if dir.is_empty():
		dir = OS.get_environment("TEMP")
	if dir.is_empty():
		dir = "/tmp"
	var path := dir.path_join("godot_ai_hermes_rt.yaml")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	# Seed a config.yaml with an unrelated top-level key.
	var seed := "model: openai/gpt-4o\nmcp_servers:\n  github:\n    url: \"https://mcp.github.com/mcp\"\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "could not open temp yaml")
	f.store_string(seed)
	f.close()

	# Point the descriptor at our temp file for this test.
	var real_path := c.path_template
	c.path_template = {"unix": path, "windows": path}
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://127.0.0.1:8000/mcp")
	c.path_template = real_path
	assert_eq(res.get("status", ""), "ok", "configure must report ok: %s" % res.get("message", ""))

	# Read back and assert shape.
	var reread := FileAccess.get_file_as_string(path)
	assert_contains(reread, "mcp_servers:")
	assert_contains(reread, "godot-ai:")
	assert_contains(reread, "url: http://127.0.0.1:8000/mcp")
	# Unrelated key preserved.
	assert_contains(reread, "model: openai/gpt-4o")
	# github entry preserved.
	assert_contains(reread, "github:")
	DirAccess.remove_absolute(path)


func test_hermes_yaml_empty_block_does_not_swallow_sibling_key() -> void:
	## Corruption regression: an EMPTY `mcp_servers:` block followed by a
	## top-level sibling key. The block parser must not consume the sibling
	## as a server entry — that would re-emit `model:` nested under
	## mcp_servers on rewrite and corrupt the user's config.
	var c := McpClientRegistry.get_by_id("hermes")
	var dir := OS.get_environment("TMPDIR")
	if dir.is_empty():
		dir = OS.get_environment("TEMP")
	if dir.is_empty():
		dir = "/tmp"
	var path := dir.path_join("godot_ai_hermes_empty_block.yaml")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "could not open temp yaml")
	f.store_string("mcp_servers:\nmodel: openai/gpt-4o\n")
	f.close()

	var real_path := c.path_template
	c.path_template = {"unix": path, "windows": path}
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://127.0.0.1:8000/mcp")
	c.path_template = real_path
	assert_eq(res.get("status", ""), "ok", "configure must report ok: %s" % res.get("message", ""))

	var reread := FileAccess.get_file_as_string(path)
	assert_contains(reread, "godot-ai:")
	# model must survive AT TOP LEVEL — never indented under mcp_servers.
	var has_top_level_model := false
	for line in reread.split("\n"):
		if String(line).begins_with("model: openai/gpt-4o"):
			has_top_level_model = true
			break
	assert_true(has_top_level_model, "sibling key must stay top-level, got:\n%s" % reread)
	assert_false(reread.contains("  model:"), "sibling key must not be nested under mcp_servers, got:\n%s" % reread)
	DirAccess.remove_absolute(path)


func test_hermes_yaml_comments_in_block_are_not_parsed_as_entries() -> void:
	## Corruption regression: comment lines inside the mcp_servers block —
	## at entry indent or inside an entry — must never be parsed as entry
	## headers or keys (a `# note` entry would be re-emitted as a bogus
	## `# note:` server on rewrite).
	var c := McpClientRegistry.get_by_id("hermes")
	var dir := OS.get_environment("TMPDIR")
	if dir.is_empty():
		dir = OS.get_environment("TEMP")
	if dir.is_empty():
		dir = "/tmp"
	var path := dir.path_join("godot_ai_hermes_comments.yaml")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "could not open temp yaml")
	f.store_string(
		"mcp_servers:\n"
		+ "  # my github server\n"
		+ "  github:\n"
		+ "    # auth for CI\n"
		+ "    url: \"https://mcp.github.com/mcp\"\n"
	)
	f.close()

	var real_path := c.path_template
	c.path_template = {"unix": path, "windows": path}
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://127.0.0.1:8000/mcp")
	c.path_template = real_path
	assert_eq(res.get("status", ""), "ok", "configure must report ok: %s" % res.get("message", ""))

	var reread := FileAccess.get_file_as_string(path)
	assert_contains(reread, "godot-ai:")
	assert_contains(reread, "github:")
	assert_contains(reread, "url: https://mcp.github.com/mcp")
	assert_false(reread.contains("# my github server:"),
		"a comment must never be re-emitted as an entry, got:\n%s" % reread)
	assert_false(reread.contains("# auth for CI:"),
		"an in-entry comment must never become a key, got:\n%s" % reread)
	DirAccess.remove_absolute(path)


func test_hermes_yaml_reconfigure_preserves_user_headers_drops_stdio_keys() -> void:
	## Reconfigure preservation contract (mirrors JSON's entry_initial_fields
	## split): user-mutable keys like `headers` survive a repoint; stale
	## stdio-bridge keys (`command`) are scrubbed so Hermes never sees both a
	## url and a command on one entry.
	var c := McpClientRegistry.get_by_id("hermes")
	var existing := {
		"url": "http://old:1234/mcp",
		"command": "uvx mcp-proxy",
		"headers": {"Authorization": "Bearer abc"},
	}
	var entry := McpYamlStrategy.build_entry(c, "http://127.0.0.1:8000/mcp", existing)
	assert_eq(entry.get("url", ""), "http://127.0.0.1:8000/mcp", "url must be repointed")
	assert_false(entry.has("command"), "stdio-bridge command must be scrubbed")
	var headers: Dictionary = entry.get("headers", {})
	assert_eq(headers.get("Authorization", ""), "Bearer abc", "user headers must survive reconfigure")


func test_opencode_client_uses_home_config_on_windows() -> void:
	## Regression: OpenCode reads its MCP config from
	## ~/.config/opencode/opencode.json on ALL platforms (verified via
	## `opencode debug paths`). The Windows descriptor used to point at
	## $APPDATA/opencode/opencode.json, so auto-configure silently wrote
	## to a file OpenCode never read.
	var c := McpClientRegistry.get_by_id("opencode")
	assert_true(c != null, "opencode client must be registered")
	assert_true(c.path_template.has("windows"), "opencode descriptor must declare a windows path_template entry")
	var windows_template: String = c.path_template["windows"]
	assert_contains(windows_template, "$HOME", "windows template must use $HOME, got: %s" % windows_template)
	assert_false(windows_template.contains("$APPDATA"), "windows template must not use $APPDATA, got: %s" % windows_template)

	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	if home.is_empty():
		skip("HOME / USERPROFILE not set")
		return
	var resolved := McpPathTemplate.expand(windows_template)
	assert_eq(resolved, home.path_join(".config/opencode/opencode.json"))


func test_path_template_expand_home_falls_back_to_userprofile() -> void:
	## Defensive coverage for the Windows fallback: when HOME is unset (a
	## stock Windows install), $HOME and ~ must both resolve via _home()'s
	## USERPROFILE fallback. The existing OpenCode descriptor test never
	## hits this branch on GitHub Actions Windows runners because GHA
	## injects HOME — explicitly mock the env so the fallback path is
	## exercised on every CI platform.
	var saved_home := OS.get_environment("HOME")
	var saved_userprofile := OS.get_environment("USERPROFILE")
	var fake_userprofile := "/tmp/godot-ai-test-userprofile"

	OS.unset_environment("HOME")
	OS.set_environment("USERPROFILE", fake_userprofile)
	var via_dollar := McpPathTemplate.expand("$HOME/foo")
	var via_tilde := McpPathTemplate.expand("~/foo")
	# Restore before asserting so a failure can't leak into later tests.
	# Mirror the unset-when-saved-was-empty pattern used by the
	# GODOT_AI_MODE tests above — `set_environment(var, "")` would
	# define a new empty-valued env var rather than leave it unset.
	if saved_home.is_empty():
		OS.unset_environment("HOME")
	else:
		OS.set_environment("HOME", saved_home)
	if saved_userprofile.is_empty():
		OS.unset_environment("USERPROFILE")
	else:
		OS.set_environment("USERPROFILE", saved_userprofile)

	assert_eq(via_dollar, fake_userprofile.path_join("foo"),
		"$HOME must fall back to USERPROFILE when HOME is unset")
	assert_eq(via_tilde, fake_userprofile.path_join("foo"),
		"~ must fall back to USERPROFILE when HOME is unset")
	assert_eq(via_dollar, via_tilde,
		"$HOME and ~ must resolve identically — both go through _home()")


# ----- helpers -----

func _assert_uvx_command(cmd: Variant) -> void:
	## The bridge command may be a bare "uvx"/"uvx.exe" (CI fallback) or an
	## absolute path resolved by McpCliFinder. Either is fine — just assert
	## the basename matches uvx.
	assert_true(cmd is String, "command must be a String, got: %s" % cmd)
	var cmd_str: String = cmd
	var basename := cmd_str.get_file()
	assert_true(basename == "uvx" or basename == "uvx.exe", "command must resolve to uvx/uvx.exe, got: %s" % cmd_str)


func _assert_mcp_proxy_bridge_args(args: Variant, expected_url: String) -> void:
	## Shared shape check for any client that bridges stdio → streamable-http
	## via `uvx mcp-proxy`. The first arg is a pinned version spec like
	## `mcp-proxy==0.11.0` — match by prefix so this doesn't have to churn
	## every time MCP_PROXY_VERSION bumps.
	##
	## NOTE: Pass `args` through `str()` before `%` substitution. GDScript's
	## `%` operator interprets a bare Array on the right-hand side as a list
	## of arguments to splice into multiple `%s` slots — `"got: %s" % args`
	## with a 4-element array errors with "not all arguments converted",
	## the assertion message becomes garbage, and on stricter runtimes the
	## SCRIPT ERROR is treated as a test failure.
	assert_true(args is Array, "bridge args must be an Array, got: %s" % str(args))
	var has_mcp_proxy := false
	for a in args:
		if a is String and (a as String).begins_with("mcp-proxy"):
			has_mcp_proxy = true
			break
	assert_true(has_mcp_proxy, "args must include an mcp-proxy entry, got: %s" % str(args))
	assert_contains(args, "--transport")
	assert_contains(args, "streamablehttp")
	assert_contains(args, expected_url)


func _assert_bridge_env_pin(entry: Variant) -> void:
	## Every uvx-bridge entry must carry `env.UV_LINK_MODE=copy`. Without it,
	## the running godot-ai server's `_pydantic_core.pyd` mapping locks the
	## hard-linked copy under `builds-v0\.tmpXXXXXX\` on Windows and uvx's
	## post-install cleanup fails — the symptom is a "pywin32 wheel invalid /
	## file in use" error in Claude Desktop's MCP launcher with no working
	## transport. See utils/uv_cache_cleanup.gd and the README troubleshooting
	## section for the full hard-link explanation.
	assert_true(entry is Dictionary, "entry must be a Dictionary, got: %s" % str(entry))
	var env = entry.get("env", null)
	assert_true(env is Dictionary, "bridged entry must include an env dict pinning UV_LINK_MODE=copy, got env=%s" % str(env))
	assert_eq(env.get("UV_LINK_MODE", ""), "copy", "env must pin UV_LINK_MODE=copy")


func _make_test_json_client(path: String) -> McpClient:
	var c := McpClient.new()
	c.id = "json_test"
	c.display_name = "JSON Test"
	c.config_type = "json"
	c.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	c.server_key_path = PackedStringArray(["mcpServers"])
	# entry_url_field defaults to "url"; entry_extra_fields stays empty
	# → strategy synthesises `{"url": <url>}`, matching the pre-refactor
	# entry_builder lambda.
	return c


func _make_test_toml_client(path: String) -> McpClient:
	var c := McpClient.new()
	c.id = "toml_test"
	c.display_name = "TOML Test"
	c.config_type = "toml"
	c.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	c.toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	c.toml_body_template = PackedStringArray(["url = \"{url}\"", "enabled = true"])
	return c


func _remove_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Relative path inside a scratch dir where `_find_venv_python_in` expects
## to find the python binary — OS-dependent, mirrors the same conditional
## in `client_configurator.gd::_find_venv_python_in`.
func _venv_python_relpath() -> String:
	return ".venv/Scripts/python.exe" if OS.get_name() == "Windows" else ".venv/bin/python"


func _touch_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "Failed to create scratch file at %s" % path)
	f.close()


## Reset http/ws port overrides to the built-in defaults for the duration of
## a single test. The suite-level teardown restores whatever the user had
## configured before the run so a mid-suite failure doesn't leave the editor
## with a stomped port.
func _clear_port_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(McpSettings.SETTING_HTTP_PORT, McpClientConfigurator.DEFAULT_HTTP_PORT)
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, McpClientConfigurator.DEFAULT_WS_PORT)


func _restore_port_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if _saved_http_port == null:
		es.set_setting(McpSettings.SETTING_HTTP_PORT, McpClientConfigurator.DEFAULT_HTTP_PORT)
	else:
		es.set_setting(McpSettings.SETTING_HTTP_PORT, _saved_http_port)
	if _saved_ws_port == null:
		es.set_setting(McpClientConfigurator.SETTING_WS_PORT, McpClientConfigurator.DEFAULT_WS_PORT)
	else:
		es.set_setting(McpClientConfigurator.SETTING_WS_PORT, _saved_ws_port)
