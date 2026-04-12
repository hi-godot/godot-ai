"""Shared handlers for testing tools."""

from __future__ import annotations

from godot_ai.runtime.interface import Runtime


async def run_tests(runtime: Runtime, suite: str = "", test_name: str = "") -> dict:
    params: dict[str, str] = {}
    if suite:
        params["suite"] = suite
    if test_name:
        params["test_name"] = test_name
    return await runtime.send_command("run_tests", params)


async def get_test_results(runtime: Runtime) -> dict:
    return await runtime.send_command("get_test_results")

