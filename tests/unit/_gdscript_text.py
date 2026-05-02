"""Helpers for asserting GDScript source-text properties from Python tests."""

from __future__ import annotations

_TERMINATORS = ("\nfunc ", "\nstatic func ")


def get_func_block(source: str, signature: str) -> str:
    """Return the body of a GDScript function sliced out of `source`.

    `signature` is the literal first line of the function as it appears in
    the source — e.g. ``"func _foo() -> void:"`` or
    ``"static func _bar(arg: int) -> bool:"``. Slice runs from the end of
    `signature` to the next top-level ``func ``/``static func ``
    declaration. If the matched function is the last one in the file, the
    slice runs to end-of-source.

    Raises AssertionError if `signature` is not present in `source` —
    catches the silent-pass case where a refactor renames the target
    function and ``"X" in block`` would otherwise match an empty string.
    """
    if signature not in source:
        raise AssertionError(f"signature not found in source: {signature!r}")
    rest = source.split(signature, 1)[1]
    cuts = [c for c in (rest.find(t) for t in _TERMINATORS) if c >= 0]
    return rest if not cuts else rest[: min(cuts)]
