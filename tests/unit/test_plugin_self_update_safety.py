"""Lock the self-update parse-hazard policy across the plugin load surface.

Issue #242 surfaced as `v2.1.1 -> v2.1.2` SIGABRT during in-place
self-update: v2.1.2's `plugin.gd` declared `var _editor_log_buffer:
EditorLogBuffer` -- a typed-var against a brand-new `class_name`
introduced in the same release. During `_install_update`'s extract ->
`set_plugin_enabled(false)` path the parser hits the typed-var BEFORE the
new class_name has been registered in the global table -> `plugin.gd`
parse fails -> plugin enters a degraded state -> the follow-up
`_exit_tree` cascade crashes.

Issue #244 is the defense-in-depth follow-up: any name reference from
plugin load-path code to a plugin-defined `Mcp*` class is the same latent
hazard. The hazard has four syntactic forms, all of which resolve through
the global class_name registry at parse time:

    var x: McpFoo                  # typed-var (top-level field)
    func f(x: McpFoo):             # typed-parameter
    McpFoo.new()                   # constructor
    McpFoo.SOME_CONST              # constant access
    McpFoo.some_method(...)        # static-method access

The constant/method form is especially risky in a static-var initializer:
`static var _x := McpFoo.BAR` runs at script-load, so a failed lookup
aborts the parse before `_enter_tree` runs and surfaces as Godot's
"Unable to load addon script" warning.

The structurally correct answer is "plugin load-path code does NOT name
plugin classes directly." Field types fall through to the runtime
parameter checks at handler `_init` sites that take typed parameters
(see e.g. `McpEditorHandler._init`'s typed
`editor_log_buffer: McpEditorLogBuffer` parameter -- the type fence still
fires, just at the call site at runtime, not at `plugin.gd`'s parse).
Constructors, constants, and static methods go through script-local
`const X := preload("res://...")` aliases (e.g. `Connection`,
`Dispatcher`, `LogBuffer`); `preload(...)` resolves the script by path at
script-load and never consults the registry.

## Enforcement (#399)

A single deny-by-default scan over every `.gd` under the addon tree
minus `OFF_LOAD_SURFACE`. The violation count is ratcheted via
`BASELINE_VIOLATION_COUNT`: regressions raise it (test fails with
offender list); fixes lower it (test fails until the constant is
updated, so improvements lock in). End state is 0.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Literal

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = REPO_ROOT / "plugin" / "addons" / "godot_ai"
PLUGIN_GD = PLUGIN_ROOT / "plugin.gd"

# The five `.gd` files that are genuinely off the self-update load
# surface, per the #399 audit. Each is either game-side (runs in the
# game subprocess, not the editor process where self-update happens) or
# test-only (loaded by the test runner, not by `plugin.gd`'s preload
# graph). Bare `Mcp*` references in these files cannot trip the
# self-update parse hazard because their parse never overlaps the
# disable -> extract -> enable window in the editor.
#
# Keep this list short and stable -- it is the single deny-by-default
# escape hatch. Any new entry needs a concrete justification (the file
# is provably outside the editor-process load graph) and a comment
# below recording why.
OFF_LOAD_SURFACE = frozenset(
    {
        # Game subprocess: spawned by play-in-editor, parsed by the game
        # binary, not the editor's plugin loader.
        "runtime/editor_logger.gd",
        "runtime/game_helper.gd",
        "runtime/game_logger.gd",
        # Test-only: loaded by the GDScript test runner, never by
        # plugin.gd's preload graph or the global class_name registry
        # consulted at editor parse time.
        "testing/stub_backtrace.gd",
        "utils/log_backtrace.gd",
    }
)

# Ratchet target for the deny-by-default scan. Recorded against
# `origin/beta` at the time #399 Step 1 landed. Lower this when fixes
# land; raising it requires explicit justification and is the signal
# that a regression slipped through review.
#
# End state: 0. Steps 2 and 3 of #399 drive this down.
BASELINE_VIOLATION_COUNT = 1254


Kind = Literal["typed_field", "typed_annotation", "constructor", "member_access"]

_CLASS_NAME_RE = re.compile(r"^class_name\s+(Mcp\w+)\s*$", re.MULTILINE)
# Top-level typed-var fields: `(static )?var name: McpFoo` at column 0.
# Indented `var` declarations inside function bodies are still flagged
# by `_TYPED_ANNOTATION_RE` below; this pass is the dedicated counter
# for top-level fields specifically (the worst case, since they parse
# at script-load).
_TYPED_FIELD_RE = re.compile(r"^(?:static\s+)?var\s+\w+\s*:\s*(Mcp\w+)\b", re.MULTILINE)
# Any `name: McpFoo` annotation (parameters, typed locals, indented
# fields, return types). Intentionally overlaps `_TYPED_FIELD_RE` for
# top-level fields so a single offender counts in both buckets --
# matches the original audit's accounting and keeps the baseline a
# stable reproducible number.
_TYPED_ANNOTATION_RE = re.compile(r"\b\w+\s*:\s*(Mcp\w+)\b")
_CONSTRUCTOR_RE = re.compile(r"\b(Mcp\w+)\s*\.\s*new\s*\(")
# Any identifier after `Mcp*.`. `Mcp*.method()` hits the same
# parse-time class_name lookup as `Mcp*.CONST`. `.new` matches the
# constructor pattern above and is filtered out so single sites
# don't double-count.
_MEMBER_ACCESS_RE = re.compile(r"\b(Mcp\w+)\s*\.\s*(\w+)\b")

_PASSES: tuple[tuple[re.Pattern[str], Kind], ...] = (
    (_TYPED_FIELD_RE, "typed_field"),
    (_TYPED_ANNOTATION_RE, "typed_annotation"),
    (_CONSTRUCTOR_RE, "constructor"),
    (_MEMBER_ACCESS_RE, "member_access"),
)


def _strip_gdscript_comments(source: str) -> str:
    """Remove `# ...` line comments while preserving string literals.

    A naive `re.sub(r"#.*$", ...)` truncates lines like
    `remainder.begins_with("#")`, which can shift the violation count
    when an offender appears later on the same line. This walks
    character by character, recognising GDScript single, triple, and
    prefixed (raw `r`, StringName `&`, NodePath `^`) string forms, and
    only treats `#` as a comment when outside a string. Newlines are
    preserved so line numbers in offender messages stay accurate.
    """
    out: list[str] = []
    n = len(source)
    i = 0
    while i < n:
        c = source[i]
        if c == "#":
            while i < n and source[i] != "\n":
                i += 1
            continue
        prefix_len = 0
        if c in ("r", "&", "^") and i + 1 < n and source[i + 1] in ('"', "'"):
            prefix_len = 1
        q_start = i + prefix_len
        if q_start < n and source[q_start] in ('"', "'"):
            q = source[q_start]
            if source[q_start : q_start + 3] == q * 3:
                end = source.find(q * 3, q_start + 3)
                end = (end + 3) if end != -1 else n
            else:
                j = q_start + 1
                while j < n:
                    ch = source[j]
                    if ch == "\\":
                        j += 2
                        continue
                    if ch == q:
                        j += 1
                        break
                    if ch == "\n":
                        break  # unterminated string; bail without crashing
                    j += 1
                end = j
            out.append(source[i:end])
            i = end
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _format_ident(kind: Kind, match: re.Match[str]) -> str | None:
    """Render an offender's identifier, or None to skip the match."""
    name = match.group(1)
    if kind == "typed_field":
        return f"var: {name}"
    if kind == "typed_annotation":
        return f": {name}"
    if kind == "constructor":
        return f"{name}.new"
    member = match.group(2)
    if member == "new":
        return None  # owned by the constructor pass
    return f"{name}.{member}"


def _scan_load_surface() -> tuple[set[str], list[tuple[Path, int, Kind, str]]]:
    """Walk the load surface in one pass.

    Returns the set of `Mcp*` class names declared anywhere in the addon
    tree (for sanity-check assertions) and the list of offending sites
    across the load surface. A file's own `class_name` is excluded from
    in-scope lookups, since a class can safely reference its own
    constants and static methods.
    """
    registered: set[str] = set()
    surface_sources: list[tuple[Path, str, set[str]]] = []

    for gd in sorted(PLUGIN_ROOT.rglob("*.gd")):
        raw = gd.read_text(encoding="utf-8")
        own = set(_CLASS_NAME_RE.findall(raw))
        registered |= own
        if gd.relative_to(PLUGIN_ROOT).as_posix() in OFF_LOAD_SURFACE:
            continue
        surface_sources.append((gd, _strip_gdscript_comments(raw), own))

    offenders: list[tuple[Path, int, Kind, str]] = []
    for path, src, own in surface_sources:
        in_scope = registered - own
        for pattern, kind in _PASSES:
            for match in pattern.finditer(src):
                if match.group(1) not in in_scope:
                    continue
                ident = _format_ident(kind, match)
                if ident is None:
                    continue
                line_no = src.count("\n", 0, match.start()) + 1
                offenders.append((path, line_no, kind, ident))

    return registered, offenders


def test_self_update_parse_hazard_baseline_ratchet() -> None:
    """Deny-by-default lint of the self-update load surface (#399).

    Scans every `.gd` under `plugin/addons/godot_ai/` (minus
    `OFF_LOAD_SURFACE`) for the four syntactic forms of the
    parse-hazard: typed-var, typed-param, `Mcp*.new(...)`, and
    `Mcp*.<identifier>` member access. Total violations must be
    `<= BASELINE_VIOLATION_COUNT`.

    When the count rises, the failure prints a paste-over-ready offender
    list -- the regression is somewhere in those new lines.

    When the count drops, the failure asks the developer to lower
    `BASELINE_VIOLATION_COUNT` to the new value. This is the ratchet:
    fixes get locked in so they cannot silently regress later.

    End state: `BASELINE_VIOLATION_COUNT == 0`.
    """
    registered, all_offenders = _scan_load_surface()
    assert registered, (
        "Sanity check: expected to find Mcp* class_name declarations in the addon tree"
    )

    total = len(all_offenders)

    if total > BASELINE_VIOLATION_COUNT:
        all_offenders.sort(key=lambda t: (t[0].relative_to(REPO_ROOT).as_posix(), t[1]))
        lines = [
            f"  {p.relative_to(REPO_ROOT).as_posix()}:{ln}: {kind}: {ident}"
            for p, ln, kind, ident in all_offenders
        ]
        listing = "\n".join(lines)
        raise AssertionError(
            f"Self-update parse-hazard violations regressed: {total} sites "
            f"(baseline {BASELINE_VIOLATION_COUNT}). New bare `Mcp*` "
            "references slipped into the addon load surface. Either route "
            "the reference through a script-local `const X := preload("
            '"res://addons/godot_ai/...")` alias, or (only if the file is '
            "provably off the editor-process load graph) add it to "
            "OFF_LOAD_SURFACE with justification.\n\n"
            "Issues: #242 / #244 / #399.\n\n"
            f"All {total} offending sites:\n{listing}"
        )

    if total < BASELINE_VIOLATION_COUNT:
        raise AssertionError(
            "Self-update parse-hazard violation count dropped from "
            f"{BASELINE_VIOLATION_COUNT} to {total}. Lower "
            "BASELINE_VIOLATION_COUNT in this file to "
            f"{total} to lock in the improvement -- otherwise the next "
            "regression that re-adds these sites will pass under the "
            "old baseline. End state is 0; we ratchet there one PR at a "
            "time (#399 Step 2 onward)."
        )


def test_update_backup_suffix_stays_in_sync() -> None:
    """Build-time anti-drift guard for `update_mixed_state.gd::BACKUP_SUFFIX`.

    Replaces the runtime alias removed for #398 -- see
    `update_mixed_state.gd`.
    """
    runner = (PLUGIN_ROOT / "update_reload_runner.gd").read_text(encoding="utf-8")
    scanner = (PLUGIN_ROOT / "utils" / "update_mixed_state.gd").read_text(encoding="utf-8")

    runner_match = re.search(
        r'^const\s+INSTALL_BACKUP_SUFFIX\s*:=\s*"([^"]+)"',
        runner,
        re.MULTILINE,
    )
    assert runner_match, (
        'update_reload_runner.gd must declare `const INSTALL_BACKUP_SUFFIX := "..."` '
        "as the authoritative producer of the backup-file suffix."
    )

    scanner_match = re.search(
        r'^const\s+BACKUP_SUFFIX\s*:=\s*"([^"]+)"',
        scanner,
        re.MULTILINE,
    )
    assert scanner_match, (
        'update_mixed_state.gd must declare `const BACKUP_SUFFIX := "..."` as a '
        "string literal -- aliasing via `UpdateReloadRunner.INSTALL_BACKUP_SUFFIX` "
        "re-introduces the self-update parse hazard (issue #398)."
    )

    assert runner_match.group(1) == scanner_match.group(1), (
        "update_mixed_state.gd::BACKUP_SUFFIX "
        f"({scanner_match.group(1)!r}) drifted from the producer "
        f"update_reload_runner.gd::INSTALL_BACKUP_SUFFIX "
        f"({runner_match.group(1)!r}). Update both literals in lockstep -- they "
        "describe the same on-disk suffix, but the scanner's value is inlined "
        "to avoid the parse hazard fixed in #398."
    )


def test_plugin_gd_documents_the_untyped_policy() -> None:
    """The policy comment must stay near the field declarations.

    A future contributor must understand WHY the fields are untyped and
    why constructors/constants/static methods go through preload-aliased
    consts, or they will "fix" the apparent oversight and re-introduce
    the hazard.
    """
    source = PLUGIN_GD.read_text(encoding="utf-8")
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
        "preload-aliased consts -- without that half, a future contributor "
        "may untype a field but still write `McpFoo.new()` or "
        "`McpFoo.CONST`, leaving the parse-time class_name lookup in place."
    )
    assert "static-var" in source.lower() or "static var" in source.lower(), (
        "The policy comment must call out static-var initializers as the "
        "worst case, so a future contributor doesn't add "
        "`static var _x := McpFoo.BAR` and reproduce the load-time parse "
        "failure."
    )
