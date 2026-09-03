# Plan v3: fix `test_run` transport starvation (MCP disconnect during long suites)

Status: APPROVED for implementation — v3 with round-3 amendments folded in.
v1 review: request changes (frame-yield concurrency blockers) → v2 removed
frame-yielding. v2 review: request changes (poll() is not heartbeat-only;
single-frame fallback unsafe) → v3 added drain-and-reject servicing and a
hard stop/re-vet gate. v3 review: **approved** with three clarifications
(drain-to-quiescence, discovery lifecycle, paused-response correction) —
all folded in below. Dispositions: §8. Resolved decisions: §9.

Origin: Discord report (SloppyMayor, 2026-07-21/22, Godot 4.7.1 + plugin
3.0.5), diagnosis verified claim-by-claim against this repo at `764c9c4`.

## 1. Problem (condensed)

`run_tests` runs the whole suite synchronously on the editor main thread
(`test_handler.gd:51` → `test_runner.gd:110-172`). The WebSocket is serviced
only by `McpConnection._process` (`connection.gd:124-154`); the Python server
pings every editor peer and closes the session when the pong is late. At the
time of this plan the server inherited the `websockets` defaults (20 s ping
interval / 20 s pong deadline, so a ~20–40 s window); since #958 it pins the
keepalive explicitly — `DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS` (20 s) and
`DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS` (60 s) in
`transport/websocket.py` — so the window is now ~20–80 s. The numbers below
were written against the historical 20/20 defaults; the servicing design is
unchanged, only the threshold moved. Any suite whose synchronous run exceeds
the window starves the pong; the server closes the socket (1011), unregisters
the session (`websocket.py:354-374`), and fails the in-flight `test_run`
future with `ConnectionError`. The 120 s `TEST_RUN_TIMEOUT_SEC` never fires —
the heartbeat always wins. Threshold is duration, not count: our
63-suite/~2000-test corpus passes in CI; the reporter's 299 heavy tests
(~107 s) cannot.

## 2. Design evolution and the hard decision gate

- **v1**: deferred, frame-yielding runner. Rejected: yielding editor frames
  mid-suite turns snapshot-diff leak cleanup into a deletion path for
  legitimate nodes, violates the no-caching-`get_edited_scene_root()` rule,
  and needs an orphanable exclusive-run gate.
- **v2**: synchronous runner + "heartbeat-only" cooperative `poll()`.
  Rejected: **there is no heartbeat-only mode** — `WebSocketPeer.poll()`
  buffers inbound application frames. Commands from other clients would
  accumulate silently during a run and replay *stale* afterward (their
  server-side futures are popped after the 5 s default timeout,
  `websocket.py:430-455`) — exactly the "uncorrelatable surprise write"
  that `dispatcher.clear_command_queue()` (#712) exists to prevent, plus a
  packet-buffer exhaustion risk under flood.
- **v3 (this plan)**: synchronous runner + cooperative servicing that
  **drains and rejects**: every application frame received during a run is
  answered immediately with a structured retryable busy error, never
  buffered past the run, never dispatched.

**Hard gate replacing v2's fallback clause:** the step-1 spike (§6 harness)
must prove that cooperative `poll()`-based servicing keeps the session alive
through a ~50 s run. If it does not, **Phase 1 stops and the plan returns to
vetting** — the previously-sketched "await a single frame between tests"
fallback is withdrawn entirely, because one frame yield runs
`McpConnection._process` → drain → `dispatcher.tick()`, reviving every v1
concurrency hazard (interleaving, cleanup deletion, root caching, autosave
exposure, exclusive-run lifecycle). There is no safe in-plan fallback.

## 3. Phase 1 design

### D1: cooperative servicing = poll + drain-and-reject

New `McpConnection` method, called only by the test runner via callback
(doc-commented contract: exclusive-run servicing, not general use):

```
enum ServiceStatus { SERVICED, DISCONNECTED, PAUSED, BLOCKED }
func service_transport_during_exclusive_run() -> ServiceStatus
```

- `connect_blocked` → `BLOCKED` (unreachable via MCP in practice — a blocked
  connection never carried the command — treated like DISCONNECTED by the
  runner).
- `pause_processing` active → `PAUSED`, **without polling**. See §9 Q2: the
  runner treats this as an abort-worthy invariant violation, because a
  leaked pause at a between-test boundary would otherwise silently skip
  every subsequent poll and recreate the exact starvation this plan fixes.
- Otherwise: **drain to quiescence — never spill buffered packets to a
  later checkpoint**. A full application-packet queue can prevent `poll()`
  from reading deeper into the TCP stream (including a ping behind those
  packets), and any deferred packet decays into a stale command. Loop:
  1. `_peer.poll()`.
  2. Drain and handle every currently available application packet.
  3. `_peer.poll()` again now that inbound capacity is free.
  4. Repeat until no packets remain (the flood cap guarantees termination).
  5. If the cap is reached mid-loop, close with 1013 immediately.

  Each drained packet is handled by kind:
  - `handshake_ack` → existing ack handling.
  - Malformed frame → existing warning + INVALID_PARAMS reply path.
  - Valid command frame → **immediate rejection reply** over the socket:
    top-level `EDITOR_NOT_READY`, `data.sub_code = EDITOR_TEST_RUNNING`,
    `retryable = true`, hint: *"A test run is in progress on this editor;
    retry when it completes, or fetch results afterward with
    test_manage(op=\"results_get\")."* Readiness + error-watermark stamped
    like the existing malformed-frame reply (`connection.gd:437-446`). No
    dispatcher involvement, no execution, no allowlist — `get_test_results`
    is also rejected (mid-run progress is Phase 2).
  - Implementation shares parsing with `_handle_message` via an extracted
    `_classify_message(raw)` helper — the normal path enqueues commands, the
    service path rejects them; one parser, two sinks.
- Return `DISCONNECTED` when the peer leaves `STATE_OPEN`.

**Flood policy** (cap approved at review round 3): the counter counts
**every application packet processed during exclusive servicing** — valid
commands, malformed frames, and handshake-like frames alike — so no frame
kind can evade it. It lives in a small mutable run-state dictionary owned
by the runner and passed into the service callback (no connection-global
begin/end state, so there is no lifecycle to leak or clean up). At **2048**
cumulative packets the connection is closed
(`_peer.close(1013, "command flood during test run")`) and `DISCONNECTED`
is returned; the run aborts at that checkpoint with results preserved.
Rationale for 2048: it leaves headroom under Godot 4.5's default
`max_queued_packets` of 4096 (both directions) and sits above stormtest's
~1000-call **default** workload (the brutal configuration is ~9000 and is
expected to trip the cap — that is the cap working). Treat 2048 as
telemetry- and benchmark-tunable in the implementation PR: if emitting 2048
rejection envelopes materially extends a checkpoint, lower it.

**Final checkpoint:** after the last test and before the handler builds its
response, one more drain-to-quiescence pass so no already-buffered command
survives into the post-run `_process` drain. Commands arriving *after* that
final pass are genuinely fresh (their futures are still pending against
5–15 s timeouts) and execute normally after the run — correlated, not stale.

**Servicing checkpoints:** after each test, after each
`suite_setup`/`suite_teardown`, after each suite's leak-cleanup pass, and
between per-file `ResourceLoader.load()` calls in
`test_handler._discover_suites()`.

**Transport-loss reality check (per review):** if servicing observes
`STATE_CLOSED`, `McpConnection._connected` remains `true` until the next
`_process` pass, so the handler's normal response is not "skipped by the
`_connected` check" — it reaches `_send_json`, whose `send_text` fails
against the closed peer and returns `false`. Functionally fine; documented
as the actual behavior, and tests assert the runner outcome, not send
success.

### D2: per-call time budget + explicit runner outcome contract

- `src/godot_ai/handlers/testing.py`: raise `TEST_RUN_TIMEOUT_SEC` 120→300
  and inject `params["timeout_budget_sec"] = TEST_RUN_TIMEOUT_SEC` into the
  `run_tests` envelope — one shared constant, so the wire value and the
  `asyncio.wait_for` deadline cannot drift. (Replaces v1's handshake-ack
  advertisement, which raced registration at `websocket.py:225` vs ack at
  `:240`.)
- Plugin validation: numeric (int/float), finite, then clamp to
  **[30, 3600]**; malformed/missing/non-positive → conservative default
  **110 s** (safe inside an old server's 120 s). Old plugins ignore the
  unknown param; old servers don't send it — both directions degrade to
  today's behavior.
- Runner ceiling = `budget − 10 s`, checked at the same between-phase
  checkpoints. **Best-effort, not a guarantee**: an atomic phase (test body,
  setup/teardown, one script load) that starts before the ceiling can
  overshoot it, and a hard main-thread block still dies by heartbeat
  (~40 s under the historical 20/20 defaults, ~80 s with the 60 s pong
  deadline pinned since #958) — which is the desired fail-fast for genuine
  hangs, and the
  server fails the in-flight future immediately on that disconnect (#690).
  No cancel op in Phase 1 (nothing can be dispatched mid-run to deliver
  one); a client that cancels early leaves the plugin finishing a run
  nobody awaits, bounded by the ceiling. Documented.
- **Outcome contract** (per review — response-envelope ownership is the
  handler's, not the runner's): a new serviced entry point (existing
  `run_suites()` keeps its exact signature/return for direct callers and
  fixtures; both drive one shared execution core):

  ```gdscript
  ## run_suites_serviced(...) ->
  ## {
  ##   "outcome": "completed" | "timeout" | "transport_lost" | "paused",
  ##   "results": <same dict get_results() returns>,
  ## }
  ```

  Handler mapping — deterministic, no ambiguity:
  - `completed` → `{"data": results}` + today's `load_errors` /
    `edited_scene` / `scene_warning` annotations.
  - `timeout` → `TEST_RUN_TIMEOUT` error envelope; `error.data` carries
    partial counts, elapsed, remaining estimate, filter hint; full partials
    stay retrievable via `test_manage(op="results_get")`.
  - `transport_lost` → the data envelope is still returned to the
    dispatcher (a sync handler must return something); the send fails
    against the dead peer as described in D1. Results preserved for
    `results_get` after reconnect.
  - `paused` → `INTERNAL_ERROR` envelope with the observed pause depth in
    `error.data` + partials note. Delivery is normal, not deferred
    (corrected at review round 3): in the live MCP path `run_tests` itself
    executes through `_call_handler`, whose pause-depth guard
    (`dispatcher.gd:276-286`) restores any leaked depth right after the
    handler returns — so the response goes out in the same `_process` pass.
    A live-dispatch test proves both the error response and the restored
    depth.

  Every non-`completed` path that has entered a suite runs current-suite
  `suite_teardown` + ownership-safe cleanup, restores `console_echo`, and
  unregisters the capture logger before returning; an abort during
  discovery (below) skips suite teardown — no suite has begun.

- **Discovery is inside the outcome lifecycle** (review round 3): the
  budget deadline starts *before* `_discover_suites()`, and the previous
  run's results are cleared before discovery so an early abort can never
  expose stale results through `results_get`. Discovery checkpoints check
  both servicing status **and the ceiling** — a pathological discovery
  phase is bounded by the same advertised budget as the run itself.
  Discovery returns its partial `load_errors` plus an optional terminal
  outcome (`timeout` / `transport_lost` / `paused`), which the handler maps
  through the same envelope contract above.

### D3: forbid `run_tests` inside `batch_execute`

Add `"run_tests"` to the existing `FORBIDDEN_SUBCOMMANDS`
(`batch_handler.gd:10`); error message points at the `test_run` tool.
`get_test_results` stays batch-allowed. Direct fixture calls and
`run_suites()` untouched. (Also resolves the 30 s Python batch timeout
mismatch, `batch.py:28`.)

### D4: per-test duration in results

Add `duration_ms` to each per-test result entry (`test_runner.gd:98` block).
Additive; surfaced by `verbose=true`; makes the "find the slow test"
guidance actionable.

### D5: close-code telemetry, concrete

`SessionRegistry.unregister()` already emits a `GODOT_CONNECTION`
`disconnected` telemetry event (`registry.py:169-180`). Changes:
- `websocket.py` passes an optional normalized `close_code: int | None`
  into `unregister()` from the `ConnectionClosed` exception; the numeric
  code joins the telemetry payload (e.g. `{"event": "disconnected",
  "close_code": 1011, ...}`).
- The free-form close *reason* goes to local logs only, never telemetry.
- This directly measures the 1011 rate before/after release.

### D6: unchanged decisions

- Server heartbeat settings stay default (#698 fail-fast preserved).
- Per-test #19 leak cleanup byte-identical (no yields → no new exposure).
- Error-code parity: `TEST_RUN_TIMEOUT` and the revived
  `EDITOR_TEST_RUNNING` sub-code added to both `utils/error_codes.gd` and
  `protocol/errors.py`. (`EDITOR_TEST_RUNNING` returns from v1 in a much
  narrower role: emitted only by the service-reject path, no dispatcher
  gate.)
- No `in_progress` field (unobservable in Phase 1; Phase 2 adds it with
  `elapsed_ms` + `run_id`).

## 4. Implementation steps

1. **Spike/harness (red on HEAD)**: `script/ci-slow-suite-smoke` (§6) as the
   first commit of the feature branch; record the HEAD failure mode in the
   PR. This is the §2 hard gate — if cooperative servicing can't keep the
   session alive, stop and re-vet.
2. **Connection**: `_classify_message` extraction;
   `service_transport_during_exclusive_run()` with drain-and-reject, flood
   cap, status enum.
3. **Runner + discovery lifecycle**: shared execution core;
   `run_suites_serviced` with checkpoints, ceiling, outcome contract,
   teardown-on-every-exit; discovery inside the deadline/outcome lifecycle
   (results cleared first, no suite teardown before a suite begins);
   `duration_ms`.
4. **Handler + wiring**: budget validation/clamp; outcome→envelope mapping;
   connection ctor arg (4th, default `null`); `plugin.gd:306` registration
   args; discovery servicing.
5. **Server**: timeout constant 300 + envelope injection; close-code →
   `unregister()` → telemetry; batch denylist + tests; error codes both
   sides.
6. **Docs**: `docs/testing.md` (budget/ceiling/best-effort framing,
   residual-limitation wording from §5, busy-error behavior for concurrent
   clients, batch rejection); `tools/testing.py` docstring.

## 5. Visible behavior changes (release-notes material)

- Full-suite runs no longer drop the MCP session. The editor still freezes
  during a run (unchanged; interactivity is Phase 2).
- **Concurrent commands during a run now get an immediate retryable
  `EDITOR_NOT_READY` / `EDITOR_TEST_RUNNING` busy error** instead of
  five-second timeouts followed by session death (v2's "timeouts as today"
  expectation is superseded — timeouts would imply buffered stale commands,
  which v3 forbids).
- Runs may take up to ~290 s before aborting with `TEST_RUN_TIMEOUT` +
  partial results (server budget 300 s, was 120 s).
- `run_tests` inside `batch_execute` is rejected with a clear error.
- Per-test `duration_ms` in verbose results.
- **Residual limitation:** any single non-serviced atomic phase longer than
  the heartbeat window (~20–40 s historically, ~20–80 s since #958) — a long
  test body, `suite_setup`/
  `suite_teardown`, `setup`/`teardown`, one huge script load, a pathological
  cleanup walk — can still starve the transport and end in a heartbeat
  disconnect (which doubles as the hang fail-fast). Servicing happens
  *between* phases; per-test `duration_ms` identifies the offenders.

## 6. Test plan

**Starvation regression harness** — `script/ci-slow-suite-smoke`:
- Fixture suite (`test_mcp_slow_smoke.gd`, ~25 × 2 s busy-wait ≈ 50 s,
  unique suite name) copied into `test_project/tests/`; removal via shell
  `trap` on EXIT.
- Runs `test_run suite=mcp_slow_smoke` (filter excludes the corpus).
- Asserts: the JSON-RPC response arrives **with the original request id and
  correct pass counts** — this is the primary continuity evidence, because
  a heartbeat disconnect fails the server-side future and the client gets
  `ConnectionError` instead of a result. Same `session_id` before/after is
  kept as a sanity check but **not** described as proof of no-reconnect
  (`_session_id` is created once in `_ready` and survives reconnects,
  `connection.gd:61,106`). Additionally: grep the captured server log for
  `Session disconnected` / re-handshake lines inside the run window and
  assert zero.
- Development gate: run against HEAD first; record the reproduced failure.

**Concurrent-client E2E** (new, per review):
1. Start the slow suite from client A.
2. From client B, send a write (`create_node`) mid-run → assert an
   **immediate** `EDITOR_TEST_RUNNING` busy error, not a timeout.
3. After the suite completes → assert the mutation **never appears** in the
   scene.
4. Flood variant: a **mix of valid commands and malformed frames** crossing
   the packet cap — proving neither kind evades it → assert the connection
   closes (1013), the run aborts with preserved partials retrievable via
   `results_get` after reconnect.

**GDScript unit** (`test_project/tests/`):
- `_classify_message`: ack / valid command / malformed classification.
- Service-reject reply shape (code, sub_code, retryable, readiness +
  watermark stamped).
- Flood cap → close + `DISCONNECTED`.
- Runner: ceiling abort (tiny ceiling via runner param) → `timeout` outcome
  + teardown + echo/capture restored; `service_cb` → `DISCONNECTED` →
  `transport_lost` outcome with results preserved; `PAUSED` at checkpoint →
  `paused` outcome + teardown + pause depth logged; **live-dispatch paused
  test**: a run aborted by `PAUSED` while executing through `_call_handler`
  yields the `INTERNAL_ERROR` response AND restored pause depth in the same
  pass; checkpoint cadence (counting fake callback); drain-to-quiescence:
  no packet remains buffered after any checkpoint, and the cap counter
  advances on malformed and ack-like frames, not just valid commands;
  discovery aborts: a terminal outcome during discovery maps through the
  handler contract, skips suite teardown, and never exposes the prior run's
  results; `duration_ms` per entry; refactor-equivalence for
  pass/fail/skip/zero-assert/script-error classification.
- Handler: outcome→envelope mapping (all four); budget validation —
  missing, malformed (string/dict), negative, zero, fractional, sub-clamp,
  over-clamp.
- Batch: `run_tests` rejected; `get_test_results` still allowed.

**Python unit** (`tests/`): shared-constant test (envelope budget ==
`TEST_RUN_TIMEOUT_SEC`); `unregister(close_code=...)` telemetry payload
shape (numeric code present, no free-form reason); error-code parity
extended (`TEST_RUN_TIMEOUT`, `EDITOR_TEST_RUNNING`).

**CI end-to-end**: `ci-godot-tests` full corpus stays green (now exercises
servicing on every run).

**Stress**: stormtest does not call `test_run`, so run stormtest
concurrently with the slow-suite harness on the branch. Expected outcome:
storm workers receive **immediate structured busy errors** during the run
window — not timeouts — with no session death, no wedge, and no post-run
surprise mutations. Record in PR.

**Manual smoke**: reporter-shaped project (heavy scene tests >60 s) via the
local-smoke recipe; partials-after-ceiling by temporarily lowering the
budget; old-server pairing (3.0.5 server from tag checkout → 110 s default
engages).

## 7. Phase 2 (separate future work)

Interactive-editor runs (frame-yielding), reconsidered only with:
ownership-based leak cleanup (track/tag test-created nodes, no
snapshot-diffing), edited-root identity checks across barriers, a single
dispatcher-owned run token with generation counter self-clearing on every
terminal path, `test_manage(op="cancel")`, mid-run progress (`in_progress`,
`elapsed_ms`, `run_id`), and an exact read-only allowlist (plugin command
names: `get_test_results`, `get_editor_state`, `get_logs`). File as a
tracking issue when Phase 1 merges.

## 8. Disposition of v2 review findings

| Finding | Disposition |
|---|---|
| **B1: `poll()` receives command frames; stale execution + buffer exhaustion** | **Accepted — verified** (`send_command` pops futures on 5 s timeout, `websocket.py:430-455`; drain at `connection.gd:203` would replay). D1 is now drain-and-reject with immediate `EDITOR_TEST_RUNNING` busy errors, bounded flood cap with close-on-flood, and a final-checkpoint drain. "Heartbeat-only" language removed. |
| **B2: single-frame fallback revives v1 hazards** | **Accepted.** Fallback withdrawn; §2 is now a hard stop-and-re-vet gate. |
| Transport-loss is not a no-op (`_connected` lag) | **Accepted.** Documented actual `send_text`-fails behavior (D1); tests assert runner outcome, not send success. |
| Stable session ID ≠ no reconnect (`connection.gd:61,106`) | **Accepted.** Harness reworded: original-response completion is primary evidence; session-id check demoted to sanity; server-log grep added. |
| Close-code telemetry: make concrete via `unregister()` | **Accepted — verified** (`registry.py:169` event exists). D5 passes normalized `close_code` into it; reason stays in local logs. |
| Define runner return contract | **Accepted.** Outcome envelope + deterministic handler mapping (D2); `run_suites()` signature preserved via new `run_suites_serviced`. |
| Paused transport should abort | **Accepted** (flips my v2 lean — see §9 Q2). Status enum `SERVICED/DISCONNECTED/PAUSED/BLOCKED` adopted. |
| Stress expectation "ordinary timeouts" unsafe | **Accepted.** Superseded by immediate-busy-error expectation (§5, §6). |

Round 3 (approval review) clarifications — all folded in:

| Clarification | Where |
|---|---|
| No packet spillover across checkpoints — drain to quiescence; close 1013 on cap mid-loop | D1 |
| Cap counts **all** application packets (valid, malformed, ack-like); counter in runner-owned run-state, not connection-global | D1 |
| Discovery inside the deadline/outcome lifecycle; clear prior results first; no suite teardown before a suite begins; ceiling checked at discovery checkpoints | D2 |
| Paused response is sent same-pass via the `_call_handler` depth guard, not queued | D2 |
| Flood-cap wording: above stormtest *default* (~1000, not "brutal" ~9000); headroom under Godot's 4096 `max_queued_packets`; tunable in the implementation PR | D1 |
| Flood E2E mixes valid + malformed frames | §6 |

Round 1 (v1 review) dispositions are preserved in git history
(`docs/test-run-transport-starvation-plan.md` @ v2); summary: both blockers
eliminated by dropping frame-yielding; all six major findings accepted, of
which the gate/allowlist items moved to Phase 2 prerequisites.

## 9. Resolved decisions (formerly open questions)

1. **Spike timing** — RESOLVED: spike-first as the first red/green commit of
   the feature branch (§4 step 1). If cooperative servicing cannot keep the
   session alive, Phase 1 stops and returns to vetting; no in-plan fallback
   exists. (Reviewer and author agree.)
2. **Paused transport at a checkpoint** — RESOLVED: **abort** with teardown,
   preserved partials, and logged pause depth (`paused` outcome). Rationale
   for flipping from "accept the conflation": the #712 depth-restoration
   guard only covers handlers invoked through `_call_handler`; a test that
   constructs a handler directly and crashes inside a pause window leaks
   depth *outside* that guard, and skip-poll-while-paused would then
   silently starve the heartbeat at every remaining checkpoint — recreating
   the exact bug this plan fixes, minutes from the cause. Abort surfaces the
   invariant violation at the first checkpoint that observes it.
3. **Budget clamp floor 30 s** — RESOLVED: keep. Purely defensive (no
   user-facing knob exists in Phase 1; the new server always injects 300);
   revisit only if a public `timeout_sec` parameter is added later.
