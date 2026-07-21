"""Contract test: screenshot docs must only use real editor_screenshot sources.

docs/screenshot-testing.md once described ``source="viewport"`` as the editor's
2D view — it is the 3D viewport; the 2D view is ``source="viewport_2d"``
(issue #773). This guard keeps the doc's source tokens aligned with the
handler's accepted set so the two can't silently diverge again.

The accepted set is parsed from the invalid-source error message in
plugin/addons/godot_ai/handlers/editor_handler.gd — the one line the handler
keeps in lockstep with its own ``match source:`` arms.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path

from tests.unit._gdscript_text import get_func_block

_REPO_ROOT = Path(__file__).resolve().parents[2]
EDITOR_HANDLER_GD = _REPO_ROOT / "plugin" / "addons" / "godot_ai" / "handlers" / "editor_handler.gd"
SCREENSHOT_DOC = _REPO_ROOT / "docs" / "screenshot-testing.md"

## Matches take_screenshot's rejection message (scoped to that function —
## logs_read has its own "Invalid source" line with a different vocabulary):
##   "Invalid source '%s' — use 'viewport', 'viewport_2d', 'cinematic', or 'game'"
_INVALID_SOURCE_LINE_RE = re.compile(r"Invalid source '%s' — use ([^\"]+)")
_QUOTED_TOKEN_RE = re.compile(r"'([a-z0-9_]+)'")

## Matches source="viewport" / source='viewport' in prose and code fences.
_DOC_SOURCE_TOKEN_RE = re.compile(r"""source\s*=\s*["']([^"']+)["']""")


@functools.cache
def _handler_sources() -> frozenset[str]:
    text = EDITOR_HANDLER_GD.read_text(encoding="utf-8")
    block = get_func_block(text, "func take_screenshot(params: Dictionary) -> Dictionary:")
    match = _INVALID_SOURCE_LINE_RE.search(block)
    assert match, (
        f"Invalid-source error message not found in take_screenshot in {EDITOR_HANDLER_GD}; "
        "if its wording changed, update _INVALID_SOURCE_LINE_RE."
    )
    return frozenset(_QUOTED_TOKEN_RE.findall(match.group(1)))


def test_handler_sources_parsed_sanely() -> None:
    # Guard the parser itself: an empty or shrunken set would let the doc
    # assertions below pass (or fail) for the wrong reason.
    assert _handler_sources() >= {"viewport", "viewport_2d", "cinematic", "game"}, (
        f"Parsed handler sources {sorted(_handler_sources())} lost a known "
        f"value; check {EDITOR_HANDLER_GD} and the regexes in this file."
    )


def test_doc_source_tokens_are_accepted_by_handler() -> None:
    doc_tokens = _DOC_SOURCE_TOKEN_RE.findall(SCREENSHOT_DOC.read_text(encoding="utf-8"))
    assert doc_tokens, f'No source="..." tokens found in {SCREENSHOT_DOC}; check the regex'
    unknown = sorted(set(doc_tokens) - _handler_sources())
    assert not unknown, (
        f"{SCREENSHOT_DOC} references source values the editor_screenshot "
        f"handler does not accept: {unknown}. Accepted: {sorted(_handler_sources())}."
    )


def test_every_handler_source_is_documented() -> None:
    doc_text = SCREENSHOT_DOC.read_text(encoding="utf-8")
    # \b keeps "viewport" from matching inside "viewport_2d" ("_" is a word char).
    missing = sorted(
        s for s in _handler_sources() if not re.search(rf"\b{re.escape(s)}\b", doc_text)
    )
    assert not missing, (
        f"editor_screenshot sources missing from {SCREENSHOT_DOC}: {missing}. "
        "Document each source in the 'Pick the right source' table."
    )
