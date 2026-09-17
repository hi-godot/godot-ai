---
name: principle-separate-before-serializing-shared-state
description: Apply when concurrent actors might write to the same file, branch, key, or state object. Eliminate the sharing first; serialize structurally only when one shared writer is a real invariant.
---

Read [the host adapter](../../PORTABILITY.md) first. Then read and apply
[the upstream principle-separate-before-serializing-shared-state skill](../../upstream/pstack/skills/principle-separate-before-serializing-shared-state/SKILL.md)
under that adapter. Resolve all routed skills through this same bundle.
