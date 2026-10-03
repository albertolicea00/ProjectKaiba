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
## Why a picker and not an editor
## -------------------------------------------------------------------------------------------
## Decks are built in the tools the player already uses and arrive as `.ydk` files. Owning a
## deck *format* would cut this client off from every other one; reading theirs costs a parser
## and gains every deck they have ever made. See `DeckLibrary` for the longer version.

## The deck the player committed to. Carries a `DeckLibrary` entry.
signal chose(entry: Dictionary)

## Backing out without choosing.
signal cancelled

const EMPTY_TITLE: String = "No decks found"

var _entries: Array[Dictionary] = []
var _selected: int = -1

@onready var _list: ItemList = $Root/Column/Body/List
@onready var _detail: RichTextLabel = $Root/Column/Body/Detail
@onready var _play: Button = $Root/Column/Actions/Play
@onready var _hint: Label = $Root/Column/Hint


func _ready() -> void:
	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_play.pressed.connect(_commit)
	$Root/Column/Actions/Back.pressed.connect(func() -> void: cancelled.emit())
	refresh()


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
	lines.append("[i]%s[/i]" % str(entry.get("path", "")))
	_detail.text = "\n".join(lines)


func _on_item_activated(index: int) -> void:
	_selected = index
	_commit()


func _commit() -> void:
	var entry: Dictionary = selected_entry()
	if entry.is_empty():
		return
	DeckLibrary.remember(entry)
	chose.emit(entry)


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
