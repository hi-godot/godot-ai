extends Node

func _ready() -> void:
	var hud_scene := preload("res://cyberpunk_hud.tscn")
	var hud := hud_scene.instantiate()
	add_child(hud)
