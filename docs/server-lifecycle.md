# Server lifecycle, authority, and plugin reload

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the
always-loaded rules.

Godot AI v4 has one lifecycle owner:
`plugin/addons/godot_ai/utils/server_lifecycle.gd`. The plugin root captures an
immutable launch plan on the main thread, configures the owner without side
effects, completes composition, and only then activates it. An active update
transaction blocks composition before normal settings capture or construction
of client/lifecycle/transport workers, sockets, or server objects. A successful
claim with unfinished M6 client migration is different: the root may construct
inert owners and UI, but keeps
`_normal_start_released == false`. Lifecycle start/restart/recover and all other
normal client, update, transport, and telemetry effects remain barred until the
exact actor publishes `migration-complete.json`. Stop remains available so
shutdown cannot be trapped behind the release gate.

## One serialized episode

The lifecycle stores one tagged episode with these states:

```text
DORMANT -> STARTING -> READY
                    -> BLOCKED
READY   -> STOPPING -> DORMANT
BLOCKED -> RECOVERING -> STARTING
```

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

1. Read the private per-port capability record.
2. Probe `/godot-ai/status` with its HTTP bearer and enforce the 8 KiB response
   bound.
3. If the authenticated endpoint has the expected version and WS port, adopt
   its transport authority. Adoption deliberately carries no process grant.
4. If the port is free, launch the configured command with fresh independent
   HTTP and WebSocket capabilities.
5. Wait for the new capability record, authenticate status, and bind the live
   process fingerprint before publishing `READY`.

The Python server owns the private record and a per-port launch claim. HTTP,
status, and lease routes require the HTTP bearer. The editor WebSocket stays on
IPv4 loopback and uses a transcript-bound challenge/response before the editor
reveals project metadata. There is no v3 parser, tokenless retry, or bare URL
fallback in v4.

An adopted backend remains external. Ordinary teardown drops the transport and
leaves it running. A plugin-launched backend is stopped only with its matching
owned-process grant, except when `keep_server_on_exit` is enabled or a live
attach lease requires continuity; in either case the plugin deliberately
detaches. Lease counts are finite and authenticated like every other HTTP
route.

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

The editor tool first waits for the filesystem's main-thread completion
notification, not merely `is_scanning() == false`: that worker flag can clear
before Godot applies resource/script reloads. One bounded native-signal handoff
survives those script reloads without retaining a suspended handler coroutine.
A real-time five-second deadline leaves the plugin unchanged on timeout;
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
