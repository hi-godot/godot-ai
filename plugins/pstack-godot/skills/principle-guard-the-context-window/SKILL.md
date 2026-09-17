---
name: principle-guard-the-context-window
description: 'Apply when context is filling up: large outputs, long files, repeated reads, fan-out planning. Route bulk to subagents; keep summaries in the main thread, not raw payloads.'
---

Read [the host adapter](../../PORTABILITY.md) first. Then read and apply
[the upstream principle-guard-the-context-window skill](../../upstream/pstack/skills/principle-guard-the-context-window/SKILL.md)
under that adapter. Resolve all routed skills through this same bundle.
