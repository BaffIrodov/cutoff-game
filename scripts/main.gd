extends Node

const PROTOCOL = 2
const GRACE_MS = 90000
const MAX_INPUTS = 180
var map = CutoffMap.new()
var peer: ENetMultiplayerPeer
var is_server = false
var options = {}
var clients = {}
var leases = {}
var rooms = {}
var port = 9080
var server_clock = 0
var view
var test_mode = false
# Client state. A reconnect keeps the player token, never a transport peer ID.
var nickname = "Игрок"
var address = "127.0.0.1"
var token = ""
var player_id = ""
var online = false
var room = {}
var game = {}
var epoch = ""
var pending: Array = []
var predicted = {}
var sequence = 0
var send_counter = 0
var snapshot_buffer: Array = []
var visual_offset = Vector2.ZERO
var last_packet_ms = 0
var reconnect_at = 0
var reconnect_attempt = 0
var connecting_at = 0
var want_connection = false
var rtt_ms = 0
var last_ping = 0
var server_step_ms = 0.0
var queued_actions: Array = []
var dash_requested = false
var network_bytes = 0
var world_epoch_count = 0
var bot_input = {}
var frame_parts = {}
var last_active_ms = 0
var map_store = CutoffMapStore.new()
var map_catalog: Array = []
var selected_map = ""
var loaded_map_key = ""
var uploads_allowed = false
var upload_token_required = false
var last_notice = ""
var editor_service

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--"):
			var parts = argument.substr(2).split("=", true, 1)
			options[parts[0]] = parts[1] if parts.size() > 1 else "true"
	port = int(options.get("port", "9080"))
	var error = map.load_file(options.get("map", CutoffMap.PRODUCTION_PATH))
	if not error.is_empty():
		push_error(error)
		get_tree().quit(1)
		return
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_connection_failed)
	multiplayer.server_disconnected.connect(_connection_failed)
	is_server = options.has("server")
	if is_server:
		_start_server()
	else:
		if options.has("name"): nickname = options.name
		if options.has("connect"): address = options.connect
		if DisplayServer.get_name() != "headless":
			view = load("res://scripts/view.gd").new()
			view.app = self
			add_child(view)
		if options.has("bot"):
			var bot = load("res://tests/network_bot.gd").new()
			bot.app = self
			add_child(bot)
		elif options.has("autoconnect"):
			connect_to(address, nickname)
		elif options.has("editor-map") and view:
			view.open_editor.call_deferred()
		if options.has("editor-http"):
			ensure_editor_service()
		if options.has("run-for"):
			get_tree().create_timer(float(options["run-for"])).timeout.connect(func(): get_tree().quit())

func ensure_editor_service():
	if not is_instance_valid(editor_service):
		editor_service = load("res://scripts/editor_http.gd").new()
		editor_service.app = self
		add_child(editor_service)
	return editor_service

func _start_server() -> void:
	var storage = options.get("map-directory", CutoffMap.editable_maps_directory().get_base_dir().path_join("server_maps"))
	var map_error = map_store.initialize(options.get("map", CutoffMap.PRODUCTION_PATH), storage)
	if not map_error.is_empty():
		push_error(map_error)
		get_tree().quit(1)
		return
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, 64, 3)
	if error != OK:
		push_error("Не удалось открыть UDP-порт %d: %s" % [port, error_string(error)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	last_active_ms = Time.get_ticks_msec()
	print("CUTOFF_SERVER_READY port=%d map=%s protocol=%d" % [port, map.data.id, PROTOCOL])
	if options.has("run-for"):
		get_tree().create_timer(float(options["run-for"])).timeout.connect(func(): get_tree().quit())

func connect_to(host: String, name_value: String) -> void:
	address = host.strip_edges()
	nickname = name_value.strip_edges().left(24)
	if nickname.is_empty(): nickname = "Игрок"
	want_connection = true
	reconnect_attempt = 0
	open_connection()

func open_connection() -> void:
	if peer != null: peer.close()
	online = false
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(address, port, 3)
	if error != OK:
		_connection_failed()
		return
	multiplayer.multiplayer_peer = peer
	connecting_at = Time.get_ticks_msec()
	notice("Подключение к %s:%d…" % [address, port])

func _connected() -> void:
	hello.rpc_id(1, PROTOCOL, nickname, token, map_hash())

func _peer_connected(id: int) -> void:
	if is_server:
		clients[id] = {"id": "", "connected_at": Time.get_ticks_msec(), "window": 0, "requests": 0}
		var remote = peer.get_peer(id)
		if remote: remote.set_timeout(32, 5000, 15000)

func _peer_disconnected(id: int) -> void:
	if not is_server or not clients.has(id): return
	var player = clients[id].id
	clients.erase(id)
	if player.is_empty() or not leases.has(player) or leases[player].peer != id: return
	var lease = leases[player]
	lease.peer = 0
	lease.disconnected_at = Time.get_ticks_msec()
	lease.queue.clear()
	lease.actions.clear()
	lease.current_input = CutoffMotor.idle()
	var code = lease.room
	if rooms.has(code):
		var current_room = rooms[code]
		if current_room.world != null and current_room.world.players.has(player):
			current_room.world.players[player].connected = false
		broadcast_lobby(code)
	print("PLAYER_DISCONNECTED id=%s grace=90s" % player)

func _connection_failed() -> void:
	online = false
	connecting_at = 0
	pending.clear()
	dash_requested = false
	if want_connection:
		reconnect_at = Time.get_ticks_msec() + mini(8000, 500 * int(pow(2, mini(reconnect_attempt, 4))))
		reconnect_attempt += 1
		notice("Связь потеряна. Переподключение…")

func disconnect_client() -> void:
	want_connection = false
	online = false
	if peer != null: peer.close()
	room = {}
	game = {}
	predicted = {}
	player_id = ""
	token = ""
	epoch = ""
	pending.clear()
	snapshot_buffer.clear()
	if view: view.show_menu()

func map_hash() -> String:
	return loaded_map_key

@rpc("any_peer", "call_remote", "reliable", 0)
func hello(protocol: int, name_value: String, resume: String, hash_value: String) -> void:
	if not is_server: return
	var sender = multiplayer.get_remote_sender_id()
	if not clients.has(sender) or clients[sender].id != "": return
	if protocol != PROTOCOL:
		reject.rpc_id(sender, "Версия клиента отличается от сервера. Обнови клиент.")
		return
	var lease = {}
	var id = ""
	if resume.length() == 64:
		for candidate in leases:
			if leases[candidate].token == resume:
				lease = leases[candidate]
				id = candidate
				break
	if lease.is_empty():
		id = Crypto.new().generate_random_bytes(12).hex_encode()
		lease = {"token": Crypto.new().generate_random_bytes(32).hex_encode(), "peer": sender, "name": name_value.strip_edges().left(24),
			"room": "", "disconnected_at": 0, "queue": {}, "actions": [], "ack": 0, "action_seq": 0,
			"current_input": CutoffMotor.idle(), "last_input_ms": 0}
		if lease.name.is_empty(): lease.name = "Игрок"
		leases[id] = lease
	var old_peer = lease.peer
	lease.peer = sender
	lease.disconnected_at = 0
	lease.queue.clear()
	lease.actions.clear()
	clients[sender].id = id
	if old_peer != 0 and old_peer != sender and clients.has(old_peer): peer.disconnect_peer(old_peer)
	var key = rooms[lease.room].map_key if rooms.has(lease.room) else map_store.default_key
	send_catalog(sender)
	send_map(sender, key)
	welcome.rpc_id(sender, id, lease.token, lease.ack)
	if rooms.has(lease.room):
		var current_room = rooms[lease.room]
		if current_room.world != null and current_room.world.players.has(id): current_room.world.players[id].connected = true
		broadcast_lobby(lease.room)
	print("PLAYER_CONNECTED id=%s resumed=%s" % [id, not resume.is_empty()])

@rpc("authority", "call_remote", "reliable", 0)
func welcome(id: String, new_token: String, ack: int) -> void:
	if is_server: return
	if not player_id.is_empty() and id != player_id:
		room = {}
		game = {}
		predicted = {}
		epoch = ""
		notice("Сессия истекла или сервер перезапущен. Создай комнату заново.")
	player_id = id
	token = new_token
	sequence = ack
	pending.clear()
	online = true
	connecting_at = 0
	reconnect_attempt = 0
	last_packet_ms = Time.get_ticks_msec()
	if view: view.connected()

@rpc("authority", "call_remote", "reliable", 0)
func reject(message: String) -> void:
	if is_server: return
	want_connection = false
	online = false
	notice(message)
	if peer != null: peer.close()

func request(kind: String, value = null) -> void:
	if online: control.rpc_id(1, kind, value)
	else: notice("Сначала подключись к серверу.")

func send_catalog(destination: int) -> void:
	catalog_received.rpc_id(destination, map_store.catalog(), options.has("allow-map-upload"), options.has("map-upload-token"))

func send_map(destination: int, key: String) -> void:
	if clients[destination].get("map_key", "") == key: return
	clients[destination].map_key = key
	map_received.rpc_id(destination, key, map_store.entries[key].bytes)

func set_room_map(code: String, key: String) -> void:
	rooms[code].map_key = key
	rooms[code].ready.clear()
	for member in rooms[code].roster:
		if leases[member].peer != 0: send_map(leases[member].peer, key)
	broadcast_lobby(code)

@rpc("authority", "call_remote", "reliable", 0)
func catalog_received(items: Array, can_upload: bool, token_required: bool) -> void:
	if is_server: return
	map_catalog = items
	uploads_allowed = can_upload
	upload_token_required = token_required
	if view and online and room.is_empty(): view.connected()

@rpc("authority", "call_remote", "reliable", 0)
func map_received(key: String, bytes: PackedByteArray) -> void:
	if is_server: return
	var digest = HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	if digest.finish().hex_encode() != key:
		reject("Повреждена переданная сервером карта.")
		return
	var candidate = CutoffMap.new()
	var error = candidate.load_bytes(bytes)
	if not error.is_empty():
		reject(error)
		return
	map = candidate
	loaded_map_key = key
	selected_map = key
	last_packet_ms = Time.get_ticks_msec()
	if view and online and room.is_empty(): view.connected()

func upload_file(path: String, credential = "") -> void:
	var candidate = CutoffMap.new()
	var error = candidate.load_file(path)
	if not error.is_empty():
		notice(error)
		return
	if not online:
		notice("Подключись к серверу, затем загрузи сохранённую карту.")
		return
	notice("Загрузка карты на сервер…")
	upload_map.rpc_id(1, FileAccess.get_file_as_bytes(path), credential)

@rpc("any_peer", "call_remote", "reliable", 0)
func upload_map(bytes: PackedByteArray, credential: String) -> void:
	var id = allowed_sender()
	if id.is_empty(): return
	var lease = leases[id]
	if not options.has("allow-map-upload"):
		reject_notice(id, "Загрузка карт отключена владельцем сервера.")
		return
	if options.has("map-upload-token") and credential != options["map-upload-token"]:
		reject_notice(id, "Неверный ключ загрузки карт.")
		return
	if not lease.room.is_empty() and (not rooms.has(lease.room) or rooms[lease.room].host != id or rooms[lease.room].phase != "LOBBY"):
		reject_notice(id, "Загрузить карту может создатель комнаты до начала матча.")
		return
	var now = Time.get_ticks_msec()
	if now - lease.get("last_upload", -10000) < 2000:
		reject_notice(id, "Подожди две секунды перед следующей загрузкой.")
		return
	lease.last_upload = now
	var result = map_store.register(bytes, true)
	if not result.error.is_empty():
		reject_notice(id, result.error)
		return
	for client in clients:
		if not clients[client].id.is_empty(): send_catalog(client)
	if lease.room.is_empty(): send_map(lease.peer, result.key)
	else: set_room_map(lease.room, result.key)
	reject_notice(id, "Карта сохранена на сервере и выбрана. Другие игроки получат её автоматически.")

func allowed_sender() -> String:
	var sender = multiplayer.get_remote_sender_id()
	if not is_server or not clients.has(sender): return ""
	var client = clients[sender]
	var now = Time.get_ticks_msec()
	if now - client.window > 1000:
		client.window = now
		client.requests = 0
	client.requests += 1
	if client.requests > 150: return ""
	return client.id

@rpc("any_peer", "call_remote", "reliable", 0)
func control(kind: String, value = null) -> void:
	var id = allowed_sender()
	if id.is_empty(): return
	var lease = leases[id]
	var code = lease.room
	match kind:
		"ping": pong.rpc_id(lease.peer, int(value))
		"create":
			if not code.is_empty(): return
			if rooms.size() >= 16:
				reject_notice(id, "Сервер занят: достигнут предел комнат.")
				return
			code = new_code()
			var key = str(value) if value is String and map_store.entries.has(value) else map_store.default_key
			rooms[code] = {"host": id, "roster": [id], "ready": {}, "world": null, "epoch": "", "phase": "LOBBY", "practice": false, "map_key": key}
			lease.room = code
			send_map(lease.peer, key)
			broadcast_lobby(code)
		"join":
			var destination = str(value).strip_edges().to_upper()
			if not code.is_empty() or not rooms.has(destination):
				reject_notice(id, "Комната не найдена или ты уже в комнате.")
				return
			var target_room = rooms[destination]
			if target_room.phase != "LOBBY" or target_room.roster.size() >= 4:
				reject_notice(id, "Комната заполнена или матч уже начался.")
				return
			target_room.roster.append(id)
			lease.room = destination
			send_map(lease.peer, target_room.map_key)
			broadcast_lobby(destination)
		"select_map":
			if not value is String or not map_store.entries.has(value): return
			if code.is_empty():
				send_map(lease.peer, value)
			elif rooms.has(code) and rooms[code].host == id and rooms[code].phase == "LOBBY":
				set_room_map(code, value)
		"ready":
			if rooms.has(code) and rooms[code].phase == "LOBBY":
				rooms[code].ready[id] = not rooms[code].ready.get(id, false)
				broadcast_lobby(code)
		"start", "practice", "restart":
			if not rooms.has(code) or rooms[code].host != id: return
			var current_room = rooms[code]
			if kind == "practice":
				if not options.has("allow-practice"):
					reject_notice(id, "Тренировка включается параметром сервера --allow-practice.")
					return
				if current_room.roster.size() != 1:
					reject_notice(id, "Тренировка предназначена для одного игрока.")
					return
				current_room.practice = true
			elif kind == "start": current_room.practice = false
			var minimum = 1 if current_room.practice else maxi(2, map_store.entries[current_room.map_key].map.minimum_after(-1))
			if current_room.roster.size() < minimum:
				reject_notice(id, "Для этой карты нужно минимум %d игрока. Для одиночной проверки есть тренировка." % minimum)
				return
			if kind == "start":
				for member in current_room.roster:
					if leases[member].peer == 0 or not current_room.ready.get(member, false):
						reject_notice(id, "Все игроки должны подключиться и нажать «Готов».")
						return
			start_match(code)

func new_code() -> String:
	var letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	while true:
		var code = ""
		for _i in range(5): code += letters[randi() % letters.length()]
		if not rooms.has(code): return code
	return ""

func start_match(code: String) -> void:
	var current_room = rooms[code]
	var roster = []
	for id in current_room.roster:
		roster.append({"id": id, "name": leases[id].name})
		leases[id].queue.clear()
		leases[id].actions.clear()
		leases[id].ack = 0
		leases[id].action_seq = 0
		leases[id].current_input = CutoffMotor.idle()
		leases[id].last_input_ms = 0
	current_room.world = CutoffWorld.new()
	current_room.world.initialize(map_store.entries[current_room.map_key].map, roster, current_room.practice)
	current_room.epoch = Crypto.new().generate_random_bytes(8).hex_encode()
	current_room.phase = "IN_GAME"
	broadcast_lobby(code)
	print("MATCH_STARTED room=%s players=%d practice=%s" % [code, roster.size(), current_room.practice])

func broadcast_lobby(code: String) -> void:
	if not rooms.has(code): return
	var current_room = rooms[code]
	var roster = []
	for id in current_room.roster:
		roster.append({"id": id, "name": leases[id].name, "ready": current_room.ready.get(id, false), "connected": leases[id].peer != 0})
	var payload = {"code": code, "host": current_room.host, "players": roster, "phase": current_room.phase, "map_name": map_store.entries[current_room.map_key].map.data.name, "map_key": current_room.map_key,
		"epoch": current_room.epoch, "practice": current_room.practice}
	for id in current_room.roster:
		if leases[id].peer != 0: lobby.rpc_id(leases[id].peer, payload)

@rpc("authority", "call_remote", "reliable", 0)
func lobby(payload: Dictionary) -> void:
	if is_server: return
	last_packet_ms = Time.get_ticks_msec()
	if payload.epoch != epoch:
		epoch = payload.epoch
		game = {}
		predicted = {}
		sequence = 0
		pending.clear()
		snapshot_buffer.clear()
		visual_offset = Vector2.ZERO
		world_epoch_count += 1
	room = payload
	if view: view.lobby_changed()

func reject_notice(id: String, message: String) -> void:
	if leases.has(id) and leases[id].peer != 0: remote_notice.rpc_id(leases[id].peer, message)

@rpc("authority", "call_remote", "reliable", 0)
func remote_notice(message: String) -> void:
	if not is_server: notice(message)

@rpc("authority", "call_remote", "unreliable", 2)
func pong(sent_ms: int) -> void:
	if not is_server:
		rtt_ms = Time.get_ticks_msec() - sent_ms
		last_packet_ms = Time.get_ticks_msec()

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func commands(match_epoch: String, packet: PackedByteArray) -> void:
	var id = allowed_sender()
	if id.is_empty() or packet.is_empty() or packet.size() > 16 * 21 or packet.size() % 21 != 0: return
	var batch = []
	for offset in range(0, packet.size(), 21):
		var flags = packet[offset + 20]
		batch.append({"seq": packet.decode_u32(offset), "move": Vector2(packet.decode_float(offset + 4), packet.decode_float(offset + 8)),
			"aim": Vector2(packet.decode_float(offset + 12), packet.decode_float(offset + 16)), "run": bool(flags & 1), "fire": bool(flags & 2), "dash": bool(flags & 4)})
	accept_commands(id, match_epoch, batch)

func pack_commands(batch: Array) -> PackedByteArray:
	var packet = PackedByteArray()
	packet.resize(batch.size() * 21)
	for i in range(batch.size()):
		var command = batch[i]
		var offset = i * 21
		packet.encode_u32(offset, command.seq)
		packet.encode_float(offset + 4, command.move.x)
		packet.encode_float(offset + 8, command.move.y)
		packet.encode_float(offset + 12, command.aim.x)
		packet.encode_float(offset + 16, command.aim.y)
		packet[offset + 20] = int(command.run) | (int(command.fire) << 1) | (int(command.dash) << 2)
	return packet

func accept_commands(id: String, match_epoch: String, batch: Array) -> void:
	var lease = leases[id]
	if not rooms.has(lease.room): return
	var current_room = rooms[lease.room]
	if current_room.epoch != match_epoch or current_room.phase != "IN_GAME": return
	for item in batch:
		if not item is Dictionary: continue
		var seq = int(item.get("seq", 0))
		if seq <= lease.ack or seq > lease.ack + MAX_INPUTS or lease.queue.has(seq): continue
		var movement = item.get("move", Vector2.ZERO)
		var aim = item.get("aim", Vector2.RIGHT)
		if not movement is Vector2 or not aim is Vector2 or not movement.is_finite() or not aim.is_finite(): continue
		lease.queue[seq] = {"seq": seq, "move": movement.limit_length(), "aim": aim.normalized(), "run": bool(item.get("run", false)),
			"fire": bool(item.get("fire", false)), "dash": bool(item.get("dash", false))}
		lease.last_input_ms = Time.get_ticks_msec()

@rpc("any_peer", "call_remote", "reliable", 0)
func action(match_epoch: String, number: int, kind: String, value = null) -> void:
	var id = allowed_sender()
	if id.is_empty(): return
	var lease = leases[id]
	if not rooms.has(lease.room) or rooms[lease.room].epoch != match_epoch or number <= lease.action_seq: return
	lease.action_seq = number
	if kind == "dash" and value is Dictionary:
		accept_commands(id, match_epoch, [value])
	elif kind in ["interact", "attack", "reload", "slot", "heal", "heal_other", "transfer"] and lease.actions.size() < 32:
		if kind == "slot" and not (value is int or value is float): return
		lease.actions.append({"player": id, "kind": kind, "value": value})

var action_number = 0
func queue_action(kind: String, value = null) -> void:
	if online and not epoch.is_empty():
		action_number += 1
		action.rpc_id(1, epoch, action_number, kind, value)

func _physics_process(_delta: float) -> void:
	if is_server:
		server_tick()
		return
	var now = Time.get_ticks_msec()
	if want_connection and not online:
		if connecting_at > 0 and now - connecting_at > 10000:
			if peer != null: peer.close()
			_connection_failed()
		elif connecting_at == 0 and now >= reconnect_at: open_connection()
	if not online: return
	if now - last_packet_ms > 10000 and not room.is_empty() and room.phase == "IN_GAME":
		peer.close()
		_connection_failed()
		return
	if now - last_ping >= 1000:
		last_ping = now
		request("ping", now)
	if predicted.is_empty() or game.is_empty() or room.get("phase", "") != "IN_GAME": return
	sequence += 1
	var input = view.sample_input() if view else (bot_input.duplicate() if not bot_input.is_empty() else CutoffMotor.idle())
	input.seq = sequence
	if dash_requested:
		input.dash = true
		dash_requested = false
		queue_action("dash", input)
	pending.append(input)
	CutoffMotor.step(predicted, input, map, game.gates, remote_player_actors())
	# A bounded window is repeated in each datagram; isolated packet loss cannot leave keys stuck.
	if pending.size() > 150:
		peer.close()
		_connection_failed()
		return
	send_counter += 1
	if send_counter % 2 == 0:
		commands.rpc_id(1, epoch, pack_commands(pending.slice(maxi(0, pending.size() - 16))))

func remote_player_actors() -> Array:
	return game.get("players", []).filter(func(p): return p.id != player_id and p.alive) + game.get("mobs", []).filter(func(m): return m.alive)

func server_tick() -> void:
	server_clock += 1
	if not clients.is_empty(): last_active_ms = Time.get_ticks_msec()
	elif options.has("idle-exit") and Time.get_ticks_msec() - last_active_ms > int(options["idle-exit"]) * 1000:
		get_tree().quit()
	for code in rooms:
		var current_room = rooms[code]
		if current_room.world == null: continue
		var inputs = {}
		var actions_for_tick = []
		for id in current_room.roster:
			var lease = leases[id]
			if not lease.queue.is_empty() and lease.peer != 0:
				var keys = lease.queue.keys()
				keys.sort()
				var key = keys[-1]
				var latest = lease.queue[key].duplicate()
				# Input is a current control state, not a backlog of simulation time.
				# A slow server or burst of packets must never build seconds of input lag.
				for number in keys:
					var command = lease.queue[number]
					if command.dash:
						latest.dash = true
						latest.dash_direction = command.move.normalized() if command.move.length_squared() > 0.01 else command.aim
				inputs[id] = latest
				lease.ack = key
				lease.current_input = latest.duplicate()
				lease.current_input.seq = 0
				lease.current_input.dash = false
				lease.queue.clear()
			elif lease.peer != 0 and Time.get_ticks_msec() - lease.last_input_ms < 250:
				inputs[id] = lease.current_input
			actions_for_tick.append_array(lease.actions)
			lease.actions.clear()
		current_room.world.step(inputs, actions_for_tick)
		if server_clock % 3 == 0:
			for id in current_room.roster:
				if leases[id].peer == 0: continue
				var payload = current_room.world.snapshot(id)
				payload.epoch = current_room.epoch
				payload.step_us = current_room.world.last_step_us
				var raw = var_to_bytes(payload)
				var compressed = raw.compress(FileAccess.COMPRESSION_ZSTD)
				var pieces = ceili(compressed.size() / 1000.0)
				for index in range(pieces):
					state_piece.rpc_id(leases[id].peer, current_room.epoch, current_room.world.tick, index, pieces, raw.size(), compressed.slice(index * 1000, (index + 1) * 1000))
	if server_clock % 60 == 0: expire_leases()

func expire_leases() -> void:
	var now = Time.get_ticks_msec()
	for id in leases.keys():
		var lease = leases[id]
		if lease.peer != 0 or lease.disconnected_at == 0 or now - lease.disconnected_at < GRACE_MS: continue
		var code = lease.room
		if rooms.has(code):
			var current_room = rooms[code]
			current_room.roster.erase(id)
			if current_room.world != null and current_room.world.players.has(id):
				current_room.world.players[id].alive = false
				current_room.world.players[id].hp = 0.0
			if current_room.roster.is_empty(): rooms.erase(code)
			else:
				if current_room.host == id: current_room.host = current_room.roster[0]
				broadcast_lobby(code)
		leases.erase(id)
	for id in clients.keys():
		if clients[id].id == "" and now - clients[id].connected_at > 10000: peer.disconnect_peer(id)

@rpc("authority", "call_remote", "unreliable", 2)
func state_piece(match_epoch: String, frame_tick: int, index: int, total: int, raw_size: int, piece: PackedByteArray) -> void:
	if is_server or match_epoch != epoch or total < 1 or total > 128 or index < 0 or index >= total or piece.size() > 1000 or raw_size < 1 or raw_size > 524288: return
	if not game.is_empty() and frame_tick <= game.tick: return
	var now = Time.get_ticks_msec()
	for key in frame_parts.keys():
		if now - frame_parts[key].at > 500 or frame_parts[key].epoch != epoch: frame_parts.erase(key)
	if not frame_parts.has(frame_tick):
		if frame_parts.size() >= 12: return
		frame_parts[frame_tick] = {"at": now, "epoch": epoch, "total": total, "size": raw_size, "pieces": {}}
	var part = frame_parts[frame_tick]
	if part.total != total or part.size != raw_size: return
	part.pieces[index] = piece
	if part.pieces.size() != total: return
	var compressed = PackedByteArray()
	for i in range(total): compressed.append_array(part.pieces[i])
	frame_parts.erase(frame_tick)
	var bytes = compressed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if bytes.is_empty(): return
	var payload = bytes_to_var(bytes)
	if not payload is Dictionary or payload.get("epoch", "") != epoch: return
	if not game.is_empty() and payload.tick <= game.tick: return
	last_packet_ms = Time.get_ticks_msec()
	network_bytes += compressed.size()
	server_step_ms = float(payload.step_us) / 1000
	game = payload
	var own = {}
	for p in payload.players:
		if p.id == player_id: own = p
	if own.is_empty(): return
	var old_visual: Vector2 = predicted.get("p", own.p) + visual_offset
	pending = pending.filter(func(cmd): return cmd.seq > own.ack)
	sequence = maxi(sequence, int(own.ack))
	predicted = own.duplicate(true)
	for input in pending: CutoffMotor.step(predicted, input, map, game.gates, remote_player_actors())
	var error: Vector2 = old_visual - predicted.p
	visual_offset = error if error.length() < 96 else Vector2.ZERO
	snapshot_buffer.append({"at": Time.get_ticks_msec(), "data": payload})
	if snapshot_buffer.size() > 8: snapshot_buffer.pop_front()
	if view: view.game_changed()

func render_state() -> Dictionary:
	if game.is_empty(): return {}
	var result = game.duplicate(false)
	var now = Time.get_ticks_msec() - 100
	var a = {}
	var b = {}
	for item in snapshot_buffer:
		if item.at <= now: a = item
		elif b.is_empty(): b = item
	var alpha = 1.0
	if not a.is_empty() and not b.is_empty() and b.at > a.at:
		alpha = clampf(float(now - a.at) / (b.at - a.at), 0, 1)
	else:
		a = {"data": game}
		b = {"data": game}
	for key in ["players", "mobs", "shots"]:
		var previous = {}
		for actor in a.data[key]: previous[actor.id] = actor
		var actors = []
		for actor in b.data[key]:
			var copy = actor.duplicate(false)
			if key == "players" and actor.id == player_id and not predicted.is_empty():
				copy = predicted.duplicate(false)
				copy.p += visual_offset
			elif previous.has(actor.id): copy.p = previous[actor.id].p.lerp(actor.p, alpha)
			actors.append(copy)
		result[key] = actors
	return result

func _process(delta: float) -> void:
	visual_offset *= exp(-delta * 18)

func notice(message: String) -> void:
	last_notice = message
	print("NOTICE " + message)
	if view: view.set_notice(message)
