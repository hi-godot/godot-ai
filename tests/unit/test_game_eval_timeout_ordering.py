"""Contract tests: the game_eval/game_command timeout ladders stay ordered.

The timeout contracts span several files with no shared constant across the
Python/GDScript boundary, so this test scrapes each source of truth and enforces
both ladders:

    game (8s) < editor (10s)
    liveness (0.25s) + editor (10s) < dispatcher (15s)
    ready-wait (3s) + liveness + editor < dispatcher == server (15s)
    run-ready (3s) + game-command editor (10s) < dispatcher == server (15s)

- **game**: ``game_helper.gd::EVAL_TIMEOUT_SEC`` — the only tier that can
  name the hung await ("Eval exceeded 8s"). If it rises to/above the editor
  timer, the less specific editor message wins the race and the diagnostic
  is silently lost (#487/#518).
- **editor**: ``mcp_debugger_plugin.gd`` ``timeout_sec`` defaults on the
  ``request_game_eval`` and ``request_game_command`` entry points.
- **ready-waits**: ``mcp_debugger_plugin.gd::EVAL_READY_WAIT_SEC`` for eval
  and ``project_handler.gd::RUN_READY_WAIT_SEC`` for the run path.
- **dispatcher/server**: ``dispatcher.gd::DEFERRED_TIMEOUT_MS_BY_COMMAND``
  plus the Python handler budgets — the outermost layers; if either undercuts
  the inner tiers, the deferred reply is dropped as expired and the actionable
  message never reaches the agent.

Source-scraping pattern per test_dock_cli_timeout.py /
test_deferred_timeout_contract.py.
"""

from __future__ import annotations

import re
from pathlib import Path

from godot_ai.handlers.game import GAME_COMMAND_TIMEOUT_SEC

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = REPO_ROOT / "plugin" / "addons" / "godot_ai"


def _scrape_float(path: Path, pattern: str) -> float:
    source = path.read_text(encoding="utf-8")
    match = re.search(pattern, source, re.MULTILINE)
    assert match, f"pattern {pattern!r} not found in {path}"
    return float(match.group(1))


def _game_timeout_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "runtime" / "game_helper.gd",
        r"^const EVAL_TIMEOUT_SEC := ([0-9.]+)",
    )


def _editor_eval_timeout_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "debugger" / "mcp_debugger_plugin.gd",
        r"^func request_game_eval\([\s\S]*?^\ttimeout_sec: float = ([0-9.]+),",
    )


def _editor_game_command_timeout_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "debugger" / "mcp_debugger_plugin.gd",
        r"^func request_game_command\([\s\S]*?^\ttimeout_sec: float = ([0-9.]+),",
    )


def _ready_wait_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "debugger" / "mcp_debugger_plugin.gd",
        r"^const EVAL_READY_WAIT_SEC := ([0-9.]+)",
    )


def _run_ready_wait_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "handlers" / "project_handler.gd",
        r"^const RUN_READY_WAIT_SEC := ([0-9.]+)",
    )


def _eval_liveness_wait_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "debugger" / "mcp_debugger_plugin.gd",
        r"^const EVAL_LIVENESS_WAIT_SEC := ([0-9.]+)",
    )


def _dispatcher_budget_secs() -> dict[str, float]:
    source = (PLUGIN_ROOT / "dispatcher.gd").read_text(encoding="utf-8")
    budgets = {
        name: int(ms) / 1000.0
        for name, ms in re.findall(r'"(game_eval|game_command)":\s*(\d+)', source)
    }
    assert set(budgets) == {"game_eval", "game_command"}, (
        f"expected both game_* entries in DEFERRED_TIMEOUT_MS_BY_COMMAND, got {budgets}"
    )
    return budgets


def _server_eval_timeout_sec() -> float:
    return _scrape_float(
        REPO_ROOT / "src" / "godot_ai" / "handlers" / "editor.py",
        r"^async def game_eval\([\s\S]*?timeout=([0-9.]+)\)",
    )


def test_game_guard_stays_below_editor_fallback() -> None:
    game = _game_timeout_sec()
    editor = _editor_eval_timeout_sec()
    assert game < editor, (
        f"game EVAL_TIMEOUT_SEC ({game}s) must stay below the editor "
        f"fallback ({editor}s) or the specific 'Eval exceeded' "
        f"diagnostic loses the race to the generic editor message"
    )


def test_eval_liveness_probe_stays_sub_half_second() -> None:
    assert _eval_liveness_wait_sec() < 0.5, (
        "the #859 pre-dispatch liveness probe must fail non-live game_eval "
        "calls inside the telemetry target of 0.5s"
    )


def test_editor_fallback_stays_below_dispatcher_budget() -> None:
    stacked = _eval_liveness_wait_sec() + _editor_eval_timeout_sec()
    budget = _dispatcher_budget_secs()["game_eval"]
    assert stacked < budget, (
        f"liveness probe + editor fallback ({stacked}s) must stay below the "
        f"game_eval dispatcher budget ({budget}s) or the deferred reply is "
        "dropped as expired before the editor can answer"
    )


def test_ready_wait_plus_editor_stays_below_dispatcher_budget() -> None:
    stacked = _ready_wait_sec() + _eval_liveness_wait_sec() + _editor_eval_timeout_sec()
    budget = _dispatcher_budget_secs()["game_eval"]
    assert stacked < budget, (
        f"ready wait + liveness probe + editor fallback ({stacked}s) must stay "
        f"below the game_eval dispatcher budget ({budget}s)"
    )


def test_game_command_editor_fallback_stays_below_dispatcher_budgets() -> None:
    editor = _editor_game_command_timeout_sec()
    for name, budget in _dispatcher_budget_secs().items():
        assert editor < budget, (
            f"game_command editor fallback ({editor}s) must stay below the "
            f"dispatcher's {name} budget ({budget}s) or the deferred reply is "
            "dropped as expired before the editor can answer"
        )


def test_run_ready_wait_plus_game_command_stays_below_dispatcher_budgets() -> None:
    stacked = _run_ready_wait_sec() + _editor_game_command_timeout_sec()
    for name, budget in _dispatcher_budget_secs().items():
        assert stacked < budget, (
            f"RUN_READY_WAIT_SEC + game_command editor fallback ({stacked}s) "
            f"must stay below the dispatcher's {name} budget ({budget}s)"
        )


def test_eval_server_timeout_covers_dispatcher_budget() -> None:
    server = _server_eval_timeout_sec()
    dispatcher = _dispatcher_budget_secs()["game_eval"]
    assert server >= dispatcher, (
        f"server game_eval timeout ({server}s) must not undercut the dispatcher "
        f"budget ({dispatcher}s) — the server would time out first and "
        "misattribute the failure"
    )


def test_game_command_server_timeout_covers_dispatcher_budgets() -> None:
    for name, budget in _dispatcher_budget_secs().items():
        assert GAME_COMMAND_TIMEOUT_SEC >= budget, (
            f"server GAME_COMMAND_TIMEOUT_SEC ({GAME_COMMAND_TIMEOUT_SEC}s) "
            f"must not undercut the dispatcher's {name} budget ({budget}s) — "
            "the server would time out first and misattribute the failure"
        )
