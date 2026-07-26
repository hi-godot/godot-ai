# Verifying a change before you commit

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


The full pre-commit gauntlet. Run this before every commit — Python mocks do not
catch GDScript bugs, editor API regressions, or undo/redo issues.

## First: check whether an editor is already running

**Do not assume you need a GUI, or that a headless environment can't run these
tests.** Claude Code on the web bootstraps a headless Godot and a live MCP
server via `.claude/hooks/session-start.sh`, so steps 3–5 below are usually
already done for you. Check before concluding anything is unavailable:

```bash
command -v godot                      # engine installed?
pgrep -f 'godot.*--editor'            # editor already running?
curl -sf -o /dev/null http://127.0.0.1:8000/mcp -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'
```

If the editor is up, run the whole GDScript suite non-interactively — no GUI, no
MCP client, no human:

```bash
script/ci-godot-tests    # waits for the plugin, opens main.tscn, runs test_run,
                         # prints {suite}.{test}: {message} for each failure
```

That satisfies steps 3–5. Use the interactive path below when you need a live
editor to *look at* — the step 6 smoke test — or when nothing is running yet.

## Pre-commit smoke test

**Always do this before every commit.** Python mocks don't catch GDScript bugs, editor API regressions, or undo/redo issues.

1. `ruff check src/ tests/` — lint passes
2. `pytest -v` — all Python tests pass
3. Open `test_project/` in Godot — macOS GUI: `/Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path test_project/`; headless: `godot --headless --path test_project --editor`. Skip if one is already running (see above).
4. `session_activate` the test_project session if multiple editors are connected
5. `test_run` via MCP — all GDScript tests pass (0 failures). `script/ci-godot-tests` does 3–5 in one command.
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
