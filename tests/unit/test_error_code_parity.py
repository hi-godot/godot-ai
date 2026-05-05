"""Contract test: every code GDScript emits must exist in Python's ErrorCode.

Plugin handlers send `{"error": {"code": "<NAME>", ...}}` over the wire;
`godot_client.client.GodotCommandError` forwards `error.code` verbatim. If a
GDScript handler ever emits a code Python's `ErrorCode` enum doesn't know, the
forwarded string still works at runtime but agents and tests that match on
`ErrorCode.X` silently miss it. Tracked as #297 audit finding #12.

The contract is one-way: GDScript ⊆ Python. Python carries server-only codes
(SESSION_NOT_FOUND, COMMAND_TIMEOUT, PLUGIN_DISCONNECTED) the plugin never
emits; that asymmetry is intentional.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path

from godot_ai.protocol.errors import ErrorCode

ERROR_CODES_GD = (
    Path(__file__).resolve().parents[2]
    / "plugin"
    / "addons"
    / "godot_ai"
    / "utils"
    / "error_codes.gd"
)

_CONST_RE = re.compile(r'^\s*const\s+([A-Z_]+)\s*:=\s*"([A-Z_]+)"\s*$', re.MULTILINE)


@functools.cache
def _parse_gdscript_codes() -> dict[str, str]:
    text = ERROR_CODES_GD.read_text()
    return dict(_CONST_RE.findall(text))


def test_gdscript_codes_parsed_non_empty() -> None:
    # Guard the test itself: a parser regression that returns {} would let
    # every other assertion below pass vacuously.
    codes = _parse_gdscript_codes()
    assert codes, f"No constants parsed from {ERROR_CODES_GD}; check the regex"


def test_every_gdscript_code_exists_in_python_errorcode() -> None:
    gdscript_codes = _parse_gdscript_codes()
    python_codes = {member.name: member.value for member in ErrorCode}
    missing = sorted(gdscript_codes.keys() - python_codes.keys())
    assert not missing, (
        f"GDScript emits error codes that Python's ErrorCode doesn't define: "
        f"{missing}. Add them to src/godot_ai/protocol/errors.py."
    )


def test_gdscript_and_python_string_values_match() -> None:
    gdscript_codes = _parse_gdscript_codes()
    python_codes = {member.name: member.value for member in ErrorCode}
    mismatched = {
        name: (gdscript_codes[name], python_codes[name])
        for name in gdscript_codes.keys() & python_codes.keys()
        if gdscript_codes[name] != python_codes[name]
    }
    assert not mismatched, (
        f"String-value drift between GDScript and Python error codes: "
        f"{mismatched} (format: name -> (gdscript, python))"
    )
