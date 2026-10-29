class_name CutoffWorld
extends RefCounted

const DT = CutoffMotor.DT
var map: CutoffMap
var players = {}
var mobs: Array = []
var shots: Array = []
var effects: Array = []
var crates: Array = []
var pickups: Array = []
var boosts: Array = []
var terminals: Array = []
var coop: Array = []
var trust: Array = []
var bridges: Array = []
var dividers: Array = []
var relays: Array = []
var checkpoints: Array = []
var targets: Array = []
var triggers = {}
var entrance_open = false
var gates: Array = []
var tick = 0
var time = 0.0
var practice = false
var won = false
var next_id = 1
var starting_count = 0
var nav_grids = {}
var gate_revision = 0
var nav_revision = -1
var paths_this_tick = 0
var last_step_us = 0
var truth_events: Array = []

func initialize(source: CutoffMap, roster: Array, training = false) -> void:
	map = source
	practice = training
	starting_count = roster.size()
	for i in range(roster.size()):
		var seed = roster[i]
		players[seed.id] = CutoffMotor.player(seed.id, seed.name, CutoffMap.point(map.data.playerSpawns[i]))
	var current = roster.size()
	for i in range(map.data.checkpoints.size()):
		var c = map.data.checkpoints[i].duplicate(true)
		var low = 1 if practice else maxi(map.minimum_after(i), mini(2, current) if i < map.data.checkpoints.size() - 1 else 1)
		var high = mini(current, int(c.get("maximumSurvivors", 4)))
		var choices = []
		var weights = [50, 40, 10] if i == 0 else ([50, 35, 15] if i == 1 else [45, 35, 20])
		for drop in range(3):
			if current - drop >= low and current - drop <= high:
				for _j in range(weights[drop]):
					choices.append(current - drop)
		current = 1 if practice else (choices.pick_random() if not choices.is_empty() else high)
		targets.append(current)
		c.merge({"state": "ACTIVE", "charge": 0.0, "occupied": []})
		checkpoints.append(c)
	for item in map.data.get("cooperationGates", []):
		var c = item.duplicate(true)
		c.merge({"open": false, "charge": 0.0, "occupied": []})
		coop.append(c)
	for item in map.data.get("trustPockets", []):
		var c = item.duplicate(true)
		c.merge({"open": false, "occupied": false})
		trust.append(c)
	for item in map.data.get("serviceBridges", []):
		var c = item.duplicate(true)
		c.merge({"safe": false, "locked": false, "remaining": 0.0, "occupied": false})
		bridges.append(c)
	for item in map.data.get("separationGates", []):
		var c = item.duplicate(true)
		c.remaining = 0.0
		dividers.append(c)
	for item in map.data.get("finalRelays", []):
		var c = item.duplicate(true)
		c.merge({"open": false, "remaining": [0.0, 0.0]})
		relays.append(c)
	var contents = []
	for i in range(map.data.get("lootCrates", []).size()):
		contents.append(["MEDKIT", "AMMO", "ASSAULT_RIFLE", "GRENADE_LAUNCHER"][i % 4])
	contents.shuffle()
	for i in range(contents.size()):
		crates.append({"p": CutoffMap.point(map.data.lootCrates[i]), "opened": false, "loot": contents[i]})
	for item in map.data.get("weaponPickups", []):
		pickups.append({"id": item.id, "p": CutoffMap.point(item), "ammo": int(item.ammo), "available": true})
	for item in map.data.get("healthBoostPickups", []):
		boosts.append({"p": CutoffMap.point(item), "available": true})
	for item in map.data.get("intelTerminals", []):
		terminals.append({"id": item.id, "p": CutoffMap.point(item), "checkpoint": int(item.checkpoint), "claimed": ""})
	for item in map.data.mobs:
		var boss = item.type.begins_with("BOSS")
		var radius = (32.0 if item.type == "BOSS_ASSAULT" else 29.0) if boss else 13.0
		mobs.append({"id": item.id, "p": CutoffMap.point(item), "aim": Vector2.LEFT,
			"type": item.type, "level": int(item.level), "hp": float(item.health), "max_hp": float(item.health),
			"ammo": int(item.ammo), "mag": mini(int(item.ammo), 30 if "ASSAULT" in item.type else 5),
			"alive": true, "spawned": false, "route_active": false, "definition": item,
			"radius": radius, "target": "", "cooldown": 0.0, "reload": 0.0, "shot": 0, "swing": -1.0, "swing_hit": false, "swing_aim": Vector2.LEFT,
			"path": PackedVector2Array(), "path_at": 0.0, "stamina": 3.0, "regen": 0.0, "sprint_locked": false})
	fire_trigger("world-created")
	refresh_gates()

func fire_trigger(name: String) -> void:
	if name.is_empty() or triggers.has(name):
		return
	triggers[name] = true
	for m in mobs:
		var newly_spawned = not m.spawned and m.definition.spawnTrigger == name
		if newly_spawned: m.spawned = true
		var route = m.definition.route
		# An unrelated trigger must never restart an already completed route.
		if m.spawned and route.get("enabled", false) and (route.startTrigger == name or (newly_spawned and triggers.has(route.startTrigger))):
			m.route_active = true
			m.path = PackedVector2Array()
			m.path_at = 0.0

func trigger_action(definition: Dictionary, key: String) -> void:
	fire_trigger(definition.get("triggers", {}).get(key, ""))

func refresh_gates() -> void:
	var next: Array = []
	if not entrance_open:
		next.append(CutoffMap.rect(map.data.entrance.gate))
	for group in [coop, trust, relays]:
		for gate in group:
			if not gate.open:
				next.append(CutoffMap.rect(gate.gate))
	for gate in dividers:
		if gate.remaining <= 0:
			next.append(CutoffMap.rect(gate.gate))
	for c in checkpoints:
		if c.state != "CLEARED":
			next.append(CutoffMap.rect(c.exitGate))
	if next != gates:
		gates = next
		gate_revision += 1

func step(inputs: Dictionary, actions: Array = []) -> void:
	var started = Time.get_ticks_usec()
	tick += 1
	time += DT
	paths_this_tick = 0
	for id in players:
		var p = players[id]
		p.cooldown = maxf(0, p.cooldown - DT)
		if p.reload > 0:
			p.reload = maxf(0, p.reload - DT)
			if p.reload <= 0:
				var ar = p.reload_slot == 2
				var missing = (30 - p.mag) if ar else (5 - p.ammo)
				var amount = mini(missing, p.ar_reserve if ar else p.reserve)
				if ar:
					p.mag += amount
					p.ar_reserve -= amount
				else:
					p.ammo += amount
					p.reserve -= amount
		if p.down:
			p.down_time += DT
			if p.down_time >= 5:
				p.alive = false
				p.down = false
		var input = inputs.get(id, CutoffMotor.idle())
		if input.seq > 0:
			p.ack = int(input.seq)
		CutoffMotor.step(p, input, map, gates, solid_actors(id))
		if p.swing >= 0:
			p.swing += DT
			if p.swing >= 0.14 and not p.swing_hit:
				p.swing_hit = true
				melee(p)
			if p.swing >= 0.34:
				p.swing = -1.0
		if input.get("fire", false) and p.slot == 2:
			attack(id)
	for action in actions:
		if players.has(action.player):
			act(action.player, action.kind, action.get("value", null))
	for area in map.data.get("triggerAreas", []):
		for p in players.values():
			if active(p) and CutoffMap.rect(area.area).has_point(p.p):
				fire_trigger(area.trigger)
	update_mechanisms()
	update_mobs()
	update_shots()
	collect_items()
	update_checkpoints()
	refresh_gates()
	eject_and_separate()
	for e in effects:
		e.life -= DT
	effects = effects.filter(func(e): return e.life > 0)
	won = not checkpoints.is_empty() and checkpoints[-1].state == "CLEARED"
	last_step_us = Time.get_ticks_usec() - started

func active(p: Dictionary) -> bool:
	return p.alive and not p.down

func solid_actors(except_id: String) -> Array:
	var actors = []
	for p in players.values():
		if p.id != except_id and p.alive:
			actors.append(p)
	for m in mobs:
		if m.spawned and m.alive: actors.append(m)
	return actors

func act(id: String, kind: String, value = null) -> void:
	var p = players[id]
	if not active(p):
		return
	match kind:
		"interact": interact(p)
		"attack": attack(id)
		"reload": reload_weapon(p)
		"slot":
			p.slot = clampi(int(value), 0, 4)
		"heal": heal(p, false)
		"heal_other": heal(p, true)
		"transfer": transfer(p)

func reload_weapon(p: Dictionary) -> void:
	if p.reload > 0:
		return
	if (p.slot == 1 and p.rifle and p.ammo < 5 and p.reserve > 0) or (p.slot == 2 and p.assault and p.mag < 30 and p.ar_reserve > 0):
		p.reload = 1.0
		p.reload_slot = p.slot

func attack(id: String) -> void:
	var p = players[id]
	if not active(p) or p.cooldown > 0:
		return
	if p.slot == 4:
		heal(p, false)
		return
	if p.slot == 0:
		p.swing = 0.0
		p.swing_hit = false
		p.swing_aim = p.aim
		p.cooldown = 0.55
		return
	if p.reload > 0:
		return
	var speed = 760.0
	var damage = 40.0
	var grenade = false
	match p.slot:
		1:
			if not p.rifle: return
			if p.ammo <= 0:
				reload_weapon(p)
				return
			p.ammo -= 1
			p.cooldown = 0.5
		2:
			if not p.assault: return
			if p.mag <= 0:
				reload_weapon(p)
				return
			p.mag -= 1
			p.cooldown = 0.2
			damage = 10.0
		3:
			if p.grenades <= 0: return
			p.grenades -= 1
			p.cooldown = 0.9
			speed = 380.0
			grenade = true
	spawn_shot(id, p.p, p.aim, false, speed, damage, grenade, 28.0 if grenade else 23.0)
	p.shot += 1
	if (p.slot == 1 and p.ammo == 0) or (p.slot == 2 and p.mag == 0):
		reload_weapon(p)

func melee(p: Dictionary) -> void:
	if not active(p): return
	var candidates = mobs + players.values()
	for target in candidates:
		if target.id == p.id or not target.alive or (target.has("spawned") and not target.spawned): continue
		var delta: Vector2 = target.p - p.p
		if delta.length() <= 76 + target.radius and delta.normalized().dot(p.get("swing_aim", p.aim)) >= 0.45 and map.clear_line(p.p, target.p, 0, gates):
			damage_actor(target, 20.0)
			p.hit += 1
			if not target.alive or target.get("down", false): p.kill += 1
			effect("impact", target.p, 0.35)

func damage_actor(target: Dictionary, amount: float) -> void:
	if not target.alive:
		return
	if target.has("down") and target.down:
		return
	target.hp = maxf(0, target.hp - amount)
	if target.hp <= 0:
		if target.has("down"):
			target.down = true
			target.down_time = 0.0
			target.dash_time = 0.0
		else:
			target.alive = false

func heal(p: Dictionary, other: bool) -> void:
	if p.medkits <= 0 or p.slot != 4:
		return
	var target = p
	if other:
		var distance = 90.0
		target = {}
		for candidate in players.values():
			if candidate.id != p.id and candidate.alive and (candidate.down or candidate.hp < candidate.max_hp):
				var d = p.p.distance_to(candidate.p)
				if d <= distance and map.clear_line(p.p, candidate.p, 0, gates):
					distance = d
					target = candidate
	if target.is_empty() or (not target.down and target.hp >= target.max_hp):
		return
	p.medkits -= 1
	if target.down:
		target.down = false
		target.down_time = 0.0
		target.hp = 50.0
	else:
		target.hp = minf(target.max_hp, target.hp + 50)
	effect("heal", target.p, 0.6)

func transfer(p: Dictionary) -> void:
	var target = {}
	var distance = 90.0
	for candidate in players.values():
		if candidate.id != p.id and active(candidate) and p.p.distance_to(candidate.p) < distance:
			if map.clear_line(p.p, candidate.p, 0, gates):
				distance = p.p.distance_to(candidate.p)
				target = candidate
	if target.is_empty(): return
	match p.slot:
		1:
			var amount = mini(3, p.reserve + p.ammo)
			if amount <= 0: return
			var reserve_amount = mini(amount, p.reserve)
			p.reserve -= reserve_amount
			p.ammo -= amount - reserve_amount
			target.rifle = true
			target.reserve += amount
		2:
			var amount = mini(3, p.ar_reserve + p.mag)
			if amount <= 0: return
			var reserve_amount = mini(amount, p.ar_reserve)
			p.ar_reserve -= reserve_amount
			p.mag -= amount - reserve_amount
			target.assault = true
			target.ar_reserve += amount
		3:
			if p.grenades <= 0: return
			p.grenades -= 1
			target.grenades += 1
		4:
			if p.medkits <= 0: return
			p.medkits -= 1
			target.medkits += 1
	effect("transfer", target.p, 0.7)

func interact(p: Dictionary) -> void:
	if not entrance_open and p.p.distance_to(CutoffMap.point(map.data.entrance.console)) <= 72:
		entrance_open = true
		trigger_action(map.data.entrance, "opened")
		refresh_gates()
		return
	for bridge in bridges:
		if not bridge.locked and p.p.distance_to(CutoffMap.point(bridge.overrideConsole)) <= 72:
			bridge.locked = true
			bridge.safe = true
			trigger_action(bridge, "override-pressed")
			return
	for gate in dividers:
		for i in range(gate.controls.size()):
			if p.p.distance_to(CutoffMap.point(gate.controls[i])) <= 72:
				gate.remaining = 3.0
				trigger_action(gate, "control-" + str(i + 1))
				return
	for relay in relays:
		if relay.open: continue
		for i in range(relay.nodes.size()):
			if p.p.distance_to(CutoffMap.point(relay.nodes[i])) <= 72:
				relay.remaining[i] = 4.0
				trigger_action(relay, "node-" + str(i + 1))
				return
	var nearest = {}
	var distance = 70.0
	var is_terminal = false
	for crate in crates:
		var d = p.p.distance_to(crate.p)
		if not crate.opened and d <= minf(distance, 58):
			nearest = crate
			distance = d
	for terminal in terminals:
		var d = p.p.distance_to(terminal.p)
		if d <= distance and (terminal.claimed == "" or p.hints.has(terminal.checkpoint)):
			nearest = terminal
			distance = d
			is_terminal = true
	if nearest.is_empty(): return
	if is_terminal:
		var first_knowledge = not p.hints.has(nearest.checkpoint)
		nearest.claimed = p.id
		p.hints[nearest.checkpoint] = targets[nearest.checkpoint - 1]
		if first_knowledge:
			truth_events.append({"id": truth_events.size() + 1, "player": p.id, "name": p.name, "checkpoint": nearest.checkpoint, "time": time})
	else:
		nearest.opened = true
		match nearest.loot:
			"MEDKIT": p.medkits += 1
			"AMMO":
				if not p.rifle:
					p.rifle = true
					p.ammo = 5
				else: p.reserve += 5
			"ASSAULT_RIFLE":
				if not p.assault:
					p.assault = true
					p.mag = 30
				else: p.ar_reserve += 30
			"GRENADE_LAUNCHER": p.grenades += 1
		effect("loot", nearest.p, 0.7)

func collect_items() -> void:
	for p in players.values():
		if not active(p): continue
		for pickup in pickups:
			if pickup.available and p.p.distance_to(pickup.p) <= 30:
				pickup.available = false
				if not p.rifle:
					p.rifle = true
					p.ammo = mini(5, pickup.ammo)
					p.reserve += maxi(0, pickup.ammo - 5)
				else: p.reserve += pickup.ammo
		for boost in boosts:
			if boost.available and p.p.distance_to(boost.p) <= 30:
				boost.available = false
				p.max_hp += 50
				effect("heal", boost.p, 0.5)

func plate_players(points: Array, radius = 28.0) -> Array:
	var occupied = []
	var used = {}
	for point in points:
		var occupant = ""
		for p in players.values():
			if active(p) and not used.has(p.id) and p.p.distance_to(CutoffMap.point(point)) <= radius:
				occupant = p.id
				used[p.id] = true
				break
		occupied.append(occupant)
	return occupied

func update_mechanisms() -> void:
	for gate in coop:
		if gate.open or not entrance_open: continue
		var occupied = plate_players(gate.plates)
		var count = 0
		for i in range(occupied.size()):
			if occupied[i] != "":
				count += 1
				if gate.occupied.is_empty() or gate.occupied[i] == "": trigger_action(gate, "plate-" + str(i + 1))
		gate.occupied = occupied
		var required = int(gate.requiredPlayers)
		if practice: required = 1
		elif gate.get("adaptiveToTeamSize", false): required = mini(required, starting_count)
		gate.charge = gate.charge + DT if count >= required else 0.0
		if gate.charge >= 1.25:
			gate.open = true
			trigger_action(gate, "opened")
	for pocket in trust:
		var occupied = plate_players([pocket.plate])[0] != ""
		if occupied != pocket.occupied: trigger_action(pocket, "plate-pressed" if occupied else "plate-released")
		pocket.occupied = occupied
		pocket.open = occupied
		if not pocket.open:
			for p in players.values():
				if active(p) and CutoffMap.rect(pocket.pocket).has_point(p.p): damage_actor(p, 30 * DT)
	for bridge in bridges:
		var occupied = plate_players([bridge.plate], 30)[0] != ""
		if occupied and not bridge.occupied: trigger_action(bridge, "plate-pressed")
		bridge.occupied = occupied
		bridge.remaining = 2.0 if occupied else maxf(0, bridge.remaining - DT)
		bridge.safe = bridge.locked or bridge.remaining > 0
		if not bridge.safe:
			for p in players.values():
				if active(p) and CutoffMap.rect(bridge.hazard).has_point(p.p): damage_actor(p, 45 * DT)
	for gate in dividers:
		gate.remaining = maxf(0, gate.remaining - DT)
	for relay in relays:
		if relay.open: continue
		for i in range(relay.remaining.size()): relay.remaining[i] = maxf(0, relay.remaining[i] - DT)
		if relay.remaining.all(func(value): return value > 0):
			relay.open = true
			trigger_action(relay, "opened")

func update_checkpoints() -> void:
	for i in range(checkpoints.size()):
		var c = checkpoints[i]
		var occupied = plate_players(c.platforms, 30)
		for j in range(occupied.size()):
			if occupied[j] != "" and (c.occupied.is_empty() or c.occupied[j] == ""):
				trigger_action(c, "platform-" + str(j + 1))
		c.occupied = occupied
		if c.state != "ACTIVE" or (i > 0 and checkpoints[i - 1].state != "CLEARED"): continue
		var survivors = players.values().filter(func(p): return p.alive)
		var all_on = not survivors.is_empty() and survivors.all(func(p): return not p.down and occupied.has(p.id))
		if not all_on:
			c.charge = 0.0
			continue
		if c.charge == 0: trigger_action(c, "activated")
		c.charge = minf(2, c.charge + DT)
		if c.charge >= 2:
			if survivors.size() == targets[i]:
				c.state = "CLEARED"
				trigger_action(c, "cleared")
			else:
				c.state = "FAILED"
				trigger_action(c, "failed")
				for p in survivors:
					p.hp = 0.0
					p.alive = false
					p.down = false
			effect("checkpoint", CutoffMap.point(c.platforms[0]), 1.0)

func spawn_shot(owner: String, position: Vector2, aim: Vector2, hostile: bool, speed: float, damage: float, grenade: bool, muzzle: float) -> void:
	var shot = {"id": next_id, "owner": owner, "p": position, "origin": position, "v": aim * speed,
		"damage": damage, "hostile": hostile, "grenade": grenade, "life": 2.5, "radius": 8.0 if grenade else 5.0}
	next_id += 1
	# Check the barrel path as well: weapons cannot shoot through adjacent walls.
	shot.p = map.move_body(position, aim * muzzle, 1.0, gates)
	shots.append(shot)

func update_shots() -> void:
	var remaining = []
	for shot in shots:
		shot.life -= DT
		var motion: Vector2 = shot.v * DT
		var steps = maxi(1, ceili(motion.length() / 5.0))
		var hit = false
		for _i in range(steps):
			shot.p += motion / steps
			if map.blocked(shot.p, shot.radius, gates):
				hit = true
				break
			for actor in players.values() + mobs:
				if actor.id == shot.owner or not actor.alive or (actor.has("spawned") and not actor.spawned): continue
				if actor.p.distance_squared_to(shot.p) <= pow(actor.radius + shot.radius, 2):
					if not shot.grenade:
						var amount = shot.damage * (0.5 if shot.hostile and actor.has("spawned") else 1.0)
						damage_actor(actor, amount)
						if players.has(shot.owner):
							players[shot.owner].hit += 1
							if not actor.alive or actor.get("down", false): players[shot.owner].kill += 1
					hit = true
					break
			if hit: break
		if hit or shot.life <= 0:
			if shot.grenade: explode(shot)
			else: effect("impact", shot.p, 0.35)
		else: remaining.append(shot)
	shots = remaining

func explode(shot: Dictionary) -> void:
	effect("explosion", shot.p, 0.5)
	for actor in players.values() + mobs:
		if not actor.alive or (actor.has("spawned") and not actor.spawned): continue
		var distance = actor.p.distance_to(shot.p)
		if distance > 100: continue
		var direction: Vector2 = (actor.p - shot.p).normalized()
		# The detonation may be just inside the wall that stopped the projectile.
		var start: Vector2 = shot.p - shot.v.normalized() * (shot.radius + 6)
		if map.clear_line(start, actor.p - direction * actor.radius, 0, gates):
			damage_actor(actor, (100.0 if distance <= 50 else 50.0) * (0.5 if shot.hostile and actor.has("spawned") else 1.0))

func effect(kind: String, position: Vector2, lifetime: float) -> void:
	effects.append({"id": next_id, "kind": kind, "p": position, "life": lifetime})
	next_id += 1

func update_mobs() -> void:
	for m in mobs:
		if not m.alive or not m.spawned: continue
		m.regen = maxf(0, m.regen - DT)
		if m.regen <= 0:
			m.stamina = minf(3, m.stamina + DT * 1.25)
			if m.stamina >= 3: m.sprint_locked = false
		m.cooldown = maxf(0, m.cooldown - DT)
		if m.swing >= 0:
			m.swing += DT
			if m.swing >= 0.14 and not m.swing_hit:
				m.swing_hit = true
				for p in players.values():
					var offset: Vector2 = p.p - m.p
					if active(p) and offset.length() <= 31 + maxf(0, m.radius - 13) + 14 and offset.normalized().dot(m.swing_aim) >= 0.45 and map.clear_line(m.p, p.p, 0, gates):
						damage_actor(p, 10.0)
			if m.swing >= 0.34: m.swing = -1.0
		if m.reload > 0:
			m.reload = maxf(0, m.reload - DT)
			if m.reload <= 0: m.mag = mini(m.ammo, 30 if "ASSAULT" in m.type else 5)
		var destination: Vector2 = m.p
		var target = players.get(m.target, {})
		if not target.is_empty() and not active(target):
			target = {}
			m.target = ""
		if m.route_active:
			destination = CutoffMap.point(m.definition.route.points[0])
			if m.p.distance_to(destination) < 8:
				m.route_active = false
			else:
				m.aim = (destination - m.p).normalized()
				move_mob(m, destination, mob_speed(m, m.p.distance_to(destination)))
				continue
		if target.is_empty():
			var nearest = 530.0
			for p in players.values():
				var distance = m.p.distance_to(p.p)
				if active(p) and distance <= nearest and map.clear_line(m.p, p.p, 0, gates):
					nearest = distance
					target = p
					m.target = p.id
		if target.is_empty(): continue
		destination = target.p
		var distance = m.p.distance_to(destination)
		m.aim = (destination - m.p).normalized()
		var visible = map.clear_line(m.p, destination, 0, gates)
		var ranged = m.type != "MELEE" and m.ammo > 0
		if ranged and distance <= 340 and visible:
			fire_mob(m)
			if m.level == 1: continue
		elif not ranged and distance <= 31 + maxf(0, m.radius - 13) and visible:
			if m.cooldown <= 0:
				m.cooldown = 1.0
				m.swing = 0.0
				m.swing_hit = false
				m.swing_aim = m.aim
			continue
		var speed = mob_speed(m, distance)
		if m.level == 2 and visible:
			var dodge = shots.any(func(s): return not s.hostile and not s.grenade and s.p.distance_to(m.p) <= 180)
			var forward_weight = (0.42 if distance > 270 else (-0.38 if distance < 155 else 0.05)) if ranged else 1.0
			var side_weight = (1.18 if dodge else 0.72) if ranged else (1.0 if dodge else 0.48)
			var side: Vector2 = Vector2(-m.aim.y, m.aim.x) * (1.0 if sin(time * 5.2 + float(m.id.hash() % 628) / 100.0) >= 0 else -1.0)
			var before: Vector2 = m.p
			m.p = map.move_body(m.p, (m.aim * forward_weight + side * side_weight).normalized() * speed * DT, m.radius, gates)
			if m.p.distance_to(before) < 0.25:
				m.p = map.move_body(m.p, (m.aim * 0.35 - side).normalized() * speed * DT, m.radius, gates)
		else: move_mob(m, destination, speed)

func mob_speed(m: Dictionary, _distance: float) -> float:
	var speed = 104.0
	if m.level != 2: return speed
	speed *= 1.08
	if (m.type == "MELEE" or m.ammo <= 0) and not m.sprint_locked and m.stamina > 0:
		speed *= 1.5
		m.stamina = maxf(0, m.stamina - DT)
		m.regen = 0.85
		if m.stamina <= 0: m.sprint_locked = true
	return speed

func fire_mob(m: Dictionary) -> void:
	if m.cooldown > 0 or m.reload > 0 or m.ammo <= 0: return
	var grenade = "GRENADIER" in m.type
	if not grenade and m.mag <= 0:
		m.reload = 1.0
		return
	m.cooldown = 2.8 if grenade else (0.2 if "ASSAULT" in m.type else 1.35)
	m.ammo -= 1
	m.mag = maxi(0, m.mag - 1)
	m.shot += 1
	spawn_shot(m.id, m.p, m.aim, true, 380.0 if grenade else 520.0, 10.0 if "ASSAULT" in m.type else 15.0, grenade, m.radius + (15 if grenade else 9))
	if not grenade and m.mag == 0 and m.ammo > 0: m.reload = 1.0

func move_mob(m: Dictionary, destination: Vector2, speed: float) -> void:
	var direction: Vector2 = (destination - m.p).normalized()
	if not map.clear_line(m.p, destination, m.radius, gates):
		if time >= m.path_at and paths_this_tick < 3:
			paths_this_tick += 1
			m.path = navigation_path(m.p, destination, m.radius)
			m.path_at = time + 0.45
		while not m.path.is_empty() and m.p.distance_to(m.path[0]) < 15:
			m.path.remove_at(0)
		if m.path.is_empty(): return
		direction = (m.path[0] - m.p).normalized()
	m.p = map.move_body(m.p, direction * speed * DT, m.radius, gates)

func navigation_path(from: Vector2, destination: Vector2, radius: float) -> PackedVector2Array:
	var category = int(radius)
	if nav_revision != gate_revision:
		nav_grids.clear()
		nav_revision = gate_revision
	if not nav_grids.has(category):
		var grid = AStarGrid2D.new()
		grid.region = Rect2i(0, 0, ceili(map.width / 32), ceili(map.height / 32))
		grid.cell_size = Vector2(32, 32)
		grid.offset = Vector2(16, 16)
		grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		grid.update()
		# Mark expanded rectangles directly, without testing the entire world per cell.
		var rectangles: Array = map.obstacles.duplicate()
		rectangles.append_array(gates)
		for rectangle in rectangles:
			var expanded: Rect2 = rectangle.grow(radius)
			var a = Vector2i(ceili((expanded.position.x - 16) / 32), ceili((expanded.position.y - 16) / 32))
			var b = Vector2i(floori((expanded.end.x - 16) / 32), floori((expanded.end.y - 16) / 32))
			var area = Rect2i(a, b - a + Vector2i.ONE).intersection(grid.region)
			if area.has_area(): grid.fill_solid_region(area)
		for x in range(grid.region.size.x):
			for y in [0, 1, 2, grid.region.size.y - 1, grid.region.size.y - 2, grid.region.size.y - 3]:
				if grid.is_in_bounds(x, y): grid.set_point_solid(Vector2i(x, y))
		for y in range(grid.region.size.y):
			grid.set_point_solid(Vector2i(0, y))
			grid.set_point_solid(Vector2i(grid.region.size.x - 1, y))
		nav_grids[category] = grid
	var grid: AStarGrid2D = nav_grids[category]
	var start = Vector2i(floori(from.x / 32), floori(from.y / 32))
	var goal = Vector2i(floori(destination.x / 32), floori(destination.y / 32))
	start = nearest_cell(grid, start)
	goal = nearest_cell(grid, goal)
	if start.x < 0 or goal.x < 0: return PackedVector2Array()
	return grid.get_point_path(start, goal, true)

func nearest_cell(grid: AStarGrid2D, cell: Vector2i) -> Vector2i:
	for ring in range(5):
		for x in range(cell.x - ring, cell.x + ring + 1):
			for y in range(cell.y - ring, cell.y + ring + 1):
				if grid.is_in_bounds(x, y) and not grid.is_point_solid(Vector2i(x, y)):
					return Vector2i(x, y)
	return Vector2i(-1, -1)

func eject_and_separate() -> void:
	var actors = players.values() + mobs.filter(func(m): return m.spawned)
	for actor in actors:
		if not actor.alive: continue
		for gate in gates:
			if gate.grow(actor.radius).has_point(actor.p):
				var expanded: Rect2 = gate.grow(actor.radius + 0.5)
				var candidates = [Vector2(expanded.position.x, actor.p.y), Vector2(expanded.end.x, actor.p.y), Vector2(actor.p.x, expanded.position.y), Vector2(actor.p.x, expanded.end.y)]
				candidates.sort_custom(func(a, b): return a.distance_squared_to(actor.p) < b.distance_squared_to(actor.p))
				for candidate in candidates:
					if not map.blocked(candidate, actor.radius, gates):
						actor.p = candidate
						break
	# Pair separation prevents enemies and players occupying the same point.
	for i in range(actors.size()):
		var a = actors[i]
		if not a.alive: continue
		for j in range(i + 1, actors.size()):
			var b = actors[j]
			if not b.alive: continue
			var offset: Vector2 = b.p - a.p
			var overlap = a.radius + b.radius - offset.length()
			if overlap <= 0: continue
			var direction = offset.normalized() if offset.length() > 0.001 else Vector2.RIGHT
			a.p = map.move_body(a.p, -direction * overlap * 0.5, a.radius, gates)
			b.p = map.move_body(b.p, direction * overlap * 0.5, b.radius, gates)

func snapshot(viewer: String) -> Dictionary:
	var public_players = []
	for p in players.values():
		var item = p.duplicate(true)
		if p.id != viewer: item.hints = {}
		public_players.append(item)
	var public_mobs = []
	for m in mobs:
		if not m.spawned: continue
		var item = {}
		for key in ["id", "p", "aim", "type", "level", "hp", "max_hp", "ammo", "alive", "radius", "shot", "swing"]: item[key] = m[key]
		public_mobs.append(item)
	var crate_state = []
	for crate in crates: crate_state.append({"opened": crate.opened, "loot": crate.loot if crate.opened else ""})
	return {"tick": tick, "time": time, "players": public_players, "mobs": public_mobs, "shots": shots,
		"truth_events": truth_events,
		"effects": effects, "gates": gates, "entrance_open": entrance_open,
		"coop": coop.map(func(c): return {"open": c.open, "charge": c.charge}),
		"trust": trust.map(func(c): return {"open": c.open}),
		"bridges": bridges.map(func(c): return {"safe": c.safe, "locked": c.locked, "remaining": c.remaining}),
		"dividers": dividers.map(func(c): return c.remaining), "relays": relays.map(func(c): return {"open": c.open, "remaining": c.remaining}),
		"checkpoints": checkpoints.map(func(c): return {"state": c.state, "charge": c.charge}),
		"crates": crate_state, "pickups": pickups.map(func(c): return c.available), "boosts": boosts.map(func(c): return c.available),
		"terminals": terminals.map(func(c): return c.claimed != ""), "won": won, "practice": practice}
