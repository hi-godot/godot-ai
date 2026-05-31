# CLAUDE.md - Godot AI

Claude Code loads this file automatically. The shared assistant instructions for
this repository live in [AGENTS.md](AGENTS.md). Read and follow `AGENTS.md` as
the source of truth for project structure, development workflow, tool changes,
testing expectations, worktree safety, and release compatibility.

## Claude-specific notes

- Claude Code sessions may run in `.claude/worktrees/<name>`. The worktree and
  editor-routing guidance in `AGENTS.md` applies; verify the active worktree and
  connected Godot `test_project/` before editing or testing plugin code.
- Keep `.claude/skills/godot-ai/skill.md` as a Claude adapter that points back
  to `AGENTS.md`.
- When updating general repo operating guidance, update `AGENTS.md` first. Keep
  this file limited to Claude-specific loading behavior and reminders.
