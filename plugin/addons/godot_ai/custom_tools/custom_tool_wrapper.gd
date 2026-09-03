@tool
extends RefCounted

## bridge between dispatcher and addon handler

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

var _spec: McpCustomToolSpec
var _locator: McpServiceLocator
var _handler_instance = null  # lazily loaded from _spec.script_path

func _init(spec: McpCustomToolSpec, locator: McpServiceLocator) -> void:
	_spec = spec
	_locator = locator


func quiesce_for_script_swap() -> Dictionary:
	if _handler_instance == null:
		return {"ok": true}
	if not _handler_instance.has_method("quiesce_for_script_swap"):
		return {
			"ok": false,
			"error": "Custom tool '%s' must provide quiesce_for_script_swap() before hot updates." % _spec.name,
		}
	var result: Variant = _handler_instance.call("quiesce_for_script_swap")
	if not result is Dictionary or result.get("ok") != true:
		return {"ok": false, "error": "Custom tool '%s' still owns active work." % _spec.name}
	return {"ok": true}

## Invoked by dispatcher._call_handler as .call(params) — SINGLE ARG.
## Internally splits into (clean_params, ctx) for the addon handler.
func invoke(params: Dictionary) -> Dictionary:
	## Dock enable/disable gate: a disabled tool is dropped from the
	## catalog push, but a client holding a stale list (or batch_execute)
	## can still name it — reject at dispatch too.
	var registry := McpToolRegistry.get_instance()
	if registry != null and not registry.is_tool_enabled(_spec.name):
		return ErrorCodes.make(ErrorCodes.CUSTOM_TOOL_DISABLED,
			"Custom tool '%s' is disabled in the Godot AI dock" % _spec.name)
	## Readiness gate (https://github.com/hi-godot/godot-ai/issues/781#issuecomment-5036376599 #1): block writes during play/import.
	## Checked BEFORE the lazy load so a gated tool's handler script (and any
	## _init side effects) never runs while the editor is busy.
	var _readiness := McpConnection.get_readiness()
	if _spec.requires_writable and (_readiness == "importing" or _readiness == "playing"):
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "Editor is '%s' — write blocked for custom tool '%s'" % [_readiness, _spec.name])
	if _handler_instance == null:
		var script := load(_spec.script_path) as GDScript
		if script == null:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Cannot load %s" % _spec.script_path)
		_handler_instance = script.new()  # no-arg; per-call context arrives via ctx
	if not _handler_instance.has_method(_spec.method):
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "%s has no method '%s' for custom tool '%s'" % [_spec.script_path, _spec.method, _spec.name])
	## Extract _request_id (dispatcher injected it) and strip from params
	## so the addon sees clean params matching its declared schema (https://github.com/hi-godot/godot-ai/issues/781#issuecomment-5036376599 #2).
	var request_id: String= params.get("_request_id", "")
	var clean_params := params.duplicate()
	clean_params.erase("_request_id")
	## Construct ctx with transport metadata + live-object locator.
	var ctx := McpCallContext.new()
	ctx.request_id = request_id
	ctx.session_id = _locator.get_connection().get_session_id()
	ctx.spec = _spec
	ctx.attach_locator(_locator)
	ctx.deadline_msec = Time.get_ticks_msec() + _spec.timeout_ms
	var result: Dictionary = _handler_instance.call(_spec.method, clean_params, ctx)
	if result.get("_deferred", false):
		## Enforce the declared contract: batch_execute and the server's
		## timeout budget both trust spec.deferred, so a non-deferred spec
		## whose handler defers anyway would report success while its real
		## reply arrives uncorrelated later.
		if not _spec.deferred:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
				"Custom tool '%s' returned a deferred response but its spec declares deferred=false" % _spec.name)
		if _spec.timeout_ms > 0:
			## Handlers return the SHARED McpDispatcher.DEFERRED_RESPONSE
			## const, which Godot makes read-only — stamping the per-spec
			## budget on it directly is a script error that aborts the call.
			result = result.duplicate()
			result["_deferred_timeout_ms"] = _spec.timeout_ms
	return result
