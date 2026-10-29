extends Control

const BG = Color("0d1312")
const PANEL = Color("111716")
const LINE = Color("2a3530")
const TEXT = Color("edf2ee")
const MUTED = Color("8c9992")
const GREEN = Color("b4dd80")
const RED = Color("e47c69")
const GOLD = Color("d8be71")
var app
var panel: PanelContainer
var box: VBoxContainer
var status_label: Label
var name_input: LineEdit
var host_input: LineEdit
var code_input: LineEdit
var roster_label: Label
var notice_label: Label
var restart_button: Button
var menu_mode = "menu"
var paused_overlay = false
var camera = Vector2.ZERO
var origin = Vector2(24, 104)
var area_size = Vector2(1232, 574)
var frame = {}
var font: Font
var editor
var shot_versions = {}
var seen_effects = {}
var last_hp = -1.0
var last_hit = 0
var shake_until = 0
var damage_until = 0
var hit_until = 0
var flash_until = {}
var sound_players: Array = []
var truth_notices: Array = []
var truth_seen = {}
var presentation_epoch = ""
var upload_credential: LineEdit

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	var theme = Theme.new()
	theme.default_font_size = 17
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style = StyleBoxFlat.new()
		style.bg_color = Color("29332e") if style_name != "hover" else Color("3b4a40")
		style.border_color = GREEN if style_name == "focus" else LINE
		style.set_border_width_all(1)
		style.content_margin_left = 18
		style.content_margin_right = 18
		style.content_margin_top = 8
		style.content_margin_bottom = 8
		theme.set_stylebox(style_name, "Button", style)
	for style_name in ["normal", "focus"]:
		var style = StyleBoxFlat.new()
		style.bg_color = Color("0c1110")
		style.border_color = GREEN if style_name == "focus" else Color("34413b")
		style.set_border_width_all(1)
		style.set_content_margin_all(12)
		theme.set_stylebox(style_name, "LineEdit", style)
	self.theme = theme
	panel = PanelContainer.new()
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = PANEL
	panel_style.border_color = LINE
	panel_style.set_border_width_all(1)
	panel_style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	restart_button = Button.new()
	restart_button.text = "Перезапустить уровень"
	restart_button.focus_mode = Control.FOCUS_NONE
	restart_button.position = Vector2(990, 48)
	restart_button.pressed.connect(func(): app.request("restart"))
	restart_button.hide()
	add_child(restart_button)
	for _i in range(6):
		var audio = AudioStreamPlayer.new()
		add_child(audio)
		sound_players.append(audio)
	show_menu()

func clear_panel() -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	panel.position = Vector2(48, 112)
	panel.size = Vector2(540, 0)
	panel.show()

func label(text: String, size_value = 17, color = TEXT) -> Label:
	var item = Label.new()
	item.text = text
	item.add_theme_font_size_override("font_size", size_value)
	item.add_theme_color_override("font_color", color)
	item.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	item.custom_minimum_size.x = 470
	box.add_child(item)
	return item

func button(text: String, callback: Callable, primary = false) -> Button:
	var item = Button.new()
	item.text = text
	if primary:
		item.add_theme_color_override("font_color", Color("10150f"))
		var style = StyleBoxFlat.new()
		style.bg_color = GREEN
		style.set_content_margin_all(13)
		item.add_theme_stylebox_override("normal", style)
	item.pressed.connect(callback)
	box.add_child(item)
	return item

func edit(text: String, placeholder: String) -> LineEdit:
	var item = LineEdit.new()
	item.text = text
	item.placeholder_text = placeholder
	box.add_child(item)
	return item

func show_menu() -> void:
	menu_mode = "menu"
	restart_button.hide()
	paused_overlay = false
	clear_panel()
	label("СЕТЕВОЙ КООПЕРАТИВ · 2–4 ИГРОКА", 13, GREEN)
	label("Дойти до отсечки", 36)
	label("Имя игрока", 15, MUTED)
	name_input = edit(app.nickname, "Имя")
	name_input.max_length = 24
	label("Адрес сервера", 15, MUTED)
	host_input = edit(app.address, "127.0.0.1")
	button("Подключиться", func(): app.connect_to(host_input.text, name_input.text), true)
	button("Редактор карты", open_editor)
	label("Для проверки на этом компьютере открой «Играть.cmd».\nДля второго игрока — «Ещё игрок.cmd».", 14, MUTED)
	notice_label = label("", 14, GOLD)

func connected() -> void:
	if not app.room.is_empty(): return
	menu_mode = "connected"
	clear_panel()
	label("СЕРВЕР ДОСТУПЕН", 13, GREEN)
	label("Начать забег", 36)
	map_controls()
	button("Создать комнату", func(): app.request("create", app.selected_map), true)
	label("Или введи код комнаты друга", 15, MUTED)
	code_input = edit("", "Пятисимвольный код")
	code_input.max_length = 5
	button("Войти по коду", func(): app.request("join", code_input.text))
	button("Отключиться", func(): app.disconnect_client())
	notice_label = label("", 14, GOLD)

func lobby_changed() -> void:
	if app.room.phase == "IN_GAME":
		menu_mode = "game"
		panel.hide()
		restart_button.visible = app.room.host == app.player_id
		return
	menu_mode = "lobby"
	clear_panel()
	label("КОМНАТА " + app.room.code, 29, GREEN)
	button("Копировать код · " + app.room.code, copy_room_code)
	if app.room.host == app.player_id: map_controls()
	else: label(app.room.map_name, 18)
	var roster = ""
	for p in app.room.players:
		roster += "%s%s  ·  %s\n" % [p.name, " — создатель" if p.id == app.room.host else "", "нет связи" if not p.connected else ("готов" if p.ready else "ожидание")]
	label(roster.strip_edges(), 19)
	button("Готов / не готов", func(): app.request("ready"), true)
	if app.room.host == app.player_id:
		button("Начать матч", func(): app.request("start"))
		if app.room.players.size() == 1:
			button("Одиночная тренировка", func(): app.request("practice"))
			label("Тренировка: плиты и отсечки рассчитаны на одного.", 13, MUTED)
	button("Отключиться", func(): app.disconnect_client())
	notice_label = label("", 14, GOLD)

func set_notice(message: String) -> void:
	if is_instance_valid(notice_label): notice_label.text = message
	if is_instance_valid(editor): editor.message.text = message
	if menu_mode == "game" and not app.online:
		# Connection status is also drawn over the frozen world.
		pass

func game_changed() -> void:
	var now = Time.get_ticks_msec()
	if presentation_epoch != app.epoch:
		presentation_epoch = app.epoch
		truth_seen.clear()
		truth_notices.clear()
		shot_versions.clear()
		seen_effects.clear()
		last_hp = -1
	for event in app.game.get("truth_events", []):
		if truth_seen.has(event.id): continue
		truth_seen[event.id] = true
		if app.game.time - event.time > 5: continue
		var mine = event.player == app.player_id
		truth_notices.append({"text": "Ты узнал правду об отсечке %02d" % event.checkpoint if mine else "%s узнал правду" % event.name, "expires": now + 4000})
	for actor in app.game.players + app.game.mobs:
		if shot_versions.has(actor.id) and actor.shot > shot_versions[actor.id]:
			flash_until[actor.id] = now + 75
			var local = actor.id == app.player_id
			var distance = 0.0 if app.predicted.is_empty() else actor.p.distance_to(app.predicted.p)
			if distance < 900: tone(150 if actor.get("slot", 1) == 2 else 110, 0.07, 0.1 if local else 0.035)
			if local: shake_until = now + 70
		shot_versions[actor.id] = actor.shot
	for e in app.game.effects:
		if seen_effects.has(e.id): continue
		seen_effects[e.id] = true
		if e.kind == "explosion" and not app.predicted.is_empty() and e.p.distance_to(app.predicted.p) < 400:
			shake_until = now + 350
			tone(45, 0.25, 0.18)
	if seen_effects.size() > 512:
		seen_effects.clear()
	if not app.predicted.is_empty():
		var p = app.predicted
		if last_hp >= 0 and p.hp < last_hp:
			damage_until = now + 300
			shake_until = now + 130
		last_hp = p.hp
		if p.hit > last_hit: hit_until = now + 160
		last_hit = p.hit

func sample_input() -> Dictionary:
	var result = CutoffMotor.idle()
	if menu_mode != "game" or paused_overlay or not get_window().has_focus(): return result
	var movement = Vector2(float(key_down(KEY_D) or key_down(KEY_RIGHT)) - float(key_down(KEY_A) or key_down(KEY_LEFT)),
		float(key_down(KEY_S) or key_down(KEY_DOWN)) - float(key_down(KEY_W) or key_down(KEY_UP)))
	result.move = movement.limit_length()
	result.run = Input.is_physical_key_pressed(KEY_SHIFT)
	result.aim = (get_global_mouse_position() - origin + camera - app.predicted.p).normalized()
	result.fire = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	return result

func key_down(key: Key) -> bool:
	return Input.is_physical_key_pressed(key) or Input.is_key_pressed(key)

func _input(event: InputEvent) -> void:
	if menu_mode != "game": return
	if event is InputEventKey and event.pressed and not event.echo:
		var key = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if event.keycode in [KEY_ESCAPE, KEY_SPACE, KEY_E, KEY_R, KEY_G, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5]: key = event.keycode
		if key == KEY_ESCAPE:
			toggle_pause()
			get_viewport().set_input_as_handled()
			return
		if paused_overlay: return
		match key:
			KEY_SPACE: app.dash_requested = true
			KEY_E: app.queue_action("interact")
			KEY_R: app.queue_action("reload")
			KEY_G: app.queue_action("transfer")
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5: app.queue_action("slot", key - KEY_1)
	if event is InputEventMouseButton and event.pressed and not paused_overlay and Rect2(origin, area_size).has_point(event.position):
		if event.button_index == MOUSE_BUTTON_LEFT: app.queue_action("attack")
		elif event.button_index == MOUSE_BUTTON_RIGHT: app.queue_action("heal_other")

func toggle_pause() -> void:
	paused_overlay = not paused_overlay
	if not paused_overlay:
		panel.hide()
		return
	clear_panel()
	label("МАТЧ ПРОДОЛЖАЕТСЯ", 13, GREEN)
	label("Меню", 36)
	button("Вернуться в игру", toggle_pause, true)
	button("Копировать код · " + app.room.code, copy_room_code)
	button("Отключиться", func(): app.disconnect_client())
	notice_label = label("", 14, GOLD)

func _process(_delta: float) -> void:
	area_size = Vector2(maxf(400, size.x - 48), maxf(250, size.y - 226))
	restart_button.position.x = size.x - 280
	frame = app.render_state()
	if not frame.is_empty():
		var subject = app.predicted
		if not subject.get("alive", true):
			for p in frame.players:
				if p.alive: subject = p; break
		if not subject.is_empty():
			camera = subject.p + app.visual_offset - area_size * 0.5
			camera.x = clampf(camera.x, 0, maxf(0, app.map.width - area_size.x))
			camera.y = clampf(camera.y, 0, maxf(0, app.map.height - area_size.y))
	queue_redraw()

func text(at: Vector2, value: String, color = TEXT, font_size = 16) -> void:
	draw_string(font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if font == null: return
	draw_rect(Rect2(Vector2.ZERO, size), Color("090c0d"))
	if menu_mode == "game" and not frame.is_empty(): draw_world()
	draw_rect(Rect2(0, 0, size.x, 100), Color("090c0d"))
	text(Vector2(28, 38), "◇", GREEN, 28)
	text(Vector2(66, 34), "О Т С Е Ч К А", TEXT, 21)
	text(Vector2(66, 59), "Кооперативный забег на выживание", MUTED, 13)
	var connection = "%d мс" % app.rtt_ms if app.online else ("Переподключение…" if app.want_connection else "Нет соединения")
	text(Vector2(size.x - 250, 30), connection, GREEN if app.online else RED, 14)
	if menu_mode == "game":
		text(Vector2(28, 91), app.map.data.name + ("  ·  ТРЕНИРОВКА" if app.room.get("practice", false) else ""), MUTED, 18)
		draw_hud()
	else:
		# Restrained grid carries the same dark industrial palette as the original client.
		for x in range(660, int(size.x), 40): draw_line(Vector2(x, 155), Vector2(x, size.y), Color("131b18"))
		for y in range(155, int(size.y), 40): draw_line(Vector2(660, y), Vector2(size.x, y), Color("131b18"))
		text(Vector2(710, 245), "АВАРИЙНЫЙ", MUTED, 26)
		text(Vector2(710, 282), "РЕАКТОР", GREEN, 36)
		text(Vector2(710, 325), "Одна команда. Три отсечки.", MUTED, 16)
		text(Vector2(710, 352), "Не все дойдут до конца.", MUTED, 16)

func world_transform() -> void:
	var shake = Vector2.ZERO
	if Time.get_ticks_msec() < shake_until: shake = Vector2(randf_range(-2, 2), randf_range(-2, 2))
	draw_set_transform(origin - camera + shake)

func draw_world() -> void:
	world_transform()
	draw_rect(Rect2(camera, area_size), BG)
	for x in range(floori(camera.x / 40) * 40, ceili((camera.x + area_size.x) / 40) * 40, 40):
		draw_line(Vector2(x, camera.y), Vector2(x, camera.y + area_size.y), Color("18211e"))
	for y in range(floori(camera.y / 40) * 40, ceili((camera.y + area_size.y) / 40) * 40, 40):
		draw_line(Vector2(camera.x, y), Vector2(camera.x + area_size.x, y), Color("18211e"))
	for y in [0.0, app.map.height - 70]:
		draw_rect(Rect2(0, y, app.map.width, 70), Color("1c2622"))
		draw_rect(Rect2(0, y + (68 if y == 0 else -1), app.map.width, 3), Color("526459"))
	for link in CutoffMap.connections(app.map.data):
		var color = Color("82c1cb") if link.kind == "bridge" else (GOLD if link.kind == "hazard" else GREEN)
		draw_dashed_line(link.from, link.to, Color(color, 0.52), 1.5, 7)
		var direction: Vector2 = (link.to - link.from).normalized()
		draw_line(link.to, link.to - direction.rotated(0.5) * 12, color, 1.5)
		draw_line(link.to, link.to - direction.rotated(-0.5) * 12, color, 1.5)
	var visible = Rect2(camera, area_size).grow(70)
	for r in app.map.obstacles:
		if not visible.intersects(r): continue
		draw_rect(r, Color("29332e"))
		draw_rect(r, Color("4b5a50"), false, 1)
		draw_line(r.position + Vector2(3, 3), Vector2(r.end.x - 3, r.position.y + 3), Color("637266"), 2)
	for item in app.map.data.labels:
		if visible.has_point(CutoffMap.point(item)): text(CutoffMap.point(item), item.text, Color("6f8175"), 13)
	var data = app.map.data
	console_at(CutoffMap.point(data.entrance.console), frame.entrance_open, "E · шлюз")
	gate_at(data.entrance.gate, frame.entrance_open)
	for i in range(data.get("cooperationGates", []).size()):
		var mechanism = data.cooperationGates[i]
		var runtime = frame.coop[i]
		gate_at(mechanism.gate, runtime.open)
		for plate in mechanism.plates: plate_at(CutoffMap.point(plate), runtime.open, 28, GREEN)
		if runtime.charge > 0: text(CutoffMap.point(mechanism.plates[0]) + Vector2(-20, -35), "%d%%" % int(runtime.charge / 1.25 * 100), GREEN, 14)
	for i in range(data.get("trustPockets", []).size()):
		var mechanism = data.trustPockets[i]
		var safe = frame.trust[i].open
		hazard_at(mechanism.pocket, safe, false)
		plate_at(CutoffMap.point(mechanism.plate), safe, 28, GOLD)
		gate_at(mechanism.gate, safe)
	for i in range(data.get("serviceBridges", []).size()):
		var mechanism = data.serviceBridges[i]
		var runtime = frame.bridges[i]
		hazard_at(mechanism.hazard, runtime.safe, true)
		plate_at(CutoffMap.point(mechanism.plate), runtime.safe, 30, Color("82c1cb"))
		console_at(CutoffMap.point(mechanism.overrideConsole), runtime.locked, "E · закрепить")
	for i in range(data.get("separationGates", []).size()):
		var mechanism = data.separationGates[i]
		gate_at(mechanism.gate, frame.dividers[i] > 0)
		for point in mechanism.controls: console_at(CutoffMap.point(point), frame.dividers[i] > 0, "E · заслон")
	for i in range(data.get("finalRelays", []).size()):
		var mechanism = data.finalRelays[i]
		gate_at(mechanism.gate, frame.relays[i].open)
		for j in range(mechanism.nodes.size()): console_at(CutoffMap.point(mechanism.nodes[j]), frame.relays[i].remaining[j] > 0, "E · реле")
	for i in range(data.checkpoints.size()):
		var mechanism = data.checkpoints[i]
		var runtime = frame.checkpoints[i]
		gate_at(mechanism.exitGate, runtime.state == "CLEARED")
		for plate in mechanism.platforms: plate_at(CutoffMap.point(plate), runtime.state == "CLEARED", 30, RED if runtime.state == "FAILED" else GOLD)
		text(CutoffMap.point(mechanism.platforms[0]) + Vector2(-20, -45), "ОТСЕЧКА %02d  %d%%" % [i + 1, int(runtime.charge / 2 * 100)], GOLD, 14)
	for i in range(data.lootCrates.size()):
		var p = CutoffMap.point(data.lootCrates[i])
		if not visible.has_point(p): continue
		draw_rect(Rect2(p - Vector2(20, 15), Vector2(40, 30)), Color("5f452b") if not frame.crates[i].opened else Color("30271d"))
		draw_rect(Rect2(p - Vector2(20, 15), Vector2(40, 30)), GOLD if not frame.crates[i].opened else MUTED, false, 1.5)
		if not frame.crates[i].opened: text(p + Vector2(-10, 4), "loot", Color("f1d39f"), 10)
		else:
			draw_line(p + Vector2(-21, -15), p + Vector2(18, -25), Color("9a754c"), 6)
			var loot = frame.crates[i].loot
			if loot == "AMMO":
				for j in range(3): draw_rect(Rect2(p + Vector2(-10 + j * 8, -7), Vector2(4, 14)), GOLD)
			else:
				draw_set_transform(origin - camera + p - Vector2(16, 0), 0, Vector2(0.48, 0.48))
				draw_weapon_model({"MEDKIT": 4, "ASSAULT_RIFLE": 2, "GRENADE_LAUNCHER": 3}.get(loot, 1), GREEN)
				world_transform()
			text(p + Vector2(-35, 31), {"MEDKIT": "+1 аптечка", "AMMO": "+5 патронов", "ASSAULT_RIFLE": "автомат · 30", "GRENADE_LAUNCHER": "гранатомёт · 1"}.get(loot, ""), MUTED, 10)
		near_label(p, "E · ящик" if not frame.crates[i].opened else "Пусто")
	for i in range(data.intelTerminals.size()):
		console_at(CutoffMap.point(data.intelTerminals[i]), frame.terminals[i], "E · данные")
	for i in range(data.weaponPickups.size()):
		if frame.pickups[i]: weapon(CutoffMap.point(data.weaponPickups[i]), Vector2.RIGHT, 1, GREEN)
	for i in range(data.healthBoostPickups.size()):
		if not frame.boosts[i]: continue
		var p = CutoffMap.point(data.healthBoostPickups[i])
		draw_circle(p, 12, Color("365749"))
		text(p + Vector2(-8, 6), "+", GREEN, 22)
	for shot in frame.shots:
		if not visible.has_point(shot.p): continue
		draw_line(shot.p - shot.v.normalized() * (12 if shot.grenade else 24), shot.p, RED if shot.hostile else GOLD, 3 if shot.grenade else 2)
		draw_circle(shot.p, 5 if shot.grenade else 2, Color("ffd488"))
	for e in frame.effects:
		if e.kind == "explosion":
			draw_circle(e.p, 100 * (1 - e.life / 0.5), Color(1, 0.4, 0.1, e.life * 0.7), false, 5)
		elif e.kind == "impact":
			for j in range(4): draw_line(e.p, e.p + Vector2.from_angle(j * TAU / 4 + e.id) * 10, GOLD, 1)
		else: draw_circle(e.p, 24 * (1 - e.life), Color(0.7, 0.86, 0.5, e.life), false, 2)
	for mob in frame.mobs:
		if visible.has_point(mob.p): actor_at(mob, false, true)
	for p in frame.players:
		if visible.has_point(p.p): actor_at(p, p.id == app.player_id, false)
	draw_set_transform(Vector2.ZERO)
	draw_rect(Rect2(0, 100, origin.x, area_size.y + 4), Color("090c0d"))
	draw_rect(Rect2(origin.x + area_size.x, 100, size.x - origin.x - area_size.x, area_size.y + 4), Color("090c0d"))
	draw_rect(Rect2(origin, area_size), LINE, false, 1)

func gate_at(value: Dictionary, opened: bool) -> void:
	var r = CutoffMap.rect(value)
	if opened:
		draw_rect(r, Color(0.5, 0.7, 0.4, 0.12))
		draw_rect(r, Color("405a43"), false, 1)
	else:
		draw_rect(r, Color("67483c"))
		draw_rect(r, GOLD, false, 2)
		if r.size.y > r.size.x:
			for y in range(int(r.position.y + 6), int(r.end.y), 18): draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y + 10), Color("9c7753"), 2)

func console_at(p: Vector2, enabled: bool, hint: String) -> void:
	draw_rect(Rect2(p - Vector2(10, 13), Vector2(20, 26)), Color("233a35"))
	draw_rect(Rect2(p - Vector2(7, 9), Vector2(14, 10)), GREEN if enabled else Color("77aeb1"))
	near_label(p, hint)

func plate_at(p: Vector2, enabled: bool, radius: float, color: Color) -> void:
	draw_circle(p, radius, Color(color, 0.12 if not enabled else 0.3))
	draw_circle(p, radius, color, false, 2)
	draw_line(p - Vector2(8, 0), p + Vector2(8, 0), color)

func hazard_at(value: Dictionary, safe: bool, electric: bool) -> void:
	var r = CutoffMap.rect(value)
	var color = Color("689daf") if electric else Color("c67546")
	draw_rect(r, Color(color, 0.06 if safe else 0.25))
	draw_rect(r, Color("3e6558") if safe else color, false, 1)
	if not safe:
		for x in range(int(r.position.x + 8), int(r.end.x), 24):
			draw_line(Vector2(x, r.position.y), Vector2(minf(r.end.x, x + 18), r.end.y), Color(color, 0.35), 1)

func near_label(p: Vector2, hint: String) -> void:
	if not app.predicted.is_empty() and app.predicted.p.distance_to(p) < 85:
		text(p + Vector2(-24, -25), hint, TEXT, 13)

func actor_at(p: Dictionary, mine: bool, mob: bool) -> void:
	var color = (Color("d37d65") if p.level == 1 else Color("d1aa72")) if mob else (GREEN if mine else Color("82bdba"))
	var at: Vector2 = p.p
	var radius = float(p.get("radius", 14))
	if not p.alive:
		draw_line(at - Vector2(8, 8), at + Vector2(8, 8), Color("4b514b"), 4)
		draw_line(at + Vector2(-8, 8), at + Vector2(8, -8), Color("4b514b"), 4)
		return
	if p.get("moving", false): at.y += sin(Time.get_ticks_msec() / (54.0 if p.sprinting else 88.0)) * 1.5
	draw_circle(at + Vector2(2, 4), radius + 2, Color(0, 0, 0, 0.35))
	if p.get("down", false):
		draw_circle(at, radius + 9 + sin(Time.get_ticks_msec() / 120.0) * 3, Color(GREEN, 0.25), false, 2)
		color = Color("7c8c70")
	if p.get("dash_time", 0) > 0: draw_circle(at, radius + 6, Color("b4e1ff"), false, 3)
	draw_circle(at, radius, color)
	draw_circle(at - Vector2(3, 3), radius * 0.54, color.lightened(0.2))
	var slot = p.get("slot", 0)
	if mob: slot = 0 if p.type == "MELEE" or p.ammo <= 0 else (3 if "GRENADIER" in p.type else (2 if "ASSAULT" in p.type else 1))
	if not p.get("down", false): weapon(at, p.aim, slot, color, flash_until.get(p.id, 0) > Time.get_ticks_msec())
	if p.get("swing", -1) >= 0:
		var angle = p.aim.angle()
		draw_arc(at, 45 + radius, angle - 0.8, angle + 0.8, 16, Color(color, 0.7), 3)
	if not mob:
		text(at + Vector2(-20, -radius - 12), p.name + (" · нет связи" if not p.connected else ""), TEXT if mine else MUTED, 12)
	if p.hp < p.max_hp or not mob:
		draw_rect(Rect2(at.x - radius, at.y + radius + 5, radius * 2, 3), Color("26332c"))
		draw_rect(Rect2(at.x - radius, at.y + radius + 5, radius * 2 * p.hp / p.max_hp, 3), color)

func weapon(at: Vector2, aim: Vector2, slot: int, color: Color, flash = false) -> void:
	draw_set_transform(origin - camera + at, aim.angle())
	draw_weapon_model(slot, color)
	if flash: draw_colored_polygon(PackedVector2Array([Vector2(60, -7), Vector2(78, 0), Vector2(60, 7), Vector2(65, 0)]), Color("fff1a8"))
	world_transform()

func polygon(points: Array, color: Color) -> void:
	var vertices = PackedVector2Array()
	for p in points: vertices.append(Vector2(p[0], p[1]))
	draw_colored_polygon(vertices, color)
	vertices.append(vertices[0])
	draw_polyline(vertices, Color("101713"), 1.2, true)

func draw_weapon_model(slot: int, color: Color) -> void:
	var metal = Color("bfc9c2")
	var dark = Color("39443e")
	var wood = Color("9a663d")
	match slot:
		0:
			draw_line(Vector2(9, 9), Vector2(23, 9), Color("5d695b"), 5)
			draw_colored_polygon(PackedVector2Array([Vector2(20, 5), Vector2(39, 8), Vector2(22, 12)]), Color("d2ddd2"))
		1:
			# Long wooden stock, slim barrel, bolt and sights: a recognisable rifle.
			polygon([[3,-7],[17,-6],[25,-3],[39,-4],[42,3],[23,5],[17,10],[3,8]], wood)
			draw_line(Vector2(6, 5), Vector2(16, 3), Color("c48d55"), 2)
			draw_rect(Rect2(22, -4, 22, 7), dark)
			draw_rect(Rect2(40, -2, 25, 4), metal)
			draw_rect(Rect2(61, -4, 2, 7), dark)
			draw_line(Vector2(29, -2), Vector2(30, -8), metal, 2)
			draw_circle(Vector2(30, -8), 2, metal)
			draw_arc(Vector2(23, 6), 4, 0, PI, 8, dark, 1.5)
		2:
			# Short stock, receiver, curved magazine, wood handguard and gas tube.
			polygon([[3,-6],[17,-4],[22,0],[17,5],[3,9]], wood)
			polygon([[26,4],[34,4],[36,12],[42,17],[35,19],[29,14]], dark)
			draw_line(Vector2(32, 8), Vector2(37, 15), metal.darkened(0.35), 1)
			polygon([[20,4],[25,5],[22,14],[17,13]], wood)
			draw_rect(Rect2(18,-6,27,12), dark)
			draw_rect(Rect2(40,-5,13,10), Color("c08a55"))
			for x in [43,47,51]: draw_line(Vector2(x,-4), Vector2(x,4), wood, 1)
			draw_rect(Rect2(51,-2,14,4), metal)
			draw_line(Vector2(22,-7), Vector2(53,-7), metal, 2)
			draw_rect(Rect2(60,-6,2,7), dark)
		3:
			# Broad shoulder tube, two grips, front sight and an olive warhead.
			draw_rect(Rect2(7,-7,48,14), Color("596f3f"))
			draw_rect(Rect2(4,-5,53,10), dark)
			draw_rect(Rect2(10,-6,11,12), Color("718d4e"))
			draw_rect(Rect2(36,-6,12,12), Color("718d4e"))
			polygon([[53,-8],[60,-8],[70,0],[60,8],[53,8]], Color("879659"))
			draw_rect(Rect2(23,5,6,13), wood)
			draw_rect(Rect2(41,5,5,10), wood)
			draw_line(Vector2(31,-7), Vector2(31,-14), metal, 2)
			draw_line(Vector2(28,-14), Vector2(35,-14), metal, 2)
			draw_line(Vector2(13,-5), Vector2(51,-5), metal, 1)
		4:
			draw_rect(Rect2(12, -10, 22, 22), Color("dce8df"))
			draw_rect(Rect2(20, -7, 5, 16), RED)
			draw_rect(Rect2(15, -2, 15, 5), RED)

func draw_hud() -> void:
	var bottom = origin.y + area_size.y
	draw_rect(Rect2(0, bottom + 1, size.x, size.y - bottom), Color("090c0d"))
	if app.predicted.is_empty() or frame.is_empty(): return
	var p = app.predicted
	text(Vector2(28, bottom + 28), "HP  %d / %d" % [maxi(0, int(p.hp)), int(p.max_hp)], RED if p.hp < 60 else GREEN, 17)
	draw_rect(Rect2(28, bottom + 40, 180, 5), LINE)
	draw_rect(Rect2(28, bottom + 40, 180 * p.hp / p.max_hp, 5), GREEN)
	text(Vector2(235, bottom + 28), "ВЫНОСЛИВОСТЬ", MUTED, 12)
	draw_rect(Rect2(235, bottom + 40, 130, 5), LINE)
	draw_rect(Rect2(235, bottom + 40, 130 * p.stamina / 3, 5), Color("7cbac1"))
	var labels = ["Нож", "Винтовка %d/%d" % [p.ammo, p.reserve], "Автомат %d/%d" % [p.mag, p.ar_reserve], "Гранатомёт %d" % p.grenades, "Аптечки %d" % p.medkits]
	for i in range(5):
		var x = 410 + i * 155
		var selected = p.slot == i
		draw_rect(Rect2(x, bottom + 10, 145, 56), Color("26352a") if selected else PANEL)
		draw_rect(Rect2(x, bottom + 10, 145, 56), GREEN if selected else LINE, false, 1)
		draw_set_transform(Vector2(x + 45, bottom + 27), 0, Vector2(0.85, 0.85))
		draw_weapon_model(i, GREEN)
		draw_set_transform(Vector2.ZERO)
		text(Vector2(x + 8, bottom + 55), "%d · %s" % [i + 1, labels[i]], GREEN if selected else MUTED, 12)
	var objective = "Найдите данные и доберитесь до отсечки."
	for i in range(frame.checkpoints.size()):
		if frame.checkpoints[i].state == "ACTIVE":
			var hint = p.hints.get(i + 1, p.hints.get(float(i + 1), null))
			objective = "Отсечка %02d · %s" % [i + 1, "нужно выживших: %d" % hint if hint != null else "число выживших скрыто — найдите терминал"]
			break
	if p.reload > 0: objective += "  ·  Перезарядка…"
	text(Vector2(28, bottom + 73), objective, GOLD, 14)
	text(Vector2(28, bottom + 101), "WASD · движение    Shift · бег    Пробел · рывок    E · взаимодействие    ЛКМ · атака    R · перезарядка    ПКМ · лечить союзника    G · передать    Esc · меню", MUTED, 12)
	draw_truth(p)
	if Time.get_ticks_msec() < damage_until: draw_rect(Rect2(origin, area_size), Color(0.9, 0.2, 0.1, 0.65), false, 5)
	if Time.get_ticks_msec() < hit_until:
		var at = get_global_mouse_position()
		for i in range(4):
			var direction = Vector2.from_angle(PI / 4 + i * PI / 2)
			draw_line(at + direction * 6, at + direction * 12, TEXT, 2)
	var message = ""
	if frame.won: message = "ЗАБЕГ ЗАВЕРШЁН"
	elif not p.alive: message = "ТЫ ПОГИБ · наблюдение за командой"
	elif p.down: message = "НОКАУТ · %.1f с · союзник может поднять аптечкой" % maxf(0, 5 - p.down_time)
	if not app.online: message = "СВЯЗЬ ПОТЕРЯНА · переподключение…"
	if not message.is_empty():
		var middle = size * 0.5
		draw_rect(Rect2(middle - Vector2(360, 35), Vector2(720, 70)), Color(0.04, 0.06, 0.05, 0.92))
		text(middle + Vector2(-330, 8), message, GREEN if frame.won else RED, 21)

func centered_banner(value: String, y: float, color: Color, font_size = 20) -> void:
	var width = maxf(460, font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 40)
	var rectangle = Rect2((size.x - width) * 0.5, y, width, 44)
	draw_rect(rectangle, Color(0.10, 0.07, 0.16, 0.96))
	draw_rect(rectangle, color, false, 1.5)
	draw_string(font, Vector2(rectangle.position.x, y + 29), value, HORIZONTAL_ALIGNMENT_CENTER, width, font_size, color)

func draw_truth(p: Dictionary) -> void:
	for i in range(frame.checkpoints.size()):
		if frame.checkpoints[i].state != "ACTIVE": continue
		var hint = p.hints.get(i + 1, p.hints.get(float(i + 1), null))
		if hint != null: centered_banner("ОТСЕЧКА %02d · ДОЙТИ ДОЛЖНЫ: %d" % [i + 1, hint], origin.y + 12, Color("d0b4ff"))
		break
	truth_notices = truth_notices.filter(func(n): return n.expires > Time.get_ticks_msec())
	for i in range(mini(3, truth_notices.size())):
		centered_banner(truth_notices[i].text, origin.y + 72 + i * 50, Color("d0b4ff"), 18)

func tone(frequency: float, duration: float, volume: float) -> void:
	var output: AudioStreamPlayer
	for player in sound_players:
		if not player.playing: output = player; break
	if output == null: return
	var stream = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 22050
	var samples = PackedByteArray()
	samples.resize(int(duration * 22050) * 2)
	for i in range(samples.size() / 2):
		var envelope = 1.0 - float(i) / (samples.size() / 2)
		var wave = (sin(TAU * frequency * i / 22050.0) * 0.6 + randf_range(-0.4, 0.4)) * envelope
		samples.encode_s16(i * 2, int(wave * 18000))
	stream.data = samples
	output.stream = stream
	output.volume_db = linear_to_db(volume)
	output.play()

func open_editor() -> void:
	if is_instance_valid(editor): return
	editor = load("res://scripts/map_editor.gd").new()
	editor.app = app
	add_child(editor)
	panel.hide()
	editor.tree_exited.connect(func(): panel.show())

func copy_room_code() -> void:
	DisplayServer.clipboard_set(app.room.code)
	set_notice("Код %s скопирован" % app.room.code)

func map_controls() -> void:
	label("Карта на сервере · игроки получат её автоматически", 13, MUTED)
	var list = OptionButton.new()
	list.fit_to_longest_item = false
	list.clip_text = true
	list.custom_minimum_size.y = 36
	for entry in app.map_catalog:
		list.add_item(entry.name)
		list.set_item_metadata(list.item_count - 1, entry.key)
		if entry.key == app.selected_map: list.select(list.item_count - 1)
	list.item_selected.connect(func(index): app.request("select_map", list.get_item_metadata(index)))
	box.add_child(list)
	var row = HBoxContainer.new()
	box.add_child(row)
	var edit_button = button("Редактор карт", open_editor)
	edit_button.reparent(row)
	if app.uploads_allowed:
		var upload_button = button("Загрузить .map", choose_upload)
		upload_button.reparent(row)
	if app.upload_token_required:
		upload_credential = edit("", "Ключ загрузки карт владельца сервера")
		upload_credential.secret = true

func choose_upload() -> void:
	var dialog = FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters = PackedStringArray(["*.map ; Карты Отсечки"])
	dialog.title = "Загрузить карту на сервер"
	dialog.current_dir = ProjectSettings.globalize_path(CutoffMap.editable_maps_directory())
	add_child(dialog)
	dialog.file_selected.connect(func(path):
		app.upload_file(path, upload_credential.text if is_instance_valid(upload_credential) else "")
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(900, 600))
