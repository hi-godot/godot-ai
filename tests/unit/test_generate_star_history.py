"""Tests for script/generate-star-history (#750).

The script lives in script/ without a .py suffix, so load it via importlib.
Network fetch is not exercised here — rendering and aggregation are.
"""

import importlib.util
from datetime import date
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[2] / "script" / "generate-star-history"
_spec = importlib.util.spec_from_loader(
    "generate_star_history",
    importlib.machinery.SourceFileLoader("generate_star_history", str(_SCRIPT)),
)
gsh = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gsh)


def test_cumulative_points_collapses_same_day_stars():
    stars = [date(2026, 4, 12), date(2026, 4, 12), date(2026, 4, 14)]
    points = gsh.cumulative_points(stars)
    # First point: both same-day stars collapsed into one step at count 2.
    assert points[0] == (date(2026, 4, 12), 2)
    assert (date(2026, 4, 14), 3) in points
    # A trailing "today" point extends the line to the present.
    assert points[-1][1] == 3


def test_parse_seed_sorts_and_parses():
    points = gsh.parse_seed("2026-07-16:1009, 2026-04-12:0")
    assert points == [(date(2026, 4, 12), 0), (date(2026, 7, 16), 1009)]


@pytest.mark.parametrize(
    "value,expected",
    [(3, 10), (10, 10), (11, 20), (150, 200), (1009, 2000), (4999, 5000), (5001, 10000)],
)
def test_nice_ceiling(value, expected):
    assert gsh._nice_ceiling(value) == expected


def test_render_svg_is_valid_and_scaled():
    import xml.dom.minidom

    points = [
        (date(2026, 4, 12), 0),
        (date(2026, 5, 1), 200),
        (date(2026, 6, 1), 700),
        (date(2026, 7, 16), 1009),
    ]
    svg = gsh.render_svg(points, "hi-godot/godot-ai")
    doc = xml.dom.minidom.parseString(svg)
    assert doc.documentElement.tagName == "svg"
    assert "1009" in svg  # final count labeled
    assert "hi-godot/godot-ai" in svg
    # No external references — the SVG must be self-contained for README use.
    assert "http" not in svg.replace("http://www.w3.org/2000/svg", "")


def test_render_svg_rejects_single_point():
    with pytest.raises(SystemExit):
        gsh.render_svg([(date(2026, 4, 12), 0)], "hi-godot/godot-ai")
