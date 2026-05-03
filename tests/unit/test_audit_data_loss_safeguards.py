"""Source-structure pins for the audit-roadmap data-loss safeguards (PR 2 / issue #297).

Two P0 data-loss bugs were fixed in this PR:

  - **Finding #9**: `update_reload_runner.gd::_install_zip_paths` now tracks
    every file it writes and rolls back via `.update_backup` snapshots when a
    later write/rename fails. The runner refuses to re-enable the plugin if
    the rollback itself fails (mixed vN/vN+1 tree on disk).
  - **Finding #10**: `clients/_atomic_write.gd` no longer removes the user's
    existing config before retrying the rename. The Windows AV / lock
    fallback is overwrite-copy with size verification, with restore-from-
    backup on failure. The original is never deleted before the new bytes
    are confirmed on disk.

Runtime behavior is covered by GDScript suites
(`test_update_reload_runner.gd`, plus the new tests in `test_clients.gd`).
This file pins the *structural* invariants that protect the fix from being
silently undone by a future refactor — the same dual-coverage discipline
used for the existing self-update rescue (#283 / #284 in
`test_self_update_rescue_contract.py`).
"""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
RUNNER_PATH = PLUGIN_ROOT / "update_reload_runner.gd"
ATOMIC_WRITE_PATH = PLUGIN_ROOT / "clients" / "_atomic_write.gd"


# ---------------------------------------------------------------------------
# Finding #9: partial-extract rollback in update_reload_runner.gd
# ---------------------------------------------------------------------------


def test_runner_declares_install_status_enum() -> None:
    source = RUNNER_PATH.read_text()
    assert "enum InstallStatus { OK, FAILED_CLEAN, FAILED_MIXED }" in source, (
        "Three-state install outcome is the contract callers depend on. "
        "FAILED_CLEAN means rollback restored the prior state; FAILED_MIXED "
        "means the addons tree is half-vN / half-vN+1 and the plugin must "
        "NOT be re-enabled. Collapsing this to a bool reintroduces the "
        "data-loss path from issue #297 finding #9."
    )


def test_runner_tracks_paths_written_for_cross_batch_rollback() -> None:
    source = RUNNER_PATH.read_text()
    assert "var _paths_written = []" in source, (
        "Per-file install records must accumulate across both `_new_file_paths` "
        "and `_existing_file_paths` batches so a failure in the second batch "
        "rolls back the first batch too. Untyped per the typed-storage hot-"
        "reload hazard pinned in test_self_update_runner_does_not_introduce_"
        "typed_variant_storage_hazards."
    )
    assert "const INSTALL_BACKUP_SUFFIX" in source


def test_install_zip_paths_returns_install_status_and_drives_rollback() -> None:
    source = RUNNER_PATH.read_text()
    paths_block = get_func_block(source, "func _install_zip_paths(")
    assert "-> int:" in source[: source.index(paths_block) + len(paths_block)]
    assert "InstallStatus.OK" in paths_block, (
        "Function must signal success via the typed enum, not bare `true`."
    )
    assert "_rollback_paths_written()" in paths_block, (
        "On any per-file failure the function must invoke the rollback path "
        "rather than returning false and letting the caller re-enable the "
        "plugin against a half-installed tree."
    )
    assert "_paths_written.append(record)" in paths_block, (
        "Successful per-file installs must be recorded so a later failure "
        "(in this batch OR a subsequent batch) can roll them back."
    )


def test_install_zip_file_returns_dictionary_record_with_backup_metadata() -> None:
    source = RUNNER_PATH.read_text()
    install_block = get_func_block(source, "func _install_zip_file(")
    assert "-> Dictionary:" in source[: source.index(install_block) + len(install_block)]
    # Backup is taken via COPY (not rename) so the original stays in place
    # if the swap that follows fails. Pin the COPY semantics specifically.
    assert "DirAccess.copy_absolute(target_path, backup_path)" in install_block, (
        "Backup the existing target via copy_absolute so the source-of-truth "
        "stays in place. Renaming the original out of the way before writing "
        "the new file reintroduces the same data-loss window the atomic-write "
        "fix addresses."
    )
    assert "had_original" in install_block
    assert "INSTALL_BACKUP_SUFFIX" in install_block


def test_install_zip_file_does_not_remove_target_before_rename_attempt() -> None:
    source = RUNNER_PATH.read_text()
    install_block = get_func_block(source, "func _install_zip_file(")
    # The first rename attempt must precede any DirAccess.remove_absolute(target_path).
    # The remove-then-rename pattern only appears INSIDE the
    # rename-rejected fallback, never as the primary path.
    first_rename = install_block.find("DirAccess.rename_absolute(temp_path, target_path)")
    first_remove_target = install_block.find("DirAccess.remove_absolute(target_path)")
    assert first_rename != -1, "primary rename swap must remain in place"
    assert first_remove_target != -1, "fallback remove still exists for non-atomic FS"
    assert first_rename < first_remove_target, (
        "The original target must NOT be removed before the first "
        "rename attempt — that's the bug pattern from the atomic-write side "
        "of issue #297. If the rename fails AND we already removed the "
        "target, we've destroyed the prior content with no recovery."
    )


def test_rollback_returns_failed_mixed_when_any_restore_fails() -> None:
    source = RUNNER_PATH.read_text()
    rollback_block = get_func_block(source, "func _rollback_paths_written(")
    assert "-> int:" in source[: source.index(rollback_block) + len(rollback_block)]
    assert "InstallStatus.FAILED_MIXED" in rollback_block, (
        "Rollback must surface FAILED_MIXED when a restore step fails so "
        "the caller knows not to re-enable the plugin against a mixed tree."
    )
    assert "InstallStatus.FAILED_CLEAN" in rollback_block
    assert "DirAccess.copy_absolute(backup, target)" in rollback_block, (
        "Restore from the .update_backup snapshot via copy. Rename would "
        "lose the backup if the restore needs to be re-attempted."
    )
    # Iterate newest-first so multi-record paths land at the true original.
    assert "_paths_written.size() - 1" in rollback_block
    assert "i -= 1" in rollback_block


def test_handle_install_failure_refuses_to_reenable_on_mixed_state() -> None:
    source = RUNNER_PATH.read_text()
    handler_block = get_func_block(source, "func _handle_install_failure(")
    assert "InstallStatus.FAILED_MIXED" in handler_block
    # The MIXED branch must NOT call set_plugin_enabled(true). The caller
    # of _handle_install_failure relies on this gate to avoid loading a
    # half-vN / half-vN+1 addons tree.
    mixed_idx = handler_block.find("InstallStatus.FAILED_MIXED")
    return_idx = handler_block.find("return", mixed_idx)
    assert mixed_idx != -1 and return_idx != -1
    mixed_branch = handler_block[mixed_idx:return_idx]
    assert "set_plugin_enabled(PLUGIN_CFG_PATH, true)" not in mixed_branch, (
        "Re-enabling the plugin in the MIXED state would load a half-vN / "
        "half-vN+1 addons tree — the exact data-loss scenario this PR fixes."
    )
    # FAILED_CLEAN path DOES re-enable (rollback succeeded; vN is intact).
    assert "set_plugin_enabled(PLUGIN_CFG_PATH, true)" in handler_block


def test_extract_and_scan_routes_failure_through_handle_install_failure() -> None:
    source = RUNNER_PATH.read_text()
    extract_block = get_func_block(source, "func _extract_and_scan() -> void:")
    assert "_install_zip_paths(_new_file_paths)" in extract_block
    assert "_handle_install_failure(status)" in extract_block, (
        "Failure path must go through the FAILED_MIXED-aware helper rather "
        "than unconditionally re-enabling the plugin."
    )
    existing_block = get_func_block(source, "func _install_existing_files_and_scan() -> void:")
    assert "_install_zip_paths(_existing_file_paths)" in existing_block
    assert "_handle_install_failure(status)" in existing_block
    assert "_finalize_install_success()" in existing_block, (
        "After both batches succeed, finalize must clean up backup snapshots "
        "so they don't accumulate as stale artifacts under addons/godot_ai/."
    )


# ---------------------------------------------------------------------------
# Finding #10: atomic write fallback in clients/_atomic_write.gd
# ---------------------------------------------------------------------------


def test_atomic_write_does_not_remove_target_before_swap() -> None:
    """The bug pattern: remove(path) then retry rename. Must not return."""

    source = ATOMIC_WRITE_PATH.read_text()
    write_block = get_func_block(source, "static func write(")
    # The dangerous sequence was: rename failed -> remove(path) -> rename retry.
    # In the new code, remove(path) only happens AFTER a successful copy
    # verification (cleanup of tmp), or as part of the restore-from-backup
    # path. It must NOT precede a rename retry.
    assert "DirAccess.remove_absolute(path)" in write_block, (
        "remove(path) is still used in the restore-from-backup recovery — "
        "if this assertion fires because the call moved away, double-check "
        "the recovery path still leaves the original on disk."
    )
    # Pin: the function must not contain the legacy remove+rename pattern.
    legacy_pattern = (
        "DirAccess.remove_absolute(path)\n\t\tif DirAccess.rename_absolute(tmp_path, path) != OK:"
    )
    assert legacy_pattern not in write_block, (
        "The remove-then-rename retry destroys the user's MCP config when "
        "the second rename also fails (Windows AV / lock timing). Issue "
        "#297 finding #10. Use overwrite-copy with size verification "
        "instead — copy_absolute never removes the original before writing."
    )


def test_atomic_write_uses_copy_then_verify_as_rename_fallback() -> None:
    source = ATOMIC_WRITE_PATH.read_text()
    write_block = get_func_block(source, "static func write(")
    assert "DirAccess.copy_absolute(tmp_path, path)" in write_block, (
        "Overwrite-copy is the safe fallback when rename-over-existing is "
        "rejected: copy_absolute never removes the original before writing "
        "the new bytes, so a failed copy still leaves the user's prior "
        "config in place."
    )
    assert "_written_size_matches(path, content)" in write_block, (
        "Copy must be paired with a content/size verification — without it "
        "we'd treat a partial copy as a successful write."
    )


def test_atomic_write_restores_from_backup_when_swap_fails() -> None:
    source = ATOMIC_WRITE_PATH.read_text()
    write_block = get_func_block(source, "static func write(")
    assert "DirAccess.copy_absolute(path, backup_path)" in write_block, (
        "Snapshot the prior file via copy_absolute BEFORE attempting the "
        "swap so a failed copy can be undone."
    )
    assert "DirAccess.copy_absolute(backup_path, path)" in write_block, (
        "On failed swap the prior bytes must be restored from the .backup "
        "snapshot. Without this restore step, a partially-written copy can "
        "leave the user's config in a half-state."
    )


def test_atomic_write_size_verification_uses_utf8_byte_count() -> None:
    """`store_string` writes UTF-8 bytes — verify against to_utf8_buffer().size()."""
    source = ATOMIC_WRITE_PATH.read_text()
    verify_block = get_func_block(source, "static func _written_size_matches(")
    assert "content.to_utf8_buffer().size()" in verify_block, (
        "String.length() returns char count which diverges from the byte "
        "count for any non-ASCII content — MCP config keys/values can carry "
        "Unicode (paths with accented characters, server names). Comparing "
        "char count to file byte length would let a multi-byte truncation "
        "slip through verification."
    )
    assert "f.get_length()" in verify_block


def test_atomic_write_clears_partial_new_file_when_no_original_existed() -> None:
    """Copilot review (#299): without this branch, a verify-only failure on a
    first-time write left half-written bytes at `path`. The contract is now
    "destination is in its pre-call state on failure" — for a brand-new path
    that means nothing should be on disk after the function returns false."""

    source = ATOMIC_WRITE_PATH.read_text()
    write_block = get_func_block(source, "static func write(")
    assert "elif not had_original and FileAccess.file_exists(path):" in write_block, (
        "Failure path must clear partial bytes when no original existed. "
        "The `file_exists` guard keeps the cleanup off non-file destinations "
        "so a path that points at a directory (had_original is false there "
        "too) can't be accidentally targeted by remove_absolute."
    )
    # The `elif` branch must remove the partial bytes via remove_absolute(path).
    elif_idx = write_block.find("elif not had_original")
    return_false_idx = write_block.find("return false", elif_idx)
    elif_branch = write_block[elif_idx:return_false_idx]
    assert "DirAccess.remove_absolute(path)" in elif_branch, (
        "The no-original failure branch must delete the partial file from "
        "disk, otherwise a verify-only failure leaves a truncated config "
        "behind on first-time writes."
    )
