"""Lint: GDScript tests must not call ``_undo_redo.undo()`` / ``.redo()`` directly.

Issue #290 — ``EditorUndoRedoManager.undo()`` does not exist in Godot 4.x.
Calling it logs a ``SCRIPT ERROR: Invalid call. Nonexistent function 'undo' in
base 'EditorUndoRedoManager'.`` to the editor output and silently returns
``null`` — the test then asserts on whichever post-undo state happens to match
the do-state, masking handler regressions in the undo/redo path.

The supported pattern is the helper on ``McpTestSuite``::

    assert_true(editor_undo(_undo_redo), "<reason> undo should succeed")

which walks both the scene history and ``GLOBAL_HISTORY``, calls ``.undo()``
on the underlying ``UndoRedo``, and returns whether anything was actually
undone (so a no-op surfaces as a real test failure).

This lint runs at ``pytest`` time so the bad pattern can't sneak back in via a
new test file. The structural sweep that fixed the existing 52 sites lives in
the same PR (#290).
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GDSCRIPT_TESTS = REPO_ROOT / "test_project" / "tests"

# ``_undo_redo.undo()`` or ``_undo_redo.redo()`` as a real call — not bare
# ``_undo_redo.undo`` (a method reference) and not the same identifier appearing
# inside a comment or a string. The check below strips those out before the
# regex runs.
_BAD_CALL = re.compile(r"\b_undo_redo\s*\.\s*(?:undo|redo)\s*\(")


def _strip_comments_and_strings(text: str) -> str:
    """Return ``text`` with line comments and string literals blanked out.

    GDScript line comments start at ``#`` and run to end-of-line. Strings come
    in single-line ``"..."`` / ``'...'`` form (with backslash escaping) and in
    triple-quoted form (single or double quote, repeated three times).
    Replacing them with same-length whitespace preserves line and column
    numbers so reported locations stay accurate.
    """
    out: list[str] = []
    n = len(text)
    i = 0
    while i < n:
        ch = text[i]
        if ch == "#":
            j = text.find("\n", i)
            if j == -1:
                j = n
            out.append(" " * (j - i))
            i = j
            continue
        if ch in ('"', "'"):
            triple = text[i : i + 3]
            if triple == ch * 3:
                end = text.find(ch * 3, i + 3)
                end = (end + 3) if end != -1 else n
            else:
                j = i + 1
                while j < n:
                    c = text[j]
                    if c == "\\":
                        j += 2
                        continue
                    if c == ch or c == "\n":
                        j += 1
                        break
                    j += 1
                end = j
            # Preserve any embedded newlines so line numbers match.
            span = text[i:end]
            out.append("".join(c if c == "\n" else " " for c in span))
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _find_offenders(text: str) -> list[tuple[int, int, str]]:
    """Return ``(line, col, snippet)`` for each direct undo/redo call site."""
    stripped = _strip_comments_and_strings(text)
    hits: list[tuple[int, int, str]] = []
    for m in _BAD_CALL.finditer(stripped):
        pos = m.start()
        line = text.count("\n", 0, pos) + 1
        col = pos - (text.rfind("\n", 0, pos) + 1) + 1
        # Use the original text for the snippet so the user sees what they wrote.
        line_start = text.rfind("\n", 0, pos) + 1
        line_end = text.find("\n", pos)
        if line_end == -1:
            line_end = len(text)
        hits.append((line, col, text[line_start:line_end].rstrip()))
    return hits


def test_no_direct_undo_redo_calls_in_gdscript_tests() -> None:
    """No ``test_*.gd`` file may call ``_undo_redo.undo()`` / ``.redo()`` directly."""
    offenders: list[str] = []
    assert GDSCRIPT_TESTS.exists(), f"Test root does not exist: {GDSCRIPT_TESTS}"
    for path in sorted(GDSCRIPT_TESTS.rglob("*.gd")):
        text = path.read_text(encoding="utf-8")
        for line, col, snippet in _find_offenders(text):
            rel = path.relative_to(REPO_ROOT)
            offenders.append(f"{rel}:{line}:{col}  {snippet}")

    assert not offenders, (
        "EditorUndoRedoManager.undo()/redo() do not exist in Godot 4.x. Use "
        '`assert_true(editor_undo(_undo_redo), "... should succeed")` (or '
        "`editor_redo`) from McpTestSuite — see issue #290.\nOffenders:\n  "
        + "\n  ".join(offenders)
    )


# --- detector self-tests: pin the lint's behavior so a refactor cannot quietly
# weaken it into a no-op (the same trap covered in #246's adjacent-string lint). ---


def test_detector_flags_canonical_bad_call() -> None:
    src = "func test_x():\n\t_undo_redo.undo()\n"
    assert [h[0] for h in _find_offenders(src)] == [2]


def test_detector_flags_redo_call() -> None:
    assert _find_offenders("\t_undo_redo.redo()\n") != []


def test_detector_ignores_helper_call() -> None:
    src = '\tassert_true(editor_undo(_undo_redo), "msg")\n'
    assert _find_offenders(src) == []


def test_detector_ignores_method_reference() -> None:
    """``_undo_redo.undo`` (no parens) is a Callable reference, not a call."""
    src = "\tvar fn := _undo_redo.undo\n"
    assert _find_offenders(src) == []


def test_detector_ignores_call_inside_comment() -> None:
    src = "\t## historical: _undo_redo.undo() used to be the cleanup pattern\n"
    assert _find_offenders(src) == []


def test_detector_ignores_call_inside_string_literal() -> None:
    src = '\tprint("avoid _undo_redo.undo() in tests")\n'
    assert _find_offenders(src) == []


def test_detector_ignores_call_inside_triple_quoted_string() -> None:
    src = '\tvar doc := """example: _undo_redo.undo() bad"""\n'
    assert _find_offenders(src) == []
