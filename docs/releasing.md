# Releasing and self-update

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the
always-loaded rules.

Godot AI v4 has one signed canonical tree and one exact-tree transaction
protocol. A temporary, signed v3-compatible capsule carries that same tree
across the major-version boundary; it is not a second v4 runtime shape. See the
[v4 migration guide](v4-migration.md) for the one-click user flow.

## Qualification and publication

V4 publishes only immutable, qualified bytes. `release-qualification.yml`
builds and signs the A/B candidates once, retains their SHA-256 inventories,
and verifies those exact artifacts on Linux, macOS, and Windows. It creates no
tag, GitHub Release, or PyPI upload.

After the independent attestation repository commits an approval JSON whose
contents exactly match both candidate `evidence.json` files, dispatch
`release.yml`. Select **patch**, **minor**, or **major**, provide the previous
published version, qualification run ID, and the immutable approval commit and
path. The workflow computes the target version, verifies it matches A, publishes
the already-qualified wheel and sdist first, then creates the tag and GitHub
Release from A's already-qualified six assets. It never checks out or rebuilds
the candidate. A duplicate PyPI version, changed artifact, missing B evidence,
or mismatched approval fails closed.

The approval file is JSON with this exact object shape (the `candidates` value
is copied without changing any generated evidence fields):

```json
{"schema":1,"bump":"minor","previous_version":"4.0.0","candidates":{"a":"A evidence object","b":"B evidence object"}}
```

Keep it in the attestation repository at a full commit SHA; the release
workflow reads neither a branch nor a mutable release note. The attestation
review must confirm the qualification run, sources, signed artifact hashes,
and the separate repository's access boundary before creating that record.

The old `bump-and-release.yml` remains retired. Version changes are reviewed
source changes: prepare A with the chosen next semantic version and B as its
reserved qualification-only child before dispatching qualification. This keeps
the familiar major/minor/patch release choice without letting a release button
silently mutate a reviewed source tree.

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
4. Verify the separately permissioned attestation channel below before freezing
   A. A reviewer on the release repository alone does not establish that boundary.

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

### Attestation channel and approved threat boundary

The owner approved [dsarno/godot-ai-release-attestations](https://github.com/dsarno/godot-ai-release-attestations)
on 2026-09-01. Its [bootstrap record](https://github.com/dsarno/godot-ai-release-attestations/blob/c39ec40245e83aa2143a0e4361a97eee48407563/README.md)
names `dsarno`, the existing SPKI fingerprint, and the boundary; it is **not**
an approval of any candidate. Cite future approval records by full commit SHA.

This is credential/repository separation, not independent administration.
The attestation repo is public, owner-write-only, has Actions disabled and no
deploy keys, and protects its main history from force-push/deletion. Do not
grant godot-ai release workflows a credential that can write there. Recheck
those controls and actual release credential scope at qualification time.
Compromise of `dsarno`, GitHub, the signing key, or the trusted approval process
remains outside this guarantee; GitHub account identity and the known canonical
attestation repository are accepted bootstrap trust roots.

The `release-signing` environment requires approval by `dsarno`, permits only
the `main` and `v4/architecture-simplification` branches, and disallows admin
bypass. Self-review remains allowed because dispatch and approval may both use
`dsarno`; this is one human approval checkpoint, not a two-person rule.

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
notes are mutable and must not be treated as a trust anchor. Before publication,
the separately permissioned channel described above must authenticate the source
commit, both verifier digests, all six asset identities, the embedded public-key
SPKI fingerprint, and its approved attestation identity. The migration guide
names that channel; exact-candidate approval and retained permission checks
remain required before publication. The two verifier files and repository
documentation are not their own trust anchor.

## V3-to-v4 bridge transaction

The last signed v3 line discovers the legacy-named triple and performs its
existing outer signature/checksum verification. Its updater overlays the
temporary bridge only long enough to load it. The bridge prepares the embedded
canonical triple with the target v4 transaction actor, then disables itself and
uses the same exact-tree activation protocol described below. After the swap,
Godot performs one graceful automatic editor restart; the new process proves
the prior editor closed and transfers the inherited nonce-bound lease before
claiming the transaction. This clean process boundary prevents loaded v3
`class_name` resources from contaminating v4 startup. The
complete mixed temporary tree is retained as the old backup; only the verified
canonical tree becomes live.

The bridge begins automatically after the user's single **Update** click. V4
startup treats a pre-v4 `from_version` as a major migration, broadly replacing
owned mismatched client entries before durable completion and managed-server
startup. It does not wait for an unverifiable global client-restart
confirmation. Unsupported old updater generations are not carried forward as
permanent v4 runtime branches.

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
