# Architecture Simplification Plan — Draft 3

- Date: 2026-08-30
- Status: approved implementation baseline; the ownership simplification and
  core Phase-6 transaction/recovery reducer are present, but the complete
  section-8.1 external failpoint surface, Phase 1 numeric storm ceilings, the
  Phase-6 real process matrix, and Phase-7 exact-candidate qualification remain
  open; publication is not authorized by this document
- Target: Godot AI v4.0
- Frozen maximal oracle: `957add991347e94443014cf97079d72713fb05c2`
- Frozen draft-2 commit: `ba31206`
- Review history:
  [review 1](architecture-simplification-plan-review-1.md),
  [review 2](architecture-simplification-plan-review-2.md), and
  [review 3](architecture-simplification-plan-review-3.md)
- Executable release proof:
  [verification plan](architecture-simplification-verification-plan.md)
- Final PR-head implementation evidence:
  [2026-09-01 checkpoint](v4-pr-head-checkpoint.md)
- Historical implementation evidence:
  [2026-08-31 checkpoint](v4-local-implementation-checkpoint.md)
- Draft-3 plan reconciliation at approval: architecture **PASS**, security
  **PASS**, execution/release **PASS**; this records plan consistency, not final
  candidate qualification

Implementation checkpoint, 2026-08-31: the current working tree passes every
mechanical structural gate in section 7. This is source-level evidence, not a
candidate qualification result. No final A/B bundle, approval, or public-byte
attestation is recorded by this plan.

## 1. Objective

The maximal hardening checkpoint is a behavior/security oracle, not the tree we
must ship. Draft 3 rebuilds only the required properties from a pinned main
commit.

The governing objective is:

> Make the codebase materially easier to reason about while retaining the
> security properties v4 actually needs.

This is not a line-count contest. A change is a simplification only when it
removes an owner, writer, legal state combination, dependency cycle, protocol
branch, compatibility obligation, or failure mode. Renaming or splitting a
class without deleting one of those does not count.

The v4 architecture work is deliberately narrower than draft 2. Resource-I/O
restructuring, a general JSONC engine, target-resolver layers, optional feature
PRs, and a general-purpose architecture analyzer are outside its critical path.

## 2. Approved product decisions

These decisions were approved for implementation on 2026-08-31. Changing one
requires an explicit plan revision.

### 2.1 v4 is a clean compatibility break

- No pre-v4 updater treats an overlaid payload as the final v4 tree.
- v4 publishes no `godot-ai-plugin.zip` alias; that name is a signed temporary
  transition capsule.
- The final-v3-to-v4 transition is one Update click followed by an actor-owned
  exact-tree replacement.
- No pre-v4 add-on file is merged into the live v4 tree: the whole old add-on
  moves to an external recovery backup, then the signed v4 inventory becomes
  the entire live add-on. Project content and unrelated user/client settings
  remain outside that replacement boundary.
- v4 uses one secure transport protocol; mixed v3/v4 peers fail closed.
- v4.0 contains the new transactional updater.
- v4 and later retain one-click hot self-update for the ordinary single-editor,
  owned-server case.
- A hot update refuses before mutation if another editor uses the same install
  root or if the recovery/lock path cannot be proven safe.

The bridge supplies the authority that already-released runners lack. The v3
runner authenticates only the outer capsule; the temporary bridge verifies and
stages the inner canonical tree, waits for new-code readiness, and retains the
complete old tree transactionally.

The 30-day latest-plugin cohort was 5.4% pre-v3, 78.5% other v3.x, and
16.1% exact v3.2.4. Truly old installs are a small minority, but every current
install must cross the v4 boundary and most are not on the latest v3. In a
nearby aggregate, 44.8% of active installs had emitted a self-update outcome.
That supports a deliberately narrow final-v3 bridge without carrying general
historical compatibility into the v4 runtime.

### 2.2 v4 requires Godot 4.7+ within the 4.x line

Recent aggregate engine-version telemetry found:

| Engine cohort | Installs | Share of 17,678 |
|---|---:|---:|
| 4.7+ | 15,417 | 87.2% |
| 4.6 | 1,890 | 10.7% |
| 4.5 | 330 | 1.9% |
| older/other | 41 | 0.2% |

Method: 30-day window ending 2026-08-30, latest `godot_connection` engine
version per anonymous customer UUID, grouped by engine minor. Only aggregate
counts were returned; no identifiers were copied into the planning workspace.

A major release is the right point to raise the floor. Godot 4.7 removes the
old installer root-stripping workaround, so v4 can publish one package shape
instead of separate classic/store ZIP shapes plus a root-license sibling.

The migration page tells 4.5/4.6 users to upgrade Godot before activating v4.
The final signed v3 line presents one ordinary Update action; the temporary
bridge then enforces the exact-tree boundary. Exact floor/latest patch rows are
pinned at implementation start.

### 2.3 v4.0 crosses the boundary through a temporary bridge

The classic Asset Library and Asset Store can overlay an existing
`addons/godot_ai` tree without deleting old-only files. They cannot enforce the
closed-editor replacement boundary. Their v3 listings therefore remain frozen
while v4 is qualified. The final signed v3 updater may consume only the signed
transition capsule, never the canonical v4 archive as an overlay.

v4.0 publishes one canonical signed tree plus a legacy-named, signed capsule
that embeds that exact tree and a minimal transition plugin. The capsule is
temporary: it delegates to the v4 actor, retains the complete mixed old tree,
and commits only the canonical v4 tree. Store install can return only after a
store surface can preserve the same clean replacement boundary.

### 2.4 Keep one retained backup

The activation protocol never automatically deletes its successful backup.
The Dock reports its external path and hash. Cleanup is a separate,
editor-closed user action.

At most one retained backup may block a new activation. If one already exists,
the next update refuses before download/mutation and asks the user to archive or
remove it explicitly; it never silently rotates or overwrites recovery data.

This removes post-readiness cleanup authority, cleanup-failed terminal states,
and claim-versus-cleanup crash ordering. Storage policy can be revisited after
the first v4 update history exists; it is not part of activation correctness.

### 2.5 Narrow Windows local-process claims

Aggregate 30-day platform data is approximately 75% Windows, 13% macOS, and
12% Linux, so Windows is a mandatory release platform.

v4.0 does not add partial DACL machinery and does not claim secrecy or
integrity against another local account or a malicious process running as the
same Windows account. It uses fixed default locations, rejects configurable
Windows capability/recovery overrides, and rejects detectable reparse paths.
Its Windows claim is unauthenticated remote-peer exclusion plus accidental
mixed-instance protection.

POSIX other-user claims apply only where owner, mode, and link checks succeed.

## 3. Threat model

### 3.1 v4 protects against

- a release-asset/release-note publisher who lacks the signing key and trusted
  repository write authority;
- malformed archives, path traversal, unsafe links/reparse points, case
  collisions, stale files, mixed-version trees, and interrupted activation;
- unauthenticated HTTP or editor peers and loopback listener impostors;
- mixed v3/v4 transport peers;
- accidental same-user stale processes, duplicate sessions, and concurrent
  editors;
- other local users on POSIX when verified private-path checks pass;
- editor/updater process crashes at named durable boundaries;
- ambient project/user uv configuration selecting an alternate Python package
  index or already-installed tool environment for a production launch.

### 3.2 v4 does not protect against

- compromise of the release-signing key, protected signing workflow, trusted
  repository source, or required approver;
- compromise of the `dsarno` GitHub account or GitHub itself: the approved
  attestation channel is a separately permissioned repository, not independent
  administration or a separate hosting trust root;
- compromise of PyPI's index/artifact service or TLS delivery, the selected
  `uv` executable/cache, or the exact `godot-ai` wheel served under an approved
  version; plugin signing does not independently bind later-resolved wheel
  bytes;
- administrator/kernel compromise;
- malicious code already running as the same OS account;
- an attacker who can arbitrarily rewrite the user's project/plugin source;
- hostile local accounts/processes on Windows under the narrowed v4.0 claim;
- sudden power or storage-controller loss without an independently proven
  durability primitive.

Release assets and release notes are inputs, never trust roots. The signing key
authenticates the plugin tree. Official PyPI/TLS plus uv and same-user local
machine integrity are separate global trust roots for the Python server and
transaction actor. Their package/protocol identity response proves
compatibility only, not provenance.

## 4. Security and correctness invariants

Every tranche names the invariants it changes and links to executable proof.

### 4.1 Transport

- **T1:** HTTP and editor transports use distinct random capabilities.
- **T2:** the editor verifies server possession before sending project
  metadata.
- **T3:** the server verifies the editor before publishing a routable session.
- **T4:** missing, malformed, stale, wrong-project, or wrong-scope credentials
  never fall back to a weaker protocol.
- **T5:** raw connections, handshake bytes/time, payload bytes, per-peer
  futures, and aggregate pending work are bounded.
- **T6:** capability/recovery paths satisfy the platform-specific threat claim;
  an unverifiable path fails closed.

### 4.2 Clean migration

- **M1:** every released updater implementation either has no updater or
  selects only the absent legacy asset; pressing Update cannot mutate v4.
- **M2:** all editors, old clients, and old managed backends are stopped before
  the old add-on tree moves.
- **M3:** the v4 archive is authenticated and structurally validated before the
  live v3 tree moves.
- **M4:** the backup is canonicalized outside the entire project root and stays
  recoverable.
- **M5:** the new live tree exactly matches the signed v4 manifest.
- **M6:** owned client configuration is repinned and the exact actor records
  durable migration completion before matching-version server health and
  representative tools are declared successful. Clients reconnect to the
  stable endpoint; restart is remediation for a client that does not reconnect,
  not an unverifiable global confirmation gate.

### 4.3 v4 self-update

- **U1:** discovery, repository, channel, source, tag/version, manifest,
  signature, artifact name/size/digest, and exact inventory are authenticated.
- **U2:** staging completes and validates before quiescence or disablement.
- **U3:** one canonical install-root lock excludes another activation/editor
  before any live-tree mutation.
- **U4:** prepared state binds the signed new tree, prepare-time old tree,
  canonical roots, and initiating editor. Intent/journal, readiness,
  result/claim, and migration-completion records then strictly bind the
  identities appropriate to their phase, including the transaction, actor,
  live tree, claim, and editor lease.
- **U5:** the initiating reload lineage remains behind a startup barrier until
  it atomically claims the matching terminal result. Any non-initiating editor
  that encounters the active lock fails closed before normal composition and
  must be re-enabled or restarted after the transaction; it cannot continue
  stale compiled code as an observer.
- **U6:** the old runner is the only normal result writer; a dead runner is
  recovered only by an explicit user-invoked repair takeover.
- **U7:** one external backup is retained after success; rollback/quarantine
  never depends on automatic cleanup.
- **U8:** every recognized interrupted state has one next action: finish, roll
  back, quarantine, wait, or request repair.

### 4.4 Ownership and state

- **O1:** Dock owns controls/view-local state only.
- **O2:** no domain owner retains `plugin.gd`, Dock, or a generic host.
- **O3:** one client-work owner holds workers, cancellation, orphans, and
  quiescence.
- **O4:** one Python aggregate holds session state, peer, and per-peer futures.
- **O5:** lifecycle has one tagged active episode; startup and recovery cannot
  coexist.
- **O6:** readers receive no mutable owner record or retained mutable Dictionary
  alias.

### 4.5 Authority

- **A1:** `TransportAuthority` permits communication only.
- **A2:** `OwnedProcessGrant` permits control only of a process launched and
  fingerprinted by this plugin instance.
- **A3:** `ReplacementAuthorization` originates only from a fresh explicit user
  action, is narrowly bound/expiring/spend-once, and is never minted by a
  journal, readiness record, result, PID, or transport capability.
- **A4:** adopting an external server may retain transport authority but always
  surrenders process ownership.
- **A5:** an update may stop an ordinarily owned server. An unowned stale server
  requires a separate post-update **Replace stale server** action.
- **A6:** every production server, attach, prewarm, and transaction-actor uvx
  command uses the one isolated/no-config/no-build resolver policy with
  official PyPI explicit; Godot-owned spawns also clear inherited uv resolver
  controls under the process-spawn mutex.
- **A7:** only an explicit process-local qualification switch plus private uv
  index authorizes non-PyPI resolution. It and its credentials never persist
  into client configuration, project files, transaction records, logs, or
  telemetry.

### 4.6 Persistence honesty

- **D1:** `McpResourceIO` remains the cohesive persistence/response-contract
  helper.
- **D2:** results distinguish committed, partial, non-undoable, cleanup-failed,
  and failed outcomes where those states actually exist.
- **D3:** no API calls an operation atomic when Godot/filesystem primitives do
  not provide that property.
- **D4:** file/JSON/resource inputs remain bounded and path-confined.

## 5. Minimal collaboration and lifetime graph

Reuse existing published owners. A role below is not permission to add a
wrapper class.

```text
plugin.gd (composition root only)
├── McpServerLifecycleManager
├── McpClientConfigurator + one client-job owner
├── McpUpdateManager
├── McpConnection / McpDispatcher
└── McpDock (replaceable view)

Python process
├── GodotWebSocketServer (single editor-connection table)
└── GodotClient (depends only on that table's interface)
```

Not root owners:

- `McpTransportCapability` and process/path helpers are static boundaries;
- `McpResourceIO` remains a lazy handler utility;
- update runner and repair are transaction-scoped actors;
- endpoint policies, snapshots, authorities, plans, records, and outcomes are
  values;
- reducer/effect helpers stay colocated implementation details unless a real
  dependency edge is removed.

### 5.1 Allowed dependency directions

```text
plugin.gd
  -> constructs owners without starting effects
  -> routes Dock intents to owners
  -> fans immutable snapshots/outcomes to consumers
  -> invokes the exact actor for authenticated preparation
  -> quiesces the client owner and constructs a detached coordinator after preparation

McpDock
  -> emits intents
  <- receives snapshots

McpUpdateManager
  -> signed release discovery and bounded private-root download
  -> emits the downloaded candidate's bounded asset/identity values
  <- candidate/progress/outcome values

McpServerLifecycleManager
  -> endpoint policy / managed-server plan
  -> narrow process, probe, timer, and connection-control effects

client-job owner
  -> McpClientConfigurator policy/mutation helpers
  -> attach plan
  <- root-delivered lifecycle snapshot and post-update intent values

GodotClient -> GodotWebSocketServer editor-table interface
```

Forbidden:

- an owner receiving the root/plugin as `_host`;
- UpdateManager retaining Dock, plugin, lifecycle, or the client owner;
- Dock directly owning/calling lifecycle, update, or client worker state;
- detached runner receiving a Node/RefCounted owner instead of bounded values;
- a second session/peer membership map;
- desired launch settings duplicated inside runtime transport identity.

### 5.2 Lifetimes

| Lifetime | State |
|---|---|
| Python process | editor connection table, `GodotClient` |
| Plugin enable | lifecycle, client work, update manager, connection/dispatcher |
| Dock attachment | Dock controls and view-local values only |
| Editor peer | one entry in the editor connection table |
| Command | one future inside that peer, charged to the global budget |
| Activation transaction | prepared state, activation lock/editor leases, intent/journal/readiness/result/claim records, durable migration-completion acknowledgement, staged tree, actors, and backup creation |
| Install-root recovery artifact | retained successful backup plus its immutable path/hash reference until explicit editor-closed archive or removal |

Construction has no side effects. Normal startup begins only after the
activation barrier resolves. Teardown reverses construction; Dock may detach
at any time without destroying domain work.

## 6. Target designs

### 6.1 Secure v4 handshake

```text
editor -> auth_hello(minimal version + nonce)
server -> challenge + transcript-bound server proof
editor verifies server
editor -> project metadata + transcript-bound client proof
server verifies editor
server reserves session ID as pending
server sends simple ACK
server atomically publishes active session + peer
```

ACK-send failure releases the reservation. An HTTP request can route only to an
active entry, so no command races ahead of client authentication.

There is no legacy parser, tokenless retry, or final ACK HMAC. Ordered delivery
after the authenticated challenge is sufficient for the terminal transition;
plaintext WebSocket is not described as cryptographic transport integrity.

### 6.2 One editor connection table

Rework `GodotWebSocketServer` rather than adding `ConnectionHub` plus a separate
registry.

One map holds an entry tagged `PENDING` or `ACTIVE`. An active entry contains:

- private mutable session state;
- the peer/socket abstraction;
- per-peer pending futures and local count.

One server-level counter enforces the aggregate pending budget. The asyncio
loop serializes membership changes; no new lock layer is needed. Mutation uses
intent-named methods and all reads return frozen snapshots. `GodotClient`
routes, consumes diagnostic budgets, and waits for sessions through this one
interface.

### 6.3 Endpoint policy and plans

Capture settings once into a canonical `EndpointPolicy` value. From it derive:

- `ManagedServerPlan` for a plugin-owned Python process;
- `AttachPlan` for a configured external client, including client-specific
  console/wrapping requirements.

They are distinct effects and do not share one branch-heavy `LaunchPlan`.
`TransportIdentity` represents a proven live endpoint/capability snapshot, not
desired settings.

For GDScript, immutable means owners retain no caller-owned mutable Dictionary.
Boundaries deep-copy or use read-only values, with no-alias tests.

### 6.4 Lifecycle episode reducer

Keep `McpServerLifecycleManager` as the serialized dispatcher. Replace
independent startup/recovery/retry/generation flags with one tagged state. Every
effect result carries its episode ID; stale results are ignored.

| State | Event/result | Next | Requested effect |
|---|---|---|---|
| `DORMANT` | start | `STARTING(PROBE)` | probe endpoint |
| `STARTING(PROBE)` | compatible authenticated endpoint | `READY(adopted)` | publish transport; no process grant |
| `STARTING(PROBE)` | free endpoint + valid plan | `STARTING(LAUNCH)` | spawn |
| `STARTING(LAUNCH)` | spawn success | `STARTING(PROVE)` | record grant; await proof |
| `STARTING(PROVE)` | proof success | `READY(owned)` | publish transport |
| `STARTING(*)` | bounded failure | `BLOCKED(reason)` | notify |
| `READY` | transport/process lost | `BLOCKED(reason)` | clear invalid authority |
| `BLOCKED` | explicit valid replacement grant | `RECOVERING` | spend grant once |
| `RECOVERING` | endpoint cleared | `STARTING(PROBE)` | continue same episode lineage |
| any non-stopping | stop | `STOPPING` | stop only with process grant |
| `STOPPING` | complete | `DORMANT` | clear authority |

The lifecycle tranche removes the generic `_host` reference and obsolete flag
paths in the same change. The Python `BackendEnsurer`, lease, and self-reaper
remain in the authority map.

### 6.5 Client work

Move all reload-surviving worker, cancellation, phase, generation, and orphan
state out of Dock. Reuse `McpClientConfigurator` for client policy/mutation;
add at most one private preload-only job owner if instance lifetime cannot live
there cleanly.

The update manager receives no client-owner callable and does not own client
jobs or repin. The root quiesces the client owner after preparation and
constructs the value-only coordinator. After the update result is claimed, the
root fans the value to the client owner and requests repin; neither owner
retains the other.
The successful claim itself is the durable pending-migration fact, so a second
mutable state machine is unnecessary. Only the exact transaction actor may
publish the immutable completion acknowledgement that releases normal startup.

Every automatic Configure/Remove mutation, including an M6 repin, acquires one
account-wide durable mutation directory and holds it through post-write status
verification. Status probes remain lock-free. Consequently an M6 batch is not
an atomic compare-and-mutate transaction: its initial probe/drift decision can
become stale before the individual write acquires the lock, and another project
can complete a serialized write between those points. V4 accepts this as a P2
last-writer seam; it does not claim whole-batch client atomicity.

Do not create general `TargetResolver` or `EntryPolicy` services in v4. A small
pure helper is accepted only when it deletes duplicated policy.

### 6.6 One-click v3-to-v4 migration

Historical inventory established that updater-bearing releases select
`godot-ai-plugin.zip` by exact equality. The release therefore carries two
roles without creating two v4 runtime shapes:

- `godot-ai-v4-plugin.zip` plus its signed manifest is the only canonical v4
  tree; and
- the signed legacy-named ZIP is a minimal bridge with that canonical triple
  embedded.

After the one user Update action, the signed v3 updater authenticates and loads
the bridge. The bridge resolves the exact target transaction actor, verifies
the inner signature/inventory, prepares a private stage, disables itself, and
enters the same activation protocol as a v4 update. Once the exact v4 tree is
live, the bridge asks Godot to restart itself so no loaded v3 `class_name`
resource can be rebound to a v4 call site. The restarted process inherits the
bounded nonce/actor handoff and receives the lease only after the actor proves
the prior editor process closed. The actor retains the
complete temporary/old tree and renames only the exact canonical stage live.
First v4 startup broadly replaces owned pre-v4 client entries, durably records
completion, and starts the managed server without a second confirmation.

The publication receipt documented in
[the release runbook](releasing.md#trust-roots-and-the-retired-attestation-channel)
still binds the source commit, both
verifier-file digests, all six release assets, Python-package artifacts,
and signing-key fingerprint, and the qualification evidence retains every
dependency inventory. A capsule
is transitional delivery code, not authority to weaken canonical verification
or introduce permanent v3 branches into v4.

### 6.7 Transactional v4 updater

Preparation occurs while the old plugin remains enabled:

```text
discover -> authenticate -> exclusive preflight/editor lease
         -> allocate private download root -> bounded download
         -> verify -> extract -> exact-tree validate -> publish prepared.json
         -> root quiesces client/server work -> disable and hand off
```

Activation reduces one exclusive transaction directory through these strict
records and authorities:

1. **prepared** — immutable signed-manifest-derived new-tree identity,
   prepare-time old-tree identity, canonical roots, versions, initiating editor,
   and stage location;
2. **intent/journal** — reconstructed prepared identity, transaction, versions,
   manifest/tree hashes, initiating editor process fingerprint/nonce, runner
   nonce, phase, and recovery action;
3. **readiness** — the initiating new root invokes the frozen old-package
   startup actor, which verifies the matching live version/tree and publishes
   readiness;
4. **result -> claim** — the long-running activation actor writes the bounded
   result; the frozen startup actor validates and atomically renames that exact
   record to claim it; and
5. **migration-complete** — that same frozen actor acknowledges the completed
   M6 client barrier, bound to the claim, live tree, and editor lease.

The activation lock and editor leases are separate durable authorities, not
fields that a record can mint.

Normal event order:

```text
old actor publishes prepared.json while old code is live
-> activation actor reconstructs intent and publishes intent/journal
-> activation actor replaces live tree and publishes stage_live
-> coordinator scans and enables new code
-> new root enters STARTUP_BARRIER and invokes the frozen startup actor
-> startup actor writes readiness
-> activation actor validates readiness and writes result
-> startup actor validates and atomically renames result to claim
-> root repins owned client configuration
-> actor publishes migration-complete acknowledgement
-> root fans one immutable PostUpdateOutcome
-> root releases normal lifecycle/client/telemetry/update startup
```

If the editor exits after claim but before acknowledgement, ordinary startup
rediscovers the one uncompleted successful claim, verifies that it names the
current exact live tree, reacquires an editor lease, and repeats the client
migration barrier. Completion requires that exact lease and is an immutable,
strict record bound to the claim and intent. A completed historical claim is
semantically complete, but it is not ignored: startup and update preflight
strictly validate retained history before deciding that no obligation remains.
This reuses transaction history as authority instead of adding a parallel
root-level pending pointer or reducer.

V4 transaction records use schema 1. Transaction directories are retained and
there is no compaction pass, so future schema evolution must first define a
bounded migration or compaction policy for historical records. A malformed,
foreign-bound, or unsupported retained record deliberately fails closed; users
must not hand-edit transaction JSON to bypass that refusal.

Other editor processes are not transaction observers. An editor already live
holds a lease and blocks preflight. An editor opened after lock acquisition is
refused before normal composition and disables the plugin; it must load the
post-transaction tree in a later re-enable or process restart. This deliberately
avoids letting an old in-memory GDScript instance continue against a newly
renamed tree. Only the initiating lineage may write readiness, claim, or fan
`PostUpdateOutcome`.

The old runner holds the only normal writer lock. If it dies, no actor steals
automatically. Startup remains behind the barrier and requests the existing
Python runtime's `repair-update` command. After the user closes editors, repair
proves the recorded process is dead, atomically claims the transaction, and
uses the same reducer to complete, roll back, or quarantine it.

State records and locks live in the external recovery root. They never contain
or mint process authority. Activation may carry only the existing
`OwnedProcessGrant` for the ordinarily managed server. An unowned stale server
is handled after update by a fresh, separate **Replace stale server** action.

The successful backup remains external and untouched. This is editor/process
crash durability only; no power-loss claim is made.

## 7. Simplification gates

Use small mechanical checks tied to changed owners. Do not build a general
architecture-analysis product.

| Gate | Target |
|---|---:|
| lifecycle generic `_host.*` dependencies | 40 -> 0 |
| UpdateManager retained plugin/Dock references | 0 |
| detached runner retained owner/Node references | 0 |
| Dock-owned client worker/static stores | 0 |
| non-client-owner client `Thread.new()` spawns | 0 |
| Python session/peer membership maps | 2 -> 1 |
| external mutable Session field assignments | 0 |
| owner dependency cycles in changed graph | 0 |
| legacy/tokenless transport branches in v4 | 0 |
| v4 release plugin ZIP shapes | 1 |
| active lifecycle episode variants at once | 1 |

Per tranche also report production additions/deletions/net separately from
tests, changed mutable fields/writer sites, and the exact old field/edge/state
each new type deletes. LOC and SCC/fan-in reports are informational.

Published `class_name` compatibility remains a separate contract from updater
and wire compatibility. Draft 3 does not authorize deleting those declarations;
any future removal requires an explicit API decision plus clean-install and
class-cache evidence rather than being hidden inside a refactor.

The draft estimated 63,605 physical `.py`/`.gd` lines under `src/` and
`plugin/`. The pinned `a468a7e` gate supersedes that estimate with the measured
baseline of 59,859. At the historical `ed69dcd` implementation checkpoint the
tree contained 64,561 production physical lines, a net increase of 4,702. At
the final PR head `d6444e6`, the same gate reports 64,581 production physical
lines, a net increase of 4,722, while all eleven structural targets pass. The
result is a reduction in owners, branches, legal state combinations, and
duplicated authority—not a LOC reduction. Recompute both values from the frozen
candidate before approval.

## 8. Outstanding PR dispositions

Live status was revalidated on 2026-08-31 after the rebuild base was pinned.
Six PRs remain open; #940 merged independently in the pinned base.

| PR | Head at review | V4 outcome |
|---|---|---|
| #936 | `537a490c865837bedb96042d10ee0fc74673cd99` | superseded with provenance: root nulls the lifecycle on every exit path, and the manager no longer retains a cyclic version-check object |
| #927 | `1a95bcca51d81d29de925c2f636814eaa037c1c2` | ported with stronger owned/unowned descendant undo/redo coverage |
| #931 | `418fb5e2eec516f2b34251f0034dc37fe26e680c` | ported before the transport rewrite; live opt-out is re-read on record/send/status paths |
| #930 | `ea79e5a3735198d3be9d562871fddcb0a699bf0a` | intentionally superseded: Zed is read-only/manual-config rather than adding a general JSONC mutation subsystem |
| #934 | `5880005515e5fc234ed75f36c1b1cdd3f4595d0d` | explicitly deferred until after v4; resource persistence is unrelated feature expansion |
| #892 | `d16770c017f106d7035d9a1d59479bb0e3693668` | explicitly deferred until after v4; bulk physics generation is unrelated feature expansion |
| #940 | `d4f16f538710674e01136b1e0ba88bf458c120f4` | merged independently as `a468a7e`'s immediate history before the rebuild base was pinned |

For #930, v4 does not attempt to preserve arbitrary JSONC through a custom
parser. If Zed's supported configuration surface remains comment-bearing, the
Dock shows the exact manual entry and never rewrites the file. This turns a
large parsing subsystem into a bounded product limitation.

For #940, acceptance is a product choice, not an architecture dependency.
Merging an accepted clean PR before the pinned base is simpler than reworking
it after shared registration files change.

Every PR ends as merge, port, supersede-with-tests, or defer/exclude. No PR is
silently absorbed into a bulk commit.

## 9. Implementation proof DAG

At implementation start, pin:

- landing-base SHA;
- oracle SHA/tag;
- accepted PR heads/patch IDs;
- the retained one-time historical evidence digest and boundary decision;
- exact test-profile manifest;
- expected-red/current-green/intentional-v4-difference ledger.

Characterization tests live in standalone commits or an external harness that
can run unchanged against both oracle and rebuild. A test is never copied and
quietly edited between sides.

```text
oracle tag 957add9 ---------> oracle evidence
                              ^
shared characterization -----|
                              v
pinned main -> tranche T1 -> green tag T1
            -> tranche T2 -> green tag T2
            -> ... -> final source A
                         |-> exact v4.0.0 bundle A
                         `-> minimal qualification child source B
                              -> exact v4.0.1 qualification-only bundle B

bundle A + bundle B + per-row dependency artifacts
                    -> pre-publication qualification evidence
                    -> publication approval bound to digests
                    -> publish bundle A byte-for-byte
                    -> public redownload/hash attestation
                    -> release-completion record
```

The successor has a unique signed, stable-shaped qualification identity. Version
`4.0.1` is permanently burned for this proof: it is never published, relabeled,
or reused, so the next publishable stable version is at least `4.0.2`. Before an
eventual v4.1 release, published v4.0 must qualify the exact private stable-v4.1
candidate that will be published.

Main synchronizes only between immutable green tags. Each sync is range-diffed
and re-runs affected evidence.

## 10. Implementation phases

Checkpoint status: Phase 0 decisions and inputs are pinned. Phase 1's historical
boundary proof and architecture baseline are retained, but its numeric storm
latency/resource ceilings remain unresolved. Phases 2-5 and the core Phase-6
transaction/recovery reducer are present and pass the section-7 mechanical
gates. Phase 6 is not implementation-complete: the current external failpoint
adapter covers only a subset of activation and coordinator effects. It now
selects repeated effect names by explicit occurrence. The complete section-8.1 surface and
actual process matrix remain required before Phase 7. The phase bullets below
stay as the approved execution contract rather than being rewritten as a
release changelog.

The [PR #949 follow-up](v4-release-review-followup.md) records the release
workflow hardening, handler-quiescence/shutdown repair, restart handoff fixes
and development checks. Restart now persists the next-start enabled list
without loading v4 in the old editor, and waits through transient predecessor
uncertainty without transferring its lease until positive closure proof.
Qualification now explicitly refuses before final signing while the remaining
runtime/failure/stress producers and reviewed numeric ceilings are absent;
these changes do not close Phase 6 or Phase 7.

### Phase 0 — approve and pin

- review draft 3 and the verification companion;
- affirm Godot 4.7+ within the 4.x line and one-click final-v3 bridge;
- decide #940 independently;
- fetch/pin landing main and all PR/tag inputs;
- write the tranche/provenance manifest;
- record current runnable tests and environment gaps.

Exit: approved scope and immutable inputs.

### Phase 1 — characterize externally

- freeze only invariant/user-visible behavior;
- classify all historical updater implementations once and retain the compact
  result, not the implementation-era classifier stack;
- baseline the explicit simplification gates;
- establish deterministic seeds/workloads and numeric stress ceilings;
- mark each proof expected-red, current-green, oracle-only, or intentional v4
  difference.

Exit: repeatable evidence with no architecture changes.

### Phase 2 — composition and client work

- port/supersede #936, #927, and #931 with provenance;
- root-own existing managers and Dock;
- move all client work out of Dock;
- remove update-manager Dock/plugin retention;
- establish pure endpoint policy plus separate managed/attach plans;
- make construction side-effect-free and add the activation startup barrier.

Exit: O1-O3/O6 pass; updater and client seams will not be rewired again.

### Phase 3 — v4 transport and editor table

- implement the one v4 handshake and ACK-before-publication;
- remove legacy fallback and final ACK HMAC;
- centralize capability/transport snapshot access without a wrapper service;
- collapse session/peer/future membership into one Python table;
- enforce snapshot-only reads and global/local budgets;
- implement the fixed Windows scope.

Exit: T1-T6 and O4 pass; mixed v3/v4 pairs fail quickly/actionably.

### Phase 4 — lifecycle and authorities

- introduce the tagged lifecycle episode inside the existing manager;
- replace generic host/proxy calls with narrow value/effect boundaries;
- implement the three authority values across Godot/Python;
- prove adoption, stop, recovery, stale-result, and spend-once behavior.

Exit: O5 and A1-A5 pass; hard lifecycle gates are met.

### Phase 5 — migration and release shape

- implement one Godot-4.7 v4 package producer and distinct asset name;
- implement the standalone verifier using the existing signing root;
- freeze/deprecate overlaying store surfaces;
- preserve the completed historical updater classification while adding a
  recurring final-v3 bridge gate;
- test both signature layers, external backup, exact replacement, automatic
  client repin, and server startup after one Update action.

Exit: M1-M6 pass against provisional release-shaped fixtures. No fixture is
called a final candidate.

### Phase 6 — transactional updater

Checkpoint: the reducer, durable records, startup barrier, and production-inert
qualification capability are present. The qualification adapter is partial;
all section-8.1 effects still need unique external addressing and command-path
wiring before the process matrix can run as specified.

- implement external recovery root, install lock/editor leases, exact staging,
  prepared/intent/journal/readiness/result/claim/migration-complete reducer,
  retained backup, and startup barrier;
- expose repair through the existing Python CLI/runtime, not a new service;
- add externally controlled, production-inert failpoint barriers;
- run two-editor, crash, rollback, quarantine, and repair proofs.

Exit: U1-U8 pass against signed qualification fixtures.

### Phase 7 — exact qualification and publication

- freeze source A only after all v4 code/docs are complete;
- create unique minimal qualification child B;
- build/sign plugin and Python bundles for both without public release;
- serve exact A and B bytes under their canonical tag/artifact paths through
  private release discovery and the private PEP 503 index;
- run the full companion verification plan on Windows/macOS/Linux;
- approve the pre-publication evidence bound to both digest sets;
- publish A's Python distributions first, verify public hashes, then publish
  A's exact signed plugin assets without rebuilding.

Exit: public v4.0 bytes are identical to approved bytes, the public redownload
attestation is green, and no required row was skipped.

### Phase 8 — post-v4 optional work

Only after v4 architecture is stable:

- reconsider #934/P6 persistence feature;
- reconsider #892 and other optional features;
- reconsider Store distribution once clean-install enforcement exists;
- use actual support data before any backup-retention or Windows-DACL expansion.

## 11. Explicit deferrals

- v3 transport inside v4;
- permanent pre-v4 runtime compatibility inside v4;
- shared multi-project listener;
- generic JSONC mutation/parser work;
- `TargetResolver`/`EntryPolicy` service split;
- structural `McpResourceIO` refactor;
- automatic successful-backup deletion;
- DACL-based hostile-local-user claim on Windows;
- power-loss durability;
- general-purpose cognitive-metrics analyzer;
- atomic compare-and-mutate across the M6 probe-to-client-write interval;
- historical transaction-record schema migration or compaction;
- unrelated UI/features and opportunistic cleanup.

## 12. Approved implementation decisions

1. Godot 4.7+ within the 4.x line is the v4 support range despite the measured 12.8% 4.6-and-older
   cohort.
2. v4.0 uses one signed final-v3 transition capsule around the canonical v4
   triple; v3 Store/Asset Library listings remain frozen during qualification.
3. Accept #940 independently before the landing-base pin if its refreshed head
   remains the reviewed clean change; otherwise re-review or explicitly defer.
4. Zed becomes manual-config rather than carrying #930's general JSONC
   mutation subsystem.
5. v4.0 uses the narrowed Windows claim rather than partial DACL enforcement.
6. v4.0 never automatically deletes a successful retained backup.

## 13. Approval meaning

Approval authorizes a pinned rebuild branch and Phases 0-7. It does not
authorize publication, destructive mutation of a user's project, or optional
Phase-8 work.

The end state is a codebase where a maintainer can answer directly:

- who owns this state;
- which single path mutates it;
- which authority permits the action;
- which episode is active;
- what survives reload/crash;
- why startup is blocked;
- exactly what the user must do next.
