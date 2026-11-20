@tool
extends RefCounted

## Shared helpers for the top-down shooter tools: param reading, res://
## path checks, template copying, scene/resource saving, and undoable
## edits to the currently edited scene.
##
## Only the published Godot AI API (McpCustomToolSpec, McpToolRegistry,
## McpCallContext) is used by this addon; error dictionaries are built
## here in the same shape Godot AI's own handlers return.

const TEMPLATE_DIR := "res://addons/topdown_shooter_tools/templates/"

const INVALID_PARAMS := "INVALID_PARAMS"
const NODE_NOT_FOUND := "NODE_NOT_FOUND"
const EDITOR_NOT_READY := "EDITOR_NOT_READY"
const INTERNAL_ERROR := "INTERNAL_ERROR"
const ALREADY_EXISTS := "ALREADY_EXISTS"


static func error(code: String, message: String) -> Dictionary:
	return {"status": "error", "error": {"code": code, "message": message}}


static func is_error(value: Variant) -> bool:
	return value is Dictionary and value.get("status", "") == "error"


# --- params -----------------------------------------------------------------

## Reads a number param. Returns the float, or an error dictionary.
static func num(params: Dictionary, key: String, default_value: float, min_value: float = -INF, max_value: float = INF) -> Variant:
	if not params.has(key) or params[key] == null:
		return default_value
	var raw: Variant = params[key]
	if not (raw is float or raw is int):
		return error(INVALID_PARAMS, "'%s' must be a number, got %s" % [key, type_string(typeof(raw))])
	var value := float(raw)
	if value < min_value or value > max_value:
		return error(INVALID_PARAMS, "'%s' must be between %s and %s, got %s" % [key, min_value, max_value, value])
	return value


static func integer(params: Dictionary, key: String, default_value: int, min_value: int, max_value: int) -> Variant:
	var value: Variant = num(params, key, default_value, min_value, max_value)
	if is_error(value):
		return value
	if float(value) != floorf(float(value)):
		return error(INVALID_PARAMS, "'%s' must be a whole number, got %s" % [key, value])
	return int(value)


static func boolean(params: Dictionary, key: String, default_value: bool) -> Variant:
	if not params.has(key) or params[key] == null:
		return default_value
	if not params[key] is bool:
		return error(INVALID_PARAMS, "'%s' must be true or false" % key)
	return params[key]


static func text(params: Dictionary, key: String, default_value: String) -> Variant:
	if not params.has(key) or params[key] == null:
		return default_value
	if not params[key] is String:
		return error(INVALID_PARAMS, "'%s' must be a string" % key)
	return String(params[key]).strip_edges()


static func vec3(params: Dictionary, key: String, default_value: Vector3) -> Variant:
	if not params.has(key) or params[key] == null:
		return default_value
	var raw: Variant = params[key]
	if raw is Array and raw.size() == 3:
		for v in raw:
			if not (v is float or v is int):
				return error(INVALID_PARAMS, "'%s' must be [x, y, z] numbers" % key)
		return Vector3(raw[0], raw[1], raw[2])
	if raw is Dictionary and raw.has("x") and raw.has("y") and raw.has("z"):
		return Vector3(float(raw.x), float(raw.y), float(raw.z))
	return error(INVALID_PARAMS, "'%s' must be [x, y, z] or {x, y, z}" % key)


# --- res:// paths ------------------------------------------------------------

## Validates a project path for writing. Returns "" when fine, else a reason.
static func check_res_path(path: String, extension: String = "") -> String:
	if not path.begins_with("res://"):
		return "path '%s' must start with res://" % path
	if path.contains("..") or path.contains("\\"):
		return "path '%s' must not contain '..' or backslashes" % path
	if path.begins_with("res://addons/") or path.begins_with("res://.godot"):
		return "path '%s' is inside addons/ or .godot/; pick a game folder such as res://scripts" % path
	if not extension.is_empty() and path.get_extension() != extension:
		return "path '%s' must end with .%s" % [path, extension]
	return ""


static func clean_dir(path: String) -> String:
	var out := path.strip_edges()
	while out.ends_with("/") and out != "res://":
		out = out.substr(0, out.length() - 1)
	return out


static func ensure_dir(res_dir: String) -> Error:
	return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(res_dir))


# --- files -------------------------------------------------------------------

## Copies templates/<template> to `dest` unless it already exists (and
## overwrite is false). Loads and returns {"script": Script, "status":
## "created"|"overwritten"|"kept"} or an error dictionary.
static func install_script(template: String, dest: String, overwrite: bool) -> Dictionary:
	var reason := check_res_path(dest, "gd")
	if not reason.is_empty():
		return error(INVALID_PARAMS, reason)
	var existed := FileAccess.file_exists(dest)
	var status := "kept"
	if not existed or overwrite:
		var source := FileAccess.get_file_as_string(TEMPLATE_DIR + template)
		if source.is_empty():
			return error(INTERNAL_ERROR, "template %s is missing or empty" % template)
		var dir_err := ensure_dir(dest.get_base_dir())
		if dir_err != OK:
			return error(INTERNAL_ERROR, "cannot create %s: %s" % [dest.get_base_dir(), error_string(dir_err)])
		var file := FileAccess.open(dest, FileAccess.WRITE)
		if file == null:
			return error(INTERNAL_ERROR, "cannot write %s: %s" % [dest, error_string(FileAccess.get_open_error())])
		file.store_string(source)
		file.close()
		status = "overwritten" if existed else "created"
	var mode := ResourceLoader.CACHE_MODE_REPLACE if status == "overwritten" else ResourceLoader.CACHE_MODE_REUSE
	var script := ResourceLoader.load(dest, "Script", mode) as Script
	if script == null:
		return error(INTERNAL_ERROR, "cannot load script %s" % dest)
	## can_instantiate() is false for every non-@tool script inside the
	## editor, so compile a throwaway copy to detect a broken file.
	var probe := GDScript.new()
	probe.source_code = FileAccess.get_file_as_string(dest)
	if probe.reload() != OK:
		return error(INTERNAL_ERROR, "script %s does not compile; fix it or pass overwrite_scripts=true to restore the template" % dest)
	return {"script": script, "status": status, "path": dest}


## Packs `root` (all descendants already owned by it) and saves it. Frees
## `root`. Returns "" on success, else a message.
static func save_scene(root: Node, path: String) -> String:
	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	root.free()
	if pack_err != OK:
		return "cannot pack scene %s: %s" % [path, error_string(pack_err)]
	var dir_err := ensure_dir(path.get_base_dir())
	if dir_err != OK:
		return "cannot create %s: %s" % [path.get_base_dir(), error_string(dir_err)]
	packed.take_over_path(path)
	var save_err := ResourceSaver.save(packed, path)
	if save_err != OK:
		return "cannot save %s: %s" % [path, error_string(save_err)]
	return ""


static func save_resource(res: Resource, path: String) -> String:
	var dir_err := ensure_dir(path.get_base_dir())
	if dir_err != OK:
		return "cannot create %s: %s" % [path.get_base_dir(), error_string(dir_err)]
	res.take_over_path(path)
	var save_err := ResourceSaver.save(res, path)
	if save_err != OK:
		return "cannot save %s: %s" % [path, error_string(save_err)]
	return ""


## Tells the editor's file system about new or changed files, one file at a
## time. Never a full scan(): Godot AI documents (script_handler.gd,
## _register_written_file) that a scan() per write stacks editor background
## tasks ("Task ... already exists") and can crash the GUI editor.
static func refresh_filesystem(paths: Array) -> void:
	if not Engine.is_editor_hint():
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	for path in paths:
		efs.update_file(path)


## Sets `node.owner = owner_node` on every descendant (not node itself).
static func own_descendants(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		own_descendants(child, owner_node)


# --- edited scene ------------------------------------------------------------

static func edited_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_edited_scene_root()


static func no_scene_error() -> Dictionary:
	return error(EDITOR_NOT_READY, "No scene is open in the editor. Open or create a 3D scene first (scene_create / scene_open).")


## Resolves "", "/", "<RootName>", "/<RootName>/A/B", "/root/<RootName>/A",
## or a path relative to the scene root ("A/B"). Returns null when missing.
static func resolve(path: String, root: Node) -> Node:
	if root == null:
		return null
	var p := path.strip_edges()
	if p.is_empty() or p == "/" or p == "." or p == String(root.name) or p == "/" + String(root.name):
		return root
	if p.begins_with("/root/"):
		p = p.substr(5)
	var prefix := "/" + String(root.name) + "/"
	if p.begins_with(prefix):
		p = p.substr(prefix.length())
	elif p.begins_with("/"):
		p = p.substr(1)
	return root.get_node_or_null(NodePath(p))


static func scene_path_of(node: Node, root: Node) -> String:
	if node == root:
		return "/" + String(root.name)
	return "/" + String(root.name) + "/" + String(root.get_path_to(node))


## Adds `node` under `parent` in the edited scene as one undoable action.
## `extra` is an Array of [object, property, new_value, old_value] tuples
## applied in the same action.
static func add_to_scene(action_name: String, parent: Node, node: Node, root: Node, extra: Array = []) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action_name, UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	for child in _descendants_owned_by_node(node):
		ur.add_do_method(child, "set_owner", root)
	for item in extra:
		ur.add_do_property(item[0], item[1], item[2])
		ur.add_undo_property(item[0], item[1], item[3])
	## A child added inside an instanced scene (e.g. a weapon under the
	## player instance's WeaponMount) is only saved when that instance has
	## Editable Children on.
	for inst in _instances_containing(parent, root):
		if not root.is_editable_instance(inst):
			ur.add_do_method(root, "set_editable_instance", inst, true)
			ur.add_undo_method(root, "set_editable_instance", inst, false)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()


## Instance roots (outermost last) that `node` lives inside, when `node`
## belongs to an instanced scene rather than to the edited scene itself.
static func _instances_containing(node: Node, root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var n := node
	while n != null and n != root and n.owner != null and n.owner != root:
		out.append(n.owner)
		n = n.owner
	return out


## Descendants built in code (no owner yet) that must be owned by the
## scene root to be saved. Nodes from an instanced scene keep their owner.
static func _descendants_owned_by_node(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in node.get_children():
		if child.owner == null:
			out.append(child)
			out.append_array(_descendants_owned_by_node(child))
	return out


static func unique_child_name(parent: Node, wanted: String) -> String:
	if parent.get_node_or_null(NodePath(wanted)) == null:
		return wanted
	var i := 2
	while parent.get_node_or_null(NodePath("%s%d" % [wanted, i])) != null:
		i += 1
	return "%s%d" % [wanted, i]
