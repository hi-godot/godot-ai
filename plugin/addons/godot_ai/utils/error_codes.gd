@tool
class_name McpErrorCodes
extends RefCounted

## Error code constants shared across handlers. Mirrors protocol/errors.py.

const INVALID_PARAMS := "INVALID_PARAMS"
const EDITED_SCENE_MISMATCH := "EDITED_SCENE_MISMATCH"
const EDITOR_NOT_READY := "EDITOR_NOT_READY"
const UNKNOWN_COMMAND := "UNKNOWN_COMMAND"
const INTERNAL_ERROR := "INTERNAL_ERROR"


## Build a standard error response dictionary.
static func make(code: String, message: String) -> Dictionary:
	return {"status": "error", "error": {"code": code, "message": message}}


## Return a NEW error dict with the original code and a prefixed message.
## Prefer this over mutating `err["error"]["message"]` in place — callers
## that want to add context ("Property '%s': …") shouldn't need to know
## the internal shape of the dict returned by `make`. Empty `prefix`
## returns `err` unchanged so callers don't need their own guard.
static func prefix_message(err: Dictionary, prefix: String) -> Dictionary:
	if prefix.is_empty():
		return err
	var inner: Dictionary = err.get("error", {})
	var code: String = inner.get("code", INTERNAL_ERROR)
	var message: String = inner.get("message", "")
	return make(code, "%s: %s" % [prefix, message])
