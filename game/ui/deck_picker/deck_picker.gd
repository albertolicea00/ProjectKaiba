class_name DeckPicker
extends Control
## Choose a deck to play. There is no editing here, by design.
##
## Layer: L4/L5 shell (AGENTS.md section 4). **V1: this file never names `KaibaCore`.** It is
## handed `DeckLibrary` entries - plain Dictionaries - and emits the one the player chose.
##
## ARCHITECTURE.md section 10 rule 4: no widget below measures the screen. Anchors and
## containers only, so this layer can become world-space quads in VR without a rewrite.
##
## -------------------------------------------------------------------------------------------
## The dressing
## -------------------------------------------------------------------------------------------
## The same temple, the same stone slabs and the same borrowed face as the main menu, all of it
## resolved by `MenuArt` in `game/ui/`. Nothing about the art is decided here and no constant of
## its is copied: this file asks for a background, two slab states, a face and a panel, and
## assigns what comes back. That is what keeps the three screens in step - a change to the dress
## happens in one file or it does not happen.
##
## A deck list and a details pane are small text in quantity, and small text straight onto a
## photograph of carved stone is unreadable at arm's length. So the list and the details sit on
## `MenuArt.content_panel()`, which is near-opaque dark with a sandstone edge: the temple is
## still visible behind and around it, and every word in front of it is contrasted against a
## near-black that does not move with the picture.
##
## -------------------------------------------------------------------------------------------
## Why a picker and not an editor
## -------------------------------------------------------------------------------------------
## Decks are built in the tools the player already uses and arrive as `.ydk` files. Owning a
## deck *format* would cut this client off from every other one; reading theirs costs a parser
## and gains every deck they have ever made. See `DeckLibrary` for the longer version.

## The deck the player committed to. Carries a `DeckLibrary` entry.
##
## **Not** named `chose`. `MainMenu.chose(String)` already means "go to this destination", and
## `SceneRouter` connects to that name on whatever screen it loads - so a second screen using
## it for a different payload made the router hand a Dictionary to a String parameter and the
## choice died at the signal boundary. Two screens, one verb, two meanings.
signal deck_chosen(entry: Dictionary)

## Where this screen wants to go next. Same contract as `MainMenu.chose`, which is what makes
## the router's by-name connection safe rather than lucky: a screen either speaks the navigation
## verb properly or does not declare it at all.
signal chose(destination: String)

## Backing out without choosing.
signal cancelled

const MenuArt := preload("res://ui/menu_art.gd")

const EMPTY_TITLE: String = "No decks found"

## Where Back goes. A string, not a scene: the router owns what the name means.
const MENU: String = "menu"
## Where choosing a deck goes. A deck is chosen in order to play with it.
const PLAY: String = "solo"

## The deck names in the list, and the body text in the details pane. Both read over the panel,
## not over the picture.
const LIST_COLOR: Color = Color(0.956863, 0.901961, 0.776471)
const DETAIL_COLOR: Color = Color(0.886275, 0.843137, 0.741176)
const SELECTED_FILL: Color = Color(0.309804, 0.243137, 0.117647, 0.901961)
const SELECTED_EDGE: Color = Color(0.745098, 0.611765, 0.329412)

const LIST_FONT_SIZE: int = 20
const DETAIL_FONT_SIZE: int = 18

var _entries: Array[Dictionary] = []
var _selected: int = -1

@onready var _background: TextureRect = $Background
@onready var _body: PanelContainer = $Frame/Column/Body
@onready var _list: ItemList = $Frame/Column/Body/Split/List
@onready var _detail: RichTextLabel = $Frame/Column/Body/Split/Detail
@onready var _back: Button = $Frame/Column/Actions/Back
@onready var _play: Button = $Frame/Column/Actions/Play
@onready var _hint: Label = $Frame/Column/Hint

## What `MenuArt` resolved, held so a test can read the outcome rather than re-deriving it.
## `_face` is null when Papyrus is not on this machine, which is the supported case.
var _face: Font = null
var _background_texture: Texture2D = null


func _ready() -> void:
	_dress()

	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_play.pressed.connect(_commit)
	_back.pressed.connect(func() -> void:
		# Back was dead: `cancelled` had no listener anywhere, so the button emitted into
		# nothing. The router only ever connects the navigation verb, so Back has to speak it.
		cancelled.emit()
		chose.emit(MENU))
	refresh()


## Hangs the temple, puts the two action buttons on stone, and gives the list and the details
## pane the dark panel that makes them readable on top of it. Every decision comes from
## `MenuArt`; none of them is made here.
func _dress() -> void:
	_background_texture = MenuArt.current_background()
	_background.texture = _background_texture
	$Scrim.color = MenuArt.SCRIM_COLOR

	_face = MenuArt.menu_font()
	for path: String in ["Frame/Column/Title", "Frame/Column/Hint"]:
		MenuArt.letter(get_node_or_null(path) as Control, _face)

	_body.add_theme_stylebox_override("panel", MenuArt.content_panel())

	var resting: StyleBoxTexture = MenuArt.resting_slab()
	var pressed: StyleBoxTexture = MenuArt.pressed_slab()
	MenuArt.dress_slab(_back, _back.text, resting, pressed, _face)
	MenuArt.dress_slab(_play, _play.text, MenuArt.resting_slab(), MenuArt.pressed_slab(), _face)

	# The list draws its own background by default, which would be a second panel inside the
	# first. Emptied, so the one panel behind it is the only one.
	_list.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for slot: String in ["selected", "selected_focus", "cursor", "cursor_unfocused"]:
		_list.add_theme_stylebox_override(slot, _selected_box())
	_list.add_theme_color_override("font_color", LIST_COLOR)
	_list.add_theme_color_override("font_selected_color", LIST_COLOR)
	_list.add_theme_font_size_override("font_size", LIST_FONT_SIZE)
	_list.add_theme_constant_override("v_separation", 14)
	MenuArt.letter(_list, _face)

	_detail.add_theme_color_override("default_color", DETAIL_COLOR)
	_detail.add_theme_font_size_override("normal_font_size", DETAIL_FONT_SIZE)
	_detail.add_theme_font_size_override("bold_font_size", DETAIL_FONT_SIZE + 6)
	_detail.add_theme_font_size_override("italics_font_size", DETAIL_FONT_SIZE - 2)
	for slot: String in ["normal_font", "bold_font", "italics_font", "bold_italics_font"]:
		if _face != null:
			_detail.add_theme_font_override(slot, _face)


## The lit row in the list: the same gold the pressed slab is lit with, so a selection reads as
## the same gesture as a press.
func _selected_box() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = SELECTED_FILL
	box.border_color = SELECTED_EDGE
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	return box


## The face this screen is lettered in, or `null` when the system font was not available.
func face() -> Font:
	return _face


## The background cut that was chosen for this device's orientation.
func background_texture() -> Texture2D:
	return _background_texture


## The panel the list and the details pane sit on, so a test can measure it against the text it
## is supposed to be covering.
func content_panel_node() -> PanelContainer:
	return _body


## Re-reads the deck folders. Cheap enough to call on every entry to this screen, which is what
## makes "drop a file in and it appears" work without a watcher.
func refresh() -> void:
	_entries = DeckLibrary.entries()
	_selected = -1
	_list.clear()

	for entry: Dictionary in _entries:
		_list.add_item("%s   (%d/%d/%d)" % [
			str(entry.get("name", "?")),
			int(entry.get("main", 0)), int(entry.get("extra", 0)), int(entry.get("side", 0))])

	if _entries.is_empty():
		_detail.text = _empty_text()
		_hint.text = EMPTY_TITLE
	else:
		_detail.text = "Pick a deck."
		_hint.text = "%d deck%s available" % [_entries.size(), "" if _entries.size() == 1 else "s"]
		_list.select(0)
		_on_item_selected(0)

	_play.disabled = _entries.is_empty()


func selected_entry() -> Dictionary:
	if _selected < 0 or _selected >= _entries.size():
		return {}
	return _entries[_selected]


func _on_item_selected(index: int) -> void:
	_selected = index
	var entry: Dictionary = selected_entry()
	if entry.is_empty():
		return

	# Counts come from the parse, so a deck that is short or oversized says so here rather than
	# being refused later by the engine with a message the player cannot act on.
	var main_count: int = int(entry.get("main", 0))
	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]%s[/b]" % str(entry.get("name", "?")))
	lines.append("")
	lines.append("Main %d    Extra %d    Side %d" % [
		main_count, int(entry.get("extra", 0)), int(entry.get("side", 0))])
	if main_count < 40:
		lines.append("[color=#d88]Main deck is short - a duel needs at least 40.[/color]")
	elif main_count > 60:
		lines.append("[color=#d88]Main deck is over 60.[/color]")
	lines.append("")
	# Only the folder and the file name: a full path wraps hard in a 244 px pane on a
	# 720-wide phone, and the tail is what tells two same-named decks apart.
	lines.append("[i]%s[/i]" % _short_path(str(entry.get("path", ""))))
	_detail.text = "\n".join(lines)



func _short_path(path: String) -> String:
	if path.is_empty():
		return ""
	var parts: PackedStringArray = path.split("/", false)
	if parts.size() <= 2:
		return path
	return ".../%s/%s" % [parts[parts.size() - 2], parts[parts.size() - 1]]

func _on_item_activated(index: int) -> void:
	_selected = index
	_commit()


func _commit() -> void:
	var entry: Dictionary = selected_entry()
	if entry.is_empty():
		return
	DeckLibrary.remember(entry)
	deck_chosen.emit(entry)
	# A deck is chosen in order to play with it, so this is also a navigation: picking one and
	# being left on the picker would make the player hunt for the way out.
	chose.emit(PLAY)


## What to say when there is nothing to play. Names the folders, because the fix is to put a
## file in one of them and an empty list that does not say where is a dead end.
func _empty_text() -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]%s[/b]" % EMPTY_TITLE)
	lines.append("")
	lines.append("Drop any .ydk file into one of these and come back:")
	lines.append("")
	for source: String in ["user", "bundled"]:
		var root: String = DeckLibrary.root_for(source)
		lines.append("  %s" % (root if not root.is_empty() else "(%s folder not created yet)" % source))
	lines.append("")
	lines.append("Decks built in EDOPro, YGOPro or any other client work unchanged.")
	return "\n".join(lines)
