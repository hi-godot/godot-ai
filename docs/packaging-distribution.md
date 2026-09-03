# Godot AI v4 — Packaging and Distribution

*Updated 2026-09-02*

This document defines the supported v4 install surfaces and artifact shape.
Release operation and self-update details live in [releasing.md](releasing.md);
the user migration procedure lives in [v4-migration.md](v4-migration.md).

## Package identities

- Repository: `hi-godot/godot-ai`
- Python distribution and CLI: `godot-ai`
- Python import package: `godot_ai`
- Godot install root: `addons/godot_ai/`
- Canonical v4 plugin archive: `godot-ai-v4-plugin.zip`
- Signed inventory: `godot-ai-v4-plugin.manifest.json`
- Manifest signature: `godot-ai-v4-plugin.manifest.sig`
- V3 migration capsule: `godot-ai-plugin.zip`
- Capsule checksum/signature: `godot-ai-plugin.zip.sha256` and
  `godot-ai-plugin.zip.sha256.sig`

There is exactly one v4 plugin ZIP shape. It contains only regular files below
`addons/godot_ai/`, in sorted order, with canonical timestamps, modes, and
uncompressed ZIP metadata. The signed manifest binds repository, channel, tag,
version, source commit, archive size/hash, and every path/size/hash in the
expanded tree.

The legacy-named ZIP is intentionally not an alias. It contains a temporary
bridge plus the canonical signed triple. Historical updaters overlay the
bridge, which immediately delegates to the exact-tree v4 actor; the capsule is
never accepted as the committed v4 tree.

## Supported install paths

### Signed GitHub release

This is the v4 plugin distribution surface. A fresh project verifies the
canonical triple and extracts the exact archive into an absent
`addons/godot_ai` path. A project on the final signed v3 line clicks **Update**
once. The signed capsule then moves the complete old tree to external recovery
before renaming the verified canonical v4 tree into place.

Do not publish or document an overlay-copy shortcut.

### Python package through `uvx`

The Dock renders exact-version client commands such as:

```text
uvx --isolated --no-config --no-env-file --no-sources --no-build \
  --index https://pypi.org/simple \
  --default-index https://pypi.org/simple \
  --find-links https://pypi.org/simple/godot-ai/ \
  --index-strategy first-index --keyring-provider disabled \
  --link-mode copy --from godot-ai==4.0.0 godot-ai attach ...
```

The attach bridge starts or adopts the matching local backend, reads its private
capability record, and proxies MCP over stdio. A persistent bare HTTP URL is not
a v4 client configuration because it cannot safely discover or rotate the
bearer capability.

CI builds both wheel and sdist, installs them into clean environments on Linux,
macOS, and Windows, and executes the installed CLI. Publication still requires
the exact-candidate qualification and reviewer-gated promotion in
[releasing.md](releasing.md).

### Development checkout

Contributors run `script/setup-dev`; the plugin prefers the nearby `.venv` and
captures the worktree `src/` path in its immutable lifecycle plan. The linked
`test_project/addons/godot_ai` tree is development-only and is rejected as a
self-update target.

### Marketplace transition

The Godot Asset Store and legacy Asset Library remain on the last v3 listing
during qualification. That final signed v3 line can consume the release
capsule through its existing updater once publication opens. A future v4 store
listing must still preserve the canonical signed tree and must not overlay an
unknown existing add-on as its final state.

### Standalone binary

A standalone server executable remains deferred. It is not a v4 release
artifact until all supported platforms prove startup, authenticated capability
publication, attach, one tool roundtrip, and lifecycle cleanup without Python
installed.

## Verification bootstrap

`script/v4-release` deliberately loads the exact sibling
`src/godot_ai/release_verify.py` by file path. It does not trust an installed
`godot-ai` package. GitHub release notes are mutable and cannot authenticate
assets against a release publisher who can replace those notes. The required
reviewer on `release-publish` is the approval, and the publication receipt
artifact records:

- both verifier file SHA-256 values and their exact source commit;
- the exported RSA SPKI SHA-256 fingerprint;
- all six plugin/migration asset names, sizes, and hashes; and
- the `godot-ai` wheel and sdist names, sizes, hashes, and version.

For every qualification OS/Python row, the complete resolved distribution
inventory (normalized name, version, artifact filename, size, and SHA-256) is
retained in the qualification run's evidence artifact, which promotion
verifies before any publication write.

The behavior-defining runtime packages declared in `pyproject.toml` are exact
pins and are checked again by `godot_ai.runtime_dependencies` before CLI
dispatch. The full per-row distribution inventory also captures less critical
transitive packages; changing any resolved artifact invalidates that row and
requires requalification while candidate/publication evidence is being built,
rather than silently widening the environment that evidence describes.

Every production `uvx` server, attach, prewarm, and transaction-actor command
uses the one resolver policy shown above. Godot-owned spawns also temporarily
clear inherited `UV_*` source/override/interpreter/cache controls under the
global spawn mutex. Only
`GODOT_AI_QUALIFICATION_PYTHON_INDEX=1`, set in the launching process together
with an explicit `UV_INDEX`/`UV_DEFAULT_INDEX`, authorizes the private
qualification index. The switch and any credentials are never written into a
client command, project file, transaction record, log, or telemetry.

This prevents a user/project uv configuration or already-installed uv tool
from silently selecting an alternate `godot-ai` package. It is not wheel-byte
binding. The package/protocol identity response is a compatibility check, not
authentication, and a later public resolution does not compare the selected
wheel or every dependency to the qualification digests. PyPI's index/artifact
integrity and TLS delivery, the selected `uv` executable/cache, and same-user
local-machine integrity are therefore runtime trust roots. A PyPI compromise
capable of serving counterfeit bytes under the exact version remains able to
compromise both the server and transaction actor. Closing that residual needs
a hash-enforced, signed actor/runtime artifact that remains addressable across
the live-tree rename (or a bundled runtime), which is a separate delivery
architecture rather than another self-reported hash. Exact critical pins still
fail before FastMCP import when resolution merely drifts; noncritical
transitive drift remains an accepted packaging risk.

Promotion consults no second repository and no second cryptographic signing
key: the signing key and the same GitHub owner account are the trust roots,
and compromise of that account or GitHub is outside the guarantee.
Exact-candidate qualification and the `release-publish` review remain
required. Publication and public migration remain closed until those gates
pass.

The v4 SPKI fingerprint compiled into both standalone and in-plugin verification
is:

```text
84ebbd811f3a12c09ff4e236bbbbb9310fc23e03fcfc3717ba546747d0d21072
```

The verifier rejects duplicate JSON keys, non-canonical manifests, unexpected
identity fields, unsafe/colliding paths, links, non-canonical ZIP metadata,
oversized files/trees/archives, signature failure, and any exact-tree mismatch.

## CI and qualification tiers

1. Python unit/integration/lint on Python 3.11, 3.12, 3.13, and 3.14 across
   Linux, macOS, and Windows.
2. Godot 4.7 editor tests on Linux, macOS, and Windows; separate Linux-only
   inert-refusal rows on 4.5 and 4.6.
3. Clean wheel/sdist install smoke on all three operating systems.
4. Retained one-time historical boundary evidence: all 104 tags were
   source-classified into 24 behavior classes, with 29 selected runtime rows on
   macOS/Godot 4.7. This is not a recurring candidate or cross-platform tier.
5. Signed plugin packaging, verifier, one-click bridge migration, v4-to-v4
   transactional update, two-editor, reload, and stale-server proof in
   ordinary CI; crash/failpoint-recovery and storm matrices as nightly
   diagnostics (`nightly-diagnostics.yml`) that fail visibly but do not gate
   promotion.
6. Exact private source-A/source-B candidate qualification: package rows on
   Linux, macOS, and Windows at Python 3.11 and 3.14, plus one real-editor
   A -> B hot-update row per OS at Godot 4.7.0 / Python 3.11, bound to
   immutable plugin, Python-package, and resolved-dependency artifact digests.

Tier 6 is the release gate. Promotion cannot accept install smoke as a
substitute for its complete evidence, and hosted rows and publication remain
unqualified until that retained evidence is complete and reviewed.

## Release readiness

- [ ] Source A and the minimal qualification child B are frozen.
- [ ] Both plugin triples, wheel, and sdist are built once and
      their identities, sizes, and digests recorded.
- [ ] Every qualification row records the complete resolved distribution
      artifact set; startup proves the exact behavior-defining dependency pins.
- [ ] The embedded updater key and standalone verifier key are identical; the
      SPKI fingerprint is recorded in the publication receipt.
- [ ] One-click final-v3-to-v4 migration proves both signature layers, an
      external retained backup, graceful editor restart/lease transfer,
      automatic client repin/server start, and the exact signed live tree.
- [ ] V4-to-v4 self-update proves prepare-before-quiesce, signed stage identity,
      install/editor leases, durable journal reduction, rollback/quarantine,
      startup barrier, and repeat-update behavior.
- [x] Retained one-time evidence classifies the historical updater boundary;
      the new signed bridge path is qualified separately against the final v3
      line.
- [ ] All mandatory Windows, macOS, Linux, Godot, and Python rows pass with no
      required skip.
- [ ] The `release-publish` reviewer approves the exact digest set. No source,
      docs, workflow, or artifact is rebuilt after approval.
- [ ] Publication uploads approved Python bytes first, verifies their public
      hashes, then uploads the already-approved plugin bytes.
- [ ] Public redownload attestation proves every released byte and every
      dependency artifact selected by each publication-smoke row equals its
      approved digest.

Packaging, signing, artifact verification, the release qualification matrix,
and protected promotion safeguards are implemented. The external failpoint
surface and storm baselines are nightly diagnostics rather than release
gates; public per-row dependency attestation after publication remains a
follow-up. No final A/B digest set is approved.
See [the release runbook](releasing.md) for the current fail-closed boundary.
