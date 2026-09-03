# Stress testing — `script/stormtest.py`

`stormtest` is a concurrency + reload stress harness. It opens many MCP client
connections at once and fires rapid, randomized tool calls across **most**
domains at a live Godot editor, periodically triggering `editor_reload_plugin`
mid-run. It is not a correctness test — it answers two questions:

1. **Does the stack survive sustained concurrent abuse + reload churn without
   crashing?** (editor process, GDScript plugin, WebSocket dispatcher, server)
2. **Where are the latency / error hot-spots per tool?**

It complements the deterministic suites (`pytest`, `test_run`): those check
that each tool is *correct*; stormtest checks that the whole stack is *robust*
under load and across the disable-to-enable/session-replacement window.

## What it does

- **N parallel workers**, each its own `fastmcp.Client` connection (default 8).
- Exploratory workers route to the **active session** by default. Locked
  profiles first prove the target's project path and editor PID; reload rows
  pause that target's workers and repin only to one new session with the same
  immutable identity. An exploratory `--target NAME=URL,SESSION_ID` instead
  pins every operation to that editor, regardless of its trace's pin fraction.
  It captures the project/PID before setup and uses the same identity-bound
  replacement-session check after reload; it never follows another editor.
- **Reads dominate** the op mix (like real traffic); **writes exercise most
  domains** — node/scene/script/batch/material/theme/resource/camera/particle/
  audio/animation/input_map/signal/filesystem.
- Each worker namespaces its writes under `<scene_root>/wN/...` so workers
  hammer one shared edited scene without colliding on node paths.
- **Worker 0 is the "chaos" worker**: every `SS_RELOAD_EVERY` waves it fires
  `editor_reload_plugin`, then reconnects and reopens the scratch scene. In a
  locked `multi-editor` profile, a per-target barrier drains active calls and
  blocks new ones during rotation while the other target stays under load.
  `reload-churn` deliberately keeps its one target under load through reload.
- All disk artifacts (scratch scripts/resources/scene) land under
  `res://_stormtest/` in whatever project the target editor has open — scratch
  material that's safe to delete afterward.

## Safety

- Exploratory mode creates `res://_stormtest/storm.tscn`, but its input-map
  operations can also persist changes to `project.godot`. Run exploratory
  storms only against projects you are prepared to discard.
- A locked run refuses to start unless every target is bound to an absolute
  disposable project path whose root contains a regular
  `.godot-ai-stormtest-disposable` file with exactly
  `godot-ai-stormtest-disposable-v1` as its content. The scratch directory must
  be absent at preflight; there is no interactive or soft confirmation path.
- Locked profiles make input-map coverage read-only, capture the durable tree
  before setup (excluding Godot's generated root `.godot/` cache), require an
  already-open saved original scene, restore and observe that exact scene,
  remove only the scratch directory created by the run, and fail if the final
  tree differs at any path.
- A hard process kill cannot run teardown. It deliberately leaves the owned
  scratch tree behind, causing the next locked preflight to refuse the project
  until an operator inspects and removes it.
- After an interrupted exploratory run, close only its disposable editor,
  inspect/archive its scratch tree, and restore its initial project settings
  before restarting. Deleting files while the scratch scene is still open can
  leave cached nodes/resources in memory and invalidate the next run.
- `project_run` is not part of the operation mix.
- A full JSON snapshot is flushed to `stormtest_report.json` (in `$TMPDIR`,
  overridable via `SS_REPORT`) **every few seconds**, so a crash or a kill mid-
  run still leaves analyzable data (this is deliberate — an earlier version
  lost its metrics to a `SIGKILL`).
- Client establishment, tool calls, and client teardown are all deadline-bound.
  A harness abort exits nonzero even when the editor recovers and answers the
  final liveness probe.
- It does **not** clear logs (a diagnostic must not destroy its own evidence).

## Running

The target editor's MCP server must be reachable (default `:8000`). The harness
authenticates every HTTP connection from the private capability record for the
target loopback port; a tokenless endpoint is not supported. For a true test of
a branch's code, point the editor at that branch's worktree and serve that
worktree's `src/` (see
[Serving a worktree](#serving-a-worktree-code-under-test) below), so both the
GDScript plugin and the Python server are the code under test.

The commands below use `python` and are identical on every OS. `stormtest.py`
re-execs itself into the project `.venv` on launch, so you don't need to
activate the venv or name `.venv/bin/python` vs `.venv\Scripts\python.exe`
first — any `python` on PATH works (opt out with `SS_NO_REEXEC=1`). Host-side
paths are already platform-agnostic.

```bash
# default ≈ 1000 calls, with reload churn, against localhost:8000
python script/stormtest.py

# brutal ≈ 9000 calls
SS_WORKERS=12 SS_WAVES=30 python script/stormtest.py

# reads-only smoke, no reloads
SS_RELOAD=0 SS_WORKERS=4 SS_WAVES=3 python script/stormtest.py

# target a loopback server on another port
SS_URL=http://127.0.0.1:8010/mcp python script/stormtest.py

# isolated reload survival (single-threaded; the Windows-friendly mode)
SS_RELOAD_MODE=isolated python script/stormtest.py
```

### Serving a worktree (code under test)

The shared `.venv` lives in the root repo and editable-installs the root's
`src/godot_ai`, so a plugin launched from a worktree spawns the *root's* Python
server — worktree Python changes are invisible. The cross-platform launcher
`script/serve_worktree.py` fixes this: it resolves the venv interpreter, prepends
the worktree's `src/` to `PYTHONPATH`, frees the HTTP port, and starts the server
with `--reload` and **both** `--port` and `--ws-port` (so it matches an editor
using non-default port overrides).

```bash
# any OS — pass the editor's HTTP and WS ports
python script/serve_worktree.py --port 8000 --ws-port 9500

# convenience wrappers (same launcher underneath)
script/serve-this-worktree --port 8000 --ws-port 9500        # macOS / Linux
.\script\serve-this-worktree.ps1 --port 18130 --ws-port 19630  # Windows (PowerShell)
```

### Windows / cross-platform notes

The harness and its tooling are cross-platform: the in-editor scratch paths
(`res://_stormtest/…`) use Godot's virtual filesystem, the report path goes
through `tempfile.gettempdir()` / `os.path.join`, the worktree launcher
(`serve_worktree.py`) resolves the venv interpreter and frees the port per-OS,
and `serve-this-worktree.ps1` gives Windows a discoverable serve command. The
report lands in the platform temp dir (`%TEMP%` on Windows); pass an explicit
`SS_REPORT=…` for a known path.

**Isolated reload diagnosis:**

```bash
SS_RELOAD_MODE=isolated python script/stormtest.py
```

Isolated mode runs a single-threaded `reload → reconnect → verify-session` loop
with no concurrent load, printing a clean `survived N/N` count and per-reload
recovery time. Use it to separate reload correctness from concurrency pressure,
especially on Windows. Adopted/external-server preservation through reload has
live three-OS CI coverage. Managed-server survival is required by the same
lifecycle contract, but still needs an equivalent live locked-profile matrix;
the harness must report a failure rather than explaining it away if the server
or replacement session does not return.

### Locked and replayable runs

Use the checked-in profile, approved seed, explicit target route, and exact
disposable-project binding for qualification. Create the marker file in the
disposable project root with the single token documented in [Safety](#safety):

```bash
python script/stormtest.py \
  --profile steady \
  --seed 41001 \
  --target editor-a=http://127.0.0.1:8000/mcp \
  --qualification-project editor-a=/absolute/path/to/disposable-project \
  --trace-out /tmp/steady-41001.json
```

`steady` and `reload-churn` use the canonical target name `editor-a`.
`multi-editor` requires two repeated `--target` arguments named exactly
`editor-a` and `editor-b` (in that order) with explicit session IDs, plus one
distinct `--qualification-project NAME=/absolute/path` binding for each name.
Target IDs are part of the worker RNG seed, so locking them is necessary for a
profile + seed to identify one canonical operation trace. The single-editor
profiles require their endpoint to expose exactly one session; `multi-editor`
proves each explicit route against its separate project root.
`--replay-trace` runs the exact retained schedule and rejects tampering through
its embedded SHA-256.

Locked profiles reject `--thresholds` and `SS_THRESHOLDS`; their effective
thresholds come only from `docs/verification/storm-profiles-v1.json` and are hashed
into the report. Exploratory non-locked runs may use a threshold file. Changing
a locked threshold requires a reviewed change to the checked-in manifest, not
a per-run override. A locked run also refuses before contacting an editor while
that manifest declares any unresolved baseline gate or lacks positive finite
overall and per-operation p95/p99 ceilings. Use non-locked exploratory runs to
collect baseline evidence; those reports are not qualification evidence until
the reviewed ceilings are checked into the manifest.

### Knobs (env)

| Var | Default | Meaning |
|---|---|---|
| `SS_WORKERS` | 8 | parallel client connections |
| `SS_WAVES` | 5 | waves per worker |
| `SS_CALLS` | 25 | calls per worker per wave |
| `SS_RELOAD` | 1 | include `editor_reload_plugin` churn (`0` to skip) |
| `SS_RELOAD_EVERY` | 2 | chaos worker reloads every N waves (concurrent mode) |
| `SS_RELOAD_MODE` | `concurrent` | `concurrent` churn, or `isolated` single-threaded reload survival loop |
| `SS_ISOLATED_ITERS` | 10 | reload iterations in `isolated` mode |
| `SS_RECONNECT_TIMEOUT` | 30 | seconds to wait for the server to return after a reload |
| `SS_CLOSE_TIMEOUT` | 5 | hard cap (s) on client teardown so a dead-server socket can't wedge the loop |
| `SS_NO_REEXEC` | _(unset)_ | set to skip the auto re-exec into the project `.venv` (run under the current interpreter as-is) |
| `SS_CALL_TIMEOUT` | 20 | per-call hard cap (s) — shapes every latency number in the report |
| `SS_URL` | `http://127.0.0.1:8000/mcp` | target MCP endpoint; loopback capability is discovered from its private port record |
| `SS_REPORT` | `<platform temp dir>/stormtest_report.json` | where to write the JSON snapshot (temp dir via `tempfile.gettempdir()`; `%TEMP%` on Windows) |

Total calls ≈ `WORKERS × WAVES × CALLS` minus the chaos worker's reload waves.

## Reading the result

On exit (or `Ctrl-C` / `SIGTERM` — it has a graceful handler) it prints:

- **final verdict**: `EDITOR ALIVE` vs `EDITOR DEAD/UNREACHABLE`
- throughput (calls/sec), ok/err totals
- **reloads survived / attempted** and per-reload **recovery time** (wall-clock
  to reconnect)
- overall **latency** p50 / p95 / p99 / max
- separate **unexpected** and **reload-transient** error totals
- **error-code histogram** (e.g. `EDITOR_NOT_READY`, `NODE_NOT_FOUND`,
  `INVALID_PARAMS`, `CONNECTION`)
- **per-op table**: ok/err counts, p50/p95/p99/max latency, and the error codes for
  that op
- locked qualification evidence: authorized project/editor identity, every
  old-to-new session repin, original-scene restoration, before/after tree
  hashes, tree drift, and the cleanup-complete gate

The same data, plus more, is in `stormtest_report.json`.

### Error contract

Locked profiles permit only `CONNECTION` and `EDITOR_NOT_READY`, only for the
affected target while an explicit reload window is open. The window opens only
after that target's worker calls drain in `multi-editor`; `reload-churn` opens
it immediately before reload so it retains load-through-reload semantics. Both
close after exactly one distinct authenticated replacement with the original
editor PID + canonical project path is pinned and the scratch scene is
recovered. A call that started inside a reload window or crossed a recorded
reload epoch remains attributed to that reload even if its timeout is observed
after recovery. These errors are counted separately as reload transients.

Every other error, and every error outside that window, is unexpected and fails
the locked contract. `SESSION` is never tolerated; it indicates stale or
misrouted work and aborts a locked run. `NODE_NOT_FOUND` indicates harness state
drift rather than healthy concurrency noise: workers own disjoint namespaces,
so the harness must keep rename/delete bookkeeping correct. Exploratory runs
still print the complete histogram and per-operation table for diagnosis.

For development, an external `serve-this-worktree --reload` server makes Python
edits immediately visible and isolates plugin reload from server-code reload.
Qualification still exercises both adopted and managed ownership topologies.
