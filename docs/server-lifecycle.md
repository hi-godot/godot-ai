# Server lifecycle, authority, and plugin reload

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the
always-loaded rules.

Godot AI v4 has one lifecycle owner:
`plugin/addons/godot_ai/utils/server_lifecycle.gd`. The plugin root captures an
immutable launch plan on the main thread, configures the owner without side
effects, completes composition, and only then activates it. When
`addons/.godot_ai_update/pending.json` exists, the root first hashes the live
tree against the marker and records the outcome
([self-update.md](self-update.md)); a `repair_required` outcome keeps the
plugin inactive. Otherwise the root may construct owners and UI but keeps
`_normal_start_released == false`: lifecycle start/restart/recover and all
other normal client, update, transport, and telemetry effects remain barred
until that post-restart tree verification and the pin-only client repin have
finished. Stop remains available so shutdown cannot be trapped behind the
release gate.

## Upgrading from a pre-v4 installation

A verified pre-v4 to v4 update selects two free loopback ports before starting
client migration or the server. It stores the pair in
`godot_ai/v4_endpoint_ports` and uses that same pair for the capability record,
server launch, editor connection, and repinned client entries. Later updated
editors reuse the pair. The historical `godot_ai/http_port` and
`godot_ai/ws_port` settings remain available to older plugins. A normal v4
update without this override keeps its existing custom ports.

This avoids waiting for an already-running v3 bridge to release its server.
The old bridge cannot authenticate to v4, and updating its configuration does
not change the running process. Reload the AI client's MCP configuration and
reconnect once; clients that cannot reload configuration need an application
relaunch. The editor can connect to v4 while the old bridge remains running.
No legacy server is killed or treated as authenticated by this migration.
A repinned global client entry now targets the new server; other projects
still using older plugins need their own plugin update or explicit endpoint
configuration to join it.

On Windows, client-config rewrites retain complete newline sequences even
when the existing file uses CRLF. Upgrade checks parse the raw TOML bytes so
text-reader newline normalization cannot hide an invalid trailing carriage
return.

Endpoint selection is bounded. If no pair is available, startup remains
blocked with a retry button. A malformed saved pair also blocks startup;
correct or remove the named Editor Setting before retrying. The dock's port
changes update the complete saved pair once the override exists. Ordinary
capability and ownership checks still apply if another process takes a port
between selection and launch.

## One serialized episode

The lifecycle stores one tagged episode with these states:

```text
DORMANT -> STARTING -> READY
                    -> BLOCKED
READY   -> STOPPING -> DORMANT
BLOCKED -> RECOVERING -> STARTING
```

An authenticated endpoint that drops moves `READY -> BLOCKED(endpoint_lost)`
and revokes the connection, then schedules one re-probe. Successive losses
without a full minute in `READY` use delays of 1, 2, 4, 8, and 16 seconds.
Automatic recovery probes the existing backend before deciding whether to
launch. A lost socket does not
authorize killing a healthy shared backend. For an owned process, the probe
checks the PID, fingerprint, authenticated endpoint, and listener identity
before retaining ownership. If the process is dead and both ports are free,
recovery may launch a replacement through the normal startup path. An identity
that cannot be proven blocks recovery. The dock's explicit Restart remains a
separate process-control action.

After five recovery attempts, another loss stays blocked until Restart. A
server that holds `READY` for 60 seconds earns a fresh budget on its next loss.
A failed recovery probe can leave the lifecycle blocked immediately; the five
delays limit repeated disconnects, not retries of a single failed probe.

Startup effects are `PROBE`, `LAUNCH`, and `PROVE`; control effects are
`REPLACE` and `STOP`. Every effect carries the active episode ID. Completion
for an older or cancelled episode is discarded, so a late worker cannot revive
state from a superseded start/stop/replacement attempt. The lifecycle exposes
copied snapshots and narrow effect signals; it does not retain the plugin or
Dock and has no generic `_host.*` callback surface.

## Capabilities are not process authority

The three authority values are deliberately separate:

- `TransportAuthority` contains the HTTP/WS ports, server instance ID, and the
  two independent private capabilities. Its public snapshot omits both
  secrets. It permits authenticated communication, not process control.
- `OwnedProcessGrant` binds a PID to a process fingerprint captured after the
  launched backend publishes and proves its capability record. Stop/restart
  rechecks that exact identity before killing anything.
- `ReplacementAuthorization` is created only from an explicit Dock intent. It
  is short-lived, bound to one instance/version/port tuple, and spend-once.
  Re-probing must match that tuple before replacement proceeds.

Possessing transport metadata, seeing a branded status response, or occupying
the expected port never upgrades into kill authority. A foreign,
unauthenticated, changed, or otherwise unproven occupant leaves the lifecycle
in `BLOCKED`.

## Startup and adoption

Status probes share a three-second deadline during normal startup, recovery,
and post-update adoption. The former 800 ms normal-start window could reject
a healthy backend whose authenticated status took over a second. This gives
slow responses a finite settling window; it does not retry a failed probe or
eliminate concurrent-launch races. An unanswered bound endpoint can still
leave startup blocked when that deadline expires.

1. Read the private per-port capability record.
2. Probe `/godot-ai/status` with its HTTP bearer and enforce the 8 KiB response
   bound.
3. If the authenticated endpoint has the expected version and WS port, adopt
   its transport authority. Adoption deliberately carries no process grant.
4. If the HTTP port is free, check the WebSocket port too: the server binds
   both before it publishes anything, so a held WebSocket port (a server moved
   off the HTTP port, another editor) blocks the start with `ws_occupied` and
   names `godot_ai/ws_port` instead of dying at the server's preflight. The
   dock's port picker moves both ports and keeps whichever one is free. Then
   launch the configured command with fresh independent HTTP and WebSocket
   capabilities.
5. Wait for the new capability record, authenticate status, and bind the live
   process fingerprint before publishing `READY`.

Two diagnostics sit around step 4. On Windows the plugin creates and probes
the capability directory before it spawns: the server would otherwise create
it with `mode=0o700`, which CPython renders as a DACL of SYSTEM, Administrators
and OWNER RIGHTS only, and a directory first created by an elevated process is
unusable from the user's unelevated editor, server and bridge (#988). A failed
probe blocks the start with the exact directory path and permission guidance;
the server and the `attach` bridge report the same message from their side.
Restore the Windows account's access to that directory and reopen the editor
and clients unelevated. The diagnostic never recommends deleting a directory
based on its name. The plugin also passes `--startup-report <user://...json>` beside
`--pid-file` and removes any stale report before the spawn. A server that
fails before publishing its record writes `{pid, error, message, hint}` there
(a port already in use, an unwritable directory, an import error); the first
report wins and the record's publication disarms it. The dock appends that
text to "exited before publishing capabilities", to the proof timeout, and to
a launch whose process identity could not be captured (the process usually
died refusing to start, and the report says why). The report is quoted,
bounded and never interpreted. When the HTTP port is held and a capability
record exists for it but does not authenticate the occupant, the block names
the reason (a probe timeout, a different instance, a non-godot-ai listener).

The Python server owns the private record and a per-port launch claim. HTTP,
status, and lease routes require the HTTP bearer. The editor WebSocket stays on
IPv4 loopback and uses a transcript-bound challenge/response before the editor
reveals project metadata. There is no legacy v3 protocol fallback, tokenless
retry, or bare URL fallback in v4. One deliberately untrusted read exists
beside the probe:
when the port is bound and the authenticated probe finds no record, the
lifecycle performs a single bounded, tokenless GET of `/godot-ai/status`
and, only if the body claims `name: godot-ai` with a `3.x`
`server_version`, words the BLOCKED message as a pre-v4 server kept
alive by a client's old bridge. That result never enters the probe
outcome, never becomes a transport, and grants no replacement or kill
authority; the occupant stays `replaceable: false`. After an update the
plugin re-probes such a block slowly for about three and a half minutes,
long enough for the old bridge's lease and the server's idle backstop to
run out once the user quits and relaunches that client.

An adopted backend remains external. Ordinary teardown drops the transport and
leaves it running. A plugin-launched backend is stopped only with its matching
owned-process grant, except when `keep_server_on_exit` is enabled or a live
attach lease requires continuity; in either case the plugin deliberately
detaches. Lease counts are finite and authenticated like every other HTTP
route.

Replacement keeps the new child in its port wait for at most 60 seconds. A
Windows upgrade recorded the old 15-second wait expiring after 15.020 seconds,
while the incumbent released the port 25.262 seconds after the wait began.
The longer bound preserves the existing process checks before termination.
Python applies the same 60-second cap. Waiting for the child to announce its
port-wait phase remains bounded at 120 seconds; capability proof starts after
replacement returns and has a separate 180-second deadline.

## Command discovery

The immutable plan uses one three-tier command order:

1. `.venv/bin/python -m godot_ai` for a nearby development checkout;
2. isolated/no-config/no-build `uvx --from godot-ai==VERSION godot-ai` with
   official PyPI explicit for an exact user version;
3. a matching `godot-ai` executable as the system fallback.

`PYTHONPATH`, ports, exclusions, allow-host ranges, telemetry preference,
keep-alive policy, PID-file path, and command argv are captured on the main
thread. Worker effects consume those copied values and do not read mutable
EditorSettings or environment state.

For Python auto-reload during development, start one explicit external server
from the intended worktree:

```bash
script/serve-this-worktree
```

The script prepends that worktree's `src/` and starts Uvicorn with `--reload`;
the editor adopts it through the same authenticated capability boundary. The
Dock does not own or kill this external reload supervisor.

## Headless and unsupported editors

Normal headless launches return before server composition. Set
`GODOT_AI_ALLOW_HEADLESS=1` only for intentional CI/editor sessions. Godot 4.5
and 4.6 are below the v4 floor and return even earlier: they emit the Godot 4.7
requirement and construct no lifecycle, exporter, updater, transport, or client
worker.

## Plugin reload

`editor_reload_plugin` disables and re-enables the plugin in the same editor.
All client threads are realized, dispatcher references are cleared, transport
is torn down, and the lifecycle either stops its exact owned process or detaches
according to the rules above. The Python handler waits for a distinct
authenticated replacement session; it never treats the old session entry as a
successful reload.

The tool reserves its reload before scheduling the scan. The dispatcher blocks
nested ticks and stops starting queued handlers after returning the reload
response. The reservation holds through scan completion and plugin teardown;
a scan timeout releases it so queued commands can resume. This prevents a later
handler's filesystem operation from pumping an already-scheduled tool reload.
`reload_plugin` is rejected inside `batch_execute` before any batch operation
runs. Previously started deferred work retains its existing lifetime rules;
this command-dispatch gate does not certify its quiescence or cover a Dock
callback scheduled while a handler is already executing.

The editor tool first waits for the filesystem's main-thread completion
notification, not merely `is_scanning() == false`: that worker flag can clear
before Godot applies resource/script reloads. One bounded native-signal handoff
survives those script reloads without retaining a suspended handler coroutine.
A real-time sixty-second deadline leaves the plugin unchanged on timeout;
duplicate requests are refused, stale callbacks cannot consume a later request,
and direct reload cancels pending scan work. The script-work ledger remains
busy until this handoff actually completes or is cancelled. The transaction
coordinator already has its own notification-driven scan state and is unchanged.

Ordinary reloads from the editor tool, Dock, and pre-mutation update-abort
recovery share `utils/plugin_reload.gd`. It requires an enabled plugin, toggles
it, verifies re-enablement, then saves project settings **after** the engine's
enable call has completed. Startup/autoload callbacks may save the temporary
disabled list during that call; without the final save, a working reloaded
plugin can be disabled on the next editor start. Enable/save failures are
reported, not treated as persisted success. This helper does not replace or
relax the transaction coordinator's separate quiescence and readiness protocol.

The Dock's managed-server control is visible only in developer mode. It starts,
restarts, or stops only the lifecycle's exact fingerprinted child. If the port
belongs to any external process—including `serve-this-worktree`—the control
reads **External Server Running** and is disabled; stop that process at its
owner rather than transferring kill authority to the Dock.
