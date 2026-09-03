# Native GLES environment/undo shutdown reproduction

This standalone Godot project contains **no Godot AI code**. It reproduces
the 349,524-byte GL texture diagnostics investigated during PR #949. It is
diagnostic evidence, not a release qualification test or a waiver.

Copy this directory to a disposable location before running it: the native
control plugin writes `main.tscn`, edits that scene in memory and quits its
own editor. Do not enable the control plugin in a user project.

```sh
CONTROL_COUNT=1 CONTROL_CLEAR=immediate CONTROL_FREE=queued \
  /path/to/Godot --editor --path /path/to/disposable-copy \
  --rendering-method gl_compatibility --verbose
```

Use a graphical editor, not `--headless`. Wait for `CONTROL COMPLETE` and
normal process exit. A parse error, failed assertion, absent completion
marker, timeout or forced termination invalidates the reproduction.

The control assigns an Environment/Sky/ProceduralSkyMaterial to a native
WorldEnvironment using EditorUndoRedoManager, records its resource references,
removes the node and immediately clears the undo history. No WebSocket,
backend, dispatcher, Godot AI handler or candidate payload participates.

## Observed controls — macOS, September 3, 2026 UTC

Each row used one environment and exited normally. Counts below are only
the exact `leaked 349524 bytes` diagnostic, not a claim of zero other output.

| Official Godot build | `CONTROL_CLEAR` | `CONTROL_FREE` | Texture warnings |
|---|---|---|---|
| 4.7.2 | immediate | queued | 2 |
| 4.7.2 | deferred | queued | 0 |
| 4.7.2 | none | queued | 0 |
| 4.7.2 | immediate | immediate | 2 |
| 4.7.0 | immediate | queued | 2 |

`deferred` waits two process frames before clearing history. `none` retains
the history until editor exit. The original eight-environment immediate-clear
run emitted sixteen warnings. The single unclaimed `Node` StringName at exit
also occurs in native-only controls and is a separate diagnostic.

This isolates an engine-native reproduction and a cleanup-timing interaction;
it does not establish the internal engine cause, prove bounded impact during
long sessions, or establish equivalent behavior on other operating systems.
In particular, the no-warning controls are **not** permission to split the
full suite, add arbitrary waits to production or suppress the diagnostic.

The Godot AI combined-suite bisection narrowed the same warning to running
`environment` and then `gridmap` in one synchronous test request: environment
cleanup queues node deletion while gridmap teardown clears the shared undo
history. Environment plus input, environment plus game_helper, and gridmap
alone did not reproduce it. All diagnostic filters were confined to a
disposable clone and removed before the unchanged full-suite regression run.

Local source/log evidence: `/private/tmp/godot-native-env-undo.RSY4FG`, including
`matrix-summary.log` and the five version/clear/free logs. Pair-bisection logs
are under `/private/tmp/godot-ai-release-build.szEA2o/gles-pair-*.log`.
The retained project was copied into another fresh directory and verified on
4.7.2: `/private/tmp/godot-native-env-durable.EQx13z/editor.log` records normal
completion and the same two warnings, without earlier errors.
These temporary development logs are not the immutable qualification bundle.

Next disposition: retain this reproducer for engine review and determine
whether a justified ownership/cleanup correction is needed. No upstream issue
or engine fix is claimed by this document. All release gates remain intact.
