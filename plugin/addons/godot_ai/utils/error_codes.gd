@tool
class_name McpErrorCodes
extends RefCounted

## Error code constants shared across handlers. Mirrors protocol/errors.py.
##
## This `class_name` shipped in v2.3.2 and earlier and must stay reachable
## through self-update. v2.4.1 dropped it and triggered a "Could not resolve
## script" cascade for every user upgrading from any earlier version; v2.4.2
## restored it as a hot-fix. The cascade fires because Godot keeps stale
## registry entries during the disable -> extract -> enable window when a
## previously-registered class_name disappears, and that failure mode is
## independent of the runner's install ordering. See CLAUDE.md's
## never-delete-published-class_name policy for the shape-aware shim path
## that retirement (if ever needed) must follow.
##
## All consumers use the preload-alias pattern
## (`const ErrorCodes := preload(...)`) introduced in #412. The alias is
## stylistic; both `McpErrorCodes.X` and `ErrorCodes.X` resolve through the
## same Script object cache, so the alias is not a parse-safety boundary
## under the single-phase runner.

const INVALID_PARAMS := "INVALID_PARAMS"
const EDITED_SCENE_MISMATCH := "EDITED_SCENE_MISMATCH"
const EDITOR_NOT_READY := "EDITOR_NOT_READY"
const UNKNOWN_COMMAND := "UNKNOWN_COMMAND"
const INTERNAL_ERROR := "INTERNAL_ERROR"
const DEFERRED_TIMEOUT := "DEFERRED_TIMEOUT"
## #1120: filesystem mutation discovery failed before any disk effect
## (deadline/cancellation, entry/byte limits, unreadable owner metadata, a
## linked entry in the project walk, entries changing mid-discovery, or a UID
## the cache does not resolve). Keep this separate from INVALID_PARAMS so
## callers can distinguish an environmental discovery failure from a bad
## filesystem_manage request. `error.data.sub_code` names which refusal path.
const FILESYSTEM_DISCOVERY_FAILED := "FILESYSTEM_DISCOVERY_FAILED"
## #1120: why discovery refused, in `error.data.sub_code` of a
## FILESYSTEM_DISCOVERY_FAILED error, never as the top-level `error.code`.
## Each names one refusal path in handlers/filesystem_mutation.gd and carries
## no path, name or size, so it is safe to count in telemetry. Keep in sync
## with protocol/errors.py::FilesystemDiscoverySubCode — enforced by
## tests/unit/test_filesystem_discovery_sub_codes.py.
## The 25 s discovery deadline passed.
const DISCOVERY_SUB_EXPIRED := "DISCOVERY_EXPIRED"
## The caller stopped waiting (deferred response gone) before the deadline.
## Local to the job: a cancelled job's result is never delivered, so this
## never reaches the caller or telemetry.
const DISCOVERY_SUB_CANCELLED := "DISCOVERY_CANCELLED"
## The project walk passed MAX_ENTRIES.
const DISCOVERY_SUB_ENTRY_LIMIT := "DISCOVERY_ENTRY_LIMIT"
## Owner bytes read across the pass passed MAX_TOTAL_BYTES.
const DISCOVERY_SUB_BYTE_LIMIT := "DISCOVERY_BYTE_LIMIT"
## A script or text-resource owner is larger than MAX_FILE_BYTES.
const DISCOVERY_SUB_OWNER_TOO_LARGE := "DISCOVERY_OWNER_TOO_LARGE"
## A project directory could not be opened or listed.
const DISCOVERY_SUB_DIRECTORY_UNREADABLE := "DISCOVERY_DIRECTORY_UNREADABLE"
## An owner file could not be opened, sized or fully read.
const DISCOVERY_SUB_OWNER_UNREADABLE := "DISCOVERY_OWNER_UNREADABLE"
## A compressed binary owner's container could not be expanded.
const DISCOVERY_SUB_BINARY_UNREADABLE := "DISCOVERY_BINARY_UNREADABLE"
## The project walk met a symlink or junction it would have to look through.
const DISCOVERY_SUB_LINKED_ENTRY := "DISCOVERY_LINKED_ENTRY"
## Entries or owner bytes changed between discovery and revalidation.
const DISCOVERY_SUB_CHANGED := "DISCOVERY_CHANGED"
## An owner refers to a target by a UID the UID cache does not map to it.
const DISCOVERY_SUB_UID_UNRESOLVED := "DISCOVERY_UID_UNRESOLVED"
## Python-originated transport/attach bridge codes. GDScript has no emit path,
## but the public registry intentionally mirrors protocol/errors.py.
const TRANSPORT_OUTCOME_UNKNOWN := "TRANSPORT_OUTCOME_UNKNOWN"
const TRANSPORT_OVERLOADED := "TRANSPORT_OVERLOADED"
const NEW_CLIENT_SESSION_REQUIRED := "NEW_CLIENT_SESSION_REQUIRED"
const ATTACH_LOCK_TIMEOUT := "ATTACH_LOCK_TIMEOUT"
const ATTACH_LOCK_ERROR := "ATTACH_LOCK_ERROR"
const ATTACH_RUNTIME_DIR_ERROR := "ATTACH_RUNTIME_DIR_ERROR"
const PORT_OCCUPIED := "PORT_OCCUPIED"
const BACKEND_START_FAILED := "BACKEND_START_FAILED"
const BACKEND_START_TIMEOUT := "BACKEND_START_TIMEOUT"
# game_eval failure codes (#490) — keep in sync with protocol/errors.py
const EVAL_COMPILE_ERROR := "EVAL_COMPILE_ERROR"
const EVAL_RUNTIME_ERROR := "EVAL_RUNTIME_ERROR"
## #518/#859: the play session is up (EditorInterface.is_playing_scene() is true,
## so editor_handler's EDITOR_NOT_READY "game is not running" gate already
## passed) but the game cannot service evals: the helper did not register within
## EVAL_READY_WAIT_SEC, its main-loop beacon is stale, or its debugger session
## closed mid-eval. Carved out of INTERNAL_ERROR so these fast,
## caller-actionable failures do not burn the opaque 10s eval backstop.
const EVAL_GAME_NOT_READY := "EVAL_GAME_NOT_READY"
## #518: the eval genuinely never finished inside the timeout ladder — the
## game-side 8s deadline aborted a hung await, or the editor-side 10s backstop
## fired because the game never replied at all (CPU-bound loop, frozen /
## backgrounded idle loop). Carved out of INTERNAL_ERROR — the last big
## still-unlabeled bucket from #487/#488 — so "your eval code never finished"
## stops reading as an internal fault in telemetry and agent-facing errors.
const EVAL_HUNG := "EVAL_HUNG"
## #518: the eval completed but its serialized result is too large for the
## debugger + WebSocket pipeline. Without this the reply is dropped silently
## (the debugger TCP peer discards messages over ~8 MiB) and the request rides
## to the 10s backstop as a phantom "hang". Failing fast game-side with the
## real byte count makes the failure actionable (return a smaller slice).
const EVAL_RESULT_TOO_LARGE := "EVAL_RESULT_TOO_LARGE"
## #777: a game-side request (currently editor_screenshot source="game")
## reached a live, registered game helper but no reply came back before the
## editor-side timer fired. Every editor gate already passed
## (is_playing_scene, helper hello) so this is a TOP-LEVEL code, not an
## EDITOR_NOT_READY sub-code: the game process itself failed to respond —
## backgrounded with a frozen main loop and nothing rendered to fall back
## on, main thread blocked, or the helper died mid-run. Carved out of
## INTERNAL_ERROR (the largest opaque timeout bucket fleet-wide) so the
## residual timeout is attributable and actionable.
const GAME_HELPER_TIMEOUT := "GAME_HELPER_TIMEOUT"
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
const CUSTOM_TOOL_NOT_UNDOABLE := "CUSTOM_TOOL_NOT_UNDOABLE"
const CUSTOM_TOOL_DISABLED := "CUSTOM_TOOL_DISABLED"

## #651 stage 1: EDITOR_NOT_READY sub-codes. These travel in
## `error.data.sub_code`, NEVER as the top-level `error.code` — existing
## callers and dashboards key on EDITOR_NOT_READY, so the top-level code is
## frozen. Each sub-code names the concrete editor state at rejection time,
## limited to states EditorInterface/EditorFileSystem can report
## deterministically. States we cannot observe (script compilation,
## resource reload, modal dialogs) intentionally get NO sub-code: a bare
## EDITOR_NOT_READY stays the honest fallback rather than a guessed label.
## Keep in sync with protocol/errors.py::EditorNotReadySubCode — enforced
## by tests/unit/test_editor_not_ready_hint_contract.py.
const SUB_EDITOR_IMPORTING := "EDITOR_IMPORTING"
const SUB_EDITOR_PLAYING := "EDITOR_PLAYING"
const SUB_EDITOR_NO_SCENE := "EDITOR_NO_SCENE"
const SUB_EDITOR_GAME_NOT_RUNNING := "EDITOR_GAME_NOT_RUNNING"
const SUB_EDITOR_VIEWPORT_UNAVAILABLE := "EDITOR_VIEWPORT_UNAVAILABLE"
const SUB_EDITOR_VIEWPORT_NOT_3D := "EDITOR_VIEWPORT_NOT_3D"
const SUB_EDITOR_VIEWPORT_EMPTY := "EDITOR_VIEWPORT_EMPTY"
const SUB_EDITOR_UNAVAILABLE := "EDITOR_UNAVAILABLE"
## Emitted only by the exclusive-run transport servicing path: a command
## arrived while a synchronous test run holds the main thread, and was
## rejected (not buffered) so it can't replay stale after its server-side
## future expires. See connection.gd::service_transport_during_exclusive_run.
const SUB_EDITOR_TEST_RUNNING := "EDITOR_TEST_RUNNING"

## Terminal code for a test run that hit its between-test abort ceiling
## before finishing. error.data carries the partial summary; full partial
## results stay retrievable via get_test_results.
const TEST_RUN_TIMEOUT := "TEST_RUN_TIMEOUT"


## Build a standard error response dictionary.
static func make(code: String, message: String) -> Dictionary:
	return {"status": "error", "error": {"code": code, "message": message}}


## Build an EDITOR_NOT_READY error carrying the #651 stage-1 attribution
## payload: `data.sub_code` + `retryable` + `hint`. Mirrors the shape
## scene_path.gd::require_edited_scene established (editor_state/retryable/
## hint). `hint` may be empty when `message` already IS the recovery hint —
## the server's GodotCommandError string-appends every data key, so
## duplicating the message into data would double the agent-visible text.
static func make_not_ready(
	sub_code: String, message: String, retryable: bool, hint: String = ""
) -> Dictionary:
	var err := make(EDITOR_NOT_READY, message)
	var data := {"sub_code": sub_code, "retryable": retryable}
	if not hint.is_empty():
		data["hint"] = hint
	err["error"]["data"] = data
	return err


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
