---
name: principle-minimize-reader-load
description: Apply when reviewing or shaping code that's hard to trace. Count layers between question and answer, and hidden state in the reader's head; collapse one-caller wrappers and shrink mutable scope.
---

Read [the host adapter](../../PORTABILITY.md) first. Then read and apply
[the upstream principle-minimize-reader-load skill](../../upstream/pstack/skills/principle-minimize-reader-load/SKILL.md)
under that adapter. Resolve all routed skills through this same bundle.
