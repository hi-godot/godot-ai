@tool
extends RefCounted

const Errors := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const PLUGIN_TREE := "res://addons/godot_ai"
const SIDECARS := [".uid", ".import"]
const OWNER_EXTENSIONS := ["gd", "cs", "gdshader", "gdshaderinc", "tscn", "tres", "scn", "res"]
const MAX_ENTRIES := 10000
const MAX_FILE_BYTES := 256 * 1024
const MAX_TOTAL_BYTES := 64 * 1024 * 1024
const MAX_TARGETS := 256
## Container magic Godot writes for a compressed binary resource.
const COMPRESSED_MAGIC := "RSCC"
## Work allowed between frame yields: a share of how long the editor last took
## to come back, within these bounds. A fixed slice starves discovery once the
## editor is unfocused, because its low-processor mode then sleeps ~100 ms per
## frame (`interface/editor/timers/unfocused_low_processor_mode_sleep_usec`)
## and the frame count, not the work, reaches the deadline (#1120). The floor is
## what a focused editor gets; the ceiling bounds one slice on a stalled editor.
const BUDGET_MIN_USEC := 2000
const BUDGET_MAX_USEC := 50000
const BUDGET_GAP_DIVISOR := 3
const DEADLINE_MSEC := 25000
static var _busy := false

var _alive: Callable
var _deadline := 0
var _yield_at := 0
var _budget := BUDGET_MIN_USEC
var _bytes := 0
var _directories: Dictionary = {}
var _fingerprints: Dictionary = {}
var _large_owners: Dictionary = {}
var _fault := ""
var _fault_code := ""
var _io: Callable

## Dispatch stays synchronous; the retained job owns work across frame yields.
static func start(connection: McpConnection, params: Dictionary, operation: String) -> Dictionary:
	var request_id := str(params.get("_request_id", ""))
	if connection == null or request_id.is_empty():
		return _unchanged(
			"Filesystem mutations require a direct deferred command; call filesystem_manage outside batch_execute")
	_finish(connection, request_id, params.duplicate(true), operation)
	return {"_deferred": true, "_deferred_timeout_ms": 30000}


static func _finish(connection: McpConnection, request_id: String, params: Dictionary, operation: String) -> void:
	var work := ScriptWork.begin("filesystem_" + operation)
	var tree := connection.get_tree()
	if tree == null:
		ScriptWork.finish(work)
		return
	# Register the deferred response before the job can test its ownership.
	await tree.process_frame
	var job = load("res://addons/godot_ai/handlers/filesystem_mutation.gd").new()
	var active := func() -> bool:
		return is_instance_valid(connection) and connection.dispatcher != null and connection.dispatcher.has_pending_deferred_response(request_id)
	var result: Dictionary = await job.run(params, operation, active)
	if active.call():
		connection.send_deferred_response(request_id, result)
	ScriptWork.finish(work)


## Discovery is cancellable and read-only. Once disk effects start, this owner
## finishes or reconciles them before releasing the mutation slot.
func run(params: Dictionary, operation: String, active: Callable = Callable()) -> Dictionary:
	if _busy:
		return _unchanged("Another filesystem mutation is still running")
	_busy = true
	_alive = active
	_deadline = Time.get_ticks_msec() + DEADLINE_MSEC
	_yield_at = Time.get_ticks_usec()
	_budget = BUDGET_MIN_USEC
	_bytes = 0
	_directories.clear()
	_fingerprints.clear()
	_large_owners.clear()
	_fault = ""
	_fault_code = ""
	var result := await _run(params, operation)
	_busy = false
	return result


func _run(params: Dictionary, operation: String) -> Dictionary:
	var source := str(params.get("path", "")).trim_suffix("/")
	var error = McpPathValidator.path_error(source, "path", true)
	if error != null:
		return error
	source = source.simplify_path()
	if source == "res:/" or source == "res://" or _reserved(source):
		return _unchanged("Cannot mutate the project root, metadata, or loaded plugin tree")
	if _is_sidecar(source):
		return _unchanged("Mutate the resource, not its .uid or .import sidecar")
	var directory := DirAccess.dir_exists_absolute(source)
	if not directory and not FileAccess.file_exists(source):
		return Errors.make(Errors.RESOURCE_NOT_FOUND, "File or folder not found: %s" % source)
	var destination := str(params.get("new_path", "")).trim_suffix("/")
	if operation == "rename":
		var name := str(params.get("new_name", ""))
		if name.is_empty() or "/" in name or "\\" in name or name in [".", ".."]:
			return _unchanged("new_name must be a nonempty bare name without path separators")
		destination = source.get_base_dir().path_join(name)
	if operation != "remove":
		error = McpPathValidator.path_error(destination, "new_path", true)
		if error != null:
			return error
		destination = destination.simplify_path()
		if _reserved(destination):
			return _unchanged("Cannot move into project metadata or the loaded plugin tree")
		if source == destination or (directory and (destination + "/").to_lower().begins_with(source.to_lower() + "/")):
			return _unchanged("Cannot move a path onto itself or into its own subtree")
		if not DirAccess.dir_exists_absolute(destination.get_base_dir()):
			return _unchanged("Destination parent must already exist: %s" % destination.get_base_dir())
	if directory and operation == "remove" and bool(params.get("permanent", false)):
		return _unchanged("Permanent directory removal is unsupported; use the default OS trash")
	if not _confined_without_links(source) or (operation != "remove" and not _confined_without_links(destination)):
		return _unchanged(_fault)
	var files: Array[String] = []
	if not await _collect_tree("res://", files):
		return _fault_result()
	if directory and not _directories.has(source):
		return _unchanged("Source directory was excluded or has noncanonical casing; nothing changed")
	var targets := {}
	for path in files:
		if not _is_sidecar(path) and (path == source or (directory and path.begins_with(source + "/"))):
			targets[path] = {"uid": ResourceLoader.get_resource_uid(path)}
	if not directory and not targets.has(source):
		return _unchanged("Source was excluded from discovery; nothing changed")
	if targets.size() > MAX_TARGETS:
		return _unchanged("Mutation exceeds the %d-resource limit; use smaller groups" % MAX_TARGETS)
	for path in files:
		if not _mutation_member(path, source, directory):
			continue
		if path.get_extension().to_lower() in OWNER_EXTENSIONS:
			# Owner-extension targets are read and fingerprinted by the owner
			# pass below; reading them here too would charge the byte budget twice.
			continue
		if await _read_bounded(path) == null:
			return _fault_result()
	var owners := []
	for path in files:
		var extension := path.get_extension().to_lower()
		if extension not in OWNER_EXTENSIONS:
			continue
		var hits: Array[Dictionary]
		var length := _file_length(path)
		if length < 0:
			return _fault_result()
		if length > MAX_FILE_BYTES:
			# Dependency enumeration can replace a literal scan for packed binary
			# owners, but not for scripts or text resources: those can refer to a
			# target in ordinary strings the graph does not report. Fail closed.
			if extension not in ["res", "scn"]:
				_set_fault("Cannot safely read owner %s (exceeds %d bytes)" % [path, MAX_FILE_BYTES], Errors.FILESYSTEM_DISCOVERY_FAILED)
				return _fault_result()
			hits = await _large_owner_references(path, targets)
		else:
			var content: Variant = await _read_bounded(path)
			if content == null:
				return _fault_result()
			if extension in ["res", "scn"]:
				hits = await _binary_references(path, content, targets)
			else:
				# One call per owner: _references lowercases and regex-scans the
				# whole file, so a per-target loop repeated that up to MAX_TARGETS
				# times.
				hits = await _references(path, content, targets)
		if not _fault.is_empty():
			return _fault_result()
		if not await _yield_if_needed():
			return _fault_result()
		if not hits.is_empty() and not (operation == "remove" and targets.has(path)):
			owners.append({"path": path, "references": hits})
	var editor_guard := _editor_state_guard(targets)
	if not editor_guard.is_empty():
		return editor_guard
	for owner in owners:
		for hit in owner.references:
			if operation == "remove":
				if not bool(params.get("force", false)):
					return _unchanged("Resource is still referenced; repair references or use force=true for known dangling references", {"referenced_by": owners})
			elif hit.kind != "uid":
				return _unchanged("Move requires dependency path rewrites, which are unsupported; update references or use preserved uid:// references first", {"referenced_by": owners})
	var group: Array[Dictionary] = [{"from": source, "to": destination}]
	if not directory:
		for suffix in SIDECARS:
			if FileAccess.file_exists(source + suffix):
				group.append({"from": source + suffix, "to": destination + suffix})
	for item in group:
		if not _confined_without_links(item.from):
			return _fault_result()
		if operation != "remove" and not _destination_available(item.from, item.to):
			return _fault_result()
	# Re-read owner bytes and directory entry censuses after the yielding plan.
	if not await _revalidate():
		return _fault_result()
	if not _active():
		_set_fault("Filesystem request expired before mutation; nothing changed", Errors.FILESYSTEM_DISCOVERY_FAILED)
		return _fault_result()
	for item in group:
		if not _confined_without_links(item.from) or (operation != "remove" and not _destination_available(item.from, item.to)):
			return _fault_result()
	# Revalidation yields. Recheck mutable editor authority after the last
	# callback/yield, with no suspension between this guard and disk effects.
	editor_guard = _editor_state_guard(targets)
	if not editor_guard.is_empty():
		return editor_guard
	if operation == "remove":
		return _remove(source, directory, group, targets, owners, bool(params.get("permanent", false)))
	return _move(source, destination, directory, group, targets)


func _active() -> bool:
	return Time.get_ticks_msec() < _deadline and (not _alive.is_valid() or bool(_alive.call()))


func _yield_if_needed() -> bool:
	if not _active():
		_set_fault("Filesystem discovery expired or was cancelled; nothing changed", Errors.FILESYSTEM_DISCOVERY_FAILED)
		return false
	var paused := Time.get_ticks_usec()
	if paused - _yield_at >= _budget:
		await (Engine.get_main_loop() as SceneTree).process_frame
		_yield_at = Time.get_ticks_usec()
		_budget = _frame_budget(_yield_at - paused)
	if not _active():
		_set_fault("Filesystem discovery expired or was cancelled; nothing changed", Errors.FILESYSTEM_DISCOVERY_FAILED)
		return false
	return true


## The next slice for an editor that was away `gap_usec` between two slices.
## The frame sleep absorbs work shorter than itself, so a third of the gap is a
## quarter of a sleeping editor's frame and lengthens a busy one by a third.
static func _frame_budget(gap_usec: int) -> int:
	return clampi(gap_usec / BUDGET_GAP_DIVISOR, BUDGET_MIN_USEC, BUDGET_MAX_USEC)


func _collect_tree(root: String, files: Array[String]) -> bool:
	var pending: Array[String] = [root]
	var count := 0
	while not pending.is_empty():
		var path: String = pending.pop_back()
		var dir := DirAccess.open(path)
		if dir == null:
			_set_fault("Cannot inspect directory: %s" % path, Errors.FILESYSTEM_DISCOVERY_FAILED)
			return false
		dir.include_hidden = true
		if dir.list_dir_begin() != OK:
			_set_fault("Cannot list directory: %s" % path, Errors.FILESYSTEM_DISCOVERY_FAILED)
			return false
		var entries: Array[String] = []
		var name := dir.get_next()
		while not name.is_empty():
			if name not in [".", ".."]:
				var child := path.path_join(name)
				entries.append(name)
				# Engine metadata, VCS internals and the immutable loaded plugin
				# implementation are outside the user-resource owner scan.
				if child not in ["res://.godot", "res://.git", PLUGIN_TREE]:
					if not dir.has_method("is_link") or bool(dir.call("is_link", child)):
						_fault = "Cannot establish ownership through a linked entry: %s" % child
						dir.list_dir_end()
						return false
					if dir.current_is_dir():
						pending.append(child)
					else:
						files.append(child)
					count += 1
					if count > MAX_ENTRIES:
						_set_fault("Project discovery exceeds %d entries; nothing changed" % MAX_ENTRIES, Errors.FILESYSTEM_DISCOVERY_FAILED)
						dir.list_dir_end()
						return false
			if not await _yield_if_needed():
				dir.list_dir_end()
				return false
			name = dir.get_next()
		dir.list_dir_end()
		entries.sort()
		_directories[path] = entries
	return true


func _read_bounded(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_set_fault("Cannot safely read owner %s (unreadable)" % path, Errors.FILESYSTEM_DISCOVERY_FAILED)
		return null
	if file.get_length() > MAX_FILE_BYTES:
		_set_fault("Cannot safely read owner %s (exceeds %d bytes)" % [path, MAX_FILE_BYTES], Errors.FILESYSTEM_DISCOVERY_FAILED)
		return null
	var bytes := PackedByteArray()
	var length := file.get_length()
	while file.get_position() < length:
		var part := file.get_buffer(mini(16384, length - file.get_position()))
		if part.is_empty():
			_set_fault("Short read while inspecting %s" % path, Errors.FILESYSTEM_DISCOVERY_FAILED)
			return null
		bytes.append_array(part)
		_bytes += part.size()
		if _bytes > MAX_TOTAL_BYTES:
			_set_fault("Filesystem discovery exceeds its byte budget; nothing changed", Errors.FILESYSTEM_DISCOVERY_FAILED)
			return null
		if not await _yield_if_needed():
			return null
	file.close()
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	_fingerprints[path] = digest.finish()
	return bytes


func _mutation_member(path: String, source: String, directory: bool) -> bool:
	if directory:
		return path == source or path.begins_with(source + "/")
	return path == source or path in [source + ".uid", source + ".import"]


func _file_length(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_set_fault("Cannot inspect owner metadata: %s" % path, Errors.FILESYSTEM_DISCOVERY_FAILED)
		return -1
	var length := file.get_length()
	file.close()
	return length


func _owner_dependencies(path: String) -> PackedStringArray:
	var dependencies := PackedStringArray()
	for dependency in ResourceLoader.get_dependencies(path):
		dependencies.append(str(dependency))
	return dependencies


## Lowercased `uid://` and path segments of the engine's dependency records.
func _dependency_segments(dependencies: PackedStringArray) -> Dictionary:
	var segments: Dictionary = {}
	for dependency in dependencies:
		for segment in dependency.split("::", false):
			segments[segment.to_lower()] = true
	return segments


func _large_owner_references(path: String, targets: Dictionary) -> Array[Dictionary]:
	var dependencies := _owner_dependencies(path)
	var dependency_paths := _dependency_segments(dependencies)
	_large_owners[path] = {
		"modified": FileAccess.get_modified_time(path),
		"size": _file_length(path),
		"dependencies": dependencies,
	}
	if int(_large_owners[path]["size"]) < 0:
		return []
	var hits: Array[Dictionary] = []
	for target: String in targets:
		if not await _yield_if_needed():
			return hits
		var uid: int = targets[target].uid
		var uid_text := ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""
		if dependency_paths.has(target.to_lower()) or (not uid_text.is_empty() and dependency_paths.has(uid_text.to_lower())):
			# A dependency path can be a UID-backed ext_resource. Without reading
			# the oversized owner we cannot prove the file reference is safe to
			# rewrite, so fail closed for moves; force-remove may still use it.
			hits.append({"path": target, "kind": "path"})
	return hits


func _binary_references(path: String, bytes: PackedByteArray, targets: Dictionary) -> Array[Dictionary]:
	var hits: Array[Dictionary] = []
	var payload: Variant = _binary_scan_bytes(path, bytes)
	if payload == null:
		return hits
	# The binary format stores an ext_resource UID as an integer, which no text
	# scan can see, so the engine's dependency records are consulted as well.
	var dependency_paths := _dependency_segments(_owner_dependencies(path))
	for target: String in targets:
		# Keep cancellation and frame progress even when a path match continues.
		if not await _yield_if_needed():
			return hits
		var uid: int = targets[target].uid
		var uid_text := ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""
		var uses_path: bool = (
			_bytes_contains_ci(payload, target.to_utf8_buffer())
			or dependency_paths.has(target.to_lower())
			or (not uid_text.is_empty() and dependency_paths.has(uid_text.to_lower()))
		)
		var uses_uid: bool = not uid_text.is_empty() and _bytes_contains_ci(payload, uid_text.to_utf8_buffer())
		if uses_path:
			hits.append({"path": target, "kind": "path"})
		elif uses_uid:
			if not ResourceUID.has_id(uid) or ResourceUID.get_id_path(uid) != target:
				_set_fault("UID mapping is not authoritative for %s" % target)
				return hits
			hits.append({"path": target, "kind": "uid"})
	return hits


## The bytes a literal scan can inspect. The editor saves binary resources
## compressed by default (`filesystem/on_save/compress_binary_resources`), and
## a compressed container shows none of its serialized paths, so expand it
## first. Layout: magic, mode, block size and expanded size (u32 each), one
## u32 compressed size per block, then the blocks.
##
## Returns an empty array when the expanded payload exceeds the per-file limit
## (the caller then relies on dependency records alone, like any oversized
## binary owner) and null, with a fault, for a container that cannot be read.
func _binary_scan_bytes(path: String, bytes: PackedByteArray) -> Variant:
	if bytes.size() < 4 or bytes.slice(0, 4).get_string_from_ascii() != COMPRESSED_MAGIC:
		return bytes
	var unreadable := "Cannot inspect compressed binary owner: %s" % path
	if bytes.size() < 16:
		_set_fault(unreadable, Errors.FILESYSTEM_DISCOVERY_FAILED)
		return null
	var mode := bytes.decode_u32(4)
	var block_size := bytes.decode_u32(8)
	var total := bytes.decode_u32(12)
	if mode > FileAccess.COMPRESSION_BROTLI or block_size == 0:
		_set_fault(unreadable, Errors.FILESYSTEM_DISCOVERY_FAILED)
		return null
	if total > MAX_FILE_BYTES:
		return PackedByteArray()
	var block_count := total / block_size + 1
	var offset := 16 + block_count * 4
	if offset > bytes.size():
		_set_fault(unreadable, Errors.FILESYSTEM_DISCOVERY_FAILED)
		return null
	var payload := PackedByteArray()
	for index in block_count:
		var compressed_size := bytes.decode_u32(16 + index * 4)
		var expected := total % block_size if index == block_count - 1 else block_size
		if offset + compressed_size > bytes.size():
			_set_fault(unreadable, Errors.FILESYSTEM_DISCOVERY_FAILED)
			return null
		if expected > 0:
			var block := bytes.slice(offset, offset + compressed_size).decompress(expected, mode)
			if block.size() != expected:
				_set_fault(unreadable, Errors.FILESYSTEM_DISCOVERY_FAILED)
				return null
			payload.append_array(block)
		offset += compressed_size
	_bytes += payload.size()
	if _bytes > MAX_TOTAL_BYTES:
		_set_fault("Filesystem discovery exceeds its byte budget; nothing changed", Errors.FILESYSTEM_DISCOVERY_FAILED)
		return null
	return payload


func _ascii_lower(value: int) -> int:
	if value >= 65 and value <= 90:
		return value + 32
	return value


func _bytes_contains_ci(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty() or haystack.size() < needle.size():
		return false
	var lower := _ascii_lower(needle[0])
	var upper := lower - 32 if lower >= 97 and lower <= 122 else lower
	var candidates := [lower]
	if candidates[0] != upper:
		candidates.append(upper)
	for candidate in candidates:
		var position := haystack.find(candidate)
		while position >= 0:
			if position + needle.size() <= haystack.size():
				var matches := true
				for index in needle.size():
					if _ascii_lower(haystack[position + index]) != _ascii_lower(needle[index]):
						matches = false
						break
				if matches:
					return true
			position = haystack.find(candidate, position + 1)
	return false


func _references(path: String, bytes: PackedByteArray, targets: Dictionary) -> Array[Dictionary]:
	var hits: Array[Dictionary] = []
	# Compare paths conservatively across case-insensitive project volumes.
	# A case-only false positive on a sensitive volume is a safe refusal.
	var text := bytes.get_string_from_utf8().to_lower()
	# Relative preload/load literals are path dependencies too. Never rewrite
	# source text: recognizing one causes an unchanged refusal below.
	var literals := RegEx.new()
	literals.compile("[\"']([^\"'\\n]+)[\"']")
	var relative_paths: Dictionary = {}
	for literal in literals.search_all(text):
		var value: String = literal.get_string(1)
		if not value.contains(":"):
			relative_paths[path.get_base_dir().path_join(value).simplify_path().to_lower()] = true
			# ResourceLoader.load uses the project root for bare paths.
			relative_paths["res://".path_join(value).simplify_path().to_lower()] = true
	for target: String in targets:
		# Keep cancellation and frame progress even when a path match continues.
		if not await _yield_if_needed():
			return hits
		var target_text := target.to_lower()
		var uid: int = targets[target].uid
		var uid_text := ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""
		var uses_uid := not uid_text.is_empty() and (("\"%s\"" % uid_text) in text or ("'%s'" % uid_text) in text)
		if relative_paths.has(target_text):
			hits.append({"path": target, "kind": "path"})
			continue
		var uses_path := ("\"%s\"" % target_text) in text or ("'%s'" % target_text) in text
		if uses_path:
			# A stored ext_resource fallback path is safe only with this exact
			# target's preserved UID on the same header. Other strings block.
			var only_uid_headers := path.get_extension().to_lower() in ["tscn", "tres"] and not (("'%s'" % target_text) in text)
			for line in text.split("\n"):
				if ("\"%s\"" % target_text) in line:
					only_uid_headers = only_uid_headers and line.strip_edges().begins_with("[ext_resource ") and not uid_text.is_empty() and ("uid=\"%s\"" % uid_text) in line
			if not only_uid_headers:
				hits.append({"path": target, "kind": "path"})
				continue
			uses_uid = true
		if uses_uid:
			if not ResourceUID.has_id(uid) or ResourceUID.get_id_path(uid) != target:
				_fault = "UID mapping is not authoritative for %s" % target
				return hits
			hits.append({"path": target, "kind": "uid"})
	return hits


func _editor_state_guard(targets: Dictionary) -> Dictionary:
	var settings := _settings_references(targets)
	if not settings.is_empty():
		return _unchanged("Project settings reference this resource; update those settings explicitly before mutating it", {"settings": settings})
	for scene in EditorInterface.get_open_scenes():
		if targets.has(scene):
			return _unchanged("Close affected scene tabs before mutating their files", {"scene": scene})
	for target: String in targets:
		var uid: int = targets[target].uid
		if uid != ResourceUID.INVALID_ID and (not ResourceUID.has_id(uid) or ResourceUID.get_id_path(uid) != target):
			return _unchanged("UID mapping is no longer authoritative for %s; nothing changed" % target)
	return {}


func _settings_references(targets: Dictionary) -> Array[String]:
	var settings: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.name)
		var value: Variant = ProjectSettings.get_setting(name)
		if not value is String:
			continue
		var path: String = value.trim_prefix("*")
		if path.begins_with("uid://"):
			var uid := ResourceUID.text_to_id(path)
			path = ResourceUID.get_id_path(uid) if ResourceUID.has_id(uid) else path
		if targets.has(path):
			settings.append(name)
	return settings


func _revalidate() -> bool:
	var original_directories := _directories.duplicate(true)
	_directories.clear()
	var files: Array[String] = []
	if not await _collect_tree("res://", files):
		return false
	if _directories != original_directories:
		_fault = "Project entries changed during discovery; retry after changes settle"
		return false
	var original := _fingerprints.duplicate(true)
	for path in original:
		if await _read_bounded(path) == null:
			return false
		if _fingerprints[path] != original[path]:
			_fault = "Owner changed during discovery: %s" % path
			return false
	var original_large := _large_owners.duplicate(true)
	for path in original_large:
		if not await _large_owner_unchanged(path, original_large[path]):
			_fault = "Owner changed during discovery: %s" % path
			return false
	return true


func _large_owner_unchanged(path: String, original: Dictionary) -> bool:
	if not FileAccess.file_exists(path):
		return false
	if FileAccess.get_modified_time(path) != int(original.get("modified", 0)):
		return false
	if _file_length(path) != int(original.get("size", -1)):
		return false
	if str(_owner_dependencies(path)) != str(original.get("dependencies", PackedStringArray())):
		return false
	return await _yield_if_needed()


func _confined_without_links(path: String) -> bool:
	var dir := DirAccess.open("res://")
	if dir == null or not dir.has_method("is_link"):
		_fault = "Filesystem link inspection is unavailable; refusing mutation"
		return false
	var current := "res://"
	for component in path.trim_prefix("res://").split("/"):
		current = current.path_join(component)
		if bool(dir.call("is_link", current)):
			_fault = "Linked filesystem paths cannot be mutated: %s" % current
			return false
	return true


func _destination_available(source: String, destination: String) -> bool:
	if not _confined_without_links(destination):
		return false
	if not FileAccess.file_exists(destination) and not DirAccess.dir_exists_absolute(destination):
		return true
	var parent := source.get_base_dir()
	if parent == destination.get_base_dir() and source.to_lower() == destination.to_lower():
		var dir := DirAccess.open(parent)
		if dir != null and dir.has_method("is_equivalent"):
			dir.include_hidden = true
			var entries := dir.get_files() + dir.get_directories()
			if entries.has(source.get_file()) and not entries.has(destination.get_file()) and bool(dir.call("is_equivalent", source, destination)):
				return true
	_fault = "Destination already exists or case-only identity is ambiguous: %s" % destination
	return false


func _rename(source: String, destination: String) -> int:
	if _io.is_valid():
		return int(_io.call("rename", source, destination))
	return DirAccess.rename_absolute(source, destination)


func _move(source: String, destination: String, directory: bool, group: Array[Dictionary], targets: Dictionary) -> Dictionary:
	var applied: Array[Dictionary] = []
	for item in group:
		var code := _rename(item.from, item.to)
		if code != OK:
			var unrestored: Array[Dictionary] = []
			for index in range(applied.size() - 1, -1, -1):
				var prior := applied[index]
				if _rename(prior.to, prior.from) != OK:
					unrestored.append(prior)
			var outcome := "unchanged" if applied.is_empty() else ("rolled_back" if unrestored.is_empty() else "partial")
			if not unrestored.is_empty():
				_reconcile_move(targets, source, destination, false)
			return _failure("Move failed: %s" % error_string(code), outcome, {"applied": applied, "unrestored": unrestored})
		applied.append(item)
	_reconcile_move(targets, source, destination)
	var moved: Array[Dictionary] = []
	for old_path: String in targets:
		moved.append({"from": old_path, "to": destination + old_path.trim_prefix(source)})
	return {"data": {"path": source, "new_path": destination, "kind": "directory" if directory else "file",
		"moved": moved, "moved_count": moved.size(), "uids_updated": _uid_count(targets), "outcome": "committed", "scan_required": directory,
		"dependencies_updated": [], "project_settings_updated": [], "warnings": [], "undoable": false,
		"reason": "Filesystem moves are persistent; move the resource back explicitly to revert"}}


func _reconcile_move(targets: Dictionary, source: String, destination: String, refresh_editor: bool = true) -> void:
	var efs := EditorInterface.get_resource_filesystem()
	for old_path: String in targets:
		var new_path := destination + old_path.trim_prefix(source)
		var actual := new_path if FileAccess.file_exists(new_path) else old_path
		var uid: int = targets[old_path].uid
		if uid != ResourceUID.INVALID_ID:
			if ResourceUID.has_id(uid):
				ResourceUID.set_id(uid, actual)
			else:
				ResourceUID.add_id(uid, actual)
		if actual != old_path and ResourceLoader.has_cached(old_path):
			var cached := ResourceLoader.get_cached_ref(old_path)
			if cached != null:
				cached.take_over_path(actual)
		# Updating a missing path removes orphan UID sidecars. On partial
		# outcomes retain those bytes for explicit recovery instead.
		if efs != null and refresh_editor:
			if old_path.to_lower() != actual.to_lower():
				efs.update_file(old_path)
			efs.update_file(actual)


func _remove(source: String, directory: bool, group: Array[Dictionary], targets: Dictionary, owners: Array, permanent: bool) -> Dictionary:
	var removed: Array[String] = []
	var failure := OK
	for item in group:
		var code: int
		if _io.is_valid():
			code = int(_io.call("remove" if permanent else "trash", item.from, ""))
		else:
			code = DirAccess.remove_absolute(item.from) if permanent else OS.move_to_trash(ProjectSettings.globalize_path(item.from))
		if code != OK:
			failure = code
			break
		removed.append(item.from)
	var efs := EditorInterface.get_resource_filesystem()
	for target: String in targets:
		if FileAccess.file_exists(target):
			continue
		var uid: int = targets[target].uid
		if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
			ResourceUID.remove_id(uid)
		if efs != null and failure == OK:
			efs.update_file(target)
	if failure != OK:
		var remaining: Array[String] = []
		for item in group:
			if FileAccess.file_exists(item.from) or DirAccess.dir_exists_absolute(item.from):
				remaining.append(item.from)
		return _failure("Removal failed: %s" % error_string(failure), "unchanged" if removed.is_empty() else "partial",
			{"removed": removed, "remaining": remaining, "trashed": not permanent})
	return {"data": {"path": source, "kind": "directory" if directory else "file", "removed": targets.keys(),
		"removed_count": targets.size(), "trashed": not permanent, "uids_released": _uid_count(targets),
		"project_settings_cleared": [], "referenced_by": owners, "outcome": "committed", "scan_required": directory, "warnings": [], "undoable": false,
		"reason": "Permanently deleted" if permanent else "Moved to the OS trash; restore it there to revert"}}


static func _uid_count(targets: Dictionary) -> int:
	var count := 0
	for entry in targets.values():
		if entry.uid != ResourceUID.INVALID_ID:
			count += 1
	return count


static func _is_sidecar(path: String) -> bool:
	return path.ends_with(".uid") or path.ends_with(".import")


func _set_fault(message: String, code: String = "") -> void:
	_fault = message
	_fault_code = code


func _fault_result() -> Dictionary:
	if _fault_code == Errors.FILESYSTEM_DISCOVERY_FAILED:
		return _failure(_fault, "unchanged", {}, _fault_code)
	return _unchanged(_fault)


static func _unchanged(message: String, details: Dictionary = {}) -> Dictionary:
	return _failure(message, "unchanged", details, Errors.INVALID_PARAMS)


static func _failure(message: String, outcome: String, details: Dictionary, code: String = Errors.INTERNAL_ERROR) -> Dictionary:
	var result := Errors.make(code, message)
	result.error["data"] = details.merged({"outcome": outcome, "retry_safe": outcome in ["unchanged", "rolled_back"]}, true)
	return result


static func _reserved(path: String) -> bool:
	var normalized := path.to_lower().trim_suffix("/")
	for reserved: String in ["res://.godot", "res://.git", PLUGIN_TREE]:
		if normalized == reserved or normalized.begins_with(reserved + "/") or reserved.begins_with(normalized + "/"):
			return true
	return false
