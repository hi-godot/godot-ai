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

The capsule is not a second v4 distribution and is never overlaid as the final
installation. It is a small, temporary bridge containing the three canonical
v4 assets. The signed v3 updater authenticates the capsule. The bridge then
uses the v4 transaction actor to authenticate the inner manifest and every v4
file, stage a fresh tree, and atomically replace `addons/godot_ai`.

The entire pre-update add-on—including any old-only files—is renamed to a
private recovery location outside the project. V3 and v4 files are never
merged in the committed installation. If activation fails cleanly, the actor
restores the prior tree. Ambiguous state fails closed instead of starting a
possibly mixed plugin.

After the exact-tree swap, Godot AI gracefully restarts the editor. The new
process inherits only the bounded transaction handoff, proves the prior editor
closed, transfers its nonce-bound lease, and starts v4 without any cached v3
GDScript classes. On that first v4 start, Godot AI automatically:

- claims the exact successful transaction before normal startup;
- replaces owned pre-v4 client entries with v4 authenticated attach entries;
- records durable migration completion; and
- starts the matching managed server.

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

Reopen the same project in Godot 4.7+. Durable transaction records determine
whether Godot AI should continue v4, restore v3, or remain blocked. Do not
delete `.godot` transaction records, the add-on tree, or a recovery directory
to force progress.

Common outcomes:

- **Install uv / actor unavailable:** install `uv`, reopen Godot, and click
  **Retry migration**. No live-tree swap has occurred.
- **Rolled back safely:** the prior add-on is restored and the bridge offers
  **Retry migration**.
- **Repair required:** close Godot and preserve the full error, project, and
  recovery directory. Do not move or delete either retained tree; use the
  exact paths in the error when requesting support.
- **V4 is installed but a client is stale:** reopen only that client. The
  server does not wait for a global client-restart confirmation.

Release engineering retains a closed-editor `script/v4-release install`
interface for qualification and exceptional recovery. It is not the normal
user migration path and should not be copied into end-user instructions.

## Security boundary

The bridge preserves the existing RSA trust anchor across the major update.
The outer v3 signature prevents an altered capsule from executing; the inner
v4 signature binds repository, channel, tag, version, source commit, canonical
archive hash, and complete file inventory. The exact target
`godot-ai==VERSION` transaction actor is resolved through isolated,
no-config/no-build uv arguments with official PyPI named explicitly.

This still relies on the installed `uv` executable/cache, PyPI/TLS delivery,
and same-user machine integrity. GitHub release notes are mutable and are not
a trust anchor. The required reviewer on the `release-publish` environment is
the approval, and the public-key fingerprint plus the six release-asset hashes
are recorded in the publication receipt artifact. The signing key and the same
GitHub owner account are the trust roots. Public migration remains closed until
the exact promoted bytes have passed qualification and that review.
