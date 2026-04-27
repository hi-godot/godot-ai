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
		if es.has_setting(McpClientConfigurator.SETTING_HTTP_PORT):
			_saved_http_port = es.get_setting(McpClientConfigurator.SETTING_HTTP_PORT)
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
			assert_gt(client.server_key_path.size(), 0, "%s missing server_key_path" % client.id)
		elif client.config_type == "cli":
			assert_gt(client.cli_names.size(), 0, "%s cli client missing cli_names" % client.id)
			assert_gt(client.cli_register_template.size(), 0, "%s cli client missing cli_register_template" % client.id)
		elif client.config_type == "toml":
			assert_gt(client.toml_section_path.size(), 0, "%s toml client missing toml_section_path" % client.id)
			assert_gt(client.toml_body_template.size(), 0, "%s toml client missing toml_body_template" % client.id)


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
	es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, 8123)
	assert_eq(McpClientConfigurator.http_port(), 8123)
	_clear_port_settings()


func test_http_port_rejects_out_of_range() -> void:
	## Privileged ports and anything above 65535 must fall back to the default,
	## not be returned verbatim — the Python server would refuse to bind and
	## the dock would be left with a useless number in the label.
	_clear_port_settings()
	var es := EditorInterface.get_editor_settings()
	assert_true(es != null, "EditorSettings unavailable")
	es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, 80)
	assert_eq(McpClientConfigurator.http_port(), McpClientConfigurator.DEFAULT_HTTP_PORT)
	es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, 70000)
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
	es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, 8321)
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
	## Bridge clients (Claude Desktop "flat", Zed "nested") run through a
	## different verify path in `_json_strategy.verify_entry` than the
	## default url-field comparison. Drift must still surface as
	## CONFIGURED_MISMATCH, not NOT_CONFIGURED — dock contract is the same.
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

	# Disabled section is also drift, not absence — the entry is there,
	# the user just turned it off, and re-running Configure restores it.
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[mcp_servers.\"godot-ai\"]\nurl = \"http://127.0.0.1:8000/mcp\"\nenabled = false\n")
	f.close()
	assert_eq(
		McpTomlStrategy.check_status(client, "godot-ai", "http://127.0.0.1:8000/mcp"),
		McpClient.Status.CONFIGURED_MISMATCH,
	)


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


func test_claude_desktop_verify_entry_accepts_uvx_form() -> void:
	## Drift-detection: once we've written the new uvx entry, check_status
	## must round-trip it as CONFIGURED (not MISMATCH). Guards against a
	## verifier that still only recognises the old npx/mcp-remote shape.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://x"), "uvx entry should verify as a match")


func test_claude_desktop_verify_entry_accepts_future_url_form() -> void:
	## Tolerance preserved from the pre-refactor verifier: a hypothetical
	## future Claude Desktop that speaks HTTP natively would write a plain
	## `{"url": "..."}` entry. The flat-bridge verifier must accept that
	## shape too so we don't downgrade-classify it as drift.
	var c := McpClientRegistry.get_by_id("claude_desktop")
	var future_entry := {"url": "http://x"}
	assert_true(McpJsonStrategy.verify_entry(c, future_entry, "http://x"), "future url-style entry should verify")


func test_zed_bridges_via_uvx() -> void:
	var c := McpClientRegistry.get_by_id("zed")
	assert_eq(c.entry_uvx_bridge, McpClient.UvxBridge.NESTED, "zed must declare NESTED uvx bridge")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	var cmd = entry.get("command", {})
	assert_true(cmd is Dictionary, "Zed entry.command must be a Dictionary (path+args shape)")
	_assert_uvx_command(cmd.get("path", ""))
	_assert_mcp_proxy_bridge_args(cmd.get("args", []), "http://x")


func test_zed_verify_entry_accepts_uvx_form() -> void:
	## Parity with claude_desktop drift-detection test — if Zed's entry shape
	## changes but the verifier isn't updated in lock-step, this catches it.
	var c := McpClientRegistry.get_by_id("zed")
	var entry := McpJsonStrategy.build_entry(c, "http://x")
	assert_true(McpJsonStrategy.verify_entry(c, entry, "http://x"), "uvx entry should verify as a match")


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
	assert_true(args is Array, "bridge args must be an Array, got: %s" % args)
	var has_mcp_proxy := false
	for a in args:
		if a is String and (a as String).begins_with("mcp-proxy"):
			has_mcp_proxy = true
			break
	assert_true(has_mcp_proxy, "args must include an mcp-proxy entry, got: %s" % args)
	assert_contains(args, "--transport")
	assert_contains(args, "streamablehttp")
	assert_contains(args, expected_url)


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
	es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, McpClientConfigurator.DEFAULT_HTTP_PORT)
	es.set_setting(McpClientConfigurator.SETTING_WS_PORT, McpClientConfigurator.DEFAULT_WS_PORT)


func _restore_port_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if _saved_http_port == null:
		es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, McpClientConfigurator.DEFAULT_HTTP_PORT)
	else:
		es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, _saved_http_port)
	if _saved_ws_port == null:
		es.set_setting(McpClientConfigurator.SETTING_WS_PORT, McpClientConfigurator.DEFAULT_WS_PORT)
	else:
		es.set_setting(McpClientConfigurator.SETTING_WS_PORT, _saved_ws_port)
