extends SceneTree

var checks = 0
var failures: Array = []

func check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures.append(message)
        push_error(message)

func _initialize() -> void:
    call_deferred("run")

func run() -> void:
    var map = CutoffMap.new()
    check(map.load_file().is_empty(), "Production map loads")
    var storage = "res://artifacts/editor-catalog-" + str(Time.get_ticks_usec())
    var catalog = CutoffEditorCatalog.new()
    catalog.initialize(storage, map)
    check(catalog.descriptors().size() == 1, "Catalog exposes production without writing it")
    var original = catalog.get_map(map.data.id)
    check(original.status == 200 and original.body == map.data, "Editor opens all original map fields")
    check(catalog.get_map("template").body.id == "default" and catalog.get_map("template").body.worldWidth == 6500, "Original tunnel template is separate from production")
    check(catalog.save_map(map.data, false, map.data.id, original.etag).status == 403, "Production overwrite blocked")
    check(catalog.save_map(map.data, true).status == 403, "Production filename cannot be created")
    var copy = map.data.duplicate(true)
    copy.id = "editor-test-copy"
    copy.name = "Editor copy"
    var result = catalog.save_map(copy, true)
    check(result.status == 201, "Create writes a working copy")
    var path = storage.path_join(copy.id + ".map")
    check(FileAccess.file_exists(path), "Saved map is present on disk")
    var loaded = CutoffMap.new()
    check(loaded.load_file(path).is_empty() and loaded.data.mobs == map.data.mobs, "Saved data preserves mob triggers and routes")
    check(catalog.save_map(copy, true).status == 409, "Duplicate creation cannot overwrite a map")
    copy.name = "Updated copy"
    var update = catalog.save_map(copy, false, copy.id, result.etag)
    check(update.status == 200 and update.etag != result.etag, "Update returns new revision")
    copy.name = "Stale tab"
    check(catalog.save_map(copy, false, copy.id, result.etag).status == 412, "Stale tab cannot overwrite newer edits")
    check(catalog.get_map(copy.id).body.name == "Updated copy", "Conflict leaves saved map intact")
    check(catalog.save_map(copy, false, copy.id).status == 412, "Update requires revision")
    var invalid = copy.duplicate(true)
    invalid.id = "../outside"
    check(catalog.save_map(invalid, true).status == 400, "Path traversal rejected")
    invalid.id = "EMERGENCY-REACTOR-COPY"
    check(catalog.save_map(invalid, true).status == 400, "Uppercase protected alias cannot be used as filename")
    invalid = copy.duplicate(true)
    invalid.mobs[0].spawnTrigger = "unknown-trigger"
    check(catalog.save_map(invalid, false, copy.id, update.etag).status == 400, "Unknown trigger rejected")
    invalid = copy.duplicate(true)
    invalid.intelTerminals[0].checkpoint = 99
    check(catalog.save_map(invalid, false, copy.id, update.etag).status == 400, "Invalid checkpoint reference rejected")
    check(catalog.save_map(null, true).status == 400, "Malformed request rejected")
    var manifest = JSON.parse_string(FileAccess.get_file_as_string("res://editor/provenance.json"))
    for name in manifest.verbatim_files:
        check(FileAccess.get_sha256("res://editor/" + name) == manifest.verbatim_files[name], "Original editor file unchanged: " + name)
    check(FileAccess.get_sha256("res://editor/template.map") == manifest.template.sha256, "Original editor template copied byte-identically")
    check(FileAccess.get_sha256(CutoffMap.PRODUCTION_PATH) == CutoffMap.PRODUCTION_SHA256, "Production map unchanged")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(storage))
    var file = FileAccess.open("res://artifacts/editor-test.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
    print("EDITOR_TEST checks=%d failures=%d" % [checks, failures.size()])
    quit(0 if failures.is_empty() else 1)
