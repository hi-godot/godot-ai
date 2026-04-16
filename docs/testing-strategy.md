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

- Python unit and integration tests (3 OS x 2 Python versions)
- Godot-side editor test suites (3 OS via `chickensoft-games/setup-godot@v2` on GitHub Actions runners)
- release-surface smoke, especially install and packaging paths once distribution work is active (3 OS)

### CI hardening measures

- **GDScript validation**: `script/ci-check-gdscript` runs after `--import` and before the editor launches. It scans the import log for `SCRIPT ERROR` / `Parse Error` lines and fails the build immediately if any GDScript file has syntax errors. This catches broken scripts before the test runner starts.
- **Step timeouts**: test and smoke steps have `timeout-minutes` set to prevent CI hangs from frozen Godot processes.
- **Filesystem scan settling**: `script/ci-godot-tests` includes a short sleep after editor startup so the filesystem scan completes and test discovery finds all suites.
- **Resilient test discovery**: `test_handler.gd` catches per-file load errors during `_discover_suites()`. A broken test file does not prevent the rest of the suite from running; errors are reported in the response alongside successful results.
- **Regression diagnostics**: `script/ci-find-regression-range` helps identify which commits introduced a CI regression by binary-searching recent history.

This should stay aligned with the release work in [packaging-distribution.md](packaging-distribution.md).

---

## Future Extensions

Once the project starts targeting more polished game-production workflows, add more verification where it matters:

- screenshot-based regression checks for visibly important surfaces
- runtime-performance spot checks for new diagnostics tools
- benchmark-project smoke checks, especially for the roguelite slice in [implementation-plan.md](implementation-plan.md)

The goal is not maximal test volume. The goal is enough structured proof that the tool surface can keep growing without turning flaky.
