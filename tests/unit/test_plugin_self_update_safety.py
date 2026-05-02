"""Lock the self-update parse-hazard policy on `plugin.gd`.

Issue #242 surfaced as `v2.1.1 → v2.1.2` SIGABRT during in-place self-update:
v2.1.2's `plugin.gd` declared `var _editor_log_buffer: EditorLogBuffer` —
a typed-var against a brand-new `class_name` introduced in the same
release. During `_install_update`'s extract → `set_plugin_enabled(false)`
path the parser hits the typed-var BEFORE the new class_name has been
registered in the global table → `plugin.gd` parse fails → plugin enters
a degraded state → the follow-up `_exit_tree` cascade crashes.

Issue #244 is the defense-in-depth follow-up: any field in `plugin.gd`
that type-binds to a plugin-defined `Mcp*` class is the same latent
hazard. Even if today's inheritance is stable, a future refactor that
changes one class's `extends` chain or adds a sibling class_name file
re-trips the bug — and review won't catch it because the typed
declaration *looks* idiomatic.

The structurally correct answer is "`plugin.gd` does NOT type-bind to
plugin classes". Field types fall through to the runtime parameter
checks at handler `_init` sites that take typed parameters (see e.g.
`McpEditorHandler._init`'s typed `editor_log_buffer: McpEditorLogBuffer`
parameter — the type fence still fires, just at the call site at runtime,
not at `plugin.gd`'s parse).

This test enforces that policy. Adding `var _foo: McpAnything` to
`plugin.gd` will fail here with a paste-over-ready diff so the next
contributor doesn't silently re-introduce the hazard.
"""

from __future__ import annotations

import re
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
PLUGIN_GD = PLUGIN_ROOT / "plugin.gd"


def _registered_mcp_class_names() -> set[str]:
    """Every `class_name McpFoo` declared anywhere in the addon tree."""

    pattern = re.compile(r"^class_name\s+(Mcp\w+)\s*$", re.MULTILINE)
    found: set[str] = set()
    for gd_file in PLUGIN_ROOT.rglob("*.gd"):
        found.update(pattern.findall(gd_file.read_text()))
    return found


def test_plugin_gd_has_no_typed_field_against_plugin_class_names() -> None:
    """`plugin.gd` field declarations must not type-bind to any `Mcp*` class.

    See module docstring for the parse-hazard mechanism. Untype the field;
    keep the type fence on handler `_init` parameters.
    """

    source = PLUGIN_GD.read_text()
    mcp_classes = _registered_mcp_class_names()
    assert mcp_classes, (
        "Sanity check: expected to find Mcp* class_name declarations in the addon tree"
    )

    # Match top-level `var _foo: McpBar` (with or without trailing `=` /
    # ` # comment`). Anchored to start-of-line so we don't catch local
    # vars inside functions, which the parser resolves lazily and which
    # are not part of the parse-time hazard.
    typed_field = re.compile(r"^var\s+(\w+)\s*:\s*(Mcp\w+)\b", re.MULTILINE)
    offenders: list[tuple[str, str]] = []
    for match in typed_field.finditer(source):
        field_name, type_name = match.group(1), match.group(2)
        if type_name in mcp_classes:
            offenders.append((field_name, type_name))

    assert not offenders, (
        "plugin.gd must not declare typed fields against plugin class_names "
        "(self-update parse hazard, issues #242 / #244). Untype the field "
        "and rely on the typed handler `_init` parameters for the type "
        f"fence. Offending declarations: {offenders}"
    )


def test_plugin_gd_documents_the_untyped_policy() -> None:
    """The policy comment must stay near the field declarations.

    A future contributor must understand WHY the fields are untyped or
    they will "fix" the apparent oversight by re-typing them and re-
    introduce the hazard.
    """

    source = PLUGIN_GD.read_text()
    assert "Self-update parse-hazard policy" in source, (
        "plugin.gd must keep an explanatory comment near the untyped "
        "field declarations referencing the parse-hazard policy. Without "
        "it, the next contributor will type-bind a field and re-introduce "
        "issue #242."
    )
    assert "#242" in source and "#244" in source, (
        "The policy comment must reference issues #242 and #244 so "
        "future readers can find the full context."
    )
