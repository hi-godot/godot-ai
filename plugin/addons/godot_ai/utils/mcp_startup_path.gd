@tool
class_name McpStartupPath
extends RefCounted

## Branch-tag enum for `McpServerLifecycleManager.start_server`. Records
## which arm of the spawn / adopt / drift / recover decision tree the
## current `_enter_tree` walked. Surfaced via the startup trace log so
## a Windows port-reservation issue or a stale-record kill can be
## reconstructed from the editor output.
##
## Single-file constants, not an int enum, because the values land in
## startup-trace text and the strings are stable across releases (the
## CLAUDE.md "tool surface" entry references them by name).

const UNSET := ""
## Re-entrancy guard fired; this enable cycle did not spawn or adopt.
const GUARDED := "guarded"
## Adopted a compatible existing server (managed or external).
const ADOPTED := "adopted"
## Spawned a fresh server process.
const SPAWNED := "spawned"
## OS.create_process returned -1 or proactive Windows reservation
## detected. Either way the spawn never produced a live process.
const CRASHED := "crashed"
## Windows port-exclusion check fired — port is blocked at the OS layer.
const RESERVED := "reserved"
## Server-command discovery returned an empty list — no .venv, no uvx,
## no system godot-ai.
const NO_COMMAND := "no_command"
## Drift-recovery kill fell through; we set INCOMPATIBLE and stayed.
const INCOMPATIBLE := "incompatible"
## Port was free at start; this is the prelude to SPAWNED but kept as
## a distinct path so adopt-vs-spawn is unambiguous in the trace.
const FREE := "free"
