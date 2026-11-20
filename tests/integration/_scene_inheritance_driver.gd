@tool
extends EditorPlugin

const HOLD_REQUEST := "res://.inheritance-test/hold"
const HOLD_RECEIPT := "res://.inheritance-test/held"

var _held_path := ""


func _enter_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("godot_ai/http_port", ProjectSettings.get_setting("inheritance_test/http_port"))
	settings.set_setting("godot_ai/ws_port", ProjectSettings.get_setting("inheritance_test/ws_port"))
	_enable_addon.call_deferred()


func _enable_addon() -> void:
	if not EditorInterface.is_plugin_enabled("godot_ai"):
		EditorInterface.set_plugin_enabled("godot_ai", true)


## Keep the normal-cache threaded request alive until the Python test has
## made the real MCP activation attempt. A separate receipt makes the race
## deterministic even while Godot is scanning or loading on slower runners.
func _process(_delta: float) -> void:
	var requested := FileAccess.file_exists(HOLD_REQUEST)
	if _held_path.is_empty():
		if not requested:
			if FileAccess.file_exists(HOLD_RECEIPT):
				DirAccess.remove_absolute(HOLD_RECEIPT)
			return
		if FileAccess.file_exists(HOLD_RECEIPT):
			return
		var path := FileAccess.get_file_as_string(HOLD_REQUEST)
		var err := ResourceLoader.load_threaded_request(path, "PackedScene", false, ResourceLoader.CACHE_MODE_REUSE)
		if err != OK:
			_write_receipt(error_string(err))
			return
		_held_path = path

	var status := ResourceLoader.load_threaded_get_status(_held_path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	if not requested:
		ResourceLoader.load_threaded_get(_held_path)
		_held_path = ""
		if FileAccess.file_exists(HOLD_RECEIPT):
			DirAccess.remove_absolute(HOLD_RECEIPT)
	elif not FileAccess.file_exists(HOLD_RECEIPT):
		_write_receipt("loaded" if status == ResourceLoader.THREAD_LOAD_LOADED else str(status))


func _write_receipt(text: String) -> void:
	var receipt := FileAccess.open(HOLD_RECEIPT, FileAccess.WRITE)
	if receipt != null:
		receipt.store_string(text)
