extends Control

var app
var service
var message: Label

func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP
    service = app.ensure_editor_service()
    var background = ColorRect.new()
    background.color = Color("090c0d")
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(background)
    var center = CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)
    var panel = PanelContainer.new()
    var style = StyleBoxFlat.new()
    style.bg_color = Color("111716")
    style.border_color = Color("2a3530")
    style.set_border_width_all(1)
    style.set_content_margin_all(28)
    panel.add_theme_stylebox_override("panel", style)
    center.add_child(panel)
    var box = VBoxContainer.new()
    box.custom_minimum_size.x = 560
    box.add_theme_constant_override("separation", 16)
    panel.add_child(box)
    var title = Label.new()
    title.text = "Оригинальный редактор уровней"
    title.add_theme_font_size_override("font_size", 28)
    box.add_child(title)
    message = Label.new()
    message.text = "Редактор открыт в браузере.\nПалитра объектов, свойства, триггеры, маршруты,\nшаблоны и черновики перенесены из оригинала."
    message.add_theme_font_size_override("font_size", 16)
    box.add_child(message)
    var open_button = Button.new()
    open_button.text = "Открыть редактор в браузере"
    open_button.pressed.connect(open_browser)
    box.add_child(open_button)
    var back = Button.new()
    back.text = "Вернуться в игру"
    back.pressed.connect(queue_free)
    box.add_child(back)
    var hint = Label.new()
    hint.text = "Сохраняйте отдельную копию карты. Для совместной игры\nиспользуйте «Сохранить и загрузить на игровой сервер».\nРедактор остаётся доступен, пока открыто окно игры."
    hint.add_theme_font_size_override("font_size", 14)
    box.add_child(hint)
    if not app.options.has("no-browser"): open_browser()

func open_browser() -> void:
    if service.url.is_empty():
        message.text = app.last_notice
        return
    var error = OS.shell_open(service.url)
    if error != OK: message.text = "Не удалось открыть браузер: " + error_string(error)
