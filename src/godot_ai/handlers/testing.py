"""Shared handlers for testing tools."""

from __future__ import annotations

from typing import Any

from godot_ai.protocol.timeouts import TEST_RUN_TIMEOUT_SEC
from godot_ai.runtime.direct import DirectRuntime


async def test_run(
    runtime: DirectRuntime,
    suite: str = "",
    test_name: str = "",
    exclude_test_name: str = "",
    verbose: bool = False,
) -> dict:
    params: dict[str, Any] = {}
    if suite:
        params["suite"] = suite
    if test_name:
        params["test_name"] = test_name
    if exclude_test_name:
        params["exclude_test_name"] = exclude_test_name
    if verbose:
        params["verbose"] = True
    ## Thread the per-call budget into the command envelope so the plugin
    ## derives its between-test abort ceiling from the SAME constant that
    ## bounds this await — the two cannot drift. Old plugins ignore the
    ## extra key; the plugin clamps/validates on its side.
    params["timeout_budget_sec"] = TEST_RUN_TIMEOUT_SEC
    return await runtime.send_command("run_tests", params, timeout=TEST_RUN_TIMEOUT_SEC)


async def test_results_get(runtime: DirectRuntime, verbose: bool = False) -> dict:
    params: dict[str, Any] = {}
    if verbose:
        params["verbose"] = True
    return await runtime.send_command("get_test_results", params)
