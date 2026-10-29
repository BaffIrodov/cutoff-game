class_name CutoffMapStore
extends RefCounted

var entries = {}
var default_key = ""
var directory = ""

func initialize(default_path: String, storage: String) -> String:
	directory = storage
	var result = register(FileAccess.get_file_as_bytes(default_path))
	if not result.error.is_empty(): return result.error
	default_key = result.key
	if DirAccess.dir_exists_absolute(directory):
		for filename in DirAccess.get_files_at(directory):
			if filename.ends_with(".map") and entries.size() < 64:
				var path = directory.path_join(filename)
				var file = FileAccess.open(path, FileAccess.READ)
				if file and file.get_length() <= CutoffMap.MAX_BYTES:
					var loaded = register(file.get_buffer(file.get_length()))
					if not loaded.error.is_empty(): push_warning("Пропущена карта %s: %s" % [filename, loaded.error])
	return ""

func register(bytes: PackedByteArray, persist = false) -> Dictionary:
	var candidate = CutoffMap.new()
	var error = candidate.load_bytes(bytes)
	if not error.is_empty(): return {"error": error, "key": ""}
	var key = ""
	# Hash the original bytes, independent of JSON formatting and filenames.
	var digest = HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	key = digest.finish().hex_encode()
	if entries.has(key): return {"error": "", "key": key}
	if entries.size() >= 64: return {"error": "На сервере уже 64 карты.", "key": ""}
	if persist:
		var absolute = ProjectSettings.globalize_path(directory)
		if DirAccess.make_dir_recursive_absolute(absolute) != OK: return {"error": "Не удалось создать папку карт сервера.", "key": ""}
		var path = absolute.path_join(key + ".map")
		var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null: return {"error": "Не удалось сохранить карту на сервере.", "key": ""}
		file.store_buffer(bytes)
		file.flush()
		file.close()
		if DirAccess.rename_absolute(path + ".tmp", path) != OK: return {"error": "Не удалось завершить сохранение карты.", "key": ""}
	entries[key] = {"map": candidate, "bytes": bytes}
	return {"error": "", "key": key}

func catalog() -> Array:
	var result = []
	for key in entries:
		result.append({"key": key, "name": entries[key].map.data.name, "default": key == default_key})
	return result
