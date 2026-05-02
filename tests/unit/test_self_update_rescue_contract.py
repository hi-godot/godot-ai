"""Regression tests for the self-update rescue mechanism (PR #281, issue #284).

Users on plugin v2.2.x / v2.3.0 have a broken `_is_safe_zip_addon_file`
guard in `update_reload_runner.gd`: it rejects every zip path that ends in
`/`. Their installed runner is what runs against the *next* release zip, so
the next zip cannot contain any zero-byte directory entries (e.g.
`addons/godot_ai/utils/`) — those would land in the safety check and abort
the install, stranding them on the broken version.

The rescue: `release.yml` builds zips with `zip -D`, which strips directory
entries. Issue #283 hardens the CI to fail if `-D` is ever dropped.

This test pins the rescue contract end-to-end:

  1. Constructs two fixture zips (with and without directory entries).
  2. Re-implements both runner shapes in Python — the *broken* pre-#281 manifest
     reader and the *fixed* current one — exercising both against both fixtures.
  3. Asserts the four-quadrant outcome: broken/with-dirs aborts, broken/no-dirs
     succeeds, fixed/either succeeds. Without that exact pattern the rescue
     wouldn't actually rescue anyone.

Source-structure pinning of `update_reload_runner.gd`'s directory-entry skip
already lives in `test_editor_focus_refocus.py::test_…manifest_skips_directory_…`;
this file owns the runtime/contract simulation, that file owns the source pin.
"""

from __future__ import annotations

import zipfile
from pathlib import Path

ZIP_ADDON_PREFIX = "addons/godot_ai/"

# Files a real release zip would carry: at minimum plugin.cfg + plugin.gd at
# the addon root (the runner errors out if either is missing) plus one nested
# file so `addons/godot_ai/utils/` is a non-trivial directory entry.
_REAL_FILES: tuple[tuple[str, bytes], ...] = (
    ("addons/godot_ai/plugin.cfg", b'[plugin]\nname="godot-ai"\n'),
    ("addons/godot_ai/plugin.gd", b"@tool\nextends EditorPlugin\n"),
    ("addons/godot_ai/utils/example.gd", b"extends RefCounted\n"),
    ("LICENSE", b"MIT\n"),
)

# Directory entries an unstripped `zip -r` (without `-D`) would emit. Note
# `addons/godot_ai/` itself is harmless to the broken runner — its rel_path
# trims to "" and is skipped on `is_empty()`. The hazard is the *deeper*
# directory entries whose rel_path is non-empty but ends in `/`.
_DIR_ENTRIES: tuple[str, ...] = (
    "addons/",
    "addons/godot_ai/",
    "addons/godot_ai/utils/",
)


def _build_fixture_zip(path: Path, *, include_directory_entries: bool) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        if include_directory_entries:
            for entry in _DIR_ENTRIES:
                zf.writestr(entry, b"")
        for name, payload in _REAL_FILES:
            zf.writestr(name, payload)


def _list_zip_entries(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as zf:
        return zf.namelist()


# ---------------------------------------------------------------------------
# Python ports of the runner's path predicates. Kept tiny and side-by-side so
# the broken-vs-fixed delta in `_read_update_manifest` is one line — the same
# delta PR #281 introduced.
# ---------------------------------------------------------------------------


def _is_safe_zip_addon_file(file_path: str) -> bool:
    """Subset of `update_reload_runner.gd::_is_safe_zip_addon_file`.

    GDScript's `is_absolute_path()` also rejects Windows drive letters and
    `res://` / `user://` schemes. Zip entries can't carry those, so this port
    only mirrors the cases reachable from a real zip namelist.
    """
    if file_path.startswith("/") or "\\" in file_path:
        return False
    if not file_path.startswith(ZIP_ADDON_PREFIX):
        return False
    rel_path = file_path[len(ZIP_ADDON_PREFIX) :]
    if not rel_path or rel_path.endswith("/"):
        return False
    for segment in rel_path.split("/"):
        if not segment or segment in (".", ".."):
            return False
    return True


def _read_manifest_broken(zip_entries: list[str]) -> bool:
    """Models the v2.2.x/v2.3.0 runner: only the rel-path-empty skip."""
    has_plugin_cfg = False
    has_plugin_script = False
    for file_path in zip_entries:
        if not file_path.startswith(ZIP_ADDON_PREFIX):
            continue
        rel_path = file_path[len(ZIP_ADDON_PREFIX) :]
        if not rel_path:
            continue
        if not _is_safe_zip_addon_file(file_path):
            return False
        if rel_path == "plugin.cfg":
            has_plugin_cfg = True
        elif rel_path == "plugin.gd":
            has_plugin_script = True
    return has_plugin_cfg and has_plugin_script


def _read_manifest_fixed(zip_entries: list[str]) -> bool:
    """Models the post-#281 runner: skips both rel-path-empty AND trailing-/."""
    has_plugin_cfg = False
    has_plugin_script = False
    for file_path in zip_entries:
        if not file_path.startswith(ZIP_ADDON_PREFIX):
            continue
        rel_path = file_path[len(ZIP_ADDON_PREFIX) :]
        if not rel_path or file_path.endswith("/"):
            continue
        if not _is_safe_zip_addon_file(file_path):
            return False
        if rel_path == "plugin.cfg":
            has_plugin_cfg = True
        elif rel_path == "plugin.gd":
            has_plugin_script = True
    return has_plugin_cfg and has_plugin_script


# ---------------------------------------------------------------------------
# Rescue contract tests
# ---------------------------------------------------------------------------


def test_fixture_with_dirs_actually_contains_directory_entries(tmp_path: Path) -> None:
    """Smoke-check the fixture builder before the contract assertions rely on it."""
    zip_path = tmp_path / "with_dirs.zip"
    _build_fixture_zip(zip_path, include_directory_entries=True)
    entries = _list_zip_entries(zip_path)
    dir_entries = [e for e in entries if e.endswith("/")]
    assert "addons/godot_ai/utils/" in dir_entries, (
        "fixture should include a deeper directory entry that exercises the "
        "broken runner's safety-check rejection (rel_path non-empty, ends with /)"
    )


def test_fixture_without_dirs_has_no_directory_entries(tmp_path: Path) -> None:
    zip_path = tmp_path / "without_dirs.zip"
    _build_fixture_zip(zip_path, include_directory_entries=False)
    entries = _list_zip_entries(zip_path)
    assert not any(e.endswith("/") for e in entries), (
        f"fixture should match the `zip -D` shape; got: {entries}"
    )


def test_broken_runner_rejects_zip_with_directory_entries(tmp_path: Path) -> None:
    """The bug that stranded v2.2.x/v2.3.0 installs."""
    zip_path = tmp_path / "with_dirs.zip"
    _build_fixture_zip(zip_path, include_directory_entries=True)

    accepted = _read_manifest_broken(_list_zip_entries(zip_path))

    assert not accepted, (
        "Broken runner must reject directory-entry zips — that's the bug that "
        "shipped in v2.2.x/v2.3.0. If this passes, the rescue is unnecessary "
        "and the test fixture is wrong."
    )


def test_broken_runner_accepts_stripped_zip(tmp_path: Path) -> None:
    """Core rescue invariant: broken installs CAN install a `zip -D` artifact."""
    zip_path = tmp_path / "without_dirs.zip"
    _build_fixture_zip(zip_path, include_directory_entries=False)

    accepted = _read_manifest_broken(_list_zip_entries(zip_path))

    assert accepted, (
        "Broken runner must accept a `zip -D`-stripped zip. If this fails, "
        "the rescue mechanism doesn't actually rescue anyone — every "
        "v2.2.x/v2.3.0 install would be permanently stuck."
    )


def test_fixed_runner_accepts_both_zip_shapes(tmp_path: Path) -> None:
    with_dirs = tmp_path / "with_dirs.zip"
    without_dirs = tmp_path / "without_dirs.zip"
    _build_fixture_zip(with_dirs, include_directory_entries=True)
    _build_fixture_zip(without_dirs, include_directory_entries=False)

    assert _read_manifest_fixed(_list_zip_entries(with_dirs))
    assert _read_manifest_fixed(_list_zip_entries(without_dirs))
