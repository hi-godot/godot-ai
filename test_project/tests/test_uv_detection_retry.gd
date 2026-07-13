@tool
extends McpTestSuite

## Tests for the #739 fix: a `uvx --version` probe that fails once at
## editor startup must not pin "uv: not found" for the whole session.
## Covers the new ClientConfigurator helpers (uv_probe_negative /
## invalidate_uv_detection) and the dock's _reprobe_uv_if_negative wiring
## (server-connect transition + manual Refresh click).
##
## The configurator caches are session-global statics shared with the
## live editor session running these tests, so every test snapshots and
## restores them — including McpCliFinder's per-exe entries for the uvx
## binary names.

const McpDockScript = preload("res://addons/godot_ai/mcp_dock.gd")

const UVX_NAMES := ["uvx", "uvx.exe"]

var _orig_version_cache: String
var _orig_version_searched: bool
var _orig_finder_cache := {}
var _orig_finder_searched := {}


func suite_name() -> String:
	return "uv_detection_retry"


func setup() -> void:
	_orig_version_cache = McpClientConfigurator._uv_version_cache
	_orig_version_searched = McpClientConfigurator._uv_version_searched
	_orig_finder_cache.clear()
	_orig_finder_searched.clear()
	for name in UVX_NAMES:
		if McpCliFinder._cache.has(name):
			_orig_finder_cache[name] = McpCliFinder._cache[name]
		if McpCliFinder._searched.has(name):
			_orig_finder_searched[name] = McpCliFinder._searched[name]


func teardown() -> void:
	McpClientConfigurator._uv_version_cache = _orig_version_cache
	McpClientConfigurator._uv_version_searched = _orig_version_searched
	for name in UVX_NAMES:
		if _orig_finder_cache.has(name):
			McpCliFinder._cache[name] = _orig_finder_cache[name]
		else:
			McpCliFinder._cache.erase(name)
		if _orig_finder_searched.has(name):
			McpCliFinder._searched[name] = _orig_finder_searched[name]
		else:
			McpCliFinder._searched.erase(name)


func _seed_negative_probe() -> void:
	McpClientConfigurator._uv_version_searched = true
	McpClientConfigurator._uv_version_cache = ""
	## Seed only the names this platform actually resolves ("uvx.exe" on
	## Windows, "uvx" everywhere else) — invalidation deliberately targets
	## the platform-specific cache keys, so foreign-platform entries would
	## survive and fail the assertions below without ever mattering live.
	for name in McpClientConfigurator._uvx_cli_names():
		McpCliFinder._cache[name] = ""
		McpCliFinder._searched[name] = true


func _seed_positive_probe() -> void:
	McpClientConfigurator._uv_version_searched = true
	McpClientConfigurator._uv_version_cache = "uv 9.9.9"


# ----- ClientConfigurator helpers -----

func test_probe_negative_false_before_any_probe() -> void:
	McpClientConfigurator._uv_version_searched = false
	McpClientConfigurator._uv_version_cache = ""
	assert_false(McpClientConfigurator.uv_probe_negative())


func test_probe_negative_false_when_uv_found() -> void:
	_seed_positive_probe()
	assert_false(McpClientConfigurator.uv_probe_negative())


func test_probe_negative_true_after_failed_probe() -> void:
	_seed_negative_probe()
	assert_true(McpClientConfigurator.uv_probe_negative())


func test_invalidate_uv_detection_clears_both_caches() -> void:
	_seed_negative_probe()

	McpClientConfigurator.invalidate_uv_detection()

	assert_false(
		McpClientConfigurator._uv_version_searched,
		"version cache must be re-probed on next check"
	)
	for name in McpClientConfigurator._uvx_cli_names():
		assert_false(
			McpCliFinder._searched.has(name),
			"CliFinder entry for %s must be dropped so the path is re-resolved" % name
		)


# ----- dock reprobe helper -----

class _UiSpyDock extends McpDockScript:
	var setup_refreshes := 0
	var visibility_applies := 0

	func _refresh_setup_status() -> void:
		setup_refreshes += 1

	func _apply_dev_mode_visibility() -> void:
		visibility_applies += 1


func test_reprobe_noop_when_uv_already_found() -> void:
	_seed_positive_probe()
	var dock := _UiSpyDock.new()

	dock._reprobe_uv_if_negative()

	assert_true(
		McpClientConfigurator._uv_version_searched,
		"positive probe result must stay cached — no re-probe"
	)
	assert_eq(dock.setup_refreshes, 0, "no UI rebuild when nothing changed")
	dock.free()


func test_reprobe_invalidates_and_rerenders_when_negative() -> void:
	_seed_negative_probe()
	var dock := _UiSpyDock.new()

	dock._reprobe_uv_if_negative()

	assert_false(
		McpClientConfigurator._uv_version_searched,
		"negative probe result must be dropped for re-detection"
	)
	assert_eq(dock.setup_refreshes, 1, "setup section must re-render")
	assert_eq(dock.visibility_applies, 1, "section visibility must be recomputed")
	dock.free()


# ----- dock wiring: connect transition + Refresh click -----

class _ReprobeSpyDock extends McpDockScript:
	var reprobe_calls := 0
	var client_refresh_calls := 0

	func _reprobe_uv_if_negative() -> void:
		reprobe_calls += 1

	func _request_client_status_refresh(_force: bool = false) -> bool:
		client_refresh_calls += 1
		return true


class _ConnectionStub:
	var is_connected := true
	var server_version := ""


func test_update_status_reprobes_only_on_connect_transition() -> void:
	var dock := _ReprobeSpyDock.new()
	dock._build_ui()
	dock._connection = _ConnectionStub.new()

	dock._update_status()
	assert_eq(dock.reprobe_calls, 1, "disconnected -> connected must reprobe")

	dock._update_status()
	assert_eq(dock.reprobe_calls, 1, "steady connected state must not reprobe")

	dock._connection.is_connected = false
	dock._update_status()
	assert_eq(dock.reprobe_calls, 1, "disconnect must not reprobe")

	dock._connection.is_connected = true
	dock._update_status()
	assert_eq(dock.reprobe_calls, 2, "reconnect must reprobe again")
	dock.free()


func test_refresh_click_reprobes_uv() -> void:
	var dock := _ReprobeSpyDock.new()

	dock._on_refresh_clients_pressed()

	assert_eq(dock.reprobe_calls, 1, "manual Refresh must give uv another chance")
	assert_eq(dock.client_refresh_calls, 1, "client sweep must still run")
	dock.free()
