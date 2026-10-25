# Linux troubleshooting

Startup problems specific to Linux desktops, sandboxes, and directory
permissions. For client setup, see
[client configuration](client-configuration.md).

## Bazzite / Fedora Atomic

On Bazzite and other Fedora Atomic desktops, `/home` is normally a symbolic
link to `/var/home` (the ostree layout). Godot AI 4.0.2 and earlier refuse
every capability-directory path that passes through a link, so on such a
system the server exits with `Last pending: capability_record`
([#993](https://github.com/hi-godot/godot-ai/issues/993)). In Godot AI 4.0.3 and later,
the server follows a link when it is root-owned and sits in a root-owned directory that
other accounts cannot write, which is exactly that layout; no configuration is
needed there.

On 4.0.2 or earlier, close Godot and your MCP client, then run this in a
terminal as your normal user:

```bash
export GODOT_AI_CAPABILITY_DIR="$(
  realpath -m "${XDG_CONFIG_HOME:-$HOME/.config}/godot-ai/capabilities"
)"
install -d -m 700 "$GODOT_AI_CAPABILITY_DIR"
printf 'Using: %s\n' "$GODOT_AI_CAPABILITY_DIR"
```

Launch **both Godot and your MCP client from that terminal** so the backend and
`godot-ai attach` inherit the same directory. A desktop launcher does not
automatically inherit a terminal's `export`; for persistent use, set the same
canonical path in the launch environment of both applications. Keep the
directory private to your user; do not copy capability tokens into client
configuration. This workaround is for Linux; `GODOT_AI_CAPABILITY_DIR` is not
supported on Windows.


## Steam, Flatpak, and directory permissions

Godot AI 4.2.2 and later read process identity and listening-socket ownership
from `/proc`, so Steam and Flatpak runtimes do not need to provide `ps`, `lsof`,
or `ss`. These checks stay inside the editor's sandbox; host PIDs are not used
to authorize stopping a sandbox process. The backend launcher still needs to
be installed and executable within that environment.

Steam pressure-vessel can expose `/home -> /var/home` as a user-owned link.
Godot AI 4.2.2 and later accept root- or current-user-owned links beneath
protected parents and validates every target ancestor. Other-user ownership,
writable parents, and symlink loops remain rejected.

Flatpak and Steam's runtime run in a user namespace that maps only your own
user. The host's root-owned `/home` (`/var/home` on Fedora Atomic, Bazzite, and
other ostree systems) then reads back as an owner the sandbox cannot name,
usually UID 65534, and Godot AI 4.2.3 and earlier refuse to start there. Later
versions do not test the owner of a directory above your home directory when
they run inside such a namespace, which is where OpenSSH's `StrictModes` stops
too. That directory must still be closed to group and other writes. Your home
directory and everything below it must still belong to you or root. Nothing is
relaxed outside a user namespace, or inside one where UID 65534 is a real
account, as in a rootless container that maps a subordinate ID range.

A Flatpak editor that shares your home directory, as the Flathub Godot build
does by default, publishes its credentials under the host's `~/.config/godot-ai`
(or the host's `XDG_CONFIG_HOME`) instead of Flatpak's per-app config
directory, so an AI client outside the sandbox finds them without configuration.

**Configure** from that editor writes client settings to the same host
directories. Install `uv` with its standalone installer, so that `uvx` is in
`~/.local/bin`: the sandbox cannot see a system package in `/usr/bin`. An IDE
that is itself a Flatpak (VS Code, Zed) keeps its settings under its own
`~/.var/app/<id>`, which a Flatpak Godot cannot see. Configure then stops and
prints the `flatpak override` command that grants access; run it and restart
Godot. Details:
[client configuration](client-configuration.md#linux-flatpak-editors-and-flatpak-clients).

If you took that home access away from Godot (Flatseal, or
`flatpak override --nofilesystem=host`), its sandbox cannot reach the files
your AI clients read. Configure and Remove then stop and name the
`flatpak override` that restores access, instead of writing a file only the
sandbox can see.

Use the [explicit shared-directory guide](steam-capability-directory.md)
on 4.2.3 and earlier, for a Flatpak editor that does not share your home
directory, and whenever the startup error still names an untrusted ancestor
owner. Do not chmod or chown system directories to work around it.

If the selected credential path has group- or world-writable ancestors (for
example `775` or `777`), startup remains blocked. The plugin lists the existing
directories with problematic permissions before launching the server.
Review their ownership and intended sharing; if you own them and
shared write access is not intentional, `chmod go-w /exact/directory` removes
group/other write access from that directory. Do not use recursive chmod.
Godot AI does not change your home or config directory permissions itself.

