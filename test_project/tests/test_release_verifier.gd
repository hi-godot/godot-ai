@tool
extends McpTestSuite

## McpReleaseVerifier as pure functions: a fixture RSA key pair generated
## here, a manifest built and signed in-test, and a zip built in-test by a
## minimal stored-ZIP writer (Godot 4.7's ZIPPacker injects parent-directory
## entries, which the verifier must reject, so the fixture cannot use it).
##
## The fixture key is RSA-2048 because `Crypto.generate_rsa(4096)` takes
## seconds; only the injected-key path uses it. Production verifies with the
## embedded RSA-4096 key, whose 512-byte signature size is asserted below via
## `rsa_modulus_size`.
##
## The static fixture builders are reused by test_update_installer.gd.

const FIXTURE_DIR := "res://addons/.godot_ai_update/_test_verifier"
const VERSION := "4.9.9"
const TAG := "v4.9.9"
const COMMIT := "0123456789abcdef0123456789abcdef01234567"
const PREFIX := "addons/godot_ai/"

## python3 -c 'import json; print((json.dumps({"b":[1,{"z":True,"y":None}],
## "a":"x\"y\\\\\né/","n":0,"big":67108864,"neg":-5},
## sort_keys=True, separators=(",", ":"), ensure_ascii=False)+"\n").encode().hex())'
const CANONICAL_ANCHOR_HEX := (
	"7b2261223a22785c22795c5c5c6e5c7530303031c3a92f222c2262223a5b312c7b2279223a6e756c6c2c227a223a747275657d5d2c"
	+ "22626967223a36373130383836342c226e223a302c226e6567223a2d357d0a"
)
## Pinned with tests/unit/test_tree_hash_parity.py on the Python side: the
## same 10-file tree must hash to the same digest there and here.
const PARITY_TREE_SHA256 := "36b71557e16593f40192617dbf023f8c52043948e137b159030bdeaedfdac055"
const PARITY_ORDER := [
	"Z.txt", "a.txt", "dir.txt", "dir/b.gd", "dir/sub/deep.txt", "dir/with space.txt",
	"empty.bin", "plugin.cfg", "zz.txt", "é.txt",
]
const SHA256_ABC := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
const SHA256_EMPTY := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

var _crypto := Crypto.new()
var _key: CryptoKey
var _other_key: CryptoKey
var _public_pem := ""
var _other_pem := ""
var _entries := {}
var _zip_bytes := PackedByteArray()
var _zip_path := FIXTURE_DIR + "/fixture.zip"


func suite_name() -> String:
	return "release_verifier"


func suite_setup(_ctx: Dictionary) -> void:
	_key = _crypto.generate_rsa(2048)
	_other_key = _crypto.generate_rsa(2048)
	_public_pem = _key.save_to_string(true)
	_other_pem = _other_key.save_to_string(true)
	_entries = fixture_entries()
	_zip_bytes = build_zip(_entries)
	var rooted := McpUpdateInstaller.ensure_root()
	if not bool(rooted.ok):
		fail_setup("cannot create update root: %s" % str(rooted.error))
		return
	if not write_fixture(_zip_path, _zip_bytes):
		fail_setup("cannot write fixture zip")


func suite_teardown() -> void:
	clean_fixture_dir(FIXTURE_DIR)


# ----- fixture builders (shared with test_update_installer.gd) --------


static func fixture_entries(version: String = VERSION) -> Dictionary:
	return {
		PREFIX + "plugin.cfg": ('[plugin]\nname="Godot AI"\nversion="%s"\nscript="plugin.gd"\n' % version).to_utf8_buffer(),
		PREFIX + "plugin.gd": "@tool\nextends EditorPlugin\n".to_utf8_buffer(),
		PREFIX + "utils/helper.gd": "extends RefCounted\n".to_utf8_buffer(),
	}


static func parity_tree() -> Dictionary:
	return {
		"plugin.cfg": '[plugin]\nversion="4.0.0"\n'.to_utf8_buffer(),
		"dir/b.gd": "extends Node\n".to_utf8_buffer(),
		"dir/sub/deep.txt": "deep\n".to_utf8_buffer(),
		"dir.txt": "not a directory\n".to_utf8_buffer(),
		"Z.txt": "upper\n".to_utf8_buffer(),
		"a.txt": "lower\n".to_utf8_buffer(),
		"zz.txt": "ascii last\n".to_utf8_buffer(),
		"é.txt": "accent é\n".to_utf8_buffer(),
		"dir/with space.txt": "space\n".to_utf8_buffer(),
		"empty.bin": PackedByteArray(),
	}


## Rows for `entries`, sorted bytewise by path.
static func inventory_rows(entries: Dictionary) -> Array:
	var paths := entries.keys()
	paths.sort()
	var rows := []
	for path in paths:
		var data: PackedByteArray = entries[path]
		rows.append({"path": str(path), "size": data.size(), "sha256": McpReleaseVerifier.sha256_bytes(data)})
	return rows


static func build_manifest(entries: Dictionary, zip_bytes: PackedByteArray, overrides: Dictionary = {}) -> Dictionary:
	var manifest := {
		"schema_version": 1,
		"repository": "hi-godot/godot-ai",
		"channel": "stable",
		"tag": TAG,
		"version": VERSION,
		"source_commit": COMMIT,
		"asset": {
			"name": "godot-ai-v4-plugin.zip",
			"size": zip_bytes.size(),
			"sha256": McpReleaseVerifier.sha256_bytes(zip_bytes),
		},
		"inventory": inventory_rows(entries),
	}
	for key in overrides:
		manifest[key] = overrides[key]
	return manifest


static func canonical_bytes(manifest: Dictionary) -> PackedByteArray:
	return McpReleaseVerifier.canonical_json(manifest).bytes


static func sha256_digest(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()


static func sign_bytes(bytes: PackedByteArray, key: CryptoKey) -> PackedByteArray:
	return Crypto.new().sign(HashingContext.HASH_SHA256, sha256_digest(bytes), key)


## Minimal stored (uncompressed) ZIP writer: entries in insertion order,
## fixed 1980-01-01 timestamps, Unix mode bits, no extra fields.
static func build_zip(entries: Dictionary) -> PackedByteArray:
	var local := StreamPeerBuffer.new()
	var central := StreamPeerBuffer.new()
	var count := 0
	for name in entries:
		var data: PackedByteArray = entries[name]
		var name_bytes := str(name).to_utf8_buffer()
		var crc := crc32(data)
		var offset := local.get_size()
		local.put_u32(0x04034b50)
		local.put_u16(20)
		local.put_u16(0)
		local.put_u16(0)
		local.put_u16(0)
		local.put_u16(0x0021)
		local.put_u32(crc)
		local.put_u32(data.size())
		local.put_u32(data.size())
		local.put_u16(name_bytes.size())
		local.put_u16(0)
		local.put_data(name_bytes)
		local.put_data(data)
		central.put_u32(0x02014b50)
		central.put_u16(0x031e)
		central.put_u16(20)
		central.put_u16(0)
		central.put_u16(0)
		central.put_u16(0)
		central.put_u16(0x0021)
		central.put_u32(crc)
		central.put_u32(data.size())
		central.put_u32(data.size())
		central.put_u16(name_bytes.size())
		central.put_u16(0)
		central.put_u16(0)
		central.put_u16(0)
		central.put_u16(0)
		var mode := 16877 if str(name).ends_with("/") else 33188
		central.put_u32(mode << 16)
		central.put_u32(offset)
		central.put_data(name_bytes)
		count += 1
	var out := StreamPeerBuffer.new()
	out.put_data(local.data_array)
	var central_offset := out.get_size()
	out.put_data(central.data_array)
	out.put_u32(0x06054b50)
	out.put_u16(0)
	out.put_u16(0)
	out.put_u16(count)
	out.put_u16(count)
	out.put_u32(central.get_size())
	out.put_u32(central_offset)
	out.put_u16(0)
	return out.data_array


static func crc32(data: PackedByteArray) -> int:
	var crc := 0xFFFFFFFF
	for byte in data:
		crc ^= byte
		for _bit in 8:
			if crc & 1:
				crc = (crc >> 1) ^ 0xEDB88320
			else:
				crc = crc >> 1
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


static func write_fixture(path: String, bytes: PackedByteArray) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return false
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	var error := file.get_error()
	file.close()
	return error == OK


static func read_fixture(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(path))


static func write_tree(root: String, files: Dictionary) -> bool:
	for relative in files:
		if not write_fixture(root + "/" + str(relative), files[relative]):
			return false
	return true


static func clean_fixture_dir(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute) or FileAccess.file_exists(absolute):
		McpUpdateInstaller.remove_under_update_root(path)


# ----- per-test helpers ------------------------------------------------


func _expected(extra: Dictionary = {}) -> Dictionary:
	var expected := {"repository": "hi-godot/godot-ai", "channel": "stable"}
	for key in extra:
		expected[key] = extra[key]
	return expected


func _manifest(overrides: Dictionary = {}) -> Dictionary:
	return build_manifest(_entries, _zip_bytes, overrides)


## `extra` is merged over the default `{repository, channel}` expectation.
func _verify_signed(manifest: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var bytes := canonical_bytes(manifest)
	return McpReleaseVerifier.verify_manifest(bytes, sign_bytes(bytes, _key), _expected(extra), _public_pem)


func _assert_rejected(manifest: Dictionary, needle: String, extra: Dictionary = {}) -> void:
	var result := _verify_signed(manifest, extra)
	assert_false(bool(result.ok), "expected rejection containing %s, got ok" % needle)
	assert_contains(str(result.error), needle)
	assert_true((result.manifest as Dictionary).is_empty(), "a rejected manifest must not be returned")


func _with_rows(rows: Array) -> Dictionary:
	return _manifest({"inventory": rows})


func _row(path: String, data: PackedByteArray = "x".to_utf8_buffer()) -> Dictionary:
	return {"path": path, "size": data.size(), "sha256": McpReleaseVerifier.sha256_bytes(data)}


# ----- manifest: acceptance ---------------------------------------------


func test_valid_manifest_accepted() -> void:
	var result := _verify_signed(_manifest())
	assert_true(bool(result.ok), str(result.error))
	assert_eq(str(result.error), "")
	var manifest: Dictionary = result.manifest
	assert_eq(str(manifest.version), VERSION)
	assert_eq(str(manifest.tag), TAG)
	assert_eq(typeof(manifest["asset"]["size"]), TYPE_INT, "sizes are normalised to int")
	assert_eq(int(manifest["asset"]["size"]), _zip_bytes.size())
	assert_eq((manifest["inventory"] as Array).size(), 3)
	assert_eq(typeof(manifest["inventory"][0]["size"]), TYPE_INT)
	assert_eq(str(manifest["inventory"][0]["path"]), PREFIX + "plugin.cfg")


func test_expected_version_and_older_current_version_accepted() -> void:
	var same_major := _verify_signed(_manifest(), {"version": VERSION, "current_version": "4.9.8"})
	assert_true(bool(same_major.ok), str(same_major.error))
	var major_crossing := _verify_signed(_manifest(), {"current_version": "3.2.2"})
	assert_true(bool(major_crossing.ok), "a v3 install must be allowed to cross to v4: %s" % str(major_crossing.error))
	var minor_bump := _verify_signed(_manifest(), {"current_version": "4.8.20"})
	assert_true(bool(minor_bump.ok), str(minor_bump.error))


# ----- manifest: signature ----------------------------------------------


func test_wrong_key_rejected() -> void:
	var bytes := canonical_bytes(_manifest())
	var result := McpReleaseVerifier.verify_manifest(bytes, sign_bytes(bytes, _other_key), _expected(), _public_pem)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "signature")
	assert_contains(str(result.error), "verification failed")


func test_altered_byte_rejected() -> void:
	var bytes := canonical_bytes(_manifest())
	var signature := sign_bytes(bytes, _key)
	var offset := bytes.get_string_from_utf8().find(COMMIT)
	assert_gt(offset, 0, "fixture manifest is ASCII so the commit offset is a byte offset")
	bytes[offset] = "f".unicode_at(0)
	var result := McpReleaseVerifier.verify_manifest(bytes, signature, _expected(), _public_pem)
	assert_false(bool(result.ok), "a single altered byte must fail the signature")
	assert_contains(str(result.error), "signature")


func test_signature_size_must_match_key_modulus() -> void:
	var bytes := canonical_bytes(_manifest())
	var signature := sign_bytes(bytes, _key)
	assert_eq(signature.size(), 256, "RSA-2048 fixture signatures are 256 bytes")
	var truncated := McpReleaseVerifier.verify_manifest(bytes, signature.slice(0, 255), _expected(), _public_pem)
	assert_false(bool(truncated.ok))
	assert_contains(str(truncated.error), "expected exactly 256 bytes")
	var padded := signature.duplicate()
	padded.append(0)
	var too_long := McpReleaseVerifier.verify_manifest(bytes, padded, _expected(), _public_pem)
	assert_false(bool(too_long.ok))
	assert_contains(str(too_long.error), "expected exactly 256 bytes")


func test_rsa_modulus_size_is_512_for_the_embedded_production_key() -> void:
	assert_eq(McpReleaseVerifier.rsa_modulus_size(McpUpdateManager.RELEASE_SIGNING_PUBLIC_KEY_PEM), 512)
	assert_eq(McpReleaseVerifier.rsa_modulus_size(_public_pem), 256)
	assert_eq(McpReleaseVerifier.rsa_modulus_size("garbage"), 0)
	assert_eq(McpReleaseVerifier.rsa_modulus_size(""), 0)
	var private_pem := _key.save_to_string(false)
	assert_eq(McpReleaseVerifier.rsa_modulus_size(private_pem), 0, "a private key PEM is not a SubjectPublicKeyInfo")


func test_unloadable_public_key_rejected() -> void:
	var bytes := canonical_bytes(_manifest())
	var result := McpReleaseVerifier.verify_manifest(bytes, sign_bytes(bytes, _key), _expected(), "not a pem")
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "public key")


# ----- manifest: canonical encoding ------------------------------------


func test_non_canonical_json_rejected_even_when_signed() -> void:
	var pretty := (JSON.stringify(_manifest(), "  ", true) + "\n").to_utf8_buffer()
	var result := McpReleaseVerifier.verify_manifest(pretty, sign_bytes(pretty, _key), _expected(), _public_pem)
	assert_false(bool(result.ok), "whitespace is not canonical even with a valid signature over it")
	assert_contains(str(result.error), "canonical")


func test_trailing_newline_is_part_of_the_canonical_form() -> void:
	var bytes := canonical_bytes(_manifest())
	assert_eq(bytes[bytes.size() - 1], 10, "canonical bytes end with a newline")
	var stripped := bytes.slice(0, bytes.size() - 1)
	var result := McpReleaseVerifier.verify_manifest(stripped, sign_bytes(stripped, _key), _expected(), _public_pem)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "canonical")


func test_canonical_json_matches_python_anchor() -> void:
	var sample := {
		"b": [1, {"z": true, "y": null}],
		"a": "x\"y\\\né/",
		"n": 0,
		"big": 67108864,
		"neg": -5,
	}
	var result := McpReleaseVerifier.canonical_json(sample)
	assert_true(bool(result.ok), str(result.error))
	assert_eq((result.bytes as PackedByteArray).hex_encode(), CANONICAL_ANCHOR_HEX)
	var from_parser := McpReleaseVerifier.canonical_json(JSON.parse_string((result.bytes as PackedByteArray).get_string_from_utf8()))
	assert_eq((from_parser.bytes as PackedByteArray).hex_encode(), CANONICAL_ANCHOR_HEX, "parsed floats re-serialise as integers")
	var fractional := McpReleaseVerifier.canonical_json({"x": 1.5})
	assert_false(bool(fractional.ok), "non-integral numbers have no canonical form here")


func test_invalid_utf8_and_malformed_json_rejected() -> void:
	var bytes := canonical_bytes(_manifest())
	var broken := bytes.duplicate()
	broken[0] = 0xff
	var invalid := McpReleaseVerifier.verify_manifest(broken, sign_bytes(broken, _key), _expected(), _public_pem)
	assert_false(bool(invalid.ok))
	assert_contains(str(invalid.error), "UTF-8")
	var truncated := bytes.slice(0, bytes.size() - 3)
	var malformed := McpReleaseVerifier.verify_manifest(truncated, sign_bytes(truncated, _key), _expected(), _public_pem)
	assert_false(bool(malformed.ok))
	assert_contains(str(malformed.error), "invalid JSON")
	var empty := McpReleaseVerifier.verify_manifest(PackedByteArray(), PackedByteArray(), _expected(), _public_pem)
	assert_false(bool(empty.ok))
	assert_contains(str(empty.error), "bytes")
	assert_true(McpReleaseVerifier.is_valid_utf8("plain é 😀".to_utf8_buffer()))
	assert_false(McpReleaseVerifier.is_valid_utf8(PackedByteArray([0xc0, 0x80])), "overlong")
	assert_false(McpReleaseVerifier.is_valid_utf8(PackedByteArray([0xed, 0xa0, 0x80])), "surrogate")
	assert_false(McpReleaseVerifier.is_valid_utf8(PackedByteArray([0xe2, 0x82])), "truncated sequence")


# ----- manifest: identity -----------------------------------------------


func test_wrong_repository_rejected() -> void:
	_assert_rejected(_manifest({"repository": "someone/else"}), "repository")


func test_wrong_channel_rejected() -> void:
	_assert_rejected(_manifest({"channel": "beta"}), "channel")


func test_older_or_equal_version_rejected() -> void:
	_assert_rejected(_manifest(), "not newer", {"current_version": VERSION})
	_assert_rejected(_manifest(), "not newer", {"current_version": "4.10.0"})
	_assert_rejected(_manifest(), "not newer", {"current_version": "5.0.0"})
	_assert_rejected(_manifest(), "current_version", {"current_version": "4.9"})


func test_expected_version_mismatch_rejected() -> void:
	_assert_rejected(_manifest(), "does not match the expected release", {"version": "4.9.8"})


func test_tag_and_version_shape_rejected() -> void:
	_assert_rejected(_manifest({"tag": "v4.9.8"}), "manifest.tag")
	_assert_rejected(_manifest({"tag": "4.9.9"}), "manifest.tag")
	_assert_rejected(_manifest({"version": "3.9.9", "tag": "v3.9.9"}), "4.x.y")
	_assert_rejected(_manifest({"version": "4.9", "tag": "v4.9"}), "4.x.y")


func test_bad_source_commit_rejected() -> void:
	_assert_rejected(_manifest({"source_commit": "abc"}), "source_commit")
	_assert_rejected(_manifest({"source_commit": COMMIT.to_upper()}), "source_commit")


# ----- manifest: schema -------------------------------------------------


func test_schema_rejections() -> void:
	_assert_rejected(_manifest({"schema_version": 2}), "schema_version")
	_assert_rejected(_manifest({"extra": true}), "exactly keys")
	var missing := _manifest()
	missing.erase("asset")
	_assert_rejected(missing, "exactly keys")
	var asset := _manifest()
	asset["asset"]["name"] = "other.zip"
	_assert_rejected(asset, "asset.name")
	var oversized := _manifest()
	oversized["asset"]["size"] = McpReleaseVerifier.MAX_ARCHIVE_SIZE + 1
	_assert_rejected(oversized, "asset.size")
	var bad_hash := _manifest()
	bad_hash["asset"]["sha256"] = "X".repeat(64)
	_assert_rejected(bad_hash, "asset.sha256")
	_assert_rejected(_manifest({"inventory": "nope"}), "expected array")
	_assert_rejected(_manifest({"inventory": []}), "1..4096")


# ----- manifest: inventory path safety ---------------------------------


func test_path_outside_plugin_prefix_rejected() -> void:
	var rows := inventory_rows(_entries)
	_assert_rejected(_with_rows([_row("/etc/passwd")] + rows), "beneath " + PREFIX)
	_assert_rejected(_with_rows(rows + [_row("addons/other/x.gd")]), "beneath " + PREFIX)
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "x\\y.gd")]), "beneath " + PREFIX)
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "utils/")]), "beneath " + PREFIX)


func test_dot_dot_and_empty_segments_rejected() -> void:
	var rows := inventory_rows(_entries)
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "../x.gd")]), "unsafe path component")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "utils/../x.gd")]), "unsafe path component")
	_assert_rejected(_with_rows([_row(PREFIX + "/x.gd")] + rows), "unsafe path component")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "utils//x.gd")]), "unsafe path component")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "utils/x.")]), "unsafe path component")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "utils/x ")]), "unsafe path component")


func test_unsafe_characters_and_reserved_names_rejected() -> void:
	var rows := inventory_rows(_entries)
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "x<y.gd")]), "unsafe path character")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "x:y.gd")]), "unsafe path character")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "x\ty.gd")]), "unsafe path character")
	_assert_rejected(_with_rows([_row(PREFIX + "CON.gd")] + rows), "reserved path component")
	_assert_rejected(_with_rows([_row(PREFIX + "LPT1")] + rows), "reserved path component")
	_assert_rejected(_with_rows([_row(PREFIX + "Aux.txt")] + rows), "reserved path component")


func test_duplicate_and_colliding_paths_rejected() -> void:
	var rows := inventory_rows(_entries)
	_assert_rejected(_with_rows([rows[0]] + rows), "duplicate path")
	_assert_rejected(_with_rows([_row(PREFIX + "PLUGIN.cfg")] + rows), "case-colliding")
	_assert_rejected(_with_rows(rows + [_row(PREFIX + "utils/HELPER.gd")]), "case-colliding")
	var nested := rows.duplicate()
	nested.insert(2, _row(PREFIX + "plugin.gd/inner.gd"))
	_assert_rejected(_with_rows(nested), "file/ancestor collision")


func test_unsorted_missing_config_and_too_many_rows_rejected() -> void:
	var rows := inventory_rows(_entries)
	var reversed := rows.duplicate()
	reversed.reverse()
	_assert_rejected(_with_rows(reversed), "bytewise order")
	_assert_rejected(_with_rows(rows.slice(1)), "missing " + PREFIX + "plugin.cfg")
	var many := []
	for index in McpReleaseVerifier.MAX_FILES + 1:
		many.append(_row(PREFIX + "f%05d.gd" % index))
	_assert_rejected(_with_rows(many), "1..4096")
	var oversized := rows.duplicate()
	oversized[1] = {"path": rows[1]["path"], "size": McpReleaseVerifier.MAX_FILE_SIZE + 1, "sha256": rows[1]["sha256"]}
	_assert_rejected(_with_rows(oversized), "size")


# ----- archive ----------------------------------------------------------


func test_archive_accepted() -> void:
	var result := McpReleaseVerifier.verify_archive(_zip_path, _manifest())
	assert_true(bool(result.ok), str(result.error))
	assert_eq(str(result.error), "")


func test_archive_size_and_sha_rejected() -> void:
	var bigger := _manifest()
	bigger["asset"]["size"] = _zip_bytes.size() + 1
	var size_result := McpReleaseVerifier.verify_archive(_zip_path, bigger)
	assert_false(bool(size_result.ok))
	assert_contains(str(size_result.error), "size")
	var altered := _manifest()
	altered["asset"]["sha256"] = SHA256_ABC
	var sha_result := McpReleaseVerifier.verify_archive(_zip_path, altered)
	assert_false(bool(sha_result.ok))
	assert_contains(str(sha_result.error), "SHA-256")
	var missing := McpReleaseVerifier.verify_archive(FIXTURE_DIR + "/absent.zip", _manifest())
	assert_false(bool(missing.ok))
	assert_contains(str(missing.error), "cannot read")


func _archive_with(entries: Dictionary, inventory_entries: Dictionary) -> Dictionary:
	var zip := build_zip(entries)
	var path := FIXTURE_DIR + "/variant.zip"
	assert_true(write_fixture(path, zip), "variant zip written")
	return McpReleaseVerifier.verify_archive(path, build_manifest(inventory_entries, zip))


func test_archive_extra_entry_rejected() -> void:
	var entries := _entries.duplicate()
	entries[PREFIX + "zzz_extra.gd"] = "extra".to_utf8_buffer()
	var result := _archive_with(entries, _entries)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "not in the signed inventory")


func test_archive_missing_entry_rejected() -> void:
	var entries := _entries.duplicate()
	entries.erase(PREFIX + "utils/helper.gd")
	var result := _archive_with(entries, _entries)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "missing from the zip")


func test_archive_directory_entry_rejected() -> void:
	var entries := {}
	for path in _entries:
		if str(path).ends_with("helper.gd"):
			entries[PREFIX + "utils/"] = PackedByteArray()
		entries[path] = _entries[path]
	var result := _archive_with(entries, _entries)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "directory entry")


func test_archive_wrong_entry_hash_rejected() -> void:
	var entries := _entries.duplicate()
	## Same length as the signed content so only the SHA-256 differs.
	entries[PREFIX + "plugin.gd"] = "@tool\nextends EditorPlugiX\n".to_utf8_buffer()
	assert_eq(entries[PREFIX + "plugin.gd"].size(), _entries[PREFIX + "plugin.gd"].size())
	var result := _archive_with(entries, _entries)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "content differs from inventory")
	assert_contains(str(result.error), "plugin.gd")


func test_archive_entry_order_must_match_inventory() -> void:
	var entries := {}
	var paths := _entries.keys()
	paths.reverse()
	for path in paths:
		entries[path] = _entries[path]
	var result := _archive_with(entries, _entries)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "sorted inventory order")


func test_archive_plugin_cfg_version_must_match_manifest() -> void:
	var entries := fixture_entries("4.9.8")
	var result := _archive_with(entries, entries)
	assert_false(bool(result.ok))
	assert_contains(str(result.error), "plugin.cfg version")


# ----- tree hash --------------------------------------------------------


func test_hash_tree_matches_python_parity_pin() -> void:
	var root := FIXTURE_DIR + "/parity"
	clean_fixture_dir(root)
	assert_true(write_tree(root, parity_tree()), "parity tree written")
	var result := McpReleaseVerifier.hash_tree(root)
	assert_true(bool(result.ok), str(result.error))
	assert_eq(str(result.tree_sha256), PARITY_TREE_SHA256)
	assert_eq((result.files as Dictionary).keys(), PARITY_ORDER, "files come back in bytewise path order")
	assert_eq(result.files["empty.bin"], {"size": 0, "sha256": SHA256_EMPTY})
	assert_eq(int(result.files["dir/with space.txt"]["size"]), 6)
	assert_eq(McpReleaseVerifier.tree_hash_from_files(result.files), PARITY_TREE_SHA256)
	var bare_inventory := {"inventory": []}
	for relative in parity_tree():
		bare_inventory.inventory.append(_row(PREFIX + str(relative), parity_tree()[relative]))
	assert_eq(McpReleaseVerifier.inventory_tree_hash(bare_inventory), PARITY_TREE_SHA256, "row order does not matter")


func test_hash_tree_changes_with_any_file_change() -> void:
	var root := FIXTURE_DIR + "/mutable"
	clean_fixture_dir(root)
	assert_true(write_tree(root, parity_tree()))
	var baseline := str(McpReleaseVerifier.hash_tree(root).tree_sha256)
	assert_eq(baseline, PARITY_TREE_SHA256)
	assert_true(write_fixture(root + "/a.txt", "LOWER\n".to_utf8_buffer()))
	assert_ne(str(McpReleaseVerifier.hash_tree(root).tree_sha256), baseline)
	assert_true(write_fixture(root + "/a.txt", "lower\n".to_utf8_buffer()))
	assert_eq(str(McpReleaseVerifier.hash_tree(root).tree_sha256), baseline)
	assert_true(write_fixture(root + "/dir/sub/extra.txt", PackedByteArray()))
	assert_ne(str(McpReleaseVerifier.hash_tree(root).tree_sha256), baseline)
	var missing := McpReleaseVerifier.hash_tree(FIXTURE_DIR + "/absent")
	assert_false(bool(missing.ok))
	assert_contains(str(missing.error), "does not exist")


func test_inventory_tree_hash_agrees_with_extracted_tree() -> void:
	var root := FIXTURE_DIR + "/extract"
	clean_fixture_dir(root)
	var relative := {}
	for path in _entries:
		relative[str(path).substr(PREFIX.length())] = _entries[path]
	assert_true(write_tree(root, relative))
	var expected := McpReleaseVerifier.inventory_tree_hash(_manifest())
	assert_eq(expected.length(), 64)
	assert_eq(str(McpReleaseVerifier.hash_tree(root).tree_sha256), expected)
	assert_eq(McpReleaseVerifier.inventory_tree_hash({"inventory": [_row("plugin.cfg")]}), "", "rows outside the prefix have no hash")
	assert_eq(McpReleaseVerifier.inventory_tree_hash({"inventory": "nope"}), "")
	assert_eq(McpReleaseVerifier.inventory_tree_hash({}), "")


func test_hash_tree_refuses_links() -> void:
	if OS.get_name() == "Windows":
		skip("symlink fixture is POSIX-only")
		return
	var root := FIXTURE_DIR + "/linked"
	clean_fixture_dir(root)
	assert_true(write_tree(root, {"a.txt": "a".to_utf8_buffer()}))
	var absolute := ProjectSettings.globalize_path(root)
	var directory := DirAccess.open(absolute)
	assert_true(directory != null)
	assert_eq(directory.create_link(absolute.path_join("a.txt"), absolute.path_join("linked.txt")), OK)
	var result := McpReleaseVerifier.hash_tree(root)
	assert_false(bool(result.ok), "a symlink must not be hashed as a regular file")
	assert_contains(str(result.error), "link")


func test_sha256_helpers() -> void:
	assert_eq(McpReleaseVerifier.sha256_bytes("abc".to_utf8_buffer()), SHA256_ABC)
	assert_eq(McpReleaseVerifier.sha256_bytes(PackedByteArray()), SHA256_EMPTY)
	var path := FIXTURE_DIR + "/abc.bin"
	assert_true(write_fixture(path, "abc".to_utf8_buffer()))
	var hashed := McpReleaseVerifier.sha256_file(path)
	assert_true(bool(hashed.ok), str(hashed.error))
	assert_eq(int(hashed["size"]), 3)
	assert_eq(str(hashed.sha256), SHA256_ABC)
	assert_eq(McpReleaseVerifier.plugin_cfg_version(_entries[PREFIX + "plugin.cfg"]), VERSION)
	assert_eq(McpReleaseVerifier.plugin_cfg_version("no version here".to_utf8_buffer()), "")
	assert_true(McpReleaseVerifier.is_newer_version("4.0.0", "3.99.99"))
	assert_false(McpReleaseVerifier.is_newer_version("4.0.0", "4.0.0"))
	assert_false(McpReleaseVerifier.is_newer_version("4.0.0", "v4.0.0"))
