@tool
extends Node

## Verifies and stages the embedded canonical v4 release while the migration
## capsule is still the enabled plugin. Every step runs in GDScript on the
## editor's main thread through the same installer scripts the v4 tree ships
## (`utils/release_verifier.gd`, `utils/update_installer.gd`); nothing here
## spawns a process, and nothing here writes a live add-on file.

const PAYLOAD_ROOT := "res://addons/godot_ai/migration_payload"
const ARCHIVE_NAME := "godot-ai-v4-plugin.zip"
const MANIFEST_NAME := "godot-ai-v4-plugin.manifest.json"
const SIGNATURE_NAME := "godot-ai-v4-plugin.manifest.sig"
const VERIFIER_SCRIPT := "res://addons/godot_ai/utils/release_verifier.gd"
const INSTALLER_SCRIPT := "res://addons/godot_ai/utils/update_installer.gd"
const REPOSITORY := "hi-godot/godot-ai"
const CHANNEL := "stable"
const MAX_MANIFEST_BYTES := 1024 * 1024
const SIGNATURE_BYTES := 512
const PENDING_V3_UPDATE_SETTING := "godot_ai/pending_self_update_event"
const INCOMPLETE_CAPSULE := (
	"The migration capsule is incomplete (%s). Download the release again, then click Retry migration."
)

## Kept byte-identical to `utils/update_manager.gd::RELEASE_SIGNING_PUBLIC_KEY_PEM`
## in the v4 tree; `tests/unit/test_release_support.py` pins the two copies
## together. The capsule cannot preload the v4 updater to read it there.
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

signal state_changed(message: String, failed: bool)
signal prepared(package: Dictionary)

enum Step { IDLE, VERIFY, STAGE, DONE }

var _step := Step.IDLE
var _manifest: Dictionary = {}
var _manifest_sha256 := ""
var _from_version := ""


func start() -> void:
	if _step != Step.IDLE:
		return
	_from_version = _previous_version()
	_step = Step.VERIFY
	state_changed.emit("Verifying the signed Godot AI v4 release…", false)
	set_process(true)


func _process(_delta: float) -> void:
	## One step per frame so the dock renders each status line before the
	## next synchronous hash/extract pass runs.
	match _step:
		Step.VERIFY:
			_verify()
		Step.STAGE:
			_stage()
		_:
			set_process(false)


func _verify() -> void:
	var verifier := _load_script_with(VERIFIER_SCRIPT, "verify_manifest")
	if verifier == null or not _script_declares(verifier, "verify_archive"):
		_fail(INCOMPLETE_CAPSULE % "utils/release_verifier.gd is missing or invalid")
		return
	var manifest_bytes := _read_bounded(PAYLOAD_ROOT.path_join(MANIFEST_NAME), MAX_MANIFEST_BYTES)
	var signature := _read_bounded(PAYLOAD_ROOT.path_join(SIGNATURE_NAME), SIGNATURE_BYTES)
	if manifest_bytes.is_empty() or signature.size() != SIGNATURE_BYTES:
		_fail(INCOMPLETE_CAPSULE % "the embedded v4 manifest or signature is unreadable")
		return
	var expected := {"repository": REPOSITORY, "channel": CHANNEL}
	if not _from_version.is_empty():
		## Only the final v3 runners publish the pre-capsule plugin.cfg
		## version; older ones cannot, and the verifier must not be told a
		## guess.
		expected["current_version"] = _from_version
	var verified: Variant = verifier.call(
		"verify_manifest", manifest_bytes, signature, expected, RELEASE_SIGNING_PUBLIC_KEY_PEM
	)
	if not verified is Dictionary or not bool(verified.get("ok", false)):
		_fail(_error_of(verified, "The embedded v4 release manifest could not be verified."))
		return
	var manifest: Variant = (verified as Dictionary).get("manifest", {})
	if not manifest is Dictionary or str(manifest.get("version", "")).is_empty():
		_fail("The verified v4 manifest is missing its release version.")
		return
	_manifest = (manifest as Dictionary).duplicate(true)
	_manifest_sha256 = _sha256_hex(manifest_bytes)
	var archive_checked: Variant = verifier.call(
		"verify_archive", PAYLOAD_ROOT.path_join(ARCHIVE_NAME), _manifest
	)
	if not archive_checked is Dictionary or not bool(archive_checked.get("ok", false)):
		_fail(_error_of(archive_checked, "The embedded v4 archive does not match its signed manifest."))
		return
	_step = Step.STAGE
	state_changed.emit("Staging the verified Godot AI v4 tree…", false)


func _stage() -> void:
	var installer := _load_script_with(INSTALLER_SCRIPT, "stage")
	if installer == null:
		_fail(INCOMPLETE_CAPSULE % "utils/update_installer.gd is missing or invalid")
		return
	var staged: Variant = installer.call("stage", PAYLOAD_ROOT.path_join(ARCHIVE_NAME), _manifest)
	if not staged is Dictionary or not bool(staged.get("ok", false)):
		_fail(_error_of(staged, "The verified v4 tree could not be staged."))
		return
	var stage_root := str((staged as Dictionary).get("stage_root", ""))
	var tree_sha256 := str((staged as Dictionary).get("tree_sha256", ""))
	if stage_root.is_empty() or tree_sha256.is_empty():
		_fail("The installer staged the v4 tree without reporting where or what it wrote.")
		return
	_step = Step.DONE
	set_process(false)
	state_changed.emit("Activating the verified Godot AI v4 tree…", false)
	prepared.emit({
		"stage_root": stage_root,
		"expected_tree_sha256": tree_sha256,
		"manifest_sha256": _manifest_sha256,
		"from_version": _from_version,
		"to_version": str(_manifest.get("version", "")),
	})


func _fail(message: String) -> void:
	_step = Step.DONE
	set_process(false)
	state_changed.emit(message, true)


## The pre-capsule plugin.cfg version, as recorded by the final v3 self-update
## runner before it extracted the capsule over the tree. Empty when unknown.
static func _previous_version() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings == null or not settings.has_setting(PENDING_V3_UPDATE_SETTING):
		return ""
	var parsed: Variant = JSON.parse_string(str(settings.get_setting(PENDING_V3_UPDATE_SETTING)))
	if not parsed is Dictionary:
		return ""
	var value := str(parsed.get("from_version", ""))
	return value if _is_pre_v4_version(value) else ""


static func _is_pre_v4_version(value: String) -> bool:
	var expression := RegEx.new()
	return expression.compile("^[0-3]\\.\\d+\\.\\d+$") == OK and expression.search(value) != null


## Load one of the v4 installer scripts by path. The capsule cannot name them
## by `class_name`: those globals only exist once the v4 tree is live, and the
## bridge must still parse when a truncated capsule lacks them entirely.
static func _load_script_with(path: String, method: String) -> Script:
	if not ResourceLoader.exists(path):
		return null
	var loaded: Variant = load(path)
	if not loaded is Script or not _script_declares(loaded, method):
		return null
	return loaded


static func _script_declares(script: Script, method: String) -> bool:
	for entry in script.get_script_method_list():
		if str(entry.get("name", "")) == method:
			return true
	return false


static func _read_bounded(path: String, maximum: int) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var length := file.get_length()
	if length <= 0 or length > maximum:
		file.close()
		return PackedByteArray()
	var data := file.get_buffer(length)
	file.close()
	return data if data.size() == length else PackedByteArray()


static func _sha256_hex(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()


static func _error_of(result: Variant, fallback: String) -> String:
	if result is Dictionary:
		var error := str((result as Dictionary).get("error", "")).strip_edges()
		if not error.is_empty():
			return error
	return fallback
