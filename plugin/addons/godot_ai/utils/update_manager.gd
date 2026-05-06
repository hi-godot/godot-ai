@tool
class_name McpUpdateManager
extends Node

## Self-update pipeline + install-in-flight gate. Boundary: this manager
## owns decisions, HTTP traffic, and the install state machine; the dock
## owns banner rendering and forwards button clicks. The split exists
## because the dock script is one of the files overwritten on disk during
## install — keeping pipeline state on a separate Node lets the dock
## tear down cleanly without losing the in-flight gate that other dock
## spawn paths consult.
##
## `_plugin` and `_dock` are deliberately untyped: the same self-update
## window that overwrites this script also overwrites the dock and plugin
## scripts, and a static-typed reference into a script being hot-reloaded
## crashes inside `GDScriptFunction::call`. `server_lifecycle.gd` follows
## the same convention.

const RELEASES_URL := (
	"https://api.github.com/repos/hi-godot/godot-ai/releases/latest"
)
const RELEASES_PAGE := "https://github.com/hi-godot/godot-ai/releases/latest"
const UPDATE_TEMP_DIR := "user://godot_ai_update/"
const UPDATE_TEMP_ZIP := "user://godot_ai_update/update.zip"
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")

## Emitted after `check_for_updates()` resolves a newer remote version.
## Payload mirrors the Dictionary returned by `parse_releases_response`:
##   {has_update, version, forced, label_text, download_url}
signal update_check_completed(result: Dictionary)

## Emitted at every UI-relevant step of the install pipeline. Payload
## keys are all optional and apply on top of the current banner state:
##   label_text: String              ## banner label override
##   button_text: String             ## update button text override
##   button_disabled: bool           ## update button disabled state
##   banner_visible: bool            ## banner visibility override
##   outcome: String                 ## "success" -> dock paints green
signal install_state_changed(state: Dictionary)

var _plugin
var _dock

var _http_request: HTTPRequest
var _download_request: HTTPRequest
var _latest_download_url: String = ""

## Set for the duration of `_install_zip` — extract-overwrite of plugin
## scripts on disk would crash any worker mid-`GDScriptFunction::call`
## (confirmed via SIGABRT in the dock's refresh worker). Dock spawn paths
## consult this via `is_install_in_flight()`; in-flight workers are
## drained before any disk write.
var _install_in_flight: bool = false


# ---- Setup -------------------------------------------------------------

func setup(plugin, dock) -> void:
	_plugin = plugin
	_dock = dock


# ---- Public API ---------------------------------------------------------

## Kick off the GitHub Releases API check. No-ops in dev checkouts —
## `addons/godot_ai/` is a symlink into canonical `plugin/` source there,
## and an extract would clobber tracked files (#116). `is_dev_checkout()`
## honours the mode override (dock dropdown > GODOT_AI_MODE env), so
## testers can force `user` to exercise the AssetLib flow from a dev tree;
## `_install_zip` still gates on the physical symlink check so a forced-
## user mode can never clobber source.
func check_for_updates() -> void:
	if ClientConfigurator.is_dev_checkout():
		return
	if _http_request == null:
		_http_request = HTTPRequest.new()
		_http_request.request_completed.connect(_on_update_check_completed)
		add_child(_http_request)
	_http_request.request(RELEASES_URL, ["Accept: application/vnd.github+json"])


## Cancel any in-flight check. The dock calls this before re-issuing a
## check after a mode-override flip — without the cancel, `request()`
## returns ERR_BUSY and the dropdown change silently fails to repaint.
func cancel_check() -> void:
	if _http_request != null:
		_http_request.cancel_request()


## Reset the cached download URL. The dock calls this on mode-override
## flips so a fresh check paints over a clean banner.
func clear_pending_download() -> void:
	_latest_download_url = ""


## Driven by the dock's Update button. With no resolved download URL —
## either the check never completed, or the release didn't ship a
## matching asset — falls back to opening the release page. Otherwise
## kicks off the download → extract → reload pipeline.
func start_install() -> void:
	if _latest_download_url.is_empty():
		OS.shell_open(RELEASES_PAGE)
		return

	install_state_changed.emit({
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
		## `request_completed` never fires when `request()` itself errors,
		## so cleanup (queue_free + null + drop the staged zip) has to land
		## inline — otherwise the HTTPRequest stays parented under the
		## manager until the next click.
		_download_request.queue_free()
		_download_request = null
		DirAccess.remove_absolute(global_zip)
		install_state_changed.emit({
			"button_text": "Request failed",
			"button_disabled": false,
		})


## Consulted by the dock's spawn paths (focus-in refresh, manual button,
## deferred initial refresh) — true while plugin scripts are being
## overwritten. A worker mid-`GDScriptFunction::call` into a half-
## overwritten script SIGABRTs the editor.
func is_install_in_flight() -> bool:
	return _install_in_flight


# ---- Releases-API parse (pure, testable) -------------------------------

## Parses the GitHub Releases API JSON response. Returns:
##   has_update: bool                ## true if remote tag > local version
##   version: String                 ## remote tag minus leading "v"
##   forced: bool                    ## mode_override() == "user" (banner-only hint)
##   label_text: String              ## "Update available: vX.Y.Z" + " (forced)"
##   download_url: String            ## matching `godot-ai-plugin.zip` asset URL
##
## Static so tests drive it without instancing the manager.
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
	var local_version := ClientConfigurator.get_plugin_version()
	if not _is_newer(remote_version, local_version):
		return out

	var url := ""
	var assets: Array = json.get("assets", [])
	for asset in assets:
		var asset_dict: Dictionary = asset
		if String(asset_dict.get("name", "")) == "godot-ai-plugin.zip":
			url = String(asset_dict.get("browser_download_url", ""))
			break

	var forced := ClientConfigurator.mode_override() == "user"
	var label_text := "Update available: v%s" % remote_version
	if forced:
		## Forced-user mode (dropdown or env) is the only way the banner
		## lights up in a dev tree; suffix so the operator notices.
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
			"button_text": "Download failed (%d)" % response_code,
			"button_disabled": false,
		})
		return

	install_state_changed.emit({"button_text": "Installing..."})
	# Deferred so the HTTPRequest callback returns before the extract starts.
	_install_zip.call_deferred()


# ---- Install orchestration ---------------------------------------------

func _install_zip() -> void:
	## Symlinked addons dir means an extract would clobber canonical
	## `plugin/` source through the link. Symlink detection is independent
	## of the mode override: even forced-user aborts here. See #116.
	if ClientConfigurator.addons_dir_is_symlink():
		install_state_changed.emit({
			"button_text": "Dev checkout — update via git",
			"button_disabled": true,
			"banner_visible": false,
		})
		return

	## Drain in-flight workers + block new ones BEFORE any disk write.
	## Without this, focus-in landing in the extract→reload window spawns
	## a worker that walks into a partially-overwritten script and
	## SIGABRTs in `GDScriptFunction::call`.
	_install_in_flight = true
	_drain_dock_workers()

	var version := Engine.get_version_info()
	var has_runner: bool = (
		_plugin != null
		and _plugin.has_method("install_downloaded_update")
	)
	if int(version.get("minor", 0)) >= 4 and has_runner:
		install_state_changed.emit({"button_text": "Reloading..."})
		## Runner takes over: plugin tears down, runner extracts + scans +
		## re-enables. `install_downloaded_update` calls
		## `prepare_for_update_reload()` internally (kills the server,
		## resets the spawn guard) — see plugin.gd::install_downloaded_update.
		_plugin.install_downloaded_update(UPDATE_TEMP_ZIP, UPDATE_TEMP_DIR, _dock)
		return

	_install_zip_inline(version)


func _install_zip_inline(version: Dictionary) -> void:
	## Pre-4.4 fallback. EditorInterface.set_plugin_enabled off/on is
	## re-entry-unsafe on older Godot; we extract in-process and ask the
	## user to restart.
	var zip_path := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	var install_base := ProjectSettings.globalize_path("res://")

	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		_install_in_flight = false
		install_state_changed.emit({
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

	DirAccess.remove_absolute(zip_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))

	## Kill the old server before the reload so the re-enabled plugin spawns
	## a fresh one against the new plugin version (#132).
	if _plugin != null and _plugin.has_method("prepare_for_update_reload"):
		_plugin.prepare_for_update_reload()

	if int(version.get("minor", 0)) >= 4:
		install_state_changed.emit({"button_text": "Scanning..."})
		## Filesystem scan must complete before plugin reload — otherwise
		## plugin.gd re-parses against a ClassDB that hasn't seen the new
		## files yet, parse errors, dock tears down silently. See #127.
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.filesystem_changed.connect(
				_on_filesystem_scanned_for_update, CONNECT_ONE_SHOT
			)
			fs.scan()
		else:
			_reload_after_update.call_deferred()
	else:
		## Pre-4.4: no plugin reload; refreshes resume on the old dock
		## instance until the user restarts.
		_install_in_flight = false
		install_state_changed.emit({
			"button_text": "Restart editor to apply",
			"button_disabled": true,
			"label_text": "Updated! Restart the editor.",
			"outcome": "success",
		})


func _on_filesystem_scanned_for_update() -> void:
	install_state_changed.emit({"button_text": "Reloading..."})
	_reload_after_update.call_deferred()


func _reload_after_update() -> void:
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _drain_dock_workers() -> void:
	if _dock != null and _dock.has_method("prepare_for_self_update_drain"):
		_dock.prepare_for_self_update_drain()
