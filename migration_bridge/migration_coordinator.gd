@tool
extends Node

## Prepare the capsule's value-only handoff to the shared activation runner.
## This coordinator finishes before the runner disables the capsule or swaps
## its source. The runner alone owns the scan and in-editor activation.

const INSTALLER_SCRIPT := "res://addons/godot_ai/utils/update_installer.gd"
const ACTIVATION_SCRIPT := "res://addons/godot_ai/utils/update_activation_runner.gd"
const PORT_RESOLVER_SCRIPT := "res://addons/godot_ai/utils/port_resolver.gd"
const STATUS_SETTING := "godot_ai/v4_migration_bridge_status"
## v3's `plugin.gd::_ensure_game_helper_autoload` wrote
## `ProjectSettings.set_setting("autoload/_mcp_game_helper", "*res://addons/godot_ai/runtime/game_helper.gd")`
## and saved project.godot. The capsule never re-registers it, so the entry
## dangles for the whole migration window and points at a file the v4 swap
## moves away (#946). Remove it before the swap, matching the exact target so
## a user-owned autoload of the same name is left alone.
const GAME_HELPER_AUTOLOAD_SETTING := "autoload/_mcp_game_helper"
const GAME_HELPER_AUTOLOAD_TARGET := "res://addons/godot_ai/runtime/game_helper.gd"
const REQUIRED_INSTALLER_METHODS := [
	"acquire_lock", "release_lock", "discard_stage",
]
const PRE_DISABLE_DRAIN_FRAMES := 2
## Unknown pre-v4 versions still describe a major crossing. Manual-major
## client repinning replaces any owned pre-v4 entry, so this fallback is
## identity metadata rather than a client-selection authority.
const UNKNOWN_V3_VERSION := "3.0.0"

signal state_changed(message: String, failed: bool)

enum Phase { IDLE, DRAIN, DONE }

var _package: Dictionary = {}
var _phase := Phase.IDLE
var _frames := 0
var _installer: Script
var _lock_held := false


func start(package: Dictionary) -> void:
	if _phase != Phase.IDLE:
		return
	if not _valid_package(package):
		_fail_before_swap("The prepared v4 migration handoff is invalid.")
		return
	_package = package.duplicate(true)
	_frames = PRE_DISABLE_DRAIN_FRAMES
	_phase = Phase.DRAIN
	set_process(true)


func _process(_delta: float) -> void:
	match _phase:
		Phase.DRAIN:
			_frames -= 1
			if _frames <= 0:
				_prepare_swap()
		_:
			set_process(false)


## Everything that can still refuse without touching the live tree.
func _prepare_swap() -> void:
	_installer = _load_script_with(INSTALLER_SCRIPT, "swap")
	for method in REQUIRED_INSTALLER_METHODS:
		if _installer == null or not _script_declares(_installer, method):
			_installer = null
			_fail_before_swap(
				"The migration capsule is incomplete (utils/update_installer.gd is missing or invalid)."
			)
			return
	var activation := GDScript.new()
	activation.source_code = FileAccess.get_file_as_string(ACTIVATION_SCRIPT)
	if activation.source_code.is_empty() or activation.reload() != OK or not _script_declares(activation, "start"):
		_fail_before_swap("The migration capsule's activation runner is missing or invalid.")
		return
	var cleared := _remove_v3_game_helper_autoload()
	if cleared != OK:
		_fail_before_swap(
			"Could not remove the v3 game-helper autoload from project.godot (%s)."
			% error_string(cleared)
		)
		return
	var fingerprint := _editor_fingerprint()
	if fingerprint.is_empty():
		_fail_before_swap("Could not fingerprint this editor process for the update lock.")
		return
	var locked: Variant = _installer.call("acquire_lock", OS.get_process_id(), fingerprint)
	if not locked is Dictionary or not bool(locked.get("ok", false)):
		_fail_before_swap(_error_of(locked, "Another editor holds the Godot AI update lock."))
		return
	_lock_held = true
	var from_version := str(_package.get("from_version", ""))
	var record := {
		"from_version": from_version if not from_version.is_empty() else UNKNOWN_V3_VERSION,
		"to_version": str(_package.get("to_version", "")),
		"manifest_sha256": str(_package.get("manifest_sha256", "")),
		"expected_tree_sha256": str(_package.get("expected_tree_sha256", "")),
		"editor_nonce": Crypto.new().generate_random_bytes(16).hex_encode(),
		## The v4 plugin reads this after activation: a v3-to-v4 crossing
		## may replace owned client-config entries broadly, which an
		## ordinary v4-to-v4 update must not do.
		"replace_owned_mismatches": true,
	}
	var runner: Node = activation.new()
	get_tree().root.add_child(runner)
	var accepted: Variant = runner.call("start", {"stage_root": str(_package.stage_root), "record": record})
	if not accepted is bool or not accepted:
		var reason := str(runner.get("refusal_reason"))
		runner.queue_free()
		_fail_before_swap(reason if not reason.is_empty() else "The migration activation runner refused the prepared handoff.")
		return
	## No capsule Script or suspended callback crosses into the scan. The
	## runner holds only its independent source and copied package values.
	_lock_held = false
	_installer = null
	_phase = Phase.DONE
	set_process(false)
	print("MCP | v3 bridge handing verified tree to in-editor activation")
	queue_free()


func _fail_before_swap(message: String) -> void:
	_release_lock()
	_discard_stage()
	record_status(message)
	push_error("Godot AI v4 migration: %s" % message)
	_phase = Phase.DONE
	set_process(false)
	state_changed.emit(message, true)
	queue_free()


func _release_lock() -> void:
	if not _lock_held:
		return
	_lock_held = false
	if _installer != null:
		_installer.call("release_lock")


## A refused attempt leaves no staged tree behind; `stage()` would clear it
## on Retry anyway, so this is tidiness, not a contract the bridge relies on.
func _discard_stage() -> void:
	if _installer != null and _script_declares(_installer, "discard_stage"):
		_installer.call("discard_stage")


static func _remove_v3_game_helper_autoload() -> Error:
	if not ProjectSettings.has_setting(GAME_HELPER_AUTOLOAD_SETTING):
		return OK
	var target := str(ProjectSettings.get_setting(GAME_HELPER_AUTOLOAD_SETTING, "")).trim_prefix("*")
	if target != GAME_HELPER_AUTOLOAD_TARGET:
		return OK
	ProjectSettings.clear(GAME_HELPER_AUTOLOAD_SETTING)
	return ProjectSettings.save()


## `McpPortResolver.process_fingerprint` from the v4 `utils/port_resolver.gd`
## the capsule carries; final v3's copy of that file predates the method, so
## the lookup is by path and method, never by class_name.
static func _editor_fingerprint() -> String:
	var resolver := _load_script_with(PORT_RESOLVER_SCRIPT, "process_fingerprint")
	if resolver == null:
		return ""
	var value: Variant = resolver.call("process_fingerprint", OS.get_process_id())
	return str(value) if value is String else ""


static func _load_script_with(path: String, method: String) -> Script:
	if not ResourceLoader.exists(path):
		return null
	## Final v3 ships older files at some of these paths (utils/port_resolver.gd),
	## already compiled into the resource cache before the capsule was extracted
	## over the tree. Ignore the cache, deeply, so the capsule's copies and
	## their preloads are the ones that run.
	var loaded: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if not loaded is Script or not _script_declares(loaded, method):
		return null
	return loaded


static func _script_declares(script: Script, method: String) -> bool:
	for entry in script.get_script_method_list():
		if str(entry.get("name", "")) == method:
			return true
	return false


static func _error_of(result: Variant, fallback: String) -> String:
	if result is Dictionary:
		var error := str((result as Dictionary).get("error", "")).strip_edges()
		if not error.is_empty():
			return error
	return fallback


static func record_status(error: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings != null:
		settings.set_setting(status_setting(), JSON.stringify({"error": error}))


static func status_setting() -> String:
	## A failed migration in one project must not block a different project.
	return STATUS_SETTING + "_" + ProjectSettings.globalize_path("res://").sha256_text()


static func _valid_package(package: Dictionary) -> bool:
	for name in ["stage_root", "expected_tree_sha256", "manifest_sha256", "to_version"]:
		if str(package.get(name, "")).is_empty():
			return false
	return true
