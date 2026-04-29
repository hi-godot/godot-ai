@tool
extends McpTestSuite

## Tests for `McpUvCacheCleanup`. The live entrypoint reads
## `%LOCALAPPDATA%` and only does anything on Windows, so these tests
## go through `purge_directory(path)` and operate on a scratch directory
## under `user://`. That keeps them OS-agnostic in CI — the rename +
## recursive-remove logic is the same on every platform; the live
## entrypoint just gates on `OS.get_name() == "Windows"` because the
## hard-link lock pattern this defends against is NTFS-specific.

const Cleanup := preload("res://addons/godot_ai/utils/uv_cache_cleanup.gd")

var _scratch_root: String


func suite_name() -> String:
	return "uv_cache_cleanup"


func setup() -> void:
	## Fresh scratch dir per test, so a half-cleaned previous run can't
	## leak `_dead_*` survivors into the next test's `remaining` count.
	_scratch_root = "user://test_uv_cache_cleanup_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(_scratch_root)


func teardown() -> void:
	if not _scratch_root.is_empty():
		Cleanup._remove_recursive(_scratch_root)
	_scratch_root = ""


# ----- helpers -----

func _make_tmp_dir(name: String, file_count: int = 2) -> String:
	var path := _scratch_root.path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	for i in file_count:
		var f := FileAccess.open(path.path_join("file_%d.txt" % i), FileAccess.WRITE)
		if f != null:
			f.store_string("payload %d" % i)
			f.close()
	## Simulate uv's nested wheel layout that the bug report mentioned —
	## `Lib\site-packages\<pkg>\...` — to make sure the recursive remove
	## walks deeper than one level.
	var nested := path.path_join("Lib/site-packages/pydantic_core")
	DirAccess.make_dir_recursive_absolute(nested)
	var pyd := FileAccess.open(nested.path_join("_pydantic_core.cp313-win_amd64.pyd"), FileAccess.WRITE)
	if pyd != null:
		pyd.store_string("fake binary")
		pyd.close()
	return path


# ----- behavior -----

func test_no_op_when_directory_missing() -> void:
	var result := Cleanup.purge_directory(_scratch_root.path_join("does_not_exist"))
	assert_eq(result.scanned, 0)
	assert_eq(result.renamed, 0)
	assert_eq(result.deleted, 0)
	assert_eq(result.remaining, 0)


func test_no_op_when_directory_empty() -> void:
	var result := Cleanup.purge_directory(_scratch_root)
	assert_eq(result.scanned, 0)
	assert_eq(result.renamed, 0)
	assert_eq(result.deleted, 0)


func test_renames_and_deletes_tmp_dirs() -> void:
	_make_tmp_dir(".tmp4DPYIo")
	_make_tmp_dir(".tmp70KGqX")
	## A non-tmp sibling must be ignored — the live cache has things like
	## `archive-v0/` and `wheels-v0/` next to `builds-v0/` and the sweep
	## must never touch dirs without the `.tmp` prefix.
	DirAccess.make_dir_recursive_absolute(_scratch_root.path_join("archive-v0"))

	var result := Cleanup.purge_directory(_scratch_root)

	assert_eq(result.scanned, 2, "should see both .tmp dirs")
	assert_eq(result.renamed, 2, "both rename to _dead_*")
	assert_eq(result.deleted, 2, "both fully delete")
	assert_eq(result.remaining, 0, "nothing left behind")
	assert_true(
		DirAccess.dir_exists_absolute(_scratch_root.path_join("archive-v0")),
		"sibling non-tmp dir must survive"
	)
	assert_false(DirAccess.dir_exists_absolute(_scratch_root.path_join(".tmp4DPYIo")))
	assert_false(DirAccess.dir_exists_absolute(_scratch_root.path_join("_dead_.tmp4DPYIo")))


func test_picks_up_dead_dirs_from_previous_sweep() -> void:
	## A previous sweep renamed but couldn't delete (e.g. AV scanner held
	## the .pyd). Next call must finish the job — both initially-stale
	## `_dead_*` dirs and freshly-renamed ones get the delete pass.
	var leftover := _scratch_root.path_join("_dead_.tmpOLD")
	DirAccess.make_dir_recursive_absolute(leftover)
	var f := FileAccess.open(leftover.path_join("stub.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("x")
		f.close()
	_make_tmp_dir(".tmpNEW")

	var result := Cleanup.purge_directory(_scratch_root)

	assert_eq(result.scanned, 1, "only the .tmp* row counts as scanned")
	assert_eq(result.renamed, 1, "the new .tmpNEW")
	assert_eq(result.deleted, 2, "leftover + freshly-renamed both deleted")
	assert_eq(result.remaining, 0)
	assert_false(DirAccess.dir_exists_absolute(leftover))


func test_ignores_files_named_like_tmp() -> void:
	## DirAccess walks files alongside dirs; the sweep only ever touches
	## directories. A stray file named ".tmpfoo" must not be renamed.
	var stray := _scratch_root.path_join(".tmpfoo")
	var f := FileAccess.open(stray, FileAccess.WRITE)
	if f != null:
		f.store_string("not a dir")
		f.close()

	var result := Cleanup.purge_directory(_scratch_root)
	assert_eq(result.scanned, 0)
	assert_eq(result.renamed, 0)
	assert_true(FileAccess.file_exists(stray), "stray .tmp* file must survive")


func test_purge_stale_builds_is_no_op_on_non_windows() -> void:
	## Live entrypoint short-circuits off-Windows so CI on Linux/macOS
	## doesn't accidentally walk `~/.local/share/uv/...` (which uv doesn't
	## use on POSIX anyway, but the contract is explicit).
	if OS.get_name() == "Windows":
		skip("windows-only path; OS-agnostic logic exercised via purge_directory")
		return
	var result := Cleanup.purge_stale_builds()
	assert_eq(result.scanned, 0)
	assert_eq(result.remaining, 0)
