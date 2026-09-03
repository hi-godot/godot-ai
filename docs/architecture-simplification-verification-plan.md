# v4 Architecture Simplification — Verification Plan

- Date: 2026-08-30
- Status: approved executable release contract; the ownership redesign and
  core update reducer have a local checkpoint, but the complete section-8.1
  failpoint surface is not implemented and no final Phase-7 qualification
  bundle or publication approval is recorded
- Purpose: make migration, updater, security, release, crash, and stress gates
  executable against exact bytes
- Release range: Godot 4.7+ within the 4.x line
- Required desktop platforms: Windows, macOS, Linux

## 1. Gate rules

This document is the v4-candidate release contract, not a menu. The historical
updater classification was a one-time boundary decision completed before the
rebuild; it is not silently promoted into a recurring candidate matrix.

- Required v4 engines, candidate packages, signing access, machines, and
  platforms may not skip. Missing candidate input means the candidate is not
  qualified.
- Tests run against unmodified candidate bytes. A harness may redirect an
  explicitly authorized qualification channel; it may not patch GDScript,
  synthesize expected digests, bypass discovery/signatures, substitute a dev
  checkout, or rebuild after approval.
- Every result retains machine-readable output, exact commands, source/artifact
  hashes, tool versions, logs, tree hashes, and relevant crash reports.
- Profile or threshold changes after architecture implementation begins require
  a reviewed plan change with baseline evidence.
- A green editor process is necessary but not sufficient. Error, latency,
  resource, state, tree, process, session, and capability assertions all gate.

## 2. Freeze verification inputs

Before the first architecture tranche, check in a verification manifest with:

- pinned landing-base and oracle SHAs;
- each characterization-test commit and how the identical test runs on oracle
  and rebuild;
- every outstanding-PR head/patch ID and disposition;
- the retained one-time historical evidence digest and its reviewed boundary
  decision (not deleted historical downloads or harnesses);
- OS image/runner identity, architecture, Godot binary SHA-256, Python/uv
  version, exact behavior-defining pins, and the complete resolved distribution
  artifact inventory (name/version/filename/size/SHA-256) for every row;
- fixed workload seeds and generated operation traces;
- numeric error, latency, recovery, memory, file-descriptor, and thread bounds;
- all failpoint IDs and expected on-disk states;
- expected-red, current-green, oracle-only, and intentional-v4-difference rows;
- evidence output schema and retention path.

The implementation-start manifest was a temporary audit scaffold. Once its
decisions were incorporated into the approved plan and executable gates, the
scaffold was removed rather than maintained as a second source of truth.
Release-candidate inputs and outputs are still frozen in the pre-publication
qualification bundle. The immutable pre-v4 investigation is distilled into
[pre-v4-updater-one-time-evidence.md](verification/pre-v4-updater-one-time-evidence.md).

## 3. Mandatory platform matrix

Pin exact current-stable patch/build hashes at implementation start. At minimum:

| Platform | Primary architecture | Godot rows | Python rows |
|---|---|---|---|
| Windows | x86_64 | 4.7.0, current stable 4.x if byte-distinct | 3.11, 3.12, 3.13, 3.14 |
| macOS | arm64 | 4.7.0, current stable 4.x if byte-distinct | 3.11, 3.12, 3.13, 3.14 |
| Linux | x86_64 | 4.7.0, current stable 4.x if byte-distinct | 3.11, 3.12, 3.13, 3.14 |

Each platform/Godot row is keyed by the pinned binary hash. If current stable 4.x
is byte-identical to 4.7.0 when inputs freeze, deduplicate it rather than
pretending to have two builds; every gate derives its row count from the unique
pinned manifest. A newer-development Godot can run as a non-blocking Linux
canary; it does not replace a required stable row.

Godot 4.5 and 4.6 run explicit refusal/documentation checks: v4 does not enable,
the user sees the 4.7 floor, and no tree mutation occurs. Recurring hosted CI
runs this unsupported-engine floor guard on Linux only; it is not a supported
Windows/macOS qualification row. Every supported Godot 4.7+ row still runs on
all three required platforms.

Core Python unit/integration suites run all listed versions on all platforms.
The most expensive manual/failure rows may use Python 3.11 and 3.14, provided
ordinary CI covers 3.12 and 3.13 and the exact-candidate server path is proven
at both the floor and ceiling.

### Private HTTPS transport adapter

`script/qualification_https.py` supplies a loopback-only, authenticated release
origin for harness integration. A bounded CONNECT listener terminates TLS only
for `release.qualification.invalid:443`; it does not forward traffic. Release
and asset URLs retain ordinary HTTPS/default-port semantics. A harness-created
request adapter supplies the loopback proxy and a disposable trusted certificate
using Godot's per-request APIs, without changing system DNS, root certificates,
the production URL allowlist or candidate source. Bearer authorization is checked
inside TLS for metadata and every GET/HEAD; only the exact retained six-asset
inventory is served, with fresh regular-file, size and digest checks.
An absolute connection deadline also bounds trickling headers both before and
after TLS; a per-read timeout alone is not treated as that bound.

Real Godot transport regressions prove successful metadata/asset retrieval and
refusal of a wrong token, an untrusted certificate and a wrong certificate
hostname. These tests use a native HTTPRequest driver and synthetic bytes, not
installed A/B candidates or an updater bypass. A separate development regression
copies the production addon without changing any GDScript/config bytes and
exercises the actual UpdateManager's discovery, three-asset download and package
handoff through this origin. A wrong token yields no candidate or download. The
driver observes that handoff but never activates it: synthetic manifest/signature
bytes do not qualify an update and are not submitted as candidate evidence.
The signed development updater regression separately exercises the whole
activation/repin/backend/tool/recovery path over this transport, with unchanged
manager bytes in its live and backup trees. Its disposable signing key and
local server/client substitutions still exclude it from immutable-candidate
qualification; its retained shutdown-resource diagnostics also remain open.
Connecting this adapter to the
complete unchanged-candidate lifecycle, final-v3 migration, retained package
resolution and cross-platform runtime evidence producer remains required.

The qualification workflow now contains a fail-closed first runtime slice for
the exact A -> B path. It consumes the matching retained Python-row inventory,
installs unmodified signed A through the documented verifier, serves unmodified
signed B through the private HTTPS origin, resolves both exact server/actor
wheels through the retained private index, and drives one real editor update
from a harness-owned autoload. The retained case verifies the changed backend
identity, automatic client repin, exact B live tree, exact A backup, successful
claim, migration completion, released lock, engine hash/version and absence of
private endpoint credentials in retained output. It is not sufficient to make
the runtime row pass: final-v3 migration, the complete functional/security
case, reopen/backup restoration and repeated crash regressions remain mandatory.
The pre-signing guard therefore remains closed.

## 4. Completed historical updater boundary proof

The retained
[one-time evidence](verification/pre-v4-updater-one-time-evidence.md)
classified the historical tags and established how they select the legacy
asset. That evidence remains historical; the new signed final-v3 bridge is a
separate recurring candidate gate rather than a claim that every old updater is
supported.

Recurring v4 qualification retains only the durable consequences:

- the release inventory has one canonical v4 plugin ZIP and one legacy-named
  transition capsule, never an alias or second final tree;
- the v4 migration page presents the single Update action as the normal path;
- the bridge starts from a byte-hashed final-v3 add-on tree, moves the complete
  temporary/old tree externally, and commits only the canonical v4 tree; and
- no v4 updater or transport compatibility branch is added for pre-v4 code.

Reopening the historical compatibility decision requires a new, independently
reviewed archaeology run. It is not required to qualify an otherwise unchanged
v4 candidate. The retained evidence accurately describes its narrower
macOS/Godot 4.7 execution; it does not imply Linux, Windows, or historical-
engine runtime coverage.

## 5. Bootstrap verifier and bridge migration

### 5.1 Separately permissioned trust channel

v4.0 uses the existing release-signing key. The migration instructions obtain
the small verifier from the exact immutable v4 release source commit. At least
one separately permissioned surface, not writable with release-publisher credentials,
authenticates that commit, both verifier-file digests, every release-asset
identity, and the expected public-key fingerprint.

The owner-approved channel is
[dsarno/godot-ai-release-attestations](https://github.com/dsarno/godot-ai-release-attestations),
with `dsarno` as approver. Follow the
[runbook's approved boundary](releasing.md#attestation-channel-and-approved-threat-boundary):
no godot-ai automation write credential there, owner-only writes, Actions off,
and commit-pinned approval records. This is independent of scoped release-asset
mutation, not independent administration. The shared GitHub provider and owner
account are explicit trust roots. Qualification must retain the permission
checks and prove the release credential cannot write the attestation channel.

The verifier uses the user's Godot executable or another already-required
runtime; it does not download executable dependencies during verification. It
checks, before extraction:

- public-key fingerprint;
- detached manifest signature;
- manifest schema and canonical encoding;
- repository and stable channel;
- source commit, tag, and version;
- exact v4 artifact name, byte size, and SHA-256;
- exact managed-tree inventory and per-entry constraints;
- no encryption, unsafe compression, links/reparse metadata, traversal,
  absolute paths, duplicate paths, case collisions, reserved paths, excessive
  file count, or expansion overflow.

Negative control replaces the archive, manifest, signature, verifier asset, and
release notes as a release-asset publisher could. Verification still fails
because the trusted verifier/key fingerprint is outside that mutable set.

### 5.2 Documentation-driven migration

The harness performs the documented single **Update** action from the exact
final-v3 tree. It then proves, without another user action:

1. v3 selects and authenticates the legacy-named capsule;
2. the bridge resolves the exact actor through the production uv boundary and
   verifies the embedded canonical signature/inventory before live mutation;
3. unsafe recovery namespaces, aliases, links/reparse traversal, permissions,
   cross-filesystem roots, and competing editors fail closed;
4. the complete temporary/old tree moves to external recovery and the exact v4
   tree alone becomes live;
5. Godot gracefully restarts itself, the new editor proves its predecessor
   closed, and the actor transfers the inherited nonce-bound lease;
6. first v4 startup claims the transaction, broadly repins owned pre-v4 client
   entries, durably completes migration, and starts the matching server; and
7. authenticated tools, later reopen, and retained-backup restoration work.

Missing `uvx`, timeout/offline resolution, malformed identity, wrong package or
protocol identity, and an extra response field each fail before an install
claim, recovery directory, marker, backup, or live-tree mutation exists.

Each mandatory desktop row starts from a byte-hashed final-v3 tree with
old-only files and owned client entries. Older historical classes remain
outside the recurring support gate; the retained archaeology evidence does not
substitute for executing the exact final-v3 bridge candidate.

The harness scans the entire project after reopening for duplicate/stale
`class_name` failures and parse cascades. A backup anywhere under the project
is a hard failure.

### 5.3 Installation-surface audit

Before publication:

- GitHub release exposes the canonical v4 triple and the signed transition
  triple, with no second final plugin shape;
- README/direct links point to the migration page, not an overlay install;
- classic Asset Library and Asset Store listings remain on final v3 during
  qualification; that updater consumes only the signed transition capsule;
- source archives cannot be mistaken for updater payloads;
- the supported final-v3 Update path requires Godot 4.7+ and proves automatic
  external backup, exact replacement, client repin, and server startup.

## 6. Exact two-candidate qualification

### 6.1 Candidate identities

- **A:** final stable identity `4.0.0`, source SHA A. A's plugin ZIP, signed
  manifest, wheel, and sdist are the only bytes eligible for v4.0 publication.
- **B:** qualification-only identity `4.0.1`, source SHA B. B is a reviewed
  minimal child of A whose only runtime change is version/package identity. It
  also removes the bundled, runtime-inert `addons/godot_ai/README.md`, proving
  that activation deletes an A-only managed-tree file instead of overlaying B.
  `4.0.1` is permanently reserved for qualification: B is never relabeled or
  published, and no future release may reuse that version.

Both plugin manifests bind source SHA, repository, channel, tag/version,
artifact name/size/digest, and exact plugin-tree inventory. Each candidate's
approval digest set additionally binds its wheel and sdist plus every artifact
in each qualification row's resolved Python distribution inventory.

```text
accepted green tranches
        |
        v
SHA A / 4.0.0
  |-- credential-free build --> unsigned bundle A
  |-- protected signer -------> signed digest set A
  |
  `-- reviewed minimal child SHA B / 4.0.1 (qualification only)
       |-- credential-free build --> unsigned bundle B
       `-- protected signer -------> signed digest set B

A + B digests
  |-> retained historical boundary decision + signed bridge-shape gate
  |-> one-click final-v3 migration to exact A
  |-> exact A -> B hot self-update
  |-> failure/lock/repair/storm evidence
  `-> pre-publication qualification bundle
       `-> approval bound to sources, versions, channels, and every digest
            `-> publish A byte-for-byte
                 `-> public redownload/hash attestation
```

Signing disposable and eventual artifacts under one stable identity is
forbidden.

### 6.2 Private release and Python-package path

Qualification provides:

- a private or draft GitHub-like API/asset endpoint serving exact A under the
  final `v4.0.0` tag/artifact path and exact B under its unique
  `v4.0.1` qualification path;
- stable artifact names and documentation commands whose local paths and
  arguments are identical before and after publication; qualification changes
  only an explicit process-local authorized release base, never candidate
  bytes or the reviewed instructions;
- B served through the normal v4 discovery/parser/authentication path;
- a private PEP 503 index containing the exact A and B wheel/sdist bytes and
  the attested dependency artifacts selected for every qualification row;
- an explicit process-local qualification switch and endpoint/index
  authorization that cannot be enabled by downloaded metadata;
- proof that private endpoints/tokens are never persisted into client config,
  project files, result records, logs, or telemetry.

The unmodified A plugin is launched with
`GODOT_AI_QUALIFICATION_PYTHON_INDEX=1` plus an explicit private `UV_INDEX` or
`UV_DEFAULT_INDEX`. This is the only mode in which its shared uv resolver
policy omits the production official-PyPI arguments and preserves uv index
environment variables. The matrix exercises prewarm, server restart, client
repin, client restart, attach, and matching-version transport, and proves the
switch, endpoint, and credentials never enter persisted argv or evidence. A
dev venv, missing switch/index pair, source symlink, or public-package
substitution fails this gate.

### 6.3 Publication promotion

1. create/protect final `v4.0.0` tag at SHA A;
2. verify approval record, sources, identities, signer, and every digest;
3. upload A's exact wheel/sdist to PyPI first;
4. download public distributions and compare hashes with A;
5. if the version already exists, compare hashes and fail on any mismatch;
   `skip-existing` alone is forbidden evidence;
6. publish A's exact signed GitHub assets without checkout/rebuild;
7. download/audit the public asset inventory and hashes;
8. preserve an immutable recovery checkpoint for a forward-only emergency
   release.

If GitHub publication fails after PyPI, resume with the immutable A artifacts.
Before a future stable v4.1 release, public v4.0 must qualify the exact private
v4.1 candidate that will be published byte-for-byte; B cannot stand in for it.
The next publishable stable patch after v4.0.0 is at least v4.0.2 because the
v4.0.1 identity has been burned by qualification.

## 7. Interprocess activation-lock matrix

The policy is refusal, not invisible multi-editor coordination.

Required cases:

- two update clicks on one canonical install root: exactly one transaction
  starts; the loser fails before quiescence/disable/mutation;
- a retained successful backup causes the next update to refuse before
  download/quiescence/mutation; after an explicit editor-closed archive or
  removal, the same update may proceed without rotating or overwriting it;
- a non-initiating editor already live on the root: activation refuses before
  mutation;
- a second editor starts after lock acquisition: startup refuses before normal
  composition, persists no lease or outcome, and disables the plugin rather
  than continuing an old compiled tree as an observer;
- after the matching terminal claim exists and the activation lock is
  released, that editor must re-enable the plugin or restart so Godot loads the
  terminal tree afresh; the refused instance emits no `PostUpdateOutcome`
  fanout, client repin, or update-outcome telemetry;
- a successful claim without `migration-complete.json` is rediscovered on
  every ordinary startup; crashes before repin, during repin, and after repin
  but before durable completion all repeat the M6 barrier and start no server;
- migration completion requires the exact current editor lease, successful
  claim/journal, and signed live-tree identity; only its durable actor
  acknowledgement releases normal startup or permits another update;
- a missing, malformed, mismatched, timed-out, or still-locked terminal state
  keeps every non-initiating startup barred and points to existing-runtime
  repair;
- different canonical roots do not block each other;
- case, separator, relative, symlink, junction, and reparse aliases resolve to
  the same identity or fail closed;
- live locks are never stolen;
- killed/stale owner cannot be taken over automatically;
- repair takeover requires explicit user action, closed editors, dead-process
  fingerprint proof, and atomic claim;
- explicit `abort-prepared --dead-owner-takeover` can clean only authenticated
  preactivation stage state after proving the prepared editor and any prior
  abort requester/repairer dead or PID-reused; it never mutates the live tree;
- PID reuse, malformed/unknown records, mismatched roots/transactions, and
  unverifiable ownership fail closed;
- only the initiating reload lineage writes readiness and claims result;
- another editor cannot consume outcome or replacement authorization.

Use two real Godot editor processes, not mocked consumers.

## 8. Failpoint and crash matrix

### 8.1 Deterministic barriers

The current activation/coordinator adapter accepts optional process-local
`GODOT_AI_QUALIFICATION_FAILPOINT_OCCURRENCE` (1–9999, default 1) alongside
the required token/effect/before-or-after/timeout tuple. It counts matching
effect/timing crossings, publishes the selected occurrence as `sequence`, and
authenticates that sequence in the controller response. Unrelated effects do
not advance the counter. The selector is one-shot and never arms a barrier
without the complete capability tuple. This closes repeated-effect ambiguity;
it does not complete the command-path coverage listed below.

The activation actor also exposes `intent_temporary_write`,
`journal_temporary_write` and `terminal_temporary_write`, each before creation
and after the private temporary file is fully written, fsynced and closed but
before its record name is published/replaced. The existing `*_commit` barriers
still bracket the whole publication operation. The in-memory intent is already
validated before these controls can arm; this is not a pre-prepare or
recovery-root-creation hook. A handled failure removes its own unpublished
temporary. A killed writer leaves that temporary as evidence; repair must use
the committed journal, never promote the pending bytes to authority, and retain
the orphan temporary. The coordinator recognizes these actor effects without
claiming or consuming their execution. The rest of the surface below remains
required, including preparation and the separate startup/repair command paths.

The separate `complete-migration` CLI now accepts the same explicit tuple for
`migration_complete` and `migration_complete_temporary_write`. It arms only
after validating the exact live tree, successful claim/journal, current editor
lease and migration election. An already validated completion is idempotent
and does not re-arm. Library calls remain environment-inert. Handled failures
scrub the tuple and remove their own capability/temporary; a killed command
retains its barrier and unpublished bytes without granting startup authority.
Activation and coordinator adapters recognize these names but do not execute
them. This is a separately launched command boundary, **not** an end-to-end
Godot M6 handoff proof: the coordinator currently clears its inherited tuple
after launching activation, so qualification must explicitly provision the
completion command. Full candidate lifecycle/controller integration remains
required alongside the other missing command paths.

The explicit `repair` CLI now externally addresses `repair_claim` before and
after publication. Its optional control arms only after validating the bound
intent/activation lock and positively proving the initiating editor and runner
dead or PID-reused. A still-live prior repairer still refuses takeover. Library
calls remain environment-inert; all CLI exits scrub the tuple, handled exits
remove their capability, and a killed repair process preserves its barrier.
Six real repair-subprocess continue/fail/kill rows prove exact pre-claim tree
state, barred ordinary startup and explicit subsequent rollback/quarantine.
Their initial activation is a development crash fixture with two separate
Python owner-identity processes, not two Godot editors or an immutable candidate.
The remaining repair effects/reclamation boundaries and other command paths
below are still required; recognizing an effect name does not execute it.

Every updater/recovery reducer effect has stable `before_*` and `after_*`
barrier IDs, including:

- recovery-root and activation-lock creation;
- editor census and client quiescence;
- candidate/manifest/staged-tree revalidation;
- prepared-state temporary write and atomic commit;
- intent temporary write and atomic commit;
- disable request and verified disable;
- live-to-backup rename;
- stage-to-live rename;
- filesystem scan and enable;
- readiness temporary write and atomic commit;
- result temporary write and atomic commit;
- result rename-to-claim;
- claim validation and pre-fanout;
- migration-completion publication;
- fanout and startup-barrier release;
- every rollback/quarantine rename, rescan, and re-enable;
- repair transaction claim and each repair effect;
- prepared-update abort intent, stage deletion/sync, cleanup publication, and
  preactivation dead-owner repair-claim publication/reclamation;
- replacement-authorization spend;
- activation-lock release.

The exact candidate writes an out-of-project barrier record bound to
project/install root, transaction, effect, and monotonic sequence, then waits
for an external continue/fail token. It is owner-private on verified POSIX
paths; on Windows it uses the fixed canonical default and reparse checks under
the explicitly narrowed threat claim. The controller injects one failure or
kill only after observing the record. It does not race console logs.

Failpoint control is disabled by default, requires an explicit local
qualification capability, cannot be armed by release metadata/project data,
and never leaks its token.

### 8.2 Assertions per injected boundary

Each before/after failure and process-kill case declares:

- expected live, stage, backup, and quarantine tree hashes;
- expected prepared, activation-lock, editor-lease, intent, journal, readiness,
  result, claim, and migration-completion presence/content;
- which process may still be live;
- whether normal startup remains barred;
- exact next restart or repair action;
- final immutable `PostUpdateOutcome`;
- retained backup/evidence paths;
- expected user message and exit/error code.

Corrupt, truncated, duplicate-key, unknown-schema, stale, mismatched-version,
mismatched-root, and syntactically valid but impossible-state records each have
explicit rows.

The normal successful backup is never auto-deleted, so no post-success cleanup
failpoint exists.

### 8.3 Repeated crash regression smoke

The user observed multiple macOS Godot crashes during prior updater testing.
Qualification therefore runs repeated fresh-snapshot cycles:

- 10 exact A -> B hot updates on Windows;
- 10 exact A -> B hot updates on macOS;
- 5 exact A -> B hot updates on Linux;
- 5 one-click byte-hashed final-v3 -> A migrations per platform;
- repeated Dock detach/reattach and plugin disable/enable around success and
  failure rows.

Before and after each run, capture platform crash-report directories, Godot
logs, process trees, and tree hashes. Any new Godot crash, abort, parse cascade,
or unexplained process death fails the candidate.

## 9. Functional and security matrix

At exact A and after A -> B, run:

- all Python unit/integration suites;
- all GDScript suites and pre-launch parse/import validation;
- protocol schema/error-code synchronization;
- transport challenge, transcript tamper, replay, wrong-scope, wrong-project,
  timeout, size, connection, and pending-budget cases;
- duplicate/pending session race and ACK-send failure;
- immutable session snapshots and atomic peer/session removal;
- managed, adopted, mismatched, lost, recovered, and explicitly replaced server
  lifecycle rows;
- capability path/permission/link/reparse rows within each platform claim;
- client configure/remove/repin/restart and private-index non-persistence;
- representative tool domains, resources, batches, reads, writes, undoable and
  non-undoable outcomes;
- release ZIP/manifest/signing/workflow contracts;
- telemetry opt-out before/after server start and update outcome exactly once;
- graceful editor/server/client restart and stale-artifact absence.

No test may enable the removed v3 transport as a success path. Mixed pairs must
fail closed within the locked timeout and point to matching-version migration.

## 10. Locked storm profiles

Phase 1 executes five baseline repetitions per platform and checks the numeric
thresholds into the verification manifest before Phase 2. The operation traces
are generated once from these fixed seeds and retained:

- `41001`
- `41002`
- `41003`

Target IDs are also RNG inputs and therefore locked: single-editor profiles use
`editor-a`; multi-editor uses `editor-a`, then `editor-b`. A different CLI name
is a different schedule and is rejected rather than compared to canonical
coverage floors.

### 10.1 Steady profile

- 8 workers;
- 20 waves;
- 25 calls per worker/wave (4,000 calls/seed);
- minimum 80 calls per supported domain, except 70 for the trace-bounded
  session/signal domains and 25 for project (the same floors apply to
  multi-editor);
- no intentional reload;
- exactly one live session at the bound endpoint, matching the authorized
  disposable project root and captured editor PID;
- every unique pinned platform/Godot row.

### 10.2 Reload-churn profile

- 12 workers;
- 30 waves;
- 25 calls per worker/wave (9,000 calls/seed);
- plugin/Dock reload every third wave;
- workers continue load through the recorded reload window; recovery must
  identify exactly one new session with the original editor PID and canonical
  project path before the scratch scene is considered recovered;
- managed and adopted-server topologies;
- client configure/repin churn;
- minimum 180 calls per supported domain and 60 for project;
- latest-stable Godot on all platforms plus Linux 4.7.0.

### 10.3 Multi-editor profile

- two distinct project roots plus a separate same-root activation-refusal row;
- four workers per editor;
- 20 waves, 25 calls per worker/wave;
- at least half of calls explicitly session-pinned;
- target-local rotation barriers: the rotating editor is quiesced while the
  other editor remains under load;
- focus, Dock, plugin, client, and server churn;
- all three platforms at current stable Godot.

### 10.4 Acceptance

- zero unexpected errors;
- `CONNECTION`/`EDITOR_NOT_READY` only inside recorded reload windows and zero
  outside; `SESSION` is always unexpected;
- 100% required reload survival;
- recovery p95 <= 15 seconds and maximum <= 30 seconds;
- per-operation p95/p99 below the checked-in baseline-derived thresholds and
  absolute caps;
- no operation/domain below its minimum coverage;
- every target is an explicitly bound absolute disposable project containing
  the exact qualification marker; locked input-map operations are read-only;
- the original saved `res://` scene is observed before setup, restored and
  observed after the run, and only the run-owned `res://_stormtest/` tree is
  removed;
- the final durable project inventory exactly matches its preflight inventory
  (the generated root `.godot/` cache is excluded); cleanup incompleteness or
  any path-level drift fails the storm contract;
- after 60 seconds quiescence, the surrounding qualification row (outside the
  storm runner) records zero pending requests, exact expected
  session/process/capability/lock counts, and no orphan transaction;
- checked-in absolute RSS/file-descriptor/thread ceilings and no monotonic
  post-quiescence growth across the five repetitions;
- replay of any failed generated trace reproduces the same operation sequence.

The storm harness now seeds independent worker streams, retains/replays an
operation trace, routes multiple explicit editors, records p99, enforces the
checked-in contract, proves reload replacement identity, and gates cleanup and
tree equality. The verification manifest still lists latency and resource
ceilings as unresolved baseline fields; those values must be reviewed and
checked in before these profiles can grant final release approval.
The locked-profile preflight enforces that boundary: it refuses while any
baseline field remains explicitly unresolved or while overall/per-operation
p95 and p99 ceilings are absent. Explicit `--measure-baseline` permits the
canonical schedule to run before that numeric review while retaining all
identity/error/coverage/cleanup checks. Every such report permanently carries
`baseline_measurement: true` and the contract failure `baseline measurement is
not qualification`, with a nonzero exit even if every other check passes.
Neither this mode nor non-locked exploratory runs can satisfy this release
gate. After review, fresh unflagged immutable-candidate runs remain required.

`script/qualification_resources.py` now supplies an identity-bound measurement
primitive for that surrounding harness: immediate retained JSONL observations
of explicit editor/backend PIDs, RSS, threads and native open-resource counts.
It refuses death/reuse/access failures, never reads process arguments or
environment, and reports `measured` rather than a qualification pass. Its
psutil dependency is pinned only in development/qualification test tooling.
Windows handles are recorded separately from Unix descriptors, with the other
field explicitly unavailable; choosing corresponding Windows ceilings requires
review, not relabeling handles as descriptors. The ownership/census proof,
60-second quiescence assertions, five actual baseline workload repetitions,
numeric ceilings and candidate-bound producer integration remain required.
See the [measurement companion](STRESS_TESTING.md#resource-measurement-companion).

## 11. Evidence and release approval

### 11.1 Pre-publication qualification bundle

The bundle required for publication approval contains:

- plan/review/verification versions;
- pinned base/oracle/PR/tag manifest;
- source A/B SHAs and parentage;
- plugin/Python artifact inventories, signatures, sizes, and hashes;
- per-row complete resolved distribution inventories and successful startup
  enforcement of the exact behavior-defining package versions;
- protected-signing approval identity;
- the compact one-time pre-v4 updater evidence record;
- all platform/Godot/Python results;
- migration transcripts and verifier output;
- interprocess/failpoint/crash reports;
- storm traces, thresholds, and summaries;
- simplification-gate before/after values;
- production/test LOC additions/deletions/net per tranche;
- every skip (required count: zero).

Non-Python rows also have exact required case IDs. Runtime evidence must include
`final-v3-to-a-one-click`, `exact-a-to-b-hot-update`,
`exact-candidate-functional-security`, `reopen-and-retained-backup-restore` and
`repeated-update-crash-regression`. Failpoint evidence must include the real
interprocess activation-lock matrix, deterministic failpoint/crash matrix and
corrupt-record matrix. Stress evidence must include steady, managed and adopted
reload churn, multi-editor, and post-quiescence resource cases. Missing,
duplicate, unknown or failed cases invalidate the row even when a producer
labels the surrounding result passed.

Publication approval names the exact A/B digest set. Any source, workflow,
document, manifest, package, or asset change after approval invalidates the
affected rows and requires a new pre-publication bundle.

### 11.2 Post-publication attestation

After publishing the already-approved A bytes, append a separate attestation
containing:

- public PyPI wheel/sdist download URLs and hash comparisons;
- public dependency artifact URLs and hash comparisons for the exact
  publication-smoke resolution on every supported OS/Python row;
- public GitHub asset inventory, download URLs, and hash comparisons;
- release/tag visibility and canonical migration-link checks;
- the immutable pre-publication approval identifier and digest set;
- any interrupted-publication recovery transcript.

The release is complete only when this attestation proves that every public
byte equals its approved digest. A mismatch does not revise the approval; it
blocks or withdraws the release and invokes the forward-only recovery plan.
