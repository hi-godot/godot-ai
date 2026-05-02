"""Self-tests for tests/unit/_gdscript_text.py.

Pinning these so a future refactor of the helper can't silently weaken
the slicing — every test that depends on `get_func_block` is asserting
``"X" in block``, so a regression that returns too much text would mask
real bugs in the GDScript source it's supposed to pin.
"""

from __future__ import annotations

import pytest

from tests.unit._gdscript_text import get_func_block

_SAMPLE = """\
extends Node


func _ready() -> void:
\tprint("ready")
\t_helper()


func _helper() -> void:
\t## Some doc.
\tprint("helper")


func _last() -> void:
\treturn
"""


def test_returns_body_until_next_top_level_func() -> None:
    block = get_func_block(_SAMPLE, "func _ready() -> void:")
    assert "_helper()" in block
    # Helper body must NOT leak into the slice.
    assert "## Some doc." not in block
    assert "_last()" not in block


def test_terminal_function_runs_to_end_of_source() -> None:
    block = get_func_block(_SAMPLE, "func _last() -> void:")
    assert "return" in block


def test_signature_with_arguments() -> None:
    src = """\
func _foo(arg: int) -> bool:
\treturn arg > 0


func _bar() -> void:
\tpass
"""
    block = get_func_block(src, "func _foo(arg: int) -> bool:")
    assert "return arg > 0" in block
    assert "_bar" not in block


def test_missing_signature_raises_assertion_error() -> None:
    with pytest.raises(AssertionError, match="signature not found"):
        get_func_block(_SAMPLE, "func _does_not_exist() -> void:")


def test_partial_signature_match_is_supported() -> None:
    """The original split-call sites match prefixes (no trailing `:`)."""
    block = get_func_block(_SAMPLE, "func _helper")
    assert "## Some doc." in block
    assert 'print("helper")' in block
    assert "_last" not in block


def test_terminates_at_static_func_boundary() -> None:
    """`static func` is a top-level boundary too — one of the migrated call
    sites needs to slice out a `static func` body that's followed by another
    `static func` (no intervening blank line, just a doc comment block)."""

    src = """\
static func _foo() -> String:
\treturn "foo"
## Doc comment immediately before next static func.
static func _bar() -> void:
\tpass
"""
    block = get_func_block(src, "static func _foo() -> String:")
    assert "foo" in block
    assert "_bar" not in block, (
        "Slice must terminate at the next `static func` even if no blank "
        "line separates them — doc-commented static funcs are common."
    )


def test_does_not_terminate_at_escaped_newline_in_string_literal() -> None:
    """A `\\n` escape inside a Python-literal-quoted string (which lands as
    backslash-then-n bytes in the .gd source, NOT a real newline) must not
    fool the terminator search."""

    src = """\
func _outer() -> void:
\tvar s := "decoy:\\nfunc fake(): pass"
\tprint(s)


func _real_next() -> void:
\tpass
"""
    block = get_func_block(src, "func _outer() -> void:")
    assert "decoy" in block
    assert "_real_next" not in block
