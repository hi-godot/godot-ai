"""#1120: every FILESYSTEM_DISCOVERY_FAILED refusal names its refusal path.

Discovery refusals used to arrive as a bare FILESYSTEM_DISCOVERY_FAILED, so
telemetry could not tell an entry cap from a symlink, an unreadable owner or a
deadline. Each refusal now carries ``error.data.sub_code`` from a fixed
vocabulary. These source checks keep that true as discovery changes: a new
refusal path that sets the top-level code without a sub-code, or a sub-code
added on one side only, fails here. Behavior is covered by
tests/integration/_filesystem_mutation_suite.gd in a real editor.
"""

from __future__ import annotations

import re
from pathlib import Path

from godot_ai.protocol.errors import FilesystemDiscoverySubCode

PLUGIN = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
ERROR_CODES_GD = PLUGIN / "utils" / "error_codes.gd"
MUTATION_GD = PLUGIN / "handlers" / "filesystem_mutation.gd"

_CONST_RE = re.compile(r'^\s*const\s+(DISCOVERY_SUB_\w+)\s*:=\s*"(\w+)"\s*$', re.MULTILINE)


def _gd_constants() -> dict[str, str]:
    return dict(_CONST_RE.findall(ERROR_CODES_GD.read_text(encoding="utf-8")))


def test_gdscript_constants_match_python_enum() -> None:
    gd = set(_gd_constants().values())
    py = {member.value for member in FilesystemDiscoverySubCode}
    assert gd, f"No DISCOVERY_SUB_* constants parsed from {ERROR_CODES_GD}"
    assert gd == py, (
        "DISCOVERY_SUB_* constants and FilesystemDiscoverySubCode drifted: "
        f"gd-only={sorted(gd - py)}, py-only={sorted(py - gd)}"
    )


def test_constant_names_follow_their_values() -> None:
    for name, value in _gd_constants().items():
        assert name == "DISCOVERY_SUB_" + value.removeprefix("DISCOVERY_"), (name, value)


def test_discovery_failures_go_through_the_sub_code_helper() -> None:
    """The top-level code appears only in the helper that pairs it with a
    sub-code and in the result builder that reads it back."""
    text = MUTATION_GD.read_text(encoding="utf-8")
    code = "Errors.FILESYSTEM_DISCOVERY_FAILED"
    lines = [line.strip() for line in text.splitlines() if code in line]
    assert lines == [
        "_set_fault(message, Errors.FILESYSTEM_DISCOVERY_FAILED, sub_code)",
        "if _fault_code == Errors.FILESYSTEM_DISCOVERY_FAILED:",
    ], lines


def test_every_sub_code_is_emitted_and_every_emission_is_known() -> None:
    text = MUTATION_GD.read_text(encoding="utf-8")
    used = set(re.findall(r"Errors\.(DISCOVERY_SUB_\w+)", text))
    known = set(_gd_constants())
    assert used <= known, f"unknown sub-code constants: {sorted(used - known)}"
    assert used == known, f"sub-codes never emitted: {sorted(known - used)}"
    calls = re.findall(r"_discovery_fault\((.*)\)\s*$", text, re.MULTILINE)
    assert calls, "no _discovery_fault calls found"
    for call in calls:
        if call.startswith("message: String"):
            continue  # the definition
        assert re.search(r"Errors\.DISCOVERY_SUB_\w+$", call), call
