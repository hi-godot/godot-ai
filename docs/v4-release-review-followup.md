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
  **64,854 physical lines**; this measurement is not a claim of a smaller
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
StringName; that diagnostic remains unresolved too.

Local diagnostic evidence is retained under
`/private/tmp/godot-ai-release-build.szEA2o`,
`/private/tmp/godot-ai-release-949-quiescence-manual`, and
`/private/tmp/godot-ai-exact-install.G8FHUT`. These temporary development logs
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
