"""Cross-language contract: the server's command timeout must cover the
plugin's deferred budget for the same command.

A deferred command has two independent stopwatches running on it:

- **plugin side** — ``dispatcher.gd::DEFERRED_TIMEOUT_MS_BY_COMMAND`` (falling
  back to ``DEFAULT_DEFERRED_TIMEOUT_MS``). When it expires the dispatcher
  drops the pending entry and answers ``DEFERRED_TIMEOUT``, which is an honest,
  attributed diagnostic the agent can act on.
- **server side** — the ``timeout`` ``DirectRuntime.send_command`` hands to
  ``GodotClient.send``. When *it* expires first, ``GodotClient`` raises
  ``TimeoutError``, charges the failure to the editor-bridge circuit breaker
  (``client.py::_record_failure``), and the agent is told the call timed out —
  even when the plugin was still inside its own budget and about to answer
  successfully.

So the server budget must never undercut the plugin budget. ``run_project`` is
the case that motivated this file: the plugin allows the deferred liveness poll
6000 ms (``project_handler.gd::_finish_run_project_deferred`` re-polls
``get_game_status`` with ``RUN_READY_WAIT_SEC`` until the run resolves), while
``handlers/project.py::project_run`` sends with no explicit timeout and
therefore inherits ``DirectRuntime.send_command``'s 5.0 s default. A game that
takes 5-6 s to go live is reported to the AI client as a timeout and counted
toward opening the circuit.

The guard is table-driven over the *whole* dispatcher budget table rather than
just ``run_project``: each command is driven through its real Python handler
with a recording client, so the assertion sees the timeout production actually
resolves (default or explicit) instead of a re-declared copy of it. Source
scraping of the GDScript side follows ``test_game_eval_timeout_ordering.py`` /
``test_deferred_timeout_contract.py``.
"""

from __future__ import annotations

import contextlib
import inspect
import re
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

import pytest

from godot_ai.handlers import client as client_handlers
from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import filesystem as filesystem_handlers
from godot_ai.handlers import game as game_handlers
from godot_ai.handlers import project as project_handlers
from godot_ai.handlers import script as script_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import SessionRegistry

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
DISPATCHER = PLUGIN_ROOT / "dispatcher.gd"
VISION_ROUTING = PLUGIN_ROOT / "vision_routing.gd"


class RecordingClient:
    """``GodotClient`` stand-in that records the timeout it was sent with.

    Mirrors ``GodotClient.send``'s signature (including its 5.0 s default) so
    that a handler which stops passing ``timeout`` is recorded as whatever
    ``DirectRuntime`` resolves, not as whatever this stub prefers.
    """

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
        hint_policy=None,
    ) -> dict:
        self.calls.append({"command": command, "timeout": timeout})
        return {}


## One driver per command in DEFERRED_TIMEOUT_MS_BY_COMMAND, calling the real
## Python handler that issues it. The registry is left empty on purpose: the
## `require_writable_async` gate on the write paths is a documented no-op when
## there is no active session, so no readiness choreography is needed here.
COMMAND_DRIVERS: dict[str, Callable[[DirectRuntime], Awaitable[object]]] = {
    "run_project": lambda rt: project_handlers.project_run(rt),
    "stop_project": lambda rt: project_handlers.project_stop(rt),
    "create_script": lambda rt: script_handlers.script_create(rt, "res://_audit_probe.gd"),
    "write_file": lambda rt: filesystem_handlers.filesystem_write_text(
        rt, "res://_audit_probe.txt", "x"
    ),
    "scan_filesystem": lambda rt: filesystem_handlers.filesystem_scan(rt),
    "check_client_status": lambda rt: client_handlers.client_status(rt),
    "game_eval": lambda rt: editor_handlers.game_eval(rt, "return 1"),
    "game_command": lambda rt: game_handlers.game_get_scene_tree(rt),
    "game_debug_control": lambda rt: game_handlers.game_debug_status(rt),
    ## Only source="game" defers plugin-side (editor_handler.gd's game branch
    ## hands off to the debugger); viewport/cinematic captures reply inline, so
    ## the 30 s budget belongs to the game path. The one exception — a
    ## vision-routed editor capture — carries its own 13 s override and is
    ## checked separately below.
    "take_screenshot": lambda rt: editor_handlers.editor_screenshot(rt, source="game"),
}


def _dispatcher_source() -> str:
    return DISPATCHER.read_text(encoding="utf-8")


def _plugin_budgets_sec() -> dict[str, float]:
    """Scrape ``DEFERRED_TIMEOUT_MS_BY_COMMAND`` as {command: seconds}."""
    block = re.search(
        r"const DEFERRED_TIMEOUT_MS_BY_COMMAND := \{(.*?)\n\}",
        _dispatcher_source(),
        re.DOTALL,
    )
    assert block, "DEFERRED_TIMEOUT_MS_BY_COMMAND not found in dispatcher.gd"
    body = block.group(1)
    entries = re.findall(r'"([a-z0-9_]+)"\s*:\s*(\d+)', body)

    ## A guard that silently drops table entries is worse than no guard: the
    ## dropped command is exactly the one that would have been caught next.
    ## Command names contain digits (`camera_follow_2d`), and a budget could be
    ## written as a named constant rather than a literal — either would vanish
    ## from a permissive `findall` while leaving the list non-empty. So count
    ## the keys independently and require the two to agree.
    keys = re.findall(r'"([^"]+)"\s*:', body)
    assert keys, "no command budgets parsed out of DEFERRED_TIMEOUT_MS_BY_COMMAND"
    assert len(entries) == len(keys), (
        f"parsed {len(entries)} of {len(keys)} entries in DEFERRED_TIMEOUT_MS_BY_COMMAND — "
        f"unparsed: {sorted(set(keys) - {name for name, _ in entries})}. "
        "Every entry must be covered; widen the parser rather than letting one through."
    )
    return {name: int(ms) / 1000.0 for name, ms in entries}


def _plugin_default_budget_sec() -> float:
    match = re.search(r"const DEFAULT_DEFERRED_TIMEOUT_MS := (\d+)", _dispatcher_source())
    assert match, "DEFAULT_DEFERRED_TIMEOUT_MS not found in dispatcher.gd"
    return int(match.group(1)) / 1000.0


def _vision_route_budget_sec() -> float:
    match = re.search(
        r'"_deferred_timeout_ms":\s*(\d+)',
        VISION_ROUTING.read_text(encoding="utf-8"),
    )
    assert match, "vision_routing.gd no longer declares a _deferred_timeout_ms override"
    return int(match.group(1)) / 1000.0


def _runtime_default_timeout_sec() -> float:
    default = inspect.signature(DirectRuntime.send_command).parameters["timeout"].default
    assert isinstance(default, (int, float)), "DirectRuntime.send_command lost its timeout default"
    return float(default)


async def _observed_timeout_sec(command: str) -> float:
    """Drive `command`'s Python handler and report the timeout it sent with."""
    client = RecordingClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    ## The stub answers every command with {}, so handlers that post-process the
    ## reply (screenshot decoding, pagination, readiness reads) raise on the way
    ## back out — KeyError, TypeError, AttributeError or ValueError depending on
    ## the handler. Only the OUTBOUND timeout matters here, and it is already
    ## recorded by the time any of those fire. Unexpected exception types must
    ## fail the test; `assert sent` still fails if send_command was never reached.
    with contextlib.suppress(KeyError, TypeError, AttributeError, ValueError):
        await COMMAND_DRIVERS[command](runtime)
    sent = [call for call in client.calls if call["command"] == command]
    assert sent, f"handler for {command!r} never issued a {command!r} command"
    return float(sent[-1]["timeout"])


def test_every_deferred_budget_has_a_driver() -> None:
    """A new bespoke plugin budget must not slip in unguarded."""
    missing = sorted(set(_plugin_budgets_sec()) - set(COMMAND_DRIVERS))
    assert not missing, (
        f"dispatcher.gd budgets {missing} have no Python driver in this test — "
        "add one so the server/plugin timeout ordering stays enforced"
    )


@pytest.mark.parametrize("command", sorted(_plugin_budgets_sec()))
async def test_server_timeout_covers_plugin_deferred_budget(command: str) -> None:
    budget = _plugin_budgets_sec()[command]
    observed = await _observed_timeout_sec(command)
    assert observed >= budget, (
        f"server timeout for {command!r} ({observed}s) undercuts the plugin's "
        f"deferred budget ({budget}s) — the client aborts while the plugin is "
        "still legitimately working, so a successful command is reported as a "
        "timeout AND charged to the editor-bridge circuit breaker"
    )


async def test_default_send_timeout_covers_default_deferred_budget() -> None:
    """Commands with no bespoke budget on either side must still be ordered."""
    default_budget = _plugin_default_budget_sec()
    assert _runtime_default_timeout_sec() >= default_budget, (
        f"DirectRuntime.send_command's default timeout "
        f"({_runtime_default_timeout_sec()}s) undercuts the dispatcher's "
        f"DEFAULT_DEFERRED_TIMEOUT_MS ({default_budget}s) — every deferring "
        "command without an explicit timeout would abort early"
    )


async def test_editor_screenshot_timeout_covers_vision_route_budget() -> None:
    """The vision-routing override is the editor-source screenshot's budget."""
    budget = _vision_route_budget_sec()
    client = RecordingClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    with contextlib.suppress(KeyError, TypeError, AttributeError, ValueError):
        await editor_handlers.editor_screenshot(runtime, source="viewport")
    sent = [call for call in client.calls if call["command"] == "take_screenshot"]
    assert sent, "editor_screenshot never issued take_screenshot"
    assert float(sent[-1]["timeout"]) >= budget, (
        f"editor-source screenshot timeout ({sent[-1]['timeout']}s) undercuts "
        f"vision_routing.gd's deferred override ({budget}s) — a vision-routed "
        "capture would be aborted client-side before the worker can reply"
    )
