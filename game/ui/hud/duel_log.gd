class_name DuelLog
extends CanvasLayer

## A scrollable event log panel on the right side of the screen, EDOPro-style.
##
## Layer: L5 shell (AGENTS.md section 4). It is handed pre-formatted strings and renders them.
## It has never heard of KaibaCore, DuelState or SelectionController.

const LAYER: int = 8
const MAX_LINES: int = 200

var _root: Control = null
var _scroll: ScrollContainer = null
var _log: RichTextLabel = null
var _toggle: Button = null
var _collapsed: bool = false


func _ready() -> void:
	layer = LAYER
	_build()


func append(text: String, colour: Color = Color(0.85, 0.87, 0.9)) -> void:
	if _log == null:
		return
	_log.push_color(colour)
	_log.add_text(text)
	_log.pop()
	_log.newline()

	while _log.get_line_count() > MAX_LINES:
		_log.remove_paragraph(0)

	_scroll.call_deferred("set_v_scroll", _scroll.get_v_scroll_bar().max_value as int)


func append_system(text: String) -> void:
	append(text, Color(0.6, 0.75, 1.0))


func append_action(text: String) -> void:
	append(text, Color(1.0, 0.9, 0.5))


func append_separator(text: String) -> void:
	if _log == null:
		return
	_log.push_color(Color(0.4, 0.55, 0.8))
	_log.add_text("━━━ %s ━━━" % text)
	_log.pop()
	_log.newline()
	while _log.get_line_count() > MAX_LINES:
		_log.remove_paragraph(0)
	_scroll.call_deferred("set_v_scroll", _scroll.get_v_scroll_bar().max_value as int)


func clear_log() -> void:
	if _log != null:
		_log.clear()


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.74
	panel.anchor_top = 0.02
	panel.anchor_right = 0.99
	panel.anchor_bottom = 0.55
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.08, 0.85)
	style.border_color = Color(0.25, 0.45, 0.7, 0.4)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	var outer: VBoxContainer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	panel.add_child(outer)

	var header: HBoxContainer = HBoxContainer.new()
	outer.add_child(header)

	var title: Label = Label.new()
	title.text = "Duel Log"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(0.7, 0.8, 0.95))
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	_toggle = Button.new()
	_toggle.text = "—"
	_toggle.custom_minimum_size = Vector2(28, 28)
	_toggle.add_theme_font_size_override("font_size", 14)
	_toggle.pressed.connect(_on_toggle)
	header.add_child(_toggle)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(_scroll)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = false
	_log.fit_content = true
	_log.scroll_active = false
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 13)
	_log.add_theme_color_override("default_color", Color(0.85, 0.87, 0.9))
	_scroll.add_child(_log)


func _on_toggle() -> void:
	_collapsed = not _collapsed
	_scroll.visible = not _collapsed
	_toggle.text = "+" if _collapsed else "—"
