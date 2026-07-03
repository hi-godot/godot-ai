"""Source-pin: game_logger.gd must not depend on the McpLogBacktrace
class_name being globally registered.

A freshly-launched game subprocess (no prior editor scan; e.g. CI launching
`--headless --path` on a fresh worktree) hits the `game_helper.gd` autoload
before the global class_name table is populated. If `game_logger.gd`
references `McpLogBacktrace.resolve_error(...)` by its class_name, parsing
that script fails with:

    SCRIPT ERROR: Parse Error: Identifier "McpLogBacktrace" not declared in
    the current scope.
    at: GDScript::reload (res://addons/godot_ai/runtime/game_logger.gd:44)

…and the entire game-side log-bridge fails to load. This breaks `print()`
/ `printerr()` ferrying back to the editor for any user whose first launch
of the project is headless (CI, fleet smoke).

Fix: `const _LogBacktrace := preload("res://addons/godot_ai/utils/log_backtrace.gd")`
in game_logger.gd, then call `_LogBacktrace.resolve_error(...)`. The path is
resolved at parse time and is independent of the class_name registry.
"""

from __future__ import annotations

from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
GAME_LOGGER = PLUGIN_ROOT / "runtime" / "game_logger.gd"


def test_game_logger_preloads_log_backtrace_by_path() -> None:
    """The script must `const preload` log_backtrace.gd."""
    source = GAME_LOGGER.read_text(encoding="utf-8")
    assert 'preload("res://addons/godot_ai/utils/log_backtrace.gd")' in source, (
        "game_logger.gd must `const`-preload log_backtrace.gd by path. "
        "Relying on the McpLogBacktrace class_name fails when this script "
        "is parsed in a game subprocess before the global class_name table "
        "is populated (fresh-project headless launch)."
    )


def test_game_logger_does_not_reference_log_backtrace_class_name() -> None:
    """No `McpLogBacktrace.` call sites — those re-introduce the bug."""
    source = GAME_LOGGER.read_text(encoding="utf-8")
    # Comments referencing the class name are fine (and the comment above the
    # preload const explains the rationale). Code references — anywhere a
    # `McpLogBacktrace.` method call could land — are not.
    for lineno, raw in enumerate(source.splitlines(), start=1):
        # Strip GDScript line comments (## or #) before the check so the
        # rationale comment doesn't trip this assertion.
        code = raw.split("#", 1)[0]
        assert "McpLogBacktrace." not in code, (
            f"game_logger.gd:{lineno} references `McpLogBacktrace.` in code: "
            f"{raw.strip()!r}. Use the `_LogBacktrace` preload const instead — "
            "see the rationale in the file's header comment."
        )
