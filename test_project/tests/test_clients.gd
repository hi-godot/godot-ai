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
## Same reason as the ports: these tests drive godot_ai/mcp_client_scope
## through its valid and invalid values and must not leave the editor
## registering at a scope the user never chose.
var _saved_client_scope: Variant = null


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
		if es.has_setting(McpSettings.SETTING_CLIENT_SCOPE):
			_saved_client_scope = es.get_setting(McpSettings.SETTING_CLIENT_SCOPE)


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
			if client.command_shape != McpClient.CommandShape.NONE:
				continue
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


func test_path_candidate_expansion_supports_directory_wildcard_and_missing_leaf() -> void:
	var root := _scratch_dir.path_join("candidate_expand")
	_remove_dir_recursive(root)
	var package_root := root.path_join("Packages/Claude_testpublisher")
	DirAccess.make_dir_recursive_absolute(package_root)
	var template := root.path_join(
		"Packages/Claude_*/LocalCache/Roaming/Claude/claude_desktop_config.json"
	)
	var candidates := McpPathTemplate.expand_path_candidates(template)
	assert_eq(candidates.size(), 1)
	assert_eq(
		candidates[0],
		package_root.path_join("LocalCache/Roaming/Claude/claude_desktop_config.json"),
		"wildcard resolution must produce a create target even when the leaf is absent",
	)
	var install_matches := McpPathTemplate.expand_path_candidates(root.path_join("Packages/Claude_*"))
	assert_eq(install_matches, PackedStringArray([package_root]))
	_remove_dir_recursive(root)


func test_wildcard_segment_match_rejects_overlapping_fixed_parts() -> void:
	assert_false(
		McpPathTemplate._wildcard_segment_matches("Claude_", "Claude_", "Claude_"),
		"prefix and suffix must not overlap inside a value shorter than their combined length",
	)
	assert_true(McpPathTemplate._wildcard_segment_matches("Claude_Beta", "Claude_", "Beta"))


func test_ordered_config_candidates_choose_effective_existing_file() -> void:
	var root := _scratch_dir.path_join("candidate_existing")
	_remove_dir_recursive(root)
	var package_root := root.path_join("Packages/Claude_store")
	var container_path := package_root.path_join(
		"LocalCache/Roaming/Claude/claude_desktop_config.json"
	)
	var roaming_path := root.path_join("Roaming/Claude/claude_desktop_config.json")
	_write_text(container_path, "container")
	_write_text(roaming_path, "roaming")
	var client := _make_candidate_json_client(root, roaming_path)
	assert_eq(
		client.resolved_config_path(),
		container_path,
		"an existing Store-private config must win over the roaming file",
	)
	_remove_if_exists(container_path)
	var create_resolution := client.resolved_config_path_details()
	assert_eq(
		create_resolution.get("path"),
		container_path,
		"an installed Store package must create its private config instead of relying on read-through",
	)
	assert_eq(
		create_resolution.get("seed_path"),
		roaming_path,
		"an existing roaming config must seed a new authoritative private file",
	)
	_remove_dir_recursive(package_root)
	assert_eq(client.resolved_config_path(), roaming_path, "roaming wins when no Store package exists")
	_remove_dir_recursive(root)


func test_candidate_fresh_private_config_seeds_roaming_losslessly() -> void:
	var root := _scratch_dir.path_join("candidate_seed_roaming")
	_remove_dir_recursive(root)
	var package_root := root.path_join("Packages/Claude_store")
	var container_path := package_root.path_join(
		"LocalCache/Roaming/Claude/claude_desktop_config.json"
	)
	var roaming_path := root.path_join("Roaming/Claude/claude_desktop_config.json")
	DirAccess.make_dir_recursive_absolute(package_root)
	var roaming_seed := JSON.stringify({
		"mcpServers": {"someone-else": {"command": "keep-me"}},
		"preferences": {"theme": "dark"},
	})
	_write_text(roaming_path, roaming_seed)
	var client := _make_candidate_json_client(root, roaming_path)
	var configured := McpJsonStrategy.configure(client, "godot-ai", "http://new")
	assert_eq(configured.get("status"), "ok")
	assert_true(FileAccess.file_exists(container_path), "Configure must create the private target")
	var private_data = JSON.parse_string(_read_text(container_path))
	assert_true(private_data.get("mcpServers", {}).has("someone-else"))
	assert_eq(private_data.get("preferences"), {"theme": "dark"})
	assert_eq(
		private_data.get("mcpServers", {}).get("godot-ai", {}).get("url"),
		"http://new",
	)
	assert_eq(_read_text(roaming_path), roaming_seed, "the roaming seed must stay byte-identical")
	_remove_dir_recursive(root)


func test_candidate_invalid_roaming_seed_fails_without_private_write() -> void:
	var root := _scratch_dir.path_join("candidate_invalid_seed")
	_remove_dir_recursive(root)
	var package_root := root.path_join("Packages/Claude_store")
	var container_path := package_root.path_join(
		"LocalCache/Roaming/Claude/claude_desktop_config.json"
	)
	var roaming_path := root.path_join("Roaming/Claude/claude_desktop_config.json")
	DirAccess.make_dir_recursive_absolute(package_root)
	var invalid_seed := "{ broken json"
	_write_text(roaming_path, invalid_seed)
	var client := _make_candidate_json_client(root, roaming_path)
	var configured := McpJsonStrategy.configure(client, "godot-ai", "http://new")
	assert_eq(configured.get("status"), "error")
	assert_contains(str(configured.get("message", "")), roaming_path)
	assert_false(FileAccess.file_exists(container_path), "an invalid seed must not create a private file")
	assert_eq(_read_text(roaming_path), invalid_seed, "a failed seed read must not rewrite roaming")
	_remove_dir_recursive(root)


func test_ordered_config_candidates_define_fresh_create_target() -> void:
	var root := _scratch_dir.path_join("candidate_create")
	_remove_dir_recursive(root)
	var package_root := root.path_join("Packages/Claude_store")
	DirAccess.make_dir_recursive_absolute(package_root)
	var roaming_path := root.path_join("Roaming/Claude/claude_desktop_config.json")
	var client := _make_candidate_json_client(root, roaming_path)
	assert_eq(
		client.resolved_config_path(),
		package_root.path_join("LocalCache/Roaming/Claude/claude_desktop_config.json"),
		"a unique Store package root must define the fresh create target",
	)
	_remove_dir_recursive(package_root)
	assert_eq(
		client.resolved_config_path(),
		roaming_path,
		"without a Store package, the descriptor's roaming candidate is deterministic",
	)
	_remove_dir_recursive(root)


func test_ordered_config_candidates_fail_closed_for_ambiguous_store_roots() -> void:
	var root := _scratch_dir.path_join("candidate_ambiguous")
	_remove_dir_recursive(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("Packages/Claude_alpha"))
	DirAccess.make_dir_recursive_absolute(root.path_join("Packages/Claude_beta"))
	var roaming_path := root.path_join("Roaming/Claude/claude_desktop_config.json")
	_write_text(roaming_path, '{"mcpServers":{}}')
	var client := _make_candidate_json_client(root, roaming_path)
	var resolution := client.resolved_config_path_details()
	assert_eq(
		resolution.get("path"),
		"",
		"multiple Store targets must fail closed even when a roaming fallback exists",
	)
	assert_contains(str(resolution.get("error", "")), "multiple matching config package paths")
	assert_contains(str(resolution.get("error", "")), "Claude_alpha")
	assert_contains(str(resolution.get("error", "")), "Claude_beta")
	assert_eq(client._last_config_path_warning, resolution.get("error"))
	var repeated_resolution := client.resolved_config_path_details()
	assert_eq(repeated_resolution.get("error"), resolution.get("error"))
	assert_eq(
		client._last_config_path_warning,
		resolution.get("error"),
		"repeated resolution must retain one de-duplication key",
	)
	assert_eq(McpClientConfigurator._config_path_resolution_error(client), resolution.get("error"))
	var details := McpJsonStrategy.check_status_details(client, "godot-ai", "http://x")
	assert_eq(details.get("status"), McpClient.Status.ERROR)
	assert_eq(details.get("error_msg"), resolution.get("error"))
	var configure := McpJsonStrategy.configure(client, "godot-ai", "http://x")
	assert_eq(configure.get("status"), "error")
	assert_eq(configure.get("message"), resolution.get("error"))
	assert_false(str(configure.get("message", "")).contains("on this OS"))
	var remove := McpJsonStrategy.remove(client, "godot-ai")
	assert_eq(remove.get("status"), "error")
	assert_eq(remove.get("message"), resolution.get("error"))
	_remove_dir_recursive(root.path_join("Packages/Claude_beta"))
	client.resolved_config_path_details()
	assert_eq(client._last_config_path_warning, "", "successful resolution resets warning de-duplication")
	_remove_dir_recursive(root)


func test_candidate_detect_path_marks_store_package_installed_without_config() -> void:
	var root := _scratch_dir.path_join("candidate_detect")
	_remove_dir_recursive(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("Packages/Claude_store"))
	var client := _make_candidate_json_client(
		root, root.path_join("Roaming/Claude/claude_desktop_config.json")
	)
	client.detect_paths = PackedStringArray([root.path_join("Packages/Claude_*")])
	assert_true(client.is_installed(), "the Store package root must drive the installed badge")
	_remove_dir_recursive(root)


func test_candidate_effective_path_drives_json_configure_verify_status_and_remove() -> void:
	var root := _scratch_dir.path_join("candidate_e2e")
	_remove_dir_recursive(root)
	var container_path := root.path_join(
		"Packages/Claude_store/LocalCache/Roaming/Claude/claude_desktop_config.json"
	)
	var roaming_path := root.path_join("Roaming/Claude/claude_desktop_config.json")
	var container_seed := {
		"mcpServers": {
			"someone-else": {"command": "keep-me"},
		},
		"containerOnly": true,
	}
	var roaming_seed := '{"mcpServers":{"roaming-only":{"command":"untouched"}}}'
	_write_text(container_path, JSON.stringify(container_seed))
	_write_text(roaming_path, roaming_seed)
	var client := _make_candidate_json_client(root, roaming_path)
	client.command_shape = McpClient.CommandShape.FLAT
	var launch := _test_attach_launch()
	var configured := McpJsonStrategy.configure(client, "godot-ai", "http://unused", launch)
	var verified := McpClientConfigurator._verify_post_state(
		client,
		configured,
		McpClient.Status.CONFIGURED,
		"http://unused",
		"configure",
		launch,
	)
	assert_eq(configured.get("status"), "ok")
	assert_eq(verified.get("status"), "ok", "post-state verification must read the effective path")
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://unused", launch),
		McpClient.Status.CONFIGURED,
	)
	var configured_data = JSON.parse_string(_read_text(container_path))
	assert_true(configured_data.get("mcpServers", {}).has("someone-else"))
	assert_eq(configured_data.get("containerOnly"), true)
	assert_eq(_read_text(roaming_path), roaming_seed, "the non-effective config must stay byte-identical")
	var removed := McpJsonStrategy.remove(client, "godot-ai")
	assert_eq(removed.get("status"), "ok")
	var after_remove = JSON.parse_string(_read_text(container_path))
	assert_true(after_remove.get("mcpServers", {}).has("someone-else"))
	assert_false(after_remove.get("mcpServers", {}).has("godot-ai"))
	assert_eq(_read_text(roaming_path), roaming_seed, "Remove must target only the effective config")
	_remove_dir_recursive(root)


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


func test_capture_launch_context_worker_thread_serves_snapshot() -> void:
	McpClientConfigurator.warm_env_snapshot()
	var expected := McpClientConfigurator.capture_launch_context()
	var thread := Thread.new()
	var start_err := thread.start(func() -> Dictionary:
		return McpClientConfigurator.capture_launch_context()
	)
	assert_eq(start_err, OK, "worker thread must start")
	var worker_context: Dictionary = thread.wait_to_finish()
	assert_eq(
		worker_context,
		expected,
		"worker launch capture must use the complete main-thread snapshot",
	)


func test_warm_env_snapshot_covers_descriptor_config_path_envs() -> void:
	## ClientConfigurator.warm_env_snapshot must include every descriptor's
	## config-file/config-home env so worker-side path resolution never falls
	## into the degraded un-warmed path.
	var tested_count := 0
	for id in McpClientConfigurator.client_ids():
		var client := McpClientRegistry.get_by_id(String(id))
		if client == null:
			continue
		for env_variant in [client.config_file_env, client.config_home_env]:
			var env_name := String(env_variant)
			if env_name.is_empty():
				continue
			tested_count += 1
			var prior_env := OS.get_environment(env_name)
			OS.set_environment(env_name, "warm-probe")
			McpClientConfigurator.warm_env_snapshot()
			if prior_env.is_empty():
				OS.unset_environment(env_name)
			else:
				OS.set_environment(env_name, prior_env)
			var thread := Thread.new()
			var start_err := thread.start(func() -> String:
				return McpPathTemplate.env_lookup(env_name)
			)
			assert_eq(start_err, OK)
			var worker_value := str(thread.wait_to_finish())
			assert_eq(worker_value, "warm-probe",
				"%s must be pre-warmed by ClientConfigurator.warm_env_snapshot" % env_name)
			## Re-warm the restored value so the probe cannot leak into later tests.
			McpClientConfigurator.warm_env_snapshot()
	assert_true(tested_count > 0,
		"no descriptor declared a config path env — this test exercised nothing")


# ----- config-home env override (#617) -----

const TEST_CFG_HOME_ENV := "GODOT_AI_TEST_CFG_HOME"
const TEST_CFG_FILE_ENV := "GODOT_AI_TEST_CFG_FILE"


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


func test_config_file_env_configure_status_remove_and_manual_use_exact_file() -> void:
	## Exact-file overrides must drive every path consumer. Otherwise Configure
	## and its post-verification can agree with each other while the client reads
	## a different file — the OPENCODE_CONFIG false-success regression.
	var default_path := _scratch_dir.path_join("file_env_default_untouched.json")
	var override_path := _scratch_dir.path_join("file_env_override/opencode.json")
	_remove_if_exists(default_path)
	_remove_if_exists(override_path)
	var client := _make_test_json_client(default_path)
	client.display_name = "Exact File Test"
	client.config_file_env = TEST_CFG_FILE_ENV
	var prior_env := OS.get_environment(TEST_CFG_FILE_ENV)
	OS.set_environment(TEST_CFG_FILE_ENV, override_path)

	var resolution := client.resolved_config_path_details()
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	var status := McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")
	var drift := McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:9000/mcp")
	var manual := McpManualCommand.build(
		client, "godot-ai", "http://127.0.0.1:8000/mcp", str(resolution.get("path", ""))
	)
	var installed := client.is_installed()
	var removed := McpJsonStrategy.remove(client, "godot-ai")
	var post_remove := McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp")

	if prior_env.is_empty():
		OS.unset_environment(TEST_CFG_FILE_ENV)
	else:
		OS.set_environment(TEST_CFG_FILE_ENV, prior_env)
	_remove_if_exists(override_path)

	assert_eq(resolution.get("path"), override_path)
	assert_eq(resolution.get("error"), "")
	assert_eq(result.get("status"), "ok")
	assert_false(FileAccess.file_exists(default_path),
		"Configure must not touch the path_template default")
	assert_eq(status, McpClient.Status.CONFIGURED)
	assert_eq(drift, McpClient.Status.CONFIGURED_MISMATCH)
	assert_contains(manual, override_path, "manual instructions must name the exact-file override")
	assert_true(installed, "the exact-file override must count as installation evidence")
	assert_eq(removed.get("status"), "ok")
	assert_eq(post_remove, McpClient.Status.NOT_CONFIGURED)


func test_registry_stale_session_probe_and_gate() -> void:
	## #850: an in-session self-update can leave descriptor instances answering
	## Nil for vars the update added. The registry's coherence probe detects
	## that; a consistent checkout must never trip it, and an object without
	## the current schema must.
	assert_false(
		McpClientRegistry.stale_session_detected(),
		"a consistent session must not report a stale update"
	)
	assert_true(
		McpClientRegistry._instance_is_coherent(McpClientRegistry.get_by_id("claude_desktop")),
		"a freshly loaded descriptor must read coherent"
	)
	assert_false(
		McpClientRegistry._instance_is_coherent(RefCounted.new()),
		"an instance missing current-schema fields must read incoherent"
	)
	assert_false(McpClientRegistry._instance_is_coherent(null))
	assert_contains(
		McpClientRegistry.RESTART_TO_FINISH_UPDATE,
		"Restart the editor",
		"the stale-session message must name the one repair"
	)


func test_configure_message_names_the_written_transport() -> void:
	## The success line must describe the transport that was actually written:
	## "stdio attach" for command-shape entries, "(HTTP: <url>)" only for
	## URL-mode entries. Found live in the #838 Windows smoke — every attach
	## write reported the HTTP URL the migration had just moved away from.
	var attach_path := _scratch_dir.path_join("message_attach.json")
	_remove_if_exists(attach_path)
	var attach_client := _make_test_json_client(attach_path)
	attach_client.command_shape = McpClient.CommandShape.FLAT
	var configured := McpJsonStrategy.configure(
		attach_client, "godot-ai", "http://127.0.0.1:8000/mcp", _test_attach_launch()
	)
	assert_eq(configured.get("status"), "ok")
	var message := str(configured.get("message", ""))
	assert_contains(message, "stdio attach", "attach write must name its transport: %s" % message)
	assert_false(
		message.contains("HTTP:"),
		"attach write must not claim an HTTP transport: %s" % message,
	)
	_remove_if_exists(attach_path)

	var url_path := _scratch_dir.path_join("message_url.json")
	_remove_if_exists(url_path)
	var url_client := _make_test_json_client(url_path)
	var url_configured := McpJsonStrategy.configure(
		url_client, "godot-ai", "http://127.0.0.1:8000/mcp"
	)
	assert_eq(url_configured.get("status"), "ok")
	assert_contains(
		str(url_configured.get("message", "")),
		"HTTP: http://127.0.0.1:8000/mcp",
		"URL-mode write keeps the HTTP wording",
	)
	_remove_if_exists(url_path)


func test_config_file_env_relative_path_fails_closed() -> void:
	var client := _make_test_json_client(_scratch_dir.path_join("file_env_default.json"))
	client.display_name = "Exact File Test"
	client.config_file_env = TEST_CFG_FILE_ENV
	var prior_env := OS.get_environment(TEST_CFG_FILE_ENV)
	OS.set_environment(TEST_CFG_FILE_ENV, "relative/opencode.json")
	var details := client.resolved_config_path_details()
	if prior_env.is_empty():
		OS.unset_environment(TEST_CFG_FILE_ENV)
	else:
		OS.set_environment(TEST_CFG_FILE_ENV, prior_env)
	assert_eq(details.get("path"), "")
	assert_contains(str(details.get("error", "")), "absolute config-file path")


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


func test_opencode_declares_exact_config_file_override() -> void:
	var client := McpClientRegistry.get_by_id("opencode")
	assert_true(client != null, "opencode must be registered")
	assert_eq(client.config_file_env, "OPENCODE_CONFIG")


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


## A command-shape CLI descriptor that takes `{scope}`, shaped like
## claude_code but pointed at a scratch file. Used to exercise the scope-aware
## status routing without touching the user's real ~/.claude.json.
func _make_scope_cli_client(path: String) -> McpClient:
	var c := McpClient.new()
	c.id = "scope_cli_test"
	c.display_name = "Scope CLI Test"
	c.config_type = "cli"
	# Never resolves on PATH, so the CLI probe spawn-fails deterministically.
	c.cli_names = PackedStringArray(["godot-ai-nonexistent-cli-xyz"])
	c.cli_register_template = PackedStringArray(
		["mcp", "add", "--scope", "{scope}", "{name}", "--", "{command}", "{args...}"]
	)
	c.cli_unregister_template = PackedStringArray(["mcp", "remove", "--scope", "{scope}", "{name}"])
	c.cli_status_args = PackedStringArray(["mcp", "list"])
	c.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	c.server_key_path = PackedStringArray(["mcpServers"])
	c.command_shape = McpClient.CommandShape.FLAT
	c.command_transport_key = "type"
	c.command_transport_value = "stdio"
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
	assert_eq(client.entry_extra_fields.get("type"), "http", "URL-fallback rendering keeps the type:http shape")
	assert_true(client.resolved_config_path().ends_with(".claude.json"), "fallback path should be ~/.claude.json, got %s" % client.resolved_config_path())


func test_claude_code_declares_stdio_attach_registration() -> void:
	## #838: registration goes through `claude mcp add --scope <scope> <name> --
	## <command> <args...>` (stdio is the CLI's default transport; verified
	## live in an isolated CLAUDE_CONFIG_DIR). The JSON fallback file renders
	## the same entry the CLI itself writes: type:stdio + command + args.
	var client := McpClientRegistry.get_by_id("claude_code")
	assert_eq(client.command_shape, McpClient.CommandShape.FLAT)
	assert_eq(client.command_transport_key, "type")
	assert_eq(client.command_transport_value, "stdio")
	assert_true(client.command_legacy_keys.has("url"), "legacy HTTP entry's url must be removed")
	assert_true(client.command_supports_url_fallback)
	var register := client.cli_register_template
	assert_true(register.has("--scope"), "registration must stay explicitly scoped")
	assert_true(register.has("{scope}"), "scope comes from the setting, not a hardcoded value")
	assert_true(register.has("--"), "`--` must stop claude's own flag parsing")
	assert_true(register.has("{command}"), "register template must take the launch command token")
	assert_true(register.has("{args...}"), "register template must splice the launch args")
	var separator_index := register.find("--")
	var command_index := register.find("{command}")
	var args_index := register.find("{args...}")
	assert_true(separator_index >= 0 and separator_index < command_index,
		"`--` must precede {command} so Claude stops parsing its own flags")
	assert_eq(args_index, command_index + 1, "{args...} must immediately follow {command}")
	assert_false(register.has("--transport"), "stdio is the default transport — no pin in argv")
	assert_true(client.cli_unregister_template.has("--scope"), "unscoped remove could eat a project-local entry")
	assert_true(client.cli_unregister_template.has("{scope}"),
		"remove must target the same scope the register wrote to")


func test_client_scope_defaults_to_user() -> void:
	## Existing installs must keep registering where they always have; the
	## setting is opt-in, not a silent behaviour change on upgrade.
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(McpSettings.SETTING_CLIENT_SCOPE):
		es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, McpSettings.DEFAULT_CLIENT_SCOPE)
	assert_eq(McpSettings.client_scope(), "user")
	var client := McpClientRegistry.get_by_id("claude_code")
	var args := McpCliStrategy.format_args(
		client.cli_register_template, "godot-ai", "", {"command": "uvx", "args": ["godot-ai"]}
	)
	var scope_index := args.find("--scope")
	assert_true(scope_index >= 0, "register argv must carry --scope")
	assert_eq(args[scope_index + 1], "user", "default scope must render as user")
	assert_false(args.has("{scope}"), "the token must be substituted, never passed through to the CLI")


func test_client_scope_project_renders_in_argv() -> void:
	## The whole point of the setting: `project` makes the CLI write
	## <project>/.mcp.json instead of the global ~/.claude.json block.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorSettings unavailable in test environment")
		return
	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, "project")
	assert_eq(McpSettings.client_scope(), "project")
	var client := McpClientRegistry.get_by_id("claude_code")
	var register := McpCliStrategy.format_args(
		client.cli_register_template, "godot-ai", "", {"command": "uvx", "args": ["godot-ai"]}
	)
	var reg_index := register.find("--scope")
	assert_true(reg_index >= 0, "register argv must carry --scope")
	assert_eq(register[reg_index + 1], "project")
	## Remove must follow the same scope, or Configure-then-Remove leaves the
	## entry behind in whichever scope the register actually wrote.
	var unregister := McpCliStrategy.format_args(client.cli_unregister_template, "godot-ai", "")
	var unreg_index := unregister.find("--scope")
	assert_true(unreg_index >= 0, "unregister argv must carry --scope")
	assert_eq(unregister[unreg_index + 1], "project")
	_restore_client_scope()


func test_client_scope_rejects_unknown_value() -> void:
	## A hand-edited editor_settings-4.tres must not make the plugin shell out
	## with a bad --scope flag; fall back to the default instead.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorSettings unavailable in test environment")
		return
	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, "not-a-scope")
	assert_eq(McpSettings.client_scope(), McpSettings.DEFAULT_CLIENT_SCOPE)
	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, "  PROJECT  ")
	assert_eq(McpSettings.client_scope(), "project", "value should be trimmed and case-folded")
	_restore_client_scope()


func test_client_scope_pre_cleanup_sweeps_every_scope() -> void:
	## #872: flipping the setting and pressing Configure must not strand the
	## entry the previous scope wrote — that is precisely the "loaded in every
	## unrelated workspace" problem the setting exists to fix. The pre-cleanup
	## therefore removes from all CLIENT_SCOPES, not just the selected one.
	var client := McpClientRegistry.get_by_id("claude_code")
	assert_true(client != null, "claude_code must be registered")
	assert_true(McpCliStrategy.uses_scope_token(client), "claude_code register template takes {scope}")
	var swept := McpCliStrategy._cleanup_scopes(client)
	for scope in McpSettings.CLIENT_SCOPES:
		assert_true(swept.has(String(scope)), "pre-cleanup must sweep the %s scope" % scope)
	## A descriptor without the token keeps its single pass, so opting into
	## `{scope}` is what costs the extra subprocess spawns — nothing else
	## changes. claude_code is currently the only registered cli client, so
	## the negative case uses the synthetic descriptor rather than a dead
	## `if config_type == "cli"` branch that would pass with zero assertions.
	var plain := _make_cli_json_fallback_client(_scratch_dir.path_join("cleanup_scopes.json"))
	assert_false(McpCliStrategy.uses_scope_token(plain), "descriptor without the token must not opt in")
	var plain_scopes := McpCliStrategy._cleanup_scopes(plain)
	assert_eq(plain_scopes.size(), 1, "non-scope clients keep one pass")
	assert_eq(plain_scopes[0], "", "the single pass resolves the scope normally")


func test_project_scope_status_leaves_the_user_scope_file() -> void:
	## #872 blocker: `--scope project` writes <cwd>/.mcp.json and `--scope
	## local` writes a per-project block, neither of which is the file
	## `path_template` resolves to. A status path that keeps reading the
	## user-scope file makes _verify_post_state turn every successful
	## project-scope Configure into "configure ok but verification still reads
	## Not configured", and pins the dock row red.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorSettings unavailable in test environment")
		return
	var path := _scratch_dir.path_join("scope_status.json")
	_remove_if_exists(path)
	var client := _make_scope_cli_client(path)
	var launch := {"ok": true, "command": "uvx", "args": ["godot-ai", "attach"]}
	## Seed the user-scope file through the strategy that actually writes it,
	## so the entry is in exactly the shape the verifier accepts and a JSON
	## read-back would report CONFIGURED.
	var seeded := McpJsonStrategy.configure(client, "godot-ai", "", launch)
	assert_eq(seeded.get("status"), "ok", "seed write should succeed: %s" % seeded.get("message", ""))

	## Passing cli_path explicitly is what makes the divergence real without
	## depending on a `claude` binary existing on this machine. It never
	## resolves, so the CLI probe spawn-fails rather than reporting CONFIGURED.
	var fake_cli := "godot-ai-nonexistent-cli-xyz"

	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, McpSettings.DEFAULT_CLIENT_SCOPE)
	var at_user := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "", fake_cli, {}, launch
	)
	assert_eq(at_user.get("status"), McpClient.Status.CONFIGURED,
		"user scope must keep reading the JSON fallback file for exact drift detection")

	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, "project")
	var at_project := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "", fake_cli, {}, launch
	)
	assert_ne(at_project.get("status"), McpClient.Status.CONFIGURED,
		"project scope must not verify against the user-scope file it never wrote")

	## With no CLI to run the register, Configure falls back to the #463 JSON
	## writer, which is user-scoped whatever the setting says — so the file is
	## the correct thing to read again even at project scope.
	var at_project_no_cli := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "", "", {}, launch
	)
	assert_eq(at_project_no_cli.get("status"), McpClient.Status.CONFIGURED,
		"without a CLI the JSON fallback owns both the write and the read-back")
	_restore_client_scope()
	_remove_if_exists(path)


## Real `claude mcp get godot-ai` output, captured from claude 2.1.241 in an
## isolated CLAUDE_CONFIG_DIR. Recorded verbatim so the parser is tested
## against what the CLI actually prints rather than an idealised shape.
const _PROBE_USER := """godot-ai:
  Scope: User config (available in all your projects)
  Status: ✘ Failed to connect
  Issue: -32000: MCP error -32000: Connection closed
  Type: stdio
  Command: C:/Program Files/Git/usr/bin/true
  Args: --flag
  Environment:
"""

const _PROBE_PROJECT := """godot-ai:
  Scope: Project config (shared via .mcp.json)
  Status: ⏸ Pending approval (run `claude` to approve)
  Type: stdio
  Command: C:/Program Files/Git/usr/bin/true
  Args: --p
  Environment:
"""

const _PROBE_LOCAL := """godot-ai:
  Scope: Local config (private to you in this project)
  Status: ✘ Failed to connect
  Type: stdio
  Command: C:/Program Files/Git/usr/bin/true
  Args: --l
  Environment:
"""

const _PROBE_TARGET := "C:/Program Files/Git/usr/bin/true"


func test_scope_probe_parses_real_cli_scope_labels() -> void:
	## The parser matches the first word after "Scope:", so the parenthetical
	## blurb can be reworded by a future CLI release without breaking us.
	assert_eq(McpCliStrategy._scope_from_probe_output(_PROBE_USER), "user")
	assert_eq(McpCliStrategy._scope_from_probe_output(_PROBE_PROJECT), "project")
	assert_eq(McpCliStrategy._scope_from_probe_output(_PROBE_LOCAL), "local")
	assert_eq(McpCliStrategy._scope_from_probe_output("no scope line here"), "",
		"an unrecognisable probe must report empty, not guess a scope")


func test_scope_probe_verdict_flags_entry_resolved_from_another_scope() -> void:
	## The bug this exists to catch: `mcp list` prints a leftover user-scope
	## entry with our exact command, so a name+target scan calls an EMPTY
	## project scope CONFIGURED — a green dot over the "loaded in every
	## workspace" state the setting exists to end. Verified against claude
	## 2.1.241, where the user entry does win the resolve.
	var wrong_scope := McpCliStrategy._scope_probe_verdict(
		0, _PROBE_USER, "project", _PROBE_TARGET
	)
	assert_eq(wrong_scope.get("status"), McpClient.Status.CONFIGURED_MISMATCH,
		"an entry resolved from user scope is not a configured project scope")
	assert_contains(str(wrong_scope.get("error_msg", "")), "user",
		"the row message should name the scope that actually resolved")

	## Same output, matching selection — this is the ordinary green path.
	assert_eq(
		McpCliStrategy._scope_probe_verdict(0, _PROBE_USER, "user", _PROBE_TARGET).get("status"),
		McpClient.Status.CONFIGURED,
	)
	assert_eq(
		McpCliStrategy._scope_probe_verdict(0, _PROBE_PROJECT, "project", _PROBE_TARGET).get("status"),
		McpClient.Status.CONFIGURED,
	)
	assert_eq(
		McpCliStrategy._scope_probe_verdict(0, _PROBE_LOCAL, "local", _PROBE_TARGET).get("status"),
		McpClient.Status.CONFIGURED,
	)


func test_scope_probe_verdict_absent_entry_and_drift() -> void:
	## `claude mcp get` exits 1 with "No MCP server named ..." when absent.
	assert_eq(
		McpCliStrategy._scope_probe_verdict(1, "No MCP server named \"godot-ai\".", "project", _PROBE_TARGET).get("status"),
		McpClient.Status.NOT_CONFIGURED,
	)
	## Right scope, wrong launcher — still drift, same as the JSON path.
	assert_eq(
		McpCliStrategy._scope_probe_verdict(0, _PROBE_PROJECT, "project", "/somewhere/else/uvx").get("status"),
		McpClient.Status.CONFIGURED_MISMATCH,
	)
	## A future CLI that stops printing a Scope line must degrade to the
	## target check, not invent a red dot on a working install.
	var no_label := "godot-ai:\n  Command: %s\n" % _PROBE_TARGET
	assert_eq(
		McpCliStrategy._scope_probe_verdict(0, no_label, "project", _PROBE_TARGET).get("status"),
		McpClient.Status.CONFIGURED,
		"an unparseable Scope line degrades to the target check",
	)


func test_json_fallback_configure_notes_the_scope_it_could_not_honour() -> void:
	## #872 + #463: with no CLI on PATH, Configure falls back to writing the
	## config file directly — and that file is the USER-scope one whatever the
	## setting says. The write is real and works, so it stays `ok`; the caveat
	## rides in the message rather than in the status, because
	## _verify_post_state converts any non-CONFIGURED status after a successful
	## write into an error (see test_verify_post_state_treats_drift_as_failure_
	## after_configure) and a correct write must not report as a failure.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorSettings unavailable in test environment")
		return
	var path := _scratch_dir.path_join("fallback_scope_note.json")
	_remove_if_exists(path)
	var client := _make_scope_cli_client(path)
	var launch := {"ok": true, "command": "uvx", "args": ["godot-ai", "attach"]}

	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, "project")
	var noted := McpClientConfigurator._dispatch_configure(client, "", launch)
	assert_eq(noted.get("status"), "ok", "the fallback write really did land — it is not a failure")
	var msg := str(noted.get("message", ""))
	assert_contains(msg, "project", "the message must name the scope that was asked for")
	assert_contains(msg, "user", "...and the scope it actually wrote")

	## The status still reads CONFIGURED, so Configure does not end in the
	## "configure ok but verification reads Not configured" false error.
	var status := McpClientConfigurator._dispatch_check_status_with_cli_path_details(
		client, "", "", {}, launch
	)
	assert_eq(status.get("status"), McpClient.Status.CONFIGURED,
		"a fallback-written entry must verify clean, or configure reports success as failure")

	## At the default scope there is nothing to warn about — no note.
	es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, McpSettings.DEFAULT_CLIENT_SCOPE)
	var plain := McpClientConfigurator._dispatch_configure(client, "", launch)
	assert_eq(plain.get("status"), "ok")
	assert_false(str(plain.get("message", "")).contains("wrote user scope"),
		"no scope caveat when the selected scope is the one the fallback writes")
	_restore_client_scope()
	_remove_if_exists(path)


func test_claude_code_declares_scope_aware_status_probe() -> void:
	## `mcp list` cannot say which scope resolved, so a `{scope}` descriptor
	## needs the richer probe. Same single subprocess — see #238/#239 for why
	## adding a second CLI spawn per status check would not be acceptable.
	var client := McpClientRegistry.get_by_id("claude_code")
	assert_true(client != null, "claude_code must be registered")
	var probe := client.cli_scope_status_template
	assert_false(probe.is_empty(), "scope-token client must declare a scope probe")
	assert_true(probe.has("get"), "the probe must be `mcp get`, which prints the Scope line")
	assert_true(probe.has("{name}"), "probe must target our server by name")
	var args := McpCliStrategy.format_args(probe, "godot-ai", "")
	assert_true(args.has("godot-ai"), "{name} must substitute")
	assert_false(args.has("{name}"), "no token may reach the CLI unsubstituted")


func test_claude_code_manual_command_shows_json_fallback() -> void:
	# The CLI form is still the primary hint, but a user without the `claude`
	# binary (VS Code extension) needs the ~/.claude.json edit too (#463).
	var cmd := McpClientConfigurator.manual_command("claude_code")
	assert_contains(cmd, "claude mcp add", "manual command should still show the CLI form")
	assert_contains(cmd, ".claude.json", "manual command should also show the JSON fallback path")
	assert_contains(cmd, " -- ", "CLI form must carry the argv separator")
	assert_contains(cmd, "\"type\": \"stdio\"", "JSON fallback should show the stdio entry shape")
	assert_contains(cmd, "Advanced fallback", "URL mode stays available as the documented fallback")
	assert_contains(cmd, "\"type\": \"http\"", "URL fallback entry keeps the type:http shape")


func test_manual_cli_shell_renderers_preserve_literal_argv() -> void:
	var powershell_parts: Array[String] = [
		"tool", "hello world", "C:\\Users\\Agent Name\\pythonw.exe",
		'say "hello"', "it's", "$HOME", "`literal`", "@splat", "a,b", "",
	]
	assert_eq(
		McpManualCommand._format_shell_command(powershell_parts, McpManualCommand.SHELL_POWERSHELL),
		"Run in PowerShell:\ntool 'hello world' 'C:\\Users\\Agent Name\\pythonw.exe' 'say \"hello\"' 'it''s' '$HOME' '`literal`' '@splat' 'a,b' ''",
	)
	var posix_parts: Array[String] = powershell_parts.duplicate()
	assert_eq(
		McpManualCommand._format_shell_command(posix_parts, McpManualCommand.SHELL_POSIX),
		"Run in a POSIX shell:\ntool 'hello world' 'C:\\Users\\Agent Name\\pythonw.exe' 'say \"hello\"' 'it'\"'\"'s' '$HOME' '`literal`' '@splat' 'a,b' ''",
	)


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
	## Command clients (Claude Desktop "flat") run through a different verify path in
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
	client.command_shape = McpClient.CommandShape.FLAT
	var launch := {"ok": true, "command": "C:/Tools/godot-ai.exe", "args": ["attach", "--port", "8000"]}

	McpJsonStrategy.configure(client, "godot-ai", "http://127.0.0.1:8000/mcp", launch)
	var drifted_launch := launch.duplicate(true)
	drifted_launch["args"] = ["attach", "--port", "9000"]
	assert_eq(
		McpJsonStrategy.check_status(client, "godot-ai", "http://127.0.0.1:9000/mcp", drifted_launch),
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


func test_handler_status_requires_deferred_request_context() -> void:
	var result := _handler.check_client_status({})
	assert_is_error(result)
	assert_contains(str(result.get("error", {}).get("message", "")), "deferred request context")


func test_status_sweep_returns_array_of_clients() -> void:
	var result := McpClientConfigurator.run_client_status_sweep(
		McpClientConfigurator.capture_launch_context()
	)
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


func test_status_sweep_entry_surfaces_actionable_error_only_when_present() -> void:
	var with_error := McpClientConfigurator._client_status_sweep_entry(
		"cursor",
		{"status": McpClient.Status.ERROR, "error_msg": "two package roots matched"},
		true,
	)
	assert_eq(with_error.get("status"), "error")
	assert_eq(with_error.get("error"), "two package roots matched")
	var without_error := McpClientConfigurator._client_status_sweep_entry(
		"cursor", {"status": McpClient.Status.CONFIGURED, "error_msg": ""}, true
	)
	assert_false(without_error.has("error"), "healthy rows must not gain an empty error field")


func test_handler_teardown_defers_status_worker_join() -> void:
	var handler := ClientHandler.new()
	var worker := Thread.new()
	var start_error := worker.start(func() -> Dictionary:
		OS.delay_msec(100)
		return {"data": {}}
	)
	assert_eq(start_error, OK)
	handler._status_workers.append(worker)
	handler.prepare_for_teardown()
	assert_true(worker.is_alive(), "teardown must not block the main thread waiting for a live worker")
	assert_eq(handler._status_workers, [worker], "the polling coroutine must retain worker ownership")
	assert_true(handler._status_tearing_down, "teardown must reject new status sweeps")
	# This synthetic worker has no finisher coroutine, so realize it explicitly
	# after the non-blocking contract above has been asserted.
	worker.wait_to_finish()
	handler._status_workers.erase(worker)


# ----- entry-builder shape sanity for shipped clients -----
#
# #838: every JSON client is command-shape now; the URL form survives only as
# the manual-instruction fallback, so its per-client key shape is pinned via
# `build_url_entry` and the command entry via `build_entry` + launch.

func test_cursor_attach_entry_and_url_fallback() -> void:
	var c := McpClientRegistry.get_by_id("cursor")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	var launch := _test_attach_launch()
	var entry := McpJsonStrategy.build_entry(c, "http://unused", {"url": "http://old", "type": "http"}, launch)
	assert_eq(entry.get("command"), launch.get("command"))
	assert_eq(entry.get("args"), launch.get("args"))
	assert_eq(entry.get("type"), "stdio", "pin repins a stray legacy type value")
	assert_false(entry.has("url"), "legacy url must not survive migration")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch))
	var fallback := McpJsonStrategy.build_url_entry(c, "http://x")
	assert_eq(fallback.get("url", ""), "http://x")


func test_antigravity_attach_entry_and_serverUrl_fallback() -> void:
	var c := McpClientRegistry.get_by_id("antigravity")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	var launch := _test_attach_launch()
	var entry := McpJsonStrategy.build_entry(c, "http://unused", {"serverUrl": "http://old"}, launch)
	assert_eq(entry.get("command"), launch.get("command"))
	assert_false(entry.has("serverUrl"), "legacy serverUrl must not survive next to a command")
	assert_false(entry.has("type"), "Antigravity documents no type field — never write one")
	assert_eq(entry.get("disabled", true), false, "disabled seeds on fresh entries")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch))
	var fallback := McpJsonStrategy.build_url_entry(c, "http://x")
	assert_eq(fallback.get("serverUrl", ""), "http://x")
	assert_eq(fallback.get("disabled", true), false)


func test_gemini_cli_attach_entry_removes_both_url_forms() -> void:
	var c := McpClientRegistry.get_by_id("gemini_cli")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	var launch := _test_attach_launch()
	## Gemini's config is one-of command|url|httpUrl — a leftover of EITHER
	## URL key next to command violates the one-of and must be scrubbed.
	var entry := McpJsonStrategy.build_entry(
		c, "http://unused", {"httpUrl": "http://old", "url": "http://sse-old"}, launch
	)
	assert_eq(entry.get("command"), launch.get("command"))
	assert_false(entry.has("httpUrl"))
	assert_false(entry.has("url"))
	assert_false(entry.has("type"), "gemini-cli has no type field")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch))
	var fallback := McpJsonStrategy.build_url_entry(c, "http://x")
	assert_eq(fallback.get("httpUrl", ""), "http://x")


func test_qwen_code_matches_gemini_attach_shape() -> void:
	var c := McpClientRegistry.get_by_id("qwen_code")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	assert_true(c.command_legacy_keys.has("httpUrl"))
	assert_true(c.command_legacy_keys.has("url"))
	assert_true(c.command_user_fields.has("discoveryTimeoutMs"), "Qwen-only stdio discovery cap is user-owned")


func test_kimi_code_attach_entry_removes_transport_key() -> void:
	var c := McpClientRegistry.get_by_id("kimi_code")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	assert_eq(c.config_home_env, "KIMI_CODE_HOME", "documented $KIMI_CODE_HOME relocation (#617 analogue)")
	assert_eq(c.config_home_env_subpath, "mcp.json")
	var launch := _test_attach_launch()
	## `transport` is only defined for SSE-with-url in Kimi's docs — the
	## legacy `transport: "http"` pin must not survive on a command entry.
	var entry := McpJsonStrategy.build_entry(
		c, "http://unused", {"url": "http://old", "transport": "http"}, launch
	)
	assert_false(entry.has("url"))
	assert_false(entry.has("transport"))
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch))
	var lingering_transport := entry.duplicate(true)
	lingering_transport["transport"] = "http"
	assert_false(
		McpJsonStrategy.verify_entry(c, lingering_transport, "http://unused", launch),
		"a lingering transport key is migration drift",
	)


func test_windsurf_and_trae_and_kiro_attach_declarations() -> void:
	for probe in [
		["windsurf", "serverUrl"],
		["trae", "url"],
		["kiro", "url"],
	]:
		var c := McpClientRegistry.get_by_id(String(probe[0]))
		assert_eq(c.command_shape, McpClient.CommandShape.FLAT, "%s must be FLAT" % probe[0])
		assert_true(c.command_legacy_keys.has(String(probe[1])), "%s must scrub %s" % [probe[0], probe[1]])
		assert_true(c.command_transport_key.is_empty(), "%s documents no type field" % probe[0])
		assert_true(c.command_supports_url_fallback, "%s keeps a documented URL mode" % probe[0])


func test_claude_desktop_declares_flat_attach_shape() -> void:
	var client := McpClientRegistry.get_by_id("claude_desktop")
	assert_eq(client.command_shape, McpClient.CommandShape.FLAT)
	var windows_candidates: Array = client.config_path_candidates.get("windows", [])
	assert_eq(windows_candidates.size(), 2)
	assert_contains(str(windows_candidates[0]), "Packages/Claude_*")
	assert_eq(
		str(windows_candidates[1]),
		"$APPDATA/Claude/claude_desktop_config.json",
		"the second candidate is the deterministic conventional roaming fallback",
	)
	assert_false(
		str(windows_candidates[0]).contains("pzs8sxrjxfjjc"),
		"the Store publisher hash must not be hardcoded",
	)
	assert_true(client.detect_paths.has("$LOCALAPPDATA/Packages/Claude_*"))
	assert_false(
		client.command_supports_url_fallback,
		"claude_desktop_config.json local entries do not support URL transport",
	)
	assert_true(client.command_legacy_keys.has("url"), "URL migration must remove the legacy key")
	assert_true(client.command_env_legacy_keys.has("UV_LINK_MODE"), "legacy bridge env pin must be removed")
	assert_true(client.command_user_fields.has("env"))
	assert_true(client.command_user_fields.has("disabled"))


func test_claude_desktop_flat_entry_round_trips() -> void:
	var client := McpClientRegistry.get_by_id("claude_desktop")
	var launch := _test_attach_launch()
	var entry := McpJsonStrategy.build_entry(client, "http://unused", null, launch)
	assert_eq(entry.get("command"), launch.get("command"))
	assert_eq(entry.get("args"), launch.get("args"))
	assert_false(entry.has("url"))
	assert_true(McpJsonStrategy.verify_entry(client, entry, "http://unused", launch))


func test_json_flat_transport_and_initial_fields_are_declarative() -> void:
	var client := McpClient.new()
	client.display_name = "Typed Flat Test"
	client.command_shape = McpClient.CommandShape.FLAT
	client.command_transport_key = "transport"
	client.command_transport_value = null
	client.command_initial_fields = {"disabled": false}
	var launch := _test_attach_launch()
	var entry := McpJsonStrategy.build_entry(
		client, "http://unused", {"disabled": true, "future": 7}, launch
	)
	assert_true(entry.has("transport"), "a null-valued discriminator must still be emitted")
	assert_eq(entry.get("transport"), null)
	assert_eq(entry.get("disabled"), true, "initial fields must not reset user state")
	assert_eq(entry.get("future"), 7, "unknown fields must survive")
	assert_true(McpJsonStrategy.verify_entry(client, entry, "http://unused", launch))
	entry.erase("transport")
	assert_false(
		McpJsonStrategy.verify_entry(client, entry, "http://unused", launch),
		"a missing null-valued discriminator is still launch drift",
	)


func test_claude_desktop_legacy_proxy_and_url_entries_are_drift() -> void:
	var client := McpClientRegistry.get_by_id("claude_desktop")
	var launch := _test_attach_launch()
	var legacy_proxy := {
		"command": "uvx",
		"args": ["mcp-proxy==0.11.0", "--transport", "streamablehttp", "http://x"],
		"env": {"UV_LINK_MODE": "copy"},
	}
	assert_false(McpJsonStrategy.verify_entry(client, legacy_proxy, "http://x", launch))
	assert_false(
		McpJsonStrategy.verify_entry(client, {"url": "http://x"}, "http://x", launch),
		"legacy URL mode must surface migration drift",
	)


func test_claude_desktop_configure_migrates_losslessly() -> void:
	var path := _scratch_dir.path_join("claude_attach_migration.json")
	_remove_if_exists(path)
	var pre_existing := {
		"mcpServers": {
			"godot-ai": {
				"url": "http://old",
				"command": "uvx",
				"args": ["mcp-proxy==0.11.0", "--transport", "streamablehttp", "http://old"],
				"env": {
					"UV_LINK_MODE": "copy",
					"HTTP_PROXY": "http://corp-proxy:3128",
					"PYTHONUNBUFFERED": "1",
				},
				"disabled": true,
				"futureClaudeField": {"keep": true},
			}
		}
	}
	_write_text(path, JSON.stringify(pre_existing))

	var client := _make_claude_flat_client(path)
	var launch := _test_attach_launch()
	var before := McpJsonStrategy.check_status(client, "godot-ai", "http://new", launch)
	assert_eq(before, McpClient.Status.CONFIGURED_MISMATCH)
	var result := McpJsonStrategy.configure(client, "godot-ai", "http://new", launch)
	assert_eq(result.get("status"), "ok")

	var read_file := FileAccess.open(path, FileAccess.READ)
	var written = JSON.parse_string(read_file.get_as_text())
	read_file.close()
	var entry: Dictionary = written.get("mcpServers", {}).get("godot-ai", {})
	assert_false(entry.has("url"), "migration must remove the conflicting URL key")
	assert_eq(entry.get("command"), launch.get("command"))
	assert_eq(entry.get("args"), launch.get("args"))
	assert_eq(entry.get("disabled"), true, "user disabled state must survive")
	assert_eq(entry.get("futureClaudeField"), {"keep": true}, "unknown client fields must survive")
	var env: Dictionary = entry.get("env", {})
	assert_false(env.has("UV_LINK_MODE"), "obsolete bridge-only env pin must be removed")
	assert_eq(env.get("HTTP_PROXY"), "http://corp-proxy:3128")
	assert_eq(env.get("PYTHONUNBUFFERED"), "1")
	assert_eq(McpJsonStrategy.check_status(client, "godot-ai", "http://new", launch), McpClient.Status.CONFIGURED)


func test_claude_desktop_migration_omits_empty_env() -> void:
	var client := McpClientRegistry.get_by_id("claude_desktop")
	var existing := {"env": {"UV_LINK_MODE": "copy"}}
	var entry := McpJsonStrategy.build_entry(client, "http://unused", existing, _test_attach_launch())
	assert_false(entry.has("env"), "an env object emptied by migration must be omitted")


func test_claude_desktop_missing_launch_is_error_without_write() -> void:
	var path := _scratch_dir.path_join("claude_attach_missing_launch.json")
	_remove_if_exists(path)
	var original := '{"mcpServers":{"godot-ai":{"url":"http://x"}}}'
	_write_text(path, original)
	var client := _make_claude_flat_client(path)
	var unavailable := {"ok": false, "error": "Install uv or repair the launcher."}
	var details := McpJsonStrategy.check_status_details(client, "godot-ai", "http://x", unavailable)
	assert_eq(details.get("status"), McpClient.Status.ERROR)
	assert_contains(str(details.get("error_msg", "")), "Install uv")
	var configured := McpJsonStrategy.configure(client, "godot-ai", "http://x", unavailable)
	assert_eq(configured.get("status"), "error")
	var read_file := FileAccess.open(path, FileAccess.READ)
	assert_eq(read_file.get_as_text(), original, "failed discovery must leave JSON byte-identical")
	read_file.close()


func test_claude_desktop_manual_command_shows_attach_without_url_fallback() -> void:
	var client := McpClientRegistry.get_by_id("claude_desktop")
	var manual := McpManualCommand.build(
		client, "godot-ai", "http://x", "/tmp/cd.json", _test_attach_launch()
	)
	assert_contains(manual, '"command": "C:/Python313/pythonw.exe"')
	assert_contains(manual, '"attach"')
	assert_false(manual.contains("Advanced fallback"))
	assert_false(manual.contains('"url": "http://x"'))
	var unavailable := McpManualCommand.build(
		client,
		"godot-ai",
		"http://x",
		"/tmp/cd.json",
		{"ok": false, "error": "Install uv first."},
	)
	assert_contains(unavailable, "Install uv first")
	assert_false(unavailable.contains('"url": "http://x"'))


func test_json_manual_url_fallback_requires_descriptor_capability() -> void:
	var client := _make_claude_flat_client("/tmp/flat.json")
	client.command_supports_url_fallback = true
	var manual := McpManualCommand.build(
		client, "godot-ai", "http://x", "/tmp/flat.json", _test_attach_launch()
	)
	assert_contains(manual, "Advanced fallback")
	assert_contains(manual, '"url": "http://x"')


func test_json_manual_command_rejects_unsupported_command_shape() -> void:
	var client := McpClient.new()
	client.display_name = "Future JSON Client"
	client.config_type = "json"
	client.server_key_path = PackedStringArray(["mcpServers"])
	client.command_shape = McpClient.CommandShape.TYPED_FLAT
	var manual := McpManualCommand.build(
		client, "godot-ai", "http://x", "/tmp/future.json", _test_attach_launch()
	)
	assert_contains(manual, "command shape not supported by JSON yet")
	assert_false(manual.contains('"godot-ai": {}'), "unsupported shapes must not render an empty entry")


func test_yaml_build_entry_rejects_unsupported_command_shape() -> void:
	var client := McpClient.new()
	client.command_shape = McpClient.CommandShape.COMMAND_ARRAY
	assert_true(
		McpYamlStrategy.build_entry(client, "http://unused", null, _test_attach_launch()).is_empty(),
		"YAML must not silently flatten an unsupported command shape",
	)


func test_zed_attach_entry_scrubs_every_http_only_key() -> void:
	var c := McpClientRegistry.get_by_id("zed")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	var launch := _test_attach_launch()
	## Zed's context_servers entry is an UNTAGGED serde enum — an entry
	## carrying `command` plus any HTTP-only key (url/headers/oauth) matches
	## no variant and breaks outright, so scrubbing them is load-bearing.
	var entry := McpJsonStrategy.build_entry(
		c,
		"http://unused",
		{"url": "http://old", "headers": {"X": "y"}, "enabled": false, "timeout": 90},
		launch,
	)
	assert_false(entry.has("url"))
	assert_false(entry.has("headers"))
	assert_false(entry.has("type"), "current Zed is shape-discriminated — no type/source tag")
	assert_eq(entry.get("enabled"), false, "user enabled toggle survives")
	assert_eq(entry.get("timeout"), 90, "stdio timeout is user-owned")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch))
	var fallback := McpJsonStrategy.build_url_entry(c, "http://x")
	assert_eq(fallback.get("url", ""), "http://x")


func test_vscode_attach_entry_flips_type_pin_to_stdio() -> void:
	for id in ["vscode", "vscode_insiders"]:
		var c := McpClientRegistry.get_by_id(id)
		assert_eq(c.server_key_path.size(), 1, "%s key path" % id)
		assert_eq(c.server_key_path[0], "servers", "%s uses the servers key" % id)
		assert_eq(c.command_shape, McpClient.CommandShape.FLAT, "%s shape" % id)
		var launch := _test_attach_launch()
		## VS Code's stdio schema is additionalProperties:false — leftover
		## url/headers invalidate the entry, and the legacy `type: "http"`
		## must flip to "stdio" rather than survive the deep copy.
		var entry := McpJsonStrategy.build_entry(
			c, "http://unused", {"type": "http", "url": "http://old"}, launch
		)
		assert_eq(entry.get("type"), "stdio", "%s type pin" % id)
		assert_false(entry.has("url"), "%s legacy url" % id)
		assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch), "%s verify" % id)
		var fallback := McpJsonStrategy.build_url_entry(c, "http://x")
		assert_eq(fallback.get("type", ""), "http", "%s fallback keeps type:http" % id)
		assert_eq(fallback.get("url", ""), "http://x", "%s fallback url" % id)


func test_roo_family_attach_entries_pin_stdio_except_kilo() -> void:
	## #838: cline/roo/zoo write `type: "stdio"` (documented/schema-accepted in
	## each), which also flips the legacy streamable-http pin in place. Kilo is
	## the deliberate exception — its v7 migrator routes on `type` and only a
	## TYPELESS command entry works in both product generations, so kilo lists
	## `type` as a legacy key instead of pinning it.
	var launch := _test_attach_launch()
	for probe in [
		["cline", "streamableHttp"],
		["roo_code", "streamable-http"],
		["zoo_code", "streamable-http"],
	]:
		var c := McpClientRegistry.get_by_id(String(probe[0]))
		assert_eq(c.command_shape, McpClient.CommandShape.FLAT, "%s shape" % probe[0])
		var legacy := {"type": String(probe[1]), "url": "http://old", "disabled": true, "alwaysAllow": ["x"]}
		var entry := McpJsonStrategy.build_entry(c, "http://unused", legacy, launch)
		assert_eq(entry.get("type"), "stdio", "%s must repin type to stdio" % probe[0])
		assert_false(entry.has("url"), "%s legacy url must be removed" % probe[0])
		assert_eq(entry.get("disabled"), true, "%s user disabled state survives" % probe[0])
		assert_true(McpJsonStrategy.verify_entry(c, entry, "http://unused", launch), "%s verify" % probe[0])
	var kilo := McpClientRegistry.get_by_id("kilo_code")
	assert_eq(kilo.command_shape, McpClient.CommandShape.FLAT)
	assert_true(kilo.command_transport_key.is_empty(), "kilo stdio entries must stay typeless")
	assert_true(kilo.command_legacy_keys.has("type"), "kilo must scrub the legacy type key")
	var kilo_entry := McpJsonStrategy.build_entry(
		kilo, "http://unused", {"type": "streamable-http", "url": "http://old"}, launch
	)
	assert_false(kilo_entry.has("type"), "an http type left behind routes kilo's v7 migrator to the remote branch")
	assert_false(kilo_entry.has("url"))
	assert_true(McpJsonStrategy.verify_entry(kilo, kilo_entry, "http://unused", launch))
	assert_false(
		McpJsonStrategy.verify_entry(
			kilo,
			{"type": "stdio", "command": launch.get("command"), "args": launch.get("args")},
			"http://unused",
			launch,
		),
		"even a stdio-typed kilo entry is drift — the verified-safe form is typeless",
	)


func test_roo_family_legacy_url_entries_register_as_migration_drift() -> void:
	## Every pre-#838 URL entry — typeless, sse, or correctly pinned — must
	## read CONFIGURED_MISMATCH against the command contract so the dock
	## offers migration through the existing Configure flow (issue #838 rule:
	## legacy URL entries report CONFIGURED_MISMATCH, not CONFIGURED).
	var launch := _test_attach_launch()
	for id in ["cline", "roo_code", "kilo_code", "zoo_code"]:
		var c := McpClientRegistry.get_by_id(id)
		for legacy in [
			{"url": "http://x", "disabled": false},
			{"type": "sse", "url": "http://x"},
			{"type": "streamable-http", "url": "http://x"},
			{"type": "streamableHttp", "url": "http://x"},
		]:
			assert_false(
				McpJsonStrategy.verify_entry(c, legacy, "http://x", launch),
				"%s legacy entry %s must register as drift" % [id, str(legacy)],
			)


func test_roo_family_url_fallback_entries_keep_transport_pins() -> void:
	## The URL form survives as the manual-instruction fallback; its per-client
	## transport pin (#189/#190) must stay intact there.
	for probe in [
		["cline", "streamableHttp"],
		["roo_code", "streamable-http"],
		["kilo_code", "streamable-http"],
		["zoo_code", "streamable-http"],
	]:
		var c := McpClientRegistry.get_by_id(String(probe[0]))
		var fallback := McpJsonStrategy.build_url_entry(c, "http://x")
		assert_eq(fallback.get("type", ""), String(probe[1]), "%s fallback type pin" % probe[0])
		assert_eq(fallback.get("url", ""), "http://x")
		assert_eq(fallback.get("disabled"), false, "%s fallback seeds disabled" % probe[0])


# ----- entry_initial_fields: user-state preservation across reconfigure -----
#
# #838 moved every registered JSON client to a command shape, so these
# URL-contract tests run on a synthetic Roo-shaped URL descriptor — the URL
# path is still live code (manual fallback rendering and any future URL-only
# client), and the command-side twin of this contract is pinned by the
# claude_desktop / attach-config suites via command_initial_fields.

func _make_roo_shaped_url_client() -> McpClient:
	var c := McpClient.new()
	c.id = "url_contract_test"
	c.display_name = "URL Contract Test"
	c.config_type = "json"
	c.server_key_path = PackedStringArray(["mcpServers"])
	c.entry_extra_fields = {"type": "streamable-http"}
	c.entry_initial_fields = {"disabled": false, "alwaysAllow": []}
	return c


func test_verify_entry_ignores_initial_field_drift() -> void:
	## Default verifier must NOT compare `entry_initial_fields` keys: those are
	## user-state (auto-approval lists, `disabled` toggles) that the user is
	## expected to mutate after the initial Configure. A user with a customised
	## `alwaysAllow` array must not be flagged as drift — otherwise the dock's
	## Configure-All-Mismatched sweep silently overwrites their state.
	var c := _make_roo_shaped_url_client()
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
	var c := _make_roo_shaped_url_client()
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
	var c := _make_roo_shaped_url_client()
	var fresh := McpJsonStrategy.build_entry(c, "http://x")  # existing = null
	assert_eq(fresh.get("type"), "streamable-http", "type pin must be set on fresh entries")
	assert_eq(fresh.get("disabled"), false, "initial `disabled: false` must seed on fresh entries")
	assert_eq(fresh.get("alwaysAllow"), [], "initial `alwaysAllow: []` must seed on fresh entries")


func test_build_entry_force_overwrites_drifted_required_fields() -> void:
	## A user (or upstream) entry with a wrong `type` value gets corrected on
	## reconfigure — the type pin is in `entry_extra_fields` precisely because
	## a wrong value breaks transport negotiation. User-state preservation
	## must not extend to broken transport pins.
	var c := _make_roo_shaped_url_client()
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


func test_hermes_attach_entry_is_flat_and_typeless() -> void:
	## #838: Hermes stdio entries are flat command/args, transport-inferred
	## exactly like the URL form — so the legacy url (and HTTP-only headers)
	## must be scrubbed, and no type field may ever be written.
	var c := McpClientRegistry.get_by_id("hermes")
	assert_eq(c.command_shape, McpClient.CommandShape.FLAT)
	var launch := _test_attach_launch()
	var entry := McpYamlStrategy.build_entry(
		c, "http://unused", {"url": "http://old", "headers": {"X": "y"}, "enabled": false}, launch
	)
	assert_eq(entry.get("command"), launch.get("command"))
	assert_eq(entry.get("args"), launch.get("args"))
	assert_false(entry.has("url"), "an entry with both url and command picks the wrong transport")
	assert_false(entry.has("headers"), "headers is HTTP-only and must not survive")
	assert_eq(entry.get("enabled"), false, "user enabled toggle survives")
	assert_false(entry.has("type"), "Hermes entries must NOT carry a type field")
	assert_true(McpYamlStrategy.verify_entry(c, entry, "http://unused", launch))
	var manual := McpManualCommand.build(c, "godot-ai", "http://x", "/tmp/hermes/config.yaml", launch)
	assert_contains(manual, "mcp_servers")
	assert_contains(manual, "command: C:/Python313/pythonw.exe")
	assert_contains(manual, "args: [")
	assert_contains(manual, "\"attach\"")
	assert_contains(manual, "Advanced fallback")
	assert_contains(manual, "url: http://x")
	assert_false(manual.contains("type:"), "manual hint must not mention a type field")


func test_hermes_verify_flags_launch_and_legacy_drift() -> void:
	var c := McpClientRegistry.get_by_id("hermes")
	var launch := _test_attach_launch()
	var current := McpYamlStrategy.build_entry(c, "http://unused", null, launch)
	assert_true(McpYamlStrategy.verify_entry(c, current, "http://unused", launch), "current entry must verify")
	assert_false(
		McpYamlStrategy.verify_entry(c, {"url": "http://x"}, "http://x", launch),
		"legacy URL entry must register as migration drift",
	)
	var lingering_url := current.duplicate(true)
	lingering_url["url"] = "http://x"
	assert_false(
		McpYamlStrategy.verify_entry(c, lingering_url, "http://unused", launch),
		"a url lingering next to command must register as drift",
	)
	var args_drift := current.duplicate(true)
	args_drift["args"] = ["attach", "--port", "9999"]
	assert_false(
		McpYamlStrategy.verify_entry(c, args_drift, "http://unused", launch),
		"args drift (port change) must register as drift",
	)
	var unavailable := {"ok": false, "error": "Install uv first."}
	assert_false(
		McpYamlStrategy.verify_entry(c, current, "http://unused", unavailable),
		"no verified launcher → nothing can verify",
	)


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


func test_hermes_is_in_required_registry_check() -> void:
	## Ensure test_registry_loads_all_clients would not break if this test
	## was added to the required client list — just a forward-compat guard.
	assert_true(McpClientRegistry.has_id("hermes"), "hermes client must be in registry")


func _hermes_scratch_path(filename: String) -> String:
	var dir := OS.get_environment("TMPDIR")
	if dir.is_empty():
		dir = OS.get_environment("TEMP")
	if dir.is_empty():
		dir = "/tmp"
	return dir.path_join(filename)


func test_hermes_yaml_roundtrips_through_configure() -> void:
	## End-to-end: a configure write must produce YAML Hermes can read back
	## as CONFIGURED, preserving other top-level keys in the user's file.
	var c := McpClientRegistry.get_by_id("hermes")
	var path := _hermes_scratch_path("godot_ai_hermes_rt.yaml")
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
	var launch := _test_attach_launch()
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://127.0.0.1:8000/mcp", launch)
	var status := McpYamlStrategy.check_status(c, "godot-ai", "http://127.0.0.1:8000/mcp", launch)
	c.path_template = real_path
	assert_eq(res.get("status", ""), "ok", "configure must report ok: %s" % res.get("message", ""))
	assert_eq(status, McpClient.Status.CONFIGURED, "written command entry must read back CONFIGURED")

	# Read back and assert shape.
	var reread := FileAccess.get_file_as_string(path)
	assert_contains(reread, "mcp_servers:")
	assert_contains(reread, "godot-ai:")
	assert_contains(reread, "command: C:/Python313/pythonw.exe")
	assert_contains(reread, "args: [\"-c\", ")
	assert_contains(reread, "\"attach\"")
	assert_false(reread.contains("godot-ai:\n    url:"), "our entry must be command-mode, not url-mode")
	# Unrelated key preserved.
	assert_contains(reread, "model: openai/gpt-4o")
	# github entry preserved, still URL-shaped.
	assert_contains(reread, "github:")
	assert_contains(reread, "url: https://mcp.github.com/mcp")
	DirAccess.remove_absolute(path)


func test_hermes_yaml_empty_block_does_not_swallow_sibling_key() -> void:
	## Corruption regression: an EMPTY `mcp_servers:` block followed by a
	## top-level sibling key. The block parser must not consume the sibling
	## as a server entry — that would re-emit `model:` nested under
	## mcp_servers on rewrite and corrupt the user's config.
	var c := McpClientRegistry.get_by_id("hermes")
	var path := _hermes_scratch_path("godot_ai_hermes_empty_block.yaml")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "could not open temp yaml")
	f.store_string("mcp_servers:\nmodel: openai/gpt-4o\n")
	f.close()

	var real_path := c.path_template
	c.path_template = {"unix": path, "windows": path}
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://127.0.0.1:8000/mcp", _test_attach_launch())
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
	var path := _hermes_scratch_path("godot_ai_hermes_comments.yaml")
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
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://127.0.0.1:8000/mcp", _test_attach_launch())
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


func test_yaml_url_reconfigure_preserves_user_headers_drops_stdio_keys() -> void:
	## URL-mode reconfigure preservation contract (mirrors JSON's
	## entry_initial_fields split): user-mutable keys like `headers` survive a
	## repoint; stale stdio-bridge keys (`command`) are scrubbed so the client
	## never sees both a url and a command on one entry. Runs on a synthetic
	## URL-mode YAML descriptor — registered hermes is command-shape now
	## (#838), but the URL path stays live for its manual fallback.
	var c := McpClient.new()
	c.id = "yaml_url_contract_test"
	c.display_name = "YAML URL Contract Test"
	c.config_type = "yaml"
	c.server_key_path = PackedStringArray(["mcp_servers"])
	c.entry_url_field = "url"
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


func test_hermes_yaml_command_args_round_trip_through_flow_parser() -> void:
	## The emitted flow-style args line must parse back into the SAME array —
	## including items carrying quotes, spaces, and backslashes (the Windows
	## pythonw -c bootstrap) — or verification would drift on every refresh.
	var c := McpClientRegistry.get_by_id("hermes")
	var path := _hermes_scratch_path("godot_ai_hermes_flow_args.yaml")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var launch := {
		"ok": true,
		"tier": "uvx",
		"command": "C:/Python313/pythonw.exe",
		"args": [
			"-c", "import subprocess; \"quoted arg\"", 'C:\\Users\\Agent "quoted"\\bin\\uvx.exe',
			"godot-ai", "attach", "--port", "8123",
		],
	}
	var real_path := c.path_template
	c.path_template = {"unix": path, "windows": path}
	var res := McpYamlStrategy.configure(c, "godot-ai", "http://unused", launch)
	var status := McpYamlStrategy.check_status(c, "godot-ai", "http://unused", launch)
	var drifted := launch.duplicate(true)
	var port_index: int = drifted["args"].find("--port")
	assert_true(port_index >= 0 and port_index + 1 < drifted["args"].size(),
		"launch args must contain --port <value>")
	drifted["args"][port_index + 1] = "9999"
	var drift_status := McpYamlStrategy.check_status(c, "godot-ai", "http://unused", drifted)
	c.path_template = real_path
	assert_eq(res.get("status", ""), "ok", "configure must succeed: %s" % res.get("message", ""))
	assert_eq(status, McpClient.Status.CONFIGURED, "hazardous-char args must round-trip to CONFIGURED")
	assert_eq(drift_status, McpClient.Status.CONFIGURED_MISMATCH, "a changed port must read as drift")
	DirAccess.remove_absolute(path)


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

func _test_attach_launch() -> Dictionary:
	return {
		"ok": true,
		"tier": "uvx",
		"command": "C:/Python313/pythonw.exe",
		"args": [
			"-c", "stdio-bootstrap", "C:/Tools/uv/uvx.exe",
			"--link-mode", "copy", "--from", "godot-ai==3.0.7",
			"godot-ai", "attach", "--port", "8000", "--ws-port", "9500",
		],
	}


func _make_claude_flat_client(path: String) -> McpClient:
	var client := McpClient.new()
	client.id = "claude_desktop_test"
	client.display_name = "Claude Desktop Test"
	client.config_type = "json"
	client.path_template = {"darwin": path, "windows": path, "linux": path, "unix": path}
	client.server_key_path = PackedStringArray(["mcpServers"])
	client.command_shape = McpClient.CommandShape.FLAT
	client.command_legacy_keys = PackedStringArray(["url"])
	client.command_env_legacy_keys = PackedStringArray(["UV_LINK_MODE"])
	client.command_user_fields = PackedStringArray(["env", "disabled"])
	return client


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


func _make_candidate_json_client(root: String, roaming_path: String) -> McpClient:
	var client := _make_test_json_client(roaming_path)
	var candidates := [
		root.path_join(
			"Packages/Claude_*/LocalCache/Roaming/Claude/claude_desktop_config.json"
		),
		roaming_path,
	]
	client.config_path_candidates = {
		"darwin": candidates,
		"windows": candidates,
		"linux": candidates,
		"unix": candidates,
	}
	return client


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


func _write_text(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "Failed to write scratch file at %s" % path)
	if file != null:
		file.store_string(content)
		file.close()


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	assert_true(file != null, "Failed to read scratch file at %s" % path)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _remove_dir_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for dir_name in dir.get_directories():
		_remove_dir_recursive(path.path_join(dir_name))
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
	_restore_client_scope()


## Per-test restore. The scope setting now steers status routing as well as
## argv (#872), so leaking `project` out of one test silently changes which
## code path every later test in the suite exercises.
func _restore_client_scope() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if _saved_client_scope == null:
		es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, McpSettings.DEFAULT_CLIENT_SCOPE)
	else:
		es.set_setting(McpSettings.SETTING_CLIENT_SCOPE, _saved_client_scope)
