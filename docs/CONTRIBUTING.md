# Contributing to Godot AI

AI assistants working in this repository should read the shared guide in
[AGENTS.md](../AGENTS.md). Client-specific files should point there instead of
duplicating general repo guidance.

## Development Setup

**macOS / Linux:**

```bash
git clone https://github.com/hi-godot/godot-ai.git
cd godot-ai
script/setup-dev             # creates .venv, installs deps, builds plugin symlink, installs git hooks
source .venv/bin/activate
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/hi-godot/godot-ai.git
cd godot-ai
.\script\setup-dev.ps1       # creates .venv, installs deps, builds plugin junction, installs git hooks
.venv\Scripts\Activate.ps1
```

> **Plugin link is built locally, not tracked in git.** `test_project/addons/godot_ai`
> is a symlink (Unix) or directory junction (Windows) into `plugin/addons/godot_ai`,
> created fresh by `setup-dev`. A clone without running `setup-dev` has no link and
> Godot won't find the plugin. The Windows flavor uses `mklink /J`, which works
> without admin rights and without Windows Developer Mode.

> **One-time per clone:** `setup-dev` installs a `post-checkout` git hook
> (from `script/githooks/`) into `.git/hooks/`. The hook auto-builds the plugin
> link on every `git worktree add` and `git checkout <branch>`, so every
> future worktree of this clone gets a working link automatically. You only
> need to run `setup-dev` once per clone.

## Testing

### Python tests

```bash
pytest -v                    # unit + integration tests
ruff check src/ tests/       # lint
ruff format src/ tests/      # format
```

### Godot-side tests

GDScript test suites run inside the connected editor via MCP:

```
test_run                     # run all suites
test_run suite=scene         # run one suite
test_manage op=results_get   # review last results
```

See [testing.md](testing.md) for how to write suites and the full
`McpTestSuite` API reference.

### CI regression range helper

When CI starts failing, identify the regression window (last green → first red):

```bash
script/ci-find-regression-range hi-godot/godot-ai ci.yml main
```

If your local clone has a valid `origin` GitHub remote, you can omit `owner/repo`:

```bash
script/ci-find-regression-range
```

### Self-update tests

For changes that touch self-update, the migration bridge, or plugin
disable/enable, run `test_project/tests/test_update_installer.gd` via
`test_run` and the three real-editor scenarios in
`tests/integration/test_self_update_upgrade_paths.py` with `GODOT_BIN` set
(they skip otherwise). The path they cover is specified in
[self-update.md](self-update.md).

### Self-update compatibility rules

V4 is the runtime boundary. The final signed v3 line consumes only the
temporary signed migration capsule; the capsule then crosses the boundary with
the same in-editor installer, retained backup, post-restart tree verification,
and exact signed inventory used by v4 updates. It restarts Godot after the
swap so v4 never runs against cached v3 script classes. V4 carries no permanent
v3 runtime path.

- `godot-ai-plugin.zip` must remain a temporary bridge built from the exact
  source commit with the canonical signed triple embedded. Never make it an
  alias for the canonical archive or a second final plugin tree.
- File and `class_name` deletions are permitted only when the signed candidate
  inventory, exact-tree swap, and post-restart verification tests all pass;
  never overlay a candidate onto the live tree.
- Qualify the exact current-to-candidate pair that will ship. A synthetic or
  relabeled successor is not evidence for a different release.

## Dev Server with Auto-Reload

For Python-side changes without restarting Godot:

```bash
script/serve-this-worktree
```

This is an externally owned auto-reload server. The Godot AI Dock deliberately
does not kill or restart it. In a development checkout the Dock can separately
start/restart/stop only the lifecycle's exact managed child; when an external
server owns the port it displays **External Server Running** and leaves control
with the launching terminal.

## PR Workflow

1. Branch off `main`
2. Keep tests and lint clean
3. Add tests for new behavior — both Python and Godot-side when crossing the plugin boundary

```bash
git checkout -b feature/my-feature
pytest -v && ruff check src/ tests/
git push -u origin feature/my-feature
gh pr create
```
