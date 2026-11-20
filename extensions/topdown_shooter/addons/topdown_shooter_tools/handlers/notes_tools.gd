@tool
extends RefCounted

## Handler for playtest_notes: notes left in game with F9 (F8 on macOS).
##
## The in-game side is playtest_notes_overlay.gd, copied from a template and
## registered as the PlaytestNotes autoload. It writes one <id>.json plus an
## <id>.png per note into res://playtest_notes/ (a .gdignore keeps the editor
## from importing the screenshots). This handler reads those files, shows
## the notes as pins in the edited 3D scene and marks them resolved.
##
## Status changes and deletes are one editor undo step each (global history,
## the files are restored byte for byte). Pins in the editor are view-only:
## they have no owner, so they are never saved into the scene.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const OVERLAY_TEMPLATE := "playtest_notes_overlay.gd.tmpl"
const OVERLAY_FILE := "playtest_notes_overlay.gd"
const AUTOLOAD_NAME := "PlaytestNotes"
const NOTES_DIR := "res://playtest_notes/"
const MARKERS_NAME := "PlaytestNoteMarkers"
const OPS := ["list", "get", "resolve", "reopen", "delete", "markers", "clear_markers", "install", "uninstall"]
const STATUSES := ["open", "resolved", "all"]
const CATEGORY_COLORS := {
	"bug": Color(0.95, 0.25, 0.2),
	"balance": Color(0.95, 0.7, 0.15),
	"level": Color(0.3, 0.7, 1.0),
	"idea": Color(0.45, 0.85, 0.4),
	"other": Color(0.8, 0.8, 0.8),
}
## Folder the notes live in (tests point it elsewhere).
var notes_dir := NOTES_DIR

const ALLOWED := {
	"list": ["op", "status", "scene", "category", "limit"],
	"get": ["op", "id"],
	"resolve": ["op", "id", "ids", "resolution"],
	"reopen": ["op", "id", "ids"],
	"delete": ["op", "id", "ids"],
	"markers": ["op", "status", "scene"],
	"clear_markers": ["op"],
	"install": ["op", "script_dir", "overwrite_scripts"],
	"uninstall": ["op"],
}


func playtest_notes(params: Dictionary, _ctx = null) -> Dictionary:
	var op: Variant = Util.text(params, "op", "list")
	if Util.is_error(op):
		return op
	if not OPS.has(op):
		return Util.error(Util.INVALID_PARAMS, "'op' must be one of %s, got '%s'" % [", ".join(OPS), op])
	for key in params:
		if not ALLOWED[op].has(key):
			return Util.error(Util.INVALID_PARAMS, "op='%s' does not take '%s' (allowed: %s)" % [op, key, ", ".join(ALLOWED[op])])
	match op:
		"get":
			return _op_get(params)
		"resolve":
			return _op_set_status(params, "resolved")
		"reopen":
			return _op_set_status(params, "open")
		"delete":
			return _op_delete(params)
		"markers":
			return _op_markers(params)
		"clear_markers":
			return {"data": {"removed": clear_markers(), "undoable": false, "undo_reason": "pins are view-only and never saved into the scene"}}
		"install":
			var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
			if Util.is_error(script_dir):
				return script_dir
			var dir := Util.clean_dir(script_dir)
			var reason := Util.check_res_path(dir + "/x.gd", "gd")
			if not reason.is_empty():
				return Util.error(Util.INVALID_PARAMS, "'script_dir': " + reason)
			var overwrite: Variant = Util.boolean(params, "overwrite_scripts", false)
			if Util.is_error(overwrite):
				return overwrite
			return install(dir, overwrite)
		"uninstall":
			return _uninstall()
	return _op_list(params)


# --- reading -----------------------------------------------------------------------

## Every note on disk, oldest first. Broken files are reported, not skipped
## silently.
static func load_notes(dir: String) -> Dictionary:
	var notes: Array = []
	var broken: Array = []
	if DirAccess.dir_exists_absolute(dir):
		for file in DirAccess.get_files_at(dir):
			if file.get_extension() != "json":
				continue
			var data: Variant = parse_json(FileAccess.get_file_as_string(dir + file))
			if data is Dictionary and not str(data.get("id", "")).is_empty():
				notes.append(data)
			else:
				broken.append(dir + file)
	notes.sort_custom(func(a, b): return float(a.get("created_unix", 0.0)) < float(b.get("created_unix", 0.0)))
	return {"notes": notes, "broken": broken}


## JSON.parse_string() logs an engine error for a broken file; this does not.
static func parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func filter_notes(notes: Array, status: String, scene: String, category: String) -> Array:
	var out: Array = []
	for note in notes:
		if status != "all" and str(note.get("status", "open")) != status:
			continue
		if not scene.is_empty() and str(note.get("scene", "")) != scene:
			continue
		if not category.is_empty() and str(note.get("category", "")) != category:
			continue
		out.append(note)
	return out


## The compact form used by op=list.
static func summary(note: Dictionary) -> Dictionary:
	var out := {
		"id": note.get("id", ""),
		"status": note.get("status", "open"),
		"category": note.get("category", ""),
		"text": note.get("text", ""),
		"scene": note.get("scene", ""),
		"position": note.get("position", null),
		"created": note.get("created", ""),
	}
	for key in ["cursor_node", "resolution"]:
		if note.has(key):
			out[key] = note[key]
	var errors: Array = note.get("recent_errors", [])
	if not errors.is_empty():
		out["recent_errors"] = errors.size()
	var shot := str(note.get("screenshot", ""))
	if not shot.is_empty() and FileAccess.file_exists(shot):
		out["screenshot_path"] = ProjectSettings.globalize_path(shot)
	return out


func _read_filters(params: Dictionary, default_scene: String) -> Variant:
	var status: Variant = Util.text(params, "status", "open")
	if Util.is_error(status):
		return status
	if not STATUSES.has(status):
		return Util.error(Util.INVALID_PARAMS, "'status' must be one of %s, got '%s'" % [", ".join(STATUSES), status])
	var scene: Variant = Util.text(params, "scene", default_scene)
	if Util.is_error(scene):
		return scene
	if scene == "current":
		var root := Util.edited_root()
		scene = root.scene_file_path if root != null else ""
	if scene == "all":
		scene = ""
	if not scene.is_empty() and not scene.begins_with("res://"):
		return Util.error(Util.INVALID_PARAMS, "'scene' must be a res:// path, 'current' or 'all', got '%s'" % scene)
	return {"status": status, "scene": scene}


func _op_list(params: Dictionary) -> Dictionary:
	var filters: Variant = _read_filters(params, "")
	if Util.is_error(filters):
		return filters
	var category: Variant = Util.text(params, "category", "")
	if Util.is_error(category):
		return category
	var limit: Variant = Util.integer(params, "limit", 50, 1, 500)
	if Util.is_error(limit):
		return limit
	var loaded := load_notes(notes_dir)
	var all: Array = loaded.notes
	var matched := filter_notes(all, filters.status, filters.scene, category)
	var rows: Array = []
	## Newest last, keep the newest `limit`.
	for i in range(maxi(matched.size() - limit, 0), matched.size()):
		rows.append(summary(matched[i]))
	var open_count := 0
	for note in all:
		if str(note.get("status", "open")) == "open":
			open_count += 1
	var out := {
		"notes": rows,
		"count": matched.size(),
		"shown": rows.size(),
		"open_total": open_count,
		"resolved_total": all.size() - open_count,
		"notes_dir": ProjectSettings.globalize_path(notes_dir),
		"installed": ProjectSettings.has_setting(autoload_key()),
	}
	if not loaded.broken.is_empty():
		out["broken_files"] = loaded.broken
	if not out.installed:
		out["hint"] = "The in-game note key is not installed yet: call playtest_notes op='install', then press F9 while playing (F8 also works on macOS)."
	elif all.is_empty():
		out["hint"] = "No notes yet. Play the game and press F9 (or Ctrl/Cmd+N; F8 on macOS) where something is wrong."
	else:
		out["hint"] = "op='get' id=... returns the full note; open screenshot_path to see the screen (the red ring is the marked spot)."
	return {"data": out}


func _op_get(params: Dictionary) -> Dictionary:
	var ids: Variant = _read_ids(params)
	if Util.is_error(ids):
		return ids
	if ids.size() != 1:
		return Util.error(Util.INVALID_PARAMS, "op='get' takes one 'id'")
	var note: Variant = read_note(ids[0])
	if Util.is_error(note):
		return note
	var out: Dictionary = note.duplicate(true)
	var shot := str(note.get("screenshot", ""))
	out["screenshot_path"] = ProjectSettings.globalize_path(shot) if not shot.is_empty() else ""
	out["screenshot_exists"] = not shot.is_empty() and FileAccess.file_exists(shot)
	out["note_path"] = ProjectSettings.globalize_path(note_path(ids[0]))
	var root := Util.edited_root()
	if root != null and str(note.get("cursor_node", "")) != "":
		var node: Node = null
		if root.scene_file_path == str(note.get("scene", "")):
			node = Util.resolve(str(note.cursor_node), root)
		out["cursor_node_in_open_scene"] = node != null
	return {"data": out}


func note_path(id: String) -> String:
	return notes_dir + id + ".json"


static func valid_id(id: String) -> bool:
	if id.is_empty() or id.length() > 64:
		return false
	for c in id:
		if not (c == "-" or c == "_" or (c >= "0" and c <= "9") or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")):
			return false
	return true


func read_note(id: String) -> Variant:
	if not valid_id(id):
		return Util.error(Util.INVALID_PARAMS, "bad note id '%s'" % id)
	var path := note_path(id)
	if not FileAccess.file_exists(path):
		return Util.error(Util.NODE_NOT_FOUND, "no note '%s' in %s" % [id, notes_dir])
	var data: Variant = parse_json(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		return Util.error(Util.INTERNAL_ERROR, "%s is not a valid note (JSON)" % path)
	return data


func _read_ids(params: Dictionary) -> Variant:
	var ids: Array = []
	if params.has("id") and params.id != null:
		if not params.id is String:
			return Util.error(Util.INVALID_PARAMS, "'id' must be a string")
		ids.append(String(params.id).strip_edges())
	if params.has("ids") and params.ids != null:
		if not params.ids is Array:
			return Util.error(Util.INVALID_PARAMS, "'ids' must be an array of strings")
		for v in params.ids:
			if not v is String:
				return Util.error(Util.INVALID_PARAMS, "'ids' must be an array of strings")
			if not ids.has(String(v).strip_edges()):
				ids.append(String(v).strip_edges())
	if ids.is_empty():
		return Util.error(Util.INVALID_PARAMS, "pass 'id' (or 'ids')")
	for id in ids:
		if not valid_id(id):
			return Util.error(Util.INVALID_PARAMS, "bad note id '%s'" % id)
	return ids


# --- writing (undoable) ----------------------------------------------------------

func _op_set_status(params: Dictionary, status: String) -> Dictionary:
	var ids: Variant = _read_ids(params)
	if Util.is_error(ids):
		return ids
	var resolution: Variant = Util.text(params, "resolution", "")
	if Util.is_error(resolution):
		return resolution
	var notes := {}
	for id in ids:
		var note: Variant = read_note(id)
		if Util.is_error(note):
			return note
		notes[id] = note
	var paths: Array = []
	for id in ids:
		paths.append(note_path(id))
	var before := FileSnapshot.capture(paths)
	var changed: Array = []
	var stamp := Time.get_datetime_string_from_system(false, true)
	for id in ids:
		var note: Dictionary = notes[id]
		if str(note.get("status", "open")) == status and (status != "resolved" or resolution.is_empty()):
			continue
		note["status"] = status
		if status == "resolved":
			note["resolved"] = stamp
			if not resolution.is_empty():
				note["resolution"] = resolution
		else:
			note.erase("resolved")
			note["reopened"] = stamp
		var err := _write_json(note_path(id), note)
		if not err.is_empty():
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, err)
		changed.append(id)
	var out := {"ids": ids, "changed": changed, "status": status}
	if not changed.is_empty():
		_commit_undo("Playtest notes: mark %d %s" % [changed.size(), status], before, FileSnapshot.capture(paths))
		out["undo"] = "One editor undo step (Edit > Undo) restores the notes."
		_refresh_markers()
	return {"data": out}


func _op_delete(params: Dictionary) -> Dictionary:
	var ids: Variant = _read_ids(params)
	if Util.is_error(ids):
		return ids
	var paths: Array = []
	for id in ids:
		var note: Variant = read_note(id)
		if Util.is_error(note):
			return note
		paths.append(note_path(id))
		var shot := str(note.get("screenshot", ""))
		if shot.begins_with(notes_dir) and FileAccess.file_exists(shot):
			paths.append(shot)
	var before := FileSnapshot.capture(paths)
	for path in paths:
		var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if err != OK:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, "cannot delete %s: %s" % [path, error_string(err)])
	_commit_undo("Playtest notes: delete %d" % ids.size(), before, FileSnapshot.capture(paths))
	_refresh_markers()
	return {"data": {"deleted": ids, "files": paths, "undo": "One editor undo step (Edit > Undo) brings the notes and screenshots back."}}


func _commit_undo(action: String, before: FileSnapshot, after: FileSnapshot) -> void:
	if not Engine.is_editor_hint():
		return
	var ur := EditorInterface.get_editor_undo_redo()
	if ur == null:
		return
	## Note files are not scene edits: the action lives in the global history.
	ur.create_action(action, UndoRedo.MERGE_DISABLE, null, false, false)
	ur.add_do_method(after, "restore")
	ur.add_do_method(self, "_refresh_markers")
	ur.add_undo_method(before, "restore")
	ur.add_undo_method(self, "_refresh_markers")
	ur.commit_action(false)


static func _write_json(path: String, data: Dictionary) -> String:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "cannot write %s: %s" % [path, error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return ""


## Bytes of a set of files at one moment; restore() writes them back (a file
## that did not exist is deleted). Held by the undo history.
class FileSnapshot extends RefCounted:
	var files := {}

	static func capture(paths: Array) -> FileSnapshot:
		var snap := FileSnapshot.new()
		for path in paths:
			snap.files[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
		return snap

	func restore() -> void:
		for path in files:
			var bytes: Variant = files[path]
			if bytes == null:
				if FileAccess.file_exists(path):
					DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
				continue
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(String(path).get_base_dir()))
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				push_error("playtest_notes undo: cannot write %s" % path)
				continue
			f.store_buffer(bytes)
			f.close()


# --- editor pins -------------------------------------------------------------------

## Last op=markers filter, so status changes redraw the same pins.
var _marker_filters := {}


func _op_markers(params: Dictionary) -> Dictionary:
	var root := Util.edited_root()
	if root == null:
		return Util.no_scene_error()
	if not root is Node3D:
		return Util.error(Util.INVALID_PARAMS, "the open scene's root is not a Node3D; pins need a 3D scene")
	var filters: Variant = _read_filters(params, "current")
	if Util.is_error(filters):
		return filters
	_marker_filters = filters
	var placed := show_markers(root, filters.status, filters.scene)
	var out := {
		"scene": root.scene_file_path,
		"filter_scene": filters.scene if not filters.scene.is_empty() else "all",
		"status": filters.status,
		"pins": placed,
		"count": placed.size(),
		"node": "/%s/%s" % [root.name, MARKERS_NAME] if not placed.is_empty() else "",
		"undoable": false,
		"undo_reason": "pins are view-only: they have no owner, are never saved into the scene, and op='clear_markers' removes them",
	}
	if placed.is_empty():
		out["hint"] = "no %s notes for this scene" % ("" if filters.status == "all" else filters.status)
	return {"data": out}


## Replaces the pins under `root` with one per matching note. Returns
## [{id, position}].
func show_markers(root: Node, status: String, scene: String) -> Array:
	clear_markers(root)
	var notes := filter_notes(load_notes(notes_dir).notes, status, scene, "")
	var placed: Array = []
	var holder := Node3D.new()
	holder.name = MARKERS_NAME
	var index := 0
	for note in notes:
		var at: Variant = note.get("position", null)
		if not (at is Array and at.size() == 3):
			continue
		index += 1
		var pos := Vector3(float(at[0]), float(at[1]), float(at[2]))
		var resolved := str(note.get("status", "open")) == "resolved"
		var color: Color = CATEGORY_COLORS.get(str(note.get("category", "other")), Color.WHITE)
		var label := "%s%s" % ["✓ " if resolved else "", str(note.get("text", "")).replace("\n", " ").left(40)]
		var pin := make_pin(pos, color, label, 0.45 if resolved else 1.0)
		pin.name = "Note_" + str(note.id).replace("-", "_")
		pin.set_meta(&"playtest_note_id", str(note.id))
		holder.add_child(pin)
		placed.append({"id": note.id, "position": at, "status": note.get("status", "open")})
	if placed.is_empty():
		holder.free()
		return placed
	## No owner: drawn in the viewport, hidden from the Scene dock, never saved.
	root.add_child(holder, false, Node.INTERNAL_MODE_BACK)
	return placed


func clear_markers(root: Node = null) -> bool:
	if root == null:
		root = Util.edited_root()
	if root == null:
		return false
	var removed := false
	for child in root.get_children(true):
		if child.name == MARKERS_NAME and child.owner == null:
			root.remove_child(child)
			child.queue_free()
			removed = true
	return removed


func _refresh_markers() -> void:
	var root := Util.edited_root()
	if root == null or _marker_filters.is_empty():
		return
	for child in root.get_children(true):
		if child.name == MARKERS_NAME and child.owner == null:
			show_markers(root, _marker_filters.status, _marker_filters.scene)
			return


## A pin (stick, head, ground ring, label) drawn over walls; matches the
## in-game pins of playtest_notes_overlay.gd.
static func make_pin(at: Vector3, color: Color, label: String, alpha: float = 1.0) -> Node3D:
	var pin := Node3D.new()
	pin.position = at
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color, alpha)
	mat.render_priority = 10
	var parts := [
		[_cylinder(), Vector3(0, 0.8, 0)],
		[_sphere(), Vector3(0, 1.7, 0)],
		[_torus(), Vector3(0, 0.03, 0)],
	]
	for part in parts:
		var mesh := MeshInstance3D.new()
		mesh.mesh = part[0]
		mesh.position = part[1]
		mesh.material_override = mat
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pin.add_child(mesh)
	if not label.is_empty():
		var text := Label3D.new()
		text.text = label
		text.position = Vector3(0, 2.15, 0)
		text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		text.no_depth_test = true
		text.fixed_size = true
		text.pixel_size = 0.002
		text.font_size = 28
		text.outline_size = 8
		text.modulate = Color(1, 1, 1, alpha)
		text.render_priority = 11
		text.outline_render_priority = 10
		pin.add_child(text)
	return pin


static func _cylinder() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.04
	m.bottom_radius = 0.04
	m.height = 1.6
	return m


static func _sphere() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 0.22
	m.height = 0.44
	return m


static func _torus() -> Mesh:
	var m := TorusMesh.new()
	m.inner_radius = 0.35
	m.outer_radius = 0.45
	return m


# --- autoload -------------------------------------------------------------------

static func autoload_key() -> String:
	return "autoload/" + AUTOLOAD_NAME


## Copies the overlay script (kept when present) and registers the autoload
## (one undo step in the editor's global history).
func install(script_dir: String, overwrite: bool) -> Dictionary:
	var path := script_dir + "/" + OVERLAY_FILE
	var copied := Util.install_script(OVERLAY_TEMPLATE, path, overwrite)
	if Util.is_error(copied):
		return copied
	if copied.status != "kept":
		Util.refresh_filesystem([path])
	var key := autoload_key()
	var value := "*" + path
	var previous: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var autoload_status := "kept"
	if previous != value:
		autoload_status = "added" if previous == null else "updated"
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Playtest notes: register %s autoload" % AUTOLOAD_NAME, UndoRedo.MERGE_DISABLE, ProjectSettings)
		ur.add_do_method(ProjectSettings, &"set_setting", key, value)
		ur.add_do_method(ProjectSettings, &"save")
		ur.add_undo_method(ProjectSettings, &"set_setting", key, previous)
		ur.add_undo_method(ProjectSettings, &"save")
		ur.commit_action()
		if ProjectSettings.get_setting(key, null) != value:
			return Util.error(Util.INTERNAL_ERROR, "could not register the %s autoload in project.godot" % AUTOLOAD_NAME)
	return {"data": {
		"script": path,
		"script_status": copied.status,
		"autoload": AUTOLOAD_NAME,
		"autoload_status": autoload_status,
		"notes_dir": notes_dir,
		"how_to": "Play the game and press F9 (or Ctrl/Cmd+N; F8 on macOS) where something is wrong. Tab switches the pin between the mouse spot and the player, Enter saves, Shift+Enter adds a line, Esc cancels. Add an input action named 'playtest_note' to use your own key.",
	}}


func _uninstall() -> Dictionary:
	var key := autoload_key()
	if not ProjectSettings.has_setting(key):
		return {"data": {"autoload": AUTOLOAD_NAME, "removed": false}}
	var previous: Variant = ProjectSettings.get_setting(key)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Playtest notes: remove %s autoload" % AUTOLOAD_NAME, UndoRedo.MERGE_DISABLE, ProjectSettings)
	ur.add_do_method(ProjectSettings, &"set_setting", key, null)
	ur.add_do_method(ProjectSettings, &"save")
	ur.add_undo_method(ProjectSettings, &"set_setting", key, previous)
	ur.add_undo_method(ProjectSettings, &"save")
	ur.commit_action()
	return {"data": {"autoload": AUTOLOAD_NAME, "removed": true, "script_kept": str(previous).trim_prefix("*"), "notes_kept": notes_dir}}
