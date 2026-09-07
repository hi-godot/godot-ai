# Releasing and self-update

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the
always-loaded rules.

Godot AI v4 has one signed canonical tree and one update path, specified in
[self-update.md](self-update.md). A temporary, signed v3-compatible capsule
carries that same tree across the major-version boundary; it is not a second
v4 runtime shape. See the [v4 migration guide](v4-migration.md) for the
one-click user flow.

## Qualification and publication

V4 may publish only immutable, qualified bytes. `release-qualification.yml`
builds and signs the A/B candidate pair once, then runs the release gate on
those exact bytes:

- **Python rows** — `ubuntu-latest`, `macos-latest`, `windows-latest` × Python
  3.11 and 3.14 (the floor and ceiling interpreters; ordinary CI covers 3.12
  and 3.13): retained dependency resolution, offline installs of A's wheel and
  sdist and of B's wheel (the runtime row updates into it from the retained
  index), A's installed test suite in parallel, and the documented
  closed-editor installer for both candidates. B is A plus two version fields
  minus the bundled README, so testing B's install would only repeat A's
  evidence.
- **Runtime rows** — the same three operating systems × Godot 4.7.0 × Python
  3.11, plus one Linux row at Godot 4.7.2, the newest supported engine: one
  real-editor exact A -> B hot update through the private HTTPS
  origin and the retained package index, with the engine executable checked
  against its reviewed pin. The row launches the editor with explicit headless
  display and audio drivers rather than `--headless`, because Godot forwards
  only the explicit options when the update restarts the editor, and it waits
  for that restarted editor to report the case's result.

`complete-qualification` requires every one of those rows to be present,
passed, and bound to the same candidate pair; the runtime row's required case
set is exactly `exact-a-to-b-hot-update`. The full contract is in the
[verification plan](architecture-simplification-verification-plan.md); the
[PR #949 follow-up](v4-release-review-followup.md) records the development
evidence behind it.

`release-qualification.yml` separates credential-free packaging from protected
signing. A must equal the reviewed `main` workflow commit. B must be its immediate
single-parent child with only the two version edits and the bundled README
deletion; its version is never typed, it is always A's next patch. Make B with

```bash
python -m script.release_support prepare-b --a <A commit> --version-a <A version>
```

which commits that exact child under a fixed identity and date (the same A
always yields the same B), validates it, and prints its SHA. Every job fetches
B by SHA, so push it to a branch on this repository for the run's duration
(`git push origin <B>:refs/heads/qualify/v<A version>-b`) and delete the branch
afterwards; promotion never needs it. The packager creates required version
tags only in disposable local checkouts; it never pushes B's tag or publishes
B. Python regression fixtures that patch sources remain development evidence,
not exact-candidate runtime proof.

The signing and publishing jobs install nothing beyond the interpreter, so the
Python-side signature check runs through the OpenSSL command line there; with
the `cryptography` package present (the dev extra) the same check uses it.

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

## The update path

Every v4 update — the dock's **Update** click and the final-v3 crossing through
the signed capsule alike — is the one flow specified in
[self-update.md](self-update.md): download the canonical triple, verify the
manifest signature, release identity, archive hash and complete inventory,
stage the tree under `res://addons/.godot_ai_update/stage/`, wait for the
dispatcher to drain, take the editor lock, rename the live tree to
`backup/<old version>/` and the stage into place, write the marker, persist
the enabled entry, restart the editor, and re-hash the live tree in the new
process. There is no separate update process; `uvx` runs the server, not the
plugin. The capsule differs only in who starts it: v3's own signed-sidecar
runner extracts the bridge, and the bridge runs the same installer on the
embedded triple ([v4-migration.md](v4-migration.md)).

`script/v4-release install` performs the same verify, stage, swap sequence
from outside a running editor. It exists for release qualification and for
recovery; it is not an end-user path.

## Recovery: the three marker states

Everything the updater writes lives under `addons/.godot_ai_update/` inside the
project, a `.gdignore`d and `.gitignore`d directory beside the live tree:

- `pending.json` — the marker: from and to versions, the manifest SHA-256, the
  expected tree hash, the backup path, the editor nonce, and after the
  post-restart check a `status`;
- `backup/<old version>/` — the complete previous add-on tree;
- `stage/addons/godot_ai/` — the verified candidate before the swap;
- `quarantine/` — a live tree that failed the post-restart check;
- `lock.json` — the updating editor's PID and process fingerprint.

Nothing under it is deleted automatically on a failure path. After the restart
the marker's `status` is one of:

- **`success`** — the live tree hashed equal to the signed inventory. The
  previous tree stays in `backup/<old version>/` until the next successful
  update replaces it. No action is needed.
- **`rolled_back`** — the live tree did not match. It was renamed to
  `quarantine/` and `backup/<old version>/` was renamed back into place, so the
  editor is running the previous version; the dock shows the reason.
  `quarantine/` is kept as evidence — remove it yourself once it is no longer
  needed.
- **`repair_required`** — the live tree did not match and no backup was found
  to restore. The plugin stays inactive and the dock prints the exact paths.
  Close the editor, keep the project directory as it is, and either run
  `script/v4-release install` against the release you were updating to or
  restore `addons/godot_ai/` from version control. Do not delete
  `addons/.godot_ai_update/` while working out what happened.

A `lock.json` held by a live process that is not the current editor refuses an
update; a lock from a dead process is replaced on the next attempt, so a stale
lock needs no manual cleanup.

### Recovering a stranded client mutation lock

Automatic Configure/Remove writes and post-update repins share one
account-wide durable lock at `OS.get_config_dir()/godot-ai/client_mutation.lock`
(the error prints the exact platform path). Each claim covers the mutation and
its readback. If a timed-out CLI mutation cannot prove that its process tree
stopped, the lock survives plugin reload, editor restart, and crashes, and
later client mutation or post-update repin fails closed.

Stop the relevant MCP client processes—or reboot—then explicitly remove the
**entire exact lock directory printed in the error** before retrying. Restarting
Godot alone is insufficient, and deleting only `owner.json` deliberately leaves
the deny marker in place. This recovery concerns global client configuration;
it does not authorize editing the update marker or rolling back the live
add-on.

## Required verification

Any change to release identity or layout, `utils/release_verifier.gd`,
`utils/update_installer.gd`, `update_manager.gd`, the migration bridge, the
enabled-entry persistence, plugin disable/enable, or client repinning must
pass:

- `test_project/tests/test_update_installer.gd` via `test_run` — the verifier
  and installer as pure functions with an injected fixture key pair — and the
  Python verifier/installer unit tests behind `script/v4-release`;
- the three real-editor scenarios in
  `tests/integration/test_self_update_upgrade_paths.py`, run with `GODOT_BIN`
  set: a signed v4-to-v4 update restarts into a working server, a final-v3
  install crosses the capsule, and a tampered live tree after a swap is rolled
  back.

CI runs the three scenarios on Linux on every pull request and on all three
desktop OSes nightly; the release pipeline's A-to-B row runs the first one on
the exact signed candidate on every OS before publication. Historical pre-v4
behavior remains recorded in
[pre-v4-updater-one-time-evidence.md](verification/pre-v4-updater-one-time-evidence.md).
