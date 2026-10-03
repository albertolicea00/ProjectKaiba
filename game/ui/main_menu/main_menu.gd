class_name MainMenu
extends Control

## The first screen. Seven destinations (ARCHITECTURE.md section 4), three of which currently
## lead somewhere: Solo, Solo Test and Controls. The other four are real roadmap entries with
## nothing behind them yet, and they say so on the button rather than waiting to disappoint. A greyed-out button reads as
## "this app is broken"; a button that says "not built yet" reads as "this is being built".
##
## Layer: L5 shell. It knows destination names and nothing else - no scenes, no duel, no core.
## Whoever listens to `chose` decides what a name means; `SceneRouter` is that listener today.
##
## Touch first: one full-width target per row, no small hit areas, no hover-only affordances,
## and a layout of anchors and containers that holds at phone aspect ratios in landscape.
## As in `DuelHud`, nothing here measures the screen - ARCHITECTURE.md section 10 rule 4.

signal chose(destination: String)

## One row of the menu. `node` is the button in `main_menu.tscn`, `id` is what `chose` emits,
## and `note` is the honesty: empty means the destination works. The text on the button is
## written from this table at runtime, so the table is the single source and the text in the
## scene file is only a preview for the editor.
const ENTRIES: Array[Dictionary] = [
	{"node": "Solo", "id": "solo", "label": "Solo", "note": ""},
	{"node": "SoloTest", "id": "solo_test", "label": "Solo Test", "note": ""},
	{"node": "Controls", "id": "controls", "label": "Controls", "note": ""},
	{"node": "Host", "id": "host", "label": "Host Duel", "note": "not built yet"},
	{"node": "Join", "id": "join", "label": "Join Duel", "note": "not built yet"},
	{"node": "Decks", "id": "decks", "label": "Decks", "note": "not built yet"},
	{"node": "Replays", "id": "replays", "label": "Replays", "note": "not built yet"},
]

@onready var _buttons: VBoxContainer = $Frame/Center/Column/Buttons
@onready var _status: Label = $Frame/Center/Column/Status

## Kept here as well as on the label, so a message that arrives before this menu is in
## the tree still shows up once it is.
var _message: String = ""


func _ready() -> void:
	for entry: Dictionary in ENTRIES:
		var button: Button = _buttons.get_node(str(entry["node"])) as Button
		if button == null:
			push_error("main_menu.tscn has no button named '%s'" % str(entry["node"]))
			continue
		var note: String = str(entry["note"])
		button.text = str(entry["label"]) if note.is_empty() else "%s   (%s)" % [str(entry["label"]), note]
		button.pressed.connect(_on_pressed.bind(str(entry["id"])))

	# Only so a keyboard or a gamepad has somewhere to start. A finger ignores focus entirely.
	var first: Button = _buttons.get_child(0) as Button
	if first != null:
		first.grab_focus()

	_status.text = _message


## A line of explanation for the player: why the thing they just picked did nothing, or whatever
## else the router wants to say. Empty clears it.
func show_message(text: String) -> void:
	_message = text
	if not is_node_ready():
		return
	_status.text = _message


func _on_pressed(destination: String) -> void:
	chose.emit(destination)
