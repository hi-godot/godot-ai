"""Lock the self-update parse-hazard policy on targeted plugin-load scripts.

Issue #242 surfaced as `v2.1.1 → v2.1.2` SIGABRT during in-place self-update:
v2.1.2's `plugin.gd` declared `var _editor_log_buffer: EditorLogBuffer` —
a typed-var against a brand-new `class_name` introduced in the same
release. During `_install_update`'s extract → `set_plugin_enabled(false)`
path the parser hits the typed-var BEFORE the new class_name has been
registered in the global table → `plugin.gd` parse fails → plugin enters
a degraded state → the follow-up `_exit_tree` cascade crashes.

Issue #244 is the defense-in-depth follow-up: any name reference from
plugin load-path code to a plugin-defined `Mcp*` class is the same
latent hazard. The hazard has three syntactic forms, all of which
resolve through the global class_name registry at parse time:

    var x: McpFoo                  # typed-var
    McpFoo.new()                   # constructor
    McpFoo.SOME_CONST              # constant / static-method access

The third form is especially risky in a static-var initializer:
`static var _x := McpFoo.BAR` runs at script-load, so a failed lookup
aborts the parse before `_enter_tree` runs and surfaces as Godot's
"Unable to load addon script" warning. Even if today's inheritance is
stable, a future refactor that changes one class's `extends` chain or
adds a sibling class_name file re-trips the bug — and review won't
catch it because the named references *look* idiomatic.

The structurally correct answer is "plugin load-path code does NOT name
plugin classes directly." Field types fall through to the runtime
parameter checks at handler `_init` sites that take typed parameters
(see e.g. `McpEditorHandler._init`'s typed
`editor_log_buffer: McpEditorLogBuffer` parameter — the type fence still
fires, just at the call site at runtime, not at `plugin.gd`'s parse).
Constructors, constants, and static methods go through script-local
`const X := preload("res://...")` aliases (e.g. `Connection`,
`Dispatcher`, `LogBuffer`, `ClientConfigurator`,
`WindowsPortReservation`); `preload(...)` resolves the script by path
at script-load and never consults the registry.

This test enforces the existing typed-var / constructor policy on
`plugin.gd`, and the new constructor / member-access policy on the
targeted beta load surface touched by the PR #309 adaptation. It does
not claim the full transitive `plugin.gd` preload graph is clean yet;
that broader cleanup belongs with the ongoing #297 decomposition work.
Offenders fail with a paste-over-ready list.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = REPO_ROOT / "plugin" / "addons" / "godot_ai"
PLUGIN_GD = PLUGIN_ROOT / "plugin.gd"

# Beta #297 moved plugin-owned startup/update work into these scripts.
# This is intentionally the targeted PR #309 adaptation surface plus the
# PR 9 depth-1 infrastructure follow-up, not a broad cleanup of every
# direct/transitive preload such as handlers or client strategy scripts.
TARGETED_LOAD_SURFACE_FILES = (
    PLUGIN_GD,
    PLUGIN_ROOT / "utils" / "server_lifecycle.gd",
    PLUGIN_ROOT / "utils" / "port_resolver.gd",
    PLUGIN_ROOT / "utils" / "update_manager.gd",
    PLUGIN_ROOT / "connection.gd",
    PLUGIN_ROOT / "dispatcher.gd",
    PLUGIN_ROOT / "mcp_dock.gd",
    PLUGIN_ROOT / "client_configurator.gd",
)


def _registered_mcp_class_names() -> set[str]:
    """Every `class_name McpFoo` declared anywhere in the addon tree."""

    pattern = re.compile(r"^class_name\s+(Mcp\w+)\s*$", re.MULTILINE)
    found: set[str] = set()
    for gd_file in PLUGIN_ROOT.rglob("*.gd"):
        found.update(pattern.findall(gd_file.read_text()))
    return found


def _strip_gdscript_comments(source: str) -> str:
    """Remove `## ...` doc comments and `# ...` line comments.

    The parse hazard only fires for executable references; comments that
    happen to mention `McpConnection` or include `class_name McpFoo` in
    explanatory prose are not parsed as identifiers and must not trip the
    lint. Anchored on `#` start so we don't break legitimate code that
    happens to contain a `#` inside a string literal — `plugin.gd` has
    none today, and adding one would already be a code-smell worth
    flagging.
    """

    return re.sub(r"#.*$", "", source, flags=re.MULTILINE)


def test_targeted_load_scripts_have_no_typed_fields_against_plugin_class_names() -> None:
    """Targeted load-path field declarations must not type-bind to `Mcp*`.

    See module docstring for the parse-hazard mechanism. Untype the field;
    keep the type fence on handler `_init` parameters.
    """

    mcp_classes = _registered_mcp_class_names()
    assert mcp_classes, (
        "Sanity check: expected to find Mcp* class_name declarations in the addon tree"
    )

    # Match top-level `var _foo: McpBar` (with or without trailing `=` /
    # ` # comment`). Anchored to start-of-line so we don't catch local
    # vars inside functions, which the parser resolves lazily and which
    # are not part of the parse-time hazard.
    typed_field = re.compile(r"^var\s+(\w+)\s*:\s*(Mcp\w+)\b", re.MULTILINE)
    offenders: list[str] = []

    for gd_file in TARGETED_LOAD_SURFACE_FILES:
        source = _strip_gdscript_comments(gd_file.read_text())
        for match in typed_field.finditer(source):
            field_name, type_name = match.group(1), match.group(2)
            if type_name not in mcp_classes:
                continue
            line_no = source.count("\n", 0, match.start()) + 1
            rel_path = gd_file.relative_to(REPO_ROOT)
            offenders.append(f"{rel_path}:{line_no}: var {field_name}: {type_name}")

    assert not offenders, (
        "Targeted load-path scripts must not declare typed fields against plugin class_names "
        "(self-update parse hazard, issues #242 / #244). Untype the field "
        "and rely on the typed handler `_init` parameters for the type "
        f"fence. Offending declarations: {offenders}"
    )


def test_plugin_gd_does_not_construct_via_class_name() -> None:
    """`plugin.gd` must not call `McpFoo.new(...)` on any plugin class.

    Constructor references resolve through the global class_name
    registry at parse time, so they participate in the same self-update
    parse hazard as typed-var declarations (#242 / #244). Use a script-
    local `const Foo := preload("res://addons/godot_ai/...")` alias
    declared at the top of `plugin.gd` and call `Foo.new(...)` instead.
    """

    source = _strip_gdscript_comments(PLUGIN_GD.read_text())
    mcp_classes = _registered_mcp_class_names()

    constructor = re.compile(r"\b(Mcp\w+)\.new\s*\(")
    offenders: list[str] = []
    for match in constructor.finditer(source):
        type_name = match.group(1)
        if type_name in mcp_classes:
            offenders.append(type_name)

    assert not offenders, (
        "plugin.gd must not invoke plugin-class constructors by class_name "
        "(self-update parse hazard, issues #242 / #244). Add a script-local "
        '`const Foo := preload("res://addons/godot_ai/...")` alias at the '
        "top of plugin.gd and call `Foo.new(...)` instead. Offending "
        f"references: {sorted(set(offenders))}"
    )


def test_targeted_load_scripts_do_not_construct_via_class_name() -> None:
    """Targeted load-path scripts must not call `McpFoo.new(...)`.

    The existing constructor test predates the beta #297 extractions and
    only scans `plugin.gd`. Keep the same guard on the manager scripts
    this PR touches so future changes do not reintroduce constructor
    lookups into the targeted startup/update surface.
    """

    mcp_classes = _registered_mcp_class_names()
    constructor = re.compile(r"\b(Mcp\w+)\.new\s*\(")
    offenders: list[str] = []

    for gd_file in TARGETED_LOAD_SURFACE_FILES:
        source = _strip_gdscript_comments(gd_file.read_text())
        for match in constructor.finditer(source):
            type_name = match.group(1)
            if type_name not in mcp_classes:
                continue
            line_no = source.count("\n", 0, match.start()) + 1
            rel_path = gd_file.relative_to(REPO_ROOT)
            offenders.append(f"{rel_path}:{line_no}: {type_name}.new")

    assert not offenders, (
        "Targeted load-path scripts must not invoke plugin-class "
        "constructors by class_name (self-update parse hazard, issues "
        "#242 / #244). Add a script-local "
        '`const Foo := preload("res://addons/godot_ai/...")` alias and '
        "call `Foo.new(...)` instead. Offending references: "
        f"{sorted(set(offenders))}"
    )


def test_targeted_load_scripts_do_not_access_members_via_class_name() -> None:
    """Targeted load-path scripts must not access `McpFoo.X` directly.

    This is the third syntactic form of the parse hazard. Identifier
    resolution for `McpFoo` happens at parse time even when only its
    members are used, so `McpFoo.SOME_CONST` and
    `McpFoo.static_method()` must route through script-local
    `preload(...)` aliases. `McpFoo.new()` is skipped here because the
    targeted constructor test owns that offender list.
    """

    mcp_classes = _registered_mcp_class_names()
    member_access = re.compile(r"\b(Mcp\w+)\.(\w+)")
    offenders: list[str] = []

    for gd_file in TARGETED_LOAD_SURFACE_FILES:
        source = _strip_gdscript_comments(gd_file.read_text())
        for match in member_access.finditer(source):
            type_name, member = match.group(1), match.group(2)
            if type_name not in mcp_classes:
                continue
            if member == "new":
                continue
            line_no = source.count("\n", 0, match.start()) + 1
            rel_path = gd_file.relative_to(REPO_ROOT)
            offenders.append(f"{rel_path}:{line_no}: {type_name}.{member}")

    assert not offenders, (
        "Targeted load-path scripts must not access plugin-class "
        "constants or static methods via class_name (self-update parse "
        "hazard, issues #242 / #244). Static-var initializers are the "
        "most dangerous form: a failed lookup aborts the parse before "
        "_enter_tree. Add a "
        'script-local `const Foo := preload("res://addons/godot_ai/...")` '
        "alias and call `Foo.X` instead. Offending references: "
        f"{sorted(set(offenders))}"
    )


def test_plugin_gd_documents_the_untyped_policy() -> None:
    """The policy comment must stay near the field declarations.

    A future contributor must understand WHY the fields are untyped and
    why constructors/constants/static methods go through preload-aliased
    consts, or they will "fix" the apparent oversight and re-introduce
    the hazard.
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
    assert "preload" in source.lower(), (
        "The policy comment must explain that direct references go through "
        "preload-aliased consts — without that half, a future contributor "
        "may untype a field but still write `McpFoo.new()` or "
        "`McpFoo.CONST`, leaving the parse-time class_name lookup in place."
    )
    assert "static-var" in source.lower() or "static var" in source.lower(), (
        "The policy comment must call out static-var initializers as the "
        "worst case, so a future contributor doesn't add "
        "`static var _x := McpFoo.BAR` and reproduce the load-time parse "
        "failure."
    )
