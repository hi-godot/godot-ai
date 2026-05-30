"""Behavioral test for ``script/verify-worktree`` Invariant-2 link repair.

The ``test_project/addons/godot_ai`` link is supposed to be a symlink into this
worktree's ``plugin/addons/godot_ai`` (or, on Windows, a directory junction).

Regression guarded here: on macOS/Linux a *stale real directory* at the link
path (a full copy of an old plugin, e.g. left behind by a self-update smoke
test or a botched checkout) used to satisfy the script's ``-d`` +
``plugin.gd``-exists fallback — that branch is only meant to accept genuine
Windows directory junctions, which appear as plain dirs to bash. The script
printed ``[ok]`` and exited 0 without repairing, so a developer/agent silently
tested OUTDATED plugin source. The fix gates the ``-d`` fallback to Windows
only; on POSIX a non-symlink directory is treated as broken and replaced with
the symlink.

Driven against a throwaway sandbox repo (a copy of the script + a minimal
``plugin/`` tree) so the real worktree's link is never touched. POSIX-only —
the bug and its fix are about the POSIX path; the Windows junction branch can't
be exercised from bash on this platform.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPO_ROOT / "script" / "verify-worktree"

pytestmark = pytest.mark.skipif(
    os.name == "nt",
    reason="POSIX symlink-repair path; Windows uses the junction branch.",
)


def _make_sandbox(tmp_path: Path) -> Path:
    """Build a minimal repo where verify-worktree can run self-contained.

    The script does ``cd "$(dirname "$0")/.."`` then operates on
    ``plugin/`` and ``test_project/addons/godot_ai`` relative to that root.
    """
    root = tmp_path / "sandbox"
    (root / "script").mkdir(parents=True)
    (root / "plugin" / "addons" / "godot_ai").mkdir(parents=True)
    (root / "plugin" / "addons" / "godot_ai" / "plugin.gd").write_text(
        "# canonical plugin source\n", encoding="utf-8"
    )
    (root / "test_project" / "addons").mkdir(parents=True)

    script_copy = root / "script" / "verify-worktree"
    shutil.copy2(VERIFY_SCRIPT, script_copy)
    script_copy.chmod(0o755)
    return root


def _run(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(root / "script" / "verify-worktree")],
        capture_output=True,
        text=True,
    )


def test_stale_real_dir_is_repaired_to_symlink(tmp_path: Path) -> None:
    """A stale real directory (not a symlink) must be replaced, not accepted."""
    root = _make_sandbox(tmp_path)
    link = root / "test_project" / "addons" / "godot_ai"

    # Stale real-dir copy holding OUTDATED plugin code.
    link.mkdir()
    (link / "plugin.gd").write_text("# OUTDATED stale copy\n", encoding="utf-8")

    result = _run(root)

    assert result.returncode == 0, result.stderr
    assert link.is_symlink(), "stale real dir should have been replaced with a symlink"
    assert link.resolve() == (root / "plugin" / "addons" / "godot_ai").resolve()
    # And it now resolves to the canonical (not the stale) plugin.gd.
    assert (link / "plugin.gd").read_text(encoding="utf-8") == "# canonical plugin source\n"


def test_healthy_symlink_is_left_intact(tmp_path: Path) -> None:
    """An already-correct symlink passes without being recreated."""
    root = _make_sandbox(tmp_path)
    link = root / "test_project" / "addons" / "godot_ai"
    link.symlink_to(Path("../../plugin/addons/godot_ai"))

    result = _run(root)

    assert result.returncode == 0, result.stderr
    assert "[ok]" in result.stdout
    assert link.is_symlink()
    assert link.resolve() == (root / "plugin" / "addons" / "godot_ai").resolve()


def test_missing_link_is_created(tmp_path: Path) -> None:
    """No link at all → create the symlink."""
    root = _make_sandbox(tmp_path)
    link = root / "test_project" / "addons" / "godot_ai"

    result = _run(root)

    assert result.returncode == 0, result.stderr
    assert link.is_symlink()
    assert link.resolve() == (root / "plugin" / "addons" / "godot_ai").resolve()


def test_wrong_symlink_target_is_repaired(tmp_path: Path) -> None:
    """A symlink pointing somewhere else is repaired to the canonical target."""
    root = _make_sandbox(tmp_path)
    link = root / "test_project" / "addons" / "godot_ai"
    (root / "elsewhere").mkdir()
    link.symlink_to(Path("../../elsewhere"))

    result = _run(root)

    assert result.returncode == 0, result.stderr
    assert link.is_symlink()
    assert link.resolve() == (root / "plugin" / "addons" / "godot_ai").resolve()
