# Shared capability directories for sandboxed editors

Godot AI versions after 4.2.3 start without configuration when Godot runs in
Flatpak or Steam's runtime and shares your home directory with the host. Use
this guide for:

- Godot AI 4.2.3 and earlier in any Flatpak or Steam sandbox;
- a Flatpak editor that does not share your home directory;
- a startup error that still names a capability-path ancestor owned by a UID
  other than root or your current user.

A sandbox's user namespace does not include the host's root account, so host
directories it owns read back as an unmapped UID, usually 65534. Versions after 4.2.3
accept that owner only on directories above your home directory, and only when
they are closed to group and other writes. Anywhere else Godot AI refuses the
path because it cannot verify who owns the directory. The checks remain
enabled. Do not change system folder ownership or permissions, or copy
capability tokens into client settings. The ordinary `/home -> /var/home`
symlink fix does not solve an untrusted ancestor of the resolved path.

## Flatpak: the per-app runtime directory

Flatpak shares one private directory per app with the host:
`$XDG_RUNTIME_DIR/app/<app-id>`. It belongs to your user with mode `0700`, it
has the same path inside and outside the sandbox, and every ancestor passes
Godot AI's ownership checks in both views. It needs no extra filesystem
permission. For the Flathub Godot build:

```sh
flatpak override --user org.godotengine.Godot \
  --env=GODOT_AI_CAPABILITY_DIR="$XDG_RUNTIME_DIR/app/org.godotengine.Godot/godot-ai/capabilities"
```

Give the outside AI client the same value as described under
[Configure both launch environments](#configure-both-launch-environments).
Flatpak creates the directory when the app starts, so start Godot before the
client. `flatpak override --user --show org.godotengine.Godot` lists what is
set.

## Choose and verify a shared location

Outside Flatpak there is no universal replacement directory. Choose a
directory whose backing files are visible to both the sandboxed editor and the
outside AI client. It must be owned by your user and have mode `0700`. Every
existing ancestor must pass Godot AI's ownership and write-permission checks
in both views. A matching path string, a host-only permission check, or an
`XDG_RUNTIME_DIR` variable does not prove shared access.

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

Start the sandboxed Godot, then connect with the outside client. Ask the client
for `editor_state` and confirm it identifies the intended project/editor.
This checks the authenticated client-to-backend-to-editor connection. A running
backend, matching environment strings, or a directory-validation result alone
does not establish that connection. Do not print or share the capability JSON.

`GODOT_AI_CAPABILITY_DIR` is a POSIX override and is unsupported on Windows.

## Verification and limits

Startup without configuration was verified with the Flathub Godot 4.7.2 build
under Flatpak 1.16.6, on a regular `/home` layout and on an ostree-style
`/home -> var/home` layout. The editor started its backend, the handler suite
ran through a driver outside the sandbox, `godot-ai attach` connected from the
host and from a second Flatpak sandbox, and exact 3.2.1 and 3.2.5 installs
updated into it. The same checks fail on 4.2.3. The per-app runtime directory
above was verified with an unmodified 4.2.3 editor and client.

The ownership rule was also exercised in a bubblewrap namespace laid out like
Steam's pressure-vessel. It has not been run against the Steam client itself.
The earlier nested-owner refusal was reproduced using Valve's actual Soldier
runtime in a controlled Linux container with a Bazzite-style
`/home -> var/home` layout; a protected explicitly shared directory supported
authenticated access from an outside client and real editor node creation,
property readback, and deletion.

Native Bazzite and the original reporters' exact environments remain unverified.
See [#1113](https://github.com/hi-godot/godot-ai/issues/1113) for the concrete
namespace boundary and [#1059](https://github.com/hi-godot/godot-ai/issues/1059)
for the original Steam report.
