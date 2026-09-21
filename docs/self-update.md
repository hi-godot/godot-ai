# Self-update

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.

How the plugin updates itself and what that path defends against. The current
implementation verifies, stages, swaps, verifies again, and activates the new
plugin inside the same editor. A source-free runner survives the replacement;
there is no separate update process or resident helper.

Windows verification covers a native-click HTTPS update and a published 3.2.5
capsule crossing that retain the editor process, unsaved scene state, selection,
and undo history. Both load the exact verified tree and serve authenticated
project-pinned reads afterwards. A separate untouched 4.0.4 fixture verifies its
first update through the legacy restart path. Local test keys and version
substitutions exercise these paths; production release qualification still runs
against the exact signed release artifacts on every supported OS.

An untouched published 4.0.4 installation still uses its already-shipped
restart path for its first update. Installing new files cannot change the old
updater already executing that operation. Updates initiated by the new updater,
and final-v3 updates through the new capsule, retain the editor
process. Restart-based startup recovery remains available for an interrupted
installation.

## Goals

- A release asset that was not produced by the release pipeline can never be
  installed, even if GitHub release assets or notes were replaced.
- The live add-on is never a mix of two versions: it is the old tree or the new
  tree, and the old tree is retained until the next successful update.
- No editor start depends on any external process. `uvx` runs the server, not
  the plugin.
- Preserve the edited scene instance, unsaved changes, selection, and undo/redo
  history. Updating neither autosaves scenes nor restarts the editor.
- Keep activation coordination separate from signature verification and the
  existing installer; the runner carries only its own source and copied values.

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
   release exposing the six-name asset set. Dev checkouts skip this. Clicking
   Update asks for confirmation before installing in this editor. Files being
   installed does not mean the server or AI client connection is ready; the dock
   reports migration and connection work separately. Client refresh requirements
   are described below.
2. **Download** the three canonical assets into
   `user://godot_ai_update/download/`, enforcing the release-declared sizes and
   trusted asset URLs exactly as today.
3. **Verify** (`McpReleaseVerifier`, pure, unit-testable). From here each
   phase names itself in the dock ("Verifying signed update…", "Staging the
   verified tree…", "Waiting for client workers…", "Activating verified
   update…") and yields a frame before its main-thread work, so the dock
   repaints instead of freezing on "Downloading…":
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
   Any failure discards the download, surfaces the reason in the dock, and
   reports the install as over so the plugin releases the click-time lock.
4. **Stage.** Extract into `res://addons/.godot_ai_update/stage/addons/godot_ai/`
   and re-hash the extracted files against the inventory. The dot-prefixed
   directory is ignored by Godot's filesystem scanner and carries a
   `.gdignore` and a `.gitignore`. It lives beside the live tree on purpose:
   an atomic rename requires the same filesystem, and a project on one drive
   with user data on another must still swap atomically.
5. **Quiesce and hand off.** Wait, bounded, until the dispatcher has no
   in-flight request and client workers have stopped, then run
   `prepare_for_update_reload()`. The existing click-time lock at
   `res://addons/.godot_ai_update/lock.json` identifies the editor by PID and
   process fingerprint; another live owner refuses the update. Compile
   `utils/update_activation_runner.gd` into a script without a resource path
   and attach its node outside the plugin. Pass only the staged path and the
   installer's record. The caller returns before the runner disables the old
   plugin and drains deferred work. No suspended plugin callback crosses the
   tree replacement.
6. **Swap.** Request an old-tree filesystem scan and wait for its actual
   `sources_changed` completion callback, bounded by a deadline. A generic
   `filesystem_changed` notification is insufficient. Snapshot cached old script
   references while their complete source tree still exists.
   Rename the live tree to `.godot_ai_update/backup/<old version>/`,
   then rename the stage into place. Two renames, no file-by-file overlay.
   Write `.godot_ai_update/pending.json`: from and to versions, the manifest
   SHA-256, expected tree hash, backup path, and editor nonce.
7. **Verify again, before activation.** The runner calls the existing
   installer's verification against the exact expected tree hash:
   - equal: record success in the marker and proceed to activation;
   - different: quarantine the replacement, restore the backup, and record
     `rolled_back` with the reason;
   - no provable usable tree: retain the evidence, leave the plugin inactive,
     and report the recovery paths. Backups are not deleted on a failure.
   The same verification remains available on the next editor start after an
   interrupted update. The update lock is released before script discovery.
8. **Refresh and enable.** Before another scan or frame yield, move the captured
   old scripts to their actual
   paths under the retained backup using `take_over_path()`. First verify that
   the backup exactly matches the previous live tree and that no existing
   retained generation occupies those paths. Existing undo callbacks keep their
   old compiled code and typed state; canonical paths now load a fresh graph,
   including fresh static variables. This does not reload new source into old
   objects. Release installer/verifier references and request the new-tree scan.
   Its actual `sources_changed` completion callback gates enabling the fresh
   plugin; another scan started by an earlier listener cannot be skipped. Open user scenes/resources that serialize references to add-on
   scripts are refused before replacement, so their next save cannot silently
   point into a backup.
   Enable the plugin, require its loaded version to match, and persist
   `editor_plugins/enabled`. Scan, load, or persistence failures produce an
   explicit activation failure rather than a success banner. The runner records
   the outcome and original editor PID in `.godot_ai_update/activation.json`.
9. **Migrate and reconnect.** The new plugin handles the verified update marker,
   repins provably owned client entries, and records `clients_migrated` before
   releasing normal server startup. Foreign or unprovable entries stay unchanged
   and are reported for explicit Configure. A migration failure is not described
   as a usable connection. The durable success marker is not a pending update on
   subsequent starts. Backend ownership checks and the authenticated connection
   are separate from successful file installation.
10. **Retain.** Backups backing old compiled scripts remain available for the
    lifetime of this editor, including across further in-editor updates. Normal
    pruning resumes on a fresh editor start, when those undo references no
    longer exist. Updates remain interactive-only; headless and export launches do not update.
    `GODOT_AI_ALLOW_HEADLESS` exists only so CI can exercise the real path inside
    an isolated headless editor.

### Attached AI clients and endpoint migration

A same-major update can temporarily lose its backend while the plugin reloads.
Bridges from 4.0.4 onward can follow a compatible replacement of the same major;
this does not promise compatibility for an older process merely because the
plugin has been updated. Existing lifecycle replacement checks still require
exact process identity and ownership authority. An unsigned status response or
an occupied port grants no permission to terminate its owner. Ordinary starts
and post-update probes allow an occupied listener up to three seconds to answer.

A verified pre-v4 to v4 crossing selects a distinct free loopback HTTP/WS pair
before capability paths, launch context, or client migration are fixed. The
atomic `godot_ai/v4_endpoint_ports` override is reused by later updated editors;
legacy port settings remain available to older plugins. Normal v4 updates
without an override keep their existing custom ports. A malformed override
blocks startup with an explicit endpoint retry; it does not silently fall back.

The editor can therefore connect to v4 while an old v3 bridge still holds its
server on the old ports. The migration neither kills that server nor treats its
status as authenticated. The old bridge cannot authenticate to v4: reload the
AI client's MCP configuration and reconnect once. An application relaunch is
needed only when the host cannot reload that configuration. Repinning a global
client entry also redirects it away from other projects still using old
plugins; those projects need their own update or explicit endpoint configuration
to join the new server. See [server-lifecycle.md](server-lifecycle.md#upgrading-from-a-pre-v4-installation).

## The v3-to-v4 capsule

Final v3 installs update through their own signed-sidecar runner, which
extracts a zip over the add-on and re-enables it. The capsule is that zip: a
small bridge plugin plus the embedded canonical triple. The bridge verifies and
stages that triple, removes only v3's matching `game_helper` autoload entry
before the swap (#946), and acquires the existing process-identity lock. Its
coordinator passes copied values to the same source-free activation runner and
returns. The runner then disables the capsule, swaps, verifies, discovers the
new scripts, enables v4, and persists enablement (#957) in the original editor.
The coordinator's own source does not remain on a suspended stack through the
swap. Canonical releases retain signed compatibility files at the former capsule
paths so outstanding parser dependencies can still resolve; these inert shims
are distinct from the capsule payload and its old update runner, which are absent
from the canonical installation.

The capsule also carries the final v3 add-on (`migration_payload/godot-ai-v3-plugin.zip`,
re-packed from the `v3.2.5` tag). Pre-v4 updaters offer whatever release is
latest and cannot know the new release's Godot version floor, and they discard their
per-file backups once the overlay succeeds; on a Godot below the floor the
bridge therefore puts that final v3 back and re-enables it instead of leaving
a dead tree, and the user updates again after upgrading Godot. The fallback
is transitional like the capsule itself: once telemetry shows the fleet on
v4, the capsule triple stops being published and the fallback goes with it.

## Closed-editor installer

`script/v4-release install` performs the same verify, stage, swap sequence from
outside a running editor, for release qualification and for recovery. It uses
the `cryptography` package for signature verification and is a development
dependency only; the server package imports nothing from it at runtime. Into a
project that has no add-on (how release qualification installs candidate A) it
records an empty `from_version` and retains no backup; the first editor start
still repins owned client entries to the installed version before serving.

## What this defends against

- Replaced or tampered release assets, manifests, signatures or notes by anyone
  without the signing key.
- Malformed archives: traversal, absolute paths, links, duplicate or
  case-colliding paths, oversized trees, extra or missing files.
- A mixed-version live tree, from any interruption before the swap (nothing
  was touched) or after it (exact-tree verification can restore the backup).
- Stale in-memory scripts are an explicit activation acceptance boundary:
  relocation separates old and new compiled graphs; real tests execute changed
  dependencies and handlers, not just check a new version label.
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
- On the already-published restart path, landing in a different Godot. On
  macOS the editor relaunches
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
  a current-source signed update must retain the editor process and scene
  state while loading changed code and serving authenticated, project-pinned
  reads/writes; a final-v3 install crosses the capsule in the same editor; a tampered live tree after a swap is rolled back; the
  closed-editor installer's first start completes client migration. The
  capsule crossing is parametrized over the v3 versions the installed fleet
  runs; a pull request proves the two newest and the nightly run proves all
  of them. With the
  capsule coordinator's activation handoff in
  `tests/integration/test_migration_bridge_failures.py`, they run on Linux on
  every pull request (private HTTPS delivery) and on all three desktop OSes
  nightly (also local-file delivery on Linux/macOS), and the release
  pipeline's A-to-B row runs the signed update on the exact signed candidate
  on every OS before publication.
- Interactive pass: `script/local-self-update-smoke` prepares a signed
  A-to-B project with a one-run key and opens it in a real editor. Click
  Update in the dock; the harness checks the expected activation mode (same
  editor for the new updater, restart for an untouched old updater), marker,
  backup, live server and crash reports, and leaves the editor open for inspection. `--from-v3-tag v3.2.4` does the same for
  the crossing: it installs that exact final-v3 tree with a locally built
  capsule, and you click Update in the v3 dock.
  With `GODOT_AI_TEST_GODOT_FLOOR=unmet` in the environment the same
  command exercises the refusal instead: the capsule refuses v4, restores
  final v3 in place, and the harness verifies that restored tree rather than
  waiting for a restart.

## Preparing a two-hop interactive fixture

Prepare both locally signed updates before opening the editor:

```bash
script/local-self-update-smoke --project-dir /tmp/godot-ai-two-hop \
  --from-v3-tag v3.2.5 --target-version 4.0.5 --then-version 4.0.6 \
  --start-published-v3-server --no-launch
```

The first signed v4 tree advertises the second signed package. No installed
add-on files need to change between clicks. The published v3 server startup
remains intact; the v4 backends are frozen local snapshots stamped with the
test versions. Linux requires `lsof` or `ss` before preparation in this mode.

This command prepares a fixture; it does not execute or certify both updates.
Use the printed launch command, which runs an isolated child through a generated
wrapper. A custom driver must use `godot_child_environment(project_dir)` as well.
Use the two native dock update actions,
and check process identity, scene/undo continuity, exact trees, and authenticated
tool responses after each hop. The fixture refuses client configuration writes
when its isolated Codex environment is missing or mismatched. Preserve screenshots
and receipts, then close the editor and clean generated caches as described in
[verification](verification.md).

## Known limits

- **A signed tree can still fail to parse or activate.** Signature and tree
  hashes do not prove Godot compatibility. The independent runner can report
  that activation failed and retain the backup; it does not establish that a
  broken signed release can always roll itself back after a script-load failure.
  Recovery remains manual when required: install a good release with
  `script/v4-release install`, or restore the retained backup under
  `addons/.godot_ai_update/backup/<version>/`.
- **The two-rename swap has crash windows.** A crash between the renames
  leaves no live tree and no new marker; a crash after the second rename but
  before the marker leaves an unverified replacement. Both are seconds wide and
  both leave the backup intact. Durable pre-swap intent is a follow-up.
- **Port handoff is bounded retry, not a guarantee.** The replacement binds as
  soon as the incumbent releases the port, but a third listener can win that
  race. The lifecycle retries replacement a bounded number of times and then
  reports the occupant; the dock's Replace button remains the manual route.
- **Signed qualification-only candidates are signed with the release key.**
  Publication is bound to a qualification run, but the plugin's verifier does
  not distinguish a retained candidate from a published release of the same
  version. Whether to separate those identities cryptographically is an open
  security decision, recorded here rather than decided in a patch.
- **Foreign client entries are reported, not migrated.** A client entry under
  our name that launches something other than Godot AI is left untouched by
  the post-update migration and named in the editor output; replacing it is an
  explicit Configure from the dock.
