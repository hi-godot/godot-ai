# Contributing to Godot AI

## Development Setup

**macOS / Linux:**

```bash
git clone https://github.com/hi-godot/godot-ai.git
cd godot-ai
script/setup-dev             # creates .venv, installs deps, installs git hooks
source .venv/bin/activate
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/hi-godot/godot-ai.git
cd godot-ai
.\script\setup-dev.ps1       # creates .venv, installs deps, fixes symlink, installs git hooks
.venv\Scripts\Activate.ps1
```

> **One-time per clone:** `setup-dev` installs a `post-checkout` git hook
> (from `.githooks/`) into `.git/hooks/`. The hook auto-verifies worktree
> integrity on every `git worktree add` and `git checkout <branch>` —
> specifically, that `plugin/` is populated and `test_project/addons/godot_ai`
> is a real symlink/junction into this worktree's `plugin/`. It auto-heals
> the Windows text-file-fallback symlink via `mklink /J`. You only need to
> run `setup-dev` once per clone; the hook fires in every worktree of that
> clone from then on.

> **Windows contributors:** `setup-dev.ps1` requires **Windows Developer Mode**
> to be enabled — if it isn't, the script prompts you with a link to the Settings
> page (`ms-settings:developers`). Without Developer Mode + `core.symlinks=true`,
> the committed symlink at `test_project/addons/godot_ai` checks out as a plain
> text file, and the plugin fails to load with *"Attempt to open script
> 'res://addons/godot_ai/runtime/game_helper.gd' resulted in error 'File not
> found'"*. Every branch switch can re-break the symlink until `core.symlinks`
> is set in the repo — which `setup-dev.ps1` handles for you.

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
