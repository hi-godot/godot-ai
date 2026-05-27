"""Unit tests for `tests/integration/_self_update_fixture.py::extract_addon_from_zip`.

The helper extracts release-zip entries into a fixture directory before the
integration tests in `tests/integration/test_self_update_*.py` exercise the
update flow. The runtime installer (`update_reload_runner.gd`) rejects unsafe
zip entries via `_is_safe_zip_addon_file()`; this helper mirrors that
defense in Python so a crafted/corrupt release zip can't escape the fixture
sandbox on developer machines or CI runners.
"""

from __future__ import annotations

import zipfile
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import extract_addon_from_zip


def _write_zip(path: Path, members: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in members.items():
            zf.writestr(name, data)


def _write_zip_with_raw_member_name(
    path: Path,
    normalized_name: str,
    raw_name: str,
    data: bytes,
) -> None:
    assert len(normalized_name) == len(raw_name)
    _write_zip(
        path,
        {
            "addons/godot_ai/plugin.cfg": b"[plugin]\nname=ok\n",
            normalized_name: data,
        },
    )
    normalized_name_bytes = normalized_name.encode("ascii")
    raw_name_bytes = raw_name.encode("ascii")
    original_bytes = path.read_bytes()
    mutated_bytes = original_bytes.replace(normalized_name_bytes, raw_name_bytes)

    assert mutated_bytes != original_bytes, (
        "failed to inject raw ZIP member name: normalized member name bytes were "
        "not found in archive"
    )
    assert raw_name_bytes in mutated_bytes, (
        "failed to inject raw ZIP member name: mutated archive does not contain "
        "the expected raw member name bytes"
    )
    assert normalized_name_bytes not in mutated_bytes, (
        "failed to inject raw ZIP member name: archive still contains the "
        "normalized member name bytes after mutation"
    )

    path.write_bytes(mutated_bytes)


def test_clean_zip_extracts_files_to_target(tmp_path: Path) -> None:
    zip_path = tmp_path / "good.zip"
    _write_zip(
        zip_path,
        {
            "addons/godot_ai/plugin.cfg": b"[plugin]\nname=ok\n",
            "addons/godot_ai/sub/file.gd": b"pass",
        },
    )
    target = tmp_path / "target"
    extract_addon_from_zip(zip_path, target)
    assert (target / "plugin.cfg").read_bytes().startswith(b"[plugin]")
    assert (target / "sub" / "file.gd").read_bytes() == b"pass"


def test_parent_traversal_entry_is_rejected(tmp_path: Path) -> None:
    zip_path = tmp_path / "bad.zip"
    _write_zip(
        zip_path,
        {
            "addons/godot_ai/plugin.cfg": b"[plugin]\nname=ok\n",
            "addons/godot_ai/../../escape.txt": b"escape",
        },
    )
    with pytest.raises(ValueError, match="absolute or traversal segments"):
        extract_addon_from_zip(zip_path, tmp_path / "target")


def test_backslash_in_entry_name_is_rejected(tmp_path: Path) -> None:
    zip_path = tmp_path / "bad.zip"
    _write_zip_with_raw_member_name(
        zip_path,
        "addons/godot_ai/sub/windows-style.gd",
        "addons/godot_ai/sub\\windows-style.gd",
        b"oops",
    )
    with pytest.raises(ValueError, match="contains backslash"):
        extract_addon_from_zip(zip_path, tmp_path / "target")


def test_directory_entries_are_skipped(tmp_path: Path) -> None:
    zip_path = tmp_path / "dirs.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("addons/godot_ai/sub/", b"")
        zf.writestr("addons/godot_ai/plugin.cfg", b"[plugin]\nname=ok\n")
    target = tmp_path / "target"
    extract_addon_from_zip(zip_path, target)
    assert (target / "plugin.cfg").is_file()
    assert not (target / "sub").exists()


def test_entries_outside_addon_prefix_are_skipped(tmp_path: Path) -> None:
    zip_path = tmp_path / "mixed.zip"
    _write_zip(
        zip_path,
        {
            "addons/godot_ai/plugin.cfg": b"[plugin]\nname=ok\n",
            "README.md": b"not an addon file",
            "other/thing.txt": b"also not",
        },
    )
    target = tmp_path / "target"
    extract_addon_from_zip(zip_path, target)
    assert sorted(p.name for p in target.iterdir()) == ["plugin.cfg"]
