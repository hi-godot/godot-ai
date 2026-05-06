"""Counter regression test for audit-v2 #21 (issue #365).

The pre-fix vocabulary had 471 INVALID_PARAMS sites in plugin handlers,
conflating "missing required param", "wrong type", "value out of range",
"node not found", "property not on this class", and "resource not found"
into one opaque code. The migration carved six finer codes out of that
catch-all (NODE_NOT_FOUND, RESOURCE_NOT_FOUND, PROPERTY_NOT_ON_CLASS,
VALUE_OUT_OF_RANGE, WRONG_TYPE, MISSING_REQUIRED_PARAM).

Without this counter test, a future handler is overwhelmingly likely to
copy-paste the nearest neighbor's error pattern and silently regress the
distribution back to "everything is INVALID_PARAMS". The ceiling here
isn't aspirational — it's the post-migration baseline plus a small slack
for genuinely-catch-all additions. If you need to raise it, ask whether
the new sites really belong under a more specific code first.
"""

from __future__ import annotations

import re
from pathlib import Path

HANDLERS_DIR = (
    Path(__file__).resolve().parents[2]
    / "plugin"
    / "addons"
    / "godot_ai"
    / "handlers"
)

## Post-migration baseline: 97 INVALID_PARAMS sites in plugin/handlers/.
## The 367 specifically-coded sites are spread across NODE_NOT_FOUND (39),
## RESOURCE_NOT_FOUND (30), PROPERTY_NOT_ON_CLASS (28), VALUE_OUT_OF_RANGE
## (75), WRONG_TYPE (73), MISSING_REQUIRED_PARAM (122). The ceiling allows
## a small slack for new genuinely-catch-all errors (state conflicts,
## semantic violations, duplicate detections) without forcing this test
## to be re-baselined on every PR — but anything more than +13 should
## prompt review of whether the new sites really belong here.
INVALID_PARAMS_CEILING = 110

## Each new code should be used at least somewhere; a regression where a
## refactor accidentally drops every use of a code is exactly the kind of
## under-classification the audit was about. Floor is 1 (existence
## check); not a coverage target.
NEW_CODES_MIN_USES = {
    "NODE_NOT_FOUND": 1,
    "RESOURCE_NOT_FOUND": 1,
    "PROPERTY_NOT_ON_CLASS": 1,
    "VALUE_OUT_OF_RANGE": 1,
    "WRONG_TYPE": 1,
    "MISSING_REQUIRED_PARAM": 1,
}


def _count_code_uses(code: str) -> int:
    """Count word-boundary matches of `code` across all .gd files in handlers/."""
    pattern = re.compile(rf"\b{re.escape(code)}\b")
    total = 0
    for gd_file in HANDLERS_DIR.glob("*.gd"):
        total += len(pattern.findall(gd_file.read_text()))
    return total


def test_invalid_params_stays_below_ceiling() -> None:
    count = _count_code_uses("INVALID_PARAMS")
    assert count <= INVALID_PARAMS_CEILING, (
        f"INVALID_PARAMS count is {count}, above the {INVALID_PARAMS_CEILING} "
        "ceiling. Audit-v2 #21 carved six finer codes out of the original "
        "471-site INVALID_PARAMS catch-all (NODE_NOT_FOUND, "
        "RESOURCE_NOT_FOUND, PROPERTY_NOT_ON_CLASS, VALUE_OUT_OF_RANGE, "
        "WRONG_TYPE, MISSING_REQUIRED_PARAM). Before raising the ceiling, "
        "check whether the new sites actually fit one of the specific codes."
    )


def test_each_new_code_is_actually_used() -> None:
    counts = {code: _count_code_uses(code) for code in NEW_CODES_MIN_USES}
    starved = {code: c for code, c in counts.items() if c < NEW_CODES_MIN_USES[code]}
    assert not starved, (
        f"New error codes that aren't used anywhere in handlers/: {starved}. "
        "A code that's never emitted is dead weight in the vocabulary."
    )
