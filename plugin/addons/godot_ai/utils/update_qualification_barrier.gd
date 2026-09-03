@tool
extends RefCounted

## Process-local qualification control for coordinator-only update effects.
## The secret exists only in the editor environment. Durable records contain
## its digest and root/transaction identity, and an external controller must
## authenticate the exact observed barrier before the coordinator continues.

const TOKEN_ENV := "GODOT_AI_QUALIFICATION_FAILPOINT_TOKEN"
const EFFECT_ENV := "GODOT_AI_QUALIFICATION_FAILPOINT_EFFECT"
const WHEN_ENV := "GODOT_AI_QUALIFICATION_FAILPOINT_WHEN"
const TIMEOUT_ENV := "GODOT_AI_QUALIFICATION_FAILPOINT_TIMEOUT"
const OCCURRENCE_ENV := "GODOT_AI_QUALIFICATION_FAILPOINT_OCCURRENCE"
const COORDINATOR_EFFECTS := [
	"coordinator_disable_request",
	"coordinator_disable_verified",
	"coordinator_filesystem_scan",
	"coordinator_enable",
]
const KNOWN_EFFECTS := [
	"intent_commit",
	"intent_temporary_write",
	"activation_lock",
	"journal_commit",
	"journal_temporary_write",
	"live_to_backup",
	"stage_to_live",
	"quarantine_live",
	"backup_to_live",
	"result_commit",
	"terminal_temporary_write",
	"migration_complete",
	"migration_complete_temporary_write",
	"repair_claim",
] + COORDINATOR_EFFECTS
const CAPABILITY_NAME := "coordinator-qualification-capability.json"
const BARRIER_NAME := "coordinator-failpoint-barrier.json"
const DECISION_NAME := "coordinator-failpoint-decision.json"
const RECORD_LIMIT := 16 * 1024
const SCHEMA_VERSION := 1
const DEFAULT_TIMEOUT_SECONDS := 30.0
const MAX_TIMEOUT_SECONDS := 300.0
const TIMEOUT_PATTERN := "^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?$"
const WAITING := 0
const CONTINUE := 1
const INJECT_FAILURE := 2
const INVALID := 3
const RECORD_KEYS := {
	"coordinator_qualification_capability": [
		"record", "schema_version", "transaction", "project_root", "install_root",
		"recovery_root", "effect", "when", "token_sha256", "occurrence",
	],
	"coordinator_failpoint_barrier": [
		"record", "schema_version", "transaction", "project_root", "install_root",
		"recovery_root", "effect", "when", "token_sha256", "sequence",
	],
	"coordinator_failpoint_decision": [
		"record", "schema_version", "transaction", "project_root", "install_root",
		"recovery_root", "effect", "when", "token_sha256", "sequence", "action", "mac",
	],
}

var error := ""
var _prepared: Dictionary = {}
var _token := ""
var _effect := ""
var _when := ""
var _timeout_seconds := DEFAULT_TIMEOUT_SECONDS
var _deadline_msec := 0
var _sequence := 0
var _occurrence := 1
var _spent := false
var _records_published := false
var _decision_owned := false


func configure(prepared: Dictionary) -> bool:
	_prepared = prepared.duplicate(true)
	_token = OS.get_environment(TOKEN_ENV)
	_effect = OS.get_environment(EFFECT_ENV)
	_when = OS.get_environment(WHEN_ENV)
	var timeout_text := OS.get_environment(TIMEOUT_ENV)
	var names := [TOKEN_ENV, EFFECT_ENV, WHEN_ENV, TIMEOUT_ENV]
	var present := names.filter(func(name: String) -> bool: return OS.has_environment(name)).size()
	if present == 0 and not OS.has_environment(OCCURRENCE_ENV):
		return true
	if present != names.size():
		return _invalid("qualification failpoint environment is incomplete")
	if OS.has_environment(OCCURRENCE_ENV):
		var occurrence_text := OS.get_environment(OCCURRENCE_ENV)
		var occurrence_pattern := RegEx.new()
		occurrence_pattern.compile("^[1-9][0-9]{0,3}$")
		if occurrence_pattern.search(occurrence_text) == null:
			return _invalid("qualification failpoint occurrence must be an integer from 1 to 9999")
		_occurrence = occurrence_text.to_int()
	if not _is_lower_hex(_token, 64):
		return _invalid("qualification failpoint token must be 64 lowercase hex characters")
	if _effect not in KNOWN_EFFECTS:
		return _invalid("qualification failpoint effect is unknown")
	if _when not in ["before", "after"]:
		return _invalid("qualification failpoint timing must be before or after")
	if not _is_decimal_timeout(timeout_text):
		return _invalid("qualification failpoint timeout must be a finite positive number")
	_timeout_seconds = timeout_text.to_float()
	if (
		is_nan(_timeout_seconds)
		or is_inf(_timeout_seconds)
		or _timeout_seconds <= 0.0
		or _timeout_seconds > MAX_TIMEOUT_SECONDS
	):
		return _invalid("qualification failpoint timeout must be in (0, 300] seconds")
	for key in ["transaction", "project_root", "install_root", "recovery_root"]:
		if str(_prepared.get(key, "")).is_empty():
			return _invalid("qualification failpoint is missing prepared identity %s" % key)
	return true


func is_coordinator_effect() -> bool:
	return _effect in COORDINATOR_EFFECTS


func clear_environment() -> void:
	for name in [TOKEN_ENV, EFFECT_ENV, WHEN_ENV, TIMEOUT_ENV, OCCURRENCE_ENV]:
		OS.unset_environment(name)


func begin(effect: String, when: String) -> bool:
	if _spent or _effect != effect or _when != when:
		return false
	if not is_coordinator_effect():
		return false
	_sequence += 1
	if _sequence != _occurrence:
		return false
	var root := str(_prepared.recovery_root)
	var decision_path := root.path_join(DECISION_NAME)
	if FileAccess.file_exists(decision_path):
		_invalid("stale qualification decision already exists")
		return false
	var capability := _identity("coordinator_qualification_capability", false)
	var barrier := _identity("coordinator_failpoint_barrier", true)
	if not _write_new(root.path_join(CAPABILITY_NAME), capability):
		_invalid("qualification capability already exists or could not be published")
		return false
	if not _write_new(root.path_join(BARRIER_NAME), barrier):
		_remove_exact(root.path_join(CAPABILITY_NAME), capability)
		_invalid("qualification barrier already exists or could not be published")
		return false
	_records_published = true
	_deadline_msec = Time.get_ticks_msec() + int(_timeout_seconds * 1000.0)
	return true


func poll() -> int:
	if not error.is_empty():
		return INVALID
	var decision_path := str(_prepared.recovery_root).path_join(DECISION_NAME)
	if not FileAccess.file_exists(decision_path):
		if Time.get_ticks_msec() >= _deadline_msec:
			_invalid("qualification failpoint decision timed out")
			_cleanup_records()
			return INVALID
		return WAITING
	var decision := _read_bounded_record(decision_path)
	if not _valid_decision(decision):
		_invalid("qualification failpoint decision authentication or identity failed")
		_cleanup_records()
		return INVALID
	var action := str(decision.action)
	_spent = true
	_decision_owned = true
	_cleanup_records()
	return CONTINUE if action == "continue" else INJECT_FAILURE


func _cleanup_records() -> void:
	if not _records_published:
		return
	if _decision_owned:
		DirAccess.remove_absolute(str(_prepared.recovery_root).path_join(DECISION_NAME))
		_decision_owned = false
	for name in [BARRIER_NAME, CAPABILITY_NAME]:
		DirAccess.remove_absolute(str(_prepared.recovery_root).path_join(name))
	_records_published = false


func _identity(record: String, include_sequence: bool) -> Dictionary:
	var row := {
		"record": record,
		"schema_version": SCHEMA_VERSION,
		"transaction": str(_prepared.transaction),
		"project_root": str(_prepared.project_root),
		"install_root": str(_prepared.install_root),
		"recovery_root": str(_prepared.recovery_root),
		"effect": _effect,
		"when": _when,
		"token_sha256": _sha256(_token.hex_decode()),
	}
	if include_sequence:
		row.sequence = _sequence
	else:
		row.occurrence = _occurrence
	return row


func _valid_decision(decision: Dictionary) -> bool:
	if decision.size() != 12 or str(decision.get("record", "")) != "coordinator_failpoint_decision":
		return false
	var barrier := _identity("coordinator_failpoint_barrier", true)
	for key in barrier:
		if key == "record":
			continue
		if decision.get(key) != barrier[key]:
			return false
	var action := str(decision.get("action", ""))
	var mac := str(decision.get("mac", ""))
	return (
		action in ["continue", "fail"]
		and _is_lower_hex(mac, 64)
		and _constant_time_equal(mac, _decision_mac(action))
	)


func _decision_mac(action: String) -> String:
	var message := (
		"godot-ai-coordinator-failpoint-v1\n%s\n%s\n%s\n%s\n%s\n%s\n%d\n%s\n"
		% [
			str(_prepared.transaction),
			str(_prepared.project_root),
			str(_prepared.install_root),
			str(_prepared.recovery_root),
			_effect,
			_when,
			_sequence,
			action,
		]
	)
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, _token.hex_decode()) != OK:
		return ""
	if context.update(message.to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _write_new(path: String, value: Dictionary) -> bool:
	if FileAccess.file_exists(path):
		return false
	var temporary := "%s.tmp.%d" % [path, OS.get_process_id()]
	if FileAccess.file_exists(temporary):
		return false
	var payload := JSON.stringify(value)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.close()
	if OS.get_name() != "Windows" and FileAccess.set_unix_permissions(temporary, 384) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	file = FileAccess.open(temporary, FileAccess.READ_WRITE)
	if file == null:
		DirAccess.remove_absolute(temporary)
		return false
	file.store_string(payload)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK or FileAccess.get_file_as_string(temporary) != payload:
		DirAccess.remove_absolute(temporary)
		return false
	if DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	if OS.get_name() != "Windows" and (FileAccess.get_unix_permissions(path) & 63) != 0:
		DirAccess.remove_absolute(path)
		return false
	return true


static func _read_bounded_record(path: String) -> Dictionary:
	if OS.get_name() != "Windows" and (FileAccess.get_unix_permissions(path) & 63) != 0:
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	if file.get_length() > RECORD_LIMIT:
		file.close()
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	var record := str(parsed.get("record", ""))
	var expected_keys: Array = RECORD_KEYS.get(record, [])
	if expected_keys.is_empty() or parsed.size() != expected_keys.size():
		return {}
	## Godot silently collapses duplicate JSON keys, including escaped spellings
	## such as `\u0072ecord`. Decode top-level key tokens before comparing them.
	var scanned := _top_level_object_keys(text)
	if not bool(scanned.get("ok", false)):
		return {}
	var keys: Array = scanned.get("keys", [])
	if keys.size() != expected_keys.size():
		return {}
	var seen := {}
	for key in keys:
		if seen.has(key) or key not in expected_keys or not parsed.has(key):
			return {}
		seen[key] = true
	return parsed


static func _top_level_object_keys(text: String) -> Dictionary:
	var index := _skip_json_space(text, 0)
	if index >= text.length() or text[index] != "{":
		return {}
	index += 1
	var keys: Array = []
	while true:
		index = _skip_json_space(text, index)
		if index >= text.length():
			return {}
		if text[index] == "}":
			index = _skip_json_space(text, index + 1)
			return {"ok": index == text.length(), "keys": keys}
		var token_end := _json_string_end(text, index)
		if token_end < 0:
			return {}
		var key: Variant = JSON.parse_string(text.substr(index, token_end - index))
		if not key is String:
			return {}
		keys.append(key)
		index = _skip_json_space(text, token_end)
		if index >= text.length() or text[index] != ":":
			return {}
		index += 1
		var depth := 0
		var in_string := false
		var escaped := false
		while index < text.length():
			var character := text[index]
			if in_string:
				if escaped:
					escaped = false
				elif character == "\\":
					escaped = true
				elif character == "\"":
					in_string = false
			elif character == "\"":
				in_string = true
			elif character == "[" or character == "{":
				depth += 1
			elif character == "]":
				if depth <= 0:
					return {}
				depth -= 1
			elif character == "}":
				if depth == 0:
					break
				depth -= 1
			elif character == "," and depth == 0:
				break
			index += 1
		if index >= text.length() or in_string or depth != 0:
			return {}
		if text[index] == ",":
			index += 1
			continue
		index = _skip_json_space(text, index + 1)
		return {"ok": index == text.length(), "keys": keys}
	return {}


static func _json_string_end(text: String, start: int) -> int:
	if start >= text.length() or text[start] != "\"":
		return -1
	var escaped := false
	for index in range(start + 1, text.length()):
		var character := text[index]
		if escaped:
			escaped = false
		elif character == "\\":
			escaped = true
		elif character == "\"":
			return index + 1
	return -1


static func _skip_json_space(text: String, start: int) -> int:
	var index := start
	while index < text.length() and text[index] in [" ", "\t", "\r", "\n"]:
		index += 1
	return index


static func _remove_exact(path: String, expected: Dictionary) -> void:
	if _read_bounded_record(path) == expected:
		DirAccess.remove_absolute(path)


static func _sha256(value: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(value) != OK:
		return ""
	return context.finish().hex_encode()


static func _is_lower_hex(value: String, length: int) -> bool:
	if value.length() != length:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


static func _is_decimal_timeout(value: String) -> bool:
	var expression := RegEx.new()
	return expression.compile(TIMEOUT_PATTERN) == OK and expression.search(value) != null


static func _constant_time_equal(left: String, right: String) -> bool:
	var difference := left.length() ^ right.length()
	var length := maxi(left.length(), right.length())
	for index in length:
		var left_code := left.unicode_at(index) if index < left.length() else 0
		var right_code := right.unicode_at(index) if index < right.length() else 0
		difference |= left_code ^ right_code
	return difference == 0


func _invalid(message: String) -> bool:
	error = message
	return false
