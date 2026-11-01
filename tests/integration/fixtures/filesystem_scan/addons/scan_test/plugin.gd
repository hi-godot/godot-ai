@tool
extends EditorPlugin

const Handler := preload("res://addons/godot_ai/handlers/filesystem_handler.gd")
const Work := preload("res://addons/godot_ai/utils/script_work.gd")

class TestConnection extends McpConnection:
	signal response_received(request_id: String, payload: Dictionary)
	var replies: Dictionary = {}

	func _ready() -> void:
		set_process(false)

	func _process(_delta: float) -> void:
		pass

	func send_deferred_response(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload
		response_received.emit(request_id, payload)

var filesystem: EditorFileSystem
var connection: TestConnection
var phase := "startup"
var started := 0
var failed := false
var native_completions := 0
var native_class_updates := 0
var completion_baseline := 0
var class_baseline := 0
var saw_early_idle := false
var immediate_update_done := false

func _enter_tree() -> void:
	filesystem = EditorInterface.get_resource_filesystem()
	filesystem.sources_changed.connect(_on_native_completion)
	filesystem.script_classes_updated.connect(_on_class_update)
	started = Time.get_ticks_msec()
	set_process(true)

func _on_native_completion(_changed: bool) -> void:
	native_completions += 1

func _on_class_update() -> void:
	native_class_updates += 1

func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failed = true
	print("SCAN_TEST FAILURE: ", message)

func _new_connection() -> TestConnection:
	var transport := TestConnection.new()
	transport.response_received.connect(_on_response)
	add_child(transport)
	return transport

func _on_response(request_id: String, payload: Dictionary) -> void:
	if request_id == "withheld_completion":
		_expect(not bool(payload.data.scan_completed), "missing completion was reported as success")
		_expect(payload.data.scan_settle == "timeout", "missing completion did not time out")
		print("SCAN_TEST withheld completion returned timeout")
		return
	_expect(bool(payload.data.scan_completed), "scan did not complete: " + request_id)
	_expect(payload.data.scan_settle == "settled", "unexpected settle status: " + request_id)
	_expect(native_completions > completion_baseline, "reply preceded native completion: " + request_id)
	if phase == "coalesced" and request_id == "primary":
		_expect(native_class_updates > class_baseline, "reply preceded class registration")
		if not failed:
			print("SCAN_TEST immediate update after completed scan reply")
			immediate_update_done = true
			filesystem.update_file("res://scan_sample_0.gd")
	print("SCAN_TEST response ", request_id, " after native completion")

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() - started > 110000:
		print("SCAN_TEST FAILURE: diagnostic deadline exceeded")
		get_tree().quit(1)
		return
	if phase == "startup":
		if filesystem.is_scanning() or Time.get_ticks_msec() - started < 2500:
			return
		phase = "preparing"
		_run_contracts()
	elif phase == "coalesced" and not filesystem.is_scanning() and native_completions == completion_baseline:
		saw_early_idle = true
		_expect(connection.replies.is_empty(), "reply was released in native postprocessing")

func _write_samples(generation: int) -> void:
	for i: int in range(800):
		var file := FileAccess.open("res://scan_sample_%d.gd" % i, FileAccess.WRITE)
		file.store_string("class_name ScanBarrierSample%d\nextends RefCounted\nvar generation: int = %d\n" % [i, generation])
		file.close()

func _begin_case(label: String) -> void:
	phase = label
	completion_baseline = native_completions
	class_baseline = native_class_updates

func _await_reply(request_id: String) -> void:
	while not connection.replies.has(request_id):
		await get_tree().process_frame

func _run_contracts() -> void:
	connection = _new_connection()
	_write_samples(1)
	_begin_case("coalesced")
	Handler.new(connection).scan_filesystem({"_request_id": "primary"})
	Handler.new(connection).scan_filesystem({"_request_id": "joined"})
	var sync_result := Handler.new(null).scan_filesystem({})
	_expect(not sync_result.data.scan_completed, "synchronous scan falsely claimed completion")
	_expect(bool(sync_result.data.was_already_scanning), "synchronous request did not join pending scan")
	await _await_reply("primary")
	await _await_reply("joined")
	if failed:
		_finish()
		return
	_expect(saw_early_idle, "test did not exercise native early-idle postprocessing window")
	_expect(immediate_update_done, "immediate post-reply update was not exercised")
	_expect(bool(connection.replies.joined.data.was_already_scanning), "concurrent request did not join scan")
	var found_class := false
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if entry["class"] == "ScanBarrierSample11":
			found_class = true
	_expect(found_class, "new global script class was unavailable after scan response")

	# No file changes: a fresh native completion must still be observed.
	_begin_case("unchanged")
	Handler.new(connection).scan_filesystem({"_request_id": "unchanged"})
	await _await_reply("unchanged")
	_expect(not bool(connection.replies.unchanged.data.was_already_scanning), "completed scan retained single-flight ownership")

	# Synchronous entry points retain ownership until native completion too.
	_write_samples(2)
	_begin_case("sync_first")
	Handler.new(null).scan_filesystem({})
	Handler.new(connection).scan_filesystem({"_request_id": "sync_first"})
	await _await_reply("sync_first")
	_expect(bool(connection.replies.sync_first.data.was_already_scanning), "deferred caller did not join synchronous scan")

	# Adopt a scan started by the editor rather than this handler.
	_begin_case("external")
	filesystem.scan()
	Handler.new(connection).scan_filesystem({"_request_id": "external"})
	await _await_reply("external")
	_expect(bool(connection.replies.external.data.was_already_scanning), "handler did not adopt an external scan")

	# Disposing a requester must not orphan completion or another request.
	_write_samples(3)
	_begin_case("disconnect")
	Handler.new(connection).scan_filesystem({"_request_id": "discarded"})
	connection.free()
	connection = _new_connection()
	Handler.new(connection).scan_filesystem({"_request_id": "after_disconnect"})
	await _await_reply("after_disconnect")
	await get_tree().process_frame
	_expect(Work.active_count("scan_filesystem") == 0, "disconnected request leaked script work")

	await _run_timeout_contract()
	_finish()

func _finish() -> void:
	phase = "finished"
	connection.queue_free()
	await get_tree().process_frame
	print("SCAN_TEST_RESULT ", "FAIL" if failed else "PASS")
	get_tree().quit(1 if failed else 0)

func _run_timeout_contract() -> void:
	_begin_case("timeout")
	Handler.new(connection).scan_filesystem({"_request_id": "withheld_completion"})
	# Fault injection: hold the actual scan callback past the request deadline.
	# Native work still completes; consumers receive its completion late.
	var held_callback := Callable()
	for item: Dictionary in filesystem.sources_changed.get_connections():
		var callback: Callable = item.callable
		if callback.get_method() == &"_on_scan_completed":
			held_callback = callback
			filesystem.sources_changed.disconnect(callback)
			break
	_expect(held_callback.is_valid(), "could not hold native completion callback")
	if failed:
		return
	await _await_reply("withheld_completion")
	_expect(not bool(Work.quiescence().ok), "timeout incorrectly permitted plugin replacement during native work")
	var late_file := FileAccess.open("res://late_scan_sample.gd", FileAccess.WRITE)
	late_file.store_string("class_name LateScanBarrierSample\nextends RefCounted\n")
	late_file.close()
	Handler.new(connection).scan_filesystem({"_request_id": "after_timeout"})
	held_callback.call_deferred(false)
	await _await_reply("after_timeout")
	_expect(bool(connection.replies.after_timeout.data.was_already_scanning), "timeout released unfinished native scan ownership")
	var found_late_class := false
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if entry["class"] == "LateScanBarrierSample":
			found_late_class = true
	_expect(not found_late_class, "timed-out scan was replaced before late native completion")
	await get_tree().process_frame
	_expect(Work.active_count("scan_filesystem") == 0, "timed-out request leaked script work")
