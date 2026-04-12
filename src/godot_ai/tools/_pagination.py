"""Shared pagination helper for MCP tools."""

from __future__ import annotations


def paginate(items: list, offset: int, limit: int, *, key: str = "items") -> dict:
    """Apply offset/limit pagination to a list.

    Returns a dict with the paginated slice under the given key,
    plus total_count, offset, limit, and has_more metadata.
    """
    total_count = len(items)
    page = items[offset : offset + limit]
    return {
        key: page,
        "total_count": total_count,
        "offset": offset,
        "limit": limit,
        "has_more": offset + limit < total_count,
    }
