# CLAUDE.md - Godot AI

Claude Code loads this file automatically. The shared assistant instructions for
this repository live in [AGENTS.md](AGENTS.md). Read and follow `AGENTS.md` as
the source of truth for project structure, development workflow, tool changes,
testing expectations, worktree safety, and release compatibility.

`AGENTS.md` is long. Read the sections your task actually touches rather than
the whole file:

- Any change to plugin or server behavior — `## Architecture`, `## Key conventions`
- Editing anything under `plugin/` — `## Worktrees`, `### Godot editor + worktree safety`
- Adding or changing an MCP tool — `## Adding a new tool`, `## Tool-search friendliness + tool-count caps`
- Writing tests — `## Testing`, `### Test hygiene checklist`
- Before every commit — `## Pre-commit smoke test`
- Release, self-update, or `class_name` changes — `### Releasing`, `### Self-update`, `### Published class_name compatibility`

## Claude-specific notes

- Claude Code sessions may run in `.claude/worktrees/<name>`. The worktree and
  editor-routing guidance in `AGENTS.md` applies; verify the active worktree and
  connected Godot `test_project/` before editing or testing plugin code.
- Keep `.claude/skills/godot-ai/SKILL.md` as a Claude adapter that points back
  to `AGENTS.md`. The filename must be exactly `SKILL.md` — skill discovery is
  case-sensitive, and a lowercase `skill.md` is silently never loaded.
- When updating general repo operating guidance, update `AGENTS.md` first. Keep
  this file limited to Claude-specific loading behavior and reminders.
