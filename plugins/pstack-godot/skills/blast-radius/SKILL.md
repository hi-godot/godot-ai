---
name: blast-radius
description: Find what a change could break somewhere else before it ships, beyond the diff, and prove the one fact it's safe because of by running real code instead of writing it up. Use for 'blast radius of X', 'what could this break', or reviewing a small diff you don't trust.
---

Read [the host adapter](../../PORTABILITY.md) first. Then read and apply
[the upstream blast-radius skill](../../upstream/pstack/skills/blast-radius/SKILL.md)
under that adapter. Resolve all routed skills through this same bundle.
