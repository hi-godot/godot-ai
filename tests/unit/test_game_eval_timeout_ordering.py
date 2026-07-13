"""Contract test: the game_eval/game_command timeout ladder stays ordered.

The four-tier timeout contract spans four files and, by its own admission
(game_helper.gd's "TIMEOUT ORDERING — load-bearing across three files ...
Nothing enforces the order — change one, re-check the other two"), had no
enforcement. The ladder:

    game (8s)  <  editor (10s)  <  ready-wait + editor (3+10s)  <  dispatcher (15s) == server (15s)

- **game**: ``game_helper.gd::EVAL_TIMEOUT_SEC`` — the only tier that can
  name the hung await ("Eval exceeded 8s"). If it rises to/above the editor
  timer, the less specific editor message wins the race and the diagnostic
  is silently lost (#487/#518).
- **editor**: ``mcp_debugger_plugin.gd`` ``timeout_sec`` defaults on the
  request_game_* entry points.
- **ready-wait**: ``project_handler.gd::RUN_READY_WAIT_SEC`` — stacked on
  top of the editor timer on the run path; the sum must still beat the
  dispatcher budget.
- **dispatcher/server**: ``dispatcher.gd::DEFERRED_TIMEOUT_MS_BY_COMMAND``
  and ``handlers/game.py::GAME_COMMAND_TIMEOUT_SEC`` — the outermost
  budgets; if either undercuts the inner tiers, the deferred reply is
  dropped as expired and the actionable message never reaches the agent.

Audit backlog item (S3 · drift, game_helper.gd:640). Source-scraping
pattern per test_dock_cli_timeout.py / test_deferred_timeout_contract.py.
"""

from __future__ import annotations

import re
from pathlib import Path

from godot_ai.handlers.game import GAME_COMMAND_TIMEOUT_SEC

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def _scrape_float(path: Path, pattern: str) -> float:
    source = path.read_text(encoding="utf-8")
    match = re.search(pattern, source, re.MULTILINE)
    assert match, f"pattern {pattern!r} not found in {path}"
    return float(match.group(1))


def _scrape_all_floats(path: Path, pattern: str) -> list[float]:
    source = path.read_text(encoding="utf-8")
    values = [float(v) for v in re.findall(pattern, source, re.MULTILINE)]
    assert values, f"pattern {pattern!r} not found in {path}"
    return values


def _game_timeout_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "runtime" / "game_helper.gd",
        r"^const EVAL_TIMEOUT_SEC := ([0-9.]+)",
    )


def _editor_timeout_secs() -> list[float]:
    ## Both request_game_eval and request_game_command carry the default.
    return _scrape_all_floats(
        PLUGIN_ROOT / "debugger" / "mcp_debugger_plugin.gd",
        r"^\ttimeout_sec: float = ([0-9.]+),",
    )


def _ready_wait_sec() -> float:
    return _scrape_float(
        PLUGIN_ROOT / "handlers" / "project_handler.gd",
        r"^const RUN_READY_WAIT_SEC := ([0-9.]+)",
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


def test_game_guard_stays_below_editor_fallback() -> None:
    game = _game_timeout_sec()
    for editor in _editor_timeout_secs():
        assert game < editor, (
            f"game EVAL_TIMEOUT_SEC ({game}s) must stay below the editor "
            f"fallback ({editor}s) or the specific 'Eval exceeded' "
            f"diagnostic loses the race to the generic editor message"
        )


def test_editor_fallback_stays_below_dispatcher_budget() -> None:
    budgets = _dispatcher_budget_secs()
    for editor in _editor_timeout_secs():
        for name, budget in budgets.items():
            assert editor < budget, (
                f"editor fallback ({editor}s) must stay below the "
                f"dispatcher's {name} budget ({budget}s) or the deferred "
                f"reply is dropped as expired before the editor can answer"
            )


def test_ready_wait_plus_editor_stays_below_dispatcher_budget() -> None:
    stacked = _ready_wait_sec() + max(_editor_timeout_secs())
    for name, budget in _dispatcher_budget_secs().items():
        assert stacked < budget, (
            f"RUN_READY_WAIT_SEC + editor fallback ({stacked}s) must stay "
            f"below the dispatcher's {name} budget ({budget}s)"
        )


def test_server_timeout_covers_dispatcher_budget() -> None:
    for name, budget in _dispatcher_budget_secs().items():
        assert GAME_COMMAND_TIMEOUT_SEC >= budget, (
            f"server GAME_COMMAND_TIMEOUT_SEC ({GAME_COMMAND_TIMEOUT_SEC}s) "
            f"must not undercut the dispatcher's {name} budget ({budget}s) — "
            f"the server would time out first and misattribute the failure"
        )
