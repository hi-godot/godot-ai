# Releasing and self-update

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the
always-loaded rules.

Godot AI v4 has one signed canonical tree and one exact-tree transaction
protocol. A temporary, signed v3-compatible capsule carries that same tree
across the major-version boundary; it is not a second v4 runtime shape. See the
[v4 migration guide](v4-migration.md) for the one-click user flow.

## Qualification and publication

V4 may publish only immutable, qualified bytes. `release-qualification.yml`
builds and signs the A/B candidate pair once, then runs the release gate on
those exact bytes:

- **Python rows** — `ubuntu-latest`, `macos-latest`, `windows-latest` × Python
  3.11 and 3.14 (the floor and ceiling interpreters; ordinary CI covers 3.12
  and 3.13): retained dependency resolution, offline wheel/sdist installs of
  A and B, the installed test suites, and the documented closed-editor
  installer for both candidates.
- **Runtime rows** — the same three operating systems × Godot 4.7.0 × Python
  3.11: one real-editor exact A -> B hot update through the private HTTPS
  origin and the retained package index, with the engine executable checked
  against its reviewed pin.

`complete-qualification` requires every one of those rows to be present,
passed, and bound to the same candidate pair; the runtime row's required case
set is exactly `exact-a-to-b-hot-update`. Failpoint/crash-recovery and storm
matrices are **nightly diagnostics** (`nightly-diagnostics.yml`), not release
gates: they fail visibly and upload their outputs, but promotion does not
read them. The full contract is in the
[verification plan](architecture-simplification-verification-plan.md); the
[PR #949 follow-up](v4-release-review-followup.md) records the development
evidence behind it.

`release-qualification.yml` separates credential-free packaging from protected
signing. A must equal the reviewed `main` workflow commit. B must be its immediate
single-parent child with only the two version edits and the bundled README
deletion. The packager creates required version tags only in disposable local
checkouts; it never pushes B's tag or publishes B. Python regression fixtures
that patch sources remain development evidence, not exact-candidate runtime proof.

After the qualification run's `Require complete release evidence` job is
green, dispatch `release.yml`. Select **patch**, **minor**, or **major**, and
provide the previous published version and the qualification run ID. The
`verify-approval` job checks the run's provenance before downloading anything,
then rebuilds the expected release record from the downloaded candidates and
the complete qualification evidence: signatures, exact file inventories, A as
the reviewed workflow source, A's version as the requested bump of the
previous version, the canonical `qualification.json`, and every mandatory
evidence row. The human approval is the `release-publish` environment's
required reviewer; promotion reads no approval file in another repository.
The workflow then publishes the already-qualified wheel and sdist first, then
creates the tag and GitHub Release from A's already-qualified six assets.
Publishing jobs check out trusted workflow tooling only; they never install,
execute, check out, or rebuild the candidate. Before any artifact download,
each job checks the qualification workflow path, canonical repository,
`workflow_dispatch` event, `main` branch, successful run, and successful
complete job set, and each publishing command recomputes the release record
before its write.

The `v4-publication-receipt` artifact records the promoted identity: version,
tag, source commit, qualification run and attempt, the embedded public-key
SPKI fingerprint, and the size and SHA-256 of every release asset (all six),
distribution (wheel and sdist), and verifier file, plus the public PyPI and
GitHub URLs that were re-downloaded and compared.

Existing public version data is a recovery case, not an automatic success:
PyPI's existing files must match approved metadata **and downloaded bytes**.
Only missing files are uploaded; `skip-existing` is disabled. Before any PyPI
upload, a pre-existing GitHub tag/release must also match the approved source
and asset inventory. A partial matching draft release can resume; mismatches
fail without overwriting tags or clobbering assets. The GitHub job verifies
public PyPI bytes again before publishing and re-downloads all six public
assets afterward. This receipt does not yet replace the required cross-platform
public dependency re-resolution and immutable post-publication attestation.

The old `bump-and-release.yml` remains retired. Version changes are reviewed
source changes: prepare A with the chosen next semantic version and B as its
qualification-only child carrying A's next patch number before dispatching
qualification. This keeps the familiar major/minor/patch release choice
without letting a release button silently mutate a reviewed source tree.

B's patch number is **not** reserved. `4.0.0` qualifies with B `4.0.1`; the
next **patch** publication is `4.0.1` (a fresh reviewed A, qualified with B
`4.0.2`), and **minor** and **major** choices advance to `4.1.0` and `5.0.0`.
B validation rejects a different minor/major or a non-adjacent patch, so an
operator cannot accidentally label B with an unrelated release number.

Accepted residual: a signed, test-only build carrying the next patch identity
exists in the qualification run's Actions artifacts (`v4-candidate-b`) for
the retention window. It is byte-equivalent to A except the two version
fields and the removed bundled README, it is never published to PyPI or
GitHub Releases, and the plugin's updater consumes only GitHub Releases, so
no installation can discover or select it. When that patch number is later
published, the published bytes are a fresh reviewed A, not the retained B.

`verify-signing.yml` is safe to dispatch separately: it exercises the protected
`release-signing` environment against a synthetic payload and publishes
nothing. A green signing check proves only that the stored private key matches
the embedded public key; it is not release qualification.

### Operator setup before candidate signing

Inspect the live repository configuration; an environment name in YAML does
not establish that it is protected. The release operator must:

1. Configure `release-signing` with a designated required reviewer and an
   explicit allowed release-source branch/tag policy. Resolve who dispatches
   and who approves before enabling prevention of self-review.
2. Confirm the **existing** `RELEASE_SIGNING_KEY_PEM` is an environment secret
   and run the synthetic signing check against the embedded key. Do not rotate
   the key: released v3 updaters already trust its public half. Do not place
   private-key material in chat, logs, source, or build artifacts.
3. Confirm no repository-scoped signing-key fallback exists: jobs must not be
   able to obtain the key without the environment approval gate.
4. Protect `release-publish` with the designated required reviewer, no admin
   bypass, and an explicit `main`-only branch policy. Both publishing jobs use
   it. PyPI's trusted publisher must be owner `hi-godot`, repository `godot-ai`,
   workflow `release.yml`, environment **`release-publish`**. Remove any older
   matching publisher whose environment is `(Any)`; otherwise it still grants
   the broader publishing authority.

See GitHub's [environment protection model](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
The synthetic signing check publishes no release. Its approval does not approve
candidate hashes or waive qualification. The environment-copy check must not be
mistaken for proof that the repository-scoped fallback has been removed; inspect
both secret-name lists after the change.

The one-time repository-to-environment transfer completed on 2026-09-01;
the protected copy passed a fresh signing check before the repository fallback
was removed. The temporary token secret and transfer code have been removed.
The operator must also revoke the temporary token at its issuer; deleting an
Actions secret does not revoke the credential. See the
[setup checkpoint](v4-pr-head-checkpoint.md#signing-and-attestation-setup--owner-approved-boundary)
for run links and the revocation status. No bootstrap operation approves a release.

### Trust roots and the retired attestation channel

The owner approved [dsarno/godot-ai-release-attestations](https://github.com/dsarno/godot-ai-release-attestations)
on 2026-09-01 as a separately permissioned approval channel; its
[bootstrap record](https://github.com/dsarno/godot-ai-release-attestations/blob/c39ec40245e83aa2143a0e4361a97eee48407563/README.md)
names `dsarno`, the existing SPKI fingerprint, and the boundary. That
repository is **no longer a promotion dependency** and promotion never reads
it. The required reviewer on `release-publish` is the approval, and the
public-key fingerprint plus the six release-asset hashes are recorded in the
publication receipt artifact.

This is one human approval checkpoint, not independent administration.
Compromise of `dsarno`, GitHub, or the signing key remains outside this
guarantee; the signing key and the same GitHub owner account are the trust
roots.

The `release-signing` environment requires approval by `dsarno`, permits only
`main`, and disallows admin bypass. The obsolete
`v4/architecture-simplification` branch policy was removed on 2026-09-02 after
that branch merged; no signing key was changed. Self-review remains allowed
because dispatch and approval may both use
`dsarno`; this is one human approval checkpoint, not a two-person rule.

On 2026-09-02, `release-publish` was configured with reviewer `dsarno`, a
`main`-only policy, and no admin bypass (self-review allowed). PyPI was visually
verified to have exactly the environment-bound publisher above after the owner
removed the old `(Any)` entry. These are setup checks, not a successful publish
or approval of candidate bytes. Recheck the live settings before publication.

## Exact release asset set

Every stable release exposes exactly six same-version assets. The canonical v4
triple is:

- `godot-ai-v4-plugin.zip` — canonical `addons/godot_ai/**` tree;
- `godot-ai-v4-plugin.manifest.json` — canonical identity, archive metadata,
  and complete file inventory;
- `godot-ai-v4-plugin.manifest.sig` — 512-byte detached RSA signature over the
  exact manifest bytes.

The v3 migration triple is:

- `godot-ai-plugin.zip` — deterministic temporary bridge with the canonical
  triple embedded beneath `addons/godot_ai/migration_payload/`;
- `godot-ai-plugin.zip.sha256` — checksum in the exact format consumed by the
  signed v3 updater; and
- `godot-ai-plugin.zip.sha256.sig` — 512-byte RSA signature over that checksum.

The legacy-named ZIP is a migration capsule, not an alias for the canonical v4
archive and not a final install tree. The manifest binds repository, channel,
tag, semantic version, source commit, canonical ZIP hash and size, and every
canonical file hash. Both ZIPs are deterministic.

## Build, sign, and verify candidate bytes

`script/v4-release` is the source-of-truth CLI. Package unsigned deterministic
bytes first:

```bash
python3 script/v4-release package \
  --repo-root . \
  --output-dir /absolute/path/to/candidate \
  --channel stable \
  --tag v4.0.0 \
  --version 4.0.0 \
  --source-commit <40-hex-source-commit>
```

Sign that prebuilt manifest in the protected signing environment; do not pass
private-key material through logs or commit it to the repository:

```bash
python3 script/v4-release sign \
  --manifest /absolute/path/to/candidate/godot-ai-v4-plugin.manifest.json \
  --signature /absolute/path/to/candidate/godot-ai-v4-plugin.manifest.sig \
  --private-key /secure/path/release-private-key.pem \
  --expected-repository hi-godot/godot-ai \
  --expected-channel stable \
  --expected-tag v4.0.0 \
  --expected-version 4.0.0 \
  --expected-source <40-hex-source-commit>
```

`build` produces and verifies the complete six-asset release set, including the
signed migration capsule. It is not permission to rebuild a qualified public
candidate. `package` and `sign` remain lower-level canonical-triple primitives.
Verify the canonical tree in any candidate with:

```bash
python3 script/v4-release verify \
  --archive /absolute/path/to/candidate/godot-ai-v4-plugin.zip \
  --manifest /absolute/path/to/candidate/godot-ai-v4-plugin.manifest.json \
  --signature /absolute/path/to/candidate/godot-ai-v4-plugin.manifest.sig \
  --expected-repository hi-godot/godot-ai \
  --expected-channel stable \
  --expected-tag v4.0.0 \
  --expected-version 4.0.0 \
  --expected-source <40-hex-source-commit>
```

The standalone migration verifier is exactly `script/v4-release` plus
`src/godot_ai/release_verify.py` from the named source commit. GitHub release
notes are mutable and must not be treated as a trust anchor. The required
reviewer on `release-publish` is the approval, and the publication receipt
artifact records the embedded public-key SPKI fingerprint plus the six
release-asset hashes alongside the wheel, sdist, and verifier-file digests of
the promoted source commit. The two verifier files and repository
documentation are not their own trust anchor.

## V3-to-v4 bridge transaction

The last signed v3 line discovers the legacy-named triple and performs its
existing outer signature/checksum verification. Its updater overlays the
temporary bridge only long enough to load it. The bridge prepares the embedded
canonical triple with the target v4 transaction actor, then disables itself and
uses the same exact-tree activation protocol described below. After the swap,
the bridge persists the v4 plugin in the next-start enabled list without
enabling its scripts in the old process, then Godot performs one graceful
automatic editor restart. Failure to save that intent refuses restart and
requires explicit recovery. The new process proves the prior editor closed
and transfers the inherited nonce-bound lease before claiming the transaction.
A temporarily unverifiable predecessor is retried within the existing bounded
wait, never treated as permission to transfer; persistent uncertainty refuses
startup and leaves the predecessor lease intact. This clean process boundary
prevents loaded v3 `class_name` resources from contaminating v4 startup. The
complete mixed temporary tree is retained as the old backup; only the verified
canonical tree becomes live.

The bridge begins automatically after the user's single **Update** click. V4
startup treats a pre-v4 `from_version` as a major migration, broadly replacing
owned mismatched client entries before durable completion and managed-server
startup. It does not wait for an unverifiable global client-restart
confirmation. Unsupported old updater generations are not carried forward as
permanent v4 runtime branches.

Bridge failure status is scoped to the canonical project path, so failure in
one project cannot block migration in another.

## V4 self-update transaction

The dock considers only a newer `v4.*` GitHub release with the exact six-name,
bounded release set above, but downloads only the canonical three. An Update
click runs this sequence:

1. Preflight refuses an unresolved transaction, retained backup that still
   needs archival, unsafe recovery namespace, active transaction lock, or a
   second live editor lease before download or quiescence.
2. The actor allocates a random owner-private download directory under the
   external recovery root. The manager downloads only the three trusted HTTPS
   release-asset URLs into that exact directory, enforcing release-declared
   sizes and exact filenames. Successful preparation or cancellation removes
   the bounded files; a later exclusive preflight safely collects a stale
   interrupted directory.
3. The Python transaction actor verifies the signature and complete inventory,
   extracts a fresh stage, and publishes `prepared.json`. Its expected stage
   identity comes from the signed manifest—not from a later re-hash of mutable
   stage contents.
4. The root quiesces plugin-owned work and asks the value-only coordinator to
   disable the plugin. The coordinator owns no live files or plugin/Dock
   reference.
5. The actor reconstructs the prepared intent, proves the stage still equals
   the signed inventory, acquires the activation lock, renames the complete
   live tree to a retained backup, and renames the complete stage into place.
   It never overlays files.
6. The coordinator hands the exact initiating actor command across the swap in
   a bounded environment envelope. After Godot scans and enables the new tree,
   the new plugin's bounded startup barrier uses that old actor—never a newly
   resolved/downloaded package—to publish readiness and claim the result before
   ordinary lifecycle, transport, updater, or client work begins. Interactive
   editors run this barrier on one joined worker so a cold, offline, or wedged
   actor cannot freeze the editor UI; export/import launches run it
   synchronously with the same fixed deadline before registering the export
   filter.
7. A successful claim remains the durable client-migration obligation. The
   root repins configured clients, then asks the exact actor that cleared this
   startup barrier to publish an
   immutable `migration-complete.json` bound to the claim, intent, signed live
   tree, and current editor lease. Normal server/client/update startup is
   released only after that acknowledgement. A crash before it causes the next
   ordinary startup to rediscover the claim and repeat the migration barrier;
   a crash after publication does not repeat completed work. External clients
   reconnect to the stable endpoint; an individual restart is remediation for
   a stale client, not a release gate that the plugin cannot verify.
8. Failure rolls the complete old tree back when that can be proven safe.
   Ambiguous state becomes `repair_required`; normal startup remains barred
   until the explicit repair actor resolves it.

The prepared, intent, journal, readiness, result→claim, migration-completion,
activation-lock, and editor-lease records live in a private recovery root
outside the project on the same filesystem. Namespace changes are atomic
renames. Records are strict, size-bounded canonical JSON; links, unsafe POSIX
ancestors, wrong ownership/modes, identity drift, stale actors, and unknown
fields fail closed.

V4 transaction records use schema 1. Claimed transaction directories remain
part of startup and preflight evidence: the actor scans and validates that
retained history before deciding that no repair or M6 obligation remains. There
is no automatic history compaction. Do not hand-edit or delete record JSON to
bypass a refusal. A future record-schema change must first ship an explicit
bounded migration/compaction policy for retained v4 history.

Only the initiating editor lineage may cross an active activation lock. An
editor already open holds a lease and blocks preflight; an editor opened after
lock acquisition refuses before composition and disables the plugin. Re-enable
it or restart after the transaction so Godot loads the terminal tree afresh.
V4 never lets an old in-memory script continue as a read-only "observer" of a
newly renamed tree.

### Recovering a stranded client mutation lock

Automatic Configure/Remove writes and M6 repins share one account-wide durable
lock at `OS.get_config_dir()/godot-ai/client_mutation.lock` (the error prints
the exact platform path). Each claim covers the mutation and its readback. If a
timed-out CLI mutation cannot prove that its process tree stopped, the lock
survives plugin reload, editor restart, and crashes, and later client mutation
or M6 startup fails closed.

Stop the relevant MCP client processes—or reboot—then explicitly remove the
**entire exact lock directory printed in the error** before retrying. Restarting
Godot alone is insufficient, and deleting only `owner.json` deliberately leaves
the deny marker in place. This recovery concerns global client configuration;
it does not authorize editing update-transaction records or rolling back the
live add-on.

### Retained backup and the next update

A successful update keeps one retained backup. Godot AI never silently deletes
it. After validating and externally backing up the new version, close every
editor for the project and archive it explicitly. Use the exact
`recovery_root` printed by `prepare`/`root`—not its parent directory:

```bash
python -m godot_ai.update_transaction archive-backup \
  --project /absolute/path/to/project \
  --install /absolute/path/to/project/addons/godot_ai \
  --recovery-root /absolute/path/to/recovery-base/INSTALL-ID \
  --editors-closed
```

The actor refuses archival if it finds a live or unverifiable editor lease or
an activation lock. On success it atomically moves the retained tree into
hash-named immutable history, allowing the next update while preserving
recovery evidence.

The CLI deliberately distinguishes the two meanings. `--recovery-root` is an
exact, already-derived install root and is required by `activate`,
`abort-prepared`, `repair`, and `archive-backup`. `--recovery-base` is the
optional parent used by `root`, `prepare`, `startup`, and `lease`; those
commands append the deterministic install ID themselves. Passing an exact
root as a base would derive a different path and is refused rather than
guessing operator intent.

### Recovering an abandoned prepared update

If an editor dies after `prepare` (or after publishing an abort intent) but
before activation, first make sure that editor process is gone. Use the exact
project, install, recovery-root, and transaction values printed for the failed
update, and invoke the actor from the same exact installed environment:

```bash
python -m godot_ai.update_transaction abort-prepared \
  --project /absolute/path/to/project \
  --install /absolute/path/to/project/addons/godot_ai \
  --recovery-root /absolute/path/to/recovery-base/INSTALL-ID \
  --transaction TRANSACTION-ID \
  --dead-owner-takeover
```

For an `uvx` installation, use the same isolated/no-config/no-build,
official-PyPI resolver options rendered by the plugin, followed by
`--from godot-ai==LIVE_VERSION godot-ai-update-transaction`; substitute the
exact version in the still-live add-on's `plugin.cfg`. Do not let an alternate
index from local uv configuration choose a repair actor. The takeover refuses
while the prepared editor, another abort requester, or a prior repairer remains
live or unverifiable. It also refuses after activation begins or if any bound
identity/hash has changed. On success it deletes only the authenticated staged
candidate, publishes durable cleanup, and leaves the live add-on untouched.
Do not use this command as a general rollback tool; post-activation ambiguity
belongs to the separate `repair` command.

## Required self-update smoke

Any change to release identity/layout, verification, update discovery,
transaction records, lease/startup barriers, plugin disable/enable, client
repinning, or recovery must run:

```bash
python script/local-self-update-smoke
```

The harness builds a disposable signed v4-to-v4 fixture from the current tree and
launches a real editor. The operator clicks **Update** in the dock. Passing
requires exact version/tree advancement, a healthy authenticated backend after
reload, no parse/load error in the disable→enable window, no new macOS Godot
crash report, no activation artifact inside the project, and a retained
recoverable backup. This interactive check is release-blocking and supplements,
rather than replaces, the automated failpoint, rollback, multi-editor, exact
release-shape, bridge-migration, and clean-install suites. Historical pre-v4
behavior remains recorded in
[pre-v4-updater-one-time-evidence.md](verification/pre-v4-updater-one-time-evidence.md),
but the signed final-v3→v4 bridge path is a recurring release-blocking smoke.
