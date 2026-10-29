extends SceneTree

# Static presentation fixture using the actual view and world. No network or map writes.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var app = load("res://scripts/main.gd").new()
	root.add_child(app)
	app.set_physics_process(false)
	var world = CutoffWorld.new()
	world.initialize(app.map, [{"id": "1", "name": "Игрок 1"}, {"id": "2", "name": "Игрок 2"}])
	world.players["1"].p = world.terminals[0].p
	world.interact(world.players["1"])
	world.players["2"].p = Vector2(2140, 760)
	app.player_id = "2" if app.options.has("observer") else "1"
	app.online = true
	app.epoch = "visual-review"
	app.room = {"phase": "IN_GAME", "code": "TEST", "host": "1", "practice": false}
	app.game = world.snapshot(app.player_id)
	app.predicted = world.players[app.player_id].duplicate(true)
	app.view.lobby_changed()
	app.view.game_changed()
	# Keep the toast visible for review without mutating game logic.
	for notice in app.view.truth_notices: notice.expires += 60000
	await create_timer(90).timeout
	quit()
