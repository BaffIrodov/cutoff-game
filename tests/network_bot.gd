extends Node

var app
var role = ""
var started = 0
var create_sent = false
var join_sent = false
var ready_sent = false
var start_sent = false
var first_frame = 0
var initial_position = Vector2.ZERO
var original_id = ""
var interact_sent = false
var reconnect_sent = false
var resumed = false
var snapshots = 0
var last_tick = 0
var max_pending = 0
var epoch_before_restart = ""
var restart_sent = false
var report_written = false
var unauthorized_restart_sent = false
var match_epoch = ""
var upload_stage = 0
var upload_started = 0
var upload_bytes = PackedByteArray()
var custom_map_checked = false
var guest_map_check_started = 0

func _ready() -> void:
	role = app.options.bot
	started = Time.get_ticks_msec()
	app.nickname = role
	app.connect_to("127.0.0.1", role)

func write_json(path: String, value: Dictionary) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(value, "  "))

func _process(_delta: float) -> void:
	var now = Time.get_ticks_msec()
	if now - started > 45000:
		finish(false, "timeout")
		return
	if app.online and app.room.is_empty():
		if role == "host" and not create_sent:
			app.request("create")
			create_sent = true
		elif role != "host" and not join_sent and FileAccess.file_exists("res://artifacts/network-room.json"):
			var file = FileAccess.open("res://artifacts/network-room.json", FileAccess.READ)
			var info = JSON.parse_string(file.get_as_text())
			if info is Dictionary:
				app.request("join", info.code)
				join_sent = true
	if app.room.is_empty(): return
	if app.room.phase == "LOBBY":
		if app.options.has("custom-map"):
			if role == "host":
				if upload_stage == 0:
					var custom = app.map.data.duplicate(true)
					custom.id = "network-custom"
					custom.name = "NETWORK CUSTOM MAP"
					custom.labels.append({"x": 200, "y": 150, "text": "SERVER MAP TRANSFER TEST"})
					upload_bytes = JSON.stringify(custom).to_utf8_buffer()
					app.upload_map.rpc_id(1, upload_bytes, "wrong-key")
					upload_stage = 1
					return
				if upload_stage == 1:
					if app.last_notice != "Неверный ключ загрузки карт.": return
					app.upload_map.rpc_id(1, upload_bytes, "integration-test-token")
					upload_stage = 2
					return
				if app.map.data.id != "network-custom": return
			else:
				if guest_map_check_started == 0:
					if app.map.data.id != "network-custom": finish(false, "guest did not receive room map"); return
					app.request("select_map", CutoffMap.PRODUCTION_SHA256)
					app.upload_map.rpc_id(1, JSON.stringify(app.map.data).to_utf8_buffer(), "integration-test-token")
					guest_map_check_started = now
					return
				if now - guest_map_check_started < 700: return
				if app.map.data.id != "network-custom": finish(false, "guest changed host map"); return
			custom_map_checked = app.map.data.id == "network-custom" and app.map.data.labels[-1].text == "SERVER MAP TRANSFER TEST"
		if role == "host": write_json("res://artifacts/network-room.json", {"code": app.room.code})
		if not ready_sent:
			app.request("ready")
			ready_sent = true
		if role == "host" and not start_sent and app.room.players.size() == int(app.options.get("players", "2")) and app.room.players.all(func(p): return p.ready):
			app.request("start")
			start_sent = true
		return
	if app.game.is_empty() or app.predicted.is_empty(): return
	if first_frame == 0:
		first_frame = now
		initial_position = app.predicted.p
		original_id = app.player_id
		match_epoch = app.epoch
		print("BOT_GAME_STARTED role=%s id=%s" % [role, original_id])
	if app.game.tick != last_tick:
		last_tick = app.game.tick
		snapshots += 1
	max_pending = maxi(max_pending, app.pending.size())
	var elapsed = now - first_frame
	var input = CutoffMotor.idle()
	if role == "host" and app.predicted.p.x < 325 and not interact_sent:
		input.move = Vector2.RIGHT
	elif role != "host" and app.predicted.p.y < 590 and elapsed < 3000:
		input.move = Vector2.DOWN
	app.bot_input = input
	if role == "host" and elapsed > 1400 and not interact_sent:
		var authoritative = app.game.players.filter(func(p): return p.id == app.player_id)[0]
		if authoritative.p.distance_to(Vector2(350, 450)) < 70:
			app.queue_action("interact")
			interact_sent = true
	if role != "host" and elapsed > 2000 and not unauthorized_restart_sent:
		app.request("restart")
		unauthorized_restart_sent = true
	if role != "host" and elapsed > 2500 and elapsed < 8000 and app.epoch != match_epoch:
		finish(false, "guest could restart a match without host authority")
		return
	if role == "host" and elapsed > 3500 and not reconnect_sent:
		if not app.game.entrance_open:
			finish(false, "entrance did not open after movement and reliable interaction")
			return
		app.peer.close()
		app._connection_failed()
		reconnect_sent = true
		print("BOT_FORCED_DISCONNECT")
	if role == "host" and reconnect_sent and app.online and elapsed > 5000:
		resumed = app.player_id == original_id
	if role == "host" and elapsed > 9500 and not restart_sent:
		if not resumed:
			finish(false, "player identity not restored")
			return
		epoch_before_restart = app.epoch
		app.request("restart")
		restart_sent = true
	if role == "host" and restart_sent and app.epoch != epoch_before_restart and not app.game.is_empty():
		finish(true, "movement, interaction, loss recovery, resume and restart passed")
	elif role != "host" and elapsed > 16000:
		finish(snapshots > 50 and app.online, "guest remained connected")

func finish(success: bool, message: String) -> void:
	if report_written: return
	report_written = true
	var report = {"success": success, "message": message, "role": role, "snapshots": snapshots,
		"map_id": app.map.data.id, "map_hash": app.loaded_map_key, "custom_map_checked": custom_map_checked,
		"max_pending": max_pending, "rtt_ms": app.rtt_ms, "received_bytes": app.network_bytes, "same_player_after_resume": resumed,
		"prediction_ack": app.predicted.get("ack", -1), "server_tick": app.game.get("tick", -1), "position": str(app.predicted.get("p", Vector2.ZERO))}
	write_json("res://artifacts/network-" + role + ".json", report)
	print("NETWORK_BOT " + JSON.stringify(report))
	get_tree().quit(0 if success else 1)
