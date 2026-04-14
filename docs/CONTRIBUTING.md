# Contributing to Godot AI

## Development Setup

```bash
git clone https://github.com/hi-godot/godot-ai.git
cd godot-ai
script/setup-dev             # creates .venv, installs deps
source .venv/bin/activate
```

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
