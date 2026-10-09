class_name PileBrowser
extends CanvasLayer

## A scrollable popup listing every card in a pile: graveyard, banished or extra deck.
##
## Layer: L5 shell (AGENTS.md section 4). It is handed pre-resolved data and renders it.
## It has never heard of KaibaCore, DuelState or SelectionController.
##
## Built in code following the same pattern as ActionMenu: dynamic content, dimmer
## background, centred panel, click-to-dismiss.

signal closed
signal card_selected(card: Dictionary)

const LAYER: int = 11
const PANEL_WIDTH: int = 360
const PANEL_HEIGHT: int = 500
const ITEM_HEIGHT: int = 40

var _root: Control = null
var _panel: PanelContainer = null
var _title: Label = null
var _scroll: ScrollContainer = null
var _list: VBoxContainer = null
var _visible: bool = false


func _ready() -> void:
	layer = LAYER
	_build()
	hide_browser()


func show_pile(title: String, cards: Array[Dictionary]) -> void:
	_clear_items()
	_title.text = "%s (%d)" % [title, cards.size()]
	if cards.is_empty():
		var empty_label: Label = Label.new()
		empty_label.text = "Empty"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		empty_label.add_theme_font_size_override("font_size", 20)
		_list.add_child(empty_label)
	else:
		for card: Dictionary in cards:
			_add_item(card)
	_root.visible = true
	_visible = true


func hide_browser() -> void:
	if _root != null:
		_root.visible = false
	_visible = false


func is_open() -> bool:
	return _visible


# ------------------------------------------------------------------------------------------
# Construction
# ------------------------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dimmer: ColorRect = ColorRect.new()
	dimmer.set_anchors_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0, 0, 0, 0.5)
	dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	dimmer.gui_input.connect(_on_dimmer_input)
	_root.add_child(dimmer)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.97)
	style.border_color = Color(0.36, 0.68, 1.0, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(16)
	style.set_content_margin_all(20)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var outer: VBoxContainer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	_panel.add_child(outer)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_title.add_theme_font_size_override("font_size", 24)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	outer.add_child(_title)

	var sep: HSeparator = HSeparator.new()
	outer.add_child(sep)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	_scroll.add_child(_list)


func _add_item(card: Dictionary) -> void:
	var btn: Button = Button.new()
	btn.custom_minimum_size.y = ITEM_HEIGHT
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT

	var card_type: int = int(card.get("type", 0))
	var card_name: String = str(card.get("name", "???"))
	var stat_text: String = ""
	if (card_type & DuelEnums.TYPE.MONSTER) != 0:
		var atk: int = int(card.get("attack", 0))
		var def_val: int = int(card.get("defense", 0))
		if (card_type & DuelEnums.TYPE.LINK) != 0:
			stat_text = "  ATK %d / LINK-%d" % [atk, int(card.get("link", 0))]
		else:
			stat_text = "  ATK %d / DEF %d" % [atk, def_val]
	btn.text = card_name + stat_text

	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = Color(0.06, 0.07, 0.10, 0.0)
	normal.set_corner_radius_all(4)
	normal.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", normal)

	var hover: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.15, 0.22, 0.35, 0.6)
	btn.add_theme_stylebox_override("hover", hover)

	var pressed_style: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	pressed_style.bg_color = Color(0.10, 0.18, 0.30, 0.8)
	btn.add_theme_stylebox_override("pressed", pressed_style)

	btn.add_theme_color_override("font_color", CardPreview._name_colour(card_type))
	btn.add_theme_color_override("font_hover_color", CardPreview._name_colour(card_type).lightened(0.2))
	btn.add_theme_font_size_override("font_size", 17)

	btn.pressed.connect(_on_card_pressed.bind(card))
	_list.add_child(btn)


func _on_card_pressed(card: Dictionary) -> void:
	card_selected.emit(card)


func _clear_items() -> void:
	for child: Node in _list.get_children():
		child.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if not is_open():
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		hide_browser()
		closed.emit()


func _on_dimmer_input(event: InputEvent) -> void:
	if not is_open():
		return
	var pressed: bool = (
		(event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if not pressed:
		return
	_root.accept_event()
	hide_browser()
	closed.emit()
