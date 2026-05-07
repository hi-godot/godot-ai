"""Lint that `Path.read_text()` calls in tests/ pass `encoding="utf-8"`.

Without it, Python falls back to `locale.getpreferredencoding()` —
cp1252 on Windows, which raises `UnicodeDecodeError` on any non-ASCII
byte. CI is Linux-only (#35) so the trap is silent until a developer
runs pytest on Windows; #397 is the surfacing recurrence.
"""

from __future__ import annotations

import ast
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_ROOT = REPO_ROOT / "tests"


def _bare_read_text_offenders(source: str) -> list[int]:
    """Line numbers of `.read_text()` calls in `source` that lack `encoding=`."""

    tree = ast.parse(source)
    offenders: list[int] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if not isinstance(func, ast.Attribute) or func.attr != "read_text":
            continue
        if any(kw.arg == "encoding" for kw in node.keywords):
            continue
        offenders.append(node.lineno)
    return offenders


def test_test_files_pass_encoding_to_read_text() -> None:
    offenders: list[str] = []
    for py_file in TESTS_ROOT.rglob("*.py"):
        source = py_file.read_text(encoding="utf-8")
        if "read_text" not in source:
            continue
        rel = py_file.relative_to(REPO_ROOT)
        offenders.extend(f"{rel}:{lineno}" for lineno in _bare_read_text_offenders(source))

    assert not offenders, (
        f"Pass encoding='utf-8' to Path.read_text() (issue #397). Bare calls: {offenders}"
    )


# Detector self-tests — without these, a future refactor can silently turn the
# lint into a no-op. Mirrors the pattern in `test_no_direct_undo_redo_in_gdscript_tests.py`
# and `test_gdscript_no_adjacent_string_concat.py`.


def test_detector_flags_bare_read_text() -> None:
    assert _bare_read_text_offenders("Path('x').read_text()") == [1]


def test_detector_ignores_read_text_with_encoding() -> None:
    assert _bare_read_text_offenders('Path("x").read_text(encoding="utf-8")') == []


def test_detector_ignores_unrelated_read_text_attr() -> None:
    # `mcp__github__read_text(...)` and similar non-attribute calls are not
    # what the lint targets; they're flagged only if invoked as `obj.read_text(...)`.
    assert _bare_read_text_offenders("filesystem_read_text(path)") == []


def test_detector_finds_multiple_in_one_file() -> None:
    src = textwrap.dedent(
        """
        a = p.read_text()
        b = q.read_text(encoding="utf-8")
        c = r.read_text()
        """
    )
    assert _bare_read_text_offenders(src) == [2, 4]
