---
name: verification
description: Verify a Godot AI change before committing — ruff, pytest, GDScript test_run against a live editor, and live-smoke of changed tools. Use before every commit, and whenever asked to check that a change actually works.
---

# Verifying a Godot AI change

This skill is an adapter. The vendor-neutral source of truth is
[docs/verification.md](../../../docs/verification.md).

Read that file and follow it. It covers the full pre-commit gauntlet: lint,
Python tests, GDScript suites via `test_run` against a running editor, the
live-smoke checklist for new or changed tools, and the self-update smoke
trigger.

Two things worth knowing before you start:

- **Python mocks do not catch GDScript bugs**, editor API regressions, or
  undo/redo breakage. A green `pytest` is not a verified change.
- **Running a scene persists in-memory scene mutations to disk.** See
  "Live-smoke scene hygiene" in [AGENTS.md](../../../AGENTS.md) before smoking
  against `main.tscn`.
