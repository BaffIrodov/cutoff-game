extends Node

const ASSETS = {"/": ["index.html", "text/html; charset=utf-8"], "/editor.js": ["editor.js", "text/javascript; charset=utf-8"],
	"/styles.css": ["styles.css", "text/css; charset=utf-8"], "/integration.js": ["integration.js", "text/javascript; charset=utf-8"],
	"/integration.css": ["integration.css", "text/css; charset=utf-8"]}
var app
var server = TCPServer.new()
var clients: Array = []
var catalog = CutoffEditorCatalog.new()
var port = 9081
var session = ""
var url = ""
var upload_busy = false

func _ready() -> void:
	catalog.initialize(app.options.get("editor-maps", CutoffMap.editable_maps_directory()), app.map)
	session = app.options.get("editor-session", Crypto.new().generate_random_bytes(24).hex_encode())
	port = int(app.options.get("editor-port", "9081"))
	var error = ERR_CANT_CREATE
	for candidate in range(port, port + (1 if app.options.has("editor-port") else 20)):
		error = server.listen(candidate, "127.0.0.1")
		if error == OK:
			port = candidate
			break
	if error != OK:
		app.notice("Не удалось открыть локальный редактор: " + error_string(error))
		return
	url = "http://127.0.0.1:%d/?token=%s" % [port, session]
	print("EDITOR_HTTP_READY port=%d" % port)

func _exit_tree() -> void:
	server.stop()
	for client in clients: client.peer.disconnect_from_host()

func _process(_delta: float) -> void:
	while server.is_connection_available():
		var peer = server.take_connection()
		if clients.size() >= 24: peer.disconnect_from_host(); continue
		clients.append({"peer": peer, "input": PackedByteArray(), "output": PackedByteArray(), "sent": 0, "header_end": -1,
			"length": 0, "headers": {}, "method": "", "path": "", "started": Time.get_ticks_msec(), "handled": false, "waiting": false})
	for client in clients.duplicate():
		var peer = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - client.started > 25000:
			if client.waiting: upload_busy = false
			peer.disconnect_from_host()
			clients.erase(client)
			continue
		if client.waiting:
			if not app.online or app.last_notice != "Загрузка карты на сервер…":
				var success = app.online and app.loaded_map_key == client.upload_key and app.last_notice.begins_with("Карта сохранена на сервере")
				respond(client, {"status": 200 if success else 400, "body": {"message": app.last_notice, "uploaded": success}})
				client.waiting = false
				upload_busy = false
		if not client.handled and peer.get_available_bytes() > 0:
			var read = peer.get_data(mini(65536, peer.get_available_bytes()))
			if read[0] != OK: peer.disconnect_from_host(); continue
			client.input.append_array(read[1])
			if client.header_end < 0: parse_headers(client)
			if not client.handled and client.header_end >= 0 and client.input.size() >= client.header_end + client.length:
				client.handled = true
				dispatch(client, client.input.slice(client.header_end, client.header_end + client.length))
		if not client.output.is_empty():
			var written = peer.put_partial_data(client.output.slice(client.sent, mini(client.output.size(), client.sent + 65536)))
			if written[0] != OK: peer.disconnect_from_host(); continue
			client.sent += written[1]
			if client.sent == client.output.size():
				peer.disconnect_from_host()
				clients.erase(client)

func parse_headers(client: Dictionary) -> void:
	var bytes: PackedByteArray = client.input
	var text = bytes.get_string_from_ascii()
	var end = text.find("\r\n\r\n")
	if end < 0:
		if bytes.size() > 16384: respond(client, CutoffEditorCatalog.failure(431, "Слишком длинный HTTP-заголовок."))
		return
	if end > 16384: respond(client, CutoffEditorCatalog.failure(431, "Слишком длинный HTTP-заголовок.")); return
	var lines = text.substr(0, end).split("\r\n")
	var first = lines[0].split(" ")
	if first.size() != 3: respond(client, CutoffEditorCatalog.failure(400, "Неверный HTTP-запрос.")); return
	client.method = first[0]
	client.path = first[1]
	for line in lines.slice(1):
		var at = line.find(":")
		if at <= 0: respond(client, CutoffEditorCatalog.failure(400, "Неверный HTTP-заголовок.")); return
		var key = line.substr(0, at).to_lower()
		if client.headers.has(key): respond(client, CutoffEditorCatalog.failure(400, "Повторный HTTP-заголовок.")); return
		client.headers[key] = line.substr(at + 1).strip_edges()
	var length = client.headers.get("content-length", "0")
	if not length.is_valid_int() or int(length) < 0 or client.headers.has("transfer-encoding"):
		respond(client, CutoffEditorCatalog.failure(400, "Неверный размер запроса.")); return
	client.length = int(length)
	client.header_end = end + 4
	if client.length > CutoffMap.MAX_BYTES: respond(client, CutoffEditorCatalog.failure(413, "Карта больше 512 КБ."))

func dispatch(client: Dictionary, body: PackedByteArray) -> void:
	var host = "127.0.0.1:%d" % port
	if client.headers.get("host", "") != host:
		respond(client, CutoffEditorCatalog.failure(403, "Редактор доступен только локально.")); return
	var path = client.path.split("?", true, 1)[0]
	var cookie = client.headers.get("cookie", "").split(";")
	var authenticated = false
	for part in cookie:
		if part.strip_edges() == "cutoff_editor_%d=" % port + session: authenticated = true
	var initial = client.method == "GET" and client.path == "/?token=" + session
	if not authenticated and not initial:
		respond(client, CutoffEditorCatalog.failure(403, "Откройте редактор кнопкой в игре или через «Редактор карт.cmd».")); return
	if client.method not in ["GET", "POST", "PUT"]:
		respond(client, CutoffEditorCatalog.failure(405, "Метод не поддерживается.")); return
	if client.method != "GET" and client.headers.get("origin", "") != "http://" + host:
		respond(client, CutoffEditorCatalog.failure(403, "Запрос должен исходить из локального редактора.")); return
	if client.method == "GET" and ASSETS.has(path):
		var asset = ASSETS[path]
		var response = {"status": 200, "bytes": FileAccess.get_file_as_bytes("res://editor/" + asset[0]), "type": asset[1]}
		if initial: response.cookie = "cutoff_editor_%d=%s; HttpOnly; SameSite=Strict; Path=/" % [port, session]
		respond(client, response); return
	catalog.current_map = app.map
	if path == "/api/editor/maps" and client.method == "GET":
		respond(client, {"status": 200, "body": catalog.descriptors()}); return
	if path.begins_with("/api/editor/maps/") and client.method == "GET":
		respond(client, catalog.get_map(path.trim_prefix("/api/editor/maps/").uri_decode())); return
	if path == "/api/integration/state" and client.method == "GET":
		var can_upload = app.online and app.uploads_allowed and (app.room.is_empty() or (app.room.phase == "LOBBY" and app.room.host == app.player_id))
		respond(client, {"status": 200, "body": {"connected": app.online, "canUpload": can_upload, "tokenRequired": app.upload_token_required,
			"message": app.last_notice, "server": app.address, "mapId": app.map.data.id, "mapKey": app.loaded_map_key,
			"mapsDirectory": ProjectSettings.globalize_path(catalog.directory)}}); return
	if client.method in ["POST", "PUT"]:
		var parser = JSON.new()
		if parser.parse(body.get_string_from_utf8()) != OK:
			respond(client, CutoffEditorCatalog.failure(400, "Повреждён JSON.")); return
		if path == "/api/editor/maps" and client.method == "POST":
			respond(client, catalog.save_map(parser.data, true)); return
		if path.begins_with("/api/editor/maps/") and client.method == "PUT":
			respond(client, catalog.save_map(parser.data, false, path.trim_prefix("/api/editor/maps/").uri_decode(), client.headers.get("if-match", ""))); return
		if path == "/api/integration/upload" and client.method == "POST":
			begin_upload(client, parser.data); return
		if path == "/api/integration/import" and client.method == "POST":
			respond(client, import_map(parser.data)); return
	respond(client, CutoffEditorCatalog.failure(404, "Не найдено."))

func import_map(data) -> Dictionary:
	if not data is Dictionary: return CutoffEditorCatalog.failure(400, "Нужен JSON карты.")
	var candidate = CutoffMap.new()
	var error = candidate.load_data(data)
	if not error.is_empty(): return CutoffEditorCatalog.failure(400, error)
	catalog.refresh()
	var original_id = str(data.id).to_lower()
	var pattern = RegEx.new()
	pattern.compile("[^a-z0-9-]")
	var base = pattern.sub(original_id, "-", true).substr(0, 28).trim_suffix("-")
	if base.is_empty(): base = "imported-map"
	var id = base
	var index = 1
	while catalog.records.has(id) or FileAccess.file_exists(catalog.directory.path_join(id + ".map")):
		id = base + "-import-" + str(index)
		index += 1
	data.id = id
	if id != original_id: data.name = str(data.name).substr(0, 80) + " — импорт"
	return catalog.save_map(data, true)

func begin_upload(client: Dictionary, payload) -> void:
	if not payload is Dictionary or not payload.get("mapId") is String or not payload.get("credential", "") is String:
		respond(client, CutoffEditorCatalog.failure(400, "Нужен ID сохранённой карты.")); return
	if not app.online:
		respond(client, CutoffEditorCatalog.failure(409, "Карта сохранена локально. Подключитесь к серверу в окне игры, затем повторите загрузку.")); return
	if upload_busy:
		respond(client, CutoffEditorCatalog.failure(409, "Дождитесь завершения предыдущей загрузки.")); return
	var entry = catalog.get_map(payload.mapId)
	if entry.status != 200: respond(client, entry); return
	var record = catalog.records[payload.mapId.to_lower()]
	if record.path.is_empty(): respond(client, CutoffEditorCatalog.failure(400, "Сначала сохраните отдельную рабочую копию.")); return
	client.upload_key = FileAccess.get_sha256(record.path)
	client.waiting = true
	upload_busy = true
	app.upload_file(record.path, payload.get("credential", ""))

func respond(client: Dictionary, response: Dictionary) -> void:
	client.handled = true
	var bytes: PackedByteArray = response.get("bytes", JSON.stringify(response.get("body", {})).to_utf8_buffer())
	var status = int(response.status)
	var header = "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'\r\n" % [status, "OK" if status < 400 else "Error", response.get("type", "application/json; charset=utf-8"), bytes.size()]
	if response.has("etag"): header += "ETag: " + response.etag + "\r\n"
	if response.has("cookie"): header += "Set-Cookie: " + response.cookie + "\r\n"
	client.output = (header + "\r\n").to_utf8_buffer()
	client.output.append_array(bytes)
	client.input.clear()
