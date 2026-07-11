@tool
class_name McpUpdateManager
extends Node

## Self-update manager for pre-runner work. Owns release checks, HTTP ZIP
## download, the install-in-flight gate, and install state signals back to
## the dock. Once `_install_zip()` calls
## `plugin.gd::install_downloaded_update(...)`, ownership transfers to
## `update_reload_runner.gd`, which owns extract, scan, plugin re-enable,
## and detached-dock cleanup.
##
## The dock owns banner rendering and forwards button clicks. The split
## exists because the dock script is one of the files overwritten on disk
## during install — keeping pipeline state on a separate Node lets the dock
## tear down cleanly without losing the in-flight gate that other dock spawn
## paths consult.
##
## `class_name McpUpdateManager` is retained because it shipped in a
## published release. If this class is ever retired, follow CLAUDE.md's
## never-delete-published-class_name shim policy instead of deleting the
## declaration.
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

## Host -> required path prefix for self-update downloads (ZIP and checksum
## sidecar). The URLs are taken verbatim from the GitHub Releases API's
## `browser_download_url`, so before fetching we pin them to https on a
## GitHub-owned host AND to this repo's release-asset path (#599) — a
## tampered or unexpected API response can't point the in-editor updater at
## an arbitrary origin, nor at a release asset of a *different* repo on a
## trusted host.
##
## In practice `browser_download_url` is always the
## `https://github.com/hi-godot/godot-ai/releases/download/<tag>/<asset>`
## shape; HTTPRequest then follows the github.com -> *.githubusercontent.com
## redirect internally (this guard validates the entry point, not each hop).
## The CDN hosts are kept as defense-in-depth should the API ever hand back
## a direct CDN URL — their object keys carry the repo *id*, not the repo
## name, so the tightest checkable prefix there is the release-asset key
## namespace.
const _TRUSTED_DOWNLOAD_PATH_PREFIXES := {
	"github.com": "/hi-godot/godot-ai/releases/download/",
	"www.github.com": "/hi-godot/godot-ai/releases/download/",
	"api.github.com": "/repos/hi-godot/godot-ai/releases/assets/",
	"objects.githubusercontent.com": "/github-production-release-asset-",
	"release-assets.githubusercontent.com": "/github-production-release-asset-",
}

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
var _verify_request: HTTPRequest
var _latest_download_url: String = ""
## URL of the `godot-ai-plugin.zip.sha256` sidecar asset, when the release
## ships one. Used to verify the downloaded archive's integrity before extract
## (#523). Empty for older releases published without a checksum sidecar.
var _latest_checksum_url: String = ""

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
	_latest_checksum_url = ""


## True when the running Godot is within the supported self-update floor.
## Godot < 4.5 must not be offered a one-click update to a release whose
## always-loaded scripts depend on 4.5 APIs/classes.
## Guards `major` too so a future Godot 5.x (minor 0) isn't misclassified.
func _can_self_update() -> bool:
	var v := Engine.get_version_info()
	return _version_can_self_update(int(v.get("major", 0)), int(v.get("minor", 0)))


## Pure version predicate, split out so it's testable without faking the
## running engine. In-editor self-update needs Godot >= 4.5.
static func _version_can_self_update(major: int, minor: int) -> bool:
	return major > 4 or (major == 4 and minor >= 5)


## Banner guidance for engines below the support floor. Shown up-front at
## check time so those users do not install an incompatible latest release.
static func _manual_update_label(version: String) -> String:
	var release_noun := "release"
	var suffix := ""
	if not version.is_empty():
		release_noun = "version"
		suffix = " (latest: v%s)" % version
	return (
		"This is the last Godot AI %s for this Godot%s. " % [release_noun, suffix]
		+ "Upgrade to Godot 4.5+ to keep receiving updates."
	)

## Driven by the dock's Update button. On Godot < 4.5 (see _can_self_update)
## the in-editor install is disabled so users cannot install an incompatible
## latest release. With no resolved download URL, falls back to opening the
## release page. Otherwise kicks off the download -> extract -> reload pipeline.
func start_install() -> void:
	if not _can_self_update():
		install_state_changed.emit({
			"button_text": "Upgrade Godot",
			"button_disabled": true,
			"label_text": _manual_update_label(""),
			"banner_visible": true,
		})
		return

	if _latest_download_url.is_empty():
		OS.shell_open(RELEASES_PAGE)
		return

	## Pin the resolved asset URL to https on a GitHub host AND to this
	## repo's release-asset path before fetching (#523, #599). Fall back to
	## the release page (a user-driven browser download) rather than pulling
	## an executable plugin payload from an unexpected origin.
	if not _is_trusted_download_url(_latest_download_url):
		push_error(
			"MCP | refusing self-update download from untrusted URL: %s"
			% _latest_download_url
		)
		OS.shell_open(RELEASES_PAGE)
		install_state_changed.emit({
			"button_text": "Update via download page",
			"button_disabled": false,
		})
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
##   checksum_url: String            ## `godot-ai-plugin.zip.sha256` asset URL ("" if absent)
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
		"checksum_url": "",
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
	var checksum_url := ""
	var assets: Array = json.get("assets", [])
	for asset in assets:
		var asset_dict: Dictionary = asset
		var asset_name := String(asset_dict.get("name", ""))
		if asset_name == "godot-ai-plugin.zip":
			url = String(asset_dict.get("browser_download_url", ""))
		elif asset_name == "godot-ai-plugin.zip.sha256":
			checksum_url = String(asset_dict.get("browser_download_url", ""))

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
	out["checksum_url"] = checksum_url
	return out


## True only for an `https://` URL whose host is a key of
## `_TRUSTED_DOWNLOAD_PATH_PREFIXES` AND whose path starts with that host's
## required prefix — trusted host alone is not enough; the URL must be a
## hi-godot/godot-ai release asset (#599). Parses the authority by hand
## (GDScript has no URL parser): strips userinfo via the LAST `@` so a spoof
## like `https://github.com@evil.com/...` resolves to `evil.com` (rejected),
## and strips any `:port`. The path is compared case-sensitively (GitHub
## release paths are case-sensitive). Static so the guard is unit-testable
## without instancing the manager.
static func _is_trusted_download_url(url: String) -> bool:
	const SCHEME := "https://"
	if not url.begins_with(SCHEME):
		return false
	if url.find("\\") >= 0:
		return false
	var rest := url.substr(SCHEME.length())
	var authority := rest
	var path := ""
	var slash := rest.find("/")
	if slash >= 0:
		authority = rest.substr(0, slash)
		path = rest.substr(slash)
	## Host is everything after the LAST '@' (userinfo precedes it).
	var at := authority.rfind("@")
	if at >= 0:
		authority = authority.substr(at + 1)
	var colon := authority.find(":")
	if colon >= 0:
		authority = authority.substr(0, colon)
	var host := authority.to_lower()
	if not _TRUSTED_DOWNLOAD_PATH_PREFIXES.has(host):
		return false
	## Reject dot-segments (and their percent-encoded forms) anywhere in the
	## path: "/hi-godot/godot-ai/releases/download/../../evil/..." passes a
	## raw string-prefix test but normalizes server-side to a different repo,
	## defeating the scoping (#599 review). Also reject percent-encoded
	## slashes, which some servers decode before routing.
	var lower_path := path.to_lower()
	for needle in ["/../", "/..", "%2e", "%2f", "%5c"]:
		if lower_path.contains(needle):
			return false
	return path.begins_with(String(_TRUSTED_DOWNLOAD_PATH_PREFIXES[host]))


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
	if not _can_self_update():
		install_state_changed.emit({
			"button_text": "Upgrade Godot",
			"button_disabled": true,
			"label_text": _manual_update_label(String(parsed.get("version", ""))),
			"banner_visible": true,
		})
		return
	_latest_download_url = String(parsed.get("download_url", ""))
	_latest_checksum_url = String(parsed.get("checksum_url", ""))
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

	# Deferred so the HTTPRequest callback returns before the next step starts.
	_verify_then_install.call_deferred()


# ---- Integrity verification (#523) -------------------------------------

## Gate the extract on a SHA-256 match against the release's checksum sidecar.
## TLS + host pinning already constrain where the bytes came from; this
## verifies the bytes themselves so a tampered asset (or a compromised CDN
## object) can't be installed over live plugin code. Releases published
## without a `.sha256` sidecar (older versions) install without this check —
## verify-if-present rather than hard-fail, so existing releases stay
## updatable; the host + repo-path pin still applies to the download itself.
## Removing this legacy bypass (making verification mandatory) is tracked in
## #599 and is gated on all supported update targets publishing `.sha256`
## sidecars — a release-policy question, not a code change here.
func _verify_then_install() -> void:
	## Legacy bypass — see #599 before removing.
	if _latest_checksum_url.is_empty():
		print("MCP | no checksum published for this release; skipping integrity verification")
		install_state_changed.emit({"button_text": "Installing..."})
		_install_zip()
		return

	## A present-but-untrusted checksum URL is a tamper signal, not a
	## backward-compat case — refuse rather than silently skip. Trusted
	## means a GitHub host AND this repo's release-asset path (#599).
	if not _is_trusted_download_url(_latest_checksum_url):
		_fail_verification("checksum URL is not a trusted hi-godot/godot-ai release asset")
		return

	install_state_changed.emit({"button_text": "Verifying..."})
	if _verify_request != null:
		_verify_request.queue_free()
	_verify_request = HTTPRequest.new()
	_verify_request.max_redirects = 10
	_verify_request.request_completed.connect(_on_checksum_completed)
	add_child(_verify_request)
	var err := _verify_request.request(_latest_checksum_url)
	if err != OK:
		_verify_request.queue_free()
		_verify_request = null
		_fail_verification("could not request checksum (error %d)" % err)


func _on_checksum_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if _verify_request != null:
		_verify_request.queue_free()
		_verify_request = null

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail_verification("checksum download failed (result=%d code=%d)" % [result, response_code])
		return

	var expected := _parse_sha256_digest(body.get_string_from_utf8())
	if expected.is_empty():
		_fail_verification("malformed checksum file")
		return

	var zip_path := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	var actual := FileAccess.get_sha256(zip_path).to_lower()
	if actual.is_empty():
		_fail_verification("could not hash the downloaded archive")
		return
	if actual != expected:
		_fail_verification(
			"checksum mismatch (expected %s…, got %s…)"
			% [expected.substr(0, 12), actual.substr(0, 12)]
		)
		return

	print("MCP | self-update checksum verified (sha256 %s)" % actual)
	install_state_changed.emit({"button_text": "Installing..."})
	_install_zip.call_deferred()


## Surface an integrity-check failure and drop the staged zip so the bad
## bytes can never reach the extract path. Keeps the button enabled for retry.
func _fail_verification(reason: String) -> void:
	push_error(
		"MCP | self-update integrity check failed: %s. The download was not installed."
		% reason
	)
	print("MCP | self-update aborted (integrity): %s" % reason)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_ZIP))
	install_state_changed.emit({
		"button_text": "Verification failed — retry",
		"button_disabled": false,
	})


## Extract the hex digest from a `sha256sum`-style file ("<hex>  <name>") or a
## bare digest line. Returns lowercase 64-char hex, or "" if the content isn't
## a valid SHA-256 digest. Static so it's unit-testable. See #523.
static func _parse_sha256_digest(text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return ""
	## First whitespace-delimited token; `sha256sum` separates digest and
	## filename with two spaces, but some tools use tabs.
	var normalized := trimmed.replace("\t", " ").replace("\n", " ").replace("\r", " ")
	var tokens := normalized.split(" ", false)
	if tokens.is_empty():
		return ""
	var digest := String(tokens[0]).strip_edges().to_lower()
	if digest.length() != 64:
		return ""
	for i in digest.length():
		var c := digest[i]
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
			return ""
	return digest


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
	## Without this, focus-in landing in the extract -> reload window spawns
	## a worker that walks into a partially-overwritten script and
	## SIGABRTs in `GDScriptFunction::call`.
	_install_in_flight = true
	_drain_dock_workers()

	var has_runner: bool = (
		_plugin != null
		and _plugin.has_method("install_downloaded_update")
	)
	if has_runner:
		install_state_changed.emit({"button_text": "Reloading..."})
		## Runner takes over: plugin tears down, runner extracts + scans +
		## re-enables. `install_downloaded_update` calls
		## `prepare_for_update_reload()` internally (kills the server,
		## resets the spawn guard) - see plugin.gd::install_downloaded_update.
		_plugin.install_downloaded_update(UPDATE_TEMP_ZIP, UPDATE_TEMP_DIR, _dock)
		return

	DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_ZIP))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))
	_install_in_flight = false
	install_state_changed.emit({
		"button_text": "Reload runner missing",
		"button_disabled": false,
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
