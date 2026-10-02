# Shared capability directories for sandboxed editors

Godot AI versions after 4.2.3 start without configuration when Godot runs in
Flatpak or Steam's runtime and shares your home directory with the host. Use
this guide for:

- Godot AI 4.2.3 and earlier in any Flatpak or Steam sandbox;
- a Flatpak editor that does not share your home directory, including the
  message **Configure** returns there;
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

## Client configuration from a restricted Flatpak sandbox

The Flathub Godot build shares your home directory. If you removed that
access (Flatseal, or `flatpak override --nofilesystem=host`), the sandbox's
home directory is private, and nothing Godot writes there reaches your AI
clients. **Configure** and **Remove** then stop with a message instead of
writing a file only the sandbox can see. There are three ways forward.

Share the home directory again. This is what the message suggests, and
nothing else is needed afterwards:

```sh
flatpak override --user --filesystem=home org.godotengine.Godot
```

Share only what Godot AI needs: the directory each client keeps its settings
in, and the directory Godot AI publishes its credentials in. For Cursor and VS
Code:

```sh
flatpak override --user org.godotengine.Godot \
  --filesystem=~/.cursor \
  --filesystem=xdg-config/Code \
  --filesystem=xdg-config/godot-ai:create
```

`--filesystem=xdg-config` on its own covers the credentials and every client
that keeps its settings under `~/.config`. Flatpak mounts a granted directory
only if it exists when Godot starts, so start the client once first, or add
`:create` as on the last line. Grant the directory, not the settings file: a
grant for the file alone can be read but not replaced. Restart Godot after
changing an override. `flatpak override --user --show org.godotengine.Godot`
lists what is set.

Godot also has to see the launcher the entry names. A restricted sandbox does
not see `uvx` in your home directory, and Configure then reports that no
launcher was found
([client configuration](client-configuration.md#linux-flatpak-editors-and-flatpak-clients)).

Or leave the sandbox as it is and add the entry by hand. The client row's
**Run this manually** panel in the dock shows it whenever Godot can see a
launcher, and
[the remote-agent recipe](client-configuration.md#agents-on-another-machine-or-in-a-container)
shows the command otherwise. Put it in the client's own settings file, then
give Godot and the client the per-app runtime directory above, so the
client's bridge finds Godot's credentials.

Without the credentials directory a client entry would be correct but could
not connect: the bridge the client starts looks in `~/.config/godot-ai`, and
a sandbox that shares neither your home nor `xdg-config` publishes inside
`~/.var/app/org.godotengine.Godot`. Configure stops there as well and names
the `xdg-config/godot-ai:create` grant, unless Godot was started with
`GODOT_AI_CAPABILITY_DIR`, which is your own arrangement to complete on the
client's side.

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

Client configuration from a restricted sandbox was verified with the same
build on the ostree-style layout. With `--nofilesystem=host`, Configure and
Remove refused for Cursor, Trae, VS Code, Claude Code, OpenCode and Codex and
wrote nothing, where the previous code reported each as configured. With
`~/.cursor`, `xdg-config/Code` and `xdg-config/Trae:create` granted, the
entries landed in the host's files. A grant for a directory that did not
exist, a `--nofilesystem` rule under `home`, a grant for `~/.claude.json`
alone, and `home:ro` were each refused with their own message, and status
under `home:ro` still reported the clients configured on the host. With the
whole of `xdg-config` granted, the credentials were published in the host's
`~/.config/godot-ai` and a driver outside the sandbox connected without
`GODOT_AI_CAPABILITY_DIR`. With `~/.cursor` granted alone, Configure refused
and named the credentials grant, where an earlier build wrote an entry whose
bridge found no record. With `xdg-config/godot-ai:create` added, the entry it
wrote connected when launched from outside. With a stand-in for the `claude`
CLI visible in a sandbox without the home, the previous code ran it there and
reported Claude Code configured from a `~/.claude.json` the host never had;
Configure and Remove now refuse before running it.

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
