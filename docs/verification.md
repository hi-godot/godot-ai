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
command -v godot                          # engine on PATH?
ls -d /Applications/Godot*.app 2>/dev/null # ...or a macOS app bundle (not on PATH)
pgrep -af 'godot.*--editor'               # editor already running, and against which --path?
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

**Confirm which editor you are about to drive first.** `script/ci-godot-tests`
waits only for a session count greater than zero — it never calls
`session_activate` — then runs `scene_open` and `test_run` against whatever
session is active. Multiple editors sharing port 8000 is a supported setup (see
[worktrees](worktrees.md)), so with more than one connected, the script can open
a scene in and run tests against the wrong project. Use the shortcut only when
`pgrep -af` shows exactly one editor on the `test_project/` you mean; otherwise
`session_activate` the right session first, or take the interactive path.

That satisfies steps 3–5. Use the interactive path below when you need a live
editor to *look at* — the step 6 smoke test — or when nothing is running yet.

## Pre-commit smoke test

**Always do this before every commit.** Python mocks don't catch GDScript bugs, editor API regressions, or undo/redo issues.

1. `ruff check src/ tests/` — lint passes
2. `pytest -v` — all Python tests pass
3. Open `test_project/` in Godot. Skip if one is already running (see above). Both forms occupy the shell, so background them or use a second terminal — you need this one for steps 4–5:
   ```bash
   # macOS GUI
   /Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path test_project/ &
   # headless (CI, containers, no display)
   godot --headless --path test_project --editor >/tmp/godot-editor.log 2>&1 &
   ```
   Note the job's PID; `kill` it when you're done, and check `/tmp/godot-editor.log` if the plugin never connects.
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
