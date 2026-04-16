# Godot AI — Testing Strategy

*Updated 2026-04-16*

This document defines how Godot AI should prove that new capability is real, stable, and safe to extend.

Use the related docs for adjacent concerns:

- [proposal.md](proposal.md) for the product case
- [implementation-plan.md](implementation-plan.md) for active priorities
- [packaging-distribution.md](packaging-distribution.md) for release-smoke install coverage

---

## Quality Standard

New capability should not count as shipped just because it works once in a local editor.

The minimum bar is:

- clear tool contract
- automated coverage where the behavior is deterministic
- at least one real-project smoke path for meaningful editor workflows
- error behavior that is intentional and testable

---

## Test Layers

### Unit tests

Use unit tests for:

- request validation
- protocol serialization
- pagination
- session routing
- readiness checks
- error mapping
- runtime handler behavior that does not require a live editor

### Integration tests

Use integration tests for:

- tool orchestration against mocked or controlled plugin responses
- reconnect behavior
- stale reference handling
- partial batch failures
- runtime tool behavior on the Python/server side

### Contract tests

Use contract tests for the plugin/server boundary:

- handshake and versioning
- command envelope shape
- response and error schema
- readiness and capability signaling
- log and job payload consistency

### Godot-side test suites

Use in-editor GDScript suites for:

- scene and node mutation behavior
- signal, autoload, input, and filesystem handlers
- runtime tools like run/stop and screenshots
- any behavior that depends on actual Godot editor APIs or undo semantics

Built-in guardrails:

- **Zero-assertion detection**: the runner flags any test that completes with 0 assertions as a failure. This catches tests that silently `return` early (e.g. when `scene_root == null`) without exercising any logic.
- **Resilient discovery**: if a `.gd` file fails to parse (duplicate methods, syntax errors, wrong base class), the remaining suites still load and run. Failing files are reported in `load_errors` with a reason string.
- **Suite isolation**: each suite receives a fresh `ctx.duplicate()` so `suite_setup()` mutations cannot leak between suites.
- **CI static check**: `script/ci-check-gdscript` runs `godot --check-only` against every `.gd` file before the editor test run, catching parse errors at the gate.

### End-to-end and release-smoke tests

Run real-project smoke tests for:

- opening a project
- connecting the plugin
- creating or mutating scenes and nodes
- attaching scripts
- running and stopping the project
- reading logs or screenshots
- exporting or otherwise exercising the release surface

---

## What New Tool Families Should Add

The expected coverage depends on the surface:

- simple read tools need unit and integration coverage
- write tools need unit coverage plus Godot-side behavioral tests
- runtime or release tools need smoke coverage in addition to targeted tests
- batch or multi-step tools need explicit partial-failure coverage

If a tool has undo semantics, readiness constraints, or cross-session behavior, those should be tested directly rather than hand-waved in the docs.

---

## CI Expectations

The CI stack should exercise at least three tiers:

- Python unit and integration tests
- Godot-side editor test suites
- release-surface smoke, especially install and packaging paths once distribution work is active

This should stay aligned with the release work in [packaging-distribution.md](packaging-distribution.md).

---

## Future Extensions

Once the project starts targeting more polished game-production workflows, add more verification where it matters:

- screenshot-based regression checks for visibly important surfaces
- runtime-performance spot checks for new diagnostics tools
- benchmark-project smoke checks, especially for the roguelite slice in [implementation-plan.md](implementation-plan.md)

The goal is not maximal test volume. The goal is enough structured proof that the tool surface can keep growing without turning flaky.
