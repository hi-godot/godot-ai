@tool
class_name McpUpdateManager
extends Node

## Owns the self-update flow extracted from `mcp_dock.gd`. The dock keeps the
## visible banner + button + label and the "Run this manually" fallback
## rendering; this manager owns:
##   - GitHub Releases API check (HTTPRequest fan-out, `RELEASES_URL`)
##   - ZIP download (HTTPRequest with `download_file`)
##   - Mode-override resolution (delegates to `McpClientConfigurator`, which
##     already implements dropdown > GODOT_AI_MODE > .venv-proximity)
##   - `_install_update` orchestration: drain workers → call back into
##     `plugin.install_downloaded_update()` (4.4+, the runner path) or run
##     the in-process extract fallback (4.3 and older)
##   - The `_self_update_in_progress` gate — callers (the dock's refresh /
##     action spawn paths) consult `is_install_in_flight()` instead of
##     reading a private field on the dock
##
## Plugin lifecycle internals (`prepare_for_update_reload`,
## `install_downloaded_update`) stay on `plugin.gd`; the manager invokes
## them via the injected plugin reference. Worker drains stay on the dock —
## the manager calls back via the injected dock reference because the
## per-worker thread state lives there.
##
## `_plugin` and `_dock` are untyped to honor the same self-update parse-
## hazard policy `plugin.gd` and `server_lifecycle.gd` use for `_host` —
## typed Variant fields hot-reload-crash when this script is one of the
## live ones during install.

const UPDATE_RELOAD_RUNNER_SCRIPT := preload(
	"res://addons/godot_ai/update_reload_runner.gd"
)

const RELEASES_URL := (
	"https://api.github.com/repos/hi-godot/godot-ai/releases/latest"
)
const RELEASES_PAGE := "https://github.com/hi-godot/godot-ai/releases/latest"
const UPDATE_TEMP_DIR := "user://godot_ai_update/"
const UPDATE_TEMP_ZIP := "user://godot_ai_update/update.zip"

## Emitted after `check_for_updates()` completes with a newer remote version
## available. Payload is the Dictionary returned by `parse_releases_response`:
##   {has_update: bool, version: String, forced: bool, label_text: String,
##    download_url: String}
## The dock translates the payload into banner visibility + label colour.
signal update_check_completed(result: Dictionary)

## Emitted at every UI-relevant step of the install pipeline. Payload keys
## are all optional — the dock only repaints the field if it's present:
##   phase: String                   ## "downloading" / "installing" / etc.
##   label_text: String              ## banner label override
##   label_color: Color              ## banner label colour override
##   button_text: String             ## update button text override
##   button_disabled: bool           ## update button disabled state
##   banner_visible: bool            ## banner visibility override
signal install_state_changed(state: Dictionary)

var _plugin
var _dock

var _http_request: HTTPRequest
var _download_request: HTTPRequest
var _latest_download_url: String = ""

## Set for the duration of `_install_update` — extract-overwrite of plugin
## scripts on disk would crash any worker mid-`GDScriptFunction::call`
## (confirmed via SIGABRT in `VBoxContainer(McpDock)::_run_client_status_refresh_worker`).
## Dock spawn paths (focus-in, manual button, deferred initial refresh)
## consult this via `is_install_in_flight()`; the in-flight worker is
## drained at start of install via `_drain_dock_workers()`.
var _install_in_flight: bool = false


# ---- Setup -------------------------------------------------------------

func setup(plugin, dock) -> void:
	_plugin = plugin
	_dock = dock


# ---- Public API ---------------------------------------------------------

## Kick off the GitHub Releases API check. No-ops in dev checkouts (per the
## mode override resolved via `McpClientConfigurator.is_dev_checkout()`).
## On a positive result, emits `update_check_completed`.
func check_for_updates() -> void:
	## In a dev checkout `addons/godot_ai/` is a symlink into the canonical
	## `plugin/` tree, so `FileAccess.open(..., WRITE)` during self-update
	## follows the symlink and overwrites the user's source files in place.
	## Devs update via `git pull`, not the dock — skip the GitHub check
	## entirely to avoid even offering the destructive path. See #116.
	##
	## `is_dev_checkout()` honours the mode override (dock dropdown first,
	## then `GODOT_AI_MODE` env var), so testers can force `user` mode to
	## exercise the AssetLib update flow from inside a dev tree.
	## `start_install` still gates on the physical symlink check, so a
	## forced-user mode can never clobber source.
	if McpClientConfigurator.is_dev_checkout():
		return
	if _http_request == null:
		_http_request = HTTPRequest.new()
		_http_request.request_completed.connect(_on_update_check_completed)
		add_child(_http_request)
	_http_request.request(RELEASES_URL, ["Accept: application/vnd.github+json"])


## Cancel any in-flight check request. The dock calls this before re-
## issuing a check after a mode-override flip — without the cancel, the
## next `_http_request.request()` returns ERR_BUSY and the dropdown change
## silently fails to repaint the banner.
func cancel_check() -> void:
	if _http_request != null:
		_http_request.cancel_request()


## Returns true when a prior `update_check_completed` payload carried a
## resolvable `download_url`. The dock uses this to decide between
## triggering the install pipeline vs falling back to opening the release
## page when the user clicks Update.
func has_pending_download_url() -> bool:
	return not _latest_download_url.is_empty()


## Reset to the no-pending-update state. Called by the dock when the mode
## override flips and we want a fresh check to paint over a clean slate.
func clear_pending_download() -> void:
	_latest_download_url = ""


## Stable URL for the manual fallback ("Release notes" button on the dock,
## and the implicit fallback inside `start_install` when no asset URL was
## resolved during the check).
func get_releases_page_url() -> String:
	return RELEASES_PAGE


## Driven by the dock's Update button. If we don't have a download URL —
## either the check never completed, or the release didn't ship a matching
## asset — open the release page in the browser as a fallback. Otherwise
## kick off the download → extract → reload pipeline.
func start_install() -> void:
	if _latest_download_url.is_empty():
		OS.shell_open(RELEASES_PAGE)
		return

	install_state_changed.emit({
		"phase": "downloading",
		"button_text": "Downloading...",
		"button_disabled": true,
	})

	if _download_request != null:
		_download_request.queue_free()
	_download_request = HTTPRequest.new()
	var global_zip := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	var global_dir := ProjectSettings.globalize_path(UPDATE_TEMP_DIR)
	DirAccess.make_dir_recursive_absolute(global_dir)
	_download_request.download_file = global_zip
	_download_request.max_redirects = 10
	_download_request.request_completed.connect(_on_download_completed)
	add_child(_download_request)
	var err := _download_request.request(_latest_download_url)
	if err != OK:
		install_state_changed.emit({
			"phase": "request_failed",
			"button_text": "Request failed",
			"button_disabled": false,
		})


## Called by dock spawn paths (focus-in refresh, manual button, deferred
## initial refresh) to gate worker spawning while plugin scripts are being
## overwritten on disk. See `_install_update` for the SIGABRT this guards
## against.
func is_install_in_flight() -> bool:
	return _install_in_flight


# ---- Releases-API parse (pure, testable) -------------------------------

## Parses the GitHub Releases API JSON response. Returns a Dictionary with
## keys:
##   has_update: bool                ## true if remote tag > local version
##   version: String                 ## remote tag minus leading "v"
##   forced: bool                    ## mode_override() == "user" (banner-only hint)
##   label_text: String              ## "Update available: vX.Y.Z" + " (forced)"
##   download_url: String            ## matching `godot-ai-plugin.zip` asset URL
##
## Static so tests can drive it without instancing the manager. The dock
## branch on the result (`has_update == false` → keep banner hidden).
static func parse_releases_response(
	result: int, response_code: int, body: PackedByteArray
) -> Dictionary:
	var out := {
		"has_update": false,
		"version": "",
		"forced": false,
		"label_text": "",
		"download_url": "",
	}
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return out
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary):
		return out
	var json: Dictionary = parsed
	var tag: String = String(json.get("tag_name", ""))
	if tag.is_empty():
		return out
	var remote_version := tag.trim_prefix("v")
	var local_version := McpClientConfigurator.get_plugin_version()
	if not _is_newer(remote_version, local_version):
		return out

	var url := ""
	var assets: Array = json.get("assets", [])
	for asset in assets:
		var asset_dict: Dictionary = asset
		if String(asset_dict.get("name", "")) == "godot-ai-plugin.zip":
			url = String(asset_dict.get("browser_download_url", ""))
			break

	var forced := McpClientConfigurator.mode_override() == "user"
	var label_text := "Update available: v%s" % remote_version
	if forced:
		## Visible hint so testers notice the banner is only showing because
		## of a forced-user override (dock dropdown or GODOT_AI_MODE env
		## var). Clicking Update in a symlinked dev tree safely bails in
		## `_install_zip` via the addons_dir_is_symlink guard.
		label_text += " (forced)"

	out["has_update"] = true
	out["version"] = remote_version
	out["forced"] = forced
	out["label_text"] = label_text
	out["download_url"] = url
	return out


static func _is_newer(remote: String, local: String) -> bool:
	var r := remote.split(".")
	var l := local.split(".")
	for i in range(max(r.size(), l.size())):
		var rv := int(r[i]) if i < r.size() else 0
		var lv := int(l[i]) if i < l.size() else 0
		if rv > lv:
			return true
		if rv < lv:
			return false
	return false


# ---- HTTPRequest callbacks (instance-side) -----------------------------

func _on_update_check_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	var parsed := parse_releases_response(result, response_code, body)
	if not bool(parsed.get("has_update", false)):
		return
	_latest_download_url = String(parsed.get("download_url", ""))
	update_check_completed.emit(parsed)


func _on_download_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	_body: PackedByteArray
) -> void:
	if _download_request != null:
		_download_request.queue_free()
		_download_request = null

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		print("MCP | update download failed: result=%d code=%d" % [result, response_code])
		install_state_changed.emit({
			"phase": "download_failed",
			"button_text": "Download failed (%d)" % response_code,
			"button_disabled": false,
		})
		return

	install_state_changed.emit({
		"phase": "installing",
		"button_text": "Installing...",
	})
	# Extract and install on next frame to avoid mid-callback issues.
	_install_zip.call_deferred()


# ---- Install orchestration ---------------------------------------------

func _install_zip() -> void:
	## Belt-and-suspenders data-safety check. `check_for_updates` is gated
	## on `is_dev_checkout()` (a UX heuristic the user can override via
	## GODOT_AI_MODE=user), but the actual hazard we can never tolerate is
	## writing release-zip files into a symlinked addons dir — that
	## clobbers the canonical `plugin/` source tree. Symlink detection is
	## independent of the mode override: even a forced-user mode aborts
	## here if the target is a symlink. See #116.
	if McpClientConfigurator.addons_dir_is_symlink():
		install_state_changed.emit({
			"phase": "symlink_blocked",
			"button_text": "Dev checkout — update via git",
			"button_disabled": true,
			"banner_visible": false,
		})
		return

	## Block worker spawning + drain in-flight worker BEFORE we start
	## overwriting plugin scripts on disk. Without this, focus-in landing
	## anywhere in the extract→reload window spawns a worker that walks
	## into a partially-overwritten script and SIGABRTs inside
	## `GDScriptFunction::call`. The flag is consulted by every dock
	## spawn path via `is_install_in_flight()`.
	_install_in_flight = true
	_drain_dock_workers()

	var version := Engine.get_version_info()
	var has_runner: bool = (
		_plugin != null
		and _plugin.has_method("install_downloaded_update")
	)
	if int(version.get("minor", 0)) >= 4 and has_runner:
		install_state_changed.emit({
			"phase": "handing_off_to_runner",
			"button_text": "Reloading...",
		})
		## Hand the install over to the runner. The plugin tears down
		## (set_plugin_enabled(false)), the runner extracts + scans + re-
		## enables. `install_downloaded_update` already calls
		## `prepare_for_update_reload()` internally (kills the server,
		## resets the spawn guard) — see plugin.gd::install_downloaded_update.
		_plugin.install_downloaded_update(UPDATE_TEMP_ZIP, UPDATE_TEMP_DIR, _dock)
		return

	_install_zip_inline(version)


func _install_zip_inline(version: Dictionary) -> void:
	## 4.3-and-older fallback. The runner-based flow needs Godot 4.4+
	## EditorInterface.set_plugin_enabled timing — on older versions the
	## off/on toggle re-enters in a way that crashes. We extract in-process
	## and ask the user to restart.
	var zip_path := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	var install_base := ProjectSettings.globalize_path("res://")

	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		_install_in_flight = false
		install_state_changed.emit({
			"phase": "extract_failed",
			"button_text": "Extract failed",
			"button_disabled": false,
		})
		return

	var files := reader.get_files()
	for file_path in files:
		if not file_path.begins_with("addons/godot_ai/"):
			continue
		if file_path.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(install_base.path_join(file_path))
		else:
			var dir := file_path.get_base_dir()
			DirAccess.make_dir_recursive_absolute(install_base.path_join(dir))
			var content := reader.read_file(file_path)
			var f := FileAccess.open(install_base.path_join(file_path), FileAccess.WRITE)
			if f != null:
				f.store_buffer(content)
				f.close()

	reader.close()

	# Clean up temp files
	DirAccess.remove_absolute(zip_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))

	## Kill the old server before the reload so the re-enabled plugin spawns
	## a fresh one against the new plugin version. Without this, the running
	## Python process on port 8000 outlives the reload, `_start_server`
	## short-circuits on "port already in use," and session_list reports
	## `plugin_version != server_version` until the user restarts the
	## editor. See issue #132.
	if _plugin != null and _plugin.has_method("prepare_for_update_reload"):
		_plugin.prepare_for_update_reload()

	if int(version.get("minor", 0)) >= 4:
		install_state_changed.emit({
			"phase": "scanning",
			"button_text": "Scanning...",
		})
		## Before reloading the plugin we MUST wait for Godot's filesystem
		## scanner to see the newly-extracted files. Otherwise plugin.gd
		## re-parses and its `class_name` references resolve against a
		## ClassDB that hasn't picked up the new files yet — parse errors,
		## dock tears down, plugin reports "enabled" with no UI. See #127.
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.filesystem_changed.connect(
				_on_filesystem_scanned_for_update, CONNECT_ONE_SHOT
			)
			fs.scan()
		else:
			## Fallback: no filesystem accessor — defer and hope (matches
			## the pre-#127 behaviour).
			_reload_after_update.call_deferred()
	else:
		## Pre-4.4 Godot: no plugin reload, dock stays alive on the new files.
		## Clear the install flag so refreshes resume on the OLD dock instance
		## until the user restarts the editor.
		_install_in_flight = false
		install_state_changed.emit({
			"phase": "needs_restart",
			"button_text": "Restart editor to apply",
			"button_disabled": true,
			"label_text": "Updated! Restart the editor.",
			"label_color": Color.GREEN,
		})


func _on_filesystem_scanned_for_update() -> void:
	install_state_changed.emit({
		"phase": "reloading",
		"button_text": "Reloading...",
	})
	_reload_after_update.call_deferred()


func _reload_after_update() -> void:
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _drain_dock_workers() -> void:
	if _dock == null:
		return
	if _dock.has_method("_drain_client_status_refresh_workers"):
		_dock._drain_client_status_refresh_workers()
	if _dock.has_method("_drain_client_action_workers"):
		_dock._drain_client_action_workers()
