# Friction log — godot-ai MCP

Rolling log of pain points, surprises, and bugs hit while using the
godot-ai MCP server from AI clients. Append new entries at the top so the
most recent session is easiest to find; keep older entries around as a
record of what's been fixed vs. what keeps biting.

Each entry should include: date, what we were doing, what went wrong,
enough detail to reproduce, and — if known — a suggested fix. Entries
labelled "bug" are actual defects; "friction" entries are workflow rough
edges that aren't necessarily code bugs.

---

## 2026-05-04 — MegaSmoke beta (`origin/beta` 767220a)

Live operator-driven smoke run against PR 11-inclusive beta
(`767220a`, "PR 11: Document and pin FastMCP middleware order (#14) +
closing docs sweep (#317)"). Started 2026-05-04 13:46:01 PDT on macOS.

Scope: issue #297 audit refactor stack, PR 11 middleware-order contract,
high-traffic MCP tools, reload/self-update paths, multi-session routing,
middleware edge cases, and real editor/game-process behavior.

### Baseline gates

| Gate | Status | Notes |
| --- | --- | --- |
| `ruff check src/ tests/` | pass | All checks passed. |
| `pytest -v` | pass | Sandbox run blocked localhost connects with `PermissionError: [Errno 1]`; rerun with socket permission passed, 768 passed in 35.38s. |
| `script/ci-check-gdscript` | pass | Headless import completed; all GDScript files OK. |
| MCP `test_run` | pass | Live `test-project@43b6`: 1132 passed, 0 failed, 5 skipped across 44 suites in 4265 ms. |
| `script/ci-reload-test` | fail | Created `/Main/ReloadTestCube`, then `editor_reload_plugin` returned empty SSE; external `script/serve-this-worktree` server was killed/replaced by plugin-managed server. Test node cleaned up manually. |
| `script/ci-game-capture-smoke` | pass with workaround | Direct shebang failed because system Python lacked `PIL`; rerun with `.venv/bin/python` passed, 1920x1080 game PNG quadrants OK. |
| `script/local-self-update-smoke --no-launch` | pass with workaround | Default temp path refused as unsafe stale fixture; explicit `/private/tmp/godot-ai-megasmoke-self-update-smoke` prepared v2.3.2 -> v2.3.3 fixture. |
| interactive `script/local-self-update-smoke` + Update click | pass after harness patch | Initial managed-server run passed the core safety checks but then exposed a version-mismatch recovery loop, logged below. Managed-server rerun on `codex/megasmoke-results-harness-fix` at 14:27 PDT passed with plugin v2.3.3, server `godot-ai==2.3.2`, temp update dir consumed, no new `.ips`, managed server stopped, and no server/plugin version mismatch reported. Separate foreign/orphan lifecycle scenarios are not covered by this harness rerun. |
| `script/manual-orphan-test setup` + macOS live matrix | pass after patches | Prepared `/tmp/orphan-sim` and `/tmp/sim-statusonly`. Compatible external adoption passed; managed drift cleanup passed; IPv4 non-godot control passed; default macOS IPv6 non-godot occupant initially failed, then passed after the branch lifecycle patch. Status-name-only Restart-click initially recovered the backend but left the dock in Restarting; after the SPAWNING-unblock patch, rerun passed and the dock turned green. |

### Live MCP scenario

Corrected disposable session: `godot-ai-megasmoke-live@e913`,
`/private/tmp/godot-ai-megasmoke-live/`.

Covered: scene create/save, node create/properties/groups, hierarchy reads,
script create/read/attach, signal connect/list, input map action/binding,
autoload add/list, UI text/anchors, theme create/apply, material preset +
readback, particle main/process + readback, camera current/readback, audio
playback properties, resource creation/search, filesystem write/reimport,
batch rollback, project run/stop with `autosave=false`, game screenshot,
viewport coverage screenshot, plugin/game/all logs, and middleware edge cases.

Middleware checks: stringified `params` decoded; `task_progress` stripped;
JSON-shaped string stayed a string for a `String` param; malformed JSON
fell through to Pydantic dict validation; misspelled manage op returned
suggestions; batch unknown-command preserved `error.data.suggestions`.

Correction: an initial live-tool attempt accidentally targeted
`test_project@c4af`. All resulting `test_project` artifacts were removed
and tracked scene diffs were restored before the corrected disposable run.

### Friction items

#### bug — self-update Restart Server respawns the old server package after plugin advances

- Timestamp: 2026-05-04 13:57:54 PDT
- Phase: interactive self-update / recovery path.
- Exact operator action: run `script/local-self-update-smoke --project-dir /private/tmp/godot-ai-megasmoke-self-update-smoke`, click Update, then click Restart Server after the dock reports plugin install v2.3.3 but server v2.3.2.
- Observed result: dock stayed at `Restarting server...`; localhost status on port 18000 continued to report `{"name":"godot-ai","server_version":"2.3.2","ws_port":19500}`. Harness output showed the restart spawned `/Users/davidsarno/.local/bin/uvx --from godot-ai==2.3.2 godot-ai ...` even though the updated plugin expected v2.3.3.
- Expected result: Restart Server should replace the incompatible server with the version the plugin expects, or the dock should not promise replacement with v2.3.3 when the configured command still pins 2.3.2.
- Repro notes: the harness patches the vNext plugin to 2.3.3 while `next_server_version` defaults to the base server version. After Update, the mismatch is correctly detected, but recovery reuses the stale `godot-ai==2.3.2` command.
- Severity: high for recovery UX; the main self-update safety checks passed, but the advertised recovery action wedges.
- Workaround: close the disposable editor to let the harness finish; for a real run, manually update the server command/package pin before restarting.
- Suspected component: self-update smoke fixture command patching / `McpServerLifecycleManager.force_restart_server` command selection after plugin version advance.
- Follow-up: branch `codex/megasmoke-results-harness-fix` patches the smoke fixture to override the lifecycle manager's expected server-version seam instead of the stale `plugin.gd` call site, and the harness now fails result processing if a server/plugin version mismatch is reported. Focused unit coverage added in `tests/unit/test_self_update_smoke_harness.py`. Managed-server interactive rerun at 14:27 PDT passed: the dock stayed connected with install v2.3.3 and server `godot-ai==2.3.2`, and the harness printed `PASS: no server/plugin version mismatch reported`. This does not replace the separate foreign/orphan lifecycle matrix.

#### bug — non-godot IPv6 port occupant is ignored on startup and killed on shutdown

- Timestamp: 2026-05-04 14:34 PDT
- Phase: manual orphan/foreign lifecycle matrix / scenario 6 non-godot occupant safety.
- Exact operator action: start `python3 -m http.server 8000` on macOS, then launch `GODOT_AI_MODE=user /Applications/Godot_mono.app/Contents/MacOS/Godot --editor --quit-after 600 --path test_project`.
- Observed result: Python reported `Serving HTTP on :: port 8000`. The plugin still printed `MCP | started server (PID 58665, v2.3.2)` on `127.0.0.1:8000`, connected successfully, and on editor shutdown printed `MCP | stopped server (PID [58666, 58574])`. The temporary `http.server` session then exited; its only request log was a `POST /mcp` returning 501.
- Expected result: non-godot occupant safety should block adoption/spawn, show a warning without a Restart button, avoid kill logs, and leave the original `http.server` listener alive.
- Repro notes: macOS/Python bound the default `http.server` to IPv6 `* :8000`, while the Godot AI server later bound IPv4 `127.0.0.1:8000`. Startup port detection did not treat the IPv6 listener as blocking, but shutdown process discovery included both the godot-ai worker and unrelated Python listener.
- Severity: release-blocking lifecycle safety bug; a plugin-owned stop path killed an unrelated non-godot process on the same configured HTTP port.
- Workaround: bind test occupants explicitly to `127.0.0.1` for now when continuing the matrix, but the product should not kill unrelated IPv6 listeners.
- Suspected component: `McpServerLifecycleManager.start_server` port-in-use check vs `_find_all_pids_on_port` / `_stop_server` ownership filtering mismatch for IPv4/IPv6 listeners.
- Control run: `python3 -m http.server 8000 --bind 127.0.0.1` behaved correctly: startup printed `MCP | proof: (none)` plus an unverified-server warning, did not spawn godot-ai, did not kill on editor exit, and left the Python listener alive until manually stopped.
- Follow-up: branch `codex/megasmoke-results-harness-fix` now confirms POSIX port occupancy with `lsof` even when the IPv4 bind probe succeeds, and filters managed/dev stop kill candidates to godot-ai-branded command lines. Rerun at 15:52 PDT with default `python3 -m http.server 8000` passed: Godot printed `MCP | proof: (none)` and the unverified-server warning, did not spawn godot-ai, left port 9500 unused, and the IPv6 Python listener remained alive until manually stopped.

#### bug — status-name-only Restart-click recovers backend but dock can stay in Restarting

- Timestamp: 2026-05-04 15:15 PDT
- Phase: manual orphan/foreign lifecycle matrix / scenario 5 status-name-only occupant safety.
- Exact operator action: start `PYTHONPATH=/tmp/sim-statusonly python3 -m http_status_only --port 18100 --ws-port 19600 --fake-version 2.1.0`, temporarily set Godot AI ports to 18100/19600, launch `GODOT_AI_MODE=user /Applications/Godot_mono.app/Contents/MacOS/Godot --editor --path test_project`, then click Restart Server.
- Observed result: initial diagnosis passed: `MCP | proof: status_name` and the dock showed fake server v2.1.0 vs expected v2.3.2. After clicking Restart Server, backend recovery also succeeded: Godot printed `MCP | killed pids [35436] on port 18100`, spawned `godot-ai==2.3.2`, and `/godot-ai/status` returned `{"server_version":"2.3.2","ws_port":19600}`. The dock, however, stayed in `Restarting server...` and did not reconnect within ~30 seconds.
- Expected result: after the replacement server starts, the connection should unblock, reconnect, verify the v2.3.2 handshake, clear `_server_restart_in_progress`, and turn the dock green.
- Repro notes: the backend path is good; the stale UI appears to come from `_resume_connection_after_recovery()` requiring lifecycle state READY even though `recover_incompatible_server()` leaves the replacement in SPAWNING until the WebSocket handshake can make it READY.
- Severity: high for recovery UX; not data-loss, but the advertised Restart Server action appears wedged after doing the backend work.
- Workaround: close/reopen or reload the editor after backend recovery; the replacement server is already running.
- Suspected component: dock/client refresh state after `recover_incompatible_server()` / `_resume_connection_after_recovery()` SPAWNING gate.
- Follow-up: branch `codex/megasmoke-results-harness-fix` now unblocks the connection while recovery is in SPAWNING and adds `test_recovery_resume_unblocks_connection_while_spawn_is_in_flight`. Rerun on temporary ports 18100/19600 passed: click printed `MCP | proof: status_name`, killed fake PID 45265, spawned `godot-ai==2.3.2`, logged reconnect attempts, then `MCP | connected to server`; the dock turned green and `/godot-ai/status` reported v2.3.2 with WS 19600.

#### pass — compatible external adoption and managed drift cleanup

- Timestamp: 2026-05-04 14:58 PDT
- Phase: manual orphan/foreign lifecycle matrix / scenarios 7 and 3.
- Exact operator actions: for compatible adoption, run `script/serve-this-worktree`, verify `/godot-ai/status` reports v2.3.2 on ports 8000/9500, then launch Godot with `--quit-after 600`. For managed drift, run `/tmp/orphan-sim` fake godot-ai v2.1.0, seed `godot_ai/managed_server_pid`, `godot_ai/managed_server_version`, and `godot_ai/managed_server_ws_port` in EditorSettings, then launch Godot with `GODOT_AI_MODE=user --quit-after 800`.
- Observed result: compatible adoption printed `MCP | adopted external server owner_pid=60323 (live v2.3.2, WS 9500, plugin v2.3.2)`, left the managed record cleared, and did not kill the external server on editor exit. Managed drift printed `MCP | managed server v2.1.0 does not match plugin v2.3.2, restarting`, `MCP | strong proof: managed_record`, `MCP | killed pids [61190] on port 8000`, then started a fresh v2.3.2 server and connected.
- Expected result: same.
- Repro notes: final preflight after restoring EditorSettings showed managed-server record cleared and no listeners on ports 8000/9500.
- Severity: pass.
- Workaround: none.
- Suspected component: lifecycle manager adoption/recovery paths behaved as expected for these cases.

#### bug — `script_create` can time out while the file is successfully created

- Timestamp: 2026-05-04 14:06 PDT
- Phase: corrected disposable live scenario / script creation.
- Exact tool call: `script_create(path="res://mega_smoke/mega_smoke_controller.gd", content=...)` against `godot-ai-megasmoke-live@e913`.
- Observed result: MCP returned `DEFERRED_TIMEOUT` after 4505 ms, but `filesystem_manage(op="search")` found the script immediately afterward and `script_manage(op="read")` returned the full expected source.
- Expected result: either success once the file/import settles, or a retryable timeout that does not look like a failed mutation when the mutation already committed.
- Repro notes: happened during live creation of a new GDScript under `res://mega_smoke/`; editor readiness was `ready` after the timeout.
- Severity: medium; can cause duplicate retries or false failure reports.
- Workaround: after `DEFERRED_TIMEOUT`, poll `editor_state` and read/search the target file before retrying.
- Suspected component: script create deferred import-settle timeout / response completion.

#### bug — `particle_get` returns ok while emitting editor out-of-bounds errors for unused draw passes

- Timestamp: 2026-05-04 14:11 PDT
- Phase: corrected disposable live scenario / particle readback.
- Exact tool call: `particle_manage(op="get", params={"node_path":"/MegaSmoke/Sparks"})`.
- Observed result: MCP returned a normal `particle_get` response, but the Godot console emitted three errors: `Index p_pass = 1/2/3 is out of bounds (draw_passes.size() = 1)` with backtrace at `res://addons/godot_ai/handlers/particle_handler.gd:538`.
- Expected result: readback should only inspect configured draw passes, or should guard missing draw passes without emitting editor errors.
- Repro notes: create a default `GPUParticles3D`, set main/process properties, then call `particle_get`. The response listed four draw-pass slots even though the particle node only had one draw pass allocated.
- Severity: medium; silent success with red editor errors can hide handler defects and pollute editor logs.
- Workaround: ignore the extra editor errors for now; avoid using `particle_get` as a clean-log assertion until fixed.
- Suspected component: `ParticleHandler.get_particle` draw-pass loop bounds.

#### test gap — destructive live smoke initially targeted `test_project`

- Timestamp: 2026-05-04 13:58 PDT
- Phase: live MCP scenario / session routing.
- Exact tool calls: `scene_manage(op="create", path="res://mega_smoke/mega_smoke.tscn")` and follow-up node/material/script operations were initially sent to `test-project@c4af`.
- Observed result: `test_project/mega_smoke/` was created and Godot autosaved tracked scenes during adjacent smoke scripts. The operator caught the wrong project before the run continued.
- Expected result: destructive live smoke should refuse to run unless the active or pinned session path is a disposable project, not the repo `test_project`.
- Repro notes: `session_manage(op="list")` showed only `test_project` after the initial self-update project was on a different port; the run should have stopped there and launched a disposable project before live mutations.
- Severity: medium as a process/test gap; no lasting data loss in this run. `test_project/mega_smoke/` was removed and tracked `test_project/main.tscn` / `capture_smoke.tscn` were restored to `HEAD`.
- Workaround: gate destructive smoke with an explicit project-path assertion and exact `session_id` before any write.
- Suspected component: MegaSmoke operator checklist / missing preflight guard.

#### friction — default self-update smoke temp dir refused as stale/non-generated fixture

- Timestamp: 2026-05-04 13:48:37 PDT
- Phase: baseline gates / self-update fixture preparation.
- Exact operator action: `script/local-self-update-smoke --no-launch`
- Observed result: harness exited with `FAIL: /private/var/folders/y4/xqc3mdfd76ggjxd9gx3vbly00000gp/T/godot-ai-self-update-smoke has a smoke marker but does not look generated. Pass --project-dir elsewhere or --force.`
- Expected result: either prepare the default disposable fixture or provide a one-command safe fallback for stale generated fixture dirs.
- Repro notes: run the no-launch harness on this macOS host while the default temp dir already contains `.godot-ai-self-update-smoke/marker.txt` but the project does not satisfy `is_generated_smoke_project`.
- Severity: low; no data loss and guard is intentionally conservative.
- Workaround: rerun with an explicit disposable path, `script/local-self-update-smoke --no-launch --project-dir /private/tmp/godot-ai-megasmoke-self-update-smoke`.
- Suspected component: `script/local-self-update-smoke` stale fixture UX / cleanup guidance.

#### bug — `editor_reload_plugin` kills external dev server when a stale managed-server record still matches

- Timestamp: 2026-05-04 13:51:04 PDT
- Phase: baseline gates / reload lifecycle.
- Exact operator action: start `script/serve-this-worktree` on port 8000, confirm editor reconnects, then run `script/ci-reload-test`.
- Observed result: `script/ci-reload-test` created `/Main/ReloadTestCube`, then `editor_reload_plugin` produced no SSE data. The external dev-server terminal exited, and port 8000 was immediately owned by a new Godot-child process: `python -m godot_ai --transport streamable-http --port 8000 --ws-port 9500 --pid-file .../godot_ai_server.pid`.
- Expected result: `editor_reload_plugin` should return `status="reloaded"` with a new session id while the externally-started MCP server remains alive.
- Repro notes: the editor had previously spawned a managed server with version 2.3.2. Starting `script/serve-this-worktree` replaced that listener, but the persisted managed-server record still matched the plugin version. On reload, lifecycle adoption classified the external owner as managed and `_exit_tree` killed the port listener, severing the in-flight HTTP response.
- Severity: high / release-blocking until triaged; this is a reload-path stale ownership failure and turns a documented external-server prerequisite into a silent transport drop.
- Workaround: likely clear the managed-server record and pid-file before adopting a manually-started dev server, or launch from a clean editor settings state. Not verified in this run.
- Suspected component: `McpServerLifecycleManager.adopt_compatible_server` / `_stop_server` ownership classification for external servers when `record_version == current_version`.

#### friction — game capture smoke shebang uses system Python without Pillow

- Timestamp: 2026-05-04 13:53:05 PDT
- Phase: baseline gates / game capture smoke.
- Exact operator action: `script/ci-game-capture-smoke`
- Observed result: immediate `ModuleNotFoundError: No module named 'PIL'` before any MCP/Godot interaction.
- Expected result: script runs in the repo's dependency environment or prints the required invocation.
- Repro notes: this host's `python3` resolves to `/opt/homebrew/opt/python@3.14/bin/python3.14`; the repo `.venv/bin/python` has Pillow 12.2.0.
- Severity: low; environment-only and easy workaround.
- Workaround: `.venv/bin/python script/ci-game-capture-smoke`
- Suspected component: `script/ci-game-capture-smoke` interpreter/dependency UX.

## 2026-04-19 — Smoking PR #78 (`logs_read source=game`)

Smoking PR #78 (`claude/add-game-logs-capture-gtE27`) against a live editor
running on `/Users/davidsarno/godot-assetlib-download-test/` — not the
worktree's own `test_project/`. The installed plugin was 1.0.1; the PR
code had to be rsync'd over from the worktree.

### bug — `push_error("msg")` / `push_warning("msg")` lose the user's text — FIXED in PR #78

`plugin/addons/godot_ai/runtime/game_logger.gd::_log_error` reads only the
`rationale` argument from Godot's `Logger` virtual. For the **single-arg**
common form `push_error("msg")` / `push_warning("msg")`, Godot puts the
user's string in `code` and leaves `rationale` empty. Captured text for
`push_warning("warn-game")`:

```json
{ "level": "warn", "text": " (core/variant/variant_utility.cpp:1034 @ push_warning)" }
```

Leading space because the format string is `"%s (%s)"` with empty
`rationale`; file pointing at Godot's own C++ source instead of the user's
GDScript; the string `"warn-game"` discarded entirely.

Suggested fix:

```gdscript
func _log_error(
    function: String, file: String, line: int,
    code: String,          # <-- rename from _code
    rationale: String,
    _editor_notify: bool, error_type: int, _script_backtraces: Array,
) -> void:
    var level := "warn" if error_type == 1 else "error"
    var message := rationale if not rationale.is_empty() else code
    var loc := ""
    if not file.is_empty():
        loc = "%s:%d @ %s" % [file, line, function] if not function.is_empty() else "%s:%d" % [file, line]
    var text := "%s (%s)" % [message, loc] if not loc.is_empty() else message
    _append(level, text)
```

Bonus: `script_backtraces` carries the real user-script caller — surface
it instead of (or alongside) Godot's internal C++ frame so errors point
agents back at the user script that raised them.

Two-arg form `push_error(code, rationale)` / `push_warning(code, rationale)`
works correctly — the defect only hits the common single-arg case.

Repro: `push_warning("warn-game"); push_error("err-game")` in `_ready()`,
`project_run`, `logs_read(source="game")` → lines 3-4 in the response.

### friction — `editor_reload_plugin` can't recover from newly-added files on disk — FIXED (editor_handler.gd now `fs.scan()` awaits before re-enabling)

Sequence that breaks: rsync PR plugin over an older installed copy (adds
new `.gd` files that declare `class_name`) → `editor_reload_plugin` →
`set_plugin_enabled(false)` succeeds, `set_plugin_enabled(true)` fails
with `Parse Error: Could not find type "GameLogBuffer" in the current
scope`. Godot's class-name registry hasn't seen the new files because the
filesystem hasn't been rescanned since they appeared.

Only recovery is kill + relaunch Godot. Worth either documenting, or
making `editor_reload_plugin` call
`EditorInterface.get_resource_filesystem().scan()` and await
`filesystem_changed` before the disable/enable toggle.

### bug — SEGV in `GameLogBuffer.get_range` on the first call after `editor_reload_plugin` — FIXED in PR #103 (explicit `_exit_tree` teardown; see issue #46)

Same session (see setup for smoking PR #78 Copilot fixes). Rsync'd new
plugin code on top of a running editor, called `editor_reload_plugin`
(disable + re-enable). Reload reported success, session came back as
`ready`. First `logs_read(source="game")` after the reload crashed Godot
with SIGSEGV:

```
GDScript backtrace (most recent call first):
    [0] get_range (res://addons/godot_ai/utils/game_log_buffer.gd:47)
    [1] _get_game_logs (res://addons/godot_ai/handlers/editor_handler.gd:99)
    [2] get_logs (res://addons/godot_ai/handlers/editor_handler.gd:62)
    [3] _call_handler (res://addons/godot_ai/dispatcher.gd:131)
```

Line 47 is `var size := _storage.size()` — the first statement of
`get_range`. The same code passes every GDScript unit test (53/53) on a
fresh editor launch. Only the post-reload first call crashes.

Almost certainly a symptom of **[#46 — Harden plugin against repeated
editor_reload_plugin state corruption](https://github.com/hi-godot/godot-ai/issues/46)**:
handler RefCounted instances built in `_enter_tree` don't get explicitly
released in `_exit_tree`; when Godot reloads the scripts the in-memory
vtables for still-referenced instances go stale, and the next method call
dispatches into freed memory. Worth adding this backtrace to #46 as
another repro datapoint.

Workaround: relaunch Godot after a reload when possible. Long-term fix
tracked in #46.

### friction — `--reload` uvicorn uses the root repo's src, not the worktree's — FIXED (`script/serve-this-worktree` + dock auto-detect; see issue #84)

Dev server was running as `python -m godot_ai ... --reload` with the
repo's editable install in `.venv`. `import godot_ai` resolves to
`/Users/davidsarno/Documents/godot-ai/src/godot_ai/` regardless of which
worktree I'm in. Had to kill and restart with `PYTHONPATH=<worktree>/src`
to get PR code into the server.

Addressed in two places:
- `script/serve-this-worktree` is the CLI one-liner (prepends
  `<worktree>/src` to `PYTHONPATH`, frees the port, starts `--reload`).
- The dock's **Start Dev Server** button now auto-detects a sibling
  `src/godot_ai/` on the walk-up from `res://` and exports
  `PYTHONPATH=<that>/src` for the spawn. On the root repo it matches the
  editable install and is a no-op; in a worktree it makes the button Do
  The Right Thing without any new UI.

### friction — `scene_create` briefly rejects with `EDITOR_NOT_READY: importing` — FIXED in PR #95 (retryable/state hints on EDITOR_NOT_READY)

Right after a `filesystem_write_text`, readiness flips to `importing` for
~1-2s while Godot reimports. `editor_state` still reports `no_scene`
during that window, so callers don't have a single source of truth to
poll. Retry-with-backoff works, but consider making `require_writable`
return a distinguishable retryable error (not just a generic
`EDITOR_NOT_READY`) so clients can back off without string-matching.

### what passed cleanly

- `logs_read source="game"` baseline empty shape (test #6)
- `logs_read` default plugin source — legacy `[str]` shape preserved (#7)
- `logs_read source="bogus"` → `ValueError: Invalid source 'bogus'` (#8)
- `offset` / `count` windowing (#10)
- `has_more` + `total_count` pagination (#11)
- Run rotation: stale `since_run_id` → `stale_run_id: true`, empty lines,
  fresh RID (#12)
- Fresh poll after second run returns only new-run entries (#13)
- `since_run_id` matching current run returns populated lines (#14)
- `source="all"` merges streams with plugin-first ordering; each entry
  carries `source: "plugin" | "game"` (#15)
- `logs_clear` clears plugin buffer, leaves game buffer intact (#16)
- Back-pressure: 2500-print loop → `total_count=2000` (cap),
  `dropped_count=505`, `editor_state` returned in 16ms,
  `performance_monitors_get` reported FPS=145 — no freeze (#17)
- Bonus: `editor_screenshot(source="game")` — 1108x623 captured from the
  game process, scaled to 512x287, round-trips visible ColorRect + Label
  content (exercises PR #76's debugger-bridge path)
