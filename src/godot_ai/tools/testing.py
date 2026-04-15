"""MCP tools for running GDScript tests inside the Godot editor."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import testing as testing_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_testing_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def test_run(
        ctx: Context,
        suite: str = "",
        test_name: str = "",
        verbose: bool = False,
        session_id: str = "",
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
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await testing_handlers.test_run(
            runtime, suite=suite, test_name=test_name, verbose=verbose
        )

    @mcp.tool(meta=DEFER_META)
    async def test_results_get(
        ctx: Context,
        verbose: bool = False,
        session_id: str = "",
    ) -> dict:
        """Get results from the most recent test run.

        Returns the same structured results as test_run, without
        re-executing. Useful for reviewing results after a run.

        Args:
            verbose: If true, include every individual test result.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await testing_handlers.test_results_get(runtime, verbose=verbose)
