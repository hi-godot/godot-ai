---
name: principle-migrate-callers-then-delete-legacy-apis
description: Apply when introducing a new internal API while old callers still exist. Migrate callers and delete the old API in the same wave instead of preserving compatibility layers.
---

Read [the host adapter](../../PORTABILITY.md) first. Then read and apply
[the upstream principle-migrate-callers-then-delete-legacy-apis skill](../../upstream/pstack/skills/principle-migrate-callers-then-delete-legacy-apis/SKILL.md)
under that adapter. Resolve all routed skills through this same bundle.
