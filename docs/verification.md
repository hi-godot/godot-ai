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
source script/_ci_env.sh
ci_load_http_auth                         # reads the private record for the target port
curl -sf -o /dev/null "$MCP_SERVER_URL" -X POST \
  "${HTTP_AUTH_HEADERS[@]}" \
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

The probe above and every `script/ci-*` runner assume the server is on
`:8000`, the plugin's default. If the connected editor's `godot_ai/http_port`
is something else — the editor log names it in its
`MCP | started server ... --port N` line — point them at it:

```bash
MCP_SERVER_URL=http://127.0.0.1:8123/mcp script/ci-godot-tests
```

The symptom of forgetting is a healthy editor log next to
`No Godot session connected after 60 attempts`: the runner was polling a
different server the whole time.

Every shell `script/ci-*` runner verifies the editor before its first tool
mutation. With no explicit pin, exactly one session must be connected and its
normalized `project_path` must match this checkout's `test_project/`. This also
catches a wrong `MCP_SERVER_URL` that happens to lead to one unrelated editor.
Once selected, the runner pins every subsequent non-session-management tool
call to that session so a later connection cannot change the target.

**With several editors connected, pin the one you mean.** Multiple editors
sharing port 8000 is a supported setup (see [worktrees](worktrees.md)), so the
runners refuse to guess and list the connected sessions. Pick one with

```bash
GODOT_AI_SESSION_ID='<project-slug>@<16hex>' script/ci-godot-tests
```

which intentionally bypasses the checkout-path match for cross-worktree smoke
runs and is passed as a per-call `session_id`, so it does not disturb the active
session other clients are using. A pinned session that isn't connected fails
loudly rather than falling back to the active one.

That satisfies steps 3–5. Use the interactive path below when you need a live
editor to *look at* — the step 6 smoke test — or when nothing is running yet.

## Pre-commit smoke test

**Always do this before every commit.** Python mocks don't catch GDScript bugs, editor API regressions, or undo/redo issues.

1. Run the same Ruff scope as CI — production, tests, the `script/` Python
   package, and the executable Python release/smoke scripts:
   ```bash
   ruff check src/ tests/ script/ \
     script/ci-game-capture-smoke script/ci-stale-server-smoke \
     script/ci-unsupported-godot-smoke script/generate-star-history \
     script/local-game-capture-diag script/v4-release
   ```
   Lint must pass.
2. `pytest -v` — all environment-independent Python tests pass. Then run the
   Godot-backed updater row explicitly; those tests otherwise skip:
   ```bash
   GODOT_BIN=/absolute/path/to/Godot pytest -v \
     tests/integration/test_self_update_upgrade_paths.py
   ```
3. Open `test_project/` in Godot. Skip if one is already running (see above). Both forms occupy the shell, so background them or use a second terminal — you need this one for steps 4–5:
   ```bash
   # macOS GUI
   /Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path test_project/ &
   # headless (CI, containers, no display)
   GODOT_AI_ALLOW_HEADLESS=1 GODOT_AI_DISABLE_TELEMETRY=true \
     godot --headless --path test_project --editor >/tmp/godot-editor.log 2>&1 &
   ```
   The headless form needs `GODOT_AI_ALLOW_HEADLESS=1`: without it the plugin
   logs `MCP | plugin disabled in headless mode`, starts no server, and nothing
   ever connects (see [server lifecycle](server-lifecycle.md)).
   `GODOT_AI_DISABLE_TELEMETRY=true` keeps a local headless run out of
   production telemetry, as `script/_ci_env.sh` does for the CI runners.
   Note the job's PID; `kill` it when you're done, and check `/tmp/godot-editor.log` if the plugin never connects.
4. `session_activate` the test_project session if multiple editors are connected
5. `test_run` via MCP — all GDScript tests pass (0 failures). `script/ci-godot-tests` does 3–5 in one command.
6. **Live smoke test** new/changed features against the real editor:
   - Call each new tool and verify the response makes sense
   - For write tools: verify the change is visible in the editor, and verify undo works (Ctrl+Z in Godot)
   - For read tools: compare response against what you see in the editor
   - Check `editor_state` to confirm readiness field is present
7. If the change touches self-update, the migration bridge, or plugin
   disable/enable, the updater row in step 2 and
   `test_project/tests/test_update_installer.gd` in step 5 are the required
   coverage ([self-update.md](self-update.md)).
8. Only commit when all of the above are green

## Testing against Godot

1. Open `test_project/` in Godot, enable plugin in Project Settings > Plugins
2. Open a scene (e.g. `main.tscn`)
3. Plugin starts the server automatically; logs should show `Session connected`
4. In the dock, use **Configure** for your MCP client, then restart that client
   so it launches the authenticated `godot-ai attach` stdio bridge. Do not add
   the backend's bare `/mcp` URL directly.

**Worktree gotcha**: each working tree (main checkout or git worktree) has its own
`test_project/addons/godot_ai` symlink pointing to *that tree's* `plugin/`. If you
edit a worktree's plugin but Godot is running on the main repo's `test_project/`,
your changes won't appear there. Use `script/open-godot-here` to launch Godot on the
current working tree's `test_project/`.
