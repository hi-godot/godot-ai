@tool
extends McpTestSuite

## Tests for SignalHandler — signal listing, connecting, and disconnecting.

var _handler: SignalHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "signal"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = SignalHandler.new(_undo_redo)


# ----- list_signals -----

func test_list_signals_returns_signals() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var path := "/" + scene_root.name
	var result := _handler.list_signals({"path": path})
	assert_has_key(result, "data")
	assert_has_key(result.data, "signals")
	assert_has_key(result.data, "signal_count")
	assert_gt(result.data.signal_count, 0, "Root node should have signals")


func test_list_signals_missing_path() -> void:
	var result := _handler.list_signals({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_list_signals_unknown_node() -> void:
	var result := _handler.list_signals({"path": "/NonExistentNode"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_list_signals_no_scene() -> void:
	## If no scene is open this should report EDITOR_NOT_READY.
	## We can't easily test this in-editor since a scene is always open,
	## so just verify the path validation works.
	var result := _handler.list_signals({"path": "/BogusRoot/BogusChild"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_list_signals_hides_editor_internal_connections_by_default() -> void:
	## Bug #213: SceneTreeEditor observers connect to every scene node and
	## previously surfaced as user-authored connections. Default filter
	## drops connections whose target is outside the edited scene tree.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var path := "/" + scene_root.name
	var result := _handler.list_signals({"path": path})
	assert_has_key(result, "data")
	assert_has_key(result.data, "connections")
	assert_has_key(result.data, "editor_connection_count")
	for conn in result.data.connections:
		var target_path: String = conn.target
		assert_false(target_path.contains("SceneTreeEditor"),
			"Editor-internal SceneTreeEditor connection leaked into default list: %s" % target_path)
		assert_false(target_path.contains("DockSlot"),
			"Editor-internal dock connection leaked into default list: %s" % target_path)


func test_list_signals_include_editor_surfaces_internal_connections() -> void:
	## Opt-in flag returns the editor-side connections that the default
	## filter hides. On a real editor scene there's almost always at least
	## one — assert the include_editor count is >= the default count.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var path := "/" + scene_root.name
	var default_result := _handler.list_signals({"path": path})
	var full_result := _handler.list_signals({"path": path, "include_editor": true})
	assert_has_key(full_result, "data")
	assert_true(full_result.data.connection_count >= default_result.data.connection_count,
		"include_editor should not hide any user connections")


func test_is_editor_internal_target_keeps_autoload_targets() -> void:
	## Bug #213 review: autoload singletons live under /root/<Name>, which
	## is outside the edited scene tree, so a naive "outside scene_root"
	## filter would also hide legitimate connections to autoloads. The
	## ``autoload/<name>`` ProjectSetting whitelist must keep them visible.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return

	## Inject a fake autoload entry and a Node sitting where an autoload
	## would live (parented under a freestanding Node so we don't touch the
	## edited scene). The Node's ``name`` matches the autoload key.
	var setting_key := "autoload/_TestAutoloadFilter"
	var had_before := ProjectSettings.has_setting(setting_key)
	var before_value: Variant = ProjectSettings.get_setting(setting_key) if had_before else null
	ProjectSettings.set_setting(setting_key, "*res://tests/does_not_exist.gd")

	var fake_autoload := Node.new()
	fake_autoload.name = "_TestAutoloadFilter"
	var unrelated_target := Node.new()
	unrelated_target.name = "_NotAnAutoload"
	## Don't add to tree — the helper only needs the Node + a name + the
	## ProjectSettings entry to classify it.

	assert_false(_handler._is_editor_internal_target(fake_autoload, scene_root),
		"Autoload-named node should NOT be classified as editor-internal")
	assert_true(_handler._is_editor_internal_target(unrelated_target, scene_root),
		"Non-autoload node outside the edited scene SHOULD be editor-internal")

	fake_autoload.free()
	unrelated_target.free()
	if had_before:
		ProjectSettings.set_setting(setting_key, before_value)
	else:
		ProjectSettings.set_setting(setting_key, null)


# ----- connect_signal -----

func test_connect_signal_missing_params() -> void:
	var result := _handler.connect_signal({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.connect_signal({"path": "/Main"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.connect_signal({"path": "/Main", "signal": "ready"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.connect_signal({"path": "/Main", "signal": "ready", "target": "/Main"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_connect_signal_unknown_source() -> void:
	var result := _handler.connect_signal({
		"path": "/NoSuchNode",
		"signal": "ready",
		"target": "/Main",
		"method": "_ready",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- disconnect_signal -----

func test_disconnect_signal_missing_params() -> void:
	var result := _handler.disconnect_signal({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_disconnect_signal_not_connected() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var path := "/" + scene_root.name
	var result := _handler.disconnect_signal({
		"path": path,
		"signal": "ready",
		"target": path,
		"method": "_nonexistent_method",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- Friction fix: autoload resolution -----

func test_connect_signal_autoload_not_found() -> void:
	# An autoload name that doesn't exist should produce a clear error.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.connect_signal({
		"path": "NonExistentAutoload",
		"signal": "ready",
		"target": "/" + scene_root.name,
		"method": "queue_free",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not found")


func test_connect_signal_declared_but_uninstantiated_autoload() -> void:
	# An autoload declared in ProjectSettings but not instantiated at editor
	# time (the common case) should produce a specific error that points the
	# user at the right workaround, not a generic "not found".
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	# Inject a fake autoload entry pointing to a script path that isn't loaded.
	# We don't actually register it with the editor — just set the setting so
	# our resolver's declared-but-uninstantiated branch fires.
	var setting_key := "autoload/TestGhostAutoload"
	var had_before := ProjectSettings.has_setting(setting_key)
	var before_value: Variant = ProjectSettings.get_setting(setting_key) if had_before else null
	ProjectSettings.set_setting(setting_key, "*res://tests/does_not_exist.gd")

	var result := _handler.connect_signal({
		"path": "TestGhostAutoload",
		"signal": "ready",
		"target": "/" + scene_root.name,
		"method": "queue_free",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	# Error should mention "autoload" and guidance (@onready or runtime).
	assert_contains(result.error.message, "autoload")
	assert_contains(result.error.message, "runtime")

	# Cleanup — restore previous setting state.
	if had_before:
		ProjectSettings.set_setting(setting_key, before_value)
	else:
		ProjectSettings.set_setting(setting_key, null)
