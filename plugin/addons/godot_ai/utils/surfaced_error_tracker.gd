@tool
class_name McpSurfacedErrorTracker
extends RefCounted

## Central source for "errors the agent should know exist".
##
## Editor log cursors only cover McpEditorLogBuffer. Runtime errors from the
## game subprocess can land solely in the Debugger Errors tab, so this tracker
## promotes visible Debugger-tab rows into a monotonic sequence before the
## dispatcher stamps a watermark on each response envelope.

const MAX_PROMOTED_DEBUGGER_ENTRIES := 500
const MAX_PROMOTED_DEBUGGER_KEYS := 5000
const DEBUGGER_REFRESH_MIN_INTERVAL_MS := 250
const DEBUGGER_SCAN_AFTER_STOP_MS := 5000
## #641: delays for the self-scheduled forced scans armed on run stop (and on
## game-helper hello, via McpDebuggerPlugin). Two ticks: an early one for rows
## the remote debugger delivers right around the event, and a late one past
## Godot's per-frame Errors-tab insertion throttle for error floods.
const DEFERRED_SCAN_DELAYS_SEC: Array[float] = [1.0, 5.0]

var _editor_log_buffer
var _game_log_buffer
var _debugger_errors_root: Node
var _debugger_search_root_cache: Node
var _promoted_debugger_keys: Dictionary = {}
var _promoted_debugger_key_order: Array[String] = []
var _promoted_debugger_entries: Array[Dictionary] = []
var _debugger_promoted_total := 0
var _run_seq := 0
var _oldest_retained_debugger_sequence := 1
var _last_debugger_refresh_msec := -DEBUGGER_REFRESH_MIN_INTERVAL_MS
var _debugger_scan_active := false
var _debugger_scan_until_msec := 0
var _deferred_scans_scheduled_total := 0


func _init(editor_log_buffer = null, game_log_buffer = null, debugger_errors_root: Node = null) -> void:
	_editor_log_buffer = editor_log_buffer
	_game_log_buffer = game_log_buffer
	_debugger_errors_root = debugger_errors_root


func note_game_run_started(sticky_scan: bool = true) -> void:
	_run_seq += 1
	_debugger_scan_active = sticky_scan
	_debugger_scan_until_msec = 0
	if not sticky_scan:
		_debugger_scan_until_msec = Time.get_ticks_msec() + DEBUGGER_SCAN_AFTER_STOP_MS
	refresh_debugger_errors(true)


func note_game_run_stopped() -> void:
	_debugger_scan_active = false
	_debugger_scan_until_msec = Time.get_ticks_msec() + DEBUGGER_SCAN_AFTER_STOP_MS
	schedule_deferred_scans()


## #641: promotion into the watermark used to depend on a tool call arriving
## while the scan gate was open (run active, or within DEBUGGER_SCAN_AFTER_STOP_MS
## of stop). Boot parse errors that landed in the Errors tab with no tool call
## in that window were never promoted, so the agent never got the
## new_errors_since_last_call hint. These editor-side timers force a scan
## regardless of tool-call cadence; the next stamped response then carries the
## already-promoted count even after the gate closes. Scans are content-keyed
## and idempotent, so a timer firing after an unrelated new run is harmless.
func schedule_deferred_scans(delays: Array = DEFERRED_SCAN_DELAYS_SEC) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for delay in delays:
		var timer := tree.create_timer(maxf(0.05, float(delay)))
		timer.timeout.connect(_on_deferred_scan_timeout)
		_deferred_scans_scheduled_total += 1


func deferred_scans_scheduled_total() -> int:
	return _deferred_scans_scheduled_total


func _on_deferred_scan_timeout() -> void:
	refresh_debugger_errors(true)


func refresh_debugger_errors(force: bool = true) -> void:
	var now := Time.get_ticks_msec()
	if not force and not _should_scan_debugger_for_cached_watermark(now):
		return
	_last_debugger_refresh_msec = now
	var current_by_key: Dictionary = {}
	for entry in _raw_debugger_error_entries():
		if str(entry.get("level", "")) != "error":
			continue
		var key := _log_entry_key(entry)
		var info: Dictionary = current_by_key.get(key, {"count": 0, "entry": entry})
		info["count"] = int(info.get("count", 0)) + 1
		current_by_key[key] = info
	for key in _promoted_debugger_keys.keys():
		if not current_by_key.has(key):
			_promoted_debugger_keys[key] = 0
	for key in current_by_key.keys():
		var info: Dictionary = current_by_key[key]
		var current := int(info.get("count", 0))
		var stored := int(_promoted_debugger_keys.get(key, 0))
		if current < stored:
			_promoted_debugger_keys[key] = current
			continue
		if current == stored:
			continue
		if not _promoted_debugger_keys.has(key):
			_promoted_debugger_key_order.append(key)
		_promoted_debugger_keys[key] = current
		_debugger_promoted_total += current - stored
		var source_entry: Dictionary = info.get("entry", {})
		var promoted := source_entry.duplicate(true)
		promoted["_debugger_key"] = key
		promoted["_debugger_occurrences"] = current
		promoted["_debugger_sequence"] = _debugger_promoted_total
		_remove_promoted_debugger_entry(key)
		_promoted_debugger_entries.append(promoted)
	_trim_promoted_debugger_entries()
	_trim_promoted_debugger_key_counts()


## #645: promote an error record that has no Errors-tab row to scrape — e.g. a
## boot-time parse error that parked the game in a remote-debugger break before
## any surface got a record. The entry joins the same promoted sequence as
## scraped Debugger rows, so run-scoping (editor_entries_since), the retained
## fallback, and the response watermark all see it with no extra plumbing.
## Re-recording the same key later (the same script still broken on the next
## run) re-promotes it with a fresh sequence, mirroring how re-appearing
## Errors-tab rows behave; scan reconciliation zeroes the key's count once the
## break ends since the row never exists in the live tab.
func record_synthetic_error(entry: Dictionary) -> void:
	var key := _log_entry_key(entry)
	var occurrences := int(_promoted_debugger_keys.get(key, 0)) + 1
	if not _promoted_debugger_keys.has(key):
		_promoted_debugger_key_order.append(key)
	_promoted_debugger_keys[key] = occurrences
	_debugger_promoted_total += 1
	var promoted := entry.duplicate(true)
	promoted["_debugger_key"] = key
	promoted["_debugger_occurrences"] = occurrences
	promoted["_debugger_sequence"] = _debugger_promoted_total
	promoted["_debugger_synthetic"] = true
	_remove_promoted_debugger_entry(key)
	_promoted_debugger_entries.append(promoted)
	_trim_promoted_debugger_entries()
	_trim_promoted_debugger_key_counts()


func watermark(force_debugger_scan: bool = false) -> Dictionary:
	refresh_debugger_errors(force_debugger_scan)
	return {
		"run_seq": _run_seq,
		"editor_ring": _error_appended_total(),
		"debugger_promoted": _debugger_promoted_total,
		"game_error_warn": _game_error_total(),
	}


static func stamp_watermark(response: Dictionary, tracker) -> void:
	if tracker == null:
		return
	if not tracker.has_method("watermark"):
		return
	response["error_watermark"] = tracker.watermark()


func debugger_promoted_total(force_debugger_scan: bool = true) -> int:
	refresh_debugger_errors(force_debugger_scan)
	return _debugger_promoted_total


func collect_editor_log_entries() -> Array[Dictionary]:
	refresh_debugger_errors(true)
	var entries: Array[Dictionary] = []
	var seen_keys: Dictionary = {}
	if _editor_log_buffer != null:
		for entry in _editor_log_buffer.get_range(0, _editor_log_buffer.total_count()):
			seen_keys[_log_entry_key(entry)] = true
			entries.append(entry)
	for entry in read_debugger_error_entries():
		var key := _log_entry_key(entry)
		if seen_keys.has(key):
			continue
		seen_keys[key] = true
		entries.append(entry)
	## #645: synthesized break records have no live Errors-tab row to scrape —
	## merge them from the promoted list so logs_read(source="editor") shows
	## the record that run/game responses point at.
	for entry in _promoted_debugger_entries:
		if not bool(entry.get("_debugger_synthetic", false)):
			continue
		var key := _log_entry_key(entry)
		if seen_keys.has(key):
			continue
		seen_keys[key] = true
		entries.append(_strip_promotion_bookkeeping(entry))
	return entries


static func _strip_promotion_bookkeeping(entry: Dictionary) -> Dictionary:
	var clean := entry.duplicate(true)
	for key in ["_debugger_key", "_debugger_occurrences", "_debugger_sequence", "_debugger_synthetic"]:
		clean.erase(key)
	return clean


func editor_entries_since(editor_cursor: int, debugger_cursor: int, force_debugger_scan: bool = true) -> Dictionary:
	refresh_debugger_errors(force_debugger_scan)
	var entries: Array[Dictionary] = []
	var seen_keys: Dictionary = {}
	var truncated := false
	if _editor_log_buffer != null:
		var captured: Dictionary = _editor_log_buffer.get_since(maxi(0, editor_cursor), -1)
		truncated = bool(captured.get("truncated", false))
		for entry in captured.get("entries", []):
			seen_keys[_log_entry_key(entry)] = true
			entries.append(entry)
	if debugger_cursor < _oldest_retained_debugger_sequence - 1:
		truncated = true
	for entry in _promoted_debugger_entries:
		if int(entry.get("_debugger_sequence", 0)) <= debugger_cursor:
			continue
		var key := _log_entry_key(entry)
		if seen_keys.has(key):
			continue
		seen_keys[key] = true
		entries.append(entry)
	return {
		"entries": entries,
		"truncated": truncated,
	}


func retained_recent_editor_entries() -> Array[Dictionary]:
	## There is no shared timestamp across the editor logger ring and Godot's
	## Debugger Errors tree. Preserve the pre-PR fallback contract: newest
	## buffered editor entries first, then debugger-only rows that were not in
	## the ring, so stale Debugger rows cannot outrank newer ring entries.
	var entries: Array[Dictionary] = []
	var seen_keys: Dictionary = {}
	if _editor_log_buffer != null:
		entries = _editor_log_buffer.get_recent(_editor_log_buffer.total_count())
		entries.reverse()
		for entry in entries:
			seen_keys[_log_entry_key(entry)] = true
	for entry in collect_editor_log_entries():
		var key := _log_entry_key(entry)
		if seen_keys.has(key):
			continue
		seen_keys[key] = true
		entries.append(entry)
	return entries


func read_debugger_error_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var seen_keys: Dictionary = {}
	for entry in _raw_debugger_error_entries():
		var key := _log_entry_key(entry)
		if seen_keys.has(key):
			continue
		seen_keys[key] = true
		entries.append(entry)
	return entries


func locate_debugger_error_trees() -> Array[Tree]:
	var trees: Array[Tree] = []
	var root: Node = _debugger_errors_root
	## #641: a deferred-scan timer can outlive an injected root (tests,
	## teardown). A freed root must not fall through to the live editor UI —
	## that would promote unrelated real errors into a tracker scoped to the
	## dead root — so treat it as "nothing to scan".
	if root != null and not is_instance_valid(root):
		return trees
	if root == null:
		root = _debugger_search_root()
	if root == null:
		return trees
	_collect_debugger_error_trees(root, trees)
	return trees


func clear_debugger_error_trees() -> int:
	var cleared := 0
	for tree in locate_debugger_error_trees():
		cleared += entries_from_debugger_error_tree(tree).size()
		if not _press_debugger_clear_button(tree):
			## Synthetic roots in tests do not have Godot's Clear button.
			tree.clear()
	return cleared


func _debugger_search_root() -> Node:
	if is_instance_valid(_debugger_search_root_cache):
		return _debugger_search_root_cache
	_debugger_search_root_cache = null
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	_debugger_search_root_cache = _find_first_of_class(base, "EditorDebuggerNode")
	if _debugger_search_root_cache == null:
		return base
	return _debugger_search_root_cache


static func _find_first_of_class(node: Node, klass: String) -> Node:
	if node.get_class() == klass:
		return node
	for child in node.get_children():
		var found := _find_first_of_class(child, klass)
		if found != null:
			return found
	return null


static func _collect_debugger_error_trees(node: Node, out: Array[Tree]) -> void:
	if node is Tree and _tree_has_debugger_errors(node as Tree):
		out.append(node as Tree)
	for child in node.get_children():
		if child is Node:
			_collect_debugger_error_trees(child as Node, out)


static func _tree_has_debugger_errors(tree: Tree) -> bool:
	var root := tree.get_root()
	if root == null:
		return false
	var item := root.get_first_child()
	while item != null:
		if _is_debugger_error_item(item):
			return true
		item = item.get_next()
	return false


static func _press_debugger_clear_button(tree: Tree) -> bool:
	var parent := tree.get_parent()
	if parent == null:
		return false
	var stack: Array[Node] = [parent]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is BaseButton:
			for conn in node.get_signal_connection_list("pressed"):
				if str(conn.get("callable", "")).contains("_clear_errors_list"):
					node.emit_signal("pressed")
					return true
		for child in node.get_children():
			stack.push_back(child)
	return false


static func entries_from_debugger_error_tree(tree: Tree) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var root := tree.get_root()
	if root == null:
		return entries
	var item := root.get_first_child()
	while item != null:
		if _is_debugger_error_item(item):
			entries.append(_entry_from_debugger_error_item(item))
		item = item.get_next()
	return entries


static func _entry_from_debugger_error_item(item: TreeItem) -> Dictionary:
	var title := item.get_text(1)
	var loc := _location_from_metadata(item.get_metadata(0))
	var function := _function_from_title(title)
	return {
		"source": "editor",
		"level": "warn" if item.has_meta("_is_warning") else "error",
		"text": title,
		"path": str(loc.get("path", "")),
		"line": int(loc.get("line", 0)),
		"function": function,
		"details": _details_from_debugger_error_item(item, loc, function),
	}


static func _details_from_debugger_error_item(item: TreeItem, loc: Dictionary, function: String) -> Dictionary:
	var children: Array[Dictionary] = []
	var child := item.get_first_child()
	while child != null:
		var child_loc := _location_from_metadata(child.get_metadata(0))
		children.append({
			"label": child.get_text(0),
			"text": child.get_text(1),
			"path": str(child_loc.get("path", "")),
			"line": int(child_loc.get("line", 0)),
		})
		child = child.get_next()
	return {
		"debugger_tab": "Errors",
		"time": item.get_text(0),
		"message": item.get_text(1),
		"error_type_name": "warning" if item.has_meta("_is_warning") else "error",
		"source": {
			"path": str(loc.get("path", "")),
			"line": int(loc.get("line", 0)),
			"function": function,
		},
		"resolved": {
			"path": str(loc.get("path", "")),
			"line": int(loc.get("line", 0)),
			"function": function,
		},
		"children": children,
		"frames": _frames_from_error_children(children),
	}


static func _is_debugger_error_item(item: TreeItem) -> bool:
	return item.has_meta("_is_warning") or item.has_meta("_is_error")


static func _frames_from_error_children(children: Array[Dictionary]) -> Array[Dictionary]:
	var start := -1
	for i in children.size():
		if str(children[i].label).contains("Stack Trace"):
			start = i
			break
	if start < 0:
		for i in children.size():
			if str(children[i].label).is_empty() and not str(children[i].path).is_empty():
				start = maxi(i - 1, 0)
				break
	if start < 0:
		return []
	var frames: Array[Dictionary] = []
	for i in range(start, children.size()):
		if str(children[i].path).is_empty():
			continue
		frames.append({
			"path": children[i].path,
			"line": children[i].line,
			"function": _function_from_frame_text(children[i].text),
		})
	return frames


static func _location_from_metadata(meta: Variant) -> Dictionary:
	if meta is Array and meta.size() >= 2:
		return {"path": str(meta[0]), "line": int(meta[1])}
	return {"path": "", "line": 0}


static func _function_from_title(title: String) -> String:
	var colon := title.find(": ")
	if colon <= 0:
		return ""
	return title.substr(0, colon)


static func _function_from_frame_text(text: String) -> String:
	var marker := text.find(" @ ")
	if marker < 0:
		return ""
	var fn := text.substr(marker + 3).strip_edges()
	if fn.ends_with("()"):
		fn = fn.substr(0, fn.length() - 2)
	return fn


## Shared one-line rendering of a compact editor-error entry for messages and
## hints ("text (path:line)"). Single home so the debugger plugin, project
## handler, and editor handler can't drift apart.
static func format_editor_error_summary(entry: Dictionary) -> String:
	var text := str(entry.get("text", "editor error"))
	var path := str(entry.get("path", ""))
	var line := int(entry.get("line", 0))
	if not path.is_empty() and line > 0:
		return "%s (%s:%d)" % [text, path, line]
	if not path.is_empty():
		return "%s (%s)" % [text, path]
	return text


static func _log_entry_key(entry: Dictionary) -> String:
	return "%s|%s|%s|%s" % [
		str(entry.get("level", "")),
		str(entry.get("text", "")),
		str(entry.get("path", "")),
		str(entry.get("line", 0)),
	]


func _error_appended_total() -> int:
	if _editor_log_buffer == null:
		return 0
	if _editor_log_buffer.has_method("error_appended_total"):
		return int(_editor_log_buffer.call("error_appended_total"))
	return 0


func _game_error_total() -> int:
	if _game_log_buffer == null:
		return 0
	if _game_log_buffer.has_method("error_total"):
		return int(_game_log_buffer.call("error_total"))
	return 0


func _should_scan_debugger_for_cached_watermark(now_msec: int) -> bool:
	if not _debugger_scan_active and now_msec > _debugger_scan_until_msec:
		return false
	return now_msec - _last_debugger_refresh_msec >= DEBUGGER_REFRESH_MIN_INTERVAL_MS


func _trim_promoted_debugger_entries() -> void:
	while _promoted_debugger_entries.size() > MAX_PROMOTED_DEBUGGER_ENTRIES:
		_promoted_debugger_entries.pop_front()
	if _promoted_debugger_entries.is_empty():
		_oldest_retained_debugger_sequence = _debugger_promoted_total + 1
	else:
		_oldest_retained_debugger_sequence = int(_promoted_debugger_entries[0].get("_debugger_sequence", 1))


func _trim_promoted_debugger_key_counts() -> void:
	while _promoted_debugger_key_order.size() > MAX_PROMOTED_DEBUGGER_KEYS:
		var key := _promoted_debugger_key_order.pop_front()
		_promoted_debugger_keys.erase(key)


func _remove_promoted_debugger_entry(key: String) -> void:
	for i in range(_promoted_debugger_entries.size() - 1, -1, -1):
		if str(_promoted_debugger_entries[i].get("_debugger_key", "")) == key:
			_promoted_debugger_entries.remove_at(i)
			return


func _raw_debugger_error_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for tree in locate_debugger_error_trees():
		entries.append_array(entries_from_debugger_error_tree(tree))
	return entries
