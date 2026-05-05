@tool
extends McpTestSuite

const SignalHandler := preload("res://addons/godot_ai/handlers/signal_handler.gd")

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
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)


func test_list_signals_unknown_node() -> void:
	var result := _handler.list_signals({"path": "/NonExistentNode"})
	assert_is_error(result)


func test_list_signals_no_scene() -> void:
	## If no scene is open this should report EDITOR_NOT_READY.
	## We can't easily test this in-editor since a scene is always open,
	## so just verify the path validation works.
	var result := _handler.list_signals({"path": "/BogusRoot/BogusChild"})
	assert_is_error(result)


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


func test_is_editor_internal_target_keeps_autoload_descendants() -> void:
	## Copilot review on #222: the previous filter only allowed autoload
	## *roots*. Connections targeting a node *under* an autoload (e.g.
	## /root/MyAutoload/Child) were misclassified as editor-internal and
	## hidden from list_signals. Exercise the detached parent-chain
	## fallback used by the helper when the fixture isn't reachable from
	## /root — the real production path (in-tree autoloads with
	## /root/<Name>/... paths) is exercised by the underlying
	## ProjectSettings + Node.get_path() machinery.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return

	var setting_key := "autoload/_TestAutoloadDescendants"
	var had_before := ProjectSettings.has_setting(setting_key)
	var before_value: Variant = ProjectSettings.get_setting(setting_key) if had_before else null
	ProjectSettings.set_setting(setting_key, "*res://tests/does_not_exist.gd")

	## Detached fixture: child whose parent name matches the autoload key.
	var fake_parent := Node.new()
	fake_parent.name = "_TestAutoloadDescendants"
	var detached_child := Node.new()
	detached_child.name = "Child"
	var detached_grandchild := Node.new()
	detached_grandchild.name = "GrandChild"
	fake_parent.add_child(detached_child)
	detached_child.add_child(detached_grandchild)

	## Sanity-check the fixture before exercising the helper, so a setup
	## regression doesn't masquerade as a logic bug.
	assert_true(ProjectSettings.has_setting(setting_key),
		"setup: autoload setting should be present after set_setting")
	assert_eq(detached_child.get_parent(), fake_parent,
		"setup: detached_child.get_parent() should be fake_parent")

	assert_false(_handler._is_editor_internal_target(detached_child, scene_root),
		"Direct autoload child should NOT be classified as editor-internal")
	assert_false(_handler._is_editor_internal_target(detached_grandchild, scene_root),
		"Deeper autoload descendant should NOT be classified as editor-internal")

	fake_parent.free()
	if had_before:
		ProjectSettings.set_setting(setting_key, before_value)
	else:
		ProjectSettings.set_setting(setting_key, null)


func test_format_target_path_uses_absolute_for_non_descendants() -> void:
	## Copilot review on #222: when list_signals surfaces a connection
	## targeting a non-descendant (e.g. an autoload subtree) the previous
	## McpScenePath.from_node() output was a scene-relative path with ``..``
	## segments like ``/Main/../../root/MyAutoload/Child`` — unparseable for
	## agents and not round-trippable through scene-path resolution. The
	## new formatter emits the canonical absolute SceneTree path for
	## non-descendants instead.
	##
	## We use the editor's own base Control as a guaranteed-in-tree node
	## that lives outside the edited scene; mutating /root from a test is
	## fragile in editor context, so we read from existing tree nodes only.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var base := EditorInterface.get_base_control()
	if base == null or not base.is_inside_tree():
		skip("Editor base control not available")
		return
	if scene_root.is_ancestor_of(base):
		skip("base control is inside edited scene — fixture invalid")
		return

	var formatted := SignalHandler._format_target_path(base, scene_root)
	assert_eq(formatted, str(base.get_path()),
		"Non-descendant in-tree target should serialize as its absolute SceneTree path, got: %s" % formatted)
	assert_true(formatted.begins_with("/root/"),
		"Absolute SceneTree path should start with /root/, got: %s" % formatted)
	assert_false(formatted.contains(".."),
		"Formatted target path must not contain '..' segments: %s" % formatted)


# ----- connect_signal -----

func test_connect_signal_missing_params() -> void:
	var result := _handler.connect_signal({})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)

	result = _handler.connect_signal({"path": "/Main"})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)

	result = _handler.connect_signal({"path": "/Main", "signal": "ready"})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)

	result = _handler.connect_signal({"path": "/Main", "signal": "ready", "target": "/Main"})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)


func test_connect_signal_unknown_source() -> void:
	var result := _handler.connect_signal({
		"path": "/NoSuchNode",
		"signal": "ready",
		"target": "/Main",
		"method": "_ready",
	})
	assert_is_error(result)


# ----- disconnect_signal -----

func test_disconnect_signal_missing_params() -> void:
	var result := _handler.disconnect_signal({})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)


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
	assert_is_error(result)


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
	assert_is_error(result)
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
	assert_is_error(result)
	# Error should mention "autoload" and guidance (@onready or runtime).
	assert_contains(result.error.message, "autoload")
	assert_contains(result.error.message, "runtime")

	# Cleanup — restore previous setting state.
	if had_before:
		ProjectSettings.set_setting(setting_key, before_value)
	else:
		ProjectSettings.set_setting(setting_key, null)
