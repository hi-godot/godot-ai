@tool
class_name McpUvCacheCleanup
extends RefCounted

## Sweeps stale `.tmp*` build venvs out of `%LOCALAPPDATA%\uv\cache\builds-v0`.
##
## Background
## ----------
## When Claude Desktop's MCP launcher invokes `uvx mcp-proxy ...` to talk to
## a running godot-ai server, uv builds an ephemeral venv under
## `builds-v0\.tmpXXXXXX\`. To save disk it hard-links shared C extensions
## (notably `pydantic_core/_pydantic_core.cp313-win_amd64.pyd`) from
## `archive-v0\<hash>\Lib\site-packages\...` into the build venv.
##
## If the godot-ai server's own Python child has that same `.pyd` mapped via
## `LoadLibrary` (it does — godot-ai imports pydantic), the file is locked
## under BOTH paths because hard links share the inode and Windows tracks
## handles per-file, not per-path. uv's post-install cleanup of the build
## venv then dies with:
##
##   Failed to install: pywin32-311-cp313-cp313-win_amd64.whl (pywin32==311)
##     Caused by: failed to remove directory `...\.tmpXXXXXX\Lib\site-packages\pywin32-311.data`
##                다른 프로세스가 파일을 사용 중이기 때문에 ... (os error 32)
##
## (the `pywin32` mention is incidental — the actual lock is on the earlier
## hard-linked `_pydantic_core.pyd`; pywin32 is just the last install step
## in the wheel-resolution order that triggers the cleanup pass).
##
## What this does
## --------------
## After the plugin stops/restarts the managed server — i.e. the moment when
## the archive-v0 `.pyd` mappings drop and the hard-linked builds-v0 copy
## becomes deletable — sweep `builds-v0\` for `.tmp*` orphans:
##
##   1. Rename each `.tmpXXX` to `_dead_.tmpXXX`. Rename succeeds even when
##      AV scanners hold the file open without `FILE_SHARE_DELETE` (Defender
##      and Softcamp SDS both do this), so this step always advances.
##   2. Recursively remove the renamed dir, swallowing per-file
##      access-denied. Anything still genuinely locked is left for the next
##      sweep — uv won't reuse the renamed name, so no future build collides.
##
## No-op on non-Windows (uv's hard-link strategy only causes this lock
## pattern on NTFS) and when the cache directory doesn't exist.

const DEAD_PREFIX := "_dead_"
const TMP_PREFIX := ".tmp"


## Live entrypoint. Resolves `%LOCALAPPDATA%\uv\cache\builds-v0` and runs
## the sweep. Returns the same counts the testable `purge_directory` returns,
## or all zeros on non-Windows / missing cache.
static func purge_stale_builds() -> Dictionary:
	if OS.get_name() != "Windows":
		return _empty_result()
	var local_appdata := OS.get_environment("LOCALAPPDATA")
	if local_appdata.is_empty():
		return _empty_result()
	var builds_root := local_appdata.replace("\\", "/").path_join("uv/cache/builds-v0")
	return purge_directory(builds_root)


## Pure-ish entrypoint that takes a directory path. Returns
## `{ "scanned": int, "renamed": int, "deleted": int, "remaining": int }`.
## - `scanned`: how many `.tmp*` subdirs we saw on entry.
## - `renamed`: how many we successfully renamed to `_dead_*`.
## - `deleted`: how many we then fully removed.
## - `remaining`: how many `_dead_*` dirs are still on disk after the sweep
##                (left for the next call to retry).
##
## Errors are swallowed — the caller is on a server-stop hot path and
## must not raise.
static func purge_directory(builds_root: String) -> Dictionary:
	var result := _empty_result()
	if not DirAccess.dir_exists_absolute(builds_root):
		return result
	var dir := DirAccess.open(builds_root)
	if dir == null:
		return result
	dir.include_hidden = true

	## Pass 1: collect names. Iterating + renaming in the same walk would
	## confuse DirAccess's internal cursor on NTFS.
	var tmp_names: Array[String] = []
	var dead_names: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not (entry == "." or entry == ".."):
			if entry.begins_with(TMP_PREFIX):
				tmp_names.append(entry)
			elif entry.begins_with(DEAD_PREFIX):
				dead_names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	result.scanned = tmp_names.size()

	## Pass 2: rename `.tmp*` → `_dead_.tmp*`. Rename works even on
	## AV-locked files (Defender opens without FILE_SHARE_DELETE, but rename
	## doesn't need delete share). Any rename failure is non-fatal.
	for name in tmp_names:
		var src := builds_root.path_join(name)
		var dst := builds_root.path_join(DEAD_PREFIX + name)
		if dir.rename(src, dst) == OK:
			result.renamed += 1
			dead_names.append(DEAD_PREFIX + name)

	## Pass 3: best-effort recursive delete of every `_dead_*`, including
	## ones left over from earlier sweeps that couldn't be cleaned then.
	for name in dead_names:
		var path := builds_root.path_join(name)
		if _remove_recursive(path):
			result.deleted += 1

	## Final pass: count `_dead_*` survivors so the caller (and tests) can
	## see how many genuinely-locked dirs we couldn't reach.
	var dir2 := DirAccess.open(builds_root)
	if dir2 != null:
		dir2.include_hidden = true
		dir2.list_dir_begin()
		var e := dir2.get_next()
		while e != "":
			if dir2.current_is_dir() and e.begins_with(DEAD_PREFIX):
				result.remaining += 1
			e = dir2.get_next()
		dir2.list_dir_end()

	return result


## Recursive `rm -rf` that swallows access-denied per-file. Returns true
## only when the target directory itself was removed.
static func _remove_recursive(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		## Already gone, or unreadable — try a direct remove just in case
		## (an empty dir handle-leak path) and report based on existence.
		DirAccess.remove_absolute(path)
		return not DirAccess.dir_exists_absolute(path)
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	## Remove the (hopefully now empty) dir itself. If a hard-linked .pyd is
	## still mapped by a surviving process, this fails silently and the
	## caller sees `remaining > 0` so it can retry on the next sweep.
	DirAccess.remove_absolute(path)
	return not DirAccess.dir_exists_absolute(path)


static func _empty_result() -> Dictionary:
	return { "scanned": 0, "renamed": 0, "deleted": 0, "remaining": 0 }
