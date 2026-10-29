class_name CutoffMap
extends RefCounted

const PRODUCTION_PATH = "res://maps/emergency-reactor-copy.map"
const PRODUCTION_SHA256 = "bba06fe78c0d82944db42b4449fb4097b7f9537f8eff29869b9a4af2e0d67d8f"
const MAX_BYTES = 524288
var data = {}
var obstacles: Array[Rect2] = []
var buckets = {}
var width = 11000.0
var height = 900.0

func load_file(path = PRODUCTION_PATH) -> String:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "Не удалось открыть карту: " + path
	if file.get_length() > MAX_BYTES: return "Карта больше 512 КБ."
	return load_bytes(file.get_buffer(file.get_length()))

func load_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty() or bytes.size() > MAX_BYTES: return "Размер карты должен быть от 1 байта до 512 КБ."
	var parser = JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return "Повреждён JSON карты: " + parser.get_error_message()
	return load_data(parser.data)

static func shape(value, keys: Dictionary) -> bool:
	if not value is Dictionary: return false
	for key in keys:
		if not value.has(key): return false
		var expected = keys[key]
		if expected == TYPE_FLOAT:
			if not (value[key] is float or value[key] is int) or not is_finite(float(value[key])): return false
		elif typeof(value[key]) != expected: return false
	return true

static func point_shape(value) -> bool:
	return shape(value, {"x": TYPE_FLOAT, "y": TYPE_FLOAT})

static func rect_shape(value) -> bool:
	return shape(value, {"x": TYPE_FLOAT, "y": TYPE_FLOAT, "width": TYPE_FLOAT, "height": TYPE_FLOAT})

static func validate_structure(source: Dictionary) -> String:
	if not shape(source, {"formatVersion": TYPE_FLOAT, "worldWidth": TYPE_FLOAT, "worldHeight": TYPE_FLOAT, "id": TYPE_STRING, "name": TYPE_STRING, "entrance": TYPE_DICTIONARY}): return "Неверные поля карты."
	if source.id.length() > 100 or source.name.length() > 100: return "Слишком длинное название карты."
	var groups = {"playerSpawns": 4, "obstacles": 1500, "mobs": 256, "checkpoints": 8, "cooperationGates": 64, "trustPockets": 64, "serviceBridges": 64, "separationGates": 64, "finalRelays": 64, "triggerAreas": 128, "weaponPickups": 128, "intelTerminals": 64, "lootCrates": 256, "healthBoostPickups": 128, "labels": 128}
	for key in groups:
		if not source.get(key) is Array or source[key].size() > groups[key]: return "Неверный список или превышен лимит: " + key
		for item in source[key]:
			if not item is Dictionary: return "Объект должен быть словарём: " + key
			if key in ["playerSpawns", "mobs", "weaponPickups", "intelTerminals", "lootCrates", "healthBoostPickups", "labels"] and not point_shape(item): return "Неверные координаты: " + key
			if key == "obstacles" and not rect_shape(item): return "Неверное препятствие."
			if key == "labels" and (not item.get("text") is String or item.text.length() > 200): return "Неверная подпись."
			if key == "weaponPickups" and not shape(item, {"ammo": TYPE_FLOAT}): return "Неверные патроны."
			if key == "intelTerminals" and not shape(item, {"checkpoint": TYPE_FLOAT, "checkpointId": TYPE_STRING}): return "Неверный терминал."
			if key == "triggerAreas" and (not rect_shape(item.get("area")) or not item.get("trigger") is String): return "Неверная область триггера."
			if key == "mobs":
				if not shape(item, {"type": TYPE_STRING, "level": TYPE_FLOAT, "health": TYPE_FLOAT, "ammo": TYPE_FLOAT, "spawnTrigger": TYPE_STRING, "route": TYPE_DICTIONARY}): return "Неверные поля противника."
				if not shape(item.route, {"enabled": TYPE_BOOL, "startTrigger": TYPE_STRING, "points": TYPE_ARRAY}) or not item.route.points.all(point_shape): return "Неверный маршрут."
			var rectangles = {"checkpoints": "exitGate", "cooperationGates": "gate", "trustPockets": "gate", "separationGates": "gate", "finalRelays": "gate", "serviceBridges": "hazard"}
			if rectangles.has(key) and not rect_shape(item.get(rectangles[key])): return "Неверная геометрия механизма: " + key
			if key == "trustPockets" and (not rect_shape(item.get("pocket")) or not point_shape(item.get("plate"))): return "Неверный карман."
			if key == "serviceBridges" and (not point_shape(item.get("plate")) or not point_shape(item.get("overrideConsole"))): return "Неверный мост."
			var points = {"checkpoints": "platforms", "cooperationGates": "plates", "separationGates": "controls", "finalRelays": "nodes"}
			if points.has(key):
				var list = item.get(points[key])
				if not list is Array or list.is_empty() or list.size() > 8 or not list.all(point_shape): return "Неверные точки механизма: " + key
			if key == "cooperationGates" and not shape(item, {"requiredPlayers": TYPE_FLOAT, "adaptiveToTeamSize": TYPE_BOOL}): return "Неверные правила шлюза."
			if key == "checkpoints" and not shape(item, {"maximumSurvivors": TYPE_FLOAT}): return "Неверные правила отсечки."
			if item.has("id") and (not item.id is String or item.id.length() > 100): return "Неверный ID."
			if not valid_triggers(item): return "Неверные события механизма."
	if not rect_shape(source.entrance.get("gate")) or not point_shape(source.entrance.get("console")) or not valid_triggers(source.entrance): return "Неверный входной шлюз."
	return ""

static func valid_triggers(item: Dictionary) -> bool:
	var triggers = item.get("triggers", {})
	return triggers is Dictionary and triggers.size() <= 12 and triggers.values().all(func(v): return v is String and v.length() > 0 and v.length() <= 100)

func load_data(source: Dictionary) -> String:
	var structure_error = validate_structure(source)
	if not structure_error.is_empty(): return structure_error
	if int(source.get("formatVersion", 0)) != 4:
		return "Поддерживается формат карты 4."
	for key in ["playerSpawns", "obstacles", "checkpoints", "entrance", "mobs"]:
		if not source.has(key):
			return "В карте отсутствует " + key
	if source.playerSpawns.size() != 4 or source.checkpoints.is_empty():
		return "Нужны четыре точки появления и хотя бы одна отсечка."
	var validation = validate(source)
	if not validation.is_empty(): return validation
	data = source.duplicate(true)
	width = float(data.worldWidth)
	height = float(data.worldHeight)
	obstacles.clear()
	buckets.clear()
	for item in data.obstacles:
		var r = rect(item)
		obstacles.append(r)
		for bx in range(floori(r.position.x / 128), floori(r.end.x / 128) + 1):
			for by in range(floori(r.position.y / 128), floori(r.end.y / 128) + 1):
				var key = Vector2i(bx, by)
				if not buckets.has(key):
					buckets[key] = []
				buckets[key].append(r)
	return ""

static func validate(source: Dictionary) -> String:
	var world_width = float(source.get("worldWidth", 0))
	var world_height = float(source.get("worldHeight", 0))
	if world_width < 960 or world_width > 20000 or world_height < 540 or world_height > 2000:
		return "Размеры мира: ширина 960–20000, высота 540–2000."
	if source.get("name", "").strip_edges().is_empty() or source.get("id", "").is_empty():
		return "Нужны ID и имя карты."
	if source.checkpoints.size() > 8: return "Максимум восемь отсечек."
	var bounds_error = validate_bounds(source, world_width, world_height)
	if not bounds_error.is_empty(): return bounds_error
	var ids = {}
	var fired = {"world-created": true}
	for key in ["cooperationGates", "trustPockets", "serviceBridges", "separationGates", "finalRelays", "checkpoints", "triggerAreas", "weaponPickups", "intelTerminals", "mobs"]:
		for item in source.get(key, []):
			if not item is Dictionary or not item.has("id") or str(item.id).is_empty(): return "Отсутствует ID: " + key
			if ids.has(item.id): return "Повторяющийся ID: " + item.id
			ids[item.id] = true
			for name in item.get("triggers", {}).values(): fired[name] = true
			if key == "triggerAreas": fired[item.get("trigger", "")] = true
	for name in source.entrance.get("triggers", {}).values(): fired[name] = true
	for gate in source.get("cooperationGates", []):
		if int(gate.get("requiredPlayers", 0)) not in [2, 3, 4] or gate.get("plates", []).size() != int(gate.requiredPlayers):
			return "Шлюз должен иметь 2, 3 или 4 связанные плиты: " + gate.id
	for relay in source.get("finalRelays", []):
		if relay.get("nodes", []).size() != 2: return "Реле должно иметь два узла: " + relay.id
	for checkpoint in source.checkpoints:
		if checkpoint.get("platforms", []).size() < 4: return "Нужны четыре платформы: " + checkpoint.id
		if int(checkpoint.get("maximumSurvivors", 0)) not in [1, 2, 3, 4]: return "Неверный предел выживших: " + checkpoint.id
	for terminal in source.get("intelTerminals", []):
		if not source.checkpoints.any(func(c): return c.id == terminal.get("checkpointId", "")):
			return "Терминал ссылается на неизвестную отсечку: " + terminal.id
		var index = int(terminal.checkpoint) - 1
		if index < 0 or index >= source.checkpoints.size() or source.checkpoints[index].id != terminal.checkpointId: return "Номер отсечки терминала не совпадает с ID."
	for mob in source.mobs:
		if mob.get("type", "") not in ["MELEE", "RANGED", "ASSAULT", "GRENADIER", "BOSS_ASSAULT", "BOSS_GRENADIER"]:
			return "Неизвестный тип противника: " + mob.id
		if int(mob.get("level", 0)) not in [1, 2] or float(mob.get("health", 0)) < 1 or float(mob.get("health", 0)) > 5000:
			return "Неверные HP или уровень ИИ: " + mob.id
		if not fired.has(mob.get("spawnTrigger", "")): return "Неизвестный триггер появления: " + mob.id
		var route = mob.get("route", {})
		if route.get("points", []).size() != 1 or not fired.has(route.get("startTrigger", "")):
			return "Неверный маршрут или его триггер: " + mob.id
	return ""

static func validate_bounds(value, world_width: float, world_height: float) -> String:
	if value is Dictionary:
		if value.has("x") and value.has("y"):
			var p = point(value)
			if not p.is_finite() or p.x < 0 or p.y < 0 or p.x > world_width or p.y > world_height:
				return "Объект за пределами мира."
			if value.has("width"):
				var r = rect(value)
				if not r.size.is_finite() or r.size.x <= 0 or r.size.y <= 0 or r.end.x > world_width or r.end.y > world_height:
					return "Прямоугольник за пределами мира или имеет неверный размер."
		for item in value.values():
			if item is Array or item is Dictionary:
				var error = validate_bounds(item, world_width, world_height)
				if not error.is_empty(): return error
	elif value is Array:
		for item in value:
			var error = validate_bounds(item, world_width, world_height)
			if not error.is_empty(): return error
	return ""

static func editable_maps_directory() -> String:
	if FileAccess.file_exists("res://project.godot"): return "res://maps"
	return OS.get_executable_path().get_base_dir().path_join("maps")

static func point(value: Dictionary) -> Vector2:
	return Vector2(float(value.x), float(value.y))

static func rect(value: Dictionary) -> Rect2:
	return Rect2(float(value.x), float(value.y), float(value.width), float(value.height))

static func connections(source: Dictionary) -> Array:
	var result = [{"from": point(source.entrance.console), "to": rect(source.entrance.gate).get_center(), "kind": "gate"}]
	for group in ["cooperationGates", "separationGates", "finalRelays", "checkpoints"]:
		var points_key = {"cooperationGates": "plates", "separationGates": "controls", "finalRelays": "nodes", "checkpoints": "platforms"}[group]
		for mechanism in source.get(group, []):
			for p in mechanism[points_key]: result.append({"from": point(p), "to": rect(mechanism.exitGate if group == "checkpoints" else mechanism.gate).get_center(), "kind": "gate"})
	for mechanism in source.get("trustPockets", []):
		for target in [mechanism.gate, mechanism.pocket]: result.append({"from": point(mechanism.plate), "to": rect(target).get_center(), "kind": "hazard"})
	for mechanism in source.get("serviceBridges", []):
		for p in [mechanism.plate, mechanism.overrideConsole]: result.append({"from": point(p), "to": rect(mechanism.hazard).get_center(), "kind": "bridge"})
	return result

func blocked(position: Vector2, radius: float, gates: Array = []) -> bool:
	# Legacy's 84 is the actor-centre limit (70 wall + 14 player), not wall thickness.
	if position.x < maxf(32, radius) or position.x > width - maxf(32, radius) or position.y < 70 + radius or position.y > height - 70 - radius:
		return true
	var visited = {}
	for bx in range(floori((position.x - radius) / 128), floori((position.x + radius) / 128) + 1):
		for by in range(floori((position.y - radius) / 128), floori((position.y + radius) / 128) + 1):
			for r in buckets.get(Vector2i(bx, by), []):
				if not visited.has(r):
					visited[r] = true
					if r.grow(radius).has_point(position):
						return true
	for r in gates:
		if r.grow(radius).has_point(position):
			return true
	return false

func clear_line(a: Vector2, b: Vector2, radius = 0.0, gates: Array = []) -> bool:
	var steps = maxi(1, ceili(a.distance_to(b) / 10.0))
	for i in range(steps + 1):
		if blocked(a.lerp(b, float(i) / steps), radius, gates):
			return false
	return true

func move_body(position: Vector2, motion: Vector2, radius: float, gates: Array, actors: Array = []) -> Vector2:
	var steps = maxi(1, ceili(motion.length() / 5.0))
	var increment = motion / steps
	for _i in range(steps):
		var next = position + Vector2(increment.x, 0)
		if not blocked(next, radius, gates) and not actor_blocked(next, radius, actors):
			position.x = next.x
		next = position + Vector2(0, increment.y)
		if not blocked(next, radius, gates) and not actor_blocked(next, radius, actors):
			position.y = next.y
	return position

static func actor_blocked(position: Vector2, radius: float, actors: Array) -> bool:
	for actor in actors:
		if position.distance_squared_to(actor.p) < pow(radius + actor.get("radius", 14.0), 2):
			return true
	return false

func minimum_after(index: int) -> int:
	if index >= data.checkpoints.size() - 1:
		return 1
	var start = 0.0 if index < 0 else float(data.checkpoints[index].exitGate.x) + float(data.checkpoints[index].exitGate.width)
	var result = 1
	for gate in data.get("cooperationGates", []):
		if not gate.get("adaptiveToTeamSize", false) and float(gate.gate.x) > start:
			result = maxi(result, int(gate.requiredPlayers))
	return result
