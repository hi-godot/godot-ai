# Changelog

User-facing changes in Godot AI, newest first. Every GitHub Release links to
this file at the release's exact source commit, and its "What's Changed"
section lists every merged pull request; this file keeps the part worth
reading. Release engineering: [docs/releasing.md](docs/releasing.md).

## 4.1.0 (2026-09-11)

Plugin updates now activate inside the running editor, preserving open scenes,
unsaved changes, selection, and undo history. Updating from published 4.0.4
still restarts the editor once through its existing updater; later updates use
the new in-editor path. Published 3.2.5 can migrate through the new update
capsule without restarting the editor. Older AI clients may still need one
relaunch after migration.
[Compare v4.0.4...v4.1.0](https://github.com/hi-godot/godot-ai/compare/v4.0.4...v4.1.0).

### Fixed

- Fixed a native editor crash when an import runs while the Update confirmation
  is open. Godot's shared progress dialog survives plugin replacement and can
  be reused by the next filesystem scan.
- Updates wait for filesystem scans before replacing and enabling scripts,
  retain scripts needed by existing undo callbacks, and explain why an unsafe
  activation was refused.
- Startup and update recovery stay in a pending state until the server is
  ready. Genuine failures retain their error state and diagnostics.
- Windows process-inspection failures no longer masquerade as an exited
  process. Server ownership checks retain the evidence needed for recovery.
- Migration chooses an independent HTTP/WebSocket port pair. The dock's port
  picker updates the effective pair, including migrated settings, and also
  supports incompatible servers that cannot be reclaimed.
- Backup scans skip linked child directories, and Linux startup explains when
  required listener tools are missing.

### Known issue

- **Configure all** can report a client-configuration lock error when requests
  overlap. Configure clients individually, waiting for each operation to finish,
  and retry an affected client after the active operation completes. Tracked in
  [#1047](https://github.com/hi-godot/godot-ai/issues/1047).

## 4.0.4 (2026-09-09)

Updating with AI clients attached no longer means quitting and relaunching
them: from this version a client's `godot-ai attach` bridge keeps serving a
server of the same major version, and the restarted editor replaces the
server an old bridge left on the port by itself. Clients attached through
4.0.3 or earlier still need one last relaunch after this update. Also the
dock names each activation phase, a held WebSocket port is diagnosed before
launch, `physics_shape_generate` lands, and release qualification updates
with a real attached bridge.
[Compare v4.0.3...v4.0.4](https://github.com/hi-godot/godot-ai/compare/v4.0.3...v4.0.4).

### Added

- `resource_manage(op="physics_shape_generate")`: bulk-generate a
  `StaticBody3D` or `Area3D` sibling with a fitted `CollisionShape3D` (box,
  sphere, capsule or cylinder) for every `MeshInstance3D` path, as one undo
  action. Every path is validated before anything is written, and a deferred
  request re-validates each mesh again when its body is added, so a scene
  edited meanwhile fails the request instead of leaving a partial batch.
  Contributed by @michaltomczykowski in
  [#892](https://github.com/hi-godot/godot-ai/pull/892).

### Fixed

- The restarted editor's replacement of the server an attached bridge left on
  the port no longer loses the port to that bridge. The replacement server
  reports the moment it reaches its port wait and the occupant is killed only
  then, so a launch that spends seconds in uvx installing the new version no
  longer leaves the port free for the bridge to spawn a backend of the old
  version into (the 4.0.4 qualification's Ubuntu rows: three replacement
  attempts, each `HTTP port 8000 is already in use`). A bridge whose backend
  vanishes with the port free now also waits five seconds for a replacement
  to answer before spawning its own.
- The dock no longer looks frozen on "Downloading…" after the download has
  finished: activation now names each phase ("Verifying signed update…",
  "Staging the verified tree…", "Waiting for client workers…", "Activating
  verified update…") and lets the dock repaint before the phase's work runs.
- A server that refused to start now says why in the dock. The launch-failure
  message (`The launched process identity could not be captured…`) appends the
  server's own startup report, which two 4.0.3 reports had on disk unread:
  `WebSocket port 19630 is already in use by another process`.
- Moving the HTTP port alone no longer lands the next launch on a WebSocket
  port the previous server still holds: the lifecycle preflights the WebSocket
  port before launching and names `godot_ai/ws_port`, and the dock's port picker
  moves both ports, keeping whichever one is free.
- `Port N is occupied by another process` now says why a godot-ai record for
  that port did not authenticate the occupant (a probe timeout, a different
  instance, a non-godot-ai listener), so the report is actionable.
- After an update the restarted plugin replaces any older server of its
  major version that an attach bridge left on the port, not only the exact
  version it superseded, and its post-update status probe waits 3 s instead
  of 800 ms so a backend still settling on the port is not reported as
  "held by another process" with nothing replacing it.
- The post-update banner and log line say "AI clients keep working" when the
  clients were attached through 4.0.4 or newer (their bridges follow the new
  server), and keep telling the user to quit and relaunch only for bridges
  that predate it.

### Changed

- The `godot-ai attach` bridge keeps serving a server of the same **major**
  version instead of requiring the exact package version. Updating the plugin
  no longer requires quitting and relaunching every attached AI client: the
  restarted editor's server is one patch or minor ahead of the client's bridge
  pin, the bridge re-validates on every request and follows the new server
  instance. The attach protocol version, ports and excluded domains are still
  gated exactly. Bridges from 4.0.3 and earlier still refuse a newer server,
  so the first update onto this version needs one last relaunch.
- Release qualification's real-editor A-to-B update now runs with a real
  `godot-ai attach` bridge attached through the update, and passes only when
  that same bridge process serves the updated editor afterwards, so the gate
  measures the workflow users actually run.

## 4.0.3 (2026-09-08)

Stabilizes the v4 line on Windows and Linux after the 3.x crossing: the
private capability directory the account could not use, the post-update
client barrier, servers left behind by a client's old 3.x bridge, the
closed-editor recovery installer, the Reload Plugin crash, and the updater's
lock. Quit and relaunch AI clients that were connected during the update.
[Compare v4.0.2...v4.0.3](https://github.com/hi-godot/godot-ai/compare/v4.0.2...v4.0.3).

### Fixed

- `editor_reload_plugin` (and the dock's Reload) gave up after 5 s when the
  editor was still scanning or importing, left the plugin unchanged with only
  an editor-log error, and the calling AI client then waited out the server's
  90 s reconnect budget for a replacement session that never came. The
  reload now waits up to 60 s for its filesystem scan.
- **OpenCode:** Configure wrote only `opencode.json` while OpenCode merges
  it with `opencode.jsonc`, the latter winning per key, so a stale
  `godot-ai` entry in an existing `opencode.jsonc` kept overriding the new
  one. The descriptor now declares that merge order: Configure updates the
  effective last definition, status verifies it, Remove clears both
  ([#1011](https://github.com/hi-godot/godot-ai/issues/1011)).
- A Godot AI 3.x server left on the port by an AI client whose bridge
  attached before the update was reported as "held by another process". The
  lifecycle now performs one untrusted, tokenless status read solely to word
  the block: it names the pre-v4 server, tells the user to quit and relaunch
  that client, and re-probes slowly for about three and a half minutes so
  the editor comes up green once the old server's lease and idle backstop
  run out. The read grants no adoption, replacement or kill authority. The
  dock and the migration guide now say "quit and relaunch" rather than
  "restart": Claude Desktop keeps its MCP configuration in memory and
  respawns the old bridge until the application itself is relaunched.
- After an update, a client entry the migration could not prove as
  "what Configure wrote before the update" (a project `.mcp.json` with a
  v3 `type: http` entry, an unreadable file) blocked the server with
  `<client> has non-version configuration drift; automatic migration
  refused` and a Retry that failed the same way. The entry is still never
  rewritten (#890), but it no longer holds the server: it is left
  unchanged, named in the completion banner with a Configure hint, and
  startup continues. While an update brings the server back the dock now
  reads `Finishing update — starting server…` instead of a red
  `Connection blocked`
  startup continues
- **Closed-editor recovery installer** (`script/v4-release install`, the
  #999 procedure): on Windows it treated every update-lock holder as dead
  when `psutil` was not installed, which the published command never
  installs, so a live editor's lock was replaced instead of refused; the
  check now asks the kernel directly and needs no third-party module. A
  recovery over an existing 4.x tree also records
  `replace_owned_mismatches`, so the plugin's first start may repin every
  owned client entry that launches Godot AI, whatever the live tree's
  version, instead of refusing startup over a leftover v3-shaped entry
  ([#999](https://github.com/hi-godot/godot-ai/issues/999)).
- **Windows:** the server launched to replace an older godot-ai backend gave
  up waiting for the port after 5 s, before the plugin had finished proving
  the new process and killing the old one (each identity probe is a
  PowerShell start), so a post-update replacement could loop on `The launched
  process identity could not be captured`. The replacement now waits 15 s,
  and that message names the process, whether it is still alive, and which
  check refused it on each attempt.
- **Windows:** the server created its private capability directory with
  `mode=0o700`, which CPython turns into a DACL of SYSTEM, Administrators and
  OWNER RIGHTS alone. A directory first created by an elevated process is
  then owned by Administrators, and the user's own unelevated editor, server
  and `godot-ai attach` bridge can never read or write it: the dock showed
  `The managed server proof timed out at capability_record` and the bridge
  reported `PORT_OCCUPIED` for a healthy backend. The directory now inherits
  the per-user `%LOCALAPPDATA%` permissions; the plugin probes it before
  spawning and the bridge checks it before blaming a foreign process, and
  both name the directory and the elevated `Remove-Item` repair when the
  account cannot use it
  ([#988](https://github.com/hi-godot/godot-ai/issues/988)).
- A plugin-spawned server that fails before publishing its capability record
  now writes the failure to a startup report (`--startup-report`, beside the
  pid file) and the dock appends it to the proof failure, so a port in use, an
  unwritable directory or a crashed import is named instead of a bare
  `proof timed out at capability_record`
  ([#1012](https://github.com/hi-godot/godot-ai/issues/1012)).
- `camera_create` / `camera_configure` / `camera_apply_preset` with
  `make_current` on a **Camera2D** could leave the camera not current while
  the response and `camera_get` said it was. Godot's `Camera2D.make_current()`
  dispatches through a scene-tree group call that silently skips a node
  allocated at the address of a node removed and freed earlier in the same
  editor frame, which happens after undo-history trimming, `free()`, or an
  editor panel rebuild. The handler now detects the dropped call and applies
  the same viewport update directly. This was the "engine-state lag" behind
  the long-running camera test flake (#140, #278, #301, #316); the retry and
  sleep loops written for it are gone.
- **Bazzite / Fedora Atomic:** the server exited before publishing its
  capability record because `/home` is a symbolic link to `/var/home` on
  ostree systems and 4.0.x refused every link in a capability path. The server
  now follows a link when it is root-owned and sits in a root-owned directory
  that other accounts cannot write, which is exactly the ostree layout. The
  plugin, which cannot see file ownership, follows a link only below a
  directory closed to group and other writes. Every other link still fails
  closed on both sides, and the record file itself is never followed. The
  `GODOT_AI_CAPABILITY_DIR` workaround is no longer needed there
  ([#993](https://github.com/hi-godot/godot-ai/issues/993), reported again in
  [#989](https://github.com/hi-godot/godot-ai/issues/989)).
- The dock's **Reload Plugin** button no longer crashes the editor
  ([#1000](https://github.com/hi-godot/godot-ai/pull/1000)).
- After an in-session update the dock's Update button is an action again and
  re-arms for a newer release without an editor restart
  ([#1002](https://github.com/hi-godot/godot-ai/pull/1002)).
- A failed download releases the update lock
  ([#1001](https://github.com/hi-godot/godot-ai/pull/1001)).

### Changed

- Documented the supported way to connect an agent that runs in a container,
  in WSL2, or on another machine: the `godot-ai attach` bridge launched on the
  editor machine over SSH, with the Docker Desktop, Docker Engine, and WSL2
  host names ([#1008](https://github.com/hi-godot/godot-ai/issues/1008);
  a first-class remote mode is tracked in
  [#1009](https://github.com/hi-godot/godot-ai/issues/1009)).

## 4.0.2 (2026-09-07)

Fixes the in-editor updater's download. Nothing else changed.
[Compare v4.0.1...v4.0.2](https://github.com/hi-godot/godot-ai/compare/v4.0.1...v4.0.2).

### Fixed

- The dock's **Update** failed with `download failed (302)` on Windows, macOS,
  and Linux. Two independent causes: with `max_redirects = 0`, Godot's
  `HTTPRequest` reports `RESULT_REDIRECT_LIMIT_REACHED` for GitHub's first
  redirect instead of a success carrying a 3xx code, so the manual redirect
  branch was unreachable; and GitHub's release-asset CDN now uses a
  `/github-production-release-asset/<repository id>/...` path that the trusted
  path check rejected. The updater now treats that result as a redirect and
  pins the current CDN namespace to this repository's ID, keeping the
  destination validation and redirect limit
  ([#997](https://github.com/hi-godot/godot-ai/pull/997); reported in
  [#998](https://github.com/hi-godot/godot-ai/issues/998) and
  [#989](https://github.com/hi-godot/godot-ai/issues/989)).
- The private origin used by release qualification issues a real redirect
  before serving bytes, so every A-to-B update test now exercises this path.

### Upgrading

- **From 3.2.5:** click **Update** with Godot 4.7 or newer. You go directly to
  4.0.2.
- **From 4.0.0 or 4.0.1:** those versions cannot download this fix with their
  own Update button. Follow the one-time recovery in
  [#999](https://github.com/hi-godot/godot-ai/issues/999) (also documented in
  [docs/releasing.md](docs/releasing.md#recovering-the-400--401-http-302-download-failure)).
  Afterwards the Update button works again.

## 4.0.1 (2026-09-07)

[Compare v4.0.0...v4.0.1](https://github.com/hi-godot/godot-ai/compare/v4.0.0...v4.0.1).

### Fixed

- After the first ordinary editor start following the v4 migration, client
  rows stayed on **Installing…** or **Checking…**, **Configure all** was greyed
  out, and `client_manage(op="status")` timed out. The client job owner's
  `_ready` ran after `activate()` and switched its polling off
  ([#991](https://github.com/hi-godot/godot-ai/pull/991) by @Noniv; closes
  [#990](https://github.com/hi-godot/godot-ai/issues/990), and the stuck-dock
  half of [#989](https://github.com/hi-godot/godot-ai/issues/989)).

### Changed

- The README documents the Bazzite / Fedora Atomic capability-directory
  workaround ([#995](https://github.com/hi-godot/godot-ai/pull/995); closes
  [#993](https://github.com/hi-godot/godot-ai/issues/993)).
- Release tooling resumes a hidden draft release and waits for PyPI's index
  ([#987](https://github.com/hi-godot/godot-ai/pull/987)); Windows client
  configuration is tested across editor restarts
  ([#994](https://github.com/hi-godot/godot-ai/pull/994)).

4.0.1 shares the download bug fixed in 4.0.2, so it could not be installed
from 4.0.0 through the dock.

## 4.0.0 (2026-09-07)

Godot AI 4 is a breaking release built around one signed add-on tree, one
authenticated transport, and an updater that replaces the whole tree or
nothing. Migration guide: [docs/v4-migration.md](docs/v4-migration.md).
[Compare v3.2.4...v4.0.0](https://github.com/hi-godot/godot-ai/compare/v3.2.4...v4.0.0)
(3.2.5 was cut from the `release/v3` branch, so the comparison starts at the
last shared tag).

### Requirements and compatibility (breaking)

- **Godot 4.7 or newer.** Godot 4.5 and 4.6 load the migration bridge only far
  enough to report the requirement; below the floor the bridge restores the
  previous 3.2.5 add-on instead of leaving a dead plugin. Upgrade Godot, reopen
  the project, and retry the migration
  ([#943](https://github.com/hi-godot/godot-ai/pull/943),
  [#968](https://github.com/hi-godot/godot-ai/pull/968)).
- **Python 3.11 through 3.14** for the server, provided through `uv`. Every
  runtime dependency is an exact pin (FastMCP 3.4.7, MCP 1.29.1, websockets
  17.1, Uvicorn 0.52.4, Starlette 1.6.0, Pydantic 2.13.5, httpx 0.28.1) and
  the pins are checked again when the server starts. Dependency upgrades are
  reviewed release changes ([#943](https://github.com/hi-godot/godot-ai/pull/943)).
- **Clients connect through `godot-ai attach` over stdio.** A bare
  `http://127.0.0.1:8000/mcp` entry can no longer authenticate. Use the dock's
  **Configure**, or the **Run this manually** command it shows
  ([#943](https://github.com/hi-godot/godot-ai/pull/943)).
- **v3 and v4 do not interoperate.** A v3 plugin against a v4 server, or the
  reverse, fails closed; there is no tokenless or legacy-handshake fallback
  ([#943](https://github.com/hi-godot/godot-ai/pull/943)).
- **Cherry Studio is no longer supported.** Its servers live in an internal
  database Godot AI cannot safely edit; remove stale v3 entries in Cherry
  Studio itself. **Zed** is manual-edit only, and the dock now reads Zed's
  commented `settings.json` for status instead of reporting a parse error
  ([#954](https://github.com/hi-godot/godot-ai/pull/954); closes
  [#914](https://github.com/hi-godot/godot-ai/issues/914)).
- **Distribution is GitHub Releases only.** The Godot Asset Store and Asset
  Library listings stay on the last v3 release. A stable release publishes six
  assets: the canonical `godot-ai-v4-plugin.zip` with its signed manifest and
  signature, and the legacy-named `godot-ai-plugin.zip` triple, which is now
  the v3-to-v4 migration capsule rather than an installable add-on. Never
  extract release files over an existing `addons/godot_ai/`
  ([#943](https://github.com/hi-godot/godot-ai/pull/943),
  [#949](https://github.com/hi-godot/godot-ai/pull/949)).

### Update and migration

- **One-click migration from 3.2.5.** Click **Update**; Godot restarts once,
  owned client entries are repinned, and the matching v4 server starts.
  Nothing to download, verify, or edit by hand
  ([#943](https://github.com/hi-godot/godot-ai/pull/943),
  [#968](https://github.com/hi-godot/godot-ai/pull/968)).
- **New in-editor updater.** The release manifest is RSA-4096 signed and binds
  repository, channel, tag, version, source commit, archive hash, and every
  file's size and hash. The updater verifies it, stages the tree under
  `addons/.godot_ai_update/stage/`, swaps the live add-on with two renames,
  restarts the editor, and hashes the new tree again before it runs. The
  previous add-on is kept at `addons/.godot_ai_update/backup/<old version>/`
  until the next successful update. The outcome is recorded in
  `addons/.godot_ai_update/pending.json` as `success`, `rolled_back`, or
  `repair_required`; nothing needs deleting by hand to make progress
  ([#968](https://github.com/hi-godot/godot-ai/pull/968);
  [docs/self-update.md](docs/self-update.md)).
- An update refuses before touching anything when another editor is using the
  same add-on, and it never overlays files into the live tree.
- After an update, the plugin replaces a leftover server of the version it
  just updated from and asks you to restart AI clients that were connected
  during the update ([#968](https://github.com/hi-godot/godot-ai/pull/968)).
- Client entries under the `godot-ai` name that launch something other than
  Godot AI are reported in the editor output, not rewritten; ownership is
  matched on exact launch tokens
  ([#971](https://github.com/hi-godot/godot-ai/pull/971),
  [#973](https://github.com/hi-godot/godot-ai/pull/973),
  [#975](https://github.com/hi-godot/godot-ai/pull/975)).
- **Gated publication.** Only bytes that passed the cross-platform
  qualification run, including a real-editor update on Linux, macOS, and
  Windows, can be signed and published, behind a required reviewer
  ([#949](https://github.com/hi-godot/godot-ai/pull/949)).
- `script/v4-release install` performs the same verify, stage, swap sequence
  with the editor closed, for qualification and recovery.

### Security and transport

- **Both local hops are authenticated.** The MCP HTTP endpoint requires a
  bearer capability and the editor WebSocket a separate 32-byte capability;
  neither accepts a tokenless connection. Capabilities are generated per
  server instance and published through a private, owner-only record under
  `~/.config/godot-ai/capabilities` (Linux),
  `~/Library/Application Support/godot-ai/capabilities` (macOS), or
  `%LOCALAPPDATA%\godot-ai\capabilities` (Windows). `GODOT_AI_CAPABILITY_DIR`
  overrides the location on Linux and macOS
  ([#943](https://github.com/hi-godot/godot-ai/pull/943)).
- Connection, body, frame, and session budgets are bounded. Duplicate JSON
  keys, replayed nonces, and v3 protocol frames are rejected.
- Capability paths that pass through a symbolic link are refused. On Bazzite
  and other Fedora Atomic desktops, where `/home` links to `/var/home`, follow
  the README workaround ([#993](https://github.com/hi-godot/godot-ai/issues/993)).
- The `uvx` launch is isolated (`--isolated --no-config --no-env-file
  --no-sources --no-build`) and names the public PyPI index explicitly, so an
  ambient alternate index or uv configuration cannot change what runs.
- **Telemetry opt-out reaches adopted servers.** Unchecking telemetry now
  sends a one-way `telemetry_opt_out` event over the authenticated WebSocket,
  so a server the plugin adopted rather than spawned stops sending too, and
  `/godot-ai/status` reports what the running server will actually send
  ([#955](https://github.com/hi-godot/godot-ai/pull/955); closes
  [#913](https://github.com/hi-godot/godot-ai/issues/913)).

### Tools

- `game_manage` gains `suspend`, `resume`, `next_frame`, and `debug_status`,
  driven through Godot's native debugger: the Embedded Game View when it is
  available, the debugger session otherwise
  ([#953](https://github.com/hi-godot/godot-ai/pull/953) by @quakquak86;
  closes [#939](https://github.com/hi-godot/godot-ai/issues/939)).
- `test_run` and `test_manage(op="results_get")` return `cache_warning` when
  preloaded GDScript may be stale after an edit in the same editor. Restart
  the editor before validating dependency changes
  ([#985](https://github.com/hi-godot/godot-ai/pull/985); closes
  [#938](https://github.com/hi-godot/godot-ai/issues/938)).
- Numeric strings such as `"4.0"` are coerced to floats across node, camera,
  material, animation, and audio value handlers, for clients that stringify
  float arguments ([#969](https://github.com/hi-godot/godot-ai/pull/969) by
  @robbe1912; closes [#964](https://github.com/hi-godot/godot-ai/issues/964)).
- The tool surface is 46 tools: 19 named tools plus 27 `<domain>_manage`
  rollups ([docs/TOOLS.md](docs/TOOLS.md)).

### Clients

- CodeBuddy IDE is configured automatically through `~/.codebuddy/mcp.json`
  ([#983](https://github.com/hi-godot/godot-ai/pull/983); closes
  [#941](https://github.com/hi-godot/godot-ai/issues/941)).

### Reliability

- Losing the authenticated editor-server session is no longer terminal. The
  plugin re-probes with a 1, 2, 4, 8, 16 second backoff, five attempts per
  outage, before asking for **Restart**
  ([#982](https://github.com/hi-godot/godot-ai/pull/982); closes
  [#962](https://github.com/hi-godot/godot-ai/issues/962)).
- Concurrent `godot-ai attach` clients on Windows no longer fail on the
  startup lock race ([#986](https://github.com/hi-godot/godot-ai/pull/986)).
- Also in 4.0.0, and already shipped in 3.2.5: an already-loaded GDScript is
  refreshed after script writes
  ([#944](https://github.com/hi-godot/godot-ai/pull/944)); a UTF-8 BOM
  survives a token-preserving Remove
  ([#956](https://github.com/hi-godot/godot-ai/pull/956)); the editor
  WebSocket keepalive deadline is wider
  ([#961](https://github.com/hi-godot/godot-ai/pull/961)); the Windows
  `test_project` junction repair never deletes a real plugin copy
  ([#947](https://github.com/hi-godot/godot-ai/pull/947)); the version-check
  refcount cycle and descendant ownership on reparent and duplicate undo are
  fixed.

### Known issues in 4.0.x

- 4.0.0 and 4.0.1 cannot download an update (`download failed (302)`). Fixed
  in 4.0.2; recovery in [#999](https://github.com/hi-godot/godot-ai/issues/999).
- Bazzite / Fedora Atomic: the server exits before publishing capabilities
  because `/home` is a symbolic link
  ([#993](https://github.com/hi-godot/godot-ai/issues/993)); the README
  documents the `GODOT_AI_CAPABILITY_DIR` workaround.
- The dock's **Reload Plugin** button can crash the editor. Fixed on `main` by
  [#1000](https://github.com/hi-godot/godot-ai/pull/1000); ships in the next
  release.
- After an in-session update the dock's Update button reads **Update
  complete** and cannot take a newer release until the editor restarts. Fixed
  on `main` by [#1002](https://github.com/hi-godot/godot-ai/pull/1002); ships
  in the next release.
- A failed download leaves the update lock in place; clicking Update again in
  the same editor still works. Fixed on `main` by
  [#1001](https://github.com/hi-godot/godot-ai/pull/1001); ships in the next
  release.
- The limits accepted for 4.0.0 after independent review are recorded in
  [docs/self-update.md](docs/self-update.md#known-limits-400).

## Earlier releases

3.x release notes are on the
[GitHub Releases](https://github.com/hi-godot/godot-ai/releases) pages.
