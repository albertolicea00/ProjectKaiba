class_name ControlsScreen
extends Control

## The Controls destination: every gesture the game listens for, on both devices.
##
## Layer: L5 shell. It knows one destination name ("menu") and one table, and nothing else - no
## duel, no board, no core.
##
## -------------------------------------------------------------------------------------------
## Why this screen holds no list
## -------------------------------------------------------------------------------------------
## Every row below is read out of `InputSource.BINDINGS` at runtime. Nothing here names a
## gesture, a key or a button, because a controls screen that repeats what the input sources do
## drifts the first time somebody adds a gesture - and a controls screen that lies is worse than
## no controls screen at all. The bindings are declared once, next to the code that implements
## them; this is a renderer for that declaration. `ui/ui_test.gd` asserts that every `KIND_*`
## constant on `InputSource` appears in the table, so a new verb fails the suite rather than
## quietly going undocumented.
##
## -------------------------------------------------------------------------------------------
## Why both columns are always shown
## -------------------------------------------------------------------------------------------
## The honest-looking move is to show the touch column on a phone and the PC column on a
## desktop. That requires asking how big the window is in order to make a logic decision, which
## is exactly what ARCHITECTURE.md section 10 rule 4 forbids, and the rule is right: a phone
## cast to a monitor, a desktop with a touchscreen, a tablet with a keyboard and the VR build
## that is coming are all one binary, and a build that guesses wrong hides the controls the
## player actually has. So both columns are always present and always labelled with the device
## they belong to, and the player reads the one in front of them.
##
## -------------------------------------------------------------------------------------------
## The dressing
## -------------------------------------------------------------------------------------------
## The same temple, the same stone slab on Back and the same borrowed face as the main menu, all
## of it resolved by `MenuArt` in `game/ui/`. No constant of its is copied here and no decision
## of its is remade; this file asks and assigns.
##
## A two-column table of gestures is the hardest thing on any of the three screens to keep
## legible over a photograph, and the trap is to answer that by dropping the art. Each row
## instead sits on `MenuArt.content_panel()` - near-opaque dark with a sandstone edge - so the
## temple shows between and around the rows while every word is contrasted against a near-black
## that does not move. Back lives outside the scroll, so the way out never scrolls off.

const MenuArt := preload("res://ui/menu_art.gd")

signal chose(destination: String)

## Where Back goes. A string, not a scene: the router owns what the name means.
const MENU: String = "menu"

## Column headers. The labels, not a device test - see the header note.
const TOUCH_HEADER: String = "Touch"
const PC_HEADER: String = "Mouse & keyboard"

## Printed in the gesture cell when a device has no binding for a verb. An empty cell reads as a
## rendering bug; this reads as a fact.
const NO_BINDING: String = "no gesture yet"

## Breathing room between a row's carved edge and its words, in pixels.
const ROW_PADDING: float = 18.0

## Sandstone, not the blue this screen used to be lettered in: the rows have to look like they
## belong to the same temple as the slabs.
const COLOR_HEADING: Color = Color(0.729412, 0.647059, 0.47451)
const COLOR_LABEL: Color = Color(0.956863, 0.901961, 0.776471)
const COLOR_GESTURE: Color = Color(0.945098, 0.811765, 0.482353)
const COLOR_DETAIL: Color = Color(0.835294, 0.788235, 0.690196)

@onready var _background: TextureRect = $Background
@onready var _rows: VBoxContainer = $Frame/Column/Scroll/Rows
@onready var _status: Label = $Frame/Column/Status
@onready var _back: Button = $Frame/Column/Back

var _message: String = ""

## What `MenuArt` resolved, held so a test can read the outcome rather than re-deriving it.
## `_face` is null when Papyrus is not on this machine, which is the supported case.
var _face: Font = null
var _background_texture: Texture2D = null


func _ready() -> void:
	_dress()
	_build()
	_back.pressed.connect(func() -> void: chose.emit(MENU))
	_back.grab_focus()
	_status.text = _message


## Hangs the temple and puts Back on stone. Everything it needs comes from `MenuArt`; the row
## panels are built per row in `_row()` for the same reason.
func _dress() -> void:
	_background_texture = MenuArt.current_background()
	_background.texture = _background_texture
	$Scrim.color = MenuArt.SCRIM_COLOR

	_face = MenuArt.menu_font()
	for path: String in ["Frame/Column/Title", "Frame/Column/Subtitle", "Frame/Column/Status"]:
		MenuArt.letter(get_node_or_null(path) as Control, _face)

	MenuArt.dress_slab(_back, _back.text, MenuArt.resting_slab(), MenuArt.pressed_slab(), _face)


## The face this screen is lettered in, or `null` when the system font was not available.
func face() -> Font:
	return _face


## The background cut that was chosen for this device's orientation.
func background_texture() -> Texture2D:
	return _background_texture


## The panel one row sits on, so a test can measure it against the text it is covering.
func row_panel(index: int) -> PanelContainer:
	if index < 0 or index >= _rows.get_child_count():
		return null
	return _rows.get_child(index) as PanelContainer


## Satisfies `SceneRouter.MESSAGE_METHOD`, so this screen can carry a line of explanation like
## every other destination does.
func show_message(text: String) -> void:
	_message = text
	if not is_node_ready():
		return
	_status.text = _message


## How many rows the screen drew. The suite reads it rather than walking the tree, so the
## assertion is about what was rendered and not about a node path.
func row_count() -> int:
	return _rows.get_child_count()


## The text rendered for one binding, flattened: label, what it does, and both gestures. The
## suite greps this, so a binding that reached the table but not the screen is a failure.
func row_text(index: int) -> String:
	var row: Node = _rows.get_child(index) if index >= 0 and index < _rows.get_child_count() else null
	if row == null:
		return ""
	return _flatten(row)


func _flatten(node: Node) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if node is Label:
		parts.append((node as Label).text)
	for child: Node in node.get_children():
		var text: String = _flatten(child)
		if not text.is_empty():
			parts.append(text)
	return "\n".join(parts)


# ----------------------------------------------------------------------------------------------
# Building
# ----------------------------------------------------------------------------------------------

func _build() -> void:
	for existing: Node in _rows.get_children():
		_rows.remove_child(existing)
		existing.queue_free()

	for binding: Dictionary in InputSource.BINDINGS:
		_rows.add_child(_row(binding))


## One binding as a panel: the verb, what it does, then the two device columns side by side.
##
## Both columns live in the same `HBoxContainer` with equal expand flags, so neither is ever
## measured against the window - they split whatever width the frame gives them, and on a narrow
## phone that is simply two narrower columns of wrapped text.
func _row(binding: Dictionary) -> Control:
	var panel := PanelContainer.new()
	# The whole reason the table survives being put on top of a photograph. `content_panel()`
	# carries its own padding, so there is no `MarginContainer` between the panel and the words.
	panel.add_theme_stylebox_override("panel", MenuArt.content_panel(ROW_PADDING))

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)

	column.add_child(_label(str(binding.get("label", "")), 26, COLOR_LABEL))
	column.add_child(_label(str(binding.get("does", "")), 18, COLOR_DETAIL))

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	column.add_child(spacer)

	var devices := HBoxContainer.new()
	devices.add_theme_constant_override("separation", 24)
	column.add_child(devices)
	devices.add_child(_device(TOUCH_HEADER, str(binding.get("touch", ""))))
	devices.add_child(_device(PC_HEADER, str(binding.get("pc", ""))))

	return panel


## One device column: the device name above the gesture. The header is always drawn, including
## when the device has no binding for this verb, because "Touch: no gesture yet" is information
## and a missing column is a puzzle.
func _device(header: String, gesture: String) -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)
	column.add_child(_label(header, 15, COLOR_HEADING))
	column.add_child(_label(gesture if not gesture.is_empty() else NO_BINDING, 20, COLOR_GESTURE))
	return column


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	MenuArt.letter(label, _face)
	return label
