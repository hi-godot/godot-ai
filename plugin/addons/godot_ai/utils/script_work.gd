@tool
extends RefCounted

## A response timeout is not proof that its coroutine has returned. Track
## actual script execution across frame yields, independently of transport
## bookkeeping. This is process-wide deliberately: an older composition may
## still own a coroutine in the same scripts after an ordinary plugin reload.
## Only the main thread may use this ledger; OS workers have separate joins.
static var _next_id := 0
static var _active: Dictionary = {}


static func begin(label: String) -> int:
	_next_id += 1
	_active[_next_id] = label
	return _next_id


static func finish(id: int) -> void:
	_active.erase(id)


static func quiescence() -> Dictionary:
	if not _active.is_empty():
		return {
			"ok": false,
			"error": "Wait for active editor work before updating: %s" % str(_active.values()),
		}
	return {"ok": true}
