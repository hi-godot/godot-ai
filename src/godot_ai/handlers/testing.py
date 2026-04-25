"""Shared handlers for testing tools."""

from __future__ import annotations

from typing import Any

from godot_ai.runtime.interface import Runtime


async def test_run(
    runtime: Runtime,
    suite: str = "",
    test_name: str = "",
    verbose: bool = False,
) -> dict:
    params: dict[str, Any] = {}
    if suite:
        params["suite"] = suite
    if test_name:
        params["test_name"] = test_name
    if verbose:
        params["verbose"] = True
    return await runtime.send_command("run_tests", params, timeout=30.0)


async def test_results_get(runtime: Runtime, verbose: bool = False) -> dict:
    params: dict[str, Any] = {}
    if verbose:
        params["verbose"] = True
    return await runtime.send_command("get_test_results", params)
