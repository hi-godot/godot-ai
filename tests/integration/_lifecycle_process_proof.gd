@tool
extends Node

const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const Resolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const Capability := preload("res://addons/godot_ai/utils/transport_capability.gd")
const Authority := preload("res://addons/godot_ai/utils/server_authority.gd")
const Config := preload("res://addons/godot_ai/client_configurator.gd")
class CaptureFailureLifecycle extends Lifecycle:
	var failure_stage := ""
	var receipt_path := ""
	var case_name := ""
	var injected := false

	func _capture_process_snapshot(pid: int) -> Variant:
		if failure_stage == "initial":
			injected = true
			return {"capture_error": true}
		if failure_stage == "final" and FileAccess.file_exists(receipt_path):
			var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(receipt_path))
			if str(receipt.get("case", "")) == case_name and int(receipt.get("authenticated_requests", 0)) >= 2:
				injected = true
				return {"capture_error": true}
		return super._capture_process_snapshot(pid)

var failures: Array[String] = []
var rows: Array[Dictionary] = []

func _ready() -> void:
	if Engine.is_editor_hint():
		run.call_deferred()

func require(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func write_json(path: String, value: Dictionary) -> void:
	FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(value))

func run() -> void:
	var work := OS.get_environment("PROOF_WORK")
	var configuration: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(work.path_join("processes.json")))
	var launch_pid := int(configuration.launch_pid)
	var worker_pid := int(configuration.worker_pid)
	var unrelated_pid := int(configuration.unrelated_pid)
	var stale_pid := int(configuration.stale_pid)
	var http_port := int(configuration.http_port)
	var ws_port := int(configuration.ws_port)
	require(not Resolver.pid_alive(stale_pid), "reaped stale hint PID has not been reused")
	var exact := Resolver.capture_process_kill_grant(launch_pid)
	require(not exact.is_empty(), "real launcher exact grant can be captured")
	var worker_snapshot: Variant = Resolver.capture_process_snapshot(worker_pid)
	var worker_fingerprint := Resolver.process_fingerprint(worker_pid, worker_snapshot)
	require(not worker_fingerprint.is_empty(), "real worker fingerprint available")
	require(Resolver.process_descends_from(worker_pid, launch_pid, worker_snapshot), "actual backend is launcher's descendant")
	require(Resolver.pid_cmdline_is_godot_ai(worker_pid, worker_snapshot), "real backend command line satisfies unchanged branding")
	require(Resolver.find_all_pids_on_port(http_port).has(worker_pid), "actual backend receipt PID owns HTTP listener")
	var unrelated_snapshot: Variant = Resolver.capture_process_snapshot(unrelated_pid)
	require(not Resolver.process_descends_from(unrelated_pid, launch_pid, unrelated_snapshot), "unrelated fixture is not launcher's descendant")
	var capability_path := work.path_join("local-app-data/godot-ai/capabilities/http-%d.json" % http_port)
	var cap := Capability.read_for_http_port(http_port, capability_path)
	require(not cap.is_empty(), "real private capability readable")
	if not failures.is_empty():
		finish()
		return
	var cases := [
		{"name": "initial_capture_failure", "hint": worker_pid, "request": 0, "replacement": worker_pid, "expected": "identity_unavailable"},
		{"name": "final_capture_failure", "hint": worker_pid, "request": 2, "replacement": worker_pid, "expected": "identity_unavailable"},
		{"name": "exited_launcher", "hint": worker_pid, "request": 0, "replacement": worker_pid, "expected": "launch_gone"},
		{"name": "owned_child", "hint": worker_pid, "request": 0, "replacement": worker_pid, "expected": "ok"},
		{"name": "changed_hint", "hint": launch_pid, "request": 1, "replacement": worker_pid, "expected": "ok"},
		{"name": "stale_hint_corrected", "hint": stale_pid, "request": 1, "replacement": worker_pid, "expected": "ok"},
		{"name": "unrelated_hint_corrected", "hint": unrelated_pid, "request": 1, "replacement": worker_pid, "expected": "ok"},
		{"name": "unrelated_hint_retained", "hint": unrelated_pid, "request": 0, "replacement": worker_pid, "expected": "listener_pid"},
		{"name": "wrong_launch_identity", "hint": worker_pid, "request": 0, "replacement": worker_pid, "expected": "launch_replaced"},
		{"name": "final_pid_changed", "hint": worker_pid, "request": 2, "replacement": unrelated_pid, "expected": "final_capture_window"},
	]
	for case in cases:
		var label: String = str(case.name)
		FileAccess.open(work.path_join("worker.pid"), FileAccess.WRITE).store_string(str(case.hint))
		write_json(work.path_join("control.json"), {"case": label, "change_on_request": case.request, "replacement_pid": case.replacement})
		var fingerprint := str(exact.fingerprint) + ("changed" if case.name == "wrong_launch_identity" else "")
		var grant := Authority.OwnedProcessGrant.new(stale_pid if label == "exited_launcher" else launch_pid, fingerprint, maxi(1, Time.get_ticks_msec()))
		var manager := CaptureFailureLifecycle.new()
		manager.failure_stage = "initial" if label == "initial_capture_failure" else ("final" if label == "final_capture_failure" else "")
		manager.receipt_path = work.path_join("route-receipt.json")
		manager.case_name = label
		manager.configure({"capability_path": capability_path, "automatic_effects": false})
		var result := manager._effect_prove({"grant": grant, "http_port": http_port, "expected_ws_port": ws_port, "expected_version": Config.get_plugin_version(), "timeout_ms": 3000, "pid_file": work.path_join("worker.pid"), "http_capability": cap.http, "ws_capability": cap.websocket, "baseline_instance_id": ""})
		var reason := str(result.get("reason", "ok" if result.get("ok", false) else "missing_result"))
		require(reason == case.expected, label + " expected " + str(case.expected) + " got " + reason)
		if not manager.failure_stage.is_empty():
			require(manager.injected, label + " reaches intended capture failure")
			if manager.failure_stage == "initial":
				var diagnostic := manager._launch_unproven_message(launch_pid, ["identity_unavailable"], 1)
				require("alive=unknown" in diagnostic and "identity_unavailable" in diagnostic, label + " diagnostic does not claim death")
		if int(case.request) > 0:
			var route: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(work.path_join("route-receipt.json")))
			require(str(route.get("case", "")) == label and int(route.get("authenticated_requests", 0)) >= int(case.request), label + " real authenticated route performed scheduled mutation")
			require(Resolver.read_pid_file(work.path_join("worker.pid")) == int(case.replacement), label + " actual PID file contains scheduled replacement")
		if case.expected == "ok":
			require(bool(result.get("ok", false)), label + " explicitly succeeds")
			require(int(result.get("pid", -1)) == worker_pid, label + " grants actual worker PID")
			require(str(result.get("fingerprint", "")) == worker_fingerprint, label + " grants actual worker fingerprint")
			require(result.has("transport"), label + " returns transport")
			if result.has("transport"):
				require(result.transport.server_instance_id() == cap.instance_nonce, label + " authenticates exact instance")
		else:
			require(not result.has("transport") and not result.has("fingerprint"), label + " grants no authority")
			if case.expected not in ["launch_replaced", "launch_gone"]:
				require(result.get("pending", false), label + " remains pending")
		rows.append({"case": case.name, "reason": reason})
	finish()

func finish() -> void:
	var result := {"rows": rows, "failures": failures}
	write_json("res://result.json", result)
	print(JSON.stringify(result))
	get_tree().quit()
