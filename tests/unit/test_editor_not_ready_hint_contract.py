"""Source-level contract for the structured EDITOR_NOT_READY payload.

Telemetry on plugin v2.5.6 showed 89% of EDITOR_NOT_READY errors came from
two users in retry loops during ``playing`` — the LLM saw a bare error and
kept guessing. The fix attaches a ``data`` block with
``editor_state``/``retryable``/``hint`` to the EDITOR_NOT_READY paths that
correspond to recoverable editor *states* — the Python ``require_writable``
gate (``playing``/``importing``) and the GDScript ``require_edited_scene``
helper (``no_scene``). These are the paths AI callers loop on because
there's an obvious recovery action.

#651 stage 1 extended this: every EDITOR_NOT_READY callsite now also
carries ``data.sub_code`` naming the concrete editor state (via
``ErrorCodes.make_not_ready`` on the GDScript side), so telemetry can
attribute the formerly opaque bucket. Internal-state failures
("EditorFileSystem not available", "AnimationHandler not available",
"No 3D viewport available") get ``sub_code``/``retryable`` but still no
fabricated recovery hint — there isn't a caller action to name.

The Python gate is covered behaviorally by ``test_readiness.py``. This
file locks the GDScript-side ``no_scene`` branch in ``utils/scene_path.gd``
— that path can't be exercised from the live GDScript test runner because
the test harness always has a scene open, so we verify the source attaches
the structured payload.
"""

from __future__ import annotations

import re
from pathlib import Path

from godot_ai.protocol.errors import EditorNotReadySubCode

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def test_scene_path_no_scene_error_carries_editor_state_payload() -> None:
    source = (PLUGIN_ROOT / "utils" / "scene_path.gd").read_text(encoding="utf-8")
    # Locate the no-scene branch by its message so we don't false-positive
    # on the EDITED_SCENE_MISMATCH path further down.
    no_scene_marker = '"No scene open"'
    assert no_scene_marker in source
    branch_start = source.index(no_scene_marker)
    # The data attachment must follow within the same branch (next ~25 lines).
    branch = source[branch_start : branch_start + 600]
    assert '"editor_state": "no_scene"' in branch, (
        "no_scene error must carry editor_state for the AI-caller hint payload"
    )
    # #651 stage 1: the sub-code names the state for telemetry attribution.
    assert '"sub_code": ErrorCodes.SUB_EDITOR_NO_SCENE' in branch
    assert '"retryable": false' in branch, "no_scene is terminal until scene_open is called"
    assert '"hint":' in branch
    # The hint must name the exact recovery tool so the LLM doesn't guess.
    assert "scene_open" in branch


def test_gdscript_sub_code_constants_match_python_enum() -> None:
    """#651 stage 1: the SUB_* constants in utils/error_codes.gd and the
    ``EditorNotReadySubCode`` enum in protocol/errors.py are the same
    vocabulary — telemetry allowlists on the Python enum, so a sub-code
    added only on the GDScript side would be silently dropped from
    attribution."""
    source = (PLUGIN_ROOT / "utils" / "error_codes.gd").read_text(encoding="utf-8")
    ## Whitespace/annotation-tolerant (mirrors test_error_code_parity's
    ## _CONST_RE): `const X := "v"`, `const X: String = "v"`, and
    ## `const X = "v"` all match, so a sub-code added in any legal
    ## declaration style can't silently vanish from this parity check.
    gd_sub_codes = set(
        re.findall(
            r'^\s*const\s+SUB_\w+\s*(?::\s*String\s*)?:?=\s*"(\w+)"',
            source,
            re.MULTILINE,
        )
    )
    py_sub_codes = {member.value for member in EditorNotReadySubCode}
    assert gd_sub_codes == py_sub_codes, (
        f"GDScript SUB_* constants and EditorNotReadySubCode drifted: "
        f"gd-only={sorted(gd_sub_codes - py_sub_codes)}, "
        f"py-only={sorted(py_sub_codes - gd_sub_codes)}"
    )


def test_gdscript_make_not_ready_helper_builds_full_payload() -> None:
    """Source-level lock on the ``make_not_ready`` helper every straggler
    callsite now routes through: top-level code stays EDITOR_NOT_READY
    (dashboards key on it) and data carries sub_code + retryable."""
    source = (PLUGIN_ROOT / "utils" / "error_codes.gd").read_text(encoding="utf-8")
    marker = "static func make_not_ready("
    assert marker in source
    body = source[source.index(marker) : source.index(marker) + 800]
    assert "make(EDITOR_NOT_READY, message)" in body, (
        "make_not_ready must never emit the sub-code as the top-level code"
    )
    assert '"sub_code": sub_code' in body
    assert '"retryable": retryable' in body


def test_python_gate_payload_uses_editor_state_key_not_legacy_state() -> None:
    """The data shape changed from ``state`` to ``editor_state`` to match
    the GDScript-side payload. Both halves must stay in sync — same key
    name, same shape, regardless of which non-writable condition triggers
    the error."""
    source = (
        Path(__file__).resolve().parents[2] / "src" / "godot_ai" / "handlers" / "_readiness.py"
    ).read_text(encoding="utf-8")
    assert '"editor_state": session.readiness' in source
    assert '"hint": hint' in source
    # Make sure the legacy key didn't survive a careless refactor.
    assert '"state":' not in source.split("_enforce_blocking_state")[1].split("def ")[0], (
        "the data block must use 'editor_state' (mirrors GDScript no_scene payload), not 'state'"
    )
