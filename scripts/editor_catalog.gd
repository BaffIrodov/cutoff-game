class_name CutoffEditorCatalog
extends RefCounted

var directory = ""
var records = {}
var current_map: CutoffMap

func initialize(storage: String, current: CutoffMap = null) -> void:
	directory = storage
	current_map = current
	refresh()

func refresh() -> void:
	records.clear()
	add_file(CutoffMap.PRODUCTION_PATH, true)
	if DirAccess.dir_exists_absolute(directory):
		for filename in DirAccess.get_files_at(directory):
			if filename.to_lower().ends_with(".map"):
				add_file(directory.path_join(filename))
	if current_map != null and not records.has(current_map.data.id.to_lower()):
		var bytes = JSON.stringify(current_map.data, "  ").to_utf8_buffer()
		records[current_map.data.id.to_lower()] = {"map": current_map, "path": "", "revision": revision(bytes), "read_only": true}

func add_file(path: String, protected = false) -> void:
	var map = CutoffMap.new()
	if not map.load_file(path).is_empty(): return
	var key = map.data.id.to_lower()
	if records.has(key): return
	records[key] = {"map": map, "path": path, "revision": revision(FileAccess.get_file_as_bytes(path)),
		"read_only": protected or key == "emergency-reactor-copy" or path.get_file().to_lower() == "emergency-reactor-copy.map"}

static func revision(bytes: PackedByteArray) -> String:
	var hash = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return '"' + hash.finish().hex_encode() + '"'

func descriptors() -> Array:
	refresh()
	var result = []
	for key in records:
		var entry = records[key]
		result.append({"id": entry.map.data.id, "name": entry.map.data.name, "readOnly": entry.read_only})
	return result

func get_map(id: String) -> Dictionary:
	refresh()
	var key = id.to_lower()
	if id == "template":
		# The original editor upgrades this legacy template to format 4 in normalizeMap.
		# It is a template asset only, never a production map or the default game map.
		var bytes = FileAccess.get_file_as_bytes("res://editor/template.map")
		var data = JSON.parse_string(bytes.get_string_from_utf8())
		if not data is Dictionary: return failure(500, "Не удалось открыть исходный шаблон редактора.")
		return {"status": 200, "body": data, "etag": revision(bytes)}
	if not records.has(key): return failure(404, "Карта не найдена.")
	var entry = records[key]
	return {"status": 200, "body": entry.map.data.duplicate(true), "etag": entry.revision}

func save_map(data, create: bool, id = "", etag = "") -> Dictionary:
	if not data is Dictionary: return failure(400, "Нужен JSON карты.")
	var candidate = CutoffMap.new()
	var error = candidate.load_data(data)
	if not error.is_empty(): return failure(400, error)
	var key = str(data.id)
	var pattern = RegEx.new()
	pattern.compile("^[a-z0-9-]{1,40}$")
	if pattern.search(key) == null: return failure(400, "ID: от 1 до 40 латинских строчных букв, цифр и дефисов.")
	refresh()
	if key == "emergency-reactor-copy" or (records.has(key) and records[key].read_only):
		return failure(403, "Продовая или серверная карта защищена. Нажмите «Создать копию» в списке карт.")
	if create and records.has(key): return failure(409, "Карта с таким ID уже существует.")
	if not create:
		if id != key: return failure(400, "ID карты не должен меняться при сохранении.")
		if not records.has(key): return failure(404, "Карта не найдена.")
		if etag.is_empty() or etag != records[key].revision: return failure(412, "Карта изменена в другой вкладке. Скачайте черновик и откройте сохранённую версию заново.")
	var path = directory.path_join(key + ".map") if create else records[key].path
	if create and FileAccess.file_exists(path): return failure(409, "Файл с таким именем уже существует. Выберите другой ID.")
	if path.get_file().to_lower() == "emergency-reactor-copy.map": return failure(403, "Продовая карта защищена.")
	var bytes = JSON.stringify(data, "  ").to_utf8_buffer()
	if bytes.size() > CutoffMap.MAX_BYTES: return failure(413, "Карта больше 512 КБ.")
	var absolute = ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(absolute) != OK: return failure(500, "Не удалось создать папку карт.")
	var temporary = path + ".tmp-" + Crypto.new().generate_random_bytes(6).hex_encode()
	var file = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return failure(500, "Не удалось записать карту. Скачайте черновик.")
	file.store_buffer(bytes)
	file.flush()
	file.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path)) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return failure(500, "Не удалось завершить сохранение. Скачайте черновик.")
	return {"status": 201 if create else 200, "body": data.duplicate(true), "etag": revision(bytes)}

static func failure(status: int, message: String) -> Dictionary:
	return {"status": status, "body": {"message": message}}
