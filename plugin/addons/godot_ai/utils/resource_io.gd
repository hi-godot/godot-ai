@tool
class_name McpResourceIO
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Shared helpers for "save a Resource to .tres" and the mutually-exclusive
## path-vs-resource_path param validation that every resource-authoring
## handler needs. Extracted to remove 4-way duplication across
## resource_handler, environment_handler, texture_handler, and curve_handler.
## Also home to the shared write-a-text-file path + deferred import-settle
## completion used by both script_handler.create_script and
## filesystem_handler.write_file (#714).

# Bounded settle window for `ResourceLoader.exists(path)` after a fresh text
# write registers with the filesystem, so an agent calling
# create_script/write_file -> attach_script back-to-back doesn't race the
# editor's import pipeline (#261, extended to write_file by #714). Polled once
# per frame, with an elapsed-time cap below the dispatcher's deferred timeouts
# for both commands. If import is still not visible at the cap, we still
# return committed data instead of letting the already-written file surface
# as DEFERRED_TIMEOUT.
const IMPORT_SETTLE_MAX_FRAMES := 300
const IMPORT_SETTLE_MAX_MSEC := 3500


## Validate that exactly one of {path, resource_path} is provided.
##
## When `require_property` is true (default), also requires a non-empty
## `property` param when `path` is given — this matches the semantics of
## "assign a resource to node.property" (resource_create, texture tools,
## curve_set_points). Pass false for tools where the path itself IS the
## target (environment_create assigning to WorldEnvironment.environment).
##
## Returns null on success or an error dict on failure.
static func validate_home(params: Dictionary, require_property: bool = true) -> Variant:
	var node_path: String = params.get("path", "")
	var property: String = params.get("property", "")
	var resource_path: String = params.get("resource_path", "")
	var has_node_target := not node_path.is_empty()
	var has_file_target := not resource_path.is_empty()

	if has_node_target and has_file_target:
		var both_msg := "Provide either path+property or resource_path, not both" if require_property else "Provide either path or resource_path, not both"
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, both_msg)
	if not has_node_target and not has_file_target:
		var none_msg := "Must provide either path+property (assign inline) or resource_path (save .tres)" if require_property else "Must provide either path or resource_path"
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, none_msg)
	if require_property and has_node_target and property.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Missing required param: property (required when path is given)")
	return null


## Save `res` to `resource_path` as a .tres/.res file.
##
## Handles: res:// prefix validation, overwrite check, parent-directory
## creation, ResourceSaver.save error reporting, and the post-save
## EditorFileSystem.update_file() so the dock picks up the change.
##
## `label` is the human-readable resource-kind for error messages (e.g.
## "Environment", "Gradient texture", "Curve"). `extra_fields` is merged
## into the success response alongside the standard fields
## (`resource_path`, `overwritten`, `undoable: false`, `reason`). Passing
## a `reason` key in `extra_fields` overrides the default — useful for
## tools that edit existing files rather than creating fresh ones.
##
## `pause_target` should be the handler's `McpConnection`. When supplied,
## `pause_processing` is flipped on around `ResourceSaver.save()` so the
## dispatcher's WebSocket pump can't re-enter while Godot pumps
## `Main::iteration()` for the resource-save's progress UI / script-class
## update task. Without this guard a queued command landing during the
## save can trigger another `save_to_disk` that tries to add the same
## `update_scripts_classes` editor task — "Task already exists" → null
## deref → SIGSEGV. Same family of bug as godotengine/godot#118545 and
## the same mitigation as `SceneHandler`'s `save_scene*` wraps. See
## issue #288.
##
## Returns either an error dict or a {"data": {...}} success dict — ready
## for the handler to return directly.
static func save_to_disk(
	res: Resource,
	resource_path: String,
	overwrite: bool,
	label: String,
	extra_fields: Dictionary = {},
	pause_target: McpConnection = null,
) -> Dictionary:
	var path_err = McpPathValidator.path_error(resource_path, "resource_path", true)
	if path_err != null:
		return path_err

	var existed_before := FileAccess.file_exists(resource_path)
	if existed_before and not overwrite:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"%s already exists at %s (pass overwrite=true to replace)" % [label, resource_path]
		)
	# Captured BEFORE the overwrite below so a resave of an already-uid'd file
	# (overwrite=true) can restore its own uid instead of losing it — see
	# ensure_uid's doc comment.
	var prior_uid := ResourceLoader.get_resource_uid(resource_path) if existed_before else ResourceUID.INVALID_ID

	var dir_path := resource_path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to create directory %s: %s" % [dir_path, error_string(mkdir_err)]
		)

	if pause_target != null:
		pause_target.pause_processing = true
	var save_err := ResourceSaver.save(res, resource_path)
	if pause_target != null:
		pause_target.pause_processing = false
	if save_err != OK:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to save %s to %s: %s" % [label, resource_path, error_string(save_err)]
		)
	var uid_err := ensure_uid(resource_path, prior_uid)
	if uid_err != OK:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"%s saved to %s but failed to write its uid: %s" % [label, resource_path, error_string(uid_err)]
		)

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(resource_path)

	var data := {
		"resource_path": resource_path,
		"overwritten": existed_before,
		"undoable": false,
		"reason": "File creation is persistent; delete the file manually to revert",
	}
	attach_cleanup_hint(data, existed_before, [resource_path])
	# merge with overwrite=true so callers (e.g. curve_set_points editing an
	# existing .tres) can supply a domain-specific `reason`.
	data.merge(extra_fields, true)
	return {"data": data}


## Save `res` to `resource_path` with the same `pause_processing` re-entrancy
## guard as `save_to_disk` (see its doc for the #288 SIGSEGV background), for
## call sites that need to pick their own error handling / overwrite policy
## instead of `save_to_disk`'s full validate+mkdir+overwrite-guard bundle
## (undo/redo callables reloading-mutating-resaving an existing resource,
## `apply_to_node`'s inline-then-save branch). Returns the raw
## `ResourceSaver.save` error code.
static func guarded_save(res: Resource, resource_path: String, pause_target: McpConnection) -> int:
	var prior_uid := ResourceLoader.get_resource_uid(resource_path) if FileAccess.file_exists(resource_path) else ResourceUID.INVALID_ID
	if pause_target != null:
		pause_target.pause_processing = true
	var save_err := ResourceSaver.save(res, resource_path)
	if pause_target != null:
		pause_target.pause_processing = false
	if save_err != OK:
		return save_err
	return ensure_uid(resource_path, prior_uid)


## Make `resource_path` carry a stable uid after a successful
## `ResourceSaver.save()`, matching what Godot's own "New Scene"/"New
## Resource" editor flows always embed. A bare `ResourceSaver.save()` call
## does neither on its own: a brand-new file gets no `uid=` at all, and
## resaving a file that already had one silently drops it (#737). Call this
## immediately after every successful save.
##
## `prior_uid` is whatever `ResourceLoader.get_resource_uid(resource_path)`
## returned BEFORE this save overwrote the file (pass `ResourceUID.INVALID_ID`
## for a brand-new path). Reusing the prior id — instead of always minting a
## fresh one — keeps any `uid://...` references elsewhere in the project
## resolving to the same file.
##
## Returns the `Error` from `ResourceSaver.set_uid()` so callers can surface a
## uid-write failure instead of silently reporting success on a file that
## didn't end up with the uid it was supposed to get.
static func ensure_uid(resource_path: String, prior_uid: int) -> Error:
	var id := prior_uid
	if id == ResourceUID.INVALID_ID:
		id = ResourceUID.create_id()
	return ResourceSaver.set_uid(resource_path, id)


## Attach a `cleanup.rm` hint listing `paths` to `data` — only when the call
## just created a new file (`existed_before == false`). On overwrite the field
## is omitted because the caller already had the file on disk, and handing
## them a cleanup list would invite dropping user content instead of just
## scratch artifacts. Used by write-and-return handlers (create_script,
## filesystem_write_text, resource_create/save_to_disk) so callers running
## transient smoke tests can rm artifacts without tracking paths. See #82.
static func attach_cleanup_hint(data: Dictionary, existed_before: bool, paths: Array) -> void:
	if existed_before:
		return
	data["cleanup"] = {"rm": paths}


## Shared write-a-text-file path (#714): parent-directory mkdir, write +
## flush with an explicit error check so a truncated write (disk full,
## permission flip mid-write) surfaces as an error instead of plain success.
## Deliberately does NOT call `EditorFileSystem.update_file()` — callers
## register the file themselves after assembling their response fields, so
## the registration comment (the dsarno/godot#6 scan-stacking rationale)
## stays next to the call. Returns null on success or an error dict ready
## to return from the handler.
static func write_text_to_disk(path: String, content: String) -> Variant:
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file for writing: %s" % path)

	file.store_string(content)
	file.flush()
	var write_err := file.get_error()
	file.close()
	if write_err != OK:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Write failed for %s (%s); file may be truncated" % [path, error_string(write_err)]
		)
	return null


# `static` is load-bearing: the deferred completion captures no `self`, so the
# coroutine survives even if the calling handler RefCounted is freed mid-await.
# Under concurrent create storms with editor_reload_plugin fired during the
# burst, an instance-method coroutine is otherwise GC'd between `await` and
# resume, producing "Resumed function ... after await, but class instance is
# gone" errors and dropping the response. Keep this function static and
# parameterise everything it needs explicitly — do not reference instance
# state. Shared by create_script and write_file's fresh-`.gd` path (#714).
static func finish_text_write_deferred(
	connection: McpConnection,
	request_id: String,
	path: String,
	data: Dictionary,
) -> void:
	if not is_instance_valid(connection):
		return
	var tree := connection.get_tree()
	if tree == null:
		return
	var deadline_ms := Time.get_ticks_msec() + IMPORT_SETTLE_MAX_MSEC
	# Let _dispatch() return DEFERRED_RESPONSE and register the request before
	# this coroutine can send a committed result. ResourceLoader.exists(path)
	# may already be true on fast imports; without this handoff the connection
	# treats the response as late/unregistered and drops it, then the dispatcher
	# times out a file that was already written (#324). The deadline starts
	# before this await so a slow handoff frame is counted against the bounded
	# settle window.
	await tree.process_frame
	var frames := 0
	while (
		frames < IMPORT_SETTLE_MAX_FRAMES
		and Time.get_ticks_msec() < deadline_ms
		and not ResourceLoader.exists(path)
	):
		await tree.process_frame
		frames += 1
	# If the plugin tears down (_exit_tree frees the connection) during the
	# await, is_instance_valid() goes false and we drop the response silently —
	# the server's request timeout will surface the failure to the caller.
	if not is_instance_valid(connection):
		return
	var payload := data.duplicate()
	var settled := ResourceLoader.exists(path)
	payload["import_settled"] = settled
	payload["import_settle"] = "settled" if settled else "timeout"
	payload["import_pending"] = not settled
	connection.send_deferred_response(request_id, {"data": payload})
