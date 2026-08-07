# Releasing and self-update

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


Cutting a release, and the self-update install path with its smoke-test contract.

## Releasing

Use the GitHub Actions workflow to cut a release:
```bash
gh workflow run bump-and-release.yml -f bump=patch   # or minor / major
```
This bumps `plugin.cfg` + `pyproject.toml`, commits, tags, and pushes. The `release.yml` workflow triggers on the tag and attaches two plugin zips to the GitHub Release:

- **`godot-ai-plugin.zip`** — the artifact the classic Asset Library entry ([asset 5050](https://godotengine.org/asset-library/asset/5050)) downloads directly, the self-updater installs, and the README links for manual install. Ships `addons/` plus a `godot-ai-LICENSE.txt` sibling at the zip root: the multi-top shape stops the AssetLib-tab installer on Godot ≤ 4.6 from auto-stripping a lone `addons/` root (which would install to `res://godot_ai/`), and the namespaced filename avoids clobbering the user's project `LICENSE` (issue #450). Godot 4.7+ no longer strips a bare `addons/` root, so the sibling — and the split below — can be retired once the supported floor reaches 4.7.
- **`godot-ai-plugin-store.zip`** — the upload for the [new Godot Asset Store](https://store.godotengine.org/asset/dlight/godot-ai/) listing. `addons/` only, no root license: store review requires no license duplicate at the zip root since the canonical copy ships at `addons/godot_ai/LICENSE`. Store installs never hit the ≤ 4.6 autoskip default (browser download + manual Import, or the 4.7+ in-editor store), so the single-top shape is safe there. No `.sha256`/`.sig` sidecars — the self-updater never consumes this artifact. **Use this zip, not `godot-ai-plugin.zip`, when updating the Asset Store listing.**

The shape contract for both zips is pinned by `tests/unit/test_release_zip_shape.py` and re-verified against the built artifacts in the workflow's "Verify zip structure" step.

## Self-update

The dock checks the GitHub releases API on startup. If a newer version exists, a yellow banner appears with an "Update" button that downloads the release ZIP, hands off to `update_reload_runner.gd`, disables the old plugin, extracts over the current `addons/godot_ai/`, waits for Godot's filesystem scan, and enables a fresh plugin instance. There must be no manual editor restart and no programmatic `OS.create_process` + `quit` restart in this path.

The server process is intentionally prepared for reload, not left untouched: `prepare_for_update_reload()` stops the managed server and resets the spawn guard so the re-enabled plugin starts or adopts the correct server for the new plugin version.

In dev checkouts the check is skipped: `is_dev_checkout()` detects a nearby `.venv` and short-circuits to avoid offering a path that would overwrite tracked source (the addons dir is a symlink into `plugin/`). Three override knobs let you exercise the update flow without leaving the repo (resolved in priority order):

1. **EditorSetting `godot_ai/mode_override`** — set it manually via Editor > Editor Settings (there is currently no dock UI that writes it). Values: empty/absent (auto) / `user` / `dev`, read by `client_configurator.gd::mode_override()`.
2. **`GODOT_AI_MODE` env var** — fallback for CLI launches and CI. Values: `user` / `dev`. Only takes effect when the EditorSetting is unset (the setting always wins).
3. Neither set → the `.venv`-proximity heuristic runs as before.

When either override reports `user`, the yellow update banner's label includes `(forced)` (the `forced` hint in `update_manager.gd`'s banner payload) so testers don't forget they're in override mode.

`_install_update` keeps a physical data-safety guard (`addons_dir_is_symlink()`) independent of the mode override: even in forced-user mode the self-install bails if `res://addons/godot_ai` is a symlink. To actually test the end-to-end extract path, unpack a release zip over a plain-directory copy of the addons dir (or test from a standalone project outside the dev tree).

For self-update changes, run the local interactive smoke harness:

```bash
script/local-self-update-smoke
```

For runner-ordering changes, the current-as-base form above is the forward
regression check: it proves the runner shipped in this branch can upgrade to a
future zip without parse errors. A base from a pre-fix release is a historical
constraint case: its old installed runner may still print transient parse
errors during that one upgrade, and PRs in the new version cannot retroactively
change that runner.

Until old two-phase runners have aged out, release shape matters for the next
upgrade those users take: avoid adding new files that reference constants,
methods, or static/non-static shape changes added to existing load-surface
scripts in the same release. This applies to both `class_name` scripts and
preload-only scripts because the failure mode is stale Script-object content,
not just class registry skew.

Agent trigger: this smoke is required whenever a change touches any of these areas:

- `mcp_dock.gd` update check/download/install paths
- `update_reload_runner.gd`
- `plugin.gd` plugin disable/enable, dock detach, or update handoff paths
- server reload prep around `prepare_for_update_reload()`
- release ZIP layout or install/extract behavior

The harness creates a disposable project with a physical addon copy, stages a synthetic v(N+1) ZIP that adds a new typed Dict/Array field read from `_exit_tree`, forces the Update banner to use that local ZIP, records the macOS DiagnosticReports baseline, and launches Godot. The only operator action is to click Update in the dock. Passing means the editor stays alive without restart, the plugin version advances, `user://godot_ai_update/` is consumed, no new Godot `.ips` appears, and the vNext `_exit_tree` trigger does not print during the update window.
