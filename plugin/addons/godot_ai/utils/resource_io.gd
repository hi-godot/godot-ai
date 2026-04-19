@tool
class_name ResourceIO
extends RefCounted

## Shared helpers for "save a Resource to .tres" and the mutually-exclusive
## path-vs-resource_path param validation that every resource-authoring
## handler needs. Extracted to remove 4-way duplication across
## resource_handler, environment_handler, texture_handler, and curve_handler.


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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, both_msg)
	if not has_node_target and not has_file_target:
		var none_msg := "Must provide either path+property (assign inline) or resource_path (save .tres)" if require_property else "Must provide either path or resource_path"
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, none_msg)
	if require_property and has_node_target and property.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: property (required when path is given)")
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
## Returns either an error dict or a {"data": {...}} success dict — ready
## for the handler to return directly.
static func save_to_disk(res: Resource, resource_path: String, overwrite: bool, label: String, extra_fields: Dictionary = {}) -> Dictionary:
	if not resource_path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "resource_path must start with res://")

	var existed_before := FileAccess.file_exists(resource_path)
	if existed_before and not overwrite:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s already exists at %s (pass overwrite=true to replace)" % [label, resource_path]
		)

	var dir_path := resource_path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to create directory %s: %s" % [dir_path, error_string(mkdir_err)]
		)

	var save_err := ResourceSaver.save(res, resource_path)
	if save_err != OK:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to save %s to %s: %s" % [label, resource_path, error_string(save_err)]
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
