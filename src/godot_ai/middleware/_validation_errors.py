"""Shared helpers for inspecting FastMCP validation-error wrapper chains."""

from __future__ import annotations

from pydantic import ValidationError as PydanticValidationError


def find_pydantic_validation_error(
    exc: BaseException,
) -> PydanticValidationError | None:
    """Find a Pydantic validation error through FastMCP wrapper chains."""
    pending: list[BaseException] = [exc]
    seen: set[int] = set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        if isinstance(current, PydanticValidationError):
            return current
        for linked in (current.__cause__, current.__context__):
            if isinstance(linked, BaseException):
                pending.append(linked)
    return None
