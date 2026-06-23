@tool
extends McpTestSuite

## Tests for McpUpdateManager. Pins four contracts:
##   1. parse_releases_response fixture-in / status-out
##   2. forced-mode (mode_override == "user") label hint
##   3. install-in-flight gate (cleared on success / failure paths)
##   4. handoff to plugin.install_downloaded_update (worker drain + call)
##
## End-to-end click-Update is exercised by `script/local-self-update-smoke`.

const McpUpdateManagerScript := preload(
	"res://addons/godot_ai/utils/update_manager.gd"
)
const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")
const McpDockScript := preload("res://addons/godot_ai/mcp_dock.gd")

const TEST_ASSET_NAME := "godot-ai-plugin.zip"
const TEST_ASSET_URL := "https://github.com/hi-godot/godot-ai/releases/download/v999.0.0/godot-ai-plugin.zip"


func suite_name() -> String:
	return "update_manager"


# ---- _version_can_self_update (pure / static, #475 gate) ---------------

func test_version_can_self_update_false_below_4_4() -> void:
	## Godot < 4.4 takes the extract-then-restart path that crashes (#475),
	## so the in-editor self-update is gated off on those engines.
	assert_false(McpUpdateManagerScript._version_can_self_update(4, 3),
		"4.3 must be gated (in-editor self-update disabled)")
	assert_false(McpUpdateManagerScript._version_can_self_update(4, 0),
		"4.0 must be gated")
	assert_false(McpUpdateManagerScript._version_can_self_update(3, 9),
		"a hypothetical 3.x must be gated")


func test_version_can_self_update_true_at_and_above_4_4() -> void:
	assert_true(McpUpdateManagerScript._version_can_self_update(4, 4),
		"4.4 is the first engine that can self-update in place")
	assert_true(McpUpdateManagerScript._version_can_self_update(4, 6),
		"4.6 can self-update")
	assert_true(McpUpdateManagerScript._version_can_self_update(5, 0),
		"a future 5.0 (minor 0) must not be misclassified by the minor check")


func test_manual_update_label_includes_version_and_guidance() -> void:
	## Shown up-front on < 4.4 (before any click) so the user understands the
	## manual-update flow. Must name the version and the 4.4+ requirement.
	var with_v := McpUpdateManagerScript._manual_update_label("2.5.7")
	assert_contains(with_v, "2.5.7", "label must name the available version")
	assert_contains(with_v, "Godot 4.4+", "label must state the engine requirement")
	assert_contains(with_v, "addons/godot_ai/", "label must point at the manual-swap path")


func test_manual_update_label_omits_version_when_unknown() -> void:
	## On the click path the version isn't re-threaded; the label degrades to
	## a generic "Update available" without a stray "v" token.
	var no_v := McpUpdateManagerScript._manual_update_label("")
	assert_contains(no_v, "Update available", "generic label must still lead with 'Update available'")
	assert_false(no_v.contains(" v"), "no version token when version is empty")
	assert_contains(no_v, "Godot 4.4+", "label must still state the engine requirement")


# ---- _is_safe_zip_addon_file (pure / static, #522) --------------------

func test_safe_zip_addon_file_accepts_normal_entries() -> void:
	## The inline (pre-4.4) extract path validates every entry with the same
	## guard the runner enforces, so ordinary addon files must pass.
	assert_true(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/godot_ai/plugin.gd"),
		"a top-level addon file must be accepted")
	assert_true(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/godot_ai/utils/settings.gd"),
		"a nested addon file must be accepted")


func test_safe_zip_addon_file_rejects_traversal_and_escapes() -> void:
	## These are exactly the shapes the prefix-only check used to let through
	## onto a path_join + write (#522).
	assert_false(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/godot_ai/../../evil.gd"),
		"`..` segments must be rejected — they escape the addon dir")
	assert_false(
		McpUpdateManagerScript._is_safe_zip_addon_file("/etc/passwd"),
		"absolute paths must be rejected")
	assert_false(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/godot_ai/foo\\..\\bar.gd"),
		"backslashes must be rejected (Windows-style traversal)")
	assert_false(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/other/file.gd"),
		"entries outside addons/godot_ai/ must be rejected")
	assert_false(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/godot_ai/"),
		"the bare prefix (dir entry) must be rejected as a file")
	assert_false(
		McpUpdateManagerScript._is_safe_zip_addon_file("addons/godot_ai/a//b.gd"),
		"empty path segments must be rejected")


# ---- _is_trusted_download_url (pure / static, #523) -------------------

func test_trusted_download_url_accepts_github_hosts() -> void:
	assert_true(
		McpUpdateManagerScript._is_trusted_download_url(TEST_ASSET_URL),
		"a normal github.com release asset URL must be trusted")
	assert_true(
		McpUpdateManagerScript._is_trusted_download_url(
			"https://objects.githubusercontent.com/github-production-release/x.zip"),
		"the githubusercontent redirect target host must be trusted")


func test_trusted_download_url_rejects_untrusted_and_insecure() -> void:
	assert_false(
		McpUpdateManagerScript._is_trusted_download_url(
			"http://github.com/hi-godot/godot-ai/releases/download/v1/godot-ai-plugin.zip"),
		"plain http must be rejected even on a github host")
	assert_false(
		McpUpdateManagerScript._is_trusted_download_url("https://example.invalid/payload.zip"),
		"a non-github host must be rejected")
	assert_false(
		McpUpdateManagerScript._is_trusted_download_url("https://github.com.evil.com/x.zip"),
		"a look-alike host suffix must be rejected")
	assert_false(
		McpUpdateManagerScript._is_trusted_download_url("https://github.com@evil.com/x.zip"),
		"userinfo spoofing (host is after the last @) must be rejected")
	assert_false(
		McpUpdateManagerScript._is_trusted_download_url(""),
		"an empty URL must be rejected")


# ---- _parse_sha256_digest (pure / static, #523) ----------------------

func test_parse_sha256_digest_accepts_sha256sum_line() -> void:
	## `sha256sum godot-ai-plugin.zip` emits "<hex>  <name>"; only the digest
	## is used.
	var hex := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	var parsed := McpUpdateManagerScript._parse_sha256_digest(hex + "  godot-ai-plugin.zip\n")
	assert_eq(parsed, hex, "must extract the digest from a sha256sum line")


func test_parse_sha256_digest_accepts_bare_and_uppercase_digest() -> void:
	var hex := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	assert_eq(McpUpdateManagerScript._parse_sha256_digest(hex), hex,
		"a bare digest line must be accepted")
	assert_eq(McpUpdateManagerScript._parse_sha256_digest(hex.to_upper()), hex,
		"an uppercase digest must be normalized to lowercase")


func test_parse_sha256_digest_rejects_malformed() -> void:
	assert_eq(McpUpdateManagerScript._parse_sha256_digest(""), "",
		"empty content must be rejected")
	assert_eq(McpUpdateManagerScript._parse_sha256_digest("deadbeef"), "",
		"a too-short digest must be rejected")
	assert_eq(
		McpUpdateManagerScript._parse_sha256_digest(
			"z3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
		"",
		"a non-hex character must be rejected")


func test_parse_sha256_digest_matches_fileaccess_hash() -> void:
	## End-to-end: the digest the plugin parses from a sha256sum line must
	## equal what FileAccess.get_sha256 produces for the same bytes — the
	## exact comparison _on_checksum_completed makes before extracting.
	var path := "user://_test_checksum_target.bin"
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "seed file must open for write")
	f.store_string("godot-ai self-update integrity test payload")
	f.close()

	var real := FileAccess.get_sha256(path).to_lower()
	var sidecar_line := "%s  godot-ai-plugin.zip\n" % real
	var parsed := McpUpdateManagerScript._parse_sha256_digest(sidecar_line)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	assert_eq(parsed, real,
		"parsed sidecar digest must match FileAccess.get_sha256 (the verify compare)")


# ---- parse_releases_response (pure / static) ---------------------------

func _make_body(json_str: String) -> PackedByteArray:
	return json_str.to_utf8_buffer()


func _make_release_payload(tag: String) -> String:
	return JSON.stringify({
		"tag_name": tag,
		"assets": [{
			"name": TEST_ASSET_NAME,
			"browser_download_url": TEST_ASSET_URL,
		}]
	})


func test_parse_releases_response_no_update_when_remote_equals_local() -> void:
	## Remote == local should leave `has_update` false so the dock keeps
	## the banner hidden. Otherwise we'd re-offer "update" to the same
	## version on every focus-in.
	var local := McpClientConfigurator.get_plugin_version()
	var body := _make_body(_make_release_payload("v" + local))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	assert_false(bool(result.get("has_update", true)),
		"Equal remote/local versions must not flag an update")


func test_parse_releases_response_yes_update_when_remote_newer() -> void:
	## A bumped major guarantees newer than whatever the plugin ships at.
	var body := _make_body(_make_release_payload("v999.0.0"))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	assert_true(bool(result.get("has_update", false)),
		"Remote version > local must flag an update")
	assert_eq(String(result.get("version", "")), "999.0.0",
		"Returned version must strip the leading 'v' from the tag")
	assert_eq(String(result.get("download_url", "")), TEST_ASSET_URL,
		"Asset URL must be the matching godot-ai-plugin.zip download")
	assert_contains(String(result.get("label_text", "")), "Update available",
		"Label text must lead with 'Update available' for the dock to render")
	assert_contains(String(result.get("label_text", "")), "999.0.0",
		"Label text must include the version")


func test_parse_releases_response_handles_http_failure() -> void:
	## Non-200 (rate limit, offline, etc.) must surface `has_update: false`
	## without throwing. The dock leaves the banner hidden on failure.
	var body := _make_body("")
	var failed := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_CANT_CONNECT, 0, body
	)
	assert_false(bool(failed.get("has_update", true)),
		"Connect failure must not flag an update")
	var rate_limited := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 403, body
	)
	assert_false(bool(rate_limited.get("has_update", true)),
		"Rate-limited 403 must not flag an update")


func test_parse_releases_response_handles_malformed_json() -> void:
	## A 200 with a non-JSON body must leave `has_update: false`. JSON
	## parsing failures used to fall through to a NPE in the dock.
	var body := _make_body("not actually json")
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	assert_false(bool(result.get("has_update", true)),
		"Malformed JSON must not flag an update")


func test_parse_releases_response_captures_checksum_asset_url() -> void:
	## The release ships a `godot-ai-plugin.zip.sha256` sidecar; its URL must
	## be surfaced so the installer can verify integrity before extract (#523).
	var checksum_url := TEST_ASSET_URL + ".sha256"
	var body := _make_body(JSON.stringify({
		"tag_name": "v999.0.0",
		"assets": [
			{"name": TEST_ASSET_NAME, "browser_download_url": TEST_ASSET_URL},
			{"name": TEST_ASSET_NAME + ".sha256", "browser_download_url": checksum_url},
		],
	}))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	assert_eq(String(result.get("download_url", "")), TEST_ASSET_URL,
		"zip asset URL must still resolve when a checksum sidecar is present")
	assert_eq(String(result.get("checksum_url", "")), checksum_url,
		"the .sha256 sidecar URL must be captured")


func test_parse_releases_response_checksum_empty_when_absent() -> void:
	## Older releases without a sidecar must leave checksum_url empty so the
	## installer takes the verify-if-present (skip) path rather than failing.
	var body := _make_body(_make_release_payload("v999.0.0"))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	assert_eq(String(result.get("checksum_url", "")), "",
		"no sidecar asset must yield an empty checksum_url")


func test_parse_releases_response_missing_asset_returns_empty_url() -> void:
	## Some manual tag pushes ship without a `godot-ai-plugin.zip` asset.
	## The dock then falls back to opening the release page (the manager
	## checks `download_url.is_empty()` in `start_install`).
	var body := _make_body(JSON.stringify({
		"tag_name": "v999.0.0",
		"assets": [{
			"name": "some-other-asset.tar.gz",
			"browser_download_url": "https://example.invalid/other.tar.gz",
		}]
	}))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	assert_true(bool(result.get("has_update", false)),
		"Newer version still flags an update even when the asset is missing")
	assert_eq(String(result.get("download_url", "")), "",
		"Missing godot-ai-plugin.zip asset must surface an empty download URL")


# ---- forced-mode label hint --------------------------------------------

func _force_mode_override(value: String) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, value)


func _restore_mode_override(prior_value: String) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, prior_value)


func _read_mode_override() -> String:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING):
		return ""
	return str(es.get_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING))


func test_label_includes_forced_hint_when_user_mode_override_active() -> void:
	## Mode-override resolution lives on `McpClientConfigurator`. The
	## manager mirrors the dock's old behaviour: when `mode_override()`
	## returns "user" the label gets a " (forced)" suffix so testers
	## driving `GODOT_AI_MODE=user` from a dev tree don't forget the
	## banner is only painting because of the override.
	var prior := _read_mode_override()
	_force_mode_override("user")
	var body := _make_body(_make_release_payload("v999.0.0"))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	_restore_mode_override(prior)

	assert_true(bool(result.get("forced", false)),
		"forced flag must be true when mode_override == 'user'")
	assert_contains(String(result.get("label_text", "")), "(forced)",
		"Label text must carry the forced hint when mode_override == 'user'")


func test_label_skips_forced_hint_in_auto_mode() -> void:
	## In Auto mode (no override active) the label must not carry the
	## forced hint — that's reserved for the dropdown / env-var
	## "Force user" path so the dock label doesn't lie about how the
	## banner was reached.
	var prior := _read_mode_override()
	_force_mode_override("")
	var body := _make_body(_make_release_payload("v999.0.0"))
	var result := McpUpdateManagerScript.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, body
	)
	_restore_mode_override(prior)

	## In Auto mode + dev checkout, mode_override() == "". `forced` mirrors
	## that. (The .venv-proximity heuristic doesn't enter the parse path —
	## it's only consulted by `is_dev_checkout()` upstream of `check_for_updates`.)
	assert_false(bool(result.get("forced", true)),
		"forced flag must be false when no override is active")
	assert_false(String(result.get("label_text", "")).contains("(forced)"),
			"Label text must not carry the forced hint in Auto mode")


# ---- install-in-flight gate --------------------------------------------

func test_install_in_flight_default_false() -> void:
	var manager = McpUpdateManagerScript.new()
	assert_false(manager.is_install_in_flight(),
		"A fresh manager must default to is_install_in_flight() == false")
	manager.free()


# ---- handoff to plugin.install_downloaded_update -----------------------

class _RecordingPlugin extends GodotAiPlugin:
	var install_calls: Array = []
	var prepare_calls: int = 0

	func install_downloaded_update(zip_path: String, temp_dir: String, source_dock) -> void:
		install_calls.append({
			"zip_path": zip_path,
			"temp_dir": temp_dir,
			"source_dock": source_dock,
		})
		# Don't call into the real install flow — that would reload the plugin
		# mid-test. Just record the args; the unit asserts on those.

	func prepare_for_update_reload() -> void:
		prepare_calls += 1


class _DrainRecordingDock extends Node:
	var refresh_drain_calls: int = 0
	var action_drain_calls: int = 0

	func _drain_client_status_refresh_workers() -> void:
		refresh_drain_calls += 1

	func _drain_client_action_workers() -> void:
		action_drain_calls += 1


func test_install_zip_drains_dock_workers_and_hands_off_to_plugin() -> void:
	## In a 4.4+ editor with a runner-capable plugin, the manager must:
	##   1. Set _install_in_flight = true so dock spawn paths gate.
	##   2. Drain the dock's two worker pools (refresh + action) BEFORE
	##      handing off to the plugin — otherwise a worker mid-call into
	##      a script the runner is about to overwrite SIGABRTs in
	##      GDScriptFunction::call.
	##   3. Call plugin.install_downloaded_update with the manager's temp
	##      paths + the dock as the source_dock argument (the plugin uses
	##      that to detach the visible dock before extracting).
	## Skip on older Godot — the runner path is gated on minor >= 4.
	var version := Engine.get_version_info()
	if int(version.get("minor", 0)) < 4:
		skip("Runner-based handoff requires Godot 4.4+")
		return
	## Symlink check is independent of the mode override and aborts the
	## install before the drain runs. In a dev checkout
	## `test_project/addons/godot_ai` is a symlink, so this test is
	## meaningless there. Skip rather than assert the no-op path — that's
	## already covered by `test_install_zip_aborts_on_symlinked_addons_dir`.
	if McpClientConfigurator.addons_dir_is_symlink():
		skip("Skipping handoff test in a symlinked dev checkout")
		return

	var plugin := _RecordingPlugin.new()
	var dock := _DrainRecordingDock.new()
	var manager = McpUpdateManagerScript.new()
	manager.setup(plugin, dock)
	manager._install_zip()

	var refresh_calls := dock.refresh_drain_calls
	var action_calls := dock.action_drain_calls
	var install_calls := plugin.install_calls.duplicate()
	var was_in_flight := manager.is_install_in_flight()

	manager.free()
	dock.free()
	plugin.free()

	assert_true(was_in_flight,
		"_install_zip must set is_install_in_flight() before draining")
	assert_eq(refresh_calls, 1,
		"refresh-worker drain must run once before plugin handoff")
	assert_eq(action_calls, 1,
		"action-worker drain must run once before plugin handoff")
	assert_eq(install_calls.size(), 1,
		"plugin.install_downloaded_update must be called exactly once")
	var args: Dictionary = install_calls[0]
	assert_eq(String(args.get("zip_path", "")),
		McpUpdateManagerScript.UPDATE_TEMP_ZIP,
		"Manager's UPDATE_TEMP_ZIP path must match plugin handoff arg")
	assert_eq(String(args.get("temp_dir", "")),
		McpUpdateManagerScript.UPDATE_TEMP_DIR,
		"Manager's UPDATE_TEMP_DIR path must match plugin handoff arg")
	assert_true(args.get("source_dock") == dock,
		"Plugin must receive the dock reference so it can detach the docked control")


func test_install_zip_aborts_on_symlinked_addons_dir() -> void:
	## addons_dir_is_symlink is the data-safety guard that prevents the
	## extract from clobbering canonical `plugin/` source through a
	## symlinked `test_project/addons/godot_ai`. The check is independent
	## of the mode override — even forced-user mode bails here.
	if not McpClientConfigurator.addons_dir_is_symlink():
		skip("Skipping symlink-bail test in a non-dev install")
		return

	var plugin := _RecordingPlugin.new()
	var dock := _DrainRecordingDock.new()
	var manager = McpUpdateManagerScript.new()
	manager.setup(plugin, dock)

	## Use an Array (reference type) to capture signal payloads — GDScript
	## lambdas can mutate the array via `.append()`, but a `var =` rebind
	## inside the lambda doesn't propagate to the outer Dictionary.
	var captured_states: Array = []
	manager.install_state_changed.connect(func(state: Dictionary) -> void:
		captured_states.append(state)
	)
	manager._install_zip()

	var was_in_flight := manager.is_install_in_flight()
	var refresh_calls := dock.refresh_drain_calls
	var install_calls := plugin.install_calls.size()

	manager.free()
	dock.free()
	plugin.free()

	assert_false(was_in_flight,
		"Symlink bail must NOT flip is_install_in_flight() — that gate is for the actual install window only")
	assert_eq(refresh_calls, 0,
		"Symlink bail must NOT drain dock workers — nothing's about to overwrite scripts")
	assert_eq(install_calls, 0,
		"Symlink bail must NOT call plugin.install_downloaded_update")
	assert_eq(captured_states.size(), 1,
		"Manager must emit exactly one install_state_changed event on the symlink-bail path")
	var captured_state: Dictionary = captured_states[0]
	assert_eq(bool(captured_state.get("banner_visible", true)), false,
		"Symlink bail must hide the banner — the user can't act on it from a dev tree")
	assert_eq(String(captured_state.get("button_text", "")), "Dev checkout — update via git",
		"Symlink bail must paint the dev-checkout fallback button text")
	assert_eq(bool(captured_state.get("button_disabled", false)), true,
		"Symlink bail must disable the Update button so the user can't retry")


func test_clear_pending_download_resets_to_no_url_state() -> void:
	## Mode-override flips reach into the manager via clear_pending_download
	## so a fresh check paints over a clean banner. Without the reset, a
	## dropdown flip from "Force user" → "Auto" in a dev tree would leave
	## a stale download URL armed.
	var manager = McpUpdateManagerScript.new()
	manager._latest_download_url = TEST_ASSET_URL
	assert_eq(manager._latest_download_url, TEST_ASSET_URL,
		"Seed: manager must hold the download URL we just set")
	manager.clear_pending_download()
	assert_eq(manager._latest_download_url, "",
		"clear_pending_download must drop the cached URL")
	manager.free()


# ---- mode-override resolution: precedence -----------------------------

func test_mode_override_dropdown_wins_over_env() -> void:
	## The dock dropdown writes to EditorSettings; that wins over the env
	## var so a UI flip takes effect immediately without relaunching. The
	## .venv-proximity heuristic only runs when neither knob is set.
	## This is the contract the dock relies on — manager just reads
	## `McpClientConfigurator.mode_override()`, but the precedence is part
	## of the seam shape.
	var prior := _read_mode_override()
	_force_mode_override("user")
	## Even if GODOT_AI_MODE=dev is set in the environment, the dropdown
	## value should win. We don't actually mutate env from a test (CI
	## inherits its own env), so just confirm dropdown=user resolves to
	## "user" regardless of the surrounding env.
	var resolved := McpClientConfigurator.mode_override()
	_restore_mode_override(prior)
	assert_eq(resolved, "user",
		"Dropdown override must resolve to 'user' regardless of env")
