# Verifying a change before you commit

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


The full pre-commit gauntlet. Run this before every commit — Python mocks do not
catch GDScript bugs, editor API regressions, or undo/redo issues.

## Pre-commit smoke test

**Always do this before every commit.** Python mocks don't catch GDScript bugs, editor API regressions, or undo/redo issues.

1. `ruff check src/ tests/` — lint passes
2. `pytest -v` — all Python tests pass
3. Open `test_project/` in Godot (or launch: `/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path test_project/`)
4. `session_activate` the test_project session if multiple editors are connected
5. `test_run` via MCP — all GDScript tests pass (0 failures)
6. **Live smoke test** new/changed features against the real editor:
   - Call each new tool and verify the response makes sense
   - For write tools: verify the change is visible in the editor, and verify undo works (Ctrl+Z in Godot)
   - For read tools: compare response against what you see in the editor
   - Check `editor_state` to confirm readiness field is present
7. If the change touches self-update, plugin reload handoff, or install/extract logic, run `script/local-self-update-smoke` and click Update in the launched fixture.
8. Only commit when all of the above are green

## Testing against Godot

1. Open `test_project/` in Godot, enable plugin in Project Settings > Plugins
2. Open a scene (e.g. `main.tscn`)
3. Plugin starts the server automatically; logs should show `Session connected`
4. Use your MCP client's server connection flow to connect (for example, `/mcp` in Claude Code)

**Worktree gotcha**: each working tree (main checkout or git worktree) has its own
`test_project/addons/godot_ai` symlink pointing to *that tree's* `plugin/`. If you
edit a worktree's plugin but Godot is running on the main repo's `test_project/`,
your changes won't appear there. Use `script/open-godot-here` to launch Godot on the
current working tree's `test_project/`.
