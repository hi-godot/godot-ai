@tool
class_name McpErrorCodes
extends RefCounted

## Error code constants shared across handlers. Mirrors protocol/errors.py.

const INVALID_PARAMS := "INVALID_PARAMS"
const EDITOR_NOT_READY := "EDITOR_NOT_READY"
const UNKNOWN_COMMAND := "UNKNOWN_COMMAND"
const INTERNAL_ERROR := "INTERNAL_ERROR"


## Build a standard error response dictionary.
static func make(code: String, message: String) -> Dictionary:
	return {"status": "error", "error": {"code": code, "message": message}}


## Convert a Godot error int to a human-readable name.
static func godot_error_string(err: int) -> String:
	match err:
		OK: return "OK"
		FAILED: return "Generic failure"
		ERR_UNAVAILABLE: return "Resource unavailable"
		ERR_UNCONFIGURED: return "Not configured"
		ERR_UNAUTHORIZED: return "Unauthorized"
		ERR_PARAMETER_RANGE_ERROR: return "Parameter out of range"
		ERR_OUT_OF_MEMORY: return "Out of memory"
		ERR_FILE_NOT_FOUND: return "File not found"
		ERR_FILE_BAD_DRIVE: return "Bad drive"
		ERR_FILE_BAD_PATH: return "Bad path"
		ERR_FILE_NO_PERMISSION: return "No permission"
		ERR_FILE_ALREADY_IN_USE: return "File already in use"
		ERR_FILE_CANT_OPEN: return "Cannot open file"
		ERR_FILE_CANT_WRITE: return "Cannot write file"
		ERR_FILE_CANT_READ: return "Cannot read file"
		ERR_FILE_UNRECOGNIZED: return "Unrecognized file"
		ERR_FILE_CORRUPT: return "Corrupt file"
		ERR_FILE_MISSING_DEPENDENCIES: return "Missing dependencies"
		ERR_FILE_EOF: return "End of file"
		ERR_CANT_OPEN: return "Cannot open"
		ERR_CANT_CREATE: return "Cannot create"
		ERR_ALREADY_IN_USE: return "Already in use"
		ERR_INVALID_DATA: return "Invalid data"
		ERR_INVALID_PARAMETER: return "Invalid parameter"
		ERR_ALREADY_EXISTS: return "Already exists"
		ERR_DOES_NOT_EXIST: return "Does not exist"
		ERR_TIMEOUT: return "Timeout"
		_: return "Unknown error (%d)" % err
