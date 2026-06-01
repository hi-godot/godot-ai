# Stress testing — `script/stormtest.py`

`stormtest` is a concurrency + reload stress harness. It opens many MCP client
connections at once and fires rapid, randomized tool calls across **every**
domain at a live Godot editor, periodically triggering `editor_reload_plugin`
mid-run. It is not a correctness test — it answers two questions:

1. **Does the stack survive sustained concurrent abuse + reload churn without
   crashing?** (editor process, GDScript plugin, WebSocket dispatcher, server)
2. **Where are the latency / error hot-spots per tool?**

It complements the deterministic suites (`pytest`, `test_run`): those check
that each tool is *correct*; stormtest checks that the whole stack is *robust*
under load and across the disable→extract→enable reload window.

## What it does

- **N parallel workers**, each its own `fastmcp.Client` connection (default 8).
- Workers route to the **active session** (empty `session_id`), so when a
  reload rotates the session id they automatically follow the new one.
- **Reads dominate** the op mix (like real traffic); **writes exercise every
  domain** — node/scene/script/batch/material/theme/resource/camera/particle/
  audio/animation/input_map/signal/filesystem.
- Each worker namespaces its writes under `<scene_root>/wN/...` so workers
  hammer one shared edited scene without colliding on node paths.
- **Worker 0 is the "chaos" worker**: every `SS_RELOAD_EVERY` waves it fires
  `editor_reload_plugin` instead of a normal burst, then reconnects (and
  reopens the scratch scene). The other workers keep hammering through the
  reload window and reconnect on the connection drop.
- All disk artifacts (scratch scripts/resources/scene) land under
  `res://_stormtest/` in whatever project the target editor has open — scratch
  material that's safe to delete afterward.

## Safety

- Operates in a throwaway scratch scene (`res://_stormtest/storm.tscn`), **not**
  the project's real scene; restores the originally-open scene on teardown.
- Never calls `project_run`, so it can't autosave-pollute the real scene.
- A full JSON snapshot is flushed to `stormtest_report.json` (in `$TMPDIR`,
  overridable via `SS_REPORT`) **every few seconds**, so a crash or a kill mid-
  run still leaves analyzable data (this is deliberate — an earlier version
  lost its metrics to a `SIGKILL`).
- It does **not** clear logs (a diagnostic must not destroy its own evidence).

## Running

The target editor's MCP server must be reachable (default `:8000`). For a true
test of a branch's code, point the editor at that branch's worktree and serve
that worktree's `src/` (see `script/serve-this-worktree`), so both the GDScript
plugin and the Python server are the code under test.

```bash
# default ≈ 1000 calls, with reload churn, against localhost:8000
.venv/bin/python script/stormtest.py

# brutal ≈ 9000 calls
SS_WORKERS=12 SS_WAVES=30 .venv/bin/python script/stormtest.py

# reads-only smoke, no reloads
SS_RELOAD=0 SS_WORKERS=4 SS_WAVES=3 .venv/bin/python script/stormtest.py

# target a server on another port / host
SS_URL=http://127.0.0.1:8010/mcp .venv/bin/python script/stormtest.py
```

### Windows / cross-platform notes

> ⚠️ **Running on Windows? Reads/writes work; reload churn does not (yet).**
>
> **Concurrent reads/writes are fine.** The harness *logic* is platform-agnostic:
> the in-editor scratch paths (`res://_stormtest/…`) use Godot's virtual
> filesystem, and the report path goes through `tempfile.gettempdir()` /
> `os.path.join`, so both resolve correctly on every OS. A reads-dominant run
> (`SS_RELOAD=0`) is clean on Windows.
>
> **Reload churn (`SS_RELOAD=1`, the default) currently does NOT work on Windows**
> — two independent problems, both tracked:
> - Against a plugin-managed server, the first `editor_reload_plugin` **wedges the
>   harness**: the asyncio loop stalls past `CALL_TIMEOUT` when the server is
>   killed mid-reload under concurrent load. The *editor* survives fine (it
>   reloads and re-registers a new session) — only the harness hangs. See
>   [#513](https://github.com/hi-godot/godot-ai/issues/513).
> - The "run the server externally" mitigation **also fails on Windows**:
>   `script/serve-this-worktree` is bash-only (no PowerShell port, and it never
>   passes `--ws-port`), and even a hand-started external `--reload` server gets
>   **killed by the reload** (`_stop_server` takes down the port owner with no
>   respawn). See [#514](https://github.com/hi-godot/godot-ai/issues/514).
>
>   Until those land, validate reload survival on Windows with a *single-threaded*
>   reload loop (reload → reconnect → confirm a new `session_id`) rather than the
>   concurrent churn mode.
>
> **Invocation also differs (POSIX → Windows):**
> - **venv interpreter** — use `.venv\Scripts\python.exe`, not `.venv/bin/python`.
> - **`$TMPDIR`** in the examples is POSIX; the report lands in the platform temp
>   dir (`%TEMP%` on Windows). Pass an explicit `SS_REPORT=…` for a known
>   location, and prefer forward slashes (Python accepts them on Windows and they
>   dodge backslash-escaping surprises).
>
> Making the tooling resilient enough to drop this heads-up is tracked in
> [#509](https://github.com/hi-godot/godot-ai/issues/509).

### Knobs (env)

| Var | Default | Meaning |
|---|---|---|
| `SS_WORKERS` | 8 | parallel client connections |
| `SS_WAVES` | 5 | waves per worker |
| `SS_CALLS` | 25 | calls per worker per wave |
| `SS_RELOAD` | 1 | include `editor_reload_plugin` churn (`0` to skip) |
| `SS_RELOAD_EVERY` | 2 | chaos worker reloads every N waves |
| `SS_RECONNECT_TIMEOUT` | 30 | seconds to wait for the server to return after a reload |
| `SS_URL` | `http://127.0.0.1:8000/mcp` | target MCP endpoint |
| `SS_REPORT` | `$TMPDIR/stormtest_report.json` | where to write the JSON snapshot |

Total calls ≈ `WORKERS × WAVES × CALLS` minus the chaos worker's reload waves.

## Reading the result

On exit (or `Ctrl-C` / `SIGTERM` — it has a graceful handler) it prints:

- **final verdict**: `EDITOR ALIVE` vs `EDITOR DEAD/UNREACHABLE`
- throughput (calls/sec), ok/err totals
- **reloads survived / attempted** and per-reload **recovery time** (wall-clock
  to reconnect)
- overall **latency** p50 / p95 / max
- **error-code histogram** (e.g. `EDITOR_NOT_READY`, `NODE_NOT_FOUND`,
  `INVALID_PARAMS`, `CONNECTION`)
- **per-op table**: ok/err counts, p50/p95/max latency, and the error codes for
  that op

The same data, plus more, is in `stormtest_report.json`.

### Expected (healthy) error noise

A small error rate is normal and *not* a failure:

- `EDITOR_NOT_READY` — transient, during reload windows or play-state changes.
- `NODE_NOT_FOUND` — concurrent-delete races (one worker deletes a node another
  was about to touch); expected under concurrency.
- `CONNECTION` — during the reload disable→enable window before reconnect.

What you're watching for instead: the editor **process dying** (verdict flips to
`DEAD`, a flood of `CONNECTION` that never recovers), a reload that **never
comes back** (managed-server-killed; recovery time unbounded), or one op with a
**pathologically high error rate or latency** that points at a real regression.

> If the target server is plugin-managed (auto-spawned), a reload may kill it
> and not return — run the server **externally** (e.g. `serve-this-worktree`,
> which uses `--reload`) so `editor_reload_plugin` exercises the plugin reload
> without taking the server down with it.
