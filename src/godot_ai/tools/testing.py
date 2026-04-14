"""MCP tools for running GDScript tests inside the Godot editor."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import testing as testing_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_testing_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def run_tests(
        ctx: Context,
        suite: str = "",
        test_name: str = "",
        verbose: bool = False,
    ) -> dict:
        """Run GDScript test suites inside the connected Godot editor.

        Discovers test_*.gd scripts in the project's res://tests/ directory,
        instantiates them, and runs all test_* methods.

        By default returns a compact summary (pass/fail counts, suite names,
        duration) plus only the failures. Set verbose=true to include every
        individual test result.

        Args:
            suite: Run only the named suite (e.g. "scene", "node", "editor").
                   Empty runs all suites.
            test_name: Run only tests whose name contains this substring.
                       Empty runs all tests in the selected suite(s).
            verbose: If true, include every individual test result. Default
                     false — only summary and failures are returned.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await testing_handlers.run_tests(
            runtime, suite=suite, test_name=test_name, verbose=verbose
        )

    @mcp.tool()
    async def get_test_results(ctx: Context, verbose: bool = False) -> dict:
        """Get results from the most recent test run.

        Returns the same structured results as run_tests, without
        re-executing. Useful for reviewing results after a run.

        Args:
            verbose: If true, include every individual test result.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await testing_handlers.get_test_results(runtime, verbose=verbose)
