@tool
class_name McpDiagnosticsCapture
extends RefCounted

## Small helper for scoped validation-log capture windows. Callers snapshot a
## private log cursor, perform a deliberate validation action, then only report
## new diagnostics whose original source location is the target file.


static func capture_this_file(log_buffer: McpEditorLogBuffer, target_path: String, action: Callable) -> Dictionary:
	var cursor := 0
	if log_buffer != null:
		cursor = log_buffer.appended_total()

	var action_result = action.call()
	var diagnostics: Array[Dictionary] = []
	var truncated := false

	if log_buffer != null:
		var captured: Dictionary = log_buffer.get_since(cursor)
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
	var source := _source_location(entry)
	return str(source.get("path", "")) == target_path


static func _normalize_entry(entry: Dictionary, target_path: String) -> Dictionary:
	var normalized := entry.duplicate(true)
	var source := _source_location(entry)
	normalized["path"] = str(source.get("path", target_path))
	normalized["line"] = int(source.get("line", normalized.get("line", 0)))
	normalized["function"] = str(source.get("function", normalized.get("function", "")))
	if normalized.has("details") and normalized.details is Dictionary:
		normalized["details"] = normalized.details.duplicate(true)
	return normalized


static func _source_location(entry: Dictionary) -> Dictionary:
	if entry.get("details") is Dictionary:
		var details: Dictionary = entry.details
		if details.get("source") is Dictionary:
			return details.source
	return {}
