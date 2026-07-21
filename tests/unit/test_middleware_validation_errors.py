"""Tests for shared validation-error wrapper traversal."""

from __future__ import annotations

from godot_ai.middleware import find_pydantic_validation_error


def test_validation_error_traversal_terminates_on_wrapper_cycle() -> None:
    first = RuntimeError("first")
    second = RuntimeError("second")
    first.__cause__ = second
    second.__context__ = first

    assert find_pydantic_validation_error(first) is None
