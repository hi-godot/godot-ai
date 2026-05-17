"""Source-level contract for the structured EDITOR_NOT_READY payload.

Telemetry on plugin v2.5.6 showed 89% of EDITOR_NOT_READY errors came from
two users in retry loops during ``playing`` — the LLM saw a bare error and
kept guessing. The fix attaches a ``data`` block with
``editor_state``/``retryable``/``hint`` to the EDITOR_NOT_READY paths that
correspond to recoverable editor *states* — the Python ``require_writable``
gate (``playing``/``importing``) and the GDScript ``require_edited_scene``
helper (``no_scene``). These are the paths AI callers loop on because
there's an obvious recovery action.

Other EDITOR_NOT_READY callsites in handlers (e.g. "EditorFileSystem not
available", "AnimationHandler not available", "No 3D viewport available")
describe internal-state failures with no caller-actionable recovery and
are intentionally left unenriched — adding a fabricated hint there would
mislead more than it would help.

The Python gate is covered behaviorally by ``test_readiness.py``. This
file locks the GDScript-side ``no_scene`` branch in ``utils/scene_path.gd``
— that path can't be exercised from the live GDScript test runner because
the test harness always has a scene open, so we verify the source attaches
the structured payload.
"""

from __future__ import annotations

from pathlib import Path

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
    assert '"retryable": false' in branch, "no_scene is terminal until scene_open is called"
    assert '"hint":' in branch
    # The hint must name the exact recovery tool so the LLM doesn't guess.
    assert "scene_open" in branch


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
