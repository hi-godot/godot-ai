@tool
class_name McpDiagnosticsCapture
extends RefCounted

## Small helper for scoped editor-log capture windows. Callers snapshot the
## editor log cursor, perform a deliberate validation action, then only report
## new diagnostics that can belong to the target file.


static func capture_this_file(editor_log_buffer: McpEditorLogBuffer, target_path: String, action: Callable) -> Dictionary:
	var cursor := 0
	if editor_log_buffer != null:
		cursor = editor_log_buffer.appended_total()

	var action_result = action.call()
	var diagnostics: Array[Dictionary] = []
	var truncated := false

	if editor_log_buffer != null:
		var captured: Dictionary = editor_log_buffer.get_since(cursor)
		truncated = captured.get("truncated", false)
		diagnostics = _diagnostics_for_target(captured.get("entries", []), target_path)

	return {
		"action": action_result if action_result is Dictionary else {},
		"diagnostics": diagnostics,
		"diagnostics_detail": "log_capture" if not diagnostics.is_empty() else "none",
		"diagnostics_scope": "this_file",
		"diagnostics_status": "partial" if truncated else "checked",
	}


static func _diagnostics_for_target(entries: Array, target_path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw_entry in entries:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry
		if not _entry_matches_target(entry, target_path):
			continue
		out.append(_normalize_entry(entry, target_path))
	return out


static func _entry_matches_target(entry: Dictionary, target_path: String) -> bool:
	var path := str(entry.get("path", ""))
	## Ephemeral GDScript reloads report synthetic `gdscript://...` paths, and
	## some logger events have no path at all. Accepting empty paths is a small
	## residual misattribution risk for concurrent pathless editor errors, but
	## the cursor window is deliberately narrow and this is the only way to keep
	## pathless validation diagnostics from being dropped.
	return path == target_path or path.is_empty() or _is_ephemeral_gdscript_path(path)


static func _normalize_entry(entry: Dictionary, target_path: String) -> Dictionary:
	var normalized := entry.duplicate(true)
	if _should_rewrite_path(str(normalized.get("path", "")), target_path):
		normalized["path"] = target_path
	if normalized.has("details") and normalized.details is Dictionary:
		normalized["details"] = _normalize_details(normalized.details, target_path)
	return normalized


static func _normalize_details(details: Dictionary, target_path: String) -> Dictionary:
	var normalized := details.duplicate(true)
	for key in ["source", "resolved"]:
		if normalized.get(key) is Dictionary:
			var location: Dictionary = normalized[key]
			if _should_rewrite_path(str(location.get("path", "")), target_path):
				location["path"] = target_path
			normalized[key] = location
	if normalized.get("frames") is Array:
		normalized["frames"] = _normalize_location_array(normalized.frames, target_path)
	if normalized.get("children") is Array:
		normalized["children"] = _normalize_location_array(normalized.children, target_path)
	return normalized


static func _normalize_location_array(items: Array, target_path: String) -> Array:
	var out := []
	for item in items:
		if item is Dictionary:
			var normalized: Dictionary = item.duplicate(true)
			if _should_rewrite_path(str(normalized.get("path", "")), target_path):
				normalized["path"] = target_path
			out.append(normalized)
		else:
			out.append(item)
	return out


static func _should_rewrite_path(path: String, _target_path: String) -> bool:
	return path.is_empty() or _is_ephemeral_gdscript_path(path)


static func _is_ephemeral_gdscript_path(path: String) -> bool:
	return path.begins_with("gdscript://")
