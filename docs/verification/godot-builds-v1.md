# Godot qualification executable pins

`godot-builds-v1.json` is the source-controlled expected identity for the six
required Godot executable rows. It is not generated from the executable under
test. Pin changes require review with the release inputs.

The archives were downloaded on September 3, 2026 from the official
[4.7-stable release](https://github.com/godotengine/godot-builds/releases/tag/4.7-stable)
and [4.7.2-stable release](https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable).
Each archive's SHA-256 matched its GitHub release-asset `digest` before its
listed executable entry was hashed. Linux and Windows are x86_64; macOS uses
the official universal binary (the required runner architecture is arm64).
The Windows pin is the full engine, not the small `_console.exe` launcher.

To reproduce a pin, download the named archive from the corresponding release,
compare `shasum -a 256 ARCHIVE.zip` with the published asset digest, then obtain
the listed entry's size with `unzip -l ARCHIVE.zip` and hash its exact bytes:

```sh
unzip -p ARCHIVE.zip EXECUTABLE_ENTRY | shasum -a 256
```

The qualification workflow's pinned setup action installs the engine and
exports `GODOT`. The runtime harness resolves that path and verifies its exact
size and SHA-256 before executing it. The setup action/cache is not trusted to
choose the expected digest. Aggregate evidence validation checks the retained
identity against this same checked-in manifest.

`archive_sha256` in a runtime case identifies the source of the reviewed pin;
it is not a claim that the runtime job downloaded or retained the archive.
This gate authenticates the main executable only, not the complete app bundle,
system libraries, runner image, or runner integrity. It does not replace the
remaining exact-candidate runtime, failpoint, stress, and approval gates.
