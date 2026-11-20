# Fork notes (arche578/godot-ai)

This is a personal fork of [hi-godot/godot-ai](https://github.com/hi-godot/godot-ai),
tuned for a 3D top-down extraction shooter made with Godot 4.7.2 on macOS and
Windows, driven from Claude Desktop and Claude Code.

The fork keeps its diff from upstream small so weekly upstream merges stay
clean. Game-specific tools will live in their own folder as custom tools
(see `docs/plugin-architecture.md#custom-tools-third-party-addons`), not as
edits to upstream files.

## Differences from upstream

| Area | Upstream | This fork |
| --- | --- | --- |
| Telemetry | On by default, opt out with `GODOT_AI_DISABLE_TELEMETRY=true` | Off by default. Opt in with the dock checkbox or `GODOT_AI_ENABLE_TELEMETRY=true`. `GODOT_AI_DISABLE_TELEMETRY` still wins. |
| Attach CLI | `--disable-telemetry` | Also accepts `--enable-telemetry` |
| Upstream sync | n/a | `.github/workflows/fork-sync-upstream.yml` mirrors upstream tags, merges upstream `main` weekly into `sync/upstream` and opens a PR |

## One-time GitHub setup

1. **Actions** tab: enable workflows for this fork.
2. **Settings → Actions → General → Workflow permissions**: tick
   "Allow GitHub Actions to create and approve pull requests".
3. Run **Fork sync from upstream** once by hand (Actions tab → Run workflow).
   It copies upstream release tags into the fork; the Python test
   `test_self_update_smoke_harness.py` needs tag `v3.2.5` and fails without it.
4. Disable the upstream-only workflows you do not need in the **Actions** tab
   (for example `Release`, `Discord changelog`, `Star history`,
   `Nightly diagnostics`). They are left untouched in the tree to avoid merge
   conflicts.

## Updating by hand

```sh
git remote add upstream https://github.com/hi-godot/godot-ai.git
git fetch upstream
git merge upstream/main
```
