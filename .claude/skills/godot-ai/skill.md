---
name: godot-ai
description: Build, test, and extend the Godot AI server and editor plugin
globs:
  - "**/godot-ai/**"
  - "**/godot_ai/**"
---

# Godot AI Development

This Claude skill is an adapter. The vendor-neutral source of truth is
`AGENTS.md` at the repository root.

Read `AGENTS.md` before making changes. It covers project structure, tool
surface rules, test expectations, GDScript and Python conventions, worktree
safety, and release compatibility.

Claude-specific reminders:

- Claude Code may run in `.claude/worktrees/<name>`. Confirm the worktree and
  connected Godot editor session before editing plugin code or running
  Godot-side tests.
- Keep general repo guidance in `AGENTS.md`; only Claude-specific loading or
  workflow notes belong in this skill file.
