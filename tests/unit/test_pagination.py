"""Unit tests for pagination logic in tools."""

from __future__ import annotations

from godot_ai.tools._pagination import paginate as _paginate


class TestPaginate:
    def test_first_page(self):
        items = list(range(10))
        result = _paginate(items, offset=0, limit=3)
        assert result["items"] == [0, 1, 2]
        assert result["total_count"] == 10
        assert result["offset"] == 0
        assert result["limit"] == 3
        assert result["has_more"] is True

    def test_middle_page(self):
        items = list(range(10))
        result = _paginate(items, offset=3, limit=3)
        assert result["items"] == [3, 4, 5]
        assert result["has_more"] is True

    def test_last_page(self):
        items = list(range(10))
        result = _paginate(items, offset=9, limit=3)
        assert result["items"] == [9]
        assert result["has_more"] is False

    def test_exact_end(self):
        items = list(range(6))
        result = _paginate(items, offset=3, limit=3)
        assert result["items"] == [3, 4, 5]
        assert result["has_more"] is False

    def test_empty_list(self):
        result = _paginate([], offset=0, limit=10)
        assert result["items"] == []
        assert result["total_count"] == 0
        assert result["has_more"] is False

    def test_offset_beyond_end(self):
        items = [1, 2, 3]
        result = _paginate(items, offset=10, limit=5)
        assert result["items"] == []
        assert result["total_count"] == 3
        assert result["has_more"] is False

    def test_limit_larger_than_remaining(self):
        items = list(range(5))
        result = _paginate(items, offset=0, limit=100)
        assert result["items"] == [0, 1, 2, 3, 4]
        assert result["total_count"] == 5
        assert result["has_more"] is False
