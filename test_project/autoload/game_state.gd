extends Node

signal health_changed(value: float, max_value: float)
signal shield_changed(value: float, max_value: float)
signal ammo_changed(value: int)
signal ability_cooldown_changed(index: int, remaining: float)
signal damage_taken(amount: float)
signal log_message(text: String)

var health: float = 100.0
var max_health: float = 100.0
var shield: float = 50.0
var max_shield: float = 100.0
var ammo: int = 30

var cooldowns: Array[float] = [0.0, 0.0, 0.0]
var cooldown_max: Array[float] = [5.0, 8.0, 12.0]

var _shield_regen_rate: float = 3.0
var _damage_timer: float = 0.0
var _damage_interval: float = 4.0
var _log_timer: float = 0.0
var _log_interval: float = 3.0

var _log_messages: Array[String] = [
	"Shield charging...", "Hostile detected", "Ability ready",
	"Perimeter breach", "Signal lost", "Firewall active",
	"Target acquired", "System nominal",
]

func _process(delta: float) -> void:
	if shield < max_shield:
		shield = minf(shield + _shield_regen_rate * delta, max_shield)
		shield_changed.emit(shield, max_shield)
	for i in range(cooldowns.size()):
		if cooldowns[i] > 0.0:
			cooldowns[i] = maxf(cooldowns[i] - delta, 0.0)
			ability_cooldown_changed.emit(i, cooldowns[i])
	_damage_timer += delta
	if _damage_timer >= _damage_interval:
		_damage_timer = 0.0
		take_damage(randf_range(5.0, 20.0))
	_log_timer += delta
	if _log_timer >= _log_interval:
		_log_timer = 0.0
		log_message.emit(_log_messages[randi() % _log_messages.size()])

func take_damage(amount: float) -> void:
	var shield_absorb := minf(shield, amount)
	shield -= shield_absorb
	shield_changed.emit(shield, max_shield)
	var remaining := amount - shield_absorb
	if remaining > 0.0:
		health = maxf(health - remaining, 0.0)
		health_changed.emit(health, max_health)
	damage_taken.emit(amount)

func use_ability(index: int) -> void:
	if index < 0 or index >= cooldowns.size():
		return
	if cooldowns[index] > 0.0:
		return
	cooldowns[index] = cooldown_max[index]
	ability_cooldown_changed.emit(index, cooldowns[index])
	log_message.emit("Ability %d activated" % (index + 1))

func reload_weapon() -> void:
	ammo = 30
	ammo_changed.emit(ammo)
	log_message.emit("Reloaded")
