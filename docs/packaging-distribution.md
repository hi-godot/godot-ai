# Godot AI — Packaging & Distribution

*Updated 2026-04-13*

This document collects the install, packaging, publishing, and release mechanics that used to be scattered through the implementation plan.

For the current roadmap, use [implementation-plan.md](implementation-plan.md).

---

## Distribution Goals

The project should support these practical usage modes:

- dev checkout with local `.venv`
- published Python package via PyPI and `uvx`
- standalone binary path for users who do not want a Python install
- plugin discoverable and installable from the Godot AssetLib

The goal is not “many install methods” for its own sake. The goal is:

- low-friction onboarding
- predictable client configuration
- easy upgrades
- low support burden

---

## Naming And Package Identity

- repo: `godot-ai`
- Python package / CLI: `godot-ai`
- Python import path: `godot_ai`
- Godot plugin path: `plugin/addons/godot_ai/`

These names should stay aligned in docs and install examples.

---

## Preferred User Install Paths

### Path A: Published Package Via `uvx`

This should be the default install path for most users.

Target experience:

1. install `uv`
2. enable the plugin in Godot
3. let the plugin discover and run `uvx godot-ai`
4. connect the MCP client to `http://127.0.0.1:8000/mcp`

### Path B: Dev Checkout

This should stay easy for contributors.

Typical flow:

1. clone repo
2. run `script/setup-dev`
3. enable plugin in `test_project/`
4. plugin prefers the local `.venv` and runs `python -m godot_ai`

### Path C: Standalone Binary

This is useful for:

- users who do not want Python installed
- cleaner release artifacts
- stricter support boundaries

This path is worth building, but only if it stays reliable.

### Path D: Godot AssetLib

Godot's built-in AssetLib is the most natural discovery surface for the plugin. A user who already has Godot open should be able to find Godot AI there without ever visiting GitHub.

Target experience:

1. open Godot, go to the AssetLib tab
2. search for "Godot AI" or "MCP"
3. download and install into the current project
4. enable the plugin; it handles server startup (via `uvx` or a local `.venv`) from there

Publishing checklist:

- [ ] claim the AssetLib entry under a stable author account
- [ ] decide what the AssetLib package actually ships: plugin folder only, or plugin folder + bundled server resources
- [ ] confirm the plugin keeps working when installed from AssetLib rather than a symlinked dev checkout (paths, UID files, autoload registrations)
- [ ] tag versions so AssetLib submissions point at immutable commits
- [ ] figure out the update story — AssetLib does not push updates, so the dock should surface "a newer version is available" when appropriate
- [ ] include AssetLib install in the release-smoke tier of CI once it is live

The AssetLib path does not replace PyPI/`uvx` — the Python server still has to come from somewhere — but it dramatically lowers the "how do I even find this" friction for Godot users who are not already Python-fluent.

---

## User Install Flow

The install flow should be understandable without repo archaeology.

### Godot Side

1. copy `plugin/addons/godot_ai/` into the project’s `addons/`
2. enable the plugin in Project Settings
3. let the dock show server status and client configuration state

### MCP Client Side

Either:

- use the Godot dock’s configure buttons

Or:

- point the client at `http://127.0.0.1:8000/mcp`

The install docs should explicitly cover:

- Claude Code
- Codex
- at least one more MCP client

---

## PyPI / `uvx` Publishing Work

- [ ] verify `godot-ai` package availability and ownership
- [ ] finalize metadata in `pyproject.toml`
- [ ] publish to PyPI
- [ ] verify `uvx godot-ai --help`
- [ ] verify the plugin can discover and launch the published package cleanly

The published package path should be treated as first-class, not as a fallback for people who “know Python.”

---

## Binary Packaging Work

### Build Command

```bash
pyinstaller --onefile \
    --name godot-ai \
    --add-data "src/godot_ai:godot_ai" \
    src/godot_ai/__main__.py
```

### What To Verify

- [ ] binary starts without Python installed
- [ ] binary exposes MCP and WebSocket listeners correctly
- [ ] plugin can connect to the binary-backed server
- [ ] at least one tool roundtrip succeeds
- [ ] startup time and artifact size stay within reason

### Platform Targets

- macOS arm64
- macOS x86_64
- Windows
- Linux x86_64

The binary path is only worth keeping if it remains boring and supportable.

---

## CI Tiers

### Tier 1: Python Tests

- run on every push / PR
- all supported OSes
- multiple Python versions as needed
- `pytest` + `ruff`

### Tier 2: Godot-Side Tests

- run headless Godot where possible
- verify the plugin-backed test harness
- include reload or reconnect smoke where useful

### Tier 3: Release-Surface Smoke

- verify `uvx godot-ai` path
- verify package install path
- verify binary startup path
- verify AssetLib-installed plugin loads and connects to the server

This tier is about install confidence, not deep correctness.

---

## Release Readiness Checklist

- [ ] package path works
- [ ] plugin install docs are accurate
- [ ] client configuration docs are accurate
- [ ] CI covers the install surfaces users will actually hit
- [ ] compatibility guidance exists
- [ ] the first-run experience is clear enough that a new user can succeed without direct help

