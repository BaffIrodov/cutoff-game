class_name CutoffMotor
extends RefCounted

const DT = 1.0 / 60.0
const SPEED = 190.0
const RADIUS = 14.0

static func player(id: String, nickname: String, spawn: Vector2) -> Dictionary:
	return {"id": id, "name": nickname, "p": spawn, "aim": Vector2.RIGHT, "hp": 200.0, "max_hp": 200.0,
		"alive": true, "down": false, "down_time": 0.0, "stamina": 3.0, "regen": 0.0, "sprint_locked": false,
		"dash_time": 0.0, "dash_cd": 0.0, "dash_dir": Vector2.RIGHT, "moving": false, "sprinting": false,
		"slot": 0, "rifle": false, "ammo": 0, "reserve": 0, "assault": false, "mag": 0, "ar_reserve": 0,
		"grenades": 0, "medkits": 1, "reload": 0.0, "reload_slot": 0, "cooldown": 0.0, "swing": -1.0,
		"swing_hit": false, "shot": 0, "hit": 0, "kill": 0, "ack": 0, "connected": true, "hints": {}, "radius": RADIUS}

static func idle() -> Dictionary:
	return {"seq": 0, "move": Vector2.ZERO, "aim": Vector2.ZERO, "run": false, "fire": false, "dash": false}

static func step(p: Dictionary, input: Dictionary, map: CutoffMap, gates: Array, actors: Array = []) -> void:
	p.dash_cd = maxf(0.0, p.dash_cd - DT)
	p.regen = maxf(0.0, p.regen - DT)
	p.moving = false
	p.sprinting = false
	var aim: Vector2 = input.get("aim", p.aim)
	if aim.is_finite() and aim.length_squared() > 0.001:
		p.aim = aim.normalized()
	if not p.alive or p.down:
		p.dash_time = 0.0
		return
	var direction: Vector2 = input.get("move", Vector2.ZERO)
	if not direction.is_finite():
		direction = Vector2.ZERO
	direction = direction.limit_length(1.0)
	if input.get("dash", false) and p.dash_time <= 0 and p.dash_cd <= 0 and p.stamina >= 1:
		var dash_direction = input.get("dash_direction", direction.normalized() if direction.length_squared() > 0.01 else p.aim)
		if not map.blocked(p.p + dash_direction * 6, RADIUS, gates) and not CutoffMap.actor_blocked(p.p + dash_direction * 6, RADIUS, actors):
			p.dash_dir = dash_direction
			p.dash_time = 0.14
			p.dash_cd = 0.55
			p.stamina -= 1.0
			p.regen = 0.85
			if p.stamina <= 0:
				p.sprint_locked = true
	if p.dash_time > 0:
		var old: Vector2 = p.p
		p.p = map.move_body(p.p, p.dash_dir * (105.0 / 0.14) * minf(DT, p.dash_time), RADIUS, gates, actors)
		p.dash_time = maxf(0.0, p.dash_time - DT)
		p.moving = true
		if old.distance_to(p.p) < 0.1:
			p.dash_time = 0.0
		return
	p.moving = direction.length_squared() > 0.001
	p.sprinting = p.moving and input.get("run", false) and not p.sprint_locked and p.stamina > 0
	if p.sprinting:
		p.stamina = maxf(0.0, p.stamina - DT)
		p.regen = 0.85
		if p.stamina <= 0:
			p.sprint_locked = true
	elif p.regen <= 0:
		p.stamina = minf(3.0, p.stamina + 1.25 * DT)
		if p.stamina >= 3:
			p.sprint_locked = false
	p.p = map.move_body(p.p, direction * SPEED * (1.5 if p.sprinting else 1.0) * DT, RADIUS, gates, actors)
