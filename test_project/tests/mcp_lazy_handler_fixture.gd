@tool
extends RefCounted

## Fixture for McpDispatcher lazy-registration tests (#736): a minimal
## handler the dispatcher constructs via load() + callv("new", ctor_args)
## at first dispatch. `prefix` proves ctor args arrive; `calls` proves the
## instance is cached and shared across commands of one handler key.

var prefix: String
var calls := 0


func _init(fixture_prefix: String = "") -> void:
	prefix = fixture_prefix


func echo(params: Dictionary) -> Dictionary:
	return {"data": {"echo": prefix + str(params.get("value", ""))}}


func count(_params: Dictionary) -> Dictionary:
	calls += 1
	return {"data": {"calls": calls}}


func malformed(_params: Dictionary) -> Dictionary:
	return {}
