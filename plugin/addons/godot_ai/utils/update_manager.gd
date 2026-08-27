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

## RSA-4096 public key for release-signature verification (#687). The paired
## private key exists only in the GitHub Actions secret RELEASE_SIGNING_KEY_PEM
## (plus the maintainer's offline backup) — deliberately outside the repo
## token's scope, because the threat model is release-asset substitution by a
## leaked token or compromised workflow, and a token that can rewrite assets
## still cannot read secrets. Rotation requires shipping a new plugin release
## embedding the new key (and bumping SIGNING_REQUIRED_FROM_VERSION past the
## last release signed with the old one).
const RELEASE_SIGNING_PUBLIC_KEY_PEM := """-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAr4OmbONFTONGFcXSUQ2p
e54YaUhWDA75wxeDWhOc476vsdo53YnXEFT7EPr2hUKqeNxv++LqKOkFuAsxSNZy
wBe6P1tmQA4Og6Ezv4CGnZdEj1uhlDJFK9ShQ29oWfC6bf/84625SvvBxZos2Br9
yPKl7h5wzqDoeUSpv+f0ynTiC0i/HAUo/NQBlkgGwkomK2Fr3pP1VDxxq2xvgHSk
lU6Qcomr9WjJxI+HkDN5tRPPn0pDrg6YFx2J18OfD8KIa/kMGxuXOcHlPyRYpjyu
qTtg2oL0NyUIG+1TmJ3DcN4GlKC55eOrkfJ04vudS5pxdnUIFRmkGBXZLdaetoPc
ixtlD4w6gi8KIH1CTG+/TtHP1KVdOogCWDcjRCAmMJPFZe6eEKXmGQUZDb9wfnbx
h++XiVe5tq83BTLWmaFTy+fZbNo12uhNCNS1LJ42/yj+S1xvo0yMbkkNr1hIYk0P
584XnBQeBSVJDf3667NZXaxnWv94K9zbb+1OvOvPwhbOdgi2Ymcw5QEOQIavtg86
XLLcWzG+SJsycz1imikjv6sStWh8WHneKSTMq6A7V6PBj7oJyEJp10696BDw287k
YlH+9VGqowPEMXpWX57wOBKiWb4K1kw1LfxjT8W1e/pcX9pJqiv0DkjTXUxo9CDG
1X1+ZXBBR3MkGuFAOCjy0x8CAwEAAQ==
-----END PUBLIC KEY-----
"""

## Every release at or above this version ships a signed sidecar
## (release.yml hard-fails without the signing secret). At or above it, a
## missing `.sha256.sig` asset is treated as tampering — an attacker who can
## rewrite release assets could otherwise just strip the signature to skip
## verification. Below it (releases published before signing existed), the
## legacy checksum-only path still installs.
const SIGNING_REQUIRED_FROM_VERSION := "2.9.3"

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
var _signature_request: HTTPRequest
var _latest_download_url: String = ""
## URL of the `godot-ai-plugin.zip.sha256` sidecar asset. Used to verify the
## downloaded archive's integrity before extract (#523). Verification is
## mandatory (#599): when a release ships no sidecar this stays empty and
## `_verify_then_install` refuses the install.
var _latest_checksum_url: String = ""
## URL of the `godot-ai-plugin.zip.sha256.sig` signature asset (#687). Empty
## on releases published before signing existed; `_verify_then_install`
## refuses an empty URL once the remote version is inside the signing era
## (see SIGNING_REQUIRED_FROM_VERSION).
var _latest_signature_url: String = ""
## Remote version from the last update check — drives the
## signature-required compat gate in `_verify_then_install`.
var _latest_remote_version: String = ""
## Sidecar bytes + parsed digest held between the checksum download and the
## signature verdict, so the signature is checked against exactly the bytes
## the digest was parsed from.
var _pending_sidecar_body := PackedByteArray()
var _pending_expected_digest: String = ""

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
## honours the mode override (EditorSetting `godot_ai/mode_override` >
## `GODOT_AI_MODE` env), so
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


## Cancel any in-flight check so a follow-up check_for_updates() can't
## hit ERR_BUSY on the shared HTTPRequest. No current dock caller — the
## mode-override dropdown that used it was removed in #408; kept as
## published API of the update flow.
func cancel_check() -> void:
	if _http_request != null:
		_http_request.cancel_request()


## Reset the cached download/checksum URLs so a fresh check paints over
## a clean banner. No current production caller — the mode-override
## dropdown that used it was removed in #408; kept for tests and any
## future re-check path.
func clear_pending_download() -> void:
	_latest_download_url = ""
	_latest_checksum_url = ""
	_latest_signature_url = ""
	_latest_remote_version = ""
	_pending_sidecar_body = PackedByteArray()
	_pending_expected_digest = ""


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

	## Warm the uv cache for the NEW server version while the plugin zip
	## downloads (see prewarm_server_package): the post-update walk must win
	## a port bind race against attach bridges respawning the cached OLD
	## version, and a cold uvx resolve loses that race every time. uvx is
	## almost always cached in the CliFinder by now (the dock's setup probe);
	## a cold lookup is the same bounded main-thread cost as
	## `_reprobe_uv_if_negative`, on the same rare click-driven path.
	ClientConfigurator.prewarm_server_package(_latest_remote_version)

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
##   signature_url: String           ## `godot-ai-plugin.zip.sha256.sig` asset URL ("" if absent)
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
		"signature_url": "",
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
	var signature_url := ""
	var assets: Array = json.get("assets", [])
	for asset in assets:
		var asset_dict: Dictionary = asset
		var asset_name := String(asset_dict.get("name", ""))
		if asset_name == "godot-ai-plugin.zip":
			url = String(asset_dict.get("browser_download_url", ""))
		elif asset_name == "godot-ai-plugin.zip.sha256":
			checksum_url = String(asset_dict.get("browser_download_url", ""))
		elif asset_name == "godot-ai-plugin.zip.sha256.sig":
			signature_url = String(asset_dict.get("browser_download_url", ""))

	var forced := ClientConfigurator.mode_override() == "user"
	var label_text := "Update available: v%s" % remote_version
	if forced:
		## Forced-user mode (EditorSetting or env) is the only way the banner
		## lights up in a dev tree; suffix so the operator notices.
		label_text += " (forced)"

	out["has_update"] = true
	out["version"] = remote_version
	out["forced"] = forced
	out["label_text"] = label_text
	out["download_url"] = url
	out["checksum_url"] = checksum_url
	out["signature_url"] = signature_url
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
	## Scope the checks below to the path proper (#713): direct CDN asset
	## URLs carry signed query params (X-Amz-Credential=...%2F...) whose
	## legitimate %2F tokens made every CDN prefix unreachable when the
	## needle scan covered the query string. Routing is decided by the
	## path, so the query is safe to ignore.
	var qmark := path.find("?")
	if qmark >= 0:
		path = path.substr(0, qmark)
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
	_latest_signature_url = String(parsed.get("signature_url", ""))
	_latest_remote_version = String(parsed.get("version", ""))
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
		## Failure parity with _fail_verification (#713): HTTPRequest's
		## download_file mode leaves whatever partial/error bytes it wrote
		## staged at UPDATE_TEMP_ZIP — drop them so no later step can ever
		## pick up a half-downloaded archive.
		DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_ZIP))
		install_state_changed.emit({
			"button_text": "Download failed (%d)" % response_code,
			"button_disabled": false,
		})
		return

	# Deferred so the HTTPRequest callback returns before the next step starts.
	_verify_then_install.call_deferred()


# ---- Integrity verification (#523, #599, #687) --------------------------

## Gate the extract on (1) an RSA signature over the checksum sidecar and
## (2) a SHA-256 match of the archive against that sidecar. TLS + host
## pinning constrain where the bytes came from; the digest verifies the
## bytes themselves (in-transit corruption, single-object substitution);
## the signature verifies the digest's *provenance*. Both `download_url`
## and `checksum_url` come from the same GitHub Releases API response over
## the same channel, so anyone able to modify the release's assets (leaked
## repo token, compromised release workflow) can regenerate the sidecar to
## match a tampered zip — but cannot forge the `.sha256.sig` signature,
## whose private key lives only in an Actions secret outside the repo
## token's scope (#687).
##
## Verification is MANDATORY (#599): no `.sha256` sidecar — mistake or
## tamper — refuses to install. The signature is mandatory for every
## release at or above SIGNING_REQUIRED_FROM_VERSION: a missing signature
## there is a strip-attack signal, not a compat case, and hard-fails. Only
## releases predating signing take the legacy checksum-only path.
func _verify_then_install() -> void:
	_pending_sidecar_body = PackedByteArray()
	_pending_expected_digest = ""

	if _latest_checksum_url.is_empty():
		_fail_verification(
			"release published no godot-ai-plugin.zip.sha256 sidecar; "
			+ "refusing unverified install (#599)"
		)
		return

	## A present-but-untrusted checksum URL is a tamper signal, not a
	## backward-compat case — refuse rather than silently skip. Trusted
	## means a GitHub host AND this repo's release-asset path (#599).
	if not _is_trusted_download_url(_latest_checksum_url):
		_fail_verification("checksum URL is not a trusted hi-godot/godot-ai release asset")
		return

	if _latest_signature_url.is_empty():
		if _signature_required(_latest_remote_version):
			_fail_verification(
				"release v%s ships no godot-ai-plugin.zip.sha256.sig signature. "
				% _latest_remote_version
				+ "Every release from v%s on is signed" % SIGNING_REQUIRED_FROM_VERSION
				+ " — a missing signature means a stripped or tampered release (#687)"
			)
			return
		print(
			"MCP | self-update: release v%s predates signing; " % _latest_remote_version
			+ "using legacy checksum-only verification (#687)"
		)
	elif not _is_trusted_download_url(_latest_signature_url):
		_fail_verification("signature URL is not a trusted hi-godot/godot-ai release asset")
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

	## Signature verification (when armed) runs over the exact sidecar bytes
	## the digest was parsed from — hold both until the signature verdict.
	if not _latest_signature_url.is_empty():
		_pending_sidecar_body = body
		_pending_expected_digest = expected
		_fetch_signature()
		return

	## Legacy pre-signing release: `_verify_then_install` already gated this
	## on the remote version predating SIGNING_REQUIRED_FROM_VERSION.
	_finish_digest_check_and_install(expected)


## Download the `.sha256.sig` release asset; `_on_signature_completed`
## verifies it over the held sidecar bytes before the digest is trusted.
func _fetch_signature() -> void:
	if _signature_request != null:
		_signature_request.queue_free()
	_signature_request = HTTPRequest.new()
	_signature_request.max_redirects = 10
	_signature_request.request_completed.connect(_on_signature_completed)
	add_child(_signature_request)
	var err := _signature_request.request(_latest_signature_url)
	if err != OK:
		_signature_request.queue_free()
		_signature_request = null
		_fail_verification("could not request signature (error %d)" % err)


func _on_signature_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if _signature_request != null:
		_signature_request.queue_free()
		_signature_request = null

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail_verification(
			"signature download failed (result=%d code=%d)" % [result, response_code]
		)
		return

	if not _verify_sidecar_signature(RELEASE_SIGNING_PUBLIC_KEY_PEM, _pending_sidecar_body, body):
		_fail_verification(
			"release signature does not verify against the embedded public key — "
			+ "the checksum sidecar was not produced by the release pipeline (#687)"
		)
		return

	print("MCP | self-update release signature verified (rsa-4096/sha256)")
	_finish_digest_check_and_install(_pending_expected_digest)


## Final gate shared by the signed and legacy paths: the staged archive's
## SHA-256 must match the (now-trusted) sidecar digest before extract.
func _finish_digest_check_and_install(expected: String) -> void:
	_pending_sidecar_body = PackedByteArray()
	_pending_expected_digest = ""

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


## True when `remote_version` falls inside the signing era — every release
## at or above SIGNING_REQUIRED_FROM_VERSION ships a signed sidecar, so a
## missing signature there must hard-fail rather than fall back to the
## legacy checksum-only path. An empty/unknown version fails closed. Static
## so it's unit-testable.
static func _signature_required(remote_version: String) -> bool:
	if remote_version.strip_edges().is_empty():
		return true
	return not _is_newer(SIGNING_REQUIRED_FROM_VERSION, remote_version)


## PKCS#1 v1.5 RSA verification of `signature` over SHA-256(`sidecar`) —
## the exact output of release.yml's `openssl dgst -sha256 -sign`. Takes
## the PEM as a parameter (rather than reading the const) so tests can
## exercise both verdicts with a generated throwaway keypair. Static so
## it's unit-testable without instancing the manager.
static func _verify_sidecar_signature(
	public_key_pem: String, sidecar: PackedByteArray, signature: PackedByteArray
) -> bool:
	if sidecar.is_empty() or signature.is_empty():
		return false
	var key := CryptoKey.new()
	if key.load_from_string(public_key_pem, true) != OK:
		return false
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return false
	ctx.update(sidecar)
	var digest := ctx.finish()
	var crypto := Crypto.new()
	return crypto.verify(HashingContext.HASH_SHA256, digest, signature, key)


## Surface an integrity-check failure and drop the staged zip so the bad
## bytes can never reach the extract path. Keeps the button enabled for retry.
func _fail_verification(reason: String) -> void:
	_pending_sidecar_body = PackedByteArray()
	_pending_expected_digest = ""
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


func _reload_after_update() -> void:
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _drain_dock_workers() -> void:
	if _dock != null and _dock.has_method("prepare_for_self_update_drain"):
		_dock.prepare_for_self_update_drain()
