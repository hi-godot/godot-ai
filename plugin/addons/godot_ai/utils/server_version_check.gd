@tool
class_name McpServerVersionCheck
extends RefCounted

## Standalone polling seam for the post-connection server-version
## handshake gate. Extracted from `plugin.gd` so the lifecycle manager
## stays focused on spawn/adopt/stop and the version-verify dance has
## its own home.
##
## The seam itself does NOT transition `McpServerState` on arm/disarm —
## the version check runs concurrently with whatever spawn-state the
## caller had latched (typically FOREIGN_PORT during adoption
## confirmation, or no-op directly to READY for a fresh spawn). Result
## transitions land on the manager via `handle_server_version_verified`
## (READY / INCOMPATIBLE) or `handle_server_version_unverified`
## (INCOMPATIBLE on deadline expiry); arm() leaves the state alone so a
## FOREIGN_PORT diagnosis isn't accidentally cleared before the
## handshake actually arrives.
##
## Owns the deadline timer (`_deadline_ms`) and requires the manager to
## feed it `tick(now_msec)` from the plugin's `_process` while
## `is_active()` is true.
##
## Decoupled from the connection's signal surface — `tick()` polls
## `_connection.is_connected` and `_connection.server_version` directly
## — for the same parse-hazard reason `plugin.gd` polls instead of
## subscribing: a self-update that adds a new signal to McpConnection
## would crash the re-enabled plugin's `_enter_tree` until restart. We
## still null-check `_connection` because `disarm()` releases it.

## How long to wait after the WebSocket opens before declaring the
## handshake_ack overdue. Mirrors `plugin.gd::SERVER_HANDSHAKE_VERSION_TIMEOUT_MS`
## — kept at this layer so the version-check seam is self-contained.
const TIMEOUT_MS := 5 * 1000

## Untyped on purpose for the same self-update parse-hazard reason
## plugin.gd's fields are untyped. `_connection` is the live
## `McpConnection`; `_manager` is `McpServerLifecycleManager`.
## `_connection` is null between disarm() and the next arm() — the
## seam can spend most of the plugin's life dormant and we don't want
## to pin a Node that may be queue_freed in `_exit_tree`. `_manager` is
## set once at construction and held for the seam's lifetime (the
## manager owns this instance, so the cycle is short).
var _connection
var _manager
var _active: bool = false
var _deadline_ms: int = 0
var _expected_version: String = ""


func _init(manager) -> void:
	_manager = manager


## Arm the version-check. Marks the seam active, (re)attaches the
## connection it should poll, and starts watching for
## `_connection.server_version`. Does NOT transition manager state —
## the version check runs concurrently with whatever spawn-state was
## latched (e.g. FOREIGN_PORT during adoption confirmation, READY for
## a fresh spawn). Result transitions land on the manager via
## `handle_server_version_verified` / `_unverified` once the handshake
## (or its deadline) lands.
##
## The deadline starts the moment the connection actually opens, not at
## arm-time, because uvx cold-starts can take ~30s to bind the
## WebSocket and we don't want to count that against the handshake.
func arm(connection, expected_version: String) -> void:
	_active = true
	_deadline_ms = 0
	_expected_version = expected_version
	_connection = connection


## Disarm without firing a verdict. Used when the manager moves on
## (e.g. recovery click → STOPPING). Releases the connection /
## manager references so the seam doesn't pin them past the active
## window — the plugin can spend most of its life with the version
## check disarmed, and `_connection` is a Node that may be queue_free'd
## by `_exit_tree`. Caller has already transitioned state, so we don't
## touch the manager.
func disarm() -> void:
	_active = false
	_deadline_ms = 0
	_connection = null


## True while the version-check needs `_process` ticks. Plugin uses
## this to gate `set_process(true)`.
func is_active() -> bool:
	return _active


## Per-frame tick from the plugin's `_process`. No-op when disarmed.
## Returns true when the check finished this tick (verified or
## unverified) so the plugin can re-evaluate `set_process` enable.
func tick(now_msec: int) -> bool:
	if not _active:
		return false
	if _connection == null:
		return false
	if not bool(_connection.is_connected):
		return false
	if _deadline_ms == 0:
		_deadline_ms = now_msec + TIMEOUT_MS
	var server_version := str(_connection.server_version)
	if not server_version.is_empty():
		_complete_with_version(server_version)
		return true
	if now_msec >= _deadline_ms:
		_complete_unverified()
		return true
	return false


## Invoked when `_on_connection_established` notices that we transitioned
## out of FOREIGN_PORT — the server may yet prove itself compatible.
## Re-arming is idempotent: if already active, no-op; otherwise the
## caller's connection + last-known expected version are reused.
func rearm_for_foreign_port_recovery(connection) -> void:
	if _active:
		return
	arm(connection, _expected_version)


func _complete_with_version(version: String) -> void:
	_active = false
	_deadline_ms = 0
	if _manager != null:
		_manager.handle_server_version_verified(_expected_version, version)


func _complete_unverified() -> void:
	_active = false
	_deadline_ms = 0
	if _manager != null:
		_manager.handle_server_version_unverified(_expected_version)
