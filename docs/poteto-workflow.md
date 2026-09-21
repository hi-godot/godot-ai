# Poteto workflow for Godot AI

This project applies the poteto approach by starting with a failed user journey,
measuring it in a real editor, and making the smallest change that removes the
demonstrated failure or duplicated work. Simpler code is useful when it makes
startup, connection, updating, and recovery easier to understand and verify.

## Working loop

1. Name the observable outcome before editing: a usable authenticated connection,
   an update that retains the editor, or recovery without losing scene state.
   Record the allowed editor/client restarts separately.
2. Reproduce on an isolated project using a relevant published starting version.
   Record plugin, backend, client bridge, engine, process identity, and source or
   artifact hashes. A new version label is not proof that new code runs.
3. Measure the complete journey, then its components. Use comparable caches,
   observation schedules, and endpoints; interleave comparison arms when
   practical. Preserve slow runs and failures. An optimization must improve the
   whole journey, not merely its isolated microbenchmark.
4. Remove unnecessary work or duplicated ownership decisions. Preserve required
   signature checks, exact-tree verification, authentication, loopback binding,
   process identity, and bounded recovery. Do not trade those boundaries for a
   shorter happy path.
5. Verify during implementation in a rendered editor. Inspect startup and every
   relevant reload/update, including failed states. Ordinary unchanged timing
   repetitions use sampled screenshots plus continuous error monitoring; a
   screenshot must actually be inspected. Keep capture outside measured startup.
6. Turn demonstrated failures into meaningful regressions. Exercise changed code,
   retained typed state and undo callbacks, authenticated tool responses, and
   the exact ordering boundary involved. Where feasible, show that the old
   implementation fails the new test.
7. Finish the repository gauntlet and feature-specific smoke before committing.
   Publish one coherent milestone per PR. Retain exact validation results and
   describe incomplete production or platform qualification explicitly.
8. Close disposable editors and clients after inspection. Remove generated
   caches only after exit; retain compact evidence. Exclude isolated cache and
   settings directories from the project scanner before its first launch.

## What this produced

- PR #1039 repairs Windows startup and lifecycle recovery without another
  transport rewrite. It removes redundant connection/proof work while retaining
  ownership checks. Measurements and their limits are in
  [the milestone-one review](lifecycle-review-2026-09.md). That document is a
  historical checkpoint; its next priorities are not the current completion list.
- PR #1042 addresses published-v3 upgrades with connected clients and Windows
  port reservation handling.
- PR #1043 restores in-editor activation through a shared independent runner.
  It waits for actual scan completion, keeps old script graphs usable for undo,
  and loads the verified replacement at canonical paths. The already-shipped
  4.0.4 updater still restarts on its first hop; the new updater and new v3
  capsule retain the editor. See [self-update](self-update.md).

## Reusable procedures and tests

- [Verification procedure](verification.md): full checks, visible-editor cadence,
  published-version scenarios, isolation, evidence, and cleanup.
- `script/local-self-update-smoke`: local signed update and migration fixtures.
- `tests/integration/_self_update_fixture.py`: shared real-editor test support.
- `tests/integration/test_self_update_upgrade_paths.py`: update, migration,
  continuity, connection, and recovery scenarios.
- `tests/integration/test_migration_bridge_failures.py`: activation ordering,
  successive script generations, and failure-path regressions.
- `test_project/tests/test_update_activation.gd` and `test_dock.gd`: live
  activation and dock behavior checks.
- `script/stormtest.py`: concurrent tool calls and reload churn; see
  [stress testing](STRESS_TESTING.md).
- `.github/workflows/ci.yml`: automated platform checks, including Linux
  real-editor updater scenarios under Xvfb.

## Evidence and remaining portability work

The Windows session's raw receipts live in its owned worktree at
`.pstack-local/lifecycle/`, `.pstack-local/m2/`, `.pstack-local/m3/`, and
`.pstack-local/m4/`.
They contain experiment commands, source substitution manifests, logs, test
results, screenshots, PID/version records, and cleanup receipts. They are
untracked local evidence, not a repository backup or a production release
qualification bundle. Some fixture directories contain private runtime records;
do not publish or broadly stage this directory.

The manual 3.2.5 -> 4.0.5 -> simulated 4.0.6 Windows preparations and observers
are also local under `.pstack-local/m3/`. An independent Linux cloud run reported
the rendered two-hop sequence passing with authenticated reads, reversible
writes, retained scene/selection, and cross-update undo/redo after installing
missing listener-discovery tools. Its initial failure and successful rerun are
separate evidence. Portable fixture preparation does not itself automate the
entire native-button sequence; do not call preparation a complete CI gate.

Local signing keys, redirected delivery, and version-stamped candidate runtimes
exercise implementation behavior. They do not replace qualification against
the exact production-signed release artifacts. Follow the existing release
contract for that final check.
