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


func test_list_signals_filters_editor_internal_connections() -> void:
	## list_signals should hide connections whose target lives outside the
	## edited scene (editor UI like SceneTreeEditor wires up observers on the
	## scene root). Simulate by parking a Node directly under /root and
	## connecting one of the scene root's signals to it — structurally
	## identical to an editor-internal listener.
	const OBSERVER_NAME := "_McpTestFakeEditorObserver"
	const SIG_NAME := "renamed"  # Stable Node signal — every scene root has it.

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var tree := scene_root.get_tree()
	if tree == null:
		skip("Scene tree unavailable")
		return
	var path := "/" + scene_root.name

	var baseline := _handler.list_signals({"path": path})
	var before_user: int = baseline.data.connection_count
	var before_editor: int = baseline.data.editor_connection_count

	# Capture-then-tear-down-then-assert: gather all values into locals, fully
	# undo the fixture, only then run asserts. Guarantees the fake observer
	# never leaks past this test even if every assertion fails.
	var observer := Node.new()
	observer.name = OBSERVER_NAME
	tree.root.add_child(observer)
	var callable := Callable(observer, "queue_free")
	scene_root.connect(SIG_NAME, callable)

	var result := _handler.list_signals({"path": path})
	var observed_targets: Array = []
	for conn in result.data.connections:
		observed_targets.append(str(conn.target))
	var observed_user_count: int = result.data.connection_count
	var observed_editor_count: int = result.data.editor_connection_count

	scene_root.disconnect(SIG_NAME, callable)
	observer.queue_free()

	for target_str in observed_targets:
		assert_false(target_str.contains(OBSERVER_NAME),
			"connections[] must not include nodes parked outside the edited scene")
	assert_eq(observed_user_count, before_user,
		"User-visible connection count must not include editor-internal listeners")
	assert_eq(observed_editor_count, before_editor + 1,
		"Editor-internal listener should be tallied separately, not in connections[]")


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
