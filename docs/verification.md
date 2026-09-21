# Verifying a change before you commit

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


Normal CI runs the full handler suite once per OS, followed by a single
`script/ci-reload-test` reload with session, scene-continuity, and log probes.
Nightly diagnostics use `script/ci-reload-test --stress`: ten reloads followed
by another handler-suite run, preserving the cumulative crash regression.

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

On Windows, make Git for Windows' Bash and OpenSSL available to the test
process. An installed Git can be on PATH while those companion tools are not.
For the default installation, set this in the current PowerShell session:

```powershell
$env:PATH = "$env:ProgramFiles\Git\bin;$env:ProgramFiles\Git\usr\bin;$env:PATH"
Get-Command bash, openssl
```

Use the actual Git installation directory for a non-default installation.
`bash` must resolve to Git's executable, not the Windows WSL launcher. These
tools create disposable signing/TLS fixtures and exercise the CI shell helpers.

Prepare and launch Windows fixtures under the same user context. Files created
by a separate sandbox account can deny the editor's child Python process access
to its launcher. If startup exits before publishing proof, inspect captured
stderr and fixture ACLs before attributing the failure to the plugin.

On Linux, listener ownership checks require `lsof` or `ss` (provided by
`iproute2`). Normal desktop installations commonly include `ss`; minimal test
containers may include neither. Install one before live verification, for
example `sudo apt-get install lsof` on Debian/Ubuntu. Missing tools must produce
an actionable failure, never a bypass of the process ownership checks.

1. Run the same Ruff scope as CI — production, tests, the `script/` Python
   package, and the executable Python release/smoke scripts:
   ```bash
   ruff check src/ tests/ script/ \
     script/ci-game-capture-smoke script/ci-stale-server-smoke \
     script/ci-unsupported-godot-smoke script/generate-star-history \
     script/local-game-capture-diag script/v4-release
   ```
   Lint must pass.
2. `pytest -v` — all environment-independent Python tests pass. While
   iterating, `pytest -m "not editor"` leaves out the rows that launch a
   real editor (they take minutes each and skip anyway without
   `GODOT_BIN`); the pre-commit run is the full `pytest -v`. Then run the
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
   automated coverage ([self-update.md](self-update.md)). Also complete the
   visible-editor checks below for lifecycle and update changes.
8. Only commit when all of the above are green

## Verify lifecycle and updates throughout implementation

Close each disposable editor when its test is finished. Preserve logs and
receipts, inspect the final screenshot, then request a normal exit and verify
that the exact process has stopped. Match both its project path and process
creation identity before closing it. Discard only known smoke-test mutations;
leave user editors and unsaved user work alone. Release test-owned client
connections normally, and keep only editors needed for active checks running.
After exit, remove disposable generated caches from the verified fixture paths.
Keep source snapshots, logs, receipts, and the small evidence needed to explain
failures; do not retain entire thumbnail/import caches as test evidence. Never
clean a live fixture or a user's settings/cache directories.

Full handler suites include deliberate error cases. Label their editor clearly
and attribute console diagnostics to specific tests; passing assertions do not
excuse errors from valid-input cases. Use a separate clean editor for the
user-facing startup and update checks.

For interactive pytest runs, pass `-o tmp_path_retention_policy=all` and copy
the compact evidence before releasing the visual-review gate. The default
retains only failed tests; passing assertions can otherwise delete the editor
log even when visual review found a transient error worth investigating.

Keep isolated settings and caches outside the Godot project, or create a
`.gdignore` in their directory before the first editor launch. Otherwise Godot
can import its own thumbnail cache and produce misleading scan/load timings.

Run a visible Godot editor before and after each meaningful lifecycle or update
change. Load real scenes and exercise handlers before testing recovery or an
update. A clean startup with no handlers loaded does not cover retained script
state. Repeat these checks during implementation, not only before the commit.

Watch the editor during startup, reload, and update, including failure states.
Do not wait for a successful connection before inspecting the dock. For
automated interactive runs, inspect startup after each relevant change, and
inspect every plugin reload and upgrade. For unchanged benchmark repetitions,
review the first and last runs; intermediate runs may advance automatically.
Monitor every run for errors, crashes, connection loss and unexpectedly slow
startup. On an anomaly, stop the series, capture the exact editor window when
available, and preserve its logs for inspection. Choose and record the slow-start
threshold before running. Keep foreground capture out of routine measured
startup intervals; use an excluded warmup for startup visual observation.
Continue monitoring for connection loss while awaiting visual review. A saved screenshot
without visual inspection is not a completed UI check. Check the editor's actual
exit code as well as the harness result. Use the same observation schedule in
both arms of a performance comparison.

Use isolated projects owned by the current session. Keep client configuration
and capability directories separate from the user's normal environment. Follow
the [worktree and scene safety rules](worktrees.md).

1. Start from each published release, **3.2.5 and 4.0.4**. Verify the release
   signatures and record the untouched add-on's file hashes. Record the actual
   backend and attach-bridge package versions as well as the plugin version.
2. Connect a real client through that release's bridge. Open a scene and call
   scene, node, and script handlers. Verify a scene mutation and its undo.
3. Exercise connection loss, plugin disable and enable, plugin reload, and
   editor restart. Check the scene, reconnecting client, and subsequent tool
   responses after each action. A socket loss must not kill a healthy backend.
4. Click **Update** in the actual dock. Observe its confirmation, progress,
   activation, and completion. Verify the installed tree, client configuration,
   and authenticated tool calls after activation, including after any restart.
5. Record editor and server PIDs, versions, logs, scene continuity, and every
   manual recovery action. Agree on the allowed editor and client restarts
   before evaluating whether the update is seamless. A harness that expects a
   restart does not by itself establish that UX requirement.

A failed visible-editor check fails verification even when unit tests pass.
Keep the failure open until the exact sequence passes. Report any unavailable
check as incomplete.

Distinguish local fixtures from exact release evidence. The interactive
`script/local-self-update-smoke` supports `--from-v3-tag v3.2.5` and
`--base-from-release-tag v4.0.4`, but modifies fixture code and uses local server
snapshots. Record those substitutions. These runs help catch regressions during
development, but cannot prove an untouched published stack upgrades correctly.

An untouched published updater accepts only a candidate signed by its trusted
release key. Obtain that candidate through the existing
[release qualification workflow](releasing.md), then verify both published
origins against it. Reuse `script/runtime_qualification.py` for immutable
artifact and packaged-runtime checks, and add the visible dock interaction.
Its automated headless run does not cover that interaction. Do not replace the
trust key or bypass signature verification and report the result as exact
release evidence. A pristine published-to-published run is useful baseline
evidence, but does not verify an unpublished candidate.

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
