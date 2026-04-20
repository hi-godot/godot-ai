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
