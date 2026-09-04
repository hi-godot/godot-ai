# v4 Architecture Simplification — Verification Plan

- Date: 2026-08-30
- Status: approved executable release contract; the ownership redesign has a
  local checkpoint. The storm profiles in section 7 are diagnostics rather
  than release gates, and no final qualification bundle or publication
  approval is recorded
- Purpose: make migration, updater, security, release, and stress gates
  executable against exact bytes
- Release range: Godot 4.7+ within the 4.x line
- Required desktop platforms: Windows, macOS, Linux

The updater sections were reduced on 2026-09-03 per
[self-update.md](self-update.md): the interprocess activation-lock matrix and
the failpoint/crash matrix were removed, and the migration and evidence
sections now describe the in-editor verify, stage, swap, restart, verify-again
path.

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

| Platform | Primary architecture | Godot runtime row | Python package rows |
|---|---|---|---|
| Windows | x86_64 | 4.7.0 (Python 3.11) | 3.11, 3.14 |
| macOS | arm64 | 4.7.0 (Python 3.11) | 3.11, 3.14 |
| Linux | x86_64 | 4.7.0 and 4.7.2 (Python 3.11) | 3.11, 3.14 |

The runtime row is keyed by the pinned binary hash of the reviewed 4.7.0
executable for that platform. The nightly diagnostics workflow exercises the
newer 4.7.2 engine on Linux; it does not replace or add a required row.

Godot 4.5 and 4.6 run explicit refusal/documentation checks: v4 does not enable,
the user sees the 4.7 floor, and no tree mutation occurs. Recurring hosted CI
runs this unsupported-engine floor guard on Linux only; it is not a supported
Windows/macOS qualification row. Every supported Godot 4.7+ row still runs on
all three required platforms.

Ordinary CI runs the core Python unit/integration suites on 3.11 through 3.14
on all platforms. The exact-candidate package rows run at the floor and
ceiling interpreters (3.11 and 3.14) so the exact server path is proven at
both ends; the runtime row runs at 3.11.

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
update/repin/backend/tool path over this transport, with unchanged
manager bytes in its live and backup trees. Its disposable signing key and
local server/client substitutions still exclude it from immutable-candidate
qualification; its retained shutdown-resource diagnostics also remain open.
Connecting this adapter to the
complete unchanged-candidate lifecycle, final-v3 migration, retained package
resolution and cross-platform runtime evidence producer remains required.

The qualification workflow's runtime row is the exact A -> B path. It
consumes the matching retained Python-row inventory, installs unmodified
signed A through the documented verifier, serves unmodified signed B through
the private HTTPS origin, resolves the exact server wheel through the retained
private index, and drives one real editor update from a harness-owned
autoload. The retained case verifies the changed backend identity, automatic
client repin, exact B live tree, exact A backup under
`addons/.godot_ai_update/backup/`, a `success` marker, engine hash/version and
absence of private endpoint credentials in retained output. Its required case
set is exactly `exact-a-to-b-hot-update`; the final-v3 capsule crossing and
the tampered-tree rollback are the other two real-editor scenarios in
`tests/integration/test_self_update_upgrade_paths.py`, run on Linux on every
pull request and on all three desktop OSes nightly.

Runtime jobs and aggregate evidence keys carry the engine version: one row per
desktop OS at Godot 4.7.0 / Python 3.11, plus one Linux row at Godot 4.7.2
(four runtime rows). The producer
rejects a reported engine version that differs from its requested stable
official identity. The checked-in
[engine manifest](verification/godot-builds-v1.json) pins the official 4.7.0
and 4.7.2 executables by exact size and SHA-256, with their source archive
digests; 4.7.0 is required on every OS and 4.7.2 on Linux. The runtime producer checks executable
bytes before even running `--version`, rejects a row labeled for a different
host OS, and retains the checked identity. Aggregate validation independently
compares the exact A→B case's engine identity against that manifest; evidence
cannot supply its own expected hash.

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

### 5.1 Trust roots

v4.0 uses the existing release-signing key. The migration instructions obtain
the small verifier from the exact immutable v4 release source commit. The
required reviewer on the `release-publish` environment is the approval, and
the publication receipt artifact records the public-key fingerprint plus the
six release-asset hashes, together with the verifier-file and wheel/sdist
digests of that commit. Promotion consults no second repository.

The signing key and the same GitHub owner account (`dsarno`) are the trust
roots. This is one human approval checkpoint, not independent administration;
the shared GitHub provider and owner account are explicit trust roots, and
their compromise is outside this guarantee.

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
2. the bridge verifies the embedded canonical signature and inventory inside
   the editor before any live mutation;
3. a lock held by another live editor on the same project refuses the update
   before the swap;
4. the complete old tree, bridge included, moves to
   `addons/.godot_ai_update/backup/<old version>/` and the exact v4 tree alone
   becomes live;
5. the bridge persists the v4 enabled entry without loading v4 in the old
   process, and Godot restarts itself;
6. first v4 startup hashes the live tree against the marker, records
   `success`, repins owned client entries, and starts the matching server; and
7. authenticated tools, later reopen, and restoring the retained backup work.

A wrong signature, malformed identity, or inventory mismatch fails before any
marker, backup, or live-tree mutation exists.

Each mandatory desktop row starts from a byte-hashed final-v3 tree with
old-only files and owned client entries. Older historical classes remain
outside the recurring support gate; the retained archaeology evidence does not
substitute for executing the exact final-v3 bridge candidate.

The harness scans the entire project after reopening for duplicate/stale
`class_name` failures and parse cascades. A backup anywhere in the project
outside `addons/.godot_ai_update/` is a hard failure.

### 5.3 Installation-surface audit

Before publication:

- GitHub release exposes the canonical v4 triple and the signed transition
  triple, with no second final plugin shape;
- README/direct links point to the migration page, not an overlay install;
- classic Asset Library and Asset Store listings remain on final v3 during
  qualification; that updater consumes only the signed transition capsule;
- source archives cannot be mistaken for updater payloads;
- the supported final-v3 Update path requires Godot 4.7+ and proves the
  automatic retained backup, exact replacement, client repin, and server
  startup.

## 6. Exact two-candidate qualification

### 6.1 Candidate identities

- **A:** final stable identity `4.0.0`, source SHA A. A's plugin ZIP, signed
  manifest, wheel, and sdist are the only bytes eligible for v4.0 publication.
- **B:** qualification-only identity `4.0.1`, source SHA B. B is a reviewed
  minimal child of A whose only runtime change is version/package identity. It
  also removes the bundled, runtime-inert `addons/godot_ai/README.md`, proving
  that the swap removes an A-only managed-tree file instead of overlaying B.
  B is never relabeled or published. Its patch number is not reserved: the
  next patch release publishes a fresh reviewed A under `4.0.1`, and the
  retained test-only B is the accepted residual recorded in the
  [release runbook](releasing.md#qualification-and-publication).

Both plugin manifests bind source SHA, repository, channel, tag/version,
artifact name/size/digest, and exact plugin-tree inventory. Each candidate's
sealed record additionally binds its wheel, sdist, and verifier files, and
every qualification row retains its resolved Python distribution inventory.

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
  |-> exact A -> B hot self-update (release gate)
  `-> pre-publication qualification bundle
       `-> release-publish reviewer approves the exact digest set
            `-> publish A byte-for-byte
                 `-> publication receipt + public redownload/hash check
```

Signing two different artifact sets under A's published identity is
forbidden. The retained test-only B that shares the next patch number with a
later reviewed A is the accepted residual recorded in the runbook; it is never
published and the updater consumes only GitHub Releases.

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
2. rebuild the expected record from the qualification artifacts and verify
   sources, identities, signer, and every digest; the `release-publish`
   reviewer is the approval;
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

## 7. Locked storm profiles

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

### 7.1 Steady profile

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

### 7.2 Reload-churn profile

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

### 7.3 Multi-editor profile

- two distinct project roots;
- four workers per editor;
- 20 waves, 25 calls per worker/wave;
- at least half of calls explicitly session-pinned;
- target-local rotation barriers: the rotating editor is quiesced while the
  other editor remains under load;
- focus, Dock, plugin, client, and server churn;
- all three platforms at current stable Godot.

### 7.4 Acceptance

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
  session/process/capability/lock counts;
- checked-in absolute RSS/file-descriptor/thread ceilings and no monotonic
  post-quiescence growth across the five repetitions;
- replay of any failed generated trace reproduces the same operation sequence.

The storm harness now seeds independent worker streams, retains/replays an
operation trace, routes multiple explicit editors, records p99, enforces the
checked-in contract, proves reload replacement identity, and gates cleanup and
tree equality. The verification manifest still lists latency and resource
ceilings as unresolved baseline fields; those values must be reviewed and
checked in before these profiles could become a release gate.
The locked-profile preflight enforces that boundary: it refuses while any
baseline field remains explicitly unresolved or while overall/per-operation
p95 and p99 ceilings are absent. Explicit `--measure-baseline` permits the
canonical schedule to run before that numeric review while retaining all
identity/error/coverage/cleanup checks. Every such report permanently carries
`baseline_measurement: true` and the contract failure `baseline measurement is
not qualification`, with a nonzero exit even if every other check passes.
Neither this mode nor non-locked exploratory runs is release evidence. The
nightly workflow runs the steady profile in this measurement mode and fails
only when the report carries any failure other than that expected contract
line.

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
numeric ceilings and candidate-bound producer integration remain open
diagnostics work, not release gates.
See the [measurement companion](STRESS_TESTING.md#resource-measurement-companion).

## 8. Functional and security matrix

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

## 9. Evidence and release approval

### 9.1 Pre-publication qualification bundle

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
- simplification-gate before/after values;
- production/test LOC additions/deletions/net per tranche;
- every skip (required count: zero).

Runtime rows also have an exact required case ID: runtime evidence must
include exactly `exact-a-to-b-hot-update`. Missing, duplicate, unknown or
failed cases invalidate the row even when a producer labels the surrounding
result passed. Storm results (section 7) are diagnostics and are not required
rows of this bundle.

The `release-publish` review approves the exact A/B digest set. Any source,
workflow, document, manifest, package, or asset change after approval
invalidates the affected rows and requires a new pre-publication bundle.

### 9.2 Post-publication attestation

After publishing the already-approved A bytes, append a separate attestation
containing:

- public PyPI wheel/sdist download URLs and hash comparisons;
- public dependency artifact URLs and hash comparisons for the exact
  publication-smoke resolution on every supported OS/Python row;
- public GitHub asset inventory, download URLs, and hash comparisons;
- release/tag visibility and canonical migration-link checks;
- the publication receipt's identity and digest set;
- any interrupted-publication recovery transcript.

The release is complete only when this attestation proves that every public
byte equals its approved digest. A mismatch does not revise the approval; it
blocks or withdraws the release and invokes the forward-only recovery plan.
