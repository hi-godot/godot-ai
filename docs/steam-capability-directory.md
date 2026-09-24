# Shared capability directories across Steam namespaces

Use this guide when startup reports that a capability-path ancestor is owned
by a UID other than root or your current user. Some nested Steam
pressure-vessel namespaces show host-root ancestors as an unmapped UID, often
65534. That is one possible cause; the UID alone does not establish it.

Godot AI refuses this path because it cannot verify the directory's ownership.
The checks remain enabled. Do not trust UID 65534 specially, change system
folder ownership or permissions, or copy capability tokens into client settings.
The ordinary `/home -> /var/home` symlink fix does not solve an untrusted
ancestor of the resolved path.

## Choose and verify a shared location

There is no universal replacement directory. Choose a directory whose backing
files are visible to both the Steam-launched editor and the outside AI client.
It must be owned by your user and have mode `0700`. Every existing ancestor
must pass Godot AI's ownership and write-permission checks in both views.
A matching path string, a host-only permission check, or an `XDG_RUNTIME_DIR`
variable does not prove shared access.

Create only your chosen private directory beneath a verified parent, as your
normal user. Replace the example path below; it is a placeholder, not a default:

```sh
export GODOT_AI_CAPABILITY_DIR=/absolute/verified/shared/private/godot-ai
install -d -m 700 -- "$GODOT_AI_CAPABILITY_DIR"
```

Do not apply this command to a system directory. If a parent is untrusted or
unmapped in either view, select another verified shared location. Do not repair
that parent with recursive chmod or chown. If no shared location satisfies the
checks, this namespace configuration is unsupported; launch Godot outside that
namespace instead.

For a diagnostic check, use the Python environment containing the same
`godot-ai` version as the backend, once inside the editor's namespace and once
outside in the client environment:

```sh
GODOT_AI_CAPABILITY_DIR=/absolute/verified/shared/private/godot-ai \
  python -c 'from godot_ai.transport.capability import capability_directory; print(capability_directory())'
```

A successful result validates that view's ancestors. It does not prove that
both processes see the same files. It prints a directory path, not credentials.
If `godot_ai` is not importable, use the backend's Python environment rather
than interpreting that import failure as a directory failure.

## Configure both launch environments

Close Godot and the AI client before changing their launch environments.
For Godot's Steam launch options, use your verified path:

```text
env GODOT_AI_CAPABILITY_DIR=/absolute/verified/shared/private/godot-ai %command%
```

Quote the assignment if your selected path contains spaces. The variable must
reach the Godot process inside the runtime, not only a separate host terminal.
The backend launched by Godot inherits it.

Launch the outside AI client with its corresponding verified path:

```sh
env GODOT_AI_CAPABILITY_DIR=/absolute/verified/shared/private/godot-ai your-ai-client
```

Replace `your-ai-client` with its executable. A desktop shortcut does not inherit
an export from an unrelated terminal. For persistent use, configure the variable
in that application's launcher, or in its supported per-server environment for
`godot-ai attach`. Automatic client configuration does not copy the editor's
capability-directory override into every client's environment. If the same
backing directory has different paths inside and outside the namespace, each
side needs its own valid path to those same files.

Start Godot through Steam, then connect with the outside client. Ask the client
for `editor_state` and confirm it identifies the intended project/editor.
This checks the authenticated client-to-backend-to-editor connection. A running
backend, matching environment strings, or a directory-validation result alone
does not establish that connection. Do not print or share the capability JSON.

`GODOT_AI_CAPABILITY_DIR` is a POSIX override and is unsupported on Windows.

## Verification and limits

The nested-owner refusal was reproduced using Valve's actual Soldier runtime
in a controlled Linux container with a Bazzite-style `/home -> var/home`
layout. A protected explicitly shared directory supported authenticated access
from an outside client and real editor node creation, property readback, and
deletion. This verifies the configuration mechanism, not a safe default path
for every Steam installation. The fixture backend was launched explicitly;
these results do not claim dock auto-start was tested in native Bazzite.

Native Bazzite and the original reporter's exact environment remain unverified.
See [#1113](https://github.com/hi-godot/godot-ai/issues/1113) for the concrete
namespace boundary and [#1059](https://github.com/hi-godot/godot-ai/issues/1059)
for the original Steam report.
