"""Windows regression tests for the test_project plugin junction policy (#935).

``script/_plugin_junction.ps1`` is the single Windows implementation behind
``script/setup-dev.ps1`` and the Windows branch of ``script/verify-worktree``.
The data-loss rule it enforces: a *real* directory at the link path is never
deleted (it may hold uncommitted plugin edits) — it is moved to a timestamped
``.stale.*`` sibling — and only a verified reparse point is removed, via
``rmdir`` so the target is never recursed into.

Driven against a throwaway sandbox (copies of the scripts plus a minimal
``plugin/`` tree) so the real worktree link is never touched. Junctions need no
admin rights or Developer Mode, so these run on any Windows checkout.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
JUNCTION_SCRIPT = REPO_ROOT / "script" / "_plugin_junction.ps1"
VERIFY_SCRIPT = REPO_ROOT / "script" / "verify-worktree"

pytestmark = pytest.mark.skipif(os.name != "nt", reason="Windows junction policy")

CANONICAL = "# canonical plugin source\n"


def _make_sandbox(tmp_path: Path) -> Path:
    root = tmp_path / "sandbox"
    (root / "script").mkdir(parents=True)
    plugin = root / "plugin" / "addons" / "godot_ai"
    plugin.mkdir(parents=True)
    (plugin / "plugin.gd").write_text(CANONICAL, encoding="utf-8")
    (root / "test_project" / "addons").mkdir(parents=True)
    shutil.copy2(JUNCTION_SCRIPT, root / "script" / "_plugin_junction.ps1")
    shutil.copy2(VERIFY_SCRIPT, root / "script" / "verify-worktree")
    return root


def _link(root: Path) -> Path:
    return root / "test_project" / "addons" / "godot_ai"


def _target(root: Path) -> Path:
    return root / "plugin" / "addons" / "godot_ai"


def _mklink(link: Path, target: Path) -> None:
    subprocess.run(
        ["cmd", "/c", "mklink", "/J", str(link), str(target)],
        check=True,
        capture_output=True,
    )


def _is_reparse(path: Path) -> bool:
    return bool(os.lstat(path).st_file_attributes & 0x400)  # FILE_ATTRIBUTE_REPARSE_POINT


def _run_ps(root: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(root / "script" / "_plugin_junction.ps1"),
            "-LinkPath",
            str(_link(root)),
            "-TargetPath",
            str(_target(root)),
            *extra,
        ],
        capture_output=True,
        text=True,
    )


def _git_bash() -> str:
    """Git Bash, not the WSL launcher that Windows also installs as bash.exe."""
    candidates = []
    git = shutil.which("git")
    if git:
        candidates.append(Path(git).resolve().parent.parent / "bin" / "bash.exe")
    for env in ("ProgramFiles", "ProgramFiles(x86)", "LocalAppData"):
        base = os.environ.get(env)
        if base:
            candidates.append(Path(base) / "Git" / "bin" / "bash.exe")
            candidates.append(Path(base) / "Programs" / "Git" / "bin" / "bash.exe")
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    pytest.skip("Git Bash not found; the verify-worktree entrypoint needs it")


def _run_verify(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [_git_bash(), str(root / "script" / "verify-worktree")],
        capture_output=True,
        text=True,
        cwd=root,
    )


def _stale_dirs(root: Path) -> list[Path]:
    return sorted((root / "test_project" / "addons").glob("godot_ai.stale.*"))


def _assert_healthy(root: Path) -> None:
    link = _link(root)
    assert link.is_dir()
    assert _is_reparse(link), "link must be a junction"
    assert (link / "plugin.gd").read_text(encoding="utf-8") == CANONICAL


def test_correct_junction_is_accepted_untouched(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    _mklink(_link(root), _target(root))
    before = os.lstat(_link(root)).st_ctime_ns

    result = _run_ps(root)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "[ok]" in result.stdout
    assert os.lstat(_link(root)).st_ctime_ns == before, "healthy junction must not be recreated"
    assert _stale_dirs(root) == []
    _assert_healthy(root)


def test_wrong_target_junction_is_repaired_without_touching_other_dir(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    elsewhere = root / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "keep.txt").write_text("precious\n", encoding="utf-8")
    _mklink(_link(root), elsewhere)

    result = _run_ps(root)

    assert result.returncode == 0, result.stdout + result.stderr
    _assert_healthy(root)
    assert (elsewhere / "keep.txt").read_text(encoding="utf-8") == "precious\n"
    assert _stale_dirs(root) == [], "a junction is removed, never moved aside"


def test_real_dir_with_edits_is_moved_aside_not_deleted(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    link = _link(root)
    link.mkdir()
    (link / "plugin.gd").write_text("# OUTDATED copy with uncommitted work\n", encoding="utf-8")
    (link / "handlers").mkdir()
    (link / "handlers" / "mine.gd").write_text("# my edits\n", encoding="utf-8")

    result = _run_ps(root)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "moved to" in result.stdout
    _assert_healthy(root)
    stale = _stale_dirs(root)
    assert len(stale) == 1
    assert (stale[0] / "handlers" / "mine.gd").read_text(encoding="utf-8") == "# my edits\n"


def test_real_dir_without_plugin_gd_is_moved_aside(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    link = _link(root)
    link.mkdir()
    (link / "notes.txt").write_text("not a plugin, still not yours to delete\n", encoding="utf-8")

    result = _run_ps(root)

    assert result.returncode == 0, result.stdout + result.stderr
    _assert_healthy(root)
    stale = _stale_dirs(root)
    assert len(stale) == 1
    assert (stale[0] / "notes.txt").exists()


def test_dangling_junction_is_repaired(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    gone = root / "gone"
    gone.mkdir()
    _mklink(_link(root), gone)
    gone.rmdir()

    result = _run_ps(root)

    assert result.returncode == 0, result.stdout + result.stderr
    _assert_healthy(root)
    assert _stale_dirs(root) == []


def test_missing_link_is_created(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)

    result = _run_ps(root)

    assert result.returncode == 0, result.stdout + result.stderr
    _assert_healthy(root)


def test_check_only_reports_without_mutating(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    link = _link(root)
    link.mkdir()
    (link / "plugin.gd").write_text("# OUTDATED\n", encoding="utf-8")

    result = _run_ps(root, "-CheckOnly")

    assert result.returncode == 3
    assert not _is_reparse(link)
    assert (link / "plugin.gd").read_text(encoding="utf-8") == "# OUTDATED\n"
    assert _stale_dirs(root) == []


def test_verify_worktree_delegates_real_dir_to_move_aside(tmp_path: Path) -> None:
    """The bash entrypoint must reach the same policy: no rm -rf of a real dir."""
    root = _make_sandbox(tmp_path)
    link = _link(root)
    link.mkdir()
    (link / "plugin.gd").write_text("# OUTDATED stale copy\n", encoding="utf-8")

    result = _run_verify(root)

    assert result.returncode == 0, result.stdout + result.stderr
    _assert_healthy(root)
    assert len(_stale_dirs(root)) == 1


def test_verify_worktree_rejects_real_dir_that_merely_has_plugin_gd(tmp_path: Path) -> None:
    """Regression: plugin.gd presence alone used to pass as 'junction-shaped'."""
    root = _make_sandbox(tmp_path)
    link = _link(root)
    link.mkdir()
    (link / "plugin.gd").write_text("# OUTDATED\n", encoding="utf-8")

    result = _run_verify(root)

    assert result.returncode == 0, result.stdout + result.stderr
    assert _is_reparse(link), "a real dir must be replaced by a junction, not accepted"
    assert (link / "plugin.gd").read_text(encoding="utf-8") == CANONICAL


def test_verify_worktree_accepts_correct_junction(tmp_path: Path) -> None:
    root = _make_sandbox(tmp_path)
    _mklink(_link(root), _target(root))

    result = _run_verify(root)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "[ok]" in result.stdout
    _assert_healthy(root)
    assert _stale_dirs(root) == []
