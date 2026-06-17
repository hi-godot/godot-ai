"""Source-pin: game_helper.gd must not reference the bare `EditorInterface`
identifier, which is compiled out of export templates.

`game_helper.gd` is registered as the `_mcp_game_helper` autoload, so it is
loaded (and parsed) in every game process — including exported release builds.
The bare `EditorInterface` singleton only exists in the editor; it is compiled
out of export templates. A bare reference is rejected by the GDScript parser at
load time in an exported build, even when the reference is guarded at runtime
by `Engine.is_editor_hint()` (the guard never runs because parsing fails first):

    SCRIPT ERROR: Parse Error: Identifier "EditorInterface" not declared in
    the current scope.
       at: GDScript::reload (res://addons/godot_ai/runtime/game_helper.gd:...)
    ERROR: Failed to instantiate an autoload, script 'game_helper.gd' does not
    inherit from 'Node'.

…which stops the autoload from loading in every exported build and cascades
into misleading downstream errors in the user's own scripts. The file's own
header docstring states it "silently sits idle ... (e.g. exported release
builds)", so the bare identifier contradicts the intended behavior.

Fix: reach the singleton by string name so the identifier never reaches the
parser — `Engine.get_singleton(&"EditorInterface")` — then call
`get_edited_scene_root()` on the returned object.
"""

from __future__ import annotations

import re
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
GAME_HELPER = PLUGIN_ROOT / "runtime" / "game_helper.gd"


def test_game_helper_does_not_reference_editor_interface_identifier() -> None:
    """No bare `EditorInterface` reference in code — it breaks export parsing.

    A *bare identifier* reference (`EditorInterface.method(...)` or
    `EditorInterface` used as a value) is what the export-template parser
    rejects. The string-literal form inside `Engine.get_singleton(...)` is
    fine, so the check strips comments and double-quoted strings first.
    """
    source = GAME_HELPER.read_text(encoding="utf-8")
    for lineno, raw in enumerate(source.splitlines(), start=1):
        # Strip GDScript line comments (## or #) so the rationale comment
        # (which names the identifier) doesn't trip this.
        code = raw.split("#", 1)[0]
        # Strip double-quoted strings so the `&"EditorInterface"` string-name
        # argument to Engine.get_singleton(...) is not flagged — only a bare
        # identifier reaches the parser as a symbol.
        code = re.sub(r'"[^"]*"', '""', code)
        assert "EditorInterface" not in code, (
            f"game_helper.gd:{lineno} references the bare `EditorInterface` "
            f"identifier in code: {raw.strip()!r}. This autoload loads in "
            "exported builds, where `EditorInterface` is compiled out and the "
            'parser rejects it. Use `Engine.get_singleton(&"EditorInterface")` '
            "instead — see the rationale in the call site's comment."
        )


def test_game_helper_uses_get_singleton_for_editor_interface() -> None:
    """The export-safe lookup must be present."""
    source = GAME_HELPER.read_text(encoding="utf-8")
    assert 'Engine.get_singleton(&"EditorInterface")' in source, (
        "game_helper.gd must reach the editor singleton via "
        'Engine.get_singleton(&"EditorInterface"). Referencing the bare '
        "`EditorInterface` identifier fails to parse in exported builds, where "
        "the singleton is compiled out of the export template."
    )
