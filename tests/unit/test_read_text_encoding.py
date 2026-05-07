"""Lint that `read_text()` calls in tests/ always pass `encoding=`.

`Path.read_text()` with no arguments defaults to
`locale.getpreferredencoding()`. On Windows that's cp1252, which
raises `UnicodeDecodeError` on any non-ASCII byte in the file being
read. Linux/macOS default to UTF-8, so the hazard is silent until a
developer runs pytest on Windows.

Issue #397 surfaced four failing tests in
`test_plugin_self_update_safety.py` because it `rglob`-walks the
plugin tree, and `plugin/addons/godot_ai/utils/uv_cache_cleanup.gd`
carries a verbatim Korean Windows error message string. Other tests
in `tests/unit/` walk plugin `.gd` files via `glob`/`rglob` or read
specific files that could pick up non-ASCII the next time someone
adds a foreign-language comment elsewhere.

This test enforces the hygiene rule across `tests/`: every bare
`.read_text()` call (no kwargs) is an offender. CI is Linux-only
(issue #35) so this is the only line of defense before a Windows
developer hits the same trap.
"""

from __future__ import annotations

import ast
from pathlib import Path

TESTS_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = TESTS_ROOT.parent


def test_test_files_pass_encoding_to_read_text() -> None:
    offenders: list[str] = []

    for py_file in TESTS_ROOT.rglob("*.py"):
        tree = ast.parse(py_file.read_text(encoding="utf-8"))

        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if not isinstance(func, ast.Attribute) or func.attr != "read_text":
                continue
            if any(kw.arg == "encoding" for kw in node.keywords):
                continue
            rel = py_file.relative_to(REPO_ROOT)
            offenders.append(f"{rel}:{node.lineno}")

    assert not offenders, (
        "Path.read_text() calls in tests/ must pass encoding='utf-8'. "
        "Without it, Python falls back to locale.getpreferredencoding(), "
        "which is cp1252 on Windows and raises UnicodeDecodeError on any "
        "non-ASCII byte in the file (issue #397). Add encoding='utf-8'. "
        f"Bare calls: {offenders}"
    )
