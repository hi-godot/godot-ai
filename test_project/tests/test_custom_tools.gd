@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const CustomToolWrapper := preload("res://addons/godot_ai/custom_tools/custom_tool_wrapper.gd")

## Tests for the custom-tool surface: spec budgets, registry
## register/collide/replace/unregister, the wrapper's invoke contract
## (clean params, ctx wiring, deferred stamping on a COPY of the shared
## DEFERRED_RESPONSE const), and the dispatcher's shared-lazy-key
## unregister guard.

const FIXTURE_PATH := "res://tests/mcp_custom_tool_fixture.gd"
const LAZY_FIXTURE_PATH := "res://tests/mcp_lazy_handler_fixture.gd"
const SOURCE_CFG := "res://addons/godot_ai/plugin.cfg"

var _saved_registry_instance: McpToolRegistry = null
var _connection: McpConnection = null
var _saved_disabled_meta: PackedStringArray = PackedStringArray()


class DrainableTool:
	extends RefCounted
	var result: Variant = {"ok": true}
	func quiesce_for_script_swap() -> Variant:
		return result


func suite_name() -> String:
	return "custom_tools"


func suite_setup(_ctx: Dictionary) -> void:
	## Fresh registries in these tests call setup(), which hijacks the
	## static singleton the live plugin owns — snapshot and restore it so
	## the rest of the suite run sees the real one.
	_saved_registry_instance = McpToolRegistry.get_instance()
	_connection = McpConnection.new()
	## Captured here and restored in suite_teardown so a mid-test assertion
	## failure can't leave disabled_custom_tools polluted for later tests
	## or the live dock.
	_saved_disabled_meta = _project_meta_disabled()


func suite_teardown() -> void:
	McpToolRegistry._instance = _saved_registry_instance
	EditorInterface.get_editor_settings().set_project_metadata(
		"godot_ai", "disabled_custom_tools", _saved_disabled_meta)
	if _connection != null:
		_connection.free()
		_connection = null


func _make_locator() -> McpServiceLocator:
	var locator := McpServiceLocator.new()
	locator.setup(_connection, McpLogBuffer.new())
	return locator


func _make_spec(name: String = "fixture_echo", method: StringName = &"echo") -> McpCustomToolSpec:
	var spec := McpCustomToolSpec.new()
	spec.name = name
	spec.description = "test fixture tool"
	spec.script_path = FIXTURE_PATH
	spec.method = method
	spec.source_path = SOURCE_CFG
	spec.timeout_ms = 5000
	return spec


func _make_registry(dispatcher: McpDispatcher) -> McpToolRegistry:
	var registry := McpToolRegistry.new()
	registry.setup(dispatcher, _make_locator())
	return registry


# ----- spec budgets -----

func test_wrapper_requires_explicit_drain_contract_after_instantiation() -> void:
	var wrapper := CustomToolWrapper.new(_make_spec(), _make_locator())
	assert_true(wrapper.quiesce_for_script_swap().ok)
	wrapper._handler_instance = RefCounted.new()
	assert_false(wrapper.quiesce_for_script_swap().ok)
	var handler := DrainableTool.new()
	wrapper._handler_instance = handler
	assert_true(wrapper.quiesce_for_script_swap().ok)
	handler.result = {"ok": false}
	assert_false(wrapper.quiesce_for_script_swap().ok)
	handler.result = "malformed"
	assert_false(wrapper.quiesce_for_script_swap().ok)


func test_spec_validate_accepts_valid_spec() -> void:
	assert_eq(_make_spec().validate().size(), 0, "valid spec must produce no errors")


func test_spec_validate_rejects_oversized_description() -> void:
	var spec := _make_spec()
	spec.description = "x".repeat(McpCustomToolSpec.MAX_DESCRIPTION_CHARS + 1)
	assert_false(spec.validate().is_empty(), "description over budget must be rejected")


func test_spec_validate_measures_schema_in_utf8_bytes() -> void:
	var spec := _make_spec()
	## Multi-byte chars: é is 2 UTF-8 bytes, so half the byte budget in
	## CHARS overflows the budget in BYTES — a char-based check passes it.
	spec.params_schema = {"desc": "é".repeat(McpCustomToolSpec.MAX_SCHEMA_BYTES / 2)}
	assert_false(spec.validate().is_empty(), "schema budget must count UTF-8 bytes, not chars")


func test_spec_validate_rejects_bad_name_and_timeout() -> void:
	var bad_name := _make_spec("not a name!")
	assert_false(bad_name.validate().is_empty(), "invalid identifier must be rejected")
	var bad_timeout := _make_spec()
	bad_timeout.timeout_ms = McpCustomToolSpec.MAX_TIMEOUT_MS + 1
	assert_false(bad_timeout.validate().is_empty(), "timeout over budget must be rejected")


# ----- registry -----

func test_registry_register_and_get_spec() -> void:
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	var registry := _make_registry(dispatcher)
	assert_true(registry.register(_make_spec()), "valid spec must register")
	assert_true(registry.get_spec("fixture_echo") != null, "registered spec must be retrievable")
	assert_true(dispatcher.has_command("custom_tool:fixture_echo"),
		"registration must expose the dispatcher command")


func test_registry_rejects_cross_addon_name_collision() -> void:
	var registry := _make_registry(McpDispatcher.new(McpLogBuffer.new()))
	assert_true(registry.register(_make_spec()))
	## A second addon needs its own real plugin.cfg — fabricate one under
	## user:// (validate() only requires the file to exist).
	DirAccess.make_dir_recursive_absolute("user://imposter_addon")
	var cfg := FileAccess.open("user://imposter_addon/plugin.cfg", FileAccess.WRITE)
	cfg.store_string("[plugin]\nname=\"imposter\"\n")
	cfg.close()
	var imposter := _make_spec()
	imposter.source_path = "user://imposter_addon/plugin.cfg"
	assert_false(registry.register(imposter),
		"same name from a different source_path must be rejected")
	DirAccess.remove_absolute("user://imposter_addon/plugin.cfg")
	DirAccess.remove_absolute("user://imposter_addon")


func test_registry_same_source_replaces() -> void:
	var registry := _make_registry(McpDispatcher.new(McpLogBuffer.new()))
	assert_true(registry.register(_make_spec()))
	var replacement := _make_spec()
	replacement.description = "hot-reloaded"
	assert_true(registry.register(replacement), "same source_path must hot-reload replace")
	assert_eq(registry.get_spec("fixture_echo").description, "hot-reloaded")


func test_registry_unregister_source_drops_all() -> void:
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	var registry := _make_registry(dispatcher)
	registry.register(_make_spec("tool_a"))
	registry.register(_make_spec("tool_b"))
	assert_eq(registry.unregister_source(SOURCE_CFG), 2)
	assert_true(registry.get_spec("tool_a") == null)
	assert_false(dispatcher.has_command("custom_tool:tool_a"),
		"unregister_source must also drop dispatcher commands")


# ----- wrapper -----

func test_wrapper_strips_request_id_and_wires_ctx() -> void:
	var wrapper := CustomToolWrapper.new(_make_spec(), _make_locator())
	var result: Dictionary = wrapper.invoke({"_request_id": "req-1", "value": 7})
	var echoed: Dictionary = result["data"]["echo"]
	assert_eq(echoed.get("value"), 7)
	assert_false(echoed.has("_request_id"), "addon params must not carry transport metadata")
	assert_eq(wrapper._handler_instance.last_ctx.request_id, "req-1")


func test_wrapper_stamps_deferred_timeout_on_a_copy() -> void:
	var spec := _make_spec("fixture_deferred", &"go_deferred")
	spec.deferred = true
	var wrapper := CustomToolWrapper.new(spec, _make_locator())
	var result: Dictionary = wrapper.invoke({"_request_id": "req-2"})
	assert_true(result.get("_deferred", false))
	assert_eq(result.get("_deferred_timeout_ms"), 5000,
		"deferred reply must carry the per-spec budget")
	## Regression pin (#820 review F1): the handler returned the SHARED
	## read-only McpDispatcher.DEFERRED_RESPONSE const — the wrapper must
	## stamp a duplicate, never the const itself (a write to the const is
	## a script error that aborts the call with no response at all).
	assert_false(McpDispatcher.DEFERRED_RESPONSE.has("_deferred_timeout_ms"),
		"shared DEFERRED_RESPONSE const must stay unmodified")


func test_wrapper_rejects_undeclared_deferral() -> void:
	## spec.deferred=false is what batch_execute and the server's timeout
	## budget trust — a handler deferring anyway must be an error, not a
	## success whose real reply arrives uncorrelated later.
	var wrapper := CustomToolWrapper.new(_make_spec("fixture_sneaky", &"go_deferred"), _make_locator())
	var result: Dictionary = wrapper.invoke({})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "deferred=false")


func test_wrapper_reports_missing_method() -> void:
	var wrapper := CustomToolWrapper.new(_make_spec("fixture_bad", &"no_such_method"), _make_locator())
	var result: Dictionary = wrapper.invoke({})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "no_such_method")


# ----- dispatcher shared-lazy-key guard -----

func test_unregister_keeps_shared_lazy_handler_for_siblings() -> void:
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	dispatcher.mcp_logging = false
	dispatcher.register_lazy_handler("shared_key", LAZY_FIXTURE_PATH, ["p:"])
	dispatcher.register_lazy("cmd_a", "shared_key", &"echo")
	dispatcher.register_lazy("cmd_b", "shared_key", &"echo")
	## Materialize the shared instance, then drop one sibling.
	var first: Dictionary = dispatcher.dispatch_direct("cmd_a", {"value": "x"})
	assert_eq(first["data"]["echo"], "p:x")
	dispatcher.unregister("cmd_a", "shared_key")
	assert_false(dispatcher.has_command("cmd_a"))
	var second: Dictionary = dispatcher.dispatch_direct("cmd_b", {"value": "y"})
	assert_eq(second["data"]["echo"], "p:y",
		"sibling command must survive a shared-key unregister")


# ----- dock enable/disable -----

func _project_meta_disabled() -> PackedStringArray:
	var es := EditorInterface.get_editor_settings()
	return PackedStringArray(es.get_project_metadata("godot_ai", "disabled_custom_tools", PackedStringArray()))


func test_registry_disable_filters_catalog_and_persists() -> void:
	var registry := _make_registry(McpDispatcher.new(McpLogBuffer.new()))
	registry.register(_make_spec("tool_on"))
	registry.register(_make_spec("tool_off"))
	registry.set_tool_enabled("tool_off", false)
	var enabled_names: Array = []
	for spec in registry.enabled():
		enabled_names.append(spec.name)
	assert_true(enabled_names.has("tool_on"))
	assert_false(enabled_names.has("tool_off"), "disabled tool must leave the catalog push")
	assert_eq(registry.all().size(), 2, "disabled tool stays registered for the dock list")
	## Persistence: a FRESH registry (plugin reload) re-reads the choice
	## from per-project metadata.
	var reloaded := _make_registry(McpDispatcher.new(McpLogBuffer.new()))
	assert_false(reloaded.is_tool_enabled("tool_off"), "disable must survive a registry reload")
	assert_true(reloaded.is_tool_enabled("tool_on"))
	## Metadata restore happens unconditionally in suite_teardown.
	reloaded.set_tool_enabled("tool_off", true)


func test_wrapper_rejects_disabled_tool() -> void:
	var registry := _make_registry(McpDispatcher.new(McpLogBuffer.new()))
	var spec := _make_spec("fixture_gated")
	registry.register(spec)
	registry.set_tool_enabled("fixture_gated", false)
	var wrapper := CustomToolWrapper.new(spec, _make_locator())
	var result: Dictionary = wrapper.invoke({})
	assert_is_error(result, ErrorCodes.CUSTOM_TOOL_DISABLED)
	registry.set_tool_enabled("fixture_gated", true)
