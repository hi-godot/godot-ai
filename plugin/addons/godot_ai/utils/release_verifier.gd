@tool
class_name McpReleaseVerifier
extends RefCounted

## Pure, static verification of a signed v4 release: the canonical manifest,
## its RSA signature, the archive, and the tree hash the installer compares
## after extraction and again after restart.
##
## Every rule here mirrors `src/godot_ai/release_verify.py`. The two must stay
## byte-for-byte compatible: the release pipeline produces the manifest with
## Python's `_canonical()` and the installed-tree hash with Python's
## `hash_tree()`, and this file re-derives both from raw bytes. Every function
## fails closed with a specific error string and never raises.

const REPOSITORY := "hi-godot/godot-ai"
const CHANNEL := "stable"
const ASSET_NAME := "godot-ai-v4-plugin.zip"
const PLUGIN_PREFIX := "addons/godot_ai/"
const PLUGIN_CONFIG := "addons/godot_ai/plugin.cfg"
const SCHEMA_VERSION := 1
const MAX_FILES := 4096
const MAX_FILE_SIZE := 64 * 1024 * 1024
const MAX_ARCHIVE_SIZE := 64 * 1024 * 1024
const MAX_TREE_SIZE := MAX_ARCHIVE_SIZE
const MAX_MANIFEST_SIZE := 1024 * 1024
## Signature length for the production RSA-4096 key. The check itself is
## derived from the supplied key's modulus so a smaller injected test key
## still verifies its own (shorter) signatures.
const SIGNATURE_SIZE := 512
const MIN_RSA_MODULUS_BYTES := 256
## Largest integer JSON can round-trip through Godot's double-based parser.
const MAX_SAFE_INTEGER := 9007199254740992
const READ_CHUNK := 1024 * 1024

const ROOT_KEYS := [
	"asset", "channel", "inventory", "repository", "schema_version", "source_commit", "tag", "version",
]
const ASSET_KEYS := ["name", "sha256", "size"]
const ROW_KEYS := ["path", "sha256", "size"]
const RESERVED_NAMES := [
	"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
	"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
	"COM¹", "COM²", "COM³",
	"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
	"LPT¹", "LPT²", "LPT³",
]
const _UNSAFE_PATH_CHARS := "<>:\"|?*"
## DER-encoded AlgorithmIdentifier for rsaEncryption with NULL parameters.
const _RSA_ALGORITHM := [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]


# ----- public API -------------------------------------------------------


## Authenticate raw manifest bytes against a detached signature and the
## caller's explicit expectations. `expected` carries `repository` and
## `channel`, optionally `version` (must equal the manifest's), and optionally
## `current_version` (the manifest must be strictly newer). Returns
## `{"ok": bool, "error": String, "manifest": Dictionary}`; the returned
## manifest has integer sizes normalised to `int`.
static func verify_manifest(
	manifest_bytes: PackedByteArray,
	signature: PackedByteArray,
	expected: Dictionary,
	public_key_pem: String,
) -> Dictionary:
	var result := {"ok": false, "error": "", "manifest": {}}
	if manifest_bytes.is_empty() or manifest_bytes.size() > MAX_MANIFEST_SIZE:
		result.error = "manifest: expected 1..%d bytes, got %d" % [MAX_MANIFEST_SIZE, manifest_bytes.size()]
		return result
	if not is_valid_utf8(manifest_bytes):
		result.error = "manifest: not valid UTF-8"
		return result
	var json := JSON.new()
	var parse_error := json.parse(manifest_bytes.get_string_from_utf8())
	if parse_error != OK:
		result.error = "manifest: invalid JSON: %s (line %d)" % [json.get_error_message(), json.get_error_line()]
		return result
	var canonical := canonical_json(json.data)
	if not bool(canonical.ok):
		result.error = "manifest: encoding is not canonical JSON: %s" % str(canonical.error)
		return result
	if canonical.bytes != manifest_bytes:
		result.error = "manifest: encoding is not canonical JSON"
		return result
	if not json.data is Dictionary:
		result.error = "manifest: expected a JSON object"
		return result
	var validated := validate_manifest_dict(json.data)
	if not bool(validated.ok):
		result.error = str(validated.error)
		return result
	var manifest: Dictionary = validated.manifest
	var identity_error := _check_identity(manifest, expected)
	if not identity_error.is_empty():
		result.error = identity_error
		return result
	var signature_error := verify_signature(manifest_bytes, signature, public_key_pem)
	if not signature_error.is_empty():
		result.error = signature_error
		return result
	result.ok = true
	result.manifest = manifest
	return result


## Check a zip on disk against an already-verified manifest: whole-file size
## and SHA-256 against `manifest.asset`, then the entry list against the
## inventory (exact names, exact order, no directory entries), then every
## entry's size and SHA-256 against its row. Returns `{"ok", "error"}`.
static func verify_archive(zip_path: String, manifest: Dictionary) -> Dictionary:
	var result := {"ok": false, "error": ""}
	var validated := validate_manifest_dict(manifest)
	if not bool(validated.ok):
		result.error = str(validated.error)
		return result
	var normalised: Dictionary = validated.manifest
	var asset: Dictionary = normalised["asset"]
	var hashed := sha256_file(zip_path)
	if not bool(hashed.ok):
		result.error = "archive: %s" % str(hashed.error)
		return result
	if int(hashed["size"]) != int(asset["size"]):
		result.error = "archive: size %d differs from signed manifest size %d" % [int(hashed["size"]), int(asset["size"])]
		return result
	if str(hashed.sha256) != str(asset["sha256"]):
		result.error = "archive: SHA-256 differs from signed manifest"
		return result
	var reader := ZIPReader.new()
	var open_error := reader.open(_absolute(zip_path))
	if open_error != OK:
		result.error = "archive: cannot open zip: %s" % error_string(open_error)
		return result
	var entries := reader.get_files()
	var rows: Array = normalised["inventory"]
	var expected_paths: Array[String] = []
	var expected_rows := {}
	for row in rows:
		expected_paths.append(str(row["path"]))
		expected_rows[str(row["path"])] = row
	var listing_error := _check_entry_names(entries, expected_paths, expected_rows)
	if not listing_error.is_empty():
		reader.close()
		result.error = listing_error
		return result
	var total := 0
	var config := PackedByteArray()
	for entry in entries:
		var row: Dictionary = expected_rows[entry]
		var data := reader.read_file(entry)
		if data.size() != int(row["size"]):
			reader.close()
			result.error = "archive entry %s: size %d differs from inventory size %d" % [entry, data.size(), int(row["size"])]
			return result
		if sha256_bytes(data) != str(row["sha256"]):
			reader.close()
			result.error = "archive entry %s: content differs from inventory" % entry
			return result
		total += data.size()
		if total > MAX_TREE_SIZE:
			reader.close()
			result.error = "archive: expanded tree exceeds %d-byte bound" % MAX_TREE_SIZE
			return result
		if entry == PLUGIN_CONFIG:
			config = data
	reader.close()
	var config_version := plugin_cfg_version(config)
	if config_version != str(normalised["version"]):
		result.error = "archive: plugin.cfg version %s differs from signed manifest version %s" % [
			config_version if not config_version.is_empty() else "(unreadable)", str(normalised["version"]),
		]
		return result
	result.ok = true
	return result


## Hash every regular file under `root` recursively. Returns
## `{"ok", "error", "files": {relative_path: {"size", "sha256"}}, "tree_sha256"}`.
##
## Tree-hash algorithm (shared verbatim with Python `release_verify.hash_tree`):
## relative POSIX paths sorted by UTF-8 byte order; for each file one line
## `sha256 + " " + str(size) + " " + path + "\n"`; `tree_sha256` is the hex
## SHA-256 of those lines concatenated. Symlinks anywhere in the tree fail.
static func hash_tree(root: String) -> Dictionary:
	var result := {"ok": false, "error": "", "files": {}, "tree_sha256": ""}
	var root_abs := _absolute(root)
	if not DirAccess.dir_exists_absolute(root_abs):
		result.error = "tree: directory does not exist: %s" % root_abs
		return result
	var files := {}
	var pending: Array[String] = [""]
	var total := 0
	while not pending.is_empty():
		var relative: String = pending.pop_back()
		var directory_abs := root_abs if relative.is_empty() else root_abs.path_join(relative)
		var directory := DirAccess.open(directory_abs)
		if directory == null:
			result.error = "tree: cannot open %s: %s" % [directory_abs, error_string(DirAccess.get_open_error())]
			return result
		directory.include_hidden = true
		directory.include_navigational = false
		for name in directory.get_directories():
			var child_abs := directory_abs.path_join(name)
			if directory.is_link(child_abs):
				result.error = "tree: link is not allowed: %s" % child_abs
				return result
			pending.append(name if relative.is_empty() else relative + "/" + name)
		for name in directory.get_files():
			var child_abs := directory_abs.path_join(name)
			if directory.is_link(child_abs):
				result.error = "tree: link is not allowed: %s" % child_abs
				return result
			var hashed := sha256_file(child_abs)
			if not bool(hashed.ok):
				result.error = "tree: %s" % str(hashed.error)
				return result
			total += int(hashed["size"])
			if files.size() >= MAX_FILES or total > MAX_TREE_SIZE:
				result.error = "tree: exceeds %d files or %d bytes" % [MAX_FILES, MAX_TREE_SIZE]
				return result
			var relative_path := name if relative.is_empty() else relative + "/" + name
			files[relative_path] = {"size": int(hashed["size"]), "sha256": str(hashed.sha256)}
	var sorted_paths: Array[String] = []
	for path in files:
		sorted_paths.append(str(path))
	sorted_paths.sort()
	var ordered := {}
	for path in sorted_paths:
		ordered[path] = files[path]
	result.files = ordered
	result.tree_sha256 = tree_hash_from_files(ordered)
	result.ok = true
	return result


## The tree hash a correct extraction of `manifest.inventory` must produce:
## the same line algorithm as `hash_tree` over the inventory rows with the
## `addons/godot_ai/` prefix stripped. Only `inventory` is read, and row
## order does not matter. Returns "" for a malformed inventory or a row
## outside `addons/godot_ai/`, which can never equal a real hash.
static func inventory_tree_hash(manifest: Dictionary) -> String:
	if not manifest.has("inventory") or not manifest["inventory"] is Array:
		return ""
	var files := {}
	for value in manifest["inventory"]:
		if not value is Dictionary:
			return ""
		var row: Dictionary = value
		if not _check_keys(row, ROW_KEYS, "row").is_empty():
			return ""
		var size := _integer(row["size"], "row.size", MAX_FILE_SIZE)
		if not row["path"] is String or not bool(size.ok) or not row["sha256"] is String:
			return ""
		var path := str(row["path"])
		var digest := str(row["sha256"])
		if not path.begins_with(PLUGIN_PREFIX) or path.length() == PLUGIN_PREFIX.length() or not _is_hex(digest, 64):
			return ""
		var relative := path.substr(PLUGIN_PREFIX.length())
		if files.has(relative):
			return ""
		files[relative] = {"size": int(size.value), "sha256": digest}
	if files.is_empty():
		return ""
	return tree_hash_from_files(files)


## Apply the tree-hash line algorithm to a `{relative_path: {size, sha256}}`
## dictionary (the `files` shape `hash_tree` returns).
static func tree_hash_from_files(files: Dictionary) -> String:
	var paths: Array[String] = []
	for path in files:
		paths.append(str(path))
	paths.sort()
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for path in paths:
		var entry: Dictionary = files[path]
		var line := "%s %d %s\n" % [str(entry["sha256"]), int(entry["size"]), path]
		context.update(line.to_utf8_buffer())
	return context.finish().hex_encode()


## Hex SHA-256 of a byte buffer.
static func sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


## Chunked SHA-256 of a file. Returns `{"ok", "error", "size", "sha256"}`;
## files beyond MAX_FILE_SIZE fail without being read to the end.
static func sha256_file(path: String) -> Dictionary:
	var result := {"ok": false, "error": "", "size": 0, "sha256": ""}
	var absolute := _absolute(path)
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		result.error = "cannot read %s: %s" % [absolute, error_string(FileAccess.get_open_error())]
		return result
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var size := 0
	while true:
		var chunk := file.get_buffer(READ_CHUNK)
		if chunk.is_empty():
			break
		size += chunk.size()
		if size > MAX_FILE_SIZE:
			file.close()
			result.error = "%s exceeds %d-byte bound" % [absolute, MAX_FILE_SIZE]
			return result
		context.update(chunk)
	var read_error := file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		result.error = "cannot read %s: %s" % [absolute, error_string(read_error)]
		return result
	result.size = size
	result.sha256 = context.finish().hex_encode()
	result.ok = true
	return result


## Serialise `value` exactly as Python's
## `json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"`
## encodes it: sorted keys, no whitespace, integers (including integral
## floats, which is what Godot's JSON parser yields for them) as integers,
## non-ASCII unescaped. Returns `{"ok", "error", "bytes"}`. Non-integral
## numbers fail: the manifest schema has none and Godot's float formatting
## is not guaranteed to match Python's.
static func canonical_json(value: Variant) -> Dictionary:
	var result := {"ok": false, "error": "", "bytes": PackedByteArray()}
	var text := _canonical_value(value, result)
	if not str(result.error).is_empty():
		return result
	result.bytes = (text + "\n").to_utf8_buffer()
	result.ok = true
	return result


## Strict UTF-8 validation: rejects overlong forms, surrogates, and code
## points beyond U+10FFFF, the same input Python's `bytes.decode` rejects.
static func is_valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	var size := bytes.size()
	while index < size:
		var lead := bytes[index]
		if lead < 0x80:
			index += 1
			continue
		var need := 0
		var code := 0
		if lead >= 0xC2 and lead <= 0xDF:
			need = 1
			code = lead & 0x1F
		elif lead >= 0xE0 and lead <= 0xEF:
			need = 2
			code = lead & 0x0F
		elif lead >= 0xF0 and lead <= 0xF4:
			need = 3
			code = lead & 0x07
		else:
			return false
		if index + need >= size:
			return false
		for offset in range(1, need + 1):
			var continuation := bytes[index + offset]
			if (continuation & 0xC0) != 0x80:
				return false
			code = (code << 6) | (continuation & 0x3F)
		if need == 2 and code < 0x800:
			return false
		if need == 3 and (code < 0x10000 or code > 0x10FFFF):
			return false
		if code >= 0xD800 and code <= 0xDFFF:
			return false
		index += need + 1
	return true


## Validate a parsed manifest's schema, bounds, and inventory path safety
## without checking identity or the signature. Returns
## `{"ok", "error", "manifest"}` where `manifest` is a normalised copy with
## integer fields as `int`.
static func validate_manifest_dict(root: Dictionary) -> Dictionary:
	var result := {"ok": false, "error": "", "manifest": {}}
	var root_error := _check_keys(root, ROOT_KEYS, "manifest")
	if not root_error.is_empty():
		result.error = root_error
		return result
	var schema := _integer(root["schema_version"], "manifest.schema_version", SCHEMA_VERSION)
	if not bool(schema.ok):
		result.error = str(schema.error)
		return result
	if int(schema.value) != SCHEMA_VERSION:
		result.error = "manifest.schema_version: expected %d" % SCHEMA_VERSION
		return result
	var manifest := {"schema_version": SCHEMA_VERSION}
	for key in ["repository", "channel", "tag", "version", "source_commit"]:
		var text := _string(root[key], "manifest.%s" % key)
		if not bool(text.ok):
			result.error = str(text.error)
			return result
		manifest[key] = str(text.value)
	if not root["asset"] is Dictionary:
		result.error = "manifest.asset: expected object"
		return result
	var asset: Dictionary = root["asset"]
	var asset_error := _check_keys(asset, ASSET_KEYS, "manifest.asset")
	if not asset_error.is_empty():
		result.error = asset_error
		return result
	if not asset["name"] is String or str(asset["name"]) != ASSET_NAME:
		result.error = "manifest.asset.name: expected %s" % ASSET_NAME
		return result
	var asset_size := _integer(asset["size"], "manifest.asset.size", MAX_ARCHIVE_SIZE)
	if not bool(asset_size.ok):
		result.error = str(asset_size.error)
		return result
	if not asset["sha256"] is String or not _is_hex(str(asset["sha256"]), 64):
		result.error = "manifest.asset.sha256: expected 64 lowercase hex characters"
		return result
	manifest["asset"] = {"name": ASSET_NAME, "size": int(asset_size.value), "sha256": str(asset["sha256"])}
	if not root["inventory"] is Array:
		result.error = "manifest.inventory: expected array"
		return result
	var rows: Array = root["inventory"]
	var inventory: Array = []
	var paths: Array[String] = []
	var total := 0
	for index in rows.size():
		var context := "manifest.inventory[%d]" % index
		if not rows[index] is Dictionary:
			result.error = "%s: expected object" % context
			return result
		var row: Dictionary = rows[index]
		var row_error := _check_keys(row, ROW_KEYS, context)
		if not row_error.is_empty():
			result.error = row_error
			return result
		var path := _string(row["path"], context + ".path")
		if not bool(path.ok):
			result.error = str(path.error)
			return result
		var size := _integer(row["size"], context + ".size", MAX_FILE_SIZE)
		if not bool(size.ok):
			result.error = str(size.error)
			return result
		if not row["sha256"] is String or not _is_hex(str(row["sha256"]), 64):
			result.error = "%s.sha256: expected 64 lowercase hex characters" % context
			return result
		total += int(size.value)
		paths.append(str(path.value))
		inventory.append({"path": str(path.value), "size": int(size.value), "sha256": str(row["sha256"])})
	var paths_error := _validate_paths(paths, "manifest.inventory")
	if not paths_error.is_empty():
		result.error = paths_error
		return result
	if total > MAX_TREE_SIZE:
		result.error = "manifest.inventory: expanded tree exceeds %d-byte bound" % MAX_TREE_SIZE
		return result
	if not paths.has(PLUGIN_CONFIG):
		result.error = "manifest.inventory: missing %s" % PLUGIN_CONFIG
		return result
	manifest["inventory"] = inventory
	result.manifest = manifest
	result.ok = true
	return result


## Verify a PKCS#1 v1.5 SHA-256 signature over `message` with a PEM
## SubjectPublicKeyInfo. Returns "" on success, otherwise the reason.
static func verify_signature(message: PackedByteArray, signature: PackedByteArray, public_key_pem: String) -> String:
	var modulus_size := rsa_modulus_size(public_key_pem)
	if modulus_size < MIN_RSA_MODULUS_BYTES:
		return "public key: expected a PEM RSA SubjectPublicKeyInfo of at least %d bits" % (MIN_RSA_MODULUS_BYTES * 8)
	if signature.size() != modulus_size:
		return "manifest signature: expected exactly %d bytes, got %d" % [modulus_size, signature.size()]
	var key := CryptoKey.new()
	if key.load_from_string(public_key_pem, true) != OK:
		return "public key: could not be loaded"
	var crypto := Crypto.new()
	var digest := PackedByteArray()
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(message)
	digest = context.finish()
	if not crypto.verify(HashingContext.HASH_SHA256, digest, signature, key):
		return "manifest signature: RSA PKCS#1 v1.5 SHA-256 verification failed"
	return ""


## Byte length of the RSA modulus inside a PEM SubjectPublicKeyInfo, or 0
## when the PEM is not a well-formed rsaEncryption public key.
static func rsa_modulus_size(public_key_pem: String) -> int:
	var lines := public_key_pem.replace("\r\n", "\n").strip_edges().split("\n")
	if (
		lines.size() < 3
		or lines[0].strip_edges() != "-----BEGIN PUBLIC KEY-----"
		or lines[lines.size() - 1].strip_edges() != "-----END PUBLIC KEY-----"
	):
		return 0
	var encoded := ""
	for index in range(1, lines.size() - 1):
		encoded += lines[index].strip_edges()
	if encoded.is_empty() or not _is_base64(encoded):
		return 0
	var der := Marshalls.base64_to_raw(encoded)
	if der.is_empty():
		return 0
	var outer := _der_item(der, 0, 0x30)
	if not bool(outer.ok) or int(outer.end) != der.size():
		return 0
	var body: PackedByteArray = outer.value
	var algorithm := _der_item(body, 0, 0x30)
	if not bool(algorithm.ok) or algorithm.value != PackedByteArray(_RSA_ALGORITHM):
		return 0
	var bits := _der_item(body, int(algorithm.end), 0x03)
	if not bool(bits.ok) or int(bits.end) != body.size():
		return 0
	var bit_string: PackedByteArray = bits.value
	if bit_string.is_empty() or bit_string[0] != 0:
		return 0
	var key := _der_item(bit_string, 1, 0x30)
	if not bool(key.ok) or int(key.end) != bit_string.size():
		return 0
	var key_body: PackedByteArray = key.value
	var modulus := _der_item(key_body, 0, 0x02)
	if not bool(modulus.ok):
		return 0
	var raw: PackedByteArray = modulus.value
	if raw.is_empty() or raw[0] & 0x80:
		return 0
	if raw.size() > 1 and raw[0] == 0:
		if not (raw[1] & 0x80):
			return 0
		raw = raw.slice(1)
	var exponent := _der_item(key_body, int(modulus.end), 0x02)
	if not bool(exponent.ok) or int(exponent.end) != key_body.size() or exponent.value.is_empty():
		return 0
	return raw.size()


## The single quoted `version="..."` line of a plugin.cfg, or "" when the
## file does not carry exactly one.
static func plugin_cfg_version(data: PackedByteArray) -> String:
	if not is_valid_utf8(data):
		return ""
	var expression := RegEx.new()
	if expression.compile("(?m)^\\s*version\\s*=\\s*\"([^\"]+)\"\\s*$") != OK:
		return ""
	var matches := expression.search_all(data.get_string_from_utf8())
	if matches.size() != 1:
		return ""
	return matches[0].get_string(1)


## Parse a dotted `major.minor.patch` version into three ints, or [] when
## it is not exactly three unsigned decimal components.
static func version_parts(version: String) -> Array[int]:
	var parts := version.split(".")
	if parts.size() != 3:
		return []
	var numbers: Array[int] = []
	for part in parts:
		if not _all_digits(part):
			return []
		numbers.append(int(part))
	return numbers


## True when `candidate` is strictly newer than `current` by tuple order.
static func is_newer_version(candidate: String, current: String) -> bool:
	var left := version_parts(candidate)
	var right := version_parts(current)
	if left.is_empty() or right.is_empty():
		return false
	for index in 3:
		if left[index] != right[index]:
			return left[index] > right[index]
	return false


# ----- identity ---------------------------------------------------------


static func _check_identity(manifest: Dictionary, expected: Dictionary) -> String:
	var repository := str(manifest["repository"])
	if repository != REPOSITORY or repository != str(expected.get("repository", REPOSITORY)):
		return "manifest.repository: expected %s" % REPOSITORY
	var channel := str(manifest["channel"])
	if channel != CHANNEL or channel != str(expected.get("channel", CHANNEL)):
		return "manifest.channel: v4 releases are stable-only"
	var version := str(manifest["version"])
	var parts := version_parts(version)
	if parts.is_empty() or parts[0] != 4:
		return "manifest.version: expected a 4.x.y version"
	if str(manifest["tag"]) != "v" + version:
		return "manifest.tag: expected v%s" % version
	if not _is_hex(str(manifest["source_commit"]), 40):
		return "manifest.source_commit: expected 40 lowercase hex characters"
	var expected_version := str(expected.get("version", ""))
	if not expected_version.is_empty() and expected_version != version:
		return "manifest.version: %s does not match the expected release %s" % [version, expected_version]
	var expected_tag := str(expected.get("tag", ""))
	if not expected_tag.is_empty() and expected_tag != str(manifest["tag"]):
		return "manifest.tag: %s does not match the expected tag %s" % [str(manifest["tag"]), expected_tag]
	var expected_commit := str(expected.get("source_commit", ""))
	if not expected_commit.is_empty() and expected_commit != str(manifest["source_commit"]):
		return "manifest.source_commit: does not match the expected commit"
	var current_version := str(expected.get("current_version", ""))
	if not current_version.is_empty():
		if version_parts(current_version).is_empty():
			return "current_version: %s is not a dotted major.minor.patch version" % current_version
		if not is_newer_version(version, current_version):
			return "manifest.version: %s is not newer than the installed %s" % [version, current_version]
	return ""


# ----- archive listing --------------------------------------------------


static func _check_entry_names(
	entries: PackedStringArray, expected_paths: Array[String], expected_rows: Dictionary
) -> String:
	var seen := {}
	for entry in entries:
		if entry.ends_with("/"):
			return "archive: directory entry is not allowed: %s" % entry
		if not expected_rows.has(entry):
			return "archive: entry is not in the signed inventory: %s" % entry
		if seen.has(entry):
			return "archive: duplicate entry: %s" % entry
		seen[entry] = true
	for path in expected_paths:
		if not seen.has(path):
			return "archive: inventory file is missing from the zip: %s" % path
	if Array(entries) != Array(expected_paths):
		return "archive: entries are not in the sorted inventory order"
	return ""


# ----- path safety ------------------------------------------------------


static func _validate_paths(paths: Array[String], context: String) -> String:
	if paths.is_empty() or paths.size() > MAX_FILES:
		return "%s: expected 1..%d paths" % [context, MAX_FILES]
	var sorted := paths.duplicate()
	sorted.sort()
	var exact := {}
	var identities := {}
	for index in paths.size():
		var path := paths[index]
		var path_error := _check_path(path, "%s[%d]" % [context, index])
		if not path_error.is_empty():
			return path_error
		if exact.has(path):
			return "%s: duplicate path %s" % [context, path]
		exact[path] = true
		var identity := path.to_lower()
		if identities.has(identity):
			return "%s: case-colliding paths %s and %s" % [context, str(identities[identity]), path]
		identities[identity] = path
	if paths != sorted:
		return "%s: paths are not in bytewise order" % context
	for path in paths:
		var parent := path.get_base_dir()
		while parent.contains("/"):
			if exact.has(parent):
				return "%s: file/ancestor collision at %s" % [context, parent]
			parent = parent.get_base_dir()
	return ""


static func _check_path(path: String, context: String) -> String:
	if not path.begins_with(PLUGIN_PREFIX) or path.ends_with("/") or path.contains("\\"):
		return "%s: path must be a file beneath %s: %s" % [context, PLUGIN_PREFIX, path]
	for part in path.split("/"):
		if part.is_empty() or part == "." or part == ".." or part.ends_with(" ") or part.ends_with("."):
			return "%s: unsafe path component in %s" % [context, path]
		for index in part.length():
			var code := part.unicode_at(index)
			if code < 32 or _UNSAFE_PATH_CHARS.contains(char(code)):
				return "%s: unsafe path character in %s" % [context, path]
		var stem := part.split(".", true, 1)[0]
		if RESERVED_NAMES.has(stem.to_upper()):
			return "%s: reserved path component in %s" % [context, path]
	return ""


# ----- schema helpers ---------------------------------------------------


static func _check_keys(value: Dictionary, expected_keys: Array, context: String) -> String:
	var keys := value.keys()
	for key in keys:
		if not key is String:
			return "%s: expected object with exactly keys %s" % [context, str(expected_keys)]
	keys.sort()
	if keys != expected_keys:
		return "%s: expected object with exactly keys %s" % [context, str(expected_keys)]
	return ""


static func _string(value: Variant, context: String) -> Dictionary:
	if not value is String or str(value).is_empty():
		return {"ok": false, "error": "%s: expected non-empty string" % context, "value": ""}
	return {"ok": true, "error": "", "value": str(value)}


## Accept `int`, or the integral `float` Godot's JSON parser yields, within
## `[0, maximum]`. Booleans are rejected.
static func _integer(value: Variant, context: String, maximum: int) -> Dictionary:
	var failure := {"ok": false, "error": "%s: expected integer in [0, %d]" % [context, maximum], "value": 0}
	var number := 0
	if value is int:
		number = value
	elif value is float:
		var real: float = value
		if real != floor(real) or absf(real) > MAX_SAFE_INTEGER:
			return failure
		number = int(real)
	else:
		return failure
	if number < 0 or number > maximum:
		return failure
	return {"ok": true, "error": "", "value": number}


static func _is_hex(text: String, length: int) -> bool:
	if text.length() != length:
		return false
	for index in text.length():
		var code := text.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


static func _all_digits(text: String) -> bool:
	if text.is_empty():
		return false
	for index in text.length():
		var code := text.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


static func _is_base64(text: String) -> bool:
	for index in text.length():
		var code := text.unicode_at(index)
		var ok := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or (code >= 48 and code <= 57)
			or code == 43 or code == 47 or code == 61
		)
		if not ok:
			return false
	return true


# ----- canonical JSON ---------------------------------------------------


static func _canonical_value(value: Variant, result: Dictionary) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return String.num_int64(value)
		TYPE_FLOAT:
			var real: float = value
			if real != floor(real) or absf(real) > MAX_SAFE_INTEGER:
				result.error = "non-integer number %s" % str(real)
				return ""
			return String.num_int64(int(real))
		TYPE_STRING, TYPE_STRING_NAME:
			return _escape_json_string(str(value))
		TYPE_ARRAY:
			var items: Array[String] = []
			for item in value:
				items.append(_canonical_value(item, result))
				if not str(result.error).is_empty():
					return ""
			return "[" + ",".join(items) + "]"
		TYPE_DICTIONARY:
			var dictionary: Dictionary = value
			var keys: Array = dictionary.keys()
			for key in keys:
				if not key is String:
					result.error = "non-string object key"
					return ""
			keys.sort()
			var members: Array[String] = []
			for key in keys:
				var member := _canonical_value(dictionary[key], result)
				if not str(result.error).is_empty():
					return ""
				members.append(_escape_json_string(str(key)) + ":" + member)
			return "{" + ",".join(members) + "}"
		_:
			result.error = "unsupported JSON value type %s" % type_string(typeof(value))
			return ""


static func _escape_json_string(text: String) -> String:
	var out := "\""
	for index in text.length():
		var code := text.unicode_at(index)
		match code:
			0x22:
				out += "\\\""
			0x5C:
				out += "\\\\"
			0x0A:
				out += "\\n"
			0x0D:
				out += "\\r"
			0x09:
				out += "\\t"
			0x08:
				out += "\\b"
			0x0C:
				out += "\\f"
			_:
				if code < 0x20:
					out += "\\u%04x" % code
				else:
					out += char(code)
	return out + "\""


# ----- DER --------------------------------------------------------------


static func _der_item(data: PackedByteArray, offset: int, tag: int) -> Dictionary:
	var failure := {"ok": false, "value": PackedByteArray(), "end": 0}
	var size := data.size()
	if offset >= size or data[offset] != tag:
		return failure
	offset += 1
	if offset >= size:
		return failure
	var first := data[offset]
	offset += 1
	var length := 0
	if first < 0x80:
		length = first
	else:
		var count := first & 0x7F
		if count < 1 or count > 4 or offset + count > size or data[offset] == 0:
			return failure
		for index in count:
			length = (length << 8) | data[offset + index]
		offset += count
		if length < 0x80:
			return failure
	var end := offset + length
	if end > size:
		return failure
	return {"ok": true, "value": data.slice(offset, end), "end": end}


# ----- paths ------------------------------------------------------------


static func _absolute(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path
