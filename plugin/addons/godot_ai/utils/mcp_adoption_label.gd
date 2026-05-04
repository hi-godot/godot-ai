@tool
class_name McpAdoptionLabel
extends RefCounted

## Outcome flag for `McpServerLifecycleManager.adopt_compatible_server`.
## Distinguishes a same-version managed adoption (we own the PID, can
## restart it) from an external compatible adoption (some other plugin
## instance / dev server owns the process; we just rendezvoused with it).
##
## Was a free-form string in PR 5; promoted to constants here because
## the seam now spans `server_lifecycle.gd`, `plugin.gd`'s log helper,
## the dock's restart-button gating, and the test suite. Stable strings
## keep log scrapes and characterization fixtures unaffected.

## We have a PID we spawned (or re-acquired by reading the managed
## record + verifying liveness). `force_restart_server` and
## `prepare_for_update_reload` may target this PID.
const MANAGED := "managed"

## A compatible godot-ai server is on the port but we don't own its
## PID — likely another plugin instance's spawn, or a developer-run
## `godot-ai --reload` server. We reuse it but won't kill it on stop.
const EXTERNAL := "external"
