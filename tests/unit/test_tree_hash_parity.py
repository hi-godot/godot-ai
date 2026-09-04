"""Parity contract for the tree hash shared with update_installer.gd.

The fixture tree and its digest are fixed so the GDScript side can assert the
very same value. The definition, in full: walk every regular file beneath the
root; take each file's path relative to the root in POSIX form; sort those
paths by the byte order of their UTF-8 encoding; for each file append the line
sha256_hex + " " + str(size) + " " + path + "\\n"; tree_sha256 is the
hex SHA-256 of the concatenated lines. A change to any part of that must change
EXPECTED_TREE_SHA256 here and in the GDScript test together.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

import pytest

from godot_ai import release_verify as verify

# Deliberately unsorted, with the ordering traps a directory-first or
# locale-aware walk gets wrong: "Z" before "a" (uppercase first), "dir.txt"
# before "dir/..." ('.' is 0x2E, '/' is 0x2F), "zz" before "é" (0x7A before
# 0xC3), a name with a space, a nested directory, and an empty file.
TREE: tuple[tuple[str, bytes], ...] = (
    ("plugin.cfg", b'[plugin]\nversion="4.0.0"\n'),
    ("dir/b.gd", b"extends Node\n"),
    ("dir/sub/deep.txt", b"deep\n"),
    ("dir.txt", b"not a directory\n"),
    ("Z.txt", b"upper\n"),
    ("a.txt", b"lower\n"),
    ("zz.txt", b"ascii last\n"),
    ("\u00e9.txt", "accent \u00e9\n".encode("utf-8")),
    ("dir/with space.txt", b"space\n"),
    ("empty.bin", b""),
)
EXPECTED_ORDER = [
    "Z.txt",
    "a.txt",
    "dir.txt",
    "dir/b.gd",
    "dir/sub/deep.txt",
    "dir/with space.txt",
    "empty.bin",
    "plugin.cfg",
    "zz.txt",
    "\u00e9.txt",
]
EXPECTED_TREE_SHA256 = "36b71557e16593f40192617dbf023f8c52043948e137b159030bdeaedfdac055"


def _write_tree(root: Path) -> Path:
    for path, data in TREE:
        target = root.joinpath(*path.split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return root


def _by_hand(files: tuple[tuple[str, bytes], ...]) -> str:
    """The documented formula, written out independently of hash_tree."""
    lines = ""
    for path, data in sorted(files, key=lambda item: item[0].encode("utf-8")):
        lines += hashlib.sha256(data).hexdigest() + " " + str(len(data)) + " " + path + "\n"
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


def _manifest(files: tuple[tuple[str, bytes], ...]) -> dict:
    rows = [
        {
            "path": verify.PLUGIN_PREFIX + path,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        for path, data in files
    ]
    rows.sort(key=lambda row: row["path"].encode("utf-8"))
    return {"inventory": rows}


def test_hash_tree_matches_the_documented_formula_and_the_pinned_digest(tmp_path):
    result = verify.hash_tree(_write_tree(tmp_path / "tree"))

    assert _by_hand(TREE) == EXPECTED_TREE_SHA256
    assert result["tree_sha256"] == EXPECTED_TREE_SHA256
    assert list(result["files"]) == EXPECTED_ORDER
    assert result["files"] == {
        path: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()} for path, data in TREE
    }
    assert result["files"]["empty.bin"] == {"size": 0, "sha256": hashlib.sha256(b"").hexdigest()}


def test_inventory_tree_hash_equals_hash_tree_of_the_installed_tree(tmp_path):
    root = _write_tree(tmp_path / "tree")

    assert verify.inventory_tree_hash(_manifest(TREE)) == verify.hash_tree(root)["tree_sha256"]
    assert verify.inventory_tree_hash(_manifest(TREE)) == EXPECTED_TREE_SHA256


def test_inventory_tree_hash_ignores_row_order_but_not_content():
    manifest = _manifest(TREE)
    shuffled = {"inventory": list(reversed(manifest["inventory"]))}
    assert verify.inventory_tree_hash(shuffled) == EXPECTED_TREE_SHA256

    renamed = _manifest((*TREE[:-1], ("empty.txt", b"")))
    assert verify.inventory_tree_hash(renamed) != EXPECTED_TREE_SHA256
    resized = _manifest((*TREE[:-1], ("empty.bin", b"x")))
    assert verify.inventory_tree_hash(resized) != EXPECTED_TREE_SHA256


def test_tree_hash_changes_with_any_file_change(tmp_path):
    root = _write_tree(tmp_path / "tree")
    baseline = verify.hash_tree(root)["tree_sha256"]

    (root / "a.txt").write_bytes(b"LOWER\n")
    assert verify.hash_tree(root)["tree_sha256"] != baseline
    (root / "a.txt").write_bytes(b"lower\n")
    assert verify.hash_tree(root)["tree_sha256"] == baseline
    (root / "dir/sub/extra.txt").write_bytes(b"")
    assert verify.hash_tree(root)["tree_sha256"] != baseline


@pytest.mark.parametrize("prefix", ["", "addons/other/"])
def test_inventory_tree_hash_rejects_rows_outside_the_plugin_prefix(prefix):
    manifest = {"inventory": [{"path": f"{prefix}plugin.cfg", "size": 1, "sha256": "0" * 64}]}
    with pytest.raises(verify.ReleaseError, match="beneath addons/godot_ai/"):
        verify.inventory_tree_hash(manifest)
    with pytest.raises(verify.ReleaseError, match="expected array"):
        verify.inventory_tree_hash({"inventory": "nope"})


@pytest.mark.skipif(os.name == "nt", reason="symlink fixture")
def test_hash_tree_refuses_links_instead_of_skipping_them(tmp_path):
    root = _write_tree(tmp_path / "tree")
    (root / "linked.txt").symlink_to(root / "a.txt")
    with pytest.raises(verify.ReleaseError, match="non-regular file or link"):
        verify.hash_tree(root)
    (root / "linked.txt").unlink()
    (root / "linked_dir").symlink_to(root / "dir")
    with pytest.raises(verify.ReleaseError, match="non-directory or link"):
        verify.hash_tree(root)


def test_hash_tree_reports_a_missing_root(tmp_path):
    with pytest.raises(verify.ReleaseError, match="tree "):
        verify.hash_tree(tmp_path / "absent")
