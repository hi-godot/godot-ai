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
opened its earlier storm scene at launch. It does **not** isolate or waive the
two 349,524-byte texture warnings from the full combined suite.

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
from this plugin; the texture warning is not yet similarly isolated.

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
did not reproduce the texture warning. Its cause is therefore still
unresolved; neither an upstream-engine attribution nor an all-renderers-clean
shutdown claim is justified. The manual Metal fixture's clean exit is narrower
evidence, not a waiver for this remaining investigation.

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
2. Complete unchanged-candidate runtime producers: authenticated private HTTPS
   release discovery, final-v3 one-click migration, repeated A→B updates,
   matching frozen backends, tool/client/reopen/backup checks, on every required
   OS and pinned Godot build.
3. Collect and review the required platform baselines; check in numeric latency
   and resource ceilings, then run all locked profiles and seeds. The passing
   exploratory run above is not a substitute.
4. Freeze reviewed A/B source identities, execute the complete matrix, review
   the immutable approval draft in the separately permissioned repository,
   then promote the same bytes. Public dependency re-resolution and immutable
   post-publication attestation remain required after publication.

Do not remove the preflight guard, mark the complete contract satisfied, or
sign a final stable identity just to obtain a green workflow.
