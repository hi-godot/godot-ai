---
name: setup-pstack
description: Configure which models pstack uses per role. Detects your available models and writes an always-applied rule that overrides the skill defaults. Use for /setup-pstack, "configure pstack models", or changing pstack's model choices.
---

Read [the host adapter](../../PORTABILITY.md) and [shared defaults](../../models.md).
Show the current role mapping. Defaults inherit the selected client model.
Ask which roles the user wants to change and confirm real model identifiers
against the current host before writing them. Store personal choices only
in the target repository's ignored `.pstack.local.md`. Verify it is ignored
before writing. Do not write Cursor configuration or edit shared defaults
unless the user explicitly requests a repository-wide change. Panel alias
entries still count as separate reviewers. Verify the saved values and
report where they apply. Existing Godot verification is documented in
`AGENTS.md` and `docs/verification.md`; use it rather than generating a
duplicate harness.
