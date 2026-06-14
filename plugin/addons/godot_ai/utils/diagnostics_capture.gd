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
	## some logger events have no path at all. Accept pathless/ephemeral entries
	## only when their structured details do not point at a different concrete
	## file; otherwise we would rewrite an unrelated diagnostic onto target_path.
	if path == target_path:
		return true
	if path.is_empty() or _is_ephemeral_gdscript_path(path):
		return not _details_conflict_with_target(entry.get("details", {}), target_path)
	return false


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


static func _details_conflict_with_target(details_value, target_path: String) -> bool:
	if not details_value is Dictionary:
		return false
	var details: Dictionary = details_value
	for key in ["source", "resolved"]:
		if _location_conflicts_with_target(details.get(key), target_path):
			return true
	if _locations_conflict_with_target(details.get("frames"), target_path):
		return true
	if _locations_conflict_with_target(details.get("children"), target_path):
		return true
	return false


static func _locations_conflict_with_target(items, target_path: String) -> bool:
	if not items is Array:
		return false
	for item in items:
		if _location_conflicts_with_target(item, target_path):
			return true
	return false


static func _location_conflicts_with_target(location_value, target_path: String) -> bool:
	if not location_value is Dictionary:
		return false
	var path := str(location_value.get("path", ""))
	return not path.is_empty() and not _is_ephemeral_gdscript_path(path) and path != target_path
