extends SceneTree

var failures: Array = []
var checks = 0
var map = CutoffMap.new()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)

func world(count = 2, practice = false) -> CutoffWorld:
	var roster = []
	for i in range(count): roster.append({"id": str(i + 1), "name": "Тест " + str(i + 1)})
	var result = CutoffWorld.new()
	result.initialize(map, roster, practice)
	return result

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(map.load_file().is_empty(), "Production map parses")
	check(FileAccess.get_sha256(CutoffMap.PRODUCTION_PATH) == CutoffMap.PRODUCTION_SHA256, "Production map exact SHA256")
	check(map.data.mobs.size() == 74 and map.obstacles.size() == 176, "All hand-authored entities preserved")
	var w = world()
	check(w.mobs.filter(func(m): return m.spawned).size() == 57, "Only world-created mobs initially spawn")
	w.fire_trigger("trigger-spawn-1-part")
	check(w.mobs.filter(func(m): return m.spawned).size() == 69, "Delayed 12-mob wave spawns")
	w.fire_trigger("trigger-spawn-1-part")
	check(w.mobs.size() == 74, "Triggers are idempotent")
	w.fire_trigger("final")
	check(w.mobs.all(func(m): return m.spawned), "Final wave spawns")
	var p = CutoffMotor.player("x", "x", Vector2(120, 400))
	var input = CutoffMotor.idle()
	input.move = Vector2.RIGHT
	for _i in range(60): CutoffMotor.step(p, input, map, [])
	check(absf(p.p.x - 310) < 0.01, "190 units per second deterministic motor")
	var replay = CutoffMotor.player("x", "x", Vector2(120, 400))
	for _i in range(60): CutoffMotor.step(replay, input, map, [])
	check(replay == p, "Prediction and server motor reproduce identical state")
	p.p = Vector2(420, 450)
	input.dash = true
	CutoffMotor.step(p, input, map, [CutoffMap.rect(map.data.entrance.gate)])
	input.dash = false
	for _i in range(15): CutoffMotor.step(p, input, map, [CutoffMap.rect(map.data.entrance.gate)])
	check(p.p.x < 446.1, "Dash cannot cross closed entrance")
	w = world()
	w.players["1"].p = Vector2(350, 450)
	w.interact(w.players["1"])
	check(w.entrance_open and w.triggers.has("reactor-entrance-opened"), "Entrance console and authored trigger")
	for i in range(2): w.players[str(i + 1)].p = CutoffMap.point(w.coop[0].plates[i])
	for _i in range(76): w.update_mechanisms()
	check(w.coop[0].open, "Two distinct players charge cooperative gate")
	w.players["1"].p = CutoffMap.point(w.trust[0].plate)
	w.update_mechanisms()
	check(w.trust[0].open, "Trust plate opens fire pocket")
	w.players["1"].p = Vector2(120, 400)
	w.players["2"].p = CutoffMap.point(w.trust[0].pocket) + Vector2(50, 50)
	var hp = w.players["2"].hp
	w.update_mechanisms()
	check(not w.trust[0].open and w.players["2"].hp < hp, "Releasing trust plate restores fire damage")
	w.players["1"].p = CutoffMap.point(w.bridges[0].overrideConsole)
	w.interact(w.players["1"])
	check(w.bridges[0].locked and w.bridges[0].safe, "Bridge override permanently locks safety")
	w.players["1"].p = CutoffMap.point(w.dividers[0].controls[0])
	w.interact(w.players["1"])
	check(w.dividers[0].remaining == 3, "Timed divider opens for three seconds")
	for i in range(2):
		w.players["1"].p = CutoffMap.point(w.relays[0].nodes[i])
		w.interact(w.players["1"])
	w.update_mechanisms()
	check(w.relays[0].open, "Relay nodes open linked gate")
	w = world()
	p = w.players["1"]
	p.p = w.terminals[0].p
	w.interact(p)
	check(p.hints.has(1), "Terminal reveals private checkpoint target")
	var other_view = w.snapshot("2")
	check(other_view.players[0].hints.is_empty(), "Other players cannot read private hints")
	check(not other_view.checkpoints[0].has("requiredPlayers"), "Public snapshot does not leak checkpoint plan")
	check(not other_view.crates[0].has("p") and other_view.crates[0].loot == "", "Unopened loot and static geometry not sent")
	w = world()
	w.players["1"].p = w.pickups[0].p
	w.collect_items()
	check(w.players["1"].rifle and w.players["1"].ammo == 5, "Map rifle pickup")
	p = w.players["1"]
	p.slot = 1
	w.attack("1")
	check(p.ammo == 4 and w.shots.size() == 1, "Rifle spends exactly one round")
	w.attack("1")
	check(p.ammo == 4, "Weapon fire rate is enforced")
	p.reserve = 5
	w.reload_weapon(p)
	for _i in range(61): w.step({})
	check(p.ammo == 5 and p.reserve == 4, "One-second rifle reload")
	p.slot = 4
	w.damage_actor(w.players["2"], 250)
	w.players["2"].p = p.p + Vector2(45, 0)
	w.heal(p, true)
	check(not w.players["2"].down and w.players["2"].hp == 50 and p.medkits == 0, "Medkit revives nearby ally")
	w.damage_actor(w.players["2"], 250)
	for _i in range(301): w.step({})
	check(not w.players["2"].alive, "Knockout becomes death after five seconds")
	w = world()
	w.targets[0] = 2
	for i in range(2): w.players[str(i + 1)].p = CutoffMap.point(w.checkpoints[0].platforms[i])
	for _i in range(121): w.update_checkpoints()
	check(w.checkpoints[0].state == "CLEARED", "Correct survivor count clears checkpoint")
	w = world(3)
	w.targets[0] = 2
	for i in range(3): w.players[str(i + 1)].p = CutoffMap.point(w.checkpoints[0].platforms[i])
	for _i in range(121): w.update_checkpoints()
	check(w.checkpoints[0].state == "FAILED" and w.players.values().all(func(actor): return not actor.alive), "Wrong survivor count destroys team")
	w = world(1, true)
	check(w.targets.all(func(value): return value == 1), "Solo training changes runtime rules, not the map")
	# Stress all major sectors simultaneously, keeping actors alive for the entire sample.
	w = world(4)
	w.entrance_open = true
	w.fire_trigger("trigger-spawn-1-part")
	w.fire_trigger("final")
	w.refresh_gates()
	var positions = [Vector2(1100, 450), Vector2(2700, 450), Vector2(6000, 450), Vector2(9800, 450)]
	for i in range(4):
		w.players[str(i + 1)].p = positions[i]
		w.players[str(i + 1)].hp = 1000000.0
	var times = []
	for _i in range(300):
		w.step({})
		times.append(w.last_step_us)
	times.sort()
	var sizes = []
	for id in w.players: sizes.append(var_to_bytes(w.snapshot(id)).compress(FileAccess.COMPRESSION_ZSTD).size())
	print("PERF ticks=300 mobs=74 step_p50_ms=%.3f step_p95_ms=%.3f step_max_ms=%.3f compressed_snapshot_bytes=%s" % [times[150] / 1000.0, times[285] / 1000.0, times[-1] / 1000.0, str(sizes)])
	print("WORLD_TEST checks=%d failures=%d" % [checks, failures.size()])
	var report = FileAccess.open("res://artifacts/world-test.json", FileAccess.WRITE)
	if report:
		report.store_string(JSON.stringify({"checks": checks, "failures": failures, "p50_ms": times[150] / 1000.0, "p95_ms": times[285] / 1000.0, "max_ms": times[-1] / 1000.0, "snapshots": sizes}, "  "))
	quit(0 if failures.is_empty() else 1)
