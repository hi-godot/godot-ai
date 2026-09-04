# Decisions and current work

<!-- Written by `knos export`. Commit this file. -->

<!--
Reading this file needs nothing installed: it is plain markdown, and a fresh
clone picks it up as-is. The live claim/withhold server is a separate, optional
step - `pip install knos` (Python 3.10+), which the MCP entry launches as
`python -m knos.mcp`. Without it, everything below still reads normally.
-->


A second clone reads this on its first question — it is one of the decision
records knos looks for. Nothing here is private: secrets and private paths
never reach it.


## Decisions

- **AGENTS.md is the source of truth** — Project structure, workflow, tool changes, testing and worktree safety live in `AGENTS.md`. Update it first when changing general operating guidance.  _(.claude/CLAUDE.md)_
- **no tokenless fallback** — WebSocket stays loopback-only and HTTP localhost-first, but neither relies on loopback as authentication. Never add tokenless, bare-URL, or legacy-handshake fallback.  _(AGENTS.md, Architecture)_
- **handshake fails closed** — Missing or wrong capabilities, protocol-1 frames, duplicate keys and downgrade attempts all fail closed.  _(AGENTS.md, Architecture)_
- **writes check readiness first** — Python write handlers must `await require_writable_async()`, and every new plugin response builder stamps the envelope-level `readiness` field. `EDITOR_NOT_READY` is frozen as a top-level code; never promote a `data.sub_code` into `error.code`.  _(AGENTS.md, Architecture)_
- **middleware order is load-bearing** — `src/godot_ai/middleware/` registration order matters; see Key conventions before reordering.  _(AGENTS.md, Project structure)_
- **skills must be named SKILL.md** — Discovery is case-sensitive and a lowercase `skill.md` is silently never loaded.  _(.claude/CLAUDE.md)_
- **verify the active worktree before editing plugin code** — Claude Code sessions may run in `.claude/worktrees/<name>`; check the active worktree and the connected Godot `test_project/` first.  _(.claude/CLAUDE.md)_

## Being worked on right now

_Nothing claimed._

---
<sub>knos export. Claims lapse after 30 minutes.</sub>
