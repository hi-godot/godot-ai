# Dedicated poteto session

Use this entry point only when the user selects a poteto session, uses a poteto
launcher, or configures `GODOT_AI_POTETO_SESSION=1` in a dedicated environment.
Use poteto-mode for each task in that session until the user turns it off.
Do not change other sessions or persist a new default in user settings.

Read these files from the current checkout, in order:

1. `AGENTS.md` for the repository's current constraints and verification gates.
2. `plugins/pstack-godot/PORTABILITY.md` for the host adaptation.
3. `plugins/pstack-godot/models.md` for inherited-model defaults.
4. `plugins/pstack-godot/upstream/pstack/skills/poteto-mode/SKILL.md` for routing.
5. `docs/poteto-workflow.md` when working on Godot behavior or verification.

Use the bundled leaf skills and playbooks by path as the adapter describes.
An installed plugin is convenient for the skill picker, but is not required
to read these repository files. Do not assume local plugins, personal settings,
tools, or credentials were transferred into a remote session.

At session start, report the checkout branch and the available verification
surface. If the startup request contains no task, confirm the mode and wait
for one; do not invent work. For each task, use the selected model, host
permissions, and available concurrency. Report unavailable independent reviews
or live editor checks honestly. Do not substitute a self-review for another
agent or Python mocks for Godot execution.

In hosted cloud workers, inspect the existing environment setup and repository
verification instructions before installing dependencies. A cloud worker does
not have access to the user's local Godot editor. Never expose Godot's loopback
transport to make it reachable. If live editor verification is required, use
a supported editor environment on that worker or report the exact missing gate.

Store personal settings, private receipts, and runtime records only in ignored
local files. Mode activation does not authorize publication, merging, messages,
or relaxed permissions beyond the task's existing authorization.
