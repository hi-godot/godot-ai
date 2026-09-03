# CLAUDE.md - Godot AI

Claude Code loads this file automatically. The shared assistant instructions for
this repository live in [AGENTS.md](../AGENTS.md). Read and follow `AGENTS.md` as
the source of truth for project structure, development workflow, tool changes,
testing expectations, worktree safety, and release compatibility.

`AGENTS.md` holds the rules that apply everywhere. Depth lives in `docs/`, linked
from the relevant `AGENTS.md` section — load it when the task calls for it:

| Task | Read |
|---|---|
| Adding or changing an MCP tool | [docs/tool-surface.md](../docs/tool-surface.md) |
| Verifying a change before commit | [docs/verification.md](../docs/verification.md) |
| Server start/adopt/teardown, reload | [docs/server-lifecycle.md](../docs/server-lifecycle.md) |
| Cutting a release | [docs/releasing.md](../docs/releasing.md) |
| Self-update, migration capsule, or release verification changes | [docs/self-update.md](../docs/self-update.md) |
| Undo patterns, readiness, WS security | [docs/plugin-architecture.md](../docs/plugin-architecture.md) |
| Repairing or sharing a worktree | [docs/worktrees.md](../docs/worktrees.md) |
| Adding an MCP client descriptor | [docs/client-configuration.md](../docs/client-configuration.md) |

## Claude-specific notes

- Claude Code sessions may run in `.claude/worktrees/<name>`. The worktree and
  editor-routing guidance in `AGENTS.md` applies; verify the active worktree and
  connected Godot `test_project/` before editing or testing plugin code.
- Skills under `.claude/skills/` must be named exactly `SKILL.md` — discovery is
  case-sensitive, and a lowercase `skill.md` is silently never loaded. Add one
  only when it gives access to guidance this file does not already carry; a
  skill that merely repeats `CLAUDE.md` costs a listing entry and returns
  nothing.
- When updating general repo operating guidance, update `AGENTS.md` first. Keep
  this file limited to Claude-specific loading behavior and reminders.
