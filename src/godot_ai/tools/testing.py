"""MCP tools for running GDScript tests inside the Godot editor.

Top-level: ``test_run`` (high-traffic). ``results_get`` collapses into
``test_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import testing as testing_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Test result inspection (re-fetches the most recent ``test_run`` payload).

Resource form: ``godot://test/results`` — prefer for active-session reads.

Ops:
  • results_get(verbose=False)
        Same shape as test_run — full results from the last run, no
        re-execution. verbose=True includes every individual test result.
"""


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

        Discovers test_*.gd in res://tests/, instantiates them, and runs
        all test_* methods. Returns a compact summary by default (counts,
        suite names, duration) plus failures only. verbose=True includes
        every individual test result.

        Args:
            suite: Run only the named suite (e.g. "scene", "node", "editor").
                Empty runs all suites.
            test_name: Run only tests whose name contains this substring.
            verbose: Include every individual test result. Default False.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await testing_handlers.test_run(
            runtime, suite=suite, test_name=test_name, verbose=verbose
        )

    register_manage_tool(
        mcp,
        tool_name="test_manage",
        description=_DESCRIPTION,
        ops={
            "results_get": testing_handlers.test_results_get,
        },
    )
