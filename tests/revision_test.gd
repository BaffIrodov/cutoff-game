extends SceneTree

var checks = 0
var failures: Array = []
var route_results: Array = []
var source = CutoffMap.new()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func world() -> CutoffWorld:
	var w = CutoffWorld.new()
	w.initialize(source, [{"id": "1", "name": "Первый"}, {"id": "2", "name": "Второй"}])
	return w

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(source.load_file().is_empty(), "Production map validates")
	# Activate areas through the ordinary server step, not fire_trigger directly.
	for area in source.data.triggerAreas:
		var w = world()
		var before = w.mobs.filter(func(m): return m.spawned).size()
		var expected = w.mobs.filter(func(m): return m.definition.spawnTrigger == area.trigger).size()
		w.players["1"].p = CutoffMap.rect(area.area).get_center()
		w.step({})
		check(w.triggers.has(area.trigger) and w.mobs.filter(func(m): return m.spawned).size() == before + expected, "Walk into area spawns exact wave: " + area.trigger)
		check(w.mobs.filter(func(m): return m.definition.spawnTrigger == area.trigger).all(func(m): return m.route_active), "Same-tick spawn and route: " + area.trigger)
		for _i in range(10): w.step({})
		check(w.mobs.size() == 74, "Staying in area never duplicates mobs: " + area.trigger)
	# Exercise actual plate/console producer events that feed authored routes.
	var mechanisms = world()
	mechanisms.entrance_open = true
	for i in range(2): mechanisms.players[str(i + 1)].p = CutoffMap.point(mechanisms.coop[1].plates[i])
	for _i in range(76): mechanisms.update_mechanisms()
	check(mechanisms.triggers.has("cooperation-1-opened"), "Coop gate produces route event")
	check(mechanisms.mobs.filter(func(m): return m.definition.route.startTrigger == "cooperation-1-opened").all(func(m): return m.route_active), "Coop gate activates all six routes")
	for bridge in mechanisms.bridges:
		if bridge.get("triggers", {}).get("plate-pressed", "") == "gallery-bridge-plate-pressed": mechanisms.players["1"].p = CutoffMap.point(bridge.plate)
	mechanisms.update_mechanisms()
	check(mechanisms.triggers.has("gallery-bridge-plate-pressed") and mechanisms.mobs.filter(func(m): return m.definition.route.startTrigger == "gallery-bridge-plate-pressed").all(func(m): return m.route_active), "Bridge plate activates both routes")
	# Every hand-authored route runs through actual map collision and pathfinding.
	# Other actors are absent to measure route correctness independently of crowd combat.
	for definition in source.data.mobs:
		if not definition.route.enabled: continue
		var w = world()
		var mob = w.mobs.filter(func(m): return m.id == definition.id)[0]
		w.mobs = [mob]
		w.players.clear()
		w.fire_trigger(definition.spawnTrigger)
		w.fire_trigger(definition.route.startTrigger)
		var start: Vector2 = mob.p
		var destination = CutoffMap.point(definition.route.points[0])
		var steps = 0
		while mob.route_active and steps < 1200:
			w.time += CutoffMotor.DT
			w.paths_this_tick = 0
			w.update_mobs()
			steps += 1
		var reached = not mob.route_active and mob.p.distance_to(destination) < 8.1
		route_results.append({"mob": mob.id, "reached": reached, "seconds": steps / 60.0, "start": str(start), "end": str(mob.p), "destination": str(destination)})
		check(reached, "Route reaches authored destination: " + mob.id)
		w.fire_trigger("unrelated-event")
		check(not mob.route_active, "Unrelated trigger cannot restart completed route: " + mob.id)
	# Trigger before spawn must be remembered; repeated trigger must not reset a route.
	var crowd = world()
	crowd.players.clear()
	for event in ["trigger-spawn-1-part", "cooperation-1-opened", "gallery-bridge-plate-pressed", "final"]: crowd.fire_trigger(event)
	for _i in range(1200):
		if crowd.mobs.all(func(m): return not m.route_active): break
		crowd.step({})
	for mob in crowd.mobs:
		if mob.definition.route.enabled: check(not mob.route_active, "Route completes with all 74 actors present: " + mob.id)
	var w = world()
	var late = w.mobs.filter(func(m): return m.definition.spawnTrigger == "final")[0]
	late.definition = late.definition.duplicate(true)
	late.definition.route.startTrigger = "earlier"
	w.fire_trigger("earlier")
	check(not late.spawned and not late.route_active, "Route event before spawn does not create mob")
	w.fire_trigger("final")
	check(late.spawned and late.route_active, "Later spawn remembers earlier route event")
	late.route_active = false
	w.fire_trigger("earlier")
	check(not late.route_active, "Repeated event does not restart route")
	w = world()
	var assault = w.mobs.filter(func(m): return m.type == "ASSAULT" and m.ammo > 0)[0]
	w.fire_mob(assault)
	check(w.shots[-1].damage == 10 and is_equal_approx(w.shots[-1].v.length(), 520), "Mob automatic rifle matches original damage and bullet speed")
	var grenadier = w.mobs.filter(func(m): return m.type == "GRENADIER" and m.ammo > 0)[0]
	w.fire_mob(grenadier)
	check(is_equal_approx(w.shots[-1].v.length(), 380), "Mob grenade speed matches original")
	assault.level = 2
	check(is_equal_approx(w.mob_speed(assault, 300), 104 * 1.08), "Armed level-two gunner does not melee-sprint")
	assault.ammo = 0
	assault.stamina = CutoffMotor.DT * 0.5
	w.mob_speed(assault, 300)
	check(assault.sprint_locked and assault.stamina == 0 and is_equal_approx(w.mob_speed(assault, 300), 104 * 1.08), "Exhausted melee sprint locks until full recovery")
	# Open corridor test: level-two melee must reverse lateral movement, level one doesn't.
	var clear_data = source.data.duplicate(true)
	clear_data.obstacles = []
	var clear_map = CutoffMap.new()
	check(clear_map.load_data(clear_data).is_empty(), "Corridor fixture validates")
	for level in [1, 2]:
		w = CutoffWorld.new()
		w.initialize(clear_map, [{"id": "1", "name": "Target"}])
		var m = w.mobs[0]
		m.type = "MELEE"
		m.level = level
		m.spawned = true
		m.route_active = false
		m.p = Vector2(1100,450)
		m.target = "1"
		w.players["1"].p = Vector2(1500,450)
		w.mobs = [m]
		w.gates = []
		var positive = false
		var negative = false
		for _i in range(90):
			var old_y = m.p.y
			w.time += CutoffMotor.DT
			w.update_mobs()
			positive = positive or m.p.y - old_y > 0.1
			negative = negative or m.p.y - old_y < -0.1
		check(positive and negative if level == 2 else not positive and not negative, "Melee trajectory matches AI level " + str(level))
	w = world()
	w.players["1"].p = w.terminals[0].p
	w.interact(w.players["1"])
	w.interact(w.players["1"])
	var recipient = w.snapshot("1")
	var observer = w.snapshot("2")
	check(recipient.truth_events.size() == 1 and observer.truth_events.size() == 1, "Truth announcement is public and not duplicated on re-read")
	check(not observer.truth_events[0].has("requiredPlayers") and observer.players[0].hints.is_empty() and not recipient.players[0].hints.is_empty(), "Truth count remains private")
	# Uploaded map storage survives a new store instance; data never overwrites production.
	var storage = "res://artifacts/maps-test-" + str(Time.get_ticks_msec())
	var store = CutoffMapStore.new()
	check(store.initialize(CutoffMap.PRODUCTION_PATH, storage).is_empty(), "Server map store initializes")
	var custom = source.data.duplicate(true)
	custom.name = "Test custom map"
	custom.id = "test-custom"
	var registered = store.register(JSON.stringify(custom).to_utf8_buffer(), true)
	check(registered.error.is_empty() and registered.key != store.default_key, "Upload stores separate content-addressed map")
	var restarted = CutoffMapStore.new()
	check(restarted.initialize(CutoffMap.PRODUCTION_PATH, storage).is_empty() and restarted.entries.has(registered.key), "Custom map survives server restart")
	for invalid in [{}, {"worldWidth": "bad"}, {"formatVersion": 4}, {"mobs": [null]}]:
		check(not store.register(JSON.stringify(invalid).to_utf8_buffer()).error.is_empty(), "Malformed upload rejected without exception")
	var broken = custom.duplicate(true)
	broken.intelTerminals[0].checkpoint = 99
	check(not CutoffMap.new().load_data(broken).is_empty(), "Bad terminal index rejected")
	check(FileAccess.get_sha256(CutoffMap.PRODUCTION_PATH) == CutoffMap.PRODUCTION_SHA256, "Production bytes remain intact")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage.path_join(registered.key + ".map")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage))
	var report = {"checks": checks, "failures": failures, "routes": route_results}
	var file = FileAccess.open("res://artifacts/revision-test.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	print("REVISION_TEST checks=%d failures=%d routes=%d" % [checks, failures.size(), route_results.size()])
	quit(0 if failures.is_empty() else 1)
