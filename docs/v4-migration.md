# Migrating from Godot AI v3 to v4

Godot AI v4 is a breaking release and requires Godot 4.7 or newer within the
4.x line. The normal migration is one click:

1. Back up or commit the project as you normally would before a major update.
2. Make sure `uvx` is installed and available on `PATH`.
3. Open the project in Godot 4.7+, then click **Update** once in the Godot AI
   dock.

Leave Godot open while the migration finishes; Godot will restart itself once
to discard v3's loaded script classes and open the authenticated v4 tree in a
clean process. For supported clients, you do not need to download release files,
run a verifier, stop the server, edit client configuration, press a second
confirmation button, or restart Godot yourself. Godot AI prepares and authenticates v4, replaces the
complete add-on tree, updates owned client entries, and restarts the matching
managed server automatically.

Cherry Studio is not supported in v4; remove its stale v3 entry in Cherry
Studio itself. Godot AI cannot safely edit that application's internal database.

The public v4 release is not available yet: publication remains fail-closed
until the cross-platform qualification run is complete and the maintainer
approves promotion. The steps above describe the supported flow once
publication opens. Do not install an unpublished candidate into a real project.

## What the Update click does

The stable release has six exact assets:

- the canonical v4 archive, manifest, and manifest signature; and
- a legacy-named migration capsule, checksum, and checksum signature consumed
  by the v3 updater.

The capsule is not a second v4 distribution and is never the final
installation. It is a small, temporary bridge plugin with the three canonical
v4 assets embedded. v3's own signed updater authenticates the capsule and
extracts it over the add-on, as it would any v3 release. The bridge then runs
the v4 installer that ships inside it, entirely within the editor
([self-update.md](self-update.md)):

1. verifies the embedded manifest signature, release identity, archive hash,
   and every file in the inventory;
2. stages the verified tree under `addons/.godot_ai_update/stage/` and
   re-hashes it;
3. removes v3's `game_helper` autoload, renames the complete pre-update
   add-on — bridge included — to `addons/.godot_ai_update/backup/<old version>/`,
   and renames the staged v4 tree into place: two renames, never a
   file-by-file overlay;
4. persists the v4 plugin in `editor_plugins/enabled` without loading it in
   the old process, and restarts Godot.

On that first v4 start the plugin hashes the live tree against the signed
inventory before anything else runs. When it matches, it records `success` in
the marker, repins the owned client entries (the same pin-only repin every
update uses; other drift is reported for **Configure all** in the dock), and
starts the matching managed server. No separate process or package download
is part of the update itself; `uvx` runs the server.

An individual AI client may still need to be reopened if that application
does not notice its configuration change, but restarting every client is not a
migration step or a server-start gate.

## Supported boundary

The supported path is the final signed v3 line to v4 on Godot 4.7+. V4 does not
carry permanent v3 runtime branches. Very old, unsigned updater generations
are outside the automatic migration security boundary; update them to the
latest v3 release first or ask for recovery help.

Godot 4.5 and 4.6 can load the temporary bridge only far enough to explain the
requirement. They do not activate v4. Upgrade Godot, reopen the project, and
click **Retry migration**.

Cherry Studio is not registered in v4 because its MCP entries live in an
internal database with no verified read/write interface. Remove a stale v3
Cherry Studio entry in Cherry Studio itself. Other supported, owned client
entries are migrated automatically.

## If the migration is interrupted

Reopen the same project in Godot 4.7+. The marker at
`addons/.godot_ai_update/pending.json` and the trees beside it determine what
happens next. Nothing is deleted automatically, and nothing needs to be deleted
to make progress; do not remove `addons/.godot_ai_update/` or the add-on tree
by hand while an outcome is unresolved.

An interruption before the swap — during download, verification, or staging —
touches nothing under `addons/godot_ai/`; start the update again from the
dock. After the swap, the outcome is one of the three marker states:

- **`success`** — the live tree matched the signed inventory. The previous
  add-on stays in `addons/.godot_ai_update/backup/<old version>/` until the
  next successful update replaces it.
- **`rolled_back`** — the live tree did not match. It was moved to
  `addons/.godot_ai_update/quarantine/` and the backup was renamed back into
  place, so the editor is running the previous version; the dock shows the
  reason.
- **`repair_required`** — the live tree did not match and no backup was
  available. The plugin stays inactive and the dock prints the exact paths.
  Close Godot, preserve the project and the full error, and either restore
  `addons/godot_ai/` from version control or use the closed-editor installer
  below.

If v4 is installed but one client is stale, reopen only that client. The
server does not wait for a global client-restart confirmation.

Release engineering retains a closed-editor `script/v4-release install`
interface that performs the same verify, stage, swap sequence from outside a
running editor, for qualification and for recovery. It is not the normal user
migration path and should not be copied into end-user instructions.

## Security boundary

The bridge preserves the existing RSA trust anchor across the major update.
The outer v3 signature prevents an altered capsule from executing; the inner
v4 signature binds repository, channel, tag, version, source commit, canonical
archive hash, and complete file inventory, and is checked inside the editor by
the same installer every v4 update uses. The private key exists only in the
`release-signing` GitHub environment; its public half is embedded in the
plugin.

This does not defend against:

- compromise of the signing key, the signing environment, the repository, or
  GitHub itself;
- power or storage loss in the instant between the two renames — the backup
  and the marker make that a visible, recoverable state, not a silent one, and
  that is the whole guarantee;
- malicious code already running as the same user, or an administrator; or
- two editors on the same project racing past the lock's process check.

GitHub release notes are mutable and are not a trust anchor. The required
reviewer on the `release-publish` environment is the approval, and the
public-key fingerprint plus the six release-asset hashes are recorded in the
publication receipt artifact. The signing key and the same GitHub owner account
are the trust roots. Public migration remains closed until the exact promoted
bytes have passed qualification and that review.
