# PR #949 release review follow-up — 2026-09-02

This is development evidence for the follow-up to
[dsarno's eight-point review](https://github.com/hi-godot/godot-ai/pull/949#issuecomment-5518500426).
It is not a production candidate approval. The separately approved
[verification contract](architecture-simplification-verification-plan.md)
still applies in full.

## Review dispositions

| Point | Implemented boundary |
|---|---|
| 1: promotion provenance | Before every cross-run download, require the canonical qualification workflow, repository, `workflow_dispatch`, `main`, successful run/attempt and every job, including the complete-evidence gate. Approval binds the run, attempt, workflow commit and both candidate inventories. |
| 2: attestation source | Fixed `dsarno/godot-ai-release-attestations`; full main-reachable commit and bounded relative JSON path; canonical full evidence objects, not dispatcher-selected repositories or example strings. |
| 3: shell injection | Strict canonical version/source validation; user/matrix values enter shell commands only through quoted environment variables. |
| 4: reviewed signing source | A must equal the workflow's `main` commit; B is its immediate child with only two version edits and the bundled README deletion. Packaging has no signing credentials. The signer executes reviewed tooling, not B's checkout. |
| 5: publication permission | Both publishing jobs use the reviewer-gated, main-only `release-publish` environment. Owner verified PyPI's matching environment-bound publisher and removed the older `(Any)` entry. |
| 6: tag and partial-publication handling | Required tags are local to disposable builds. Before PyPI, any existing public tag/release must match approval. Partial matching uploads resume without overwrites; public PyPI bytes are re-downloaded and verified. |
| 7: download action | Correct `download-artifact` SHA and explicit `actions: read` for cross-run downloads; both revised workflows pass actionlint. |
| 8: artifact exercise | Portable exact-tree/hash checks, signatures for all six release assets, exact wheel/sdist identities, retained dependency inventory, offline A/B installs/tests, and the actual documented installer for both A and B. A package version probe alone cannot authorize promotion. Full runtime/failure/stress qualification remains incomplete, as detailed below. |

Every v4+ B reserves the immediately following patch number permanently.
Patch publication skips it (`4.0.0` → `4.0.2` → `4.0.4`); minor and major
publication retain their normal semantics. B cannot reserve an arbitrary
future minor or major version. Signing any failed final candidate is still an
identity-consuming event, not permission to replace signed bytes under that
identity; final signing remains blocked until the missing producers exist.

## Update and shutdown fix

The previous dispatcher correctly refused hot script replacement when a
loaded handler could not prove quiescence, but no built-in handler supplied
that proof. Ordinary shutdown also ignored the failed `clear()`, retaining a
handler/dispatcher reference cycle. This could both refuse Update after real
tool use and leak resources at editor exit.

Built-in handlers now share an explicit quiescence contract. Detached scene,
filesystem, resource-write, project-run, reload and debugger continuations
register work in a process-wide ledger until their actual coroutine returns.
Clearing a request or replacing a composition cannot erase that proof.
Unknown/custom handlers still refuse replacement unless their own drain hook
returns a valid success result. A busy preflight leaves the live lifecycle
untouched so the user can retry.

Ordinary shutdown releases the dispatcher graph only after transport teardown
and worker shutdown. That operation does **not** claim script-swap safety;
the hot-update path keeps its stronger checks. Regressions cover retained
references, untracked handlers, busy continuations, early returns, custom
handlers and an unchanged lifecycle after a busy preflight.

## Development validation

### Pinned qualification engine bytes — September 3

The six official 4.7.0/4.7.2 engine binaries now have source-controlled exact
size/SHA-256 pins in `docs/verification/godot-builds-v1.json`, with reproducible
archive provenance alongside it. All six downloaded archive hashes matched
the official release-asset digests, and each listed executable's size/hash
was independently checked against its archive entry. Runtime checks happen
before even executing `--version`; aggregate validation rejects a changed
engine digest or missing identity. The workflow uses the setup action's
explicit executable path, including its extensionless Windows hardlink.

The initial real-binary smoke caught that the general release-file size limit
is smaller than the macOS engine. Engine verification now streams the digest
after checking its own exact pinned size, without relaxing release limits.
The official macOS 4.7.2 executable passed the real identity/version check.
All 27 focused engine/runtime regressions pass; the new pin verifier has 100%
line coverage. The live headless suite passed 2,140 tests, zero failures,
24 skips, all 71 suites, followed by normal editor/server shutdown. The clean
full Python rerun passed **2,695 tests**, with **36 conditional/platform skips**
and the existing Starlette/httpx deprecation warning. The broader focused
release/security set passed **142 tests**; explicit real-Godot driver/updater
checks passed **14 tests**. Ruff, actionlint, changed-file formatting, whitespace
checks and all eleven architecture gates passed. No production code changed.

This is executable identity evidence, not complete app-bundle/runner integrity
or signed-candidate qualification. The final source/pin review and all
remaining runtime/failpoint/stress gates still apply; preflight remains closed.

A read-only configuration recheck confirmed both `release-signing` and
`release-publish` allow only the `main` branch and require `dsarno` review.
`RELEASE_SIGNING_KEY_PEM` is present in the signing environment (metadata only;
its value was not read). The attestation repository is public, has Actions
disabled, and lists only `dsarno` as a collaborator with write/admin access.
This is a setup observation, not a key-fingerprint check, credential-scope
negative test, signed-candidate approval, or renewed PyPI publisher check.

### Runtime setup and engine-row follow-up — September 3

The first runtime slice is now expanded to separate 4.7.0 and 4.7.2 jobs on
every desktop OS at Python 3.11/3.14. Artifact names and aggregate row keys
retain the engine version, preventing one engine result from satisfying both
required builds. The runtime checks the reported stable official version and
retains the executable hash; the later pinning follow-up above adds the
per-platform expected binary identities for review before qualification.

Review of the not-yet-signed path found three setup defects: the headless
plugin opt-in was absent, the case attempted to recreate its parent row output
directory, and manifest paths retained their `addons/godot_ai/` prefix when
compared with an add-on-relative live/backup inventory. Each is corrected with
direct regression assertions. This remains development harness work, not an
exact signed-candidate qualification result; the pre-signing guard stays closed.

Validation: the full Python run passed **2,681 tests** with **36 conditional
skips**; the final focused release/security set passed **129 tests**, including
the subsequently added missing-engine-row aggregate regression. The real
Godot 4.7.2 driver parse check passed. The full live headless corpus passed
**2,140 tests**, **zero failures**, **24 skips**, all **71 suites**, followed by
normal editor/server quit. Ruff, actionlint and all eleven architecture gates
pass. The prior pushed commit's hosted run separately exposed a Windows 3.13
two-second readiness-barrier failure in
`test_write_readiness_rejects_changed_live_tree`; that timing investigation is
being handled separately and is not represented as a green hosted gate here.
The subsequent `ef2d53d` checkpoint passed all 32 jobs in
[its hosted run](https://github.com/hi-godot/godot-ai/actions/runs/33793021903).
That clean run does not resolve the earlier timing flake or validate the later
engine-pinning changes.

### Exact-candidate A to B runtime producer — September 3

The qualification workflow now has its first immutable runtime producer slice.
`script/runtime_qualification.py` binds to the matching retained Python evidence
row, installs signed A with the documented verifier, supplies exact A/B wheels
through the private PEP 503 index, serves B's retained six-asset release over the
authenticated private HTTPS origin, and drives a real Godot editor with only
project-owned transport/automation scripts. Neither candidate add-on is patched.
The case verifies a distinct matching B backend, automatic client repin, exact B
live inventory, exact A retained backup, successful claim, durable migration
completion, released activation lock and secret-free retained output.

The row validator now requires explicit complete case sets for runtime,
failpoint and stress evidence. A sparse row containing only this A -> B case is
rejected even if it claims `passed`; the remaining named runtime cases are the
final-v3 one-click path, complete candidate functional/security checks,
reopen/backup restoration and repeated crash regression. The workflow's
pre-signing guard remains closed while those cases, the complete failpoint row
and the complete stress row are absent.

Focused release/security verification passed **123 tests**. Eight direct new
tests cover package-source environment isolation, an external-only driver,
secret-free logging/persistence scanning (including the opaque private-index
path capability), exact Python-row/candidate binding and
sparse/duplicate/failed-case rejection. A real Godot 4.7.2 parse-only
control passed for the two harness scripts with the candidate plugin
deliberately disabled; it proves harness parsing, not an exact-candidate runtime
result. Disposable
unsigned A/B packages were built to
exercise the producer setup. A throwaway key generated for the planned local
control was never passed to the signer because exact candidates accept only the
production trust root; it was deleted. No production key was retrieved, no
candidate was signed, and no qualification or publication claim was made.

The full Python suite passed **2,675 tests** with **36 conditional/platform
skips**. The complete live headless Godot 4.7.2 suite then passed **2,140 of
2,164 tests**, with **zero failures**, **24 headless/renderer skips**, all **71
suites** discovered and the 2,153-test total floor enforced. The explicit
Godot-backed updater/migration/HTTPS/reload/restart set passed **38 tests**.
Ruff, shell syntax, actionlint 1.7.7, bytecode compilation, whitespace checks
and all eleven architecture simplification gates pass.

### #961 integration on the release branch — September 3

The accumulated batch was committed as `84097d7`. The exact changes from
merged #961 (`f3dcc437d01e3bbdda70fb8912b628f7a0db7d1d`) apply cleanly on top;
unrelated newer main-branch changes are not included by this integration.
The owned QA copy includes its new WebSocket timeout and connection comment.
The combined live Godot suite passed **2,153 tests, zero failures, 11 skips,
71 suites**, followed by metadata refresh, exact replacement-session reload
proof, real reads and normal quit without ObjectDB/resource-in-use warnings.
Native GLES findings remain open. Evidence:
`/private/tmp/godot-ai-949-with961-full-godot.log`.
Ruff, shell syntax, actionlint and all eleven architecture gates pass.
The full Python/integration gauntlet passed **2,699 tests, four skips**, in
508.46 seconds with the existing Starlette/httpx warning:
`/private/tmp/godot-ai-949-with961-full-pytest.log`. The earlier manual Update proof
remains evidence for `84097d7`; this keepalive integration does not change the
updater, signing layout, plugin enable/disable or startup barrier behavior.

### Current integration checkpoint — September 3, 13:50 UTC

At the owner's explicit request, PR [#961](https://github.com/hi-godot/godot-ai/pull/961)
was independently reviewed and squash-merged to `main` as
`f3dcc437d01e3bbdda70fb8912b628f7a0db7d1d` at 13:46 UTC. All 32 hosted CI
jobs passed on its reviewed head `a6ebbacc152586d22122254d84b0b629cfbe0913`,
including Windows game capture on attempt 1 with PNG color assertions; 100
focused local transport tests also passed. This changes the pong deadline to
60 seconds, retains the 20-second ping interval and saves server-side CI logs.
It does not change authentication, reconnect policy or update transactions.
Review checkout and Windows log: `/private/tmp/godot-ai-pr961-review.ikvdKA/`.
There were no unresolved review threads or blocking findings. The activity
subscription tool was unavailable; no subscription is claimed.

This tested #949 batch is checkpointed from parent `91c4596`; #961 is the next
integration step and was not included in the evidence below. The owner clicked
Update in the current manual fixture, then the agent verified its exact updated
session and requested a normal editor Quit. The harness exited 0 with every
assertion passing: 4.0.1 plugin/backend, durable migration, retained backup,
managed-server replacement, correct exit ordering and no new Godot crash report.
Evidence: `/private/tmp/godot-ai-949-repair-claim-manual.log`; transaction
`6821b1f6f131ea5ab1ca1a0824239e19`. No additional click is required for this
checkpoint. The owner's merge authorization covered #961, not #949 or publication.

The first attempt at five same-editor/backend steady observations stopped on
repetition 2: all 4,000 operations ran and exact disk cleanup passed, but 37
`node_manage.rename` calls failed with `INVALID_PARAMS` because a sibling
already held the requested name. Repetition 1 passed with a 60-second resource
sample stream; the five-run set is **incomplete and failed**, not a baseline.
The editor closed normally with exit 0. All reports, logs and traces remain in
`/private/tmp/godot-ai-release-build.szEA2o/steady-resource-repetitions-20260903/`.
The failure log is `/private/tmp/godot-ai-949-steady-resource-repetitions.log`.

Inspection found a harness setup gap: teardown restored the original scene
and removed scratch files, but Godot retained the scratch editor tab. On the
next run, `create_scene` wrote a new empty file then selected the old tab;
the harness's following save persisted its old nodes again. Setup now first
settles that tab, explicitly force-reloads the new file, and requires a proved
reload plus a single empty `/Root` before any save or worker operation. The
canonical schedule, payload RNG, target identity, cleanup and error policy
are unchanged. This is a harness correction, not an error waiver or production
plugin change. Twelve direct new tests cover ordered/pinned reload, malformed
or incomplete reload/tree proofs, retained children and tool errors. Focused
verification passed **77 tests**; Ruff and architecture gates pass. The first
focused run's one failure was an old source-string assertion for the relocated
hierarchy parsing; its equivalent assertion is updated and the original log
is retained at `/private/tmp/godot-ai-949-fresh-scratch-focused.log`.
The corrected focused log is `/private/tmp/godot-ai-949-fresh-scratch-verified.log`.

A fresh five-repetition run completed with this setup correction through
the unchanged canonical `steady` seed 41001. Each repetition retains exact
4,000-operation/error/cleanup checks, followed by five resource samples over
at least 60 seconds. The controller proves the exact session/project/editor,
binds the backend from the owned launch log plus OS parent identity, and
rechecks process creation times. It does not claim the full internal
pending/session/process/capability/lock census, numeric approval, other storm
profiles/platforms or immutable candidate provenance. Evidence directory:
`/private/tmp/godot-ai-release-build.szEA2o/steady-resource-repetitions-20260903-fresh-root/`;
driver log: `/private/tmp/godot-ai-949-steady-resource-fresh-root.log`.
All five retained summaries, `complete.json` and normal editor exit 0 are
present: **20,000 scheduled operations, 25,860 total calls, zero unexpected
errors and exact cleanup on every repetition**. Observed p95 values ranged
276.2–314.4 ms and p99 430.5–507.8 ms. Post-60-second editor RSS increased
from 1,203,716,096 to 1,234,911,232 bytes between repetitions 1 and 5
(29.75 MiB); backend RSS increased 65,536 bytes, with unchanged descriptor
counts (editor 11, backend 16) and backend thread count 1. Editor threads varied
between 24 and 25. These are observations, **not a no-growth/resource pass**.
The exit log retains 410 native GLES texture-leak warnings. Numeric ceilings
remain unapproved and the separate resource/native findings stay open.

The full Python gauntlet ran after the observations and passed **2,697 tests,
four skips**, in 501.90 seconds, with the existing Starlette/httpx warning:
`/private/tmp/godot-ai-949-fresh-scratch-full-pytest.log`. The fresh live Godot
gauntlet passed **2,153 tests, zero failures, 11 skips, 71 suites**, followed
by same-byte metadata refresh, replacement-session reload proof, real reads
and normal quit without ObjectDB/resource-in-use warnings. Native GLES
diagnostics remain. Log: `/private/tmp/godot-ai-949-fresh-scratch-full-godot.log`.
Ruff, actionlint and all eleven architecture gates pass. The manual check
described above completes this batch's local development gauntlet; none of
these results replace immutable cross-platform release qualification.

### Canonical workload measurement without qualification — September 3 UTC

`stormtest.py --measure-baseline` now runs the unchanged canonical schedule
before numeric ceilings are reviewed while retaining identity, exact cleanup,
coverage and error checks. Every snapshot is explicitly baseline-only, and
every completed run fails qualification with a nonzero exit regardless of
numeric thresholds. Normal qualification still refuses unresolved ceilings
before contacting an editor. No manifest, promotion gate or production plugin
bytes changed in this batch. Focused tests: **65 passed**, including eight new
cases covering permanent refusal, other failures, and CLI preflight boundaries;
Ruff, actionlint and all eleven architecture gates pass.

A real fresh disposable-project observation on Godot 4.7.2 completed the
canonical `steady` seed 41001: **4,000 scheduled operations, 5,172 total calls,
zero unexpected errors, exact cleanup/tree restoration**, and only the expected
`baseline measurement is not qualification` contract failure. It returned 1;
the owned editor then quit normally with exit 0. Observed duration was 69.9 s,
overall p95 275.3 ms and p99 482.3 ms. These are development observations on a
host concurrently running the Python suite, **not isolated performance
baselines, approved ceilings, five workload repetitions or immutable-candidate
qualification**. Native GLES diagnostics (82 texture-leak warnings) and the
`Node` StringName diagnostic remain; no ObjectDB or resource-in-use warning was
observed in this editor's exit log. Error-free MCP calls do not waive those
separate native shutdown findings.

Evidence under `/private/tmp/godot-ai-release-build.szEA2o/`:
`canonical-steady-baseline-41001-retry-{import,editor,storm}.log`,
`canonical-steady-baseline-41001-retry-{report,trace}.json`.
The first diagnostic driver tried connecting before the endpoint was ready;
its import/editor logs remain under the same prefix without `-retry`, and the
tool transcript preserves the connection failure. The retry added a bounded
startup wait. Its measurement succeeded, but its post-run assertion incorrectly
expected exit 2 instead of the existing contract-failure exit 1. That failure is
retained in `/private/tmp/godot-ai-949-canonical-baseline-driver-retry.log`;
independent read-only verification of the report and exit-code contract passed
at `/private/tmp/godot-ai-949-baseline-report-verification.log`. The disposable
driver assertion is corrected; neither failure was suppressed in the runner.

The fresh live Godot gauntlet passed **2,153 tests, zero failures, 11 skips and
71 suites**, followed by same-byte metadata refresh, exact replacement-session
reload proof, real reads and normal quit without ObjectDB/resource-in-use
warnings. Native GLES diagnostics remain. Full Python passed **2,685 tests,
four skips**, in 510.34 seconds, with the existing Starlette/httpx warning:
`/private/tmp/godot-ai-949-baseline-mode-full-{pytest,godot}.log`.
Focused evidence: `/private/tmp/godot-ai-949-baseline-mode-focused.log`;
architecture report: `/private/tmp/godot-ai-949-baseline-mode-architecture.json`.
The repair-claim manual fixture below remains current because this batch only
changes the stress harness. No commit, push, merge, signing or release occurred.

### External repair-claim command boundary — September 3 UTC

The explicit `repair` CLI now supports externally controlled before/after
`repair_claim` publication. It validates intent/lock identity and proves both
recorded owners dead before arming; prior live repair owners still refuse
takeover. This adds no automatic repair, lock stealing, new process authority
or production signing permission. Library entry remains environment-inert;
handled CLI exits scrub the tuple and remove their private controls. A killed
repairer retains its barrier as evidence, and a later explicit repair without
controls preserves that evidence while rolling back and quarantining exact trees.
The coordinator/activation actor recognizes but does not consume this separate
command's effect. Other repair and startup/preparation/abort external boundaries
remain open; this is not completion of section 8.1.

Six new actual repair-subprocess cases cover before/after × continue/fail/kill,
including token rejection, exact live/backup/journal/claim states, startup
refusal without recovery mutation, dead-repairer retry and absence of secrets
in outputs/records. Two independent Python processes provide owner identities;
the initial interrupted activation is an in-process fixture, not candidate or
two-Godot-editor qualification. Additional cases cover live owners/prior repair,
wrong recovery root, malformed capability, timeout, unreachable effect/occurrence,
library inertness and conflicting controller rejection. All **16 focused
selected tests** pass (15 new tests plus an existing CLI test). The first run's
timeout assertion failed because the fixture inherited the helper's `after`
default while asserting before-claim state; it now explicitly requests `before`.
The failure is retained, not discarded:
`/private/tmp/godot-ai-949-repair-claim-{focused,verified}.log`.
An expanded focused coverage run passed 17 selected tests and exercised all
13 executable lines in the new controller guard/scope and repair CLI branch;
this is narrow boundary coverage, not 100% of the transaction module.
Coverage data/report: `/private/tmp/godot-ai-949-repair-claim.coverage` and
`/private/tmp/godot-ai-949-repair-claim-coverage.json`.

The full live Godot run passed **2,153 tests, zero failures and 11 skips across
71 suites**, followed by metadata refresh, exact replacement-session proof,
real reads and normal quit without ObjectDB/resource warnings. Native GLES
diagnostics remain. Full Python verification passed **2,677 tests with four
skips** in 529.55 seconds (the existing Starlette/httpx deprecation warning), at
`/private/tmp/godot-ai-949-repair-claim-full-pytest.log`; Godot evidence is
`/private/tmp/godot-ai-949-repair-claim-full-godot.log`. Ruff, actionlint
and the eleven architecture gates pass. The previous scan-handoff manual
editor was normally closed without Update and is not a pass. Its log and failed
incomplete-fixture assertions remain retained. The new owner-operated fixture is
`/private/tmp/godot-ai-release-949-repair-claim-manual` (HTTP 18350, WS 19850),
with log `/private/tmp/godot-ai-949-repair-claim-manual.log`. It supersedes all
earlier manual fixtures. The owner-operated Update and subsequent normal Quit
are now verified passing in the current integration checkpoint above. This
fixture no longer blocks committing the batch. No production signing or
publication occurred.
Authenticated exact-project editor/scene/project probes passed, and both actor
copies and both reload helpers match current canonical source. Probe evidence:
`/private/tmp/godot-ai-949-repair-claim-manual-probe.log`.

### Native sky allocation growth — September 3 UTC

The retained engine-only reproducer now includes bounded repeated batches and
a smaller direct RenderingServer control. Ten batches of eight environments
with immediate undo cleanup add **55,923,840 bytes** to Godot 4.7.2's texture
accounting, in ten equal increments; **60 seconds idle** does not remove that
increase. The editor exits normally with 160 of the known texture diagnostics.
The paired two-frame deferred-cleanup control has no counter increase and none
of those texture warnings. These observations preclude treating the warning as
proven harmless or merely shutdown-only.

Creating native sky RIDs, changing radiance size to 128 and freeing the RIDs
in the same frame also reproduces growth, with no Environment, material,
undo action or Godot AI runtime involved. Both official macOS **4.7.0 and
4.7.2** accumulate 13,980,800 counter bytes across 80 skies; the 4.7.2 deferred
control remains flat. The pinned engine source suggests dirty-list work can
survive sky RID destruction, but no instrumented engine/fix has validated that
mechanism. The counters and shutdown warning share engine allocation accounting;
actual driver VRAM is not independently measured.

A further small SceneTree control reproduces the same direct-RID failure
in a normal **game process without the editor**: eight skies add 1,398,080
counter bytes and emit sixteen warnings; the deferred-free control remains
flat and emits none. Both 4.7.2 processes exit normally, and a 4.7.0 game
process reproduces the same immediate-free result. This further removes
Godot AI, editor ownership and the test runner as necessary causes.

The [native reproducer notes](verification/native-gles-environment-undo/README.md)
retain controls, precise source links, and limitations. Raw logs and the
60-second/floor repeat summary are in
`/private/tmp/godot-native-env-growth.O7PktR/retained-matrix.log` and its named
logs. The revised single-environment control still reproduces the original two
warnings. No production workaround, suppressed error, upstream issue, engine
patch or release waiver is claimed. Production updater bytes are unchanged by
this diagnostic work; the current manual fixture remains applicable.

### Bounded filesystem-completion handoff — September 3 UTC

The ordinary editor reload now uses the main-thread filesystem completion
notification with a deferred named callback, rather than resuming a suspended
handler coroutine when the scan worker flag clears. The helper owns one
command-scoped signal/timer record. Its five-second native deadline ignores
project pause/time scale; timeout leaves the plugin unchanged. Duplicates do
not start another scan, old callbacks cannot consume a newer request, and a
direct reload cancels the pending scan. Signal connections and script-work
ownership are released on completion, refusal or cancellation. The transaction
coordinator's existing notification-driven scan and all signing/activation
permissions are unchanged.

All **12 real-editor regression cases** pass: the original four persistence
outcomes plus notification ordering, timeout, stale callbacks, duplicate
requests, direct cancellation, a saved user disable, actual source-change scan,
and a real five-second timeout with `Engine.time_scale = 0`. The signed-update
fixture now waits for a genuinely different plugin instance after scheduling
reload, instead of mistaking the still-running old backend for completion.
The two initial test-authoring failures are retained: the disable fixture had
not saved the user's disabled state, and a frame-count watchdog expired before
the legitimate five-second timer in a fast headless editor. Their corrections
preserve all positive state and deadline assertions. Focused evidence:
`/private/tmp/godot-ai-949-scan-handoff-{focused,verified,clock-focused,deadline-focused}.log`.

The previously failing metadata-only refresh now returns the exact authenticated
editor, passes real reads and closes normally. A further run survived **10/10
reloads**, with 2.2–4.3-second recovery and no ObjectDB/resource warning at exit.
These are exploratory reload results, not locked storm or immutable update
qualification. Evidence: `/private/tmp/godot-ai-949-scan-handoff-real-touch.log`
and `/private/tmp/godot-ai-949-scan-handoff-ten-reloads.log`, with the detailed
`retention-suite-v3-touch-*` QA logs and reports.

The first full Python run is retained at
`/private/tmp/godot-ai-949-scan-handoff-full-pytest.log`; it captured the old
frame-watchdog test and its failure (**2,655 passed, one failed, four skipped**),
so it is not a final green gauntlet. The fresh final Python run passed **2,662
tests, four platform skips** in 516.91 seconds, with the existing third-party
Starlette/httpx deprecation warning:
`/private/tmp/godot-ai-949-read-disconnect-full-pytest.log`. The final deadline
revision also passed the full live Godot/reload rerun documented below. Ruff,
actionlint and all eleven architecture gates passed on this working tree.
The signed development update shutdown retention remains present in both
delivery paths (192/80 and 193/80 ObjectDB/resource counts in that first run).
This ordinary reload fix does not claim to resolve those retained graphs or
the independently reproduced native GLES warnings.

The first final-deadline combined Godot/reload rerun passed the functional
suite, then stopped repinning after **2.5 seconds** on a typed, message-empty
HTTPX `ReadError`. This was an immediate harness classification failure, not
exhaustion of its 30-second reconnect budget or the five-second scan deadline.
The failed run is retained at
`/private/tmp/godot-ai-949-scan-handoff-final-full-godot.log`, with its
`retention-suite-v3-touch-handoff-final-combined-*` reports. The harness now
classifies that concrete severed-read exception as a transport disconnect;
it does not catch all HTTP/protocol errors or change any deadline. All **57
storm-support tests** pass, including a replacement-session retry that proves
the same editor PID/project and new session ID, and immediate refusal of
malformed protocol, forbidden HTTP, session and ambiguous-identity errors.
The classification remains unexpected outside a measured reload window.
Fresh full-suite/reload and ten-reload runs both passed, with evidence at
`/private/tmp/godot-ai-949-read-disconnect-full-godot.log`: **2,153 passed,
zero failed, 11 skipped across 71 suites**, followed by metadata-only refresh,
an exact replacement-session proof, real reads and normal close. The separate
ten-reload run survived **10/10**, with no ObjectDB/resource warning on normal
close. One recovery took **22.2 seconds**; the other nine took 2.4–3.7 seconds.
The slow recovery remained inside the existing reconnect budget but is not
claimed as acceptable release latency without the required numeric baseline.
The SDK also reported termination of an old authenticated session as HTTP 401;
no capability bypass was used. Native GLES/Node StringName caveats remain.
Focused test evidence is `/private/tmp/godot-ai-949-read-disconnect-focused.log`.
This harness-only correction does not invalidate the current manual fixture's
production bytes.

The obsolete migration-CLI manual editor was normally closed without Update;
its incomplete result is not a pass. A fresh owner-operated fixture is open at
`/private/tmp/godot-ai-release-949-scan-handoff-manual` (HTTP 18350, WS 19850),
with log `/private/tmp/godot-ai-949-scan-handoff-manual.log`. Exact-project
editor/scene/project read probes passed. Both fixture reload helpers and actor
copies match current source. The owner must still click Update and close this
editor normally before the accumulated batch can be committed. PR #949 is
still open at `91c4596`; nothing was merged, production-signed or published.

### Descendant-marker race and fresh shutdown controls — September 3 UTC

A new combined-run diagnostic retained **one failure, 2,150 passes and 11
skips**: the POSIX descendant test observed a marker file after shell
redirection created it but before `echo` wrote its contents. File existence
passed while the immediately following content assertion read an empty string.
The test now waits for nonempty content within the same 2.5-second deadline;
timeout, surviving-descendant, termination-uncertainty and final content
assertions remain intact. Two direct regressions cover the empty-then-written
window, a persistently empty timeout and unchanged propagation of wrong
nonempty content. No production process-control code changed.

The focused live `cli_exec` suite passes **nine tests, one Windows-only skip**.
The next combined run passed **2,153 tests, zero failed, 11 skips** across all
71 suites. After removing the temporary exploratory subset filter and checking
the handler against canonical source, a further complete run passed the same
counts, followed by identity-bound reload, real read probes and normal quit.
Both fresh combined-run editors exited without ObjectDB/resource warnings.
This does **not** erase the earlier positive full-suite/reload or signed-update
reproductions: broad test loading alone is insufficient to explain retention,
and the earlier source/timing context still needs isolation. The native GLES
diagnostics remain separately tracked.

Ten more single-suite/reload controls and both half-suite/reload controls also
had no ObjectDB/resource warnings. The first matrix stopped before the `editor`
suite on a startup credential-rotation 401; its owned editor was terminated and
the failed log retained. The diagnostic now rereads the capability within its
existing startup deadline rather than bypassing authentication; `editor` then
passed. One earlier client teardown also logged a retained AnyIO closed-stream
diagnostic, so these are not blanket error-free process claims.

Evidence is retained at `/private/tmp/godot-ai-949-retention-lifecycle-suite-matrix.log`,
`/private/tmp/godot-ai-949-retention-halves-matrix.log`,
`/private/tmp/godot-ai-949-retention-combined-bisect.log` (marker failure),
`/private/tmp/godot-ai-949-retention-combined-verified.log`, and
`/private/tmp/godot-ai-949-retention-canonical-combined.log`, with detailed
`retention-suite-v{2,3}-*` logs beneath the existing QA evidence directory.
Ruff, actionlint and all eleven architecture gates pass. The fresh full Python
regression passed **2,648 tests, four platform skips** in 474.51 seconds, with
the existing Starlette/httpx deprecation warning:
`/private/tmp/godot-ai-949-marker-content-full-pytest.log`.
The manual Update fixture is unchanged and still pending; nothing is committed,
merged, production-signed or published.

The same-byte filesystem control found a separate reproducible reload failure:
changing only modification times of the 139 QA addon scripts, then invoking
ordinary reload, starts the replacement backend but produces no authenticated
replacement editor session within the unchanged 30-second deadline. This
happens both after the complete suite and after only `server_version_check`;
the full workload is not required. All script hashes remained unchanged.
Both failed reports and owned-editor termination logs are retained, not counted
as shutdown passes: `/private/tmp/godot-ai-949-retention-touch-{control,simple}.log`
and the corresponding QA `retention-suite-v3-touch-*` logs/reports.

The pinned engine source explains the ordering hazard:
[Godot 4.7.2's scan completion path](https://github.com/godotengine/godot/blob/4.7.2-stable/editor/file_system/editor_file_system.cpp#L1684)
can expose `is_scanning() == false` before the main-thread resource-reload and
filesystem-change notifications are processed. The current ordinary reload
polls that flag, and its trace re-enables the plugin before the later script
reloads. A temporary QA-only control instead scheduled re-enable after the
filesystem notification; the same metadata-only stimulus then recovered the
exact editor in **3.6 seconds**, passed real reads and quit normally without
ObjectDB/resource warnings. Evidence:
`/private/tmp/godot-ai-949-retention-notification-control.log`.
That prototype has no production-quality deadline/cancellation contract and
was removed; both QA handlers were compared back to canonical source. It is
causal ordering evidence, **not a shipped fix** or proof that it explains all
signed-update retention. Next work must implement a bounded, reload-safe
completion handoff and repeat the full/interactive updater gates before claiming
repair. The transaction coordinator already waits on `filesystem_changed`
instead of polling `is_scanning`; this ordinary-reload result must not be
extrapolated into an unproven diagnosis of the transaction path.

### Process-resource measurement foundation — September 3 UTC

The missing numeric-resource work now has a small read-only collector,
`script/qualification_resources.py`, with psutil 7.2.2 pinned as a test-only
dependency. It samples only caller-supplied PIDs, binds creation time, rechecks
identity with fresh process objects, and rejects dead/reused/inaccessible
processes rather than emitting zeroes. RSS, threads, Unix descriptors and
Windows handles have explicit semantics; unsupported counters are null, not
interchangeable. Windows handle thresholds remain a review question, not a
silent amendment to the verification contract.

Every output record is immediately flushed/fsynced to a new exclusive JSONL
file. Earlier evidence is never overwritten. Incomplete or failed collection
does not return success, and even a complete stream reports only `measured`.
It does not claim process ownership/census, quiescence, baseline completion,
approved ceilings or exact-candidate qualification. Those remain the surrounding
producer's responsibility and the release preflight remains closed.

All **63 focused unit/real-process rows** pass with **108/108 executable
collector lines covered**. They cover all three platform counter branches,
cached-identity hazards, reuse/death, denied access, invalid schedules/counts,
stream retention, existing-file and I/O failures, CLI exit behavior and a real
disposable child process. Only the current macOS process checks have run live;
the tests are included in the existing desktop Python CI matrix, not yet pushed.
Evidence: `/private/tmp/godot-ai-949-resource-collector-final-focused.log` and
`/private/tmp/godot-ai-949-resource-collector-final-coverage.json`.

A real Godot 4.7.2 smoke now proves five retained observations of an
authenticated exact-project editor and its descendant backend listening on the
bound port, followed by normal editor closure. Across the minute, editor RSS
was 1,089,912,832–1,090,011,136 bytes (11 descriptors, 24–28 threads); backend
RSS was 99,598,336–99,647,488 bytes (16 descriptors, one thread). These are idle
development observations, **not** the five workload repetitions or proposed
ceilings. The known native Node StringName remains, with no ObjectDB/resource
warning in this narrow smoke. The first complete run retained **one failure,
2,647 passes and four platform skips**: the repository's encoding gate caught
implicit `Path.read_text()` encodings in the new tests. Those reads/writes now
explicitly use UTF-8; the gate and collector tests pass together (**68 tests**,
still 108/108 collector lines). No gate was disabled. The failed full log is
retained. The fresh full rerun passed **2,648 tests with four platform skips**
in 474.06 seconds, with the existing Starlette/httpx deprecation warning.
The retained paths are
`/private/tmp/godot-ai-949-resource-collector-full-pytest.log` and
`/private/tmp/godot-ai-949-resource-collector-live{.log,.jsonl,-editor.log}`.
The UTF-8 focused evidence is
`/private/tmp/godot-ai-949-resource-collector-utf8-{focused.log,coverage.json}`;
the fresh full run is
`/private/tmp/godot-ai-949-resource-collector-final-full-pytest.log`.
The fresh full live Godot run passed **2,151 tests, zero failed, 11 skips,
71 suites**, followed by exact-project read probes and normal quit. Its
known native GLES texture/Node StringName diagnostics remain recorded:
`/private/tmp/godot-ai-release-build.szEA2o/resource-collector-full-{tests,editor,probe}.log`.
Ruff, actionlint, all eleven architecture gates and whitespace checks pass.
No production actor/addon code changed in this batch, so the current pending
manual Update fixture remains applicable. Nothing was committed, signed,
merged or published.

### External migration-completion command — September 3 UTC

The separate completion CLI now exposes authenticated before/after barriers
around both durable M6 publication and its private temporary write. Its
controller is created only after root/tree, success claim/journal, editor lease
and migration-election validation. The normal library call remains inert to
environment configuration, completed transactions do not re-arm, and every CLI
exit scrubs the process-local tuple. Activation recognizes but does not execute
these completion-owned effects. No signing permission, startup gate or release
approval was removed.

The new real-subprocess matrix covers continue, authenticated failure and
process kill at all four boundaries. It checks exact live/backup trees,
unchanged intent/journal/claim/readiness records, unpublished temporary contents,
no early startup release, retry and idempotence, and no secret in records or
output. Killed-controller records remain evidence and cannot impersonate a
completion. Additional cases cover validation refusals, already-complete and
unreachable controls, incomplete tuples, timeout, unspent occurrence cleanup,
and the environment-inert library API. The initial focused run passed **20
tests** at `/private/tmp/godot-ai-949-migration-cli-focused.log`. The expanded
transaction run retained **one failure, 261 passes and one platform skip**:
its pre-activation phase poll encountered an inode/link transition during an
atomic journal replacement, before the new migration barrier was reached.
The test poll now matches the existing subprocess phase probes: it waits for
a later fully validated journal and never admits the rejected read. Three new
regressions require a subsequent good read, a bounded failure for persistent
rejection, and immediate failure for unrelated malformed data. Production
record validation is unchanged. The failed run is retained at
`/private/tmp/godot-ai-949-migration-cli-all-transaction.log`. All **26 expanded
focused rows** pass at `/private/tmp/godot-ai-949-migration-cli-verified-focused.log`.
The coverage run warns that Python's sysmon core cannot fully retain dynamic
test contexts; it is not used to claim complete transaction-module coverage.
The initial full Python/real-Godot run passed **2,582 tests, four platform
skips** in 498.92s, with the existing Starlette/httpx deprecation:
`/private/tmp/godot-ai-949-migration-cli-full-pytest.log`. The fresh full rerun
including all three phase-poll regressions passed **2,585 tests, four platform
skips** in 468.59s, with the same existing warning:
`/private/tmp/godot-ai-949-migration-cli-final-full-pytest.log`. Its fixtures are
retained under `/private/tmp/godot-ai-949-migration-cli-final-full-tests`.
The complete
live Godot 4.7.2 suite passed **2,151 tests, zero failed, 11 skips, 71 suites**,
followed by exact-project read probes and normal quit. Evidence:
`/private/tmp/godot-ai-release-build.szEA2o/migration-cli-full-{tests,editor,probe}.log`.
The known native GLES texture/StringName diagnostics remain, not a clean-shutdown
claim. Ruff, actionlint, all eleven architecture gates and whitespace checks pass.
Two more isolated full-suite/one-reload/normal-quit controls, `dock` and
`dispatcher`, produce no ObjectDB/resource warnings. They narrow the open
combined-state investigation but do not explain or waive its positive
reproduction. Evidence: `/private/tmp/godot-ai-949-retention-dock-dispatcher-matrix.log`
and the corresponding `retention-suite-v2-{dock,dispatcher}-*` QA logs.

These are development command-path proofs. The ordinary coordinator currently
clears its tuple after activation launch; it does not automatically transfer
an M6 failpoint to the later completion command. Exact-candidate controller
integration, the remaining section-8.1 effects, three-platform runtime/stress
evidence and reviewed numeric ceilings still block release qualification.

This production change supersedes the previously pending reload-persistence
manual editor, which was normally closed without Update and is not a pass.
Its log remains retained. The fresh fixture is
`/private/tmp/godot-ai-release-949-migration-cli-manual`, with harness log
`/private/tmp/godot-ai-949-migration-cli-manual.log`; it still requires the owner's
Update click and normal closure. Exact-project editor/scene/project read probes
passed, and both fixture actor copies, both qualification-barrier scripts and
both reload-helper copies match current source. The accumulated changes remain
uncommitted. No further production change is included in the phase-poll fix.
PR #949 is open at `91c4596` with all 32 pushed CI jobs green; all ten inline
review threads were verified resolved again during this batch.
That CI result does not cover this local batch. Nothing has been merged,
production-signed or published.

### Post-readiness publication and crash boundaries — September 3 UTC

The real activation-CLI continuation matrix now covers both sides of intent
publication/temporary writes, activation locking, all three journal
publications/temporary writes, both tree renames, and final result/temporary
publication. The unreachable rollback-effect control remains. All **27 rows**
require exact new live and old backup trees, a successful claimed terminal,
released activation lock, no premature migration completion, and no token in
retained records or output.

Eight additional real-actor kill rows interrupt final journal and terminal
publication after a validated readiness record has been written. They prove the durable
journal decides recovery: a pending success temporary cannot override committed
`stage_live`, so explicit closed-editor repair rolls back and quarantines the
new tree; committed success plus validated readiness preserves the new tree
and old backup. A result already published by the normal actor keeps its
original writer identity. Normal startup and repair with the initiating editor
still alive refuse without changing evidence. Readiness and orphan temporary
bytes remain evidence even after rollback; they do not grant new startup or
tree authority. No new production failpoint or bypass was added.

The combined continuation/kill matrix passes **48 rows**. Initial assertion
mistakes (looking up tree paths on the record-path container, and expecting
repair to delete readiness) are retained as failed logs; the corrected tests
check the actual intent paths and byte-identical evidence retention. Evidence:
`/private/tmp/godot-ai-949-full-activation-barriers-final-focused.log` (path
mistake), `/private/tmp/godot-ai-949-terminal-kill-focused.log` (retained-readiness
expectation), and `/private/tmp/godot-ai-949-terminal-kill-verified.log` (all 48).
The fresh complete Python/real-Godot gauntlet passed **2,561 tests, four platform
skips** in 462.82s, with the existing Starlette/httpx deprecation:
`/private/tmp/godot-ai-949-terminal-boundaries-full-pytest.log`. Ruff, actionlint,
all eleven architecture gates and whitespace checks pass. These tests are
development actor/process proofs, not the real two-Godot-editor or immutable
candidate qualification matrix. The pending manual fixture's production bytes
remain unchanged by this test-only extension, and the complete release guard
remains closed.

### Ordinary reload persistence — September 3 UTC

An actual `EditorHandler._do_reload_plugin()` diagnostic restored the managed
backend but left the saved enabled-plugin list empty. Reopening that disposable
project consequently left the plugin inactive and the update test timed out.
This is separate from the shutdown-resource investigation: the ordinary reload
phase itself emitted no ObjectDB/resource warnings. A further signed update
control with unchanged existing GDScript bytes still produced the shutdown
warnings, so neither ordinary reload alone nor modified Dock topology explains
that retained graph.

The editor tool, Dock reload and pre-mutation abort-recovery reload now share
one small helper. It refuses a disabled plugin, verifies re-enablement and
saves only after the enable call completes. This preserves the enabled entry
across the next editor process without changing transaction activation,
quiescence, signing or permissions. The new script includes its engine-generated
UID in the source tree: the first diagnostic without that UID correctly hit
the exact-tree readiness refusal after Godot generated an unmanifested file.
That failed run is retained; the hash check was not relaxed.

Four real-engine regressions pass for success plus reopen, already-disabled
refusal, failed re-enable, and project-save failure. All preserve the unrelated
companion plugin. The first attempts exposed test expectations for saved state
and Godot's distinct `ERR_FILE_CANT_OPEN` enum; those failed logs remain retained.
Both complete signed-development update rows now first exercise the actual
production editor reload, verify saved enablement and a managed backend, close,
and reopen for the update. Both pass with all original transaction/client/tool
assertions intact. These remain development fixtures, not immutable candidates.

Evidence: `/private/tmp/godot-ai-949-production-reload-control.log` (original
failure), `/private/tmp/godot-ai-949-production-reload-persist-fixed.log` (UID
refusal), `/private/tmp/godot-ai-949-reload-persistence-{focused,final-focused}.log`
(initial test expectations; both signed-update rows passed), and
`/private/tmp/godot-ai-949-reload-persistence-outcomes.log` (four outcome passes).
The fresh full Python/real-Godot gauntlet passed **2,523 tests, four platform
skips** in 412.05s, with the existing Starlette/httpx warning, at
`/private/tmp/godot-ai-949-reload-persistence-full-pytest.log`. The full live Godot
suite already passed **2,151 tests, zero failures, 11 skips, all 71 suites**.
Evidence: `/private/tmp/godot-ai-release-build.szEA2o/reload-persistence-full-tests.log`.

The subsequent identity-pinned isolated storm run **failed on its first reload**.
The editor/backend did return with a distinct authenticated session and later
passed explicitly pinned read probes and normal quit. Inspection shows that
`run_isolated_reload()` skipped the concurrent runner's identity capture/repin
path and repeatedly probed the stale explicit session. That initial run is not
a stress pass or a waiver of its recorded failure. Log/report:
`/private/tmp/godot-ai-949-reload-persistence-storm.{log,json}`.
Full-suite-plus-ordinary-reload teardown also reproduces the resource warning
(193 ObjectDB instances, 80 resources). Thus a full update transaction is not
required once the broader script graph has been loaded; the simpler client-prep
reload control was narrower. The retained owner/cause remains unresolved.
Combined editor/probe logs are
`/private/tmp/godot-ai-release-build.szEA2o/reload-persistence-full-{editor,probe}.log`.

The isolated harness now captures the explicit target before requesting reload
and uses the same project/PID-bound replacement proof as concurrent runs. Nine
new regressions cover capture, refusal, locked/unpinned routing, disconnect,
missing replacement and cancellation; all **51 storm-support tests** pass.
The real rerun survived **10/10 reloads**, each with a distinct identity-bound
session, 2.0–2.4s recovery and final editor alive. Real read probes and normal
quit followed. This is an exploratory isolated reload result, not a locked
load/latency qualification. Evidence:
`/private/tmp/godot-ai-949-reload-persistence-storm-fixed.{log,json}` and
`/private/tmp/godot-ai-release-build.szEA2o/reload-persistence-storm-fixed-{editor,probe}.log`.
That fresh ten-reload editor has no ObjectDB/resource warnings at exit, only
the already native-reproduced single Node StringName. The contrast with the
full-suite-plus-reload editor further narrows retention to the loaded graph
or earlier suite state, not reload count alone; no diagnostic was suppressed.
Further bounded controls also exit without ObjectDB/resource warnings:
ordinary discovery of all test scripts while running only the pure version
predicate, followed by one reload; and separate complete `clients`,
`client_attach_config`, `script`, `plugin`, `update_manager` and
`update_coordinator` suites, each followed by a proven reload.
Thus simply loading the test graph, client-registry work, or script operations
alone did not reproduce it. Engine-only controls with an externally preloaded
plugin, cyclic static registry/client graph and ignored/deep-ignored suite
cache also do not reproduce the warning. These are negative controls, not an
engine-cause claim or a shutdown waiver. Retained evidence:
`/private/tmp/godot-ai-release-build.szEA2o/retention-discovery-*`,
`/private/tmp/godot-ai-949-retention-suite-matrix-v2.log`,
`/private/tmp/godot-ai-949-retention-update-suite-matrix.log`, the matching
`retention-suite-v2-*` editor/probe logs, and
`/private/tmp/godot-ai-native-reload-graph.VReKdR`.
The first suite-matrix startup connection attempt failed and normally
terminated its owned editor; its log is retained at
`/private/tmp/godot-ai-949-retention-suite-matrix.log`. The corrected diagnostic
uses bounded connection retries, not a relaxed suite or reload assertion.
The complete gauntlet including these nine harness regressions passed
**2,532 tests, four platform skips** in 404.06s, with the existing Starlette/httpx
warning: `/private/tmp/godot-ai-949-reload-and-storm-full-pytest.log`.
The preceding 2,523-pass gauntlet did not include those new rows. Ruff,
actionlint and all eleven architecture gates pass. PR #949 remains open at
`91c4596`, with all ten inline review threads resolved at the latest check.

This production change supersedes the older pending manual fixture referenced
below. That obsolete editor was normally closed without Update, and its harness
correctly reports an incomplete/failed update; it is **not** manual-pass evidence.
A fresh owner-operated fixture is ready at
`/private/tmp/godot-ai-release-949-reload-persistence-manual`, with harness log
`/private/tmp/godot-ai-949-reload-persistence-manual.log`. It still needs the
owner's Update click and normal closure before this batch can be committed.
No commit, merge, final signing or publication has occurred.

### Signed development update over real HTTPS — September 3 UTC

The existing complete self-update regression now runs both its local-file
delivery control and a real private-HTTPS delivery row. The HTTPS row restores
the production UpdateManager bytes instead of its local-I/O substitutions and
adds only a harness-owned per-request TLS/proxy adapter. Both the updated and
backed-up manager files must match canonical source exactly. The existing
transaction, automatic client repin, distinct matching backend identity,
authenticated read/write tools, signed exact tree, successful terminal claim,
durable migration completion and cleanup assertions remain enforced. The
service must observe exactly the canonical v4 triple downloads, and retained
logs/configuration/transaction records must contain no private release URL or
token.

Both delivery rows passed, including a repeated verbose diagnostic run. The
first HTTPS attempt completed the update but failed a harness ordering
expectation: its signal observer runs after the existing activation listener
has synchronously stopped A. The assertion now checks that actual listener
order; it still requires the complete ordered stop/disable/enable/repin/start
sequence and exact downloaded assets. The failed log is retained.

These are **development fixtures**, not immutable A/B qualification: disposable
signing keys, frozen local server selectors and client-launch substitutions
remain, and the unused legacy triple is synthetic. No final candidate identity
was signed, no production trust anchor changed, and the required human Update
check is still separate and pending in its unchanged editor.

Verbose comparison also exposed retained GDScript/client-descriptor resources
at exit in **both** delivery paths: the local-file control reports 191 ObjectDB
instances and 79 resources; HTTPS reports 192 and 79. They are not the native
GLES texture warnings, and no engine-cause or harmlessness claim is established.
The functional assertions passing do not make this shutdown-clean evidence;
the retention source/disposition remains open. Diagnostic fixtures and full
logs are retained at `/private/tmp/godot-ai-949-https-update-shutdown-diagnostic`.

Evidence: `/private/tmp/godot-ai-949-https-update-lifecycle-focused.log` (initial
ordering failure), `/private/tmp/godot-ai-949-https-update-lifecycle-both.log`,
`/private/tmp/godot-ai-949-https-update-shutdown-diagnostic.log`. The fresh full
regression run is `/private/tmp/godot-ai-949-https-update-full-pytest.log`, with
fixtures retained under `/private/tmp/godot-ai-949-https-update-full-tests`.
This batch remains uncommitted pending the owner-operated manual check.

The full Python/real-Godot integration gauntlet including HTTPS activation
subsequently passed **2,519 tests, four platform skips** in 391.22s, with the
existing Starlette/httpx deprecation. Its functional pass retains, rather than
waives, the exit-resource diagnostics above. All ten inline PR #949 review
threads remained resolved at the subsequent overnight check.

Further isolated retention controls narrowed what is **not** established:

- The manager's preloaded client-registry Script is the **same resource** before
  and after this update, with 23 cached clients. Clearing its cache immediately
  after update did not change the final 191/79 warning counts; normal B work
  repopulates it. This disproves the initial separate-retired-registry hypothesis.
- Clearing that cache under its mutex at diagnostic final teardown reduces the
  counts to 122 ObjectDB instances and 56 resources, but does not fix retention.
  No such cleanup was added to production or to the canonical regression.
- A signed diagnostic candidate with unchanged Dock field/preload shape still
  completes the update and reports 191/79. The deliberate typed-field/topology
  stress additions are not sufficient to explain the warning.
- Native Godot controls with no Godot AI code exercised static registry/client
  cycles, script reload, editor disable/re-enable, script edits, whole-addon
  directory replacement, and typed global-class cycles. They did **not**
  reproduce the ObjectDB/resource warnings (the editor controls retain the
  known single Node StringName diagnostic). Normal configure-and-quit phases
  of the Godot AI fixture also have no ObjectDB/resource warnings.

The [Godot static-variable documentation](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html#static-unload-annotation)
describes retained script resources, but that general behavior and these
controls do not establish the cause of this particular shutdown graph. No
`@static_unload` workaround or assertion suppression was introduced. The
remaining task is to distinguish ordinary plugin disable/re-enable from the
full update handoff, then isolate the actual retained owner before fixing it.
Diagnostic scripts and logs are retained at
`/private/tmp/godot-ai-release-setup.ebmCM7/retention_probe_plugin.py`,
`/private/tmp/godot-ai-949-retired-registry-clear`,
`/private/tmp/godot-ai-949-registry-exit-clear`,
`/private/tmp/godot-ai-949-stable-dock-control`, and
`/private/tmp/godot-ai-native-static-retention.AJF6AJ`. These are exploratory
controls only, not additions to the release qualification evidence set.

### Retained package-index identity — September 3 UTC

The existing PEP 503 helper retained references to its caller's dependency
rows. A real-request regression showed that changing both a row and its wheel
after startup could authorize the replacement bytes; changing only the row
could incorrectly reject the original wheel. The helper now copies the
validated identity rows, so neither caller mutation can change the retained
artifact contract. Both formerly failing cases pass. GET/HEAD also open with
nonblocking semantics before checking the opened descriptor, so a regular-file
to FIFO race is rejected rather than hanging a resolver worker.

All **27 private-index tests** pass with **81/81 executable lines covered**,
including four new mutation/race cases. A fresh isolated real `uv` install
consumed the retained percent-encoded `1.0+cpu` wheel and verified its imported
version. That is a synthetic resolver smoke, not an A/B candidate result.
Ruff, actionlint and all eleven architecture gates pass. The full regression
run passed **2,518 tests, four platform skips** in 530.32s, with the existing
Starlette/httpx deprecation. No production addon/actor bytes or manual fixture changed.
This correction remains in the accumulated uncommitted batch pending the
previously requested owner-operated Update check.

Evidence: `/private/tmp/godot-ai-949-index-identity-red.log` (two original
failures), `/private/tmp/godot-ai-949-index-identity-focused.log`,
`/private/tmp/godot-ai-949-index-identity-coverage.json`,
`/private/tmp/godot-ai-949-index-identity-real-uv.log`, and
`/private/tmp/godot-ai-949-index-identity-full-pytest.log` (full run).

### Private default-port HTTPS transport — September 3 UTC

The missing private release transport now has a harness-only adapter:
`script/qualification_https.py`. It exposes an ephemeral loopback CONNECT
listener for one fixed `.invalid` HTTPS origin on logical port 443. It never
forwards arbitrary destinations. Each inner request verifies a bearer token;
the exact six retained release assets are bounded and rehashed before serving.
No system DNS, privileged bind, trust-store edit, production URL-policy change,
release key or public deployment is involved. There is one bounded connection
at a time, no per-request worker pool, and unexpected handler failures fail
the context without logging exception text or credentials.

The native Godot driver uses the documented
[per-request proxy and TLS APIs](https://docs.godotengine.org/en/stable/classes/class_httprequest.html#class-httprequest-method-set-https-proxy)
from a harness-owned `node_added` adapter. Real Godot 4.7.2 successfully fetched
metadata and exact asset bytes through the default-port HTTPS URLs. Separate
negative rows rejected the wrong bearer token, wrong trust certificate and
wrong certificate hostname. All **35 focused Python/native-Godot rows** passed,
with **100% line coverage** of the new HTTPS adapter. Other rows cover duplicate
authority headers, noncanonical paths, no plaintext fallback, changed/deleted/
linked files, a FIFO replacement race, bounded stalled-client shutdown and
secret-free failure reporting. The first negative-path attempt expected 404
but hit the stricter Host rejection (400); the test now pins the correct Host
to exercise the intended path check instead of loosening either assertion.
Its failed log remains retained.

A further real-socket regression found that per-read timeouts did not bound a
client continuously trickling headers. The adapter now has an absolute deadline
whose shutdown handle survives TLS socket wrapping. Both plaintext CONNECT and
encrypted inner-header trickle cases close within the bound. Expected deadline
disconnects are handled without hiding unexpected handler errors. The initial
deadline regression and first shutdown-error follow-up remain retained as
failed evidence; all 35 focused rows now pass with 138/138 executable adapter
lines covered.

Before this deadline fix, the full Python/real-Godot integration run passed
**2,510 tests, four platform skips** in 509.09s, with the existing Starlette/httpx
deprecation. The fresh deadline run then passed **2,512 tests, four platform
skips** in 527.49s, with the same warning. The further full run including the two
manager cases below passed **2,514 tests, four platform skips** in 536.47s,
with the same warning. The full live Godot run passed **2,151 tests, zero failures,
11 conditional/platform skips, all 71 suites**, then real read tools and normal
quit; the native-reproduced GLES diagnostics remain recorded. Ruff, actionlint
and all eleven architecture gates pass for the deadline revision.

Two additional real-engine regressions now exercise the actual UpdateManager,
with its copied GDScript/configuration bytes compared against source after
execution. The manager discovers the next patch relative to its unchanged
plugin version, sends its own authorization, downloads exactly the v4 triple,
and emits a package whose paths, digests, version, source and repository match
the fixture. Its normal cancellation removes only the private download tree.
A syntactically valid wrong token yields no candidate, package or download.
The per-node TLS/proxy adapter is scoped to this manager's request children.
All **37 combined focused rows** pass, still with **138/138 adapter lines**
covered. Evidence: `/private/tmp/godot-ai-949-private-https-manager-final-focused.log`
and `/private/tmp/godot-ai-949-https-manager-coverage.json`.

This establishes the private HTTPS transport and manager handoff seams, not
complete runtime qualification. The native driver contains no plugin; the
manager fixture contains unchanged development addon code, but uses synthetic
release bytes and a harness-allocated download directory. It only observes
the package handoff; no transaction actor, signature approval, activation or
installed immutable A/B candidate is involved. A synthetic package reaching
the verifier boundary is not a verified update. CI now includes these native transport regressions in
the existing three-platform real-Godot job. The pending manual Update fixture
has not changed: its two actor copies and qualification-barrier script still
match current production source. The previously requested manual action is
still needed before committing the accumulated batch.

Focused evidence: `/private/tmp/godot-ai-949-private-https-deadline-v2-focused.log`
and `/private/tmp/godot-ai-949-https-deadline-v2-coverage.json`. Failed diagnostic
logs: `/private/tmp/godot-ai-949-private-https-focused.log`,
`/private/tmp/godot-ai-949-private-https-trickle-red.log`, and
`/private/tmp/godot-ai-949-private-https-deadline-focused.log`. The earlier full
run is `/private/tmp/godot-ai-949-private-https-full-pytest.log`; the fresh run
is `/private/tmp/godot-ai-949-private-https-deadline-full-pytest.log`. The run with
the manager cases is `/private/tmp/godot-ai-949-private-https-manager-full-pytest.log`.
Live Godot
evidence is in
`/private/tmp/godot-ai-release-build.szEA2o/private-https-full-{tests,editor,probe}.log`.

### Temporary-record interruption boundaries — September 3 UTC

The activation actor now exposes private external barriers immediately before
and after temporary intent, journal and terminal-record writes, before their
atomic publication. The same complete process-local capability tuple and
transaction/intent binding are required; record contents alone cannot arm a
barrier. The existing commit barriers keep their meanings and the GDScript
coordinator recognizes these new names without taking ownership of actor work.

Twenty new Python rows cover authenticated continue/fail decisions on both
sides of all three temporary writes, unchanged prior records, handled-failure
cleanup, preserved original I/O errors, actual CLI continuation through all
three effects, and four additional process-kill/repair rows. In the kill rows,
the temporary can contain a later journal phase than the committed journal;
startup still refuses, repair requires the editor to be gone, and explicit
repair follows committed state while preserving those orphan bytes as evidence.
A new live Godot test verifies actor/coordinator ownership and tuple handoff.
All **33 focused Python rows** passed, with no tests disabled.

The full Python run with real Godot integration passed **2,477 tests, four
platform-inapplicable skips**, in 541.75s, with the existing Starlette/httpx
deprecation. Every added executable Python writer line was covered (the full
transaction module is 83.3% line-covered; this is not a universal-coverage
claim). The complete Godot 4.7.2 run passed **2,151 tests, zero failures,
11 conditional/platform skips, all 71 suites**, followed by authenticated
real read tools and normal editor quit. The known native-reproduced GLES
texture/StringName diagnostics remain recorded. Ruff, actionlint and all
eleven architecture gates passed; production Python/GDScript is now 64,881
physical lines, an informational measurement rather than a simplification
claim. Evidence: `/private/tmp/godot-ai-949-temp-barrier-full-pytest.log`,
`/private/tmp/godot-ai-949-temp-barrier-coverage.json`, and
`/private/tmp/godot-ai-release-build.szEA2o/temp-barrier-full-{tests,editor,probe}.log`.

This is a bounded extension of the activation adapter, not completion of the
section-8.1 surface or immutable-candidate qualification. The pre-signing guard
remains closed. The fresh owner-operated Update check is pending in the
disposable `/private/tmp/godot-ai-release-949-temp-barrier-manual` project;
the editor is ready and real editor/scene/project handlers have been loaded.
The harness is waiting for the owner's Update click and normal editor closure
(`/private/tmp/godot-ai-949-temp-barrier-manual.log`). This batch must remain
uncommitted until the required check passes; it has not been pushed to PR #949.
The preceding pushed checkpoint `91c4596` separately passed all **32 CI jobs**
in [run 33722647379](https://github.com/hi-godot/godot-ai/actions/runs/33722647379);
that result does not qualify this uncommitted batch.

### Native GLES texture isolation — September 3 UTC

The two 349,524-byte texture warnings now reproduce in a fresh, standalone
Godot project with **no Godot AI code installed**. A single native
WorldEnvironment with a procedural sky, an undoable environment assignment,
node removal and immediate undo-history clearing emits two warnings on both
official Godot **4.7.0 and 4.7.2** on macOS. Eight environments emit sixteen.
The control exits normally with no earlier parse/scan error. Retaining undo
history until exit, or waiting two frames before clearing it, emits no such
warnings; immediate node freeing alone does not remove them.

The [retained minimal project and control matrix](verification/native-gles-environment-undo/README.md)
make this finding reproducible without this repository's runtime. It isolates
an engine-native cleanup/timing interaction, not the internal engine cause
or its long-session impact. No diagnostic was suppressed, and no arbitrary
wait or split-suite workaround was added to production or the canonical tests.
Engine review/disposition remains open; this is not a renderer-clean claim
or a release-gate waiver.

Diagnostic combined-suite bisection found the `environment` → `gridmap` pair:
the former queues node cleanup and the latter clears their shared undo
history. Other tested pairs and gridmap alone did not reproduce the warning.
All temporary filters were removed from the disposable clone before the fresh
full-suite regression run. The initial exploratory editor's stale particle-tab
startup stalled before an authenticated session was available; its log and
native process sample were retained, and its editor cache was moved aside
recoverably before bisection. It is not counted as a successful test run.

The latest code commit, `293f58c`, passed all **32 CI jobs** in
[run 33719622995](https://github.com/hi-godot/godot-ai/actions/runs/33719622995).
PR #949 remains open and unmerged; no final candidate has been signed.

The fresh checkpoint gauntlet passed **2,457 Python tests, four platform
skips** (469.45s, one existing Starlette/httpx deprecation) and the unchanged
combined Godot 4.7.2 suite: **2,150 passed, zero failed, 11 conditional/platform
skips, all 71 suites**. Authenticated editor/scene/node reads passed and the
editor closed normally. Its exit retains exactly the two texture warnings
and the single native-reproduced `Node` StringName, without the old particle
shader/RID diagnostics. Ruff, actionlint and all eleven architecture gates
passed. Logs: `/private/tmp/godot-ai-949-native-gles-full-pytest.log` and
`/private/tmp/godot-ai-release-build.szEA2o/native-gles-full-{tests,editor,probe}.log`.
This batch changes only the diagnostic project and documentation; the prior
owner-operated manual Update covers the unchanged production update path.

### External actor-kill regression matrix

Nine new command-line regression rows kill the actual activation subprocess
only after observing its transaction-bound external barrier: after acquiring
the activation lock; before/after the initial journal; before/after both tree
renames; and before/after publishing `stage_live`. Each row pins the exact
live/stage/backup hashes, journal phase and absence of premature terminal or
completion records. Ordinary startup refuses without changing recovery
evidence. Explicit repair also refuses without mutation while the separate
editor-identity process remains alive. After that process exits, only an
explicit repair command restores the exact old tree, quarantines an already
activated new tree, claims the rolled-back result and releases the lock.
The external crash barrier remains as evidence and its token is not persisted.

These are real actor/process-death tests using a separate Python process as
the editor identity, not real Godot composition or immutable-candidate proof.
They extend development coverage of the existing adapter; the full section-8.1
surface and two-Godot-editor qualification producer remain open. No production
runtime, signing boundary or qualification gate was changed for this batch.

Validation: the complete Python run with Godot 4.7 integration enabled passed
**2,457 tests, four platform-inapplicable skips**, with the existing third-party
Starlette/httpx deprecation warning. All nine new kill rows passed, including
their startup-refusal and exact-repair assertions. The initial focused run
failed on a test-authoring typo (`live` instead of the probe's `alive` value);
that assertion was corrected, not removed. The full Godot 4.7.2 combined run
passed **2,150 tests, zero failures, 11 conditional/platform skips, 71 suites**;
authenticated read tools passed and the editor closed normally. Ruff,
actionlint and all eleven architecture gates passed. Logs are retained at
`/private/tmp/godot-ai-949-crash-matrix-full-pytest.log` and
`/private/tmp/godot-ai-release-build.szEA2o/crash-matrix-godot-tests.log`.
The previously completed manual Update remains evidence for the unchanged
production tree; this test-only batch does not claim a new interactive run.

Additional engine-only GLES controls retained under
`/private/tmp/godot-ai-gles-sync-control.hasuIC` completed 40 path previews with
forced draws and 40 edited-resource previews with retained results, without
the texture warning. A separate native particle-scene control reproduced one
unfreed `ParticlesShaderGLES3`, one shader RID and 39 unclaimed StringNames
after leaving a particle scene in another editor tab. It contains no Godot AI
code. The corrected `particle-tabs-clean.log` has no earlier scan/parse error;
the first control attempt's deferred-scan errors are retained separately.
The same particle diagnostic reproduced again in the completely fresh,
native-only `/private/tmp/godot-native-particle-repro.8xZayJ` project.
This isolates the extra particle diagnostics seen when the reused QA project
opened its earlier storm scene at launch. That particle control does **not**
isolate or waive the two 349,524-byte texture warnings; the newer, separate
environment/undo control above now reproduces those warnings natively.

### Restart follow-up

The rerun of CI on `05c96d2` still timed out in Windows final-v3 migration
([run 33712066792, attempt 2](https://github.com/hi-godot/godot-ai/actions/runs/33712066792/attempts/2));
31 of 32 jobs passed. Increasing the timeout had not fixed
[issue #957](https://github.com/hi-godot/godot-ai/issues/957). Investigation found
three independently reproducible problems:

- Godot 4.7 does not forward the `--headless` shorthand across its own editor
  restart. A minimal real-engine regression first failed with `headless` in
  the first process and `macOS` in its replacement. The test harness now uses
  restart-forwarded display/audio driver arguments; the same test passes with
  distinct process IDs and two headless receipts. This changes test launch
  arguments, not production editor rendering.
- Disabling the bridge removes its enabled-plugin entry. Before restart it
  now durably enables the next start without loading v4 scripts in the old
  process. Real-engine cases cover absent/already-listed entries, companion
  plugin preservation, save failure and malformed settings. Bridge error
  state is project-scoped instead of poisoning other projects.
- During graceful exit, predecessor liveness may be observable briefly while
  its start fingerprint is unavailable. The existing bounded lease-transfer
  wait now tolerates that transient observation, but only positive dead/PID-
  reused proof permits transfer. Deadline and nonce regressions verify that
  persistent uncertainty preserves the predecessor's lease and refuses startup.

CI now runs the engine restart and bridge failure regressions alongside the
forward-upgrade suite, with per-test output and bounded progress messages.
The final-v3 development fixture retains replacement-process diagnostics
(Windows detaches that process from the parent's stdout). Neither its timeout
nor its positive tree/lease/backend assertions were weakened. This fixture
already substitutes development keys and launch plumbing; it remains distinct
from the required unchanged-candidate qualification producer.

The fresh manual Update check passed after real tool handlers were loaded:
plugin/backend `4.0.1`, durable transaction
`db7a9044810bed6f9023485a225016ee`, retained external backup, no early vNext
exit hook and no new Godot crash report. The owner clicked Update and closed
the Metal-renderer editor normally. The full Godot 4.7.2 run again passed all
71 suites: **2,150 passed, zero failed, 11 conditional/platform skips**.
The final full Python run with Godot integration enabled passed **2,448 tests,
four platform-inapplicable skips**, with the existing third-party
Starlette/httpx deprecation warning. Ruff, actionlint and all eleven
architecture gates passed. The subsequent
[CI run on `2589d41`](https://github.com/hi-godot/godot-ai/actions/runs/33715456363)
passed all **32 jobs**, including Windows' **19 restart/bridge/upgrade regressions**
and all **71 Godot suites** (2,152 passed, zero failed, 37 platform skips).
The final-v3 Windows test completed in approximately 27 seconds. Issue #957
remains open pending landing/review; no failed gate was rerun into a waiver.

Exploratory stress also exposed an unclassified AnyIO closed-stream exception
during reload. Typed transport classification now covers `BrokenResourceError`,
`ClosedResourceError` and `EndOfStream`; regressions prove these are tolerated
only inside the affected target's recorded reload window. The original failed
run is retained. A second run recovered both reloads but collided with scratch
files/nodes from the aborted run; it is not counted as a clean result.
After preserving that scratch tree outside the project and starting a fresh
editor, the complete exploratory rerun passed: **1,223 explicitly pinned calls,
zero unexpected errors, seven reload-transient transport errors, two of two
reloads survived** (2.4s and 3.0s recovery), original scene restored and editor
alive. These are development results, not locked-profile approval.

GLES shutdown diagnostics remain open. The clean stress-only editor emitted
ten 349,524-byte texture warnings; the earlier combined suite plus two stress
runs also emitted leaked `Image` instances. A fresh engine-only control using
ten native noise-resource saves, UID publication and filesystem updates did
not reproduce texture leaks, but **did** reproduce the single unclaimed `Node`
StringName without Godot AI installed. That isolates the StringName diagnostic
from this plugin. At that checkpoint the texture warning was not yet similarly
isolated; the newer environment/undo control above closes that evidence gap.

### Earlier release review evidence

- Final expanded Python suite with Godot integration enabled:
  **2,426 passed, four platform-inapplicable skips**, one third-party
  Starlette/httpx deprecation warning. All 135 focused release workflow,
  approval, candidate and private-index tests also passed separately.
- Live suites on Godot **4.7 and 4.7.2**: each **2,150 passed, zero failed,
  11 conditional/platform skips, all 71 suites discovered**. The additional
  4.7.2 run used isolated portable settings and unused ports after an earlier
  attempt found a pre-existing listener; that listener was left untouched.
  The manual update was exercised after real editor, scene and project tool
  calls had loaded handlers.
- Owner clicked Update and closed the disposable editor normally: plugin and
  backend both reached `4.0.1`, migration completed durably, external backup
  remained, the new backend authenticated, no new crash report appeared, and
  this Metal-renderer manual fixture exited cleanly.
- Final exploratory stress: **1,220 calls, all explicitly session-pinned,
  two of two reloads survived, zero unexpected errors**, seven measured
  reload-transient transport errors, final editor alive. Explicit exploratory
  pins now survive both trace routing and session-ID rotation. The legacy
  input-map workload establishes valid mutation preconditions; negative
  handler tests remain intact.
- Real provisional packages were built once with a disposable fixture key:
  A `073854efd0d04416aec7d026656e3b5c003bc424` (`4.0.0`) and B
  `79619e9f3b6060764f4841f927abe554a26f6ed7` (`4.0.1`). Both actual documented
  installs produced the exact signed tree and resolved their exact actor
  wheels from retained private-index bytes. These local commits and keys are
  **not** production identities or approvals.
- The complete provisional macOS/Python 3.14 package producer passed:
  **2,359 passed and 11 environment-inapplicable skips for each installed
  candidate wheel**, both wheel/sdist variants installed offline, 79 retained
  distributions, and exact documented installs of A's 279 managed files and
  B's 278. B's unit/integration source fixtures ran in its own exact child
  checkout, not A's version context. These development tests do not replace
  the separate unchanged-candidate Godot runtime matrix.
- The private index is token-scoped and loopback-only, implements resolver
  `HEAD` probes as well as `GET`, rejects changed/oversized/nonregular files,
  and does not log capability URLs. Its real-network regression tests cover
  all executable lines. Dependency metadata uses only top-level wheel
  metadata, so legitimate vendored metadata (for example in setuptools) does
  not produce a false duplicate. Installed-package checks canonicalize macOS
  path aliases while still rejecting imports outside the isolated environment.
- Follow-up review regressions cover percent-encoded wheel filenames and
  deliberately varied Windows project-path casing. The index decodes paths
  once before exact inventory lookup; encoded separators, double decoding and
  NUL suffixes remain refused. All 62 focused index/storm tests passed, with
  100% line coverage of the index, and a real isolated `uv` install consumed
  the retained `1.0+cpu` wheel through its generated `%2B` link. This is a
  disposable resolver smoke, not a production-candidate qualification row.
- All eleven architecture gates pass. The production Python/GDScript tree is
  **64,859 physical lines**; this measurement is not a claim of a smaller
  codebase or completed release qualification.

The full-suite/stress GLES3 editor still reports low-level texture allocations
at exit, but no longer reports the handler-related ObjectDB/resource leaks.
Minimal no-Godot-AI controls exercising gradient, material and noise resource
previews, edited-preview regeneration and transient texture creation/resizing
did not reproduce the texture warning. The newer environment/undo control
above now provides an engine-native reproduction, although internal cause,
long-session impact and disposition remain unresolved. An all-renderers-clean
shutdown claim is still unjustified. The manual Metal fixture's clean exit is
narrower evidence, not a waiver for this remaining investigation.

Further 4.7.2 isolation ran all 71 suites as individual `test_run` requests,
split across two fresh editors; both exited without the texture or ObjectDB
warnings. The single combined `test_run` still produced two 349,524-byte GL
texture warnings on both 4.7 and 4.7.2. This narrows the remaining reproduction
to combined-run timing/state; it does not justify changing assertions or
splitting the required full-suite gate to conceal the warning.
The verbose 4.7.2 combined-run exits also report one unclaimed `Node`
StringName; the newer engine-only control above reproduces that diagnostic
without Godot AI installed.

Local diagnostic evidence is retained under
`/private/tmp/godot-ai-release-build.szEA2o`,
`/private/tmp/godot-ai-release-949-quiescence-manual`, and
`/private/tmp/godot-ai-exact-install.G8FHUT`. The restart follow-up also retains
`/private/tmp/godot-ai-release-949-restart-manual` and
`/private/tmp/godot-ai-release-949-restart-final-pytest.log`.
These temporary development logs
are not the immutable cross-platform qualification bundle. No production key
was retrieved, no final candidate was signed, and nothing was published.

## Remaining release gates

Qualification preflight fails **before build/sign** while exact runtime,
failpoint and stress producers are missing. The workflow cannot turn these
development results or the Python row alone into an approved release.

1. Implement the remaining external failpoint surface and complete real-process
   recovery/lock matrix required by sections 7–8 of the verification contract.
2. Complete the remaining unchanged-candidate runtime cases around the new
   exact A→B slice: final-v3 one-click migration, functional/security tools,
   reopen/backup restoration and required update repetitions, on every required
   OS and pinned Godot build.
3. Collect and review the required platform baselines; check in numeric latency
   and resource ceilings, then run all locked profiles and seeds. The passing
   exploratory run above is not a substitute.
4. Freeze reviewed A/B source identities, execute the complete matrix, approve
   the `release-publish` environment, then promote the same bytes. Public
   dependency re-resolution and immutable post-publication attestation remain
   required after publication.

Do not remove the preflight guard, mark the complete contract satisfied, or
sign a final stable identity just to obtain a green workflow.
