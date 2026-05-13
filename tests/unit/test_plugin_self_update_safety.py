"""Source-structure pins for self-update safety comments and constants.

The old deny-by-default syntactic parse-hazard ratchet was removed because
it measured call shape (`Mcp*.MEMBER` vs preload aliases), not the bug that
actually caused the transient parse errors. The regression gate is now the
runner's single-phase write-before-scan behavior plus the upgrade-path test.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = REPO_ROOT / "plugin" / "addons" / "godot_ai"
PLUGIN_GD = PLUGIN_ROOT / "plugin.gd"


def test_update_backup_suffix_stays_in_sync() -> None:
    """Build-time anti-drift guard for `update_mixed_state.gd::BACKUP_SUFFIX`."""
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
        "string literal. Old two-phase runners can parse this diagnostic script "
        "against stale Script-object content during upgrade; keeping the suffix "
        "inline avoids making that diagnostic depend on a same-release runner "
        "constant."
    )

    assert runner_match.group(1) == scanner_match.group(1), (
        "update_mixed_state.gd::BACKUP_SUFFIX "
        f"({scanner_match.group(1)!r}) drifted from the producer "
        f"update_reload_runner.gd::INSTALL_BACKUP_SUFFIX "
        f"({runner_match.group(1)!r}). Update both literals in lockstep -- they "
        "describe the same on-disk suffix."
    )


def test_plugin_gd_documents_the_untyped_policy() -> None:
    """The policy comment must stay near the field declarations.

    A future contributor must understand why long-lived plugin fields stay
    untyped during self-update, without reviving the old claim that preload
    aliases are the parse-safety fix.
    """
    source = PLUGIN_GD.read_text(encoding="utf-8")
    normalized = " ".join(line.strip("# \t") for line in source.splitlines())
    assert "Self-update field and load-surface policy" in source, (
        "plugin.gd must keep an explanatory comment near the untyped "
        "field declarations. Without it, the next contributor may type-bind "
        "a field and re-introduce issue #242."
    )
    assert "#242" in source and "#244" in source and "#398" in source, (
        "The policy comment must reference the historical issues so "
        "future readers can find the full context."
    )
    assert "single-phase runner" in source, (
        "The policy comment must identify the runner's single-phase "
        "write-before-scan model as the #398 fix."
    )
    assert "preload aliases are not the self-update safety metric" in normalized, (
        "The policy must not claim path-preload aliasing avoids the parser "
        "or registry. The corrected model is stale Script-object content "
        "from mixed old/new snapshots."
    )
    assert "static-var" in source.lower() or "static var" in source.lower(), (
        "The policy comment must call out static-var initializers as the "
        "worst typed-storage case, so a future contributor does not add "
        "a top-level static Dictionary/Array field and reproduce the "
        "load-time hot-reload failure."
    )
