class_name ActionMenu
extends CanvasLayer

## A popup that shows what you can do with the card you are holding: summon, set, activate,
## attack. The player picks one and the duel answers the pending selection with that choice.
##
## Layer: L5 shell (AGENTS.md section 4). Like DuelHud, it is handed data and renders it.
## It has never heard of KaibaCore, DuelState or SelectionController.
##
## Built in code rather than a .tscn because the content is entirely dynamic: the number
## and text of the buttons depend on what the engine offers for the card being held. A
## scene file with a fixed set of buttons would either hide the ones that do not apply or
## grow a factory that is more code than the scene saves.

signal action_chosen(cmd: String, index: int)
signal dismissed

const LAYER: int = 12

const BUTTON_MIN_HEIGHT: int = 56
const PANEL_MAX_WIDTH: int = 340

var _root: Control = null
var _panel: PanelContainer = null
var _column: VBoxContainer = null
var _title: Label = null
var _visible: bool = false


func _ready() -> void:
	layer = LAYER
	_build()
	hide_menu()


func show_actions(card_name: String, actions: Array[Dictionary]) -> void:
	_clear_buttons()
	_title.text = card_name if not card_name.is_empty() else "Card"

	for action: Dictionary in actions:
		var key: String = str(action.get("key", ""))
		var label_text: String = str(action.get("label", key))
		var idx: int = int(action.get("index", 0))
		_add_button(label_text, key, idx)

	_add_button("Cancel", "", -1)
	_root.visible = true
	_visible = true


func hide_menu() -> void:
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
	_panel.custom_minimum_size.x = PANEL_MAX_WIDTH
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
	outer.add_theme_constant_override("separation", 14)
	_panel.add_child(outer)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_title.add_theme_font_size_override("font_size", 26)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	outer.add_child(_title)

	var sep: HSeparator = HSeparator.new()
	outer.add_child(sep)

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 8)
	outer.add_child(_column)


const ACTION_COLOURS: Dictionary = {
	"summon": Color(0.12, 0.18, 0.35),
	"spsummon": Color(0.20, 0.12, 0.30),
	"mset": Color(0.25, 0.22, 0.10),
	"sset": Color(0.25, 0.22, 0.10),
	"activate": Color(0.10, 0.22, 0.15),
	"attack": Color(0.30, 0.10, 0.10),
	"repos": Color(0.18, 0.18, 0.12),
	"_yesno": Color(0.12, 0.20, 0.15),
	"_chain": Color(0.10, 0.22, 0.15),
	"_surrender": Color(0.35, 0.08, 0.08),
}


func _add_button(text: String, cmd: String, index: int) -> void:
	var btn: Button = Button.new()
	btn.text = text
	btn.custom_minimum_size.y = BUTTON_MIN_HEIGHT
	btn.add_theme_font_size_override("font_size", 22)

	var bg: Color = Color(0.08, 0.08, 0.12)
	if not cmd.is_empty():
		bg = ACTION_COLOURS.get(cmd, Color(0.12, 0.14, 0.20)) as Color
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = bg
	normal.set_corner_radius_all(8)
	normal.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", normal)

	var hover: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.18, 0.28, 0.48)
	hover.border_color = Color(0.36, 0.68, 1.0, 0.6)
	hover.set_border_width_all(1)
	btn.add_theme_stylebox_override("hover", hover)

	var pressed_style: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	pressed_style.bg_color = Color(0.10, 0.20, 0.40)
	btn.add_theme_stylebox_override("pressed", pressed_style)

	btn.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))

	if cmd.is_empty():
		btn.pressed.connect(func() -> void:
			hide_menu()
			dismissed.emit())
	else:
		btn.pressed.connect(func() -> void:
			hide_menu()
			action_chosen.emit(cmd, index))
	_column.add_child(btn)


func _clear_buttons() -> void:
	for child: Node in _column.get_children():
		child.queue_free()


func _on_dimmer_input(event: InputEvent) -> void:
	if not is_open():
		return
	var pressed: bool = (
		(event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if not pressed:
		return
	_root.accept_event()
	hide_menu()
	dismissed.emit()
