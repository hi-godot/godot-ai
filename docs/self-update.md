# Self-update

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.

How the plugin updates itself, what that path defends against, and what it
deliberately does not. This replaces the transaction-actor design: there is no
separate update process, no journal, no repair mode, no editor leases, and no
hot reload. An update is verify, stage, swap, restart, then verify again.

## Goals

- A release asset that was not produced by the release pipeline can never be
  installed, even if GitHub release assets or notes were replaced.
- The live add-on is never a mix of two versions: it is the old tree or the new
  tree, and the old tree is retained until the next successful update.
- No editor start depends on any external process. `uvx` runs the server, not
  the plugin.
- The whole path is two small GDScript files, a verifier and an installer, a
  maintainer can read in a sitting.

## Trust and delivery

- Trust root: the RSA-4096 public key embedded in `update_manager.gd`
  (`RELEASE_SIGNING_PUBLIC_KEY_PEM`), fingerprint published in the README. The
  private key exists only in the `release-signing` GitHub environment.
- Delivery: GitHub Releases over TLS. The release API is trusted only to list
  assets and their sizes; every byte it delivers is verified before use.
- A stable release publishes exactly six assets: the canonical v4 triple
  (`godot-ai-v4-plugin.zip`, `.manifest.json`, `.manifest.sig`) and the
  v3-compatible capsule triple (`godot-ai-plugin.zip`, `.sha256`, `.sha256.sig`).
  The manifest is canonical JSON binding repository, channel, tag, version,
  source commit, archive size and SHA-256, and every path, size and SHA-256 in
  the expanded tree. See [packaging-distribution.md](packaging-distribution.md).

## The update path (`utils/update_installer.gd`)

All steps run inside the editor, on the main thread except the download.

1. **Check.** The dock polls the releases API; a candidate is a newer `4.x`
   release exposing the six-name asset set. Dev checkouts skip this.
2. **Download** the three canonical assets into
   `user://godot_ai_update/download/`, enforcing the release-declared sizes and
   trusted asset URLs exactly as today.
3. **Verify** (`McpReleaseVerifier`, pure, unit-testable):
   - the manifest parses as canonical JSON with `schema_version` 1 and the
     fixed key set; the signature verifies over the manifest bytes with the
     embedded key (`Crypto.verify`, SHA-256, PKCS#1 v1.5, the same primitive
     the v3 sidecar check used);
   - identity: `repository` is `hi-godot/godot-ai`, `channel` is `stable`,
     `version` equals the tag and is newer than the running plugin;
   - the archive's size and SHA-256 equal `manifest.asset`;
   - the archive's entries are exactly the inventory paths, all under
     `addons/godot_ai/`, with no absolute paths, `..`, duplicates, case
     collisions, reserved names, directory entries or links, within the file
     count and size bounds; every entry's size and SHA-256 equal its inventory
     row.
   Any failure discards the download and surfaces the reason in the dock.
4. **Stage.** Extract into `res://addons/.godot_ai_update/stage/addons/godot_ai/`
   and re-hash the extracted files against the inventory. The dot-prefixed
   directory is ignored by Godot's filesystem scanner and carries a
   `.gdignore` and a `.gitignore`. It lives beside the live tree on purpose:
   an atomic rename requires the same filesystem, and a project on one drive
   with user data on another must still swap atomically.
5. **Quiesce.** Wait, bounded, until the dispatcher has no in-flight request,
   then run the existing `prepare_for_update_reload()` server preparation.
6. **Lock.** `res://addons/.godot_ai_update/lock.json` holds the editor's PID
   and process fingerprint. A lock held by a live process that is not this
   editor refuses the update; a lock from a dead process is replaced. The lock
   covers download, stage and swap only: once the marker records the swap it
   is released, and the marker itself refuses a second update until the
   restarted editor has verified the tree.
7. **Swap.** Rename the live tree to `.godot_ai_update/backup/<old version>/`,
   then rename the stage into place. Two renames, no file-by-file overlay.
   Write `.godot_ai_update/pending.json`: from and to versions, the manifest
   SHA-256, the expected tree hash, the backup path, and the editor nonce.
8. **Restart.** Persist the add-on in `editor_plugins/enabled` without enabling
   it in the old process, then `EditorInterface.restart_editor(true)`. Updates
   are interactive-only; headless and export launches never update. The one
   exception is the `GODOT_AI_ALLOW_HEADLESS` override the plugin and the
   capsule both honour, which exists so CI can drive these paths in a
   headless editor and is never set for a real install.
9. **Verify again, in the new process.** On start, if `pending.json` exists,
   hash the live tree and compare it to the expected tree hash:
   - equal: delete the marker's pending state, record success in the marker
     (`status: success`, `from_version`, `to_version`, which the existing
     stale-server recovery arm and the pin-only auto-repin gate already read),
     repin owned client configuration once and record `clients_migrated` in
     the marker, emit the `self_update` telemetry event, and continue normal
     startup. A success marker that records its migration is the durable
     record of the last update and is nothing pending on later starts;
   - different: rename the live tree to `.godot_ai_update/quarantine/`, rename
     the backup back into place, mark `status: rolled_back` with the reason,
     and show it in the dock. If the backup is missing too, mark
     `status: repair_required`, keep the plugin inactive, and show the exact
     paths. Nothing is deleted automatically in either case.
10. **Retain.** One successful update replaces the previous retained backup.
    Backups are never deleted on a failure path.
11. **Attached AI clients.** A client attached through `godot-ai attach`
    during the update loses server A at the swap. Its bridge then does what
    it always does without a backend: it spawns one, of the old version,
    into the restart window. The restarted editor replaces a godot-ai server
    at exactly the version it just updated from without asking; any other
    conflict keeps the dock's explicit Restart Server authority. Every
    replacement launches our server before killing the occupant; that server
    waits for the port to free, binds and listens the instant it does, and
    hands that very socket to its HTTP and WebSocket servers, so the port is
    never free between the old backend's death and ours listening: a bridge
    polling for a free port to spawn again never sees one. The
    old bridge itself refuses the new backend as incompatible, so the dock
    tells the user to restart AI clients that were connected during the
    update; the repinned client configuration launches the new version.

## The v3-to-v4 capsule

Final v3 installs update through their own signed-sidecar runner, which
extracts a zip over the add-on and re-enables it. The capsule is that zip: a
small bridge plugin plus the embedded canonical triple. The bridge runs steps 3
to 8 with the same installer script shipped inside it, keeps the two fixes the
crossing needed (removing v3's `game_helper` autoload before the swap, #946,
and persisting the next-start enabled entry without loading v4 in the old
process, #957), and restarts. The v4 plugin then runs step 9 as on any update.

## Closed-editor installer

`script/v4-release install` performs the same verify, stage, swap sequence from
outside a running editor, for release qualification and for recovery. It uses
the `cryptography` package for signature verification and is a development
dependency only; the server package imports nothing from it at runtime.

## What this defends against

- Replaced or tampered release assets, manifests, signatures or notes by anyone
  without the signing key.
- Malformed archives: traversal, absolute paths, links, duplicate or
  case-colliding paths, oversized trees, extra or missing files.
- A mixed-version live tree, from any interruption before the swap (nothing
  was touched) or after it (the new-process verification restores the backup).
- Stale in-memory scripts after a swap (every update restarts the editor).
- A second editor on the same project starting an update concurrently (the
  lock).
- A project whose client configs were configured elsewhere (the existing
  pin-only repin gate; unchanged).

## What this does not defend against

- Compromise of the signing key, the signing environment, the repository, or
  GitHub itself.
- Power or storage loss in the instant between the two renames. The backup
  and the marker make that a visible, recoverable state, not a silent one, and
  that is the whole guarantee.
- Malicious code already running as the same user, or an administrator.
- Two editors on the same project racing past the lock's process check.
- The restart landing in a different Godot. On macOS the editor relaunches
  through LaunchServices by bundle, and with several Godot copies installed
  that has been seen to start another copy once under test. The marker then
  stays `swapped`, an unsupported Godot says so instead of refusing blindly,
  and the next start in the original Godot completes the update.

## Testing

- `test_project/tests/test_update_installer.gd`: the verifier and installer as
  pure functions with a fixture key pair injected: signature, identity,
  archive and inventory rejections, stage hashing, marker states, rollback and
  repair decisions.
- Four real-editor scenarios in `tests/integration/test_self_update_upgrade_paths.py`:
  a signed v4-to-v4 update restarts into a working server; a final-v3 install
  crosses the capsule; a tampered live tree after a swap is rolled back; the
  closed-editor installer's first start completes client migration. The
  capsule crossing is parametrized over the v3 versions the installed fleet
  runs; a pull request proves the two newest and the nightly run proves all
  of them. With the
  capsule coordinator's restart handoff in
  `tests/integration/test_migration_bridge_failures.py`, they run on Linux on
  every pull request and on all three desktop OSes nightly, and the release
  pipeline's A-to-B row runs the signed update on the exact signed candidate
  on every OS before publication.
- Interactive pass: `script/local-self-update-smoke` prepares a signed
  A-to-B project with a one-run key and opens it in a real editor. Click
  Update in the dock; the harness waits for the editor the swap restarts
  into, checks the marker, backup, live server and crash reports, and leaves
  that editor open for inspection. `--from-v3-tag v3.2.4` does the same for
  the crossing: it installs that exact final-v3 tree with a locally built
  capsule, and you click Update in the v3 dock.
