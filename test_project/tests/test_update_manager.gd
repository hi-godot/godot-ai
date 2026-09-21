@tool
extends McpTestSuite

const Manager := preload("res://addons/godot_ai/utils/update_manager.gd")


class RedirectProbe extends Manager:
	var requested_url := ""
	var failure := ""

	func _request_active_asset(url: String) -> void:
		requested_url = url

	func _fail_download(reason: String) -> void:
		failure = reason


func test_manual_redirect_accepts_godot_redirect_limit_result() -> void:
	var target := "https://release-assets.githubusercontent.com/github-production-release-asset/1208239711/test"
	for code in [301, 302, 303, 307, 308]:
		var manager := RedirectProbe.new()
		manager._on_asset_completed(HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED, code,
			PackedStringArray(["Location: " + target]), PackedByteArray())
		assert_eq(manager.requested_url, target)
		assert_eq(manager._redirect_count, 1)
		assert_eq(manager.failure, "")
		manager.free()


func test_manual_redirect_still_rejects_unsafe_targets_and_excess_hops() -> void:
	for headers in [PackedStringArray(), PackedStringArray(["Location: http://github.com/x"]),
		PackedStringArray(["Location: https://evil.invalid/x"]),
		PackedStringArray(["Location: /relative"]),
		PackedStringArray(["Location: https://github.com/x", "Location: https://github.com/y"])]:
		var manager := RedirectProbe.new()
		manager._on_asset_completed(HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED, 302, headers, PackedByteArray())
		assert_eq(manager.requested_url, "")
		assert_eq(manager.failure, "untrusted or excessive redirect")
		manager.free()
	var exhausted := RedirectProbe.new()
	exhausted._redirect_count = Manager.MAX_REDIRECTS
	exhausted._on_asset_completed(HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED, 302,
		PackedStringArray(["Location: https://release-assets.githubusercontent.com/github-production-release-asset-1/test"]), PackedByteArray())
	assert_eq(exhausted.requested_url, "")
	assert_eq(exhausted.failure, "untrusted or excessive redirect")
	exhausted.free()


func test_manual_redirect_does_not_accept_other_transport_failures() -> void:
	for pair in [[HTTPRequest.RESULT_CANT_CONNECT, 302], [HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED, 200]]:
		var manager := RedirectProbe.new()
		manager._on_asset_completed(pair[0], pair[1], PackedStringArray(), PackedByteArray())
		assert_eq(manager.requested_url, "")
		assert_true(manager.failure.begins_with("download failed"))
		manager.free()


func suite_name() -> String:
	return "update_manager"


class DownloadProbe extends Manager:
	var downloads_started := 0

	func _download_next() -> void:
		downloads_started += 1


static func _candidate_release() -> Dictionary:
	return {
		"urls": {},
		"sizes": {},
		"channel": "stable",
		"tag": "v4.1.0",
		"version": "4.1.0",
	}


static func _record_states(manager: Manager) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	manager.install_state_changed.connect(func(state: Dictionary) -> void:
		states.append(state)
	)
	return states


## The plugin takes the update lock before the download and releases it, and
## resumes any quiesced client work, only when an install state says the
## install is over. A failure that stays silent about that leaves lock.json
## behind for the rest of the editor session (seen live after a 4.0.0
## "download failed (302)" on 2026-09-07).
func test_failed_download_reports_the_install_as_over() -> void:
	var manager := Manager.new()
	var states := _record_states(manager)
	manager._download_root = OS.get_user_data_dir().path_join("godot_ai_test_never_created")
	manager._fail_download("download failed (302)")
	assert_eq(states.size(), 1)
	assert_true(states[0].has("install_in_flight"), "a failed download must say the install is over")
	assert_false(bool(states[0]["install_in_flight"]))
	assert_false(bool(states[0]["button_disabled"]))
	assert_eq(manager._download_root, "")
	manager.free()


func test_refused_install_reports_the_install_as_over() -> void:
	for preflight in [{"ok": false}, {"ok": true, "download_root": "relative/path"}]:
		var manager := Manager.new()
		manager._release = _candidate_release()
		var states := _record_states(manager)
		manager.start_install(preflight)
		assert_eq(states.size(), 1, str(preflight))
		assert_true(states[0].has("install_in_flight"), str(preflight))
		assert_false(bool(states[0]["install_in_flight"]), str(preflight))
		manager.free()


func test_download_start_and_repeat_click_keep_the_install_in_flight() -> void:
	var root := OS.get_user_data_dir().path_join("godot_ai_test_download_root")
	assert_eq(DirAccess.make_dir_recursive_absolute(root), OK)
	var manager := DownloadProbe.new()
	manager._release = _candidate_release()
	var states := _record_states(manager)
	manager.start_install({"ok": true, "download_root": root})
	assert_eq(manager.downloads_started, 1)
	assert_eq(states.size(), 1)
	assert_true(bool(states[0].get("install_in_flight", false)), "Downloading must hold the lock")
	assert_true(bool(states[0]["button_disabled"]))
	## A second click while the first download is queued must not report the
	## install as over: that would release the lock under the running download.
	manager.start_install({"ok": true, "download_root": root})
	assert_eq(manager.downloads_started, 1)
	assert_eq(states.size(), 2)
	assert_true(bool(states[1].get("install_in_flight", true)))
	manager.free()
	DirAccess.remove_absolute(root)


static func _asset(name: String, size: int = 32) -> Dictionary:
	return {
		"name": name,
		"size": size,
		"browser_download_url": (
			"https://github.com/hi-godot/godot-ai/releases/download/v4.1.0/" + name
		),
	}


static func _response(assets: Array, tag: String = "v4.1.0") -> PackedByteArray:
	return JSON.stringify({"tag_name": tag, "assets": assets}).to_utf8_buffer()


static func _valid_assets() -> Array:
	return [
		_asset(Manager.ASSET_NAME, 4096),
		_asset(Manager.MANIFEST_NAME, 1024),
		_asset(Manager.SIGNATURE_NAME, 512),
		_asset(Manager.LEGACY_ASSET_NAME, 8192),
		_asset(Manager.LEGACY_CHECKSUM_NAME, 88),
		_asset(Manager.LEGACY_SIGNATURE_NAME, 512),
	]


func test_release_parser_accepts_exact_v4_and_migration_asset_set() -> void:
	var parsed := Manager.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, _response(_valid_assets()), "4.0.0"
	)
	assert_true(parsed.has_update)
	assert_eq(parsed.tag, "v4.1.0")
	assert_eq(parsed.version, "4.1.0")
	assert_eq(parsed.channel, "stable")
	assert_eq(parsed.urls.size(), 3)
	assert_eq(parsed.sizes[Manager.SIGNATURE_NAME], 512)


func test_release_parser_rejects_missing_duplicate_and_unknown_assets() -> void:
	var cases := [
		_valid_assets().slice(0, 5),
		[
			_valid_assets()[0], _valid_assets()[0], _valid_assets()[2],
			_valid_assets()[3], _valid_assets()[4], _valid_assets()[5],
		],
		[
			_valid_assets()[0], _valid_assets()[1], _valid_assets()[2],
			_valid_assets()[3], _valid_assets()[4], _asset("surprise.bin", 512),
		],
	]
	for assets in cases:
		var parsed := Manager.parse_releases_response(
			HTTPRequest.RESULT_SUCCESS, 200, _response(assets), "4.0.0"
		)
		assert_false(parsed.has_update, "non-exact release asset set must fail closed")


func test_release_parser_rejects_bad_size_url_status_and_tag() -> void:
	var bad_size := _valid_assets()
	bad_size[2] = _asset(Manager.SIGNATURE_NAME, 511)
	var bad_url := _valid_assets()
	bad_url[0] = _asset(Manager.ASSET_NAME, 4096)
	bad_url[0].browser_download_url = (
		"https://github.com/attacker/godot-ai/releases/download/v4.1.0/" + Manager.ASSET_NAME
	)
	for parsed in [
		Manager.parse_releases_response(HTTPRequest.RESULT_SUCCESS, 200, _response(bad_size), "4.0.0"),
		Manager.parse_releases_response(HTTPRequest.RESULT_SUCCESS, 200, _response(bad_url), "4.0.0"),
		Manager.parse_releases_response(HTTPRequest.RESULT_CANT_CONNECT, 200, _response(_valid_assets()), "4.0.0"),
		Manager.parse_releases_response(HTTPRequest.RESULT_SUCCESS, 500, _response(_valid_assets()), "4.0.0"),
		Manager.parse_releases_response(HTTPRequest.RESULT_SUCCESS, 200, _response(_valid_assets(), "v5.0.0"), "4.0.0"),
	]:
		assert_false(parsed.has_update)


func test_version_order_accepts_only_stable_v4_releases() -> void:
	assert_true(Manager._is_newer("4.1.0", "4.0.99"))
	assert_false(Manager._is_newer("4.1.0", "4.1.0"))
	assert_false(Manager._is_newer("4.1.0rc1", "4.0.0"))
	assert_false(Manager._is_newer("4.1", "4.0.0"))
	assert_false(Manager._is_newer("5.0.0", "4.0.0"))


func test_release_parser_rejects_oversized_metadata_before_decoding() -> void:
	var oversized := PackedByteArray()
	oversized.resize(Manager.MAX_RELEASE_METADATA_BYTES + 1)
	assert_false(Manager.parse_releases_response(
		HTTPRequest.RESULT_SUCCESS, 200, oversized, "4.0.0"
	).has_update)


func test_download_url_parser_rejects_spoofing_and_path_traversal() -> void:
	var valid := (
		"https://github.com/hi-godot/godot-ai/releases/download/v4.1.0/" + Manager.ASSET_NAME
	)
	assert_true(Manager._is_trusted_download_url(valid))
	assert_true(Manager._is_trusted_download_url(valid.replace("github.com", "github.com:443")))
	assert_true(Manager._is_trusted_download_url(valid + "?signed=%2Fcredential"))
	assert_true(Manager._is_trusted_download_url(
		"https://release-assets.githubusercontent.com/github-production-release-asset-1/x?sig=y"
	))
	assert_true(Manager._is_trusted_download_url(
		"https://release-assets.githubusercontent.com/github-production-release-asset/1208239711/x?sig=y"
	))
	for url in [
		"https://release-assets.githubusercontent.com/github-production-release-asset/999/x",
		"https://release-assets.githubusercontent.com/github-production-release-asset/12082397110/x",
		"http://github.com/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://github.com.evil.invalid/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://github.com@evil.invalid/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://attacker@github.com/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://GitHub.com/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://github.com:80/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://github.com:evil/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://github.com:443:443/hi-godot/godot-ai/releases/download/v4.1.0/x",
		"https://github.com/hi-godot/godot-ai/releases/download/v4.1.0/x#fragment",
		"https://github.com/hi-godot/godot-ai/releases/download/v4.1.0/x\nignored",
		"https://github.com/hi-godot/godot-ai/releases/download/../../evil/x",
		"https://github.com/hi-godot/godot-ai/releases/download/%2e%2e/evil/x",
	]:
		assert_false(Manager._is_trusted_download_url(url), url)


func test_redirect_parser_requires_one_trusted_absolute_location() -> void:
	var trusted := (
		"https://release-assets.githubusercontent.com/github-production-release-asset-1/x?sig=y"
	)
	assert_eq(Manager._redirect_url(PackedStringArray(["Location: " + trusted])), trusted)
	assert_eq(Manager._redirect_url(PackedStringArray(["location: " + trusted])), trusted)
	assert_eq(
		Manager._redirect_url(PackedStringArray(["Location: " + trusted, "Location: " + trusted])),
		"",
	)
	assert_false(Manager._is_trusted_download_url("/relative/location"))


func test_preflight_refusal_occurs_before_download_setup() -> void:
	var manager := Manager.new()
	manager._release = {
		"urls": {},
		"sizes": {},
		"channel": "stable",
		"tag": "v4.1.0",
		"version": "4.1.0",
	}
	manager.start_install({"ok": false})
	assert_true(manager._queue.is_empty())
	assert_true(manager._asset_request == null)
	manager.free()


func test_install_candidate_requires_a_release_and_no_retained_download_root() -> void:
	var manager := Manager.new()
	assert_false(manager.has_install_candidate())
	manager._release = {"has_update": true}
	assert_true(manager.has_install_candidate())
	manager._download_root = "/private/update-download"
	assert_false(manager.has_install_candidate())
	manager._download_root = ""
	manager.free()


func test_install_rejects_a_non_actor_download_root() -> void:
	var manager := Manager.new()
	manager._release = {
		"urls": {},
		"sizes": {},
		"channel": "stable",
		"tag": "v4.1.0",
		"version": "4.1.0",
	}
	manager.start_install({"ok": true, "download_root": "relative/path"})
	assert_true(manager._queue.is_empty())
	assert_eq(manager._download_root, "")
	assert_true(manager._asset_request == null)
	manager.free()


func test_download_path_accepts_only_the_exact_release_asset_set() -> void:
	var manager := Manager.new()
	manager._download_root = "/private/update-download"
	assert_eq(
		manager._download_path(Manager.ASSET_NAME),
		"/private/update-download/" + Manager.ASSET_NAME,
	)
	assert_eq(manager._download_path("../escape"), "")
	manager.free()


func test_failed_refresh_clears_a_previous_install_candidate() -> void:
	var manager := Manager.new()
	manager._release = {"has_update": true, "tag": "v4.1.0"}
	manager._on_check_completed(
		HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()
	)
	assert_true(manager._release.is_empty())
	manager.free()


func test_release_candidate_does_not_alias_emitted_view_model() -> void:
	var manager := Manager.new()
	var next_minor := int(McpClientConfigurator.get_plugin_version().get_slice(".", 1)) + 1
	var candidate_tag := "v4.%d.0" % next_minor
	var assets := _valid_assets()
	for asset in assets:
		asset.browser_download_url = str(asset.browser_download_url).replace("/v4.1.0/", "/%s/" % candidate_tag)
	var emissions: Array[Dictionary] = []
	manager.update_check_completed.connect(func(result: Dictionary) -> void:
		emissions.append(result)
	)
	manager._on_check_completed(
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray(),
		_response(assets, candidate_tag),
	)
	assert_true(bool(manager._release.get("has_update", false)))
	assert_eq(emissions.size(), 1)
	if not bool(manager._release.get("has_update", false)) or emissions.size() != 1:
		manager.free()
		return
	var emitted := emissions[0]
	var original_url := str(manager._release.urls[Manager.ASSET_NAME])
	emitted["tag"] = "mutated"
	emitted.urls[Manager.ASSET_NAME] = "https://attacker.invalid/payload"
	assert_eq(str(manager._release.tag), candidate_tag)
	assert_eq(str(manager._release.urls[Manager.ASSET_NAME]), original_url)
	manager.free()
