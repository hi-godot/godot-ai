"""Tests for script/generate-star-history (#750).

The script lives in script/ without a .py suffix, so load it via importlib.
Network fetch is not exercised here — rendering, aggregation, and the
failure diagnostics are.
"""

import importlib.util
import io
import urllib.error
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
    [
        # (y_max, step): 3-5 tidy intervals with ~6% headroom over the peak,
        # so the curve fills the plot instead of hugging the bottom half.
        (1, (2, 1)),
        (3, (4, 1)),
        (10, (15, 5)),
        (150, (200, 50)),
        (1009, (1250, 250)),
        (1156, (1250, 250)),
        (4999, (6000, 2000)),
        (40000, (50000, 10000)),
    ],
)
def test_nice_axis(value, expected):
    y_max, step = gsh._nice_axis(value)
    assert (y_max, step) == expected
    # Invariants regardless of the picked values: the peak fits under the
    # ceiling and the gridline step divides it evenly.
    assert y_max >= value
    assert y_max % step == 0


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
    assert "1,009 stars" in svg  # final count badge, thousands-separated
    assert "hi-godot/godot-ai" in svg
    # The gradient line and end-of-line star marker are internal references.
    assert 'stroke="url(#lineGrad)"' in svg
    # No external references — the SVG must be self-contained for README use.
    assert "http" not in svg.replace("http://www.w3.org/2000/svg", "")


def test_render_svg_is_deterministic():
    # The workflow's "chart unchanged, nothing to commit" check relies on
    # byte-identical output for unchanged data — the starfield must be
    # seeded, not random.
    points = [(date(2026, 4, 12), 0), (date(2026, 7, 16), 1009)]
    assert gsh.render_svg(points, "hi-godot/godot-ai") == gsh.render_svg(
        points, "hi-godot/godot-ai"
    )


def test_render_svg_rejects_single_point():
    with pytest.raises(SystemExit):
        gsh.render_svg([(date(2026, 4, 12), 0)], "hi-godot/godot-ai")


_URL = "https://api.github.com/repos/hi-godot/godot-ai/stargazers?per_page=100&page=1"


def _http_error(code, message="Forbidden", body=None, headers=None):
    payload = b"" if body is None else body
    return urllib.error.HTTPError(_URL, code, message, headers or {}, io.BytesIO(payload))


def test_describe_http_error_quotes_the_api_message():
    # The whole point of the diagnostic: GitHub's own words, not our guess.
    # A 403 naming an org policy must not be reported as a missing secret.
    err = _http_error(
        403,
        body=b'{"message": "hi-godot forbids access via a personal access token"}',
    )
    detail = gsh.describe_http_error(err, _URL, "STAR_HISTORY_TOKEN")
    assert "hi-godot forbids access via a personal access token" in detail
    assert "Token used: STAR_HISTORY_TOKEN." in detail
    # 403 is an authorization refusal, not an expiry — don't send the reader
    # off to reissue a token that is working fine.
    assert "not authorized" in detail
    assert "Rate limited" not in detail


def test_describe_http_error_flags_rate_limiting():
    err = _http_error(
        403,
        body=b'{"message": "API rate limit exceeded"}',
        # 2026-07-25T09:00:00Z
        headers={"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1784970000"},
    )
    detail = gsh.describe_http_error(err, _URL, "STAR_HISTORY_TOKEN")
    assert "Rate limited" in detail
    assert "2026-07-25 09:00 UTC" in detail
    assert "not authorized" not in detail


def test_describe_http_error_flags_secondary_rate_limiting():
    # A secondary limit answers 403 with primary quota left, so classifying on
    # remaining == "0" alone would file it as an authorization failure and send
    # the reader off to replace a perfectly good token.
    err = _http_error(
        403,
        body=b'{"message": "You have exceeded a secondary rate limit"}',
        headers={"x-ratelimit-remaining": "4312", "retry-after": "60"},
    )
    detail = gsh.describe_http_error(err, _URL, "STAR_HISTORY_TOKEN")
    assert "Rate limited" in detail
    assert "retry after 60s" in detail
    assert "not authorized" not in detail


def test_describe_http_error_distinguishes_rejected_credentials():
    err = _http_error(401, body=b'{"message": "Bad credentials"}')
    detail = gsh.describe_http_error(err, _URL, "GITHUB_TOKEN (fallback)")
    assert "Bad credentials" in detail
    assert "expired, revoked, or malformed" in detail
    assert "Token used: GITHUB_TOKEN (fallback)." in detail


def test_describe_http_error_survives_a_bodyless_response():
    # An empty or non-JSON body must still yield a usable report rather than
    # masking the original failure with a decode error.
    detail = gsh.describe_http_error(_http_error(403, body=b"<html>"), _URL, "tok")
    assert "GitHub returned no message body." in detail
    assert "403" in detail


def test_fetch_star_dates_routes_4xx_through_the_diagnostic(monkeypatch):
    # Cross-function contract: the fetch layer must hand refusals to
    # describe_http_error with the token label attached, not swallow them or
    # report a bare status code.
    def refuse(req, timeout=None):
        raise _http_error(404, body=b'{"message": "Not Found"}')

    monkeypatch.setattr(gsh.urllib.request, "urlopen", refuse)
    with pytest.raises(SystemExit) as excinfo:
        gsh.fetch_star_dates("hi-godot/godot-ai", "tok", "STAR_HISTORY_TOKEN")

    detail = str(excinfo.value)
    assert "Not Found" in detail
    assert "Token used: STAR_HISTORY_TOKEN." in detail
    assert "cannot see hi-godot/godot-ai" in detail


def test_fetch_star_dates_reraises_server_errors(monkeypatch):
    # 5xx is an outage, not a misconfiguration — it must not be dressed up as
    # a credential problem, and the traceback is the useful artifact.
    def boom(req, timeout=None):
        raise _http_error(502, body=b"")

    monkeypatch.setattr(gsh.urllib.request, "urlopen", boom)
    with pytest.raises(urllib.error.HTTPError):
        gsh.fetch_star_dates("hi-godot/godot-ai", "tok", "STAR_HISTORY_TOKEN")
