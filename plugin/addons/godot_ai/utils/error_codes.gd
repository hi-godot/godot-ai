@tool
extends RefCounted

## Error code constants shared across handlers. Mirrors protocol/errors.py.

const INVALID_PARAMS := "INVALID_PARAMS"
const EDITED_SCENE_MISMATCH := "EDITED_SCENE_MISMATCH"
const EDITOR_NOT_READY := "EDITOR_NOT_READY"
const UNKNOWN_COMMAND := "UNKNOWN_COMMAND"
const INTERNAL_ERROR := "INTERNAL_ERROR"
const DEFERRED_TIMEOUT := "DEFERRED_TIMEOUT"
## audit-v2 #21 (issue #365): finer-grained codes carved out of the 471
## INVALID_PARAMS sites so agents can distinguish recoverable input
## errors from structural ones. INVALID_PARAMS stays for genuinely
## catch-all input errors that don't fit any of the buckets below.
##
## - NODE_NOT_FOUND: scene-tree/autoload node lookup failed (path didn't
##   resolve to a Node).
## - RESOURCE_NOT_FOUND: a `res://` path lookup failed (file/.tres/
##   .gdshader/.tscn etc. doesn't exist or couldn't load). Distinct from
##   NODE_NOT_FOUND because the recovery path differs — agents need to
##   know whether to fix a node path vs. create/import a resource.
## - PROPERTY_NOT_ON_CLASS: property/signal/method/uniform/slot lookup
##   failed on a known instance (path resolved, but the requested
##   member doesn't exist on that class).
## - VALUE_OUT_OF_RANGE: numeric/index bound violation OR enum value
##   not in the allowed set.
## - WRONG_TYPE: input was a value (or a loaded resource) of the wrong
##   type — the param was provided, but `typeof` or `is X` failed.
## - MISSING_REQUIRED_PARAM: required input field was absent or empty.
const NODE_NOT_FOUND := "NODE_NOT_FOUND"
const RESOURCE_NOT_FOUND := "RESOURCE_NOT_FOUND"
const PROPERTY_NOT_ON_CLASS := "PROPERTY_NOT_ON_CLASS"
const VALUE_OUT_OF_RANGE := "VALUE_OUT_OF_RANGE"
const WRONG_TYPE := "WRONG_TYPE"
const MISSING_REQUIRED_PARAM := "MISSING_REQUIRED_PARAM"


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
