# Contributing to Godot AI

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
> (from `.githooks/`) into `.git/hooks/`. The hook auto-builds the plugin
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
test_results_get             # review last results
```

### CI regression range helper

When CI starts failing, identify the regression window (last green → first red):

```bash
script/ci-find-regression-range hi-godot/godot-ai ci.yml main
```

If your local clone has a valid `origin` GitHub remote, you can omit `owner/repo`:

```bash
script/ci-find-regression-range
```

## Dev Server with Auto-Reload

For Python-side changes without restarting Godot:

```bash
python -m godot_ai --transport streamable-http --port 8000 --reload
```

The Godot AI dock also has a **Start/Stop Dev Server** button when running from a dev checkout.

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
