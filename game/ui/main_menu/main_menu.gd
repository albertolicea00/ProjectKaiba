class_name MainMenu
extends Control

## The first screen. Six destinations (ARCHITECTURE.md section 4), three of which currently
## lead somewhere: Solo, Decks and Controls. Host, Join and Replays are real roadmap entries
## with nothing behind them yet.
##
## Nothing on a slab says so. Every entry is lettered as a plain word and every entry is
## enabled, because a greyed-out button reads as "this app is broken". What an unbuilt entry
## does instead is **route**: pressing it lands back here with the reason written into the
## status line under the slabs - `SceneRouter.PENDING` owns that text and `show_message()`
## puts it on screen. That status line is the only thing telling the player why nothing
## happened, so no change here may let it fall silent.
##
## Layer: L5 shell. It knows destination names and nothing else - no scenes, no duel, no core.
## Whoever listens to `chose` decides what a name means; `SceneRouter` is that listener today,
## and the names in `ENTRIES` are spelled to match the ones it already routes.
##
## ------------------------------------------------------------------------------------------
## The dressing
## ------------------------------------------------------------------------------------------
## A temple behind, stone slabs stacked down the centre, one word per slab, centred in the
## stone. All three decisions that need art - which background cut, how the slab's carved edge
## survives being stretched to a menu row's shape, and which face the words are lettered in -
## live in `menu_art.gd` next door, as static functions with no scene tree, so each of them can
## be asked directly by a test. This file only assigns what they hand back.
##
## Touch first: one wide slab per row, a floor of `SLAB_MIN_HEIGHT` on every one of them, no
## small hit areas and no hover-only affordances - the lit slab that desktop gets on hover is
## the same one a finger gets on press, so nothing is communicated by hover alone.
##
## As in `DuelHud`, nothing here measures the screen - ARCHITECTURE.md section 10 rule 4. The
## one device property this file reads is the screen's *orientation*, and only to choose which
## of two background files to load; see `MenuArt.background_for_orientation()` for why that is
## a different act from sizing a widget, and `ui_test.gd` for the grep that holds the line.

const MenuArt := preload("res://ui/main_menu/menu_art.gd")

signal chose(destination: String)

## One row of the menu. `node` is the slab in `main_menu.tscn`, `id` is what `chose` emits and
## `label` is the word carved on it. The word is written from this table at runtime, so the
## table is the single source and the text in the scene file is only a preview for the editor.
##
## `id` is never a new string. Each one is a destination `SceneRouter` already answers to -
## three of them real routes (`SOLO`, `DECKS`, `CONTROLS`), three of them keys in its `PENDING`
## table (`host`, `join`, `replays`, which the router names only as keys, so they are spelled
## here as the literals it matches). `solo` is the hot seat: both turns are yours, which is the
## only solo duel the build actually plays.
const ENTRIES: Array[Dictionary] = [
	{"node": "Solo", "id": "solo", "label": "Solo"},
	{"node": "Host", "id": "host", "label": "Host"},
	{"node": "Join", "id": "join", "label": "Join"},
	{"node": "Decks", "id": "decks", "label": "Decks"},
	{"node": "Controls", "id": "controls", "label": "Controls"},
	{"node": "Replays", "id": "replays", "label": "Replays"},
]

## Every slab is at least this tall. Well above the 48 px a thumb needs, and above the carved
## border the slab's nine-patch draws at `MenuArt.SLAB_SCALE` - that second floor is the one
## that is easy to forget: below the border's own depth the patch slices would overlap each
## other instead of framing anything. `MenuArt.slab_border_height()` is what that is checked
## against, and `ui_test.gd` checks it.
const SLAB_MIN_HEIGHT := 88

const WORD_COLOR := Color(0.956863, 0.901961, 0.776471)
const WORD_SIZE := 30

@onready var _background: TextureRect = $Background
@onready var _buttons: VBoxContainer = $Frame/Center/Column/Buttons
@onready var _status: Label = $Frame/Center/Column/Status

## Kept here as well as on the label, so a message that arrives before this menu is in
## the tree still shows up once it is.
var _message: String = ""

## What `menu_art.gd` resolved, held so a test can read the outcome rather than re-deriving it.
## `_face` is null when Papyrus is not on this machine, which is the supported case.
var _face: Font = null
var _background_texture: Texture2D = null


func _ready() -> void:
	_background_texture = MenuArt.current_background()
	_background.texture = _background_texture

	_face = MenuArt.menu_font()

	var resting: StyleBoxTexture = MenuArt.resting_slab()
	var pressed: StyleBoxTexture = MenuArt.pressed_slab()

	for label: String in ["Title", "Subtitle", "Status"]:
		_letter(get_node_or_null("Frame/Center/Column/%s" % label) as Control)

	for entry: Dictionary in ENTRIES:
		var button: Button = _buttons.get_node_or_null(str(entry["node"])) as Button
		if button == null:
			push_error("main_menu.tscn has no button named '%s'" % str(entry["node"]))
			continue
		_dress(button, str(entry["label"]), resting, pressed)
		button.pressed.connect(_on_pressed.bind(str(entry["id"])))

	# Only so a keyboard or a gamepad has somewhere to start. A finger ignores focus entirely.
	var first: Button = _buttons.get_child(0) as Button
	if first != null:
		first.grab_focus()

	_status.text = _message


## Writes one word onto its slab, centred in the stone, and gives the slab its two carved
## states.
##
## `hover` gets the lit slab as well as `pressed`, which on a phone is simply never reached.
## The point is the reverse: nothing is said by hover that is not also said by a press, so a
## device with no pointer loses no information.
func _dress(button: Button, word: String, resting: StyleBox, pressed: StyleBox) -> void:
	button.text = word
	button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, float(SLAB_MIN_HEIGHT))
	# Across: explicit. Down: `Button` has no vertical text alignment because it always centres
	# its text in whatever the stylebox leaves it, so the symmetric content margins in
	# `MenuArt.slab_box()` are what actually keeps the word in the middle of the stone.
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.icon = null

	button.add_theme_stylebox_override("normal", resting)
	button.add_theme_stylebox_override("disabled", resting)
	button.add_theme_stylebox_override("hover", pressed)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", pressed)

	button.add_theme_color_override("font_color", WORD_COLOR)
	button.add_theme_color_override("font_hover_color", WORD_COLOR)
	button.add_theme_color_override("font_pressed_color", WORD_COLOR)
	button.add_theme_color_override("font_focus_color", WORD_COLOR)
	button.add_theme_font_size_override("font_size", WORD_SIZE)
	_letter(button)


## Applies the resolved face to one widget, if there is one to apply. A null face is the
## documented fallback, not a failure - see `menu_art.gd`.
func _letter(widget: Control) -> void:
	if widget == null or _face == null:
		return
	widget.add_theme_font_override("font", _face)


## The face the menu is lettered in, or `null` when the system font was not available and the
## engine default is in use. Exposed so a test can assert both paths.
func face() -> Font:
	return _face


## The background cut that was chosen for this device's orientation.
func background_texture() -> Texture2D:
	return _background_texture


## A line of explanation for the player: why the thing they just picked did nothing, or whatever
## else the router wants to say. Empty clears it.
##
## This is where an unbuilt destination explains itself. Nothing on the slabs admits to being
## unbuilt, so if this stops reaching the screen the player gets a button that does nothing and
## no reason at all.
func show_message(text: String) -> void:
	_message = text
	if not is_node_ready():
		return
	_status.text = _message


func _on_pressed(destination: String) -> void:
	chose.emit(destination)
