@tool
extends EditorPlugin

# Synthetic test for #245: macOS Godot 4.6.2-mono leaves a newly-injected
# Dictionary field with null _p after hot-reloading the script class on a
# live instance. Models the v2.1.1 → v2.1.2 self-update path of godot-ai.
#
# Sequence on _enter_tree (deferred so editor is fully booted):
#   1) stage repro_v1.gd content into res://repro.gd
#   2) construct an instance of v1
#   3) overwrite res://repro.gd with v2 content (adds Dictionary field)
#   4) trigger filesystem rescan + script reload
#   5) read instance.injected_dict.keys() — bug fires here

var _instance: RefCounted


func _enter_tree() -> void:
	print("[repro] _enter_tree — scheduling test")
	get_tree().create_timer(2.0).timeout.connect(_step_1_stage_v1)


func _exit_tree() -> void:
	pass


func _read_text(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		print("[repro] FAIL: cannot read %s" % p)
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _write_text(p: String, content: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		print("[repro] FAIL: cannot open %s for write" % p)
		return
	f.store_string(content)
	f.close()


func _step_1_stage_v1() -> void:
	print("[repro] step 1: stage v1 at res://repro.gd")
	var v1: String = _read_text("res://repro_v1.gd")
	_write_text("res://repro.gd", v1)
	EditorInterface.get_resource_filesystem().scan()
	get_tree().create_timer(2.0).timeout.connect(_step_2_construct_v1)


func _step_2_construct_v1() -> void:
	print("[repro] step 2: construct v1 instance")
	var script_v1: GDScript = load("res://repro.gd") as GDScript
	if script_v1 == null:
		print("[repro] FAIL: v1 class did not load")
		return
	_instance = script_v1.new()
	if _instance == null:
		print("[repro] FAIL: v1 instance is null")
		return
	print("[repro] v1 instance: %s" % _instance)
	var s: Variant = _instance.call("say")
	print("[repro] v1 .say() -> %s" % str(s))
	var prop_names: Array[String] = []
	for p in _instance.get_property_list():
		prop_names.append(p["name"])
	print("[repro] v1 property names: %s" % str(prop_names))
	get_tree().create_timer(1.0).timeout.connect(_step_3_overwrite_to_v2)


func _step_3_overwrite_to_v2() -> void:
	print("[repro] step 3: overwrite res://repro.gd with v2 (adds Dictionary field)")
	var v2: String = _read_text("res://repro_v2.gd")
	_write_text("res://repro.gd", v2)
	EditorInterface.get_resource_filesystem().scan()
	get_tree().create_timer(3.0).timeout.connect(_step_4_force_reload)


func _step_4_force_reload() -> void:
	print("[repro] step 4: force script reload + reimport")
	EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray(["res://repro.gd"]))
	get_tree().create_timer(2.0).timeout.connect(_step_5_probe)


func _step_5_probe() -> void:
	print("[repro] step 5: probe instance after hot-reload")
	if _instance == null:
		print("[repro] FAIL: instance was GC'd")
		_quit_with(1)
		return
	var prop_names: Array[String] = []
	for p in _instance.get_property_list():
		prop_names.append(p["name"])
	print("[repro] post-reload property names: %s" % str(prop_names))

	var v: Variant = _instance.get("injected_dict")
	print("[repro] inst.get('injected_dict'): typeof=%d value=%s" % [typeof(v), str(v)])

	if typeof(v) == TYPE_DICTIONARY:
		var d: Dictionary = v
		print("[repro] is Dictionary; calling .keys()...")
		# THIS is where the bug would crash (Dictionary::keys on null _p)
		var k: Array = d.keys()
		print("[repro] .keys() returned %s (size=%d)" % [str(k), k.size()])
	else:
		print("[repro] field is not Dictionary; type=%d" % typeof(v))

	# Call the v2 .say() method which itself does injected_dict.keys()
	print("[repro] calling inst.say() (v2 body)...")
	var msg: Variant = _instance.call("say")
	print("[repro] inst.say() -> %s" % str(msg))

	print("[repro] DONE — no SIGABRT. Bug did NOT reproduce in synthetic.")
	_quit_with(0)


func _quit_with(code: int) -> void:
	get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit(code))
