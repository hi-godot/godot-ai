extends CanvasLayer

@onready var health_bar: ProgressBar = $ThemeRoot/TopLeft/HealthGroup/HealthContent/HealthBar
@onready var health_val: Label = $ThemeRoot/TopLeft/HealthGroup/HealthContent/HpHeader/HealthVal
@onready var shield_bar: ProgressBar = $ThemeRoot/TopLeft/HealthGroup/HealthContent/ShieldBar
@onready var shield_val: Label = $ThemeRoot/TopLeft/HealthGroup/HealthContent/ShHeader/ShieldVal
@onready var ammo_label: Label = $ThemeRoot/BottomRight/AmmoGroup/AmmoContent/AmmoCount
@onready var pause_overlay: Control = $ThemeRoot/PauseOverlay
@onready var ap: AnimationPlayer = $AP

var cd_labels: Array[Label] = []
var log_labels: Array[Label] = []
var _game_state: Node

func _ready() -> void:
	_game_state = get_node("/root/GameState")
	cd_labels = [
		$ThemeRoot/BottomLeft/AbilityBar/Ability1/CD1,
		$ThemeRoot/BottomLeft/AbilityBar/Ability2/CD2,
		$ThemeRoot/BottomLeft/AbilityBar/Ability3/CD3,
	]
	log_labels = [
		$ThemeRoot/LogFeed/LogPanel/Messages/Log1,
		$ThemeRoot/LogFeed/LogPanel/Messages/Log2,
		$ThemeRoot/LogFeed/LogPanel/Messages/Log3,
		$ThemeRoot/LogFeed/LogPanel/Messages/Log4,
		$ThemeRoot/LogFeed/LogPanel/Messages/Log5,
	]
	_game_state.health_changed.connect(_on_health_changed)
	_game_state.shield_changed.connect(_on_shield_changed)
	_game_state.ammo_changed.connect(_on_ammo_changed)
	_game_state.ability_cooldown_changed.connect(_on_cooldown_changed)
	_game_state.damage_taken.connect(_on_damage_taken)
	_game_state.log_message.connect(_on_log_message)
	health_bar.value = _game_state.health
	health_val.text = str(int(_game_state.health))
	shield_bar.value = _game_state.shield
	shield_val.text = str(int(_game_state.shield))
	ammo_label.text = str(_game_state.ammo)
	if ap.has_animation("hud_fade_in"):
		ap.play("hud_fade_in")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ability_1"):
		_game_state.use_ability(0)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ability_2"):
		_game_state.use_ability(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ability_3"):
		_game_state.use_ability(2)
		get_viewport().set_input_as_handled()

func _toggle_pause() -> void:
	var is_paused := not pause_overlay.visible
	pause_overlay.visible = is_paused
	get_tree().paused = is_paused
	if is_paused and ap.has_animation("pause_slide_in"):
		ap.play("pause_slide_in")

func _on_health_changed(value: float, max_value: float) -> void:
	health_bar.max_value = max_value
	health_bar.value = value
	health_val.text = str(int(value))
	if value / max_value < 0.3 and ap.has_animation("hp_glow"):
		if not ap.is_playing() or ap.current_animation != "hp_glow":
			ap.play("hp_glow")

func _on_shield_changed(value: float, max_value: float) -> void:
	shield_bar.max_value = max_value
	shield_bar.value = value
	shield_val.text = str(int(value))

func _on_ammo_changed(value: int) -> void:
	ammo_label.text = str(value)

func _on_cooldown_changed(index: int, remaining: float) -> void:
	if index >= 0 and index < cd_labels.size():
		if remaining > 0.0:
			cd_labels[index].text = "%.1f" % remaining
		else:
			cd_labels[index].text = ["Q", "E", "R"][index]

func _on_damage_taken(amount: float) -> void:
	if ap.has_animation("dmg_hit"):
		ap.play("dmg_hit")

func _on_log_message(text: String) -> void:
	for i in range(log_labels.size() - 1):
		log_labels[i].text = log_labels[i + 1].text
	log_labels[log_labels.size() - 1].text = text
