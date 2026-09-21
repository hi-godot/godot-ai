# Windows startup and lifecycle review, September 2026

Focused repairs improve startup and recovery without another transport rewrite.
The changes retain authentication, signed updates and exact process ownership.
They do not complete production upgrade qualification or restore self-update
without an editor restart.

## Changes and their purpose

- Recover a lost editor socket by probing the existing backend. Retain an owned
  process only when its fingerprint and authenticated listener still match.
  A healthy shared backend no longer restarts merely because its socket dropped.
- Use one three-second status-probe deadline. On Windows, skip a dead TCP connect
  when a temporary loopback bind proves that no listener occupies the port.
  An occupied port still receives the authenticated HTTP probe.
- Collect bounded Windows process ancestry once per proof boundary. Prefer an
  existing PowerShell 7 installation and retain the Windows PowerShell fallback.
  Reuse a worker snapshot for the launcher only when its ancestry proves the
  relationship. Capture both independent kill-grant snapshots in one shell
  invocation; revalidate identity again before a kill.
- Give short discovery commands up to 250ms to finish before expensive process
  grant capture. This time counts against the command deadline, and cancellation
  remains latched. Resolve a Python launcher's base interpreter when its own
  directory has no `pythonw.exe`.
- Block nested dispatcher ticks and reserve reload before scheduling it. Hold
  later commands until the filesystem scan and reload settle; release the
  reservation on timeout. Reject reload inside a batch before any operation runs.
- Allow replacement to wait up to 60 seconds for the old listener to exit. One
  Windows handoff took 25.262 seconds, exceeding the former 15-second bound.
  This prevents premature failure; it does not establish acceptable handoff speed.
- Distinguish installed files from a usable connection in update messages. Remove
  permission-repair advice that could recommend deleting a repository merely
  because an ancestor directory was named `godot-ai`.

The [lifecycle reference](server-lifecycle.md) documents the ownership and reload
contracts. The dispatcher reservation covers queued commands, not quiescence of
all previously started deferred work or dock callbacks during an active handler.

## Startup measurements

Visible-editor runs used one Windows machine with Godot 4.7.2 and an installed
PowerShell 7. The endpoint was the observer's authenticated editor connection.
Warm runs reopened an imported project with the backend closed and its package
cache retained. Excluded warmups and sampled screenshots followed the
[verification procedure](verification.md).

| Comparison | Baseline | Candidate | Interpretation |
| --- | ---: | ---: | --- |
| Skip an unbound Windows connect, three runs per arm | 13.014s median | 10.171s median | Matched comparison; 2.844s saved. |
| Reuse worker ancestry, ABBA order | 10.432s mean | 9.558s mean | Two runs per arm; 0.874s saved. |
| Combine ancestry reuse with paired snapshot collection | Prior baseline about 10.2–10.4s | 9.023s median | Three runs, not interleaved with baseline. |

The combined samples were 8.965, 9.708 and 9.023 seconds. They qualify the normal
warm path on this machine, not a tail-latency bound or a gain on every Windows
installation. Shared-snapshot experiments also produced 14.916- and 15.114-second
starts. Those outliers remain unexplained. Instrumented repeats completed in
about 9.2–9.4 seconds but did not explain the slow cases.

Paired snapshot collection alone reduced a grant capture from about 1.70 to
0.94 seconds without improving whole-editor startup in its separate series.
The combined candidate, rather than that isolated operation, justified adoption.
Hidden Tools and Settings tabs took approximately 22ms to construct. No lazy-tab
refactor was accepted. Visible client rows took approximately 335–379ms.

Earlier published-version observations were 8.4 seconds warm for plugin 3.2.5
and 41.1 seconds for 4.0.4. The v3 endpoint was a handshake acknowledgement,
not v4 authentication, and the runs used different Python and dependency
versions. Early cold runs also had unequal package-cache preparation. Those
observations describe the regression seen here but cannot isolate architecture
cost or establish comparable failure rates.

## Verification

The final production snapshot passed the full live Godot suite with 2,318 passed,
zero failed and 30 skipped across 73 suites. Concurrent stress made 1,143 calls:
1,126 succeeded, 17 had tolerated reload transients, and none had unexpected
failures. Both reloads recovered within the 30-second deadline. A separately
inspected plugin-only reload kept the same editor process, showed a connected
dock and returned an authenticated ready editor state.

Actual dock-button updates from local 3.2.5 and 4.0.4 fixtures to local 4.0.5
completed installation, restart and client migration. Each updated dock was
visually inspected and each exact project returned authenticated editor-state
and scene-hierarchy reads. These fixtures substitute local signing keys,
release metadata and runtimes. The v3 fixture does not run its published old
backend. They do not qualify the untouched production update journey.

The full pre-commit Python run passed 2,592 tests with 55 skips, with
`GODOT_BIN` set so the real-editor rows ran. The full CI Ruff scope also passed.
An earlier test-only UTF-8 omission was corrected. A separate run lacked Git
Bash/OpenSSL on PATH; its failures are retained locally, and the full suite
was rerun with those installed tools available.

Detailed experiment receipts and failed runs remain local. They include the
matched ABBA comparison, individual startup observations, full suite logs,
concurrent stress results and before/after upgrade screenshots. Private runtime
records, caches and signing material are not release artifacts.

## Remaining release gates and priorities

1. **Seamless upgrade from the published 3.2.5 stack with a client still attached.**
   The untouched 3.2.5-to-4.0.4 journey failed: files installed, Python GUI-launcher
   discovery broke migration, and an old client retained the port. Closing the
   client manually did not satisfy the seamless-upgrade requirement. This is the
   next priority because 3.2.5 remains the asset-store starting point.
2. **Self-update without restarting Godot.** Plugin-only reload is verified,
   but in-editor installation and activation remain unimplemented. Startup
   process-proof improvements can be reused by that path.
3. **Actionable startup status.** Routine loading can still show red
   **Connection blocked**. An absent `exit_ms` can display a fabricated **0.0s**
   lifetime. Show progress during startup and an observed reason on failure.
4. **Startup variability and package-path robustness.** A diagnostic backend
   failed before publishing capabilities while installing into a 261-character
   cache path. A shorter isolated cache succeeded. The OS long-path setting did
   not prevent the failure. That diagnosis is not a production path-length fix,
   and it does not explain the separate slow warm starts.

These checks qualify this repair set for review, not a production release.
Further refactoring should start from a reproduced failed user journey and
remove duplicated work or ownership decisions demonstrated by that journey.
