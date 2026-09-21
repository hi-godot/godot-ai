"""Every module that launches a real Godot editor must carry the `editor` marker.

`pytest -m "not editor"` is the documented iteration loop; a new real-editor
row without the marker would silently put minutes back into it.
"""

from __future__ import annotations

from pathlib import Path

TESTS = Path(__file__).resolve().parents[1]


def test_real_editor_modules_carry_the_editor_marker() -> None:
    missing = []
    for module in sorted((TESTS / "integration").glob("test_*.py")):
        source = module.read_text(encoding="utf-8")
        launches_editor = "godot_bin_or_skip" in source or "run_godot_editor" in source
        if launches_editor and "pytestmark = pytest.mark.editor" not in source:
            missing.append(module.name)
    assert missing == [], f"add `pytestmark = pytest.mark.editor` to: {missing}"
