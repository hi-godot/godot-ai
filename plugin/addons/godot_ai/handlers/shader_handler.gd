@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## Raw shader authoring: create/read/validate/patch .gdshader and .gdshaderinc
## files. Every write parses the staged code through the engine's own shader
## compiler BEFORE the destination is touched, so invalid shader code never
## reaches disk and a failed validation preserves an existing file.
##
## Godot exposes no structured compile-error API to GDScript (the compiler's
## line-tagged output only reaches the editor Output panel), so validity is
## detected through a sentinel uniform: `Shader.get_shader_uniform_list()` is
## populated only when the whole translation unit parses, so a scratch copy
## with a generated uniform declaration appended reports parse success by
## containing that uniform. Failures return one synthesized diagnostic; the
## editor Output panel keeps the engine's line-tagged details.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MaterialValues := preload("res://addons/godot_ai/handlers/material_values.gd")

const SHADER_EXT := "gdshader"
const INCLUDE_EXT := "gdshaderinc"
## Bounded request size. A shader is hand-authored text; 256 KiB is far past
## any real shader and keeps a malformed request from parking the editor.
const MAX_CODE_BYTES := 262144
const MAX_LIST_ENTRIES := 1000
const SHADER_TYPES := ["spatial", "canvas_item", "particles", "sky", "fog"]
const MODE_NAMES := {
	Shader.MODE_SPATIAL: "spatial",
	Shader.MODE_CANVAS_ITEM: "canvas_item",
	Shader.MODE_PARTICLES: "particles",
	Shader.MODE_SKY: "sky",
	Shader.MODE_FOG: "fog",
}
const PARSE_FAILURE_TEXT := (
	"Shader failed to compile. The editor Output panel carries Godot's "
	+ "line-tagged compiler details; check syntax, declared uniforms, and "
	+ "stage-specific builtins for the shader type."
)


func create_shader(params: Dictionary) -> Dictionary:
	var resource_path: String = params.get("resource_path", "")
	var code: String = params.get("code", "")
	var overwrite: bool = params.get("overwrite", false)
	var shader_type: String = params.get("shader_type", "spatial")

	var path_err = McpPathValidator.path_error(resource_path, "resource_path", true)
	if path_err != null:
		return path_err
	var kind := _kind_for_path(resource_path)
	if kind.is_empty():
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"resource_path must end in .gdshader or .gdshaderinc: %s" % resource_path
		)
	if not params.has("code") or code.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: code")
	var size_err := _size_error(code)
	if size_err != null:
		return size_err
	var type_err := _shader_type_error(shader_type)
	if type_err != null:
		return type_err

	var directory := resource_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		return ErrorCodes.make(
			ErrorCodes.RESOURCE_NOT_FOUND,
			"Destination directory does not exist: %s" % directory
		)
	var existed_before := FileAccess.file_exists(resource_path)
	if existed_before and not overwrite:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"Shader already exists at %s (pass overwrite=true to replace)" % resource_path
		)

	var validation := _validate_code(code, kind, directory, shader_type)
	if validation.has("error"):
		return validation.error
	if not validation.valid:
		return _invalid_with_diagnostics(
			"Shader parse failed; %s was not written" % resource_path, validation
		)
	var write_err := _write_atomic(resource_path, code, kind)
	if write_err != null:
		return write_err

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(resource_path)

	var uniforms: Array = validation.uniforms
	var data := {
		"path": resource_path,
		"kind": kind,
		"shader_type": validation.shader_type,
		"uniforms": uniforms,
		"uniform_count": uniforms.size(),
		"line_count": _line_count(code),
		"size": code.length(),
		"overwritten": existed_before,
		"diagnostics": validation.diagnostics,
		"undoable": false,
		"reason": "File creation is persistent; delete the file manually to revert",
	}
	McpResourceIO.attach_cleanup_hint(data, existed_before, [resource_path, resource_path + ".uid"])
	return {"data": data}


func get_shader(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var path_err = McpPathValidator.path_error(path, "path")
	if path_err != null:
		return path_err
	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Shader not found: %s" % path)
	var kind := _kind_for_path(path)
	if kind.is_empty():
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Not a .gdshader or .gdshaderinc file: %s" % path
		)

	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if kind == "include":
		if not (loaded is ShaderInclude):
			return ErrorCodes.make(
				ErrorCodes.WRONG_TYPE, "Resource at %s is not a ShaderInclude" % path
			)
		var code: String = (loaded as ShaderInclude).get_code()
		return {"data": {
			"path": path,
			"kind": kind,
			"resource_class": "ShaderInclude",
			"code": code,
			"line_count": _line_count(code),
			"size": code.length(),
			"includes": _parse_includes(code),
		}}
	if not (loaded is Shader):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Shader" % path)
	var shader := loaded as Shader
	var shader_code: String = shader.get_code()
	var uniforms := _serialize_uniforms(shader)
	return {"data": {
		"path": path,
		"kind": kind,
		"resource_class": "Shader",
		"code": shader_code,
		"line_count": _line_count(shader_code),
		"size": shader_code.length(),
		"shader_type": MODE_NAMES.get(shader.get_mode(), ""),
		"uniforms": uniforms,
		"uniform_count": uniforms.size(),
		"render_modes": _parse_render_modes(shader_code),
		"includes": _parse_includes(shader_code),
	}}


func validate_shader(params: Dictionary) -> Dictionary:
	var code: String = params.get("code", "")
	var kind: String = params.get("kind", "shader")
	var shader_type: String = params.get("shader_type", "spatial")

	if not params.has("code") or code.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: code")
	if kind != "shader" and kind != "include":
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE, "kind must be 'shader' or 'include'"
		)
	var size_err := _size_error(code)
	if size_err != null:
		return size_err
	var type_err := _shader_type_error(shader_type)
	if type_err != null:
		return type_err

	var validation := _validate_code(code, kind, "user://", shader_type)
	if validation.has("error"):
		return validation.error
	return {"data": {
		"valid": validation.valid,
		"kind": kind,
		"shader_type": validation.shader_type,
		"uniforms": validation.uniforms,
		"uniform_count": validation.uniforms.size(),
		"diagnostics": validation.diagnostics,
		"errors": validation.errors,
		"warnings": validation.warnings,
		"undoable": false,
		"reason": "Validation compiles a scratch copy; no project state changed",
	}}


func list_shaders(params: Dictionary) -> Dictionary:
	var root: String = params.get("root", "res://")
	var path_err = McpPathValidator.path_error(root, "root")
	if path_err != null:
		return path_err
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EditorFileSystem not available", false
		)
	var dir := efs.get_filesystem_path(root)
	if dir == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Directory not found: %s" % root)

	var results: Array[Dictionary] = []
	var state := {"truncated": false}
	_scan_dir(dir, results, state)
	return {"data": {
		"shaders": results,
		"count": results.size(),
		"root": root,
		"truncated": state.truncated,
		"limit": MAX_LIST_ENTRIES,
	}}


func patch_shader(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var old_text: String = params.get("old_text", "")
	var new_text: String = params.get("new_text", "")
	var replace_all: bool = params.get("replace_all", false)
	var shader_type: String = params.get("shader_type", "spatial")

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err
	if not params.has("old_text"):
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: old_text")
	if not params.has("new_text"):
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: new_text")
	var kind := _kind_for_path(path)
	if kind.is_empty():
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE, "Path must end with .gdshader or .gdshaderinc: %s" % path
		)
	if old_text.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "old_text must not be empty")
	var type_err := _shader_type_error(shader_type)
	if type_err != null:
		return type_err

	var read := FileAccess.open(path, FileAccess.READ)
	if read == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found or unreadable: %s" % path)
	var content := read.get_as_text()
	read.close()

	var match_count := content.count(old_text)
	if match_count == 0:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "old_text not found in %s" % path)
	if match_count > 1 and not replace_all:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"old_text matches %d times; pass replace_all=true or provide a more specific snippet"
			% match_count,
		)

	var new_content: String
	var replacements: int
	if replace_all:
		new_content = content.replace(old_text, new_text)
		replacements = match_count
	else:
		var idx := content.find(old_text)
		new_content = content.substr(0, idx) + new_text + content.substr(idx + old_text.length())
		replacements = 1
	var size_err := _size_error(new_content)
	if size_err != null:
		return size_err

	var validation := _validate_code(new_content, kind, path.get_base_dir(), shader_type)
	if validation.has("error"):
		return validation.error
	if not validation.valid:
		return _invalid_with_diagnostics(
			"Shader parse failed; %s was not modified" % path, validation
		)
	var write_err := _write_atomic(path, new_content, kind)
	if write_err != null:
		return write_err

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	var uniforms: Array = validation.uniforms
	return {"data": {
		"path": path,
		"kind": kind,
		"replacements": replacements,
		"size": new_content.length(),
		"old_size": content.length(),
		"line_count": _line_count(new_content),
		"shader_type": validation.shader_type,
		"uniforms": uniforms,
		"uniform_count": uniforms.size(),
		"diagnostics": validation.diagnostics,
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}}


## Validate `code` and return a fresh in-memory Shader for inline embedding.
## The scratch copy is removed either way; callers get an `error_response`
## (parse failure) or a `shader` ready to assign to a ShaderMaterial.
static func build_inline_shader(code: String, directory: String) -> Dictionary:
	var size_err := _size_error(code)
	if size_err != null:
		return {"error_response": size_err}
	var validation := _validate_code(code, "shader", directory, "spatial")
	if validation.has("error"):
		return {"error_response": validation.error}
	if not validation.valid:
		return {
			"error_response": _invalid_with_diagnostics("Inline shader parse failed", validation),
			"diagnostics": validation.diagnostics,
		}
	var shader := Shader.new()
	shader.code = code
	return {
		"shader": shader,
		"shader_type": validation.shader_type,
		"uniforms": validation.uniforms,
		"diagnostics": validation.diagnostics,
	}


## Compile `code` through the engine's shader parser and report validity,
## uniforms, and a synthesized diagnostic on failure. `directory` receives the
## scratch files (destination directory for writes, `user://` for standalone
## validation). `.gdshaderinc` cannot compile alone, so it is wrapped in a
## minimal `shader_type <type>; #include "<scratch>"` shader in the same
## directory (include resolution is relative to the including file).
static func _validate_code(
	code: String, kind: String, directory: String, shader_type: String
) -> Dictionary:
	var token := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var sentinel := "_mcp_validate_%d" % Time.get_ticks_usec()
	var shader: Shader = null
	var scratch_paths: Array[String] = []
	if kind == "include":
		var include_path := _scratch_path(directory, token, INCLUDE_EXT)
		var wrapper_path := _scratch_path(directory, token, SHADER_EXT)
		var write_err = _write_scratch(include_path, code)
		if write_err != null:
			return {"error": write_err}
		scratch_paths.append(include_path)
		var wrapper := "shader_type %s;\n#include \"%s\"\nuniform float %s;\n" % [
			shader_type, include_path.get_file(), sentinel
		]
		write_err = _write_scratch(wrapper_path, wrapper)
		if write_err != null:
			_remove_paths(scratch_paths)
			return {"error": write_err}
		scratch_paths.append(wrapper_path)
		shader = ResourceLoader.load(wrapper_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	else:
		shader = Shader.new()
		shader.code = code + "\nuniform float %s;\n" % sentinel
	_remove_paths(scratch_paths)

	var valid := shader != null and _has_uniform(shader, sentinel)
	var uniforms: Array[Dictionary] = []
	var detected_type := shader_type
	if shader != null:
		for uniform in shader.get_shader_uniform_list():
			if str(uniform.get("name", "")) == sentinel:
				continue
			uniforms.append(_serialize_uniform(uniform))
		if kind == "shader":
			detected_type = str(MODE_NAMES.get(shader.get_mode(), ""))

	var diagnostics: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	if not valid:
		var diagnostic := {
			"level": "error",
			"text": PARSE_FAILURE_TEXT,
			"path": "",
			"line": 0,
			"function": "",
		}
		diagnostics.append(diagnostic)
		errors.append(diagnostic)
	return {
		"valid": valid,
		"diagnostics": diagnostics,
		"errors": errors,
		"warnings": warnings,
		"uniforms": uniforms,
		"shader_type": detected_type,
	}


## Write `code` beside `resource_path` and rename it into place, so a failed
## rename never truncates the destination. Validation happens before this call.
static func _write_atomic(resource_path: String, code: String, kind: String) -> Variant:
	var ext := INCLUDE_EXT if kind == "include" else SHADER_EXT
	var token := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var temp_path := _scratch_path(resource_path.get_base_dir(), token, ext)
	var write_err = _write_scratch(temp_path, code)
	if write_err != null:
		return write_err
	var rename_err := DirAccess.rename_absolute(temp_path, resource_path)
	if rename_err != OK:
		_remove_if_present(temp_path)
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Cannot write %s: %s" % [resource_path, error_string(rename_err)]
		)
	return null


static func _serialize_uniforms(shader: Shader) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for uniform in shader.get_shader_uniform_list():
		out.append(_serialize_uniform(uniform))
	return out


static func _serialize_uniform(uniform: Dictionary) -> Dictionary:
	var entry := {
		"name": str(uniform.get("name", "")),
		"type": type_string(int(uniform.get("type", TYPE_NIL))),
		"hint": int(uniform.get("hint", 0)),
		"hint_string": str(uniform.get("hint_string", "")),
		"usage": int(uniform.get("usage", 0)),
	}
	if uniform.has("default_value"):
		entry["default_value"] = MaterialValues.serialize_value(uniform.get("default_value"))
	return entry


static func _has_uniform(shader: Shader, name: String) -> bool:
	for uniform in shader.get_shader_uniform_list():
		if str(uniform.get("name", "")) == name:
			return true
	return false


static func _parse_includes(code: String) -> Array[String]:
	var out: Array[String] = []
	for raw_line in code.split("\n"):
		var line := raw_line.strip_edges()
		if not line.begins_with("#include"):
			continue
		var start := line.find("\"")
		var quote := "\""
		if start < 0:
			start = line.find("'")
			quote = "'"
		if start < 0:
			continue
		var end := line.find(quote, start + 1)
		if end > start:
			out.append(line.substr(start + 1, end - start - 1))
	return out


static func _parse_render_modes(code: String) -> Array[String]:
	var out: Array[String] = []
	for raw_line in code.split("\n"):
		var line := raw_line.strip_edges()
		if not line.begins_with("render_mode"):
			continue
		var rest := line.substr("render_mode".length()).strip_edges()
		if rest.ends_with(";"):
			rest = rest.substr(0, rest.length() - 1)
		for mode in rest.split(",", false):
			var trimmed := mode.strip_edges()
			if not trimmed.is_empty():
				out.append(trimmed)
	return out


func _scan_dir(dir: EditorFileSystemDirectory, out: Array[Dictionary], state: Dictionary) -> void:
	if state.truncated:
		return
	for i in dir.get_file_count():
		var extension := dir.get_file(i).get_extension().to_lower()
		if extension != SHADER_EXT and extension != INCLUDE_EXT:
			continue
		out.append({
			"path": dir.get_file_path(i),
			"kind": "include" if extension == INCLUDE_EXT else "shader",
		})
		if out.size() >= MAX_LIST_ENTRIES:
			state.truncated = true
			return
	for i in dir.get_subdir_count():
		_scan_dir(dir.get_subdir(i), out, state)
		if state.truncated:
			return


static func _scratch_path(directory: String, token: String, ext: String) -> String:
	var separator := "" if directory.ends_with("/") else "/"
	return "%s%s.godot-ai-shader-%s.%s" % [directory, separator, token, ext]


static func _kind_for_path(path: String) -> String:
	match path.get_extension().to_lower():
		SHADER_EXT:
			return "shader"
		INCLUDE_EXT:
			return "include"
	return ""


static func _size_error(code: String) -> Variant:
	if code.length() > MAX_CODE_BYTES:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"code exceeds the %d-byte limit (got %d)" % [MAX_CODE_BYTES, code.length()]
		)
	return null


static func _shader_type_error(shader_type: String) -> Variant:
	if shader_type in SHADER_TYPES:
		return null
	return ErrorCodes.make(
		ErrorCodes.VALUE_OUT_OF_RANGE,
		"shader_type must be one of: %s (got %s)" % [", ".join(SHADER_TYPES), shader_type]
	)


static func _invalid_with_diagnostics(message: String, validation: Dictionary) -> Dictionary:
	var err := ErrorCodes.make(ErrorCodes.INVALID_PARAMS, message)
	err["error"]["data"] = {
		"diagnostics": validation.get("diagnostics", []),
		"errors": validation.get("errors", []),
		"warnings": validation.get("warnings", []),
	}
	return err


## Scratch-file writer. Parent directories are always known to exist
## (destination dir checked by the caller; user:// is guaranteed), so this
## stays off McpResourceIO.write_text_to_disk, whose `get_base_dir()` mkdir
## path is unreliable for a bare `user://` root.
static func _write_scratch(path: String, content: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to open scratch file for writing: %s" % path
		)
	file.store_string(content)
	file.flush()
	var write_err := file.get_error()
	file.close()
	if write_err != OK:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Scratch write failed for %s: %s" % [path, error_string(write_err)]
		)
	return null


static func _remove_paths(paths: Array[String]) -> void:
	for path in paths:
		_remove_if_present(path)


static func _remove_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


static func _line_count(code: String) -> int:
	return code.count("\n") + (1 if not code.is_empty() else 0)
