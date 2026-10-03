class_name DeckEditor
extends Control

## The deck editor: a searchable card pool on the left, the three deck lists on the right, tap
## to add, tap to remove, with the validator's verdict recomputed on every change.
##
## Layer: **L5 shell**. It is handed its data and never fetches any:
##
##   * `catalogue`  an `Array` of `Dictionary`, one per card, derived by whoever owns the card
##                  database from `get_card_info()`.
##   * `info_for`   `func(code: int) -> Dictionary`, the same shape, for a card the catalogue
##                  does not list - a deck loaded from a `.ydk` written against a newer database.
##   * `art`        a `CardArt` for the thumbnails. Optional; without it the rows are blank.
##
## **V1**: nothing under `game/ui/` may name the native core, and this file does not. The
## lookups above belong to `scenes/deck_editor.gd`, which is outside `game/ui/` precisely so
## that it can own them. That is not bureaucracy: the same editor has to work over a deck
## received from a LAN host and over a deck read from a replay, neither of which has a live core
## to ask, and a widget that reached for one directly would be unusable in both.
##
## **ARCHITECTURE.md section 10 rule 4**: nothing here measures the screen. The landscape layout
## is anchors, `HBoxContainer` and stretch ratios, so it holds at a phone's aspect ratio for the
## same reason it holds on a monitor - because nothing in it branched on a pixel count.
## `VirtualCardList` reads its own height, which is a different thing; its header says why.
##
## -------------------------------------------------------------------------------------------
## An illegal deck is a state you are allowed to be in
## -------------------------------------------------------------------------------------------
## Adding a fourth copy, or a sixteenth extra-deck card, is **not** blocked. EDOPro blocks it;
## an editor should not. A player assembling a deck passes through illegal states constantly -
## the main deck is illegal at every size below forty - and a build that silently refuses a tap
## is indistinguishable from one that is broken. The verdict line goes red and says exactly what
## is wrong instead. The gate belongs where a deck is *used*, not where it is written:
## `DeckValidator.is_legal()` before a duel starts.

## Where the player wants to go next. `SceneRouter` listens; the editor knows nothing but names.
signal chose(destination: String)

## Emitted after any change to the deck, with the validator's result. A host that wants to gate
## a "Duel" button on legality listens to this rather than polling.
signal deck_changed(result: Dictionary)

const BACK_DESTINATION: String = "menu"

## The kind filter, in the order the OptionButton lists them.
enum KIND {
	ALL = 0,
	MONSTER = 1,
	SPELL = 2,
	TRAP = 3,
	EXTRA = 4,
}

## Where a tapped card goes. Side is a deliberate mode rather than a gesture: a long press or a
## second tap target would be invisible, and this has to work with a thumb.
enum TARGET {
	DECK = 0,
	SIDE = 1,
}

const PATH_BACK: String = "Frame/Column/TopBar/Back"
const PATH_NAME: String = "Frame/Column/TopBar/DeckName"
const PATH_SAVED: String = "Frame/Column/TopBar/Saved"
const PATH_SAVE: String = "Frame/Column/TopBar/Save"
const PATH_NEW: String = "Frame/Column/TopBar/New"
const PATH_VERDICT: String = "Frame/Column/Verdict"
const PATH_MESSAGE: String = "Frame/Column/Message"
const PATH_SEARCH: String = "Frame/Column/Split/Left/SearchRow/Search"
const PATH_KIND: String = "Frame/Column/Split/Left/SearchRow/Kind"
const PATH_TARGET: String = "Frame/Column/Split/Left/SearchRow/Target"
const PATH_FOUND: String = "Frame/Column/Split/Left/Found"
const PATH_CATALOGUE_SLOT: String = "Frame/Column/Split/Left/CatalogueSlot"

## Headers and slots per `DeckModel.LIST`, in that order.
const PATH_HEADER: Array[String] = [
	"Frame/Column/Split/Right/MainBox/MainHeader",
	"Frame/Column/Split/Right/ExtraBox/ExtraHeader",
	"Frame/Column/Split/Right/SideBox/SideHeader",
]
const PATH_SLOT: Array[String] = [
	"Frame/Column/Split/Right/MainBox/MainSlot",
	"Frame/Column/Split/Right/ExtraBox/ExtraSlot",
	"Frame/Column/Split/Right/SideBox/SideSlot",
]

const LIST_TITLE: Array[String] = ["Main", "Extra", "Side"]

## How many problems the verdict line spells out before it summarises the rest. Four is about
## what fits on a phone in landscape without the line eating the lists below it.
const MAX_SPELLED_ISSUES: int = 4

const COLOR_OK: Color = Color(0.513726, 0.796078, 0.517647, 1.0)
const COLOR_BAD: Color = Color(0.886275, 0.74902, 0.447059, 1.0)

const DEFAULT_DECK_NAME: String = "New Deck"

var _deck: DeckModel = DeckModel.new()
var _limits: Dictionary = DeckValidator.default_limits()

## Normalised once in `bind()`: every entry already carries the `name`, `note` and lowercase
## `search` string that filtering and `VirtualCardList` need. Filtering then appends references
## to these dictionaries instead of building 14 595 new ones per keystroke.
var _catalogue: Array[Dictionary] = []

## `code -> catalogue entry`, so a tap and a loaded deck can both find a card's type in O(1).
var _by_code: Dictionary = {}

## The fallback lookup for a code the catalogue does not carry. Set by `bind()`.
var _info_for: Callable = Callable()

var _art: CardArt = null

var _catalogue_list: VirtualCardList = null
## Indexed by `DeckModel.LIST`.
var _deck_lists: Array[VirtualCardList] = [null, null, null]

var _last_result: Dictionary = {}
var _message: String = ""


func _ready() -> void:
	_catalogue_list = _mount_list(PATH_CATALOGUE_SLOT, "Catalogue")
	_catalogue_list.set_empty_text("No cards match.")
	_catalogue_list.activated.connect(_on_catalogue_activated)

	for which: int in [DeckModel.LIST.MAIN, DeckModel.LIST.EXTRA, DeckModel.LIST.SIDE]:
		var list: VirtualCardList = _mount_list(PATH_SLOT[which], "%sList" % LIST_TITLE[which])
		list.set_empty_text("Empty.")
		list.activated.connect(_on_deck_activated.bind(which as DeckModel.LIST))
		_deck_lists[which] = list

	var kind: OptionButton = get_node(PATH_KIND) as OptionButton
	kind.clear()
	for label: String in ["All", "Monsters", "Spells", "Traps", "Extra deck"]:
		kind.add_item(label)
	kind.select(KIND.ALL)
	kind.item_selected.connect(_on_filter_changed)

	var target: OptionButton = get_node(PATH_TARGET) as OptionButton
	target.clear()
	target.add_item("To deck")
	target.add_item("To side")
	target.select(TARGET.DECK)

	(get_node(PATH_SEARCH) as LineEdit).text_changed.connect(_on_search_changed)
	(get_node(PATH_BACK) as Button).pressed.connect(_on_back)
	(get_node(PATH_SAVE) as Button).pressed.connect(_on_save)
	(get_node(PATH_NEW) as Button).pressed.connect(_on_new)
	(get_node(PATH_NAME) as LineEdit).text = DEFAULT_DECK_NAME

	var saved: OptionButton = get_node(PATH_SAVED) as OptionButton
	saved.item_selected.connect(_on_saved_selected)

	show_message(_message)

	_refresh_saved_list()
	_refresh_catalogue()
	_refresh_deck()


# ----------------------------------------------------------------------------------------------
# Binding
# ----------------------------------------------------------------------------------------------

## `catalogue` entries need `code`, `name` and `type`; `alias` is read when present. Everything
## else is derived here, once.
func bind(catalogue: Array[Dictionary], info_for: Callable = Callable(), art: CardArt = null) -> void:
	_info_for = info_for
	_art = art
	_catalogue = []
	_by_code = {}

	for row: Dictionary in catalogue:
		var code: int = int(row.get("code", 0))
		if code <= 0:
			continue
		var type: int = int(row.get("type", 0))
		var entry: Dictionary = {
			"code": code,
			"name": str(row.get("name", "")),
			"type": type,
			"alias": int(row.get("alias", 0)),
			"note": kind_label(type),
			# Name and passcode in one haystack, so "blue-eyes" and "89631139" both find the
			# dragon without the filter having to try two comparisons per card.
			"search": "%s %d" % [str(row.get("name", "")).to_lower(), code],
		}
		_catalogue.append(entry)
		_by_code[code] = entry

	if is_node_ready():
		_attach_art()
		_refresh_catalogue()
		_refresh_deck()


## Host-supplied deck sizes. See `DeckValidator`: the limits are not the engine's, they are the
## room's, and a LAN host sets them.
func set_limits(limits: Dictionary) -> void:
	_limits = DeckValidator.limits_from(limits)
	if is_node_ready():
		_refresh_deck()


## Replaces the deck being edited. The editor takes ownership of the instance it is given.
func set_deck(deck: DeckModel, deck_name: String = "") -> void:
	_deck = deck if deck != null else DeckModel.new()
	if is_node_ready():
		if not deck_name.is_empty():
			(get_node(PATH_NAME) as LineEdit).text = deck_name
		_refresh_deck()


func deck() -> DeckModel:
	return _deck


func deck_name() -> String:
	return (get_node(PATH_NAME) as LineEdit).text if is_node_ready() else ""


## The last validator result. `{}` before the first refresh.
func verdict() -> Dictionary:
	return _last_result


func verdict_text() -> String:
	return (get_node(PATH_VERDICT) as Label).text if is_node_ready() else ""


## The router's way of saying something to whatever is on screen. The label takes no height
## when there is nothing to say: three deck lists and a card pool have to share a phone's
## height in landscape, and an always-present empty line costs one row of the side deck.
func show_message(text: String) -> void:
	_message = text
	if is_node_ready():
		var label: Label = get_node(PATH_MESSAGE) as Label
		label.text = text
		label.visible = not text.is_empty()


## The catalogue list, for tests that want to see how much of it was instantiated.
func catalogue_list() -> VirtualCardList:
	return _catalogue_list


func list_for(which: DeckModel.LIST) -> VirtualCardList:
	return _deck_lists[int(which)]


# ----------------------------------------------------------------------------------------------
# Taps
# ----------------------------------------------------------------------------------------------

func _on_catalogue_activated(code: int) -> void:
	var info: Dictionary = _info(code)
	var type: int = int(info.get("type", 0))

	var target: TARGET = _target()
	var went_to: DeckModel.LIST
	if target == TARGET.SIDE:
		_deck.add_to(DeckModel.LIST.SIDE, code)
		went_to = DeckModel.LIST.SIDE
	else:
		went_to = _deck.add(code, type)

	_refresh_deck()
	# Show where it landed. Harmless when the list is short enough not to scroll.
	var list: VirtualCardList = _deck_lists[int(went_to)]
	if list != null and list.entry_count() > 0:
		list.scroll_to(list.entry_count() - 1)


func _on_deck_activated(code: int, which: DeckModel.LIST) -> void:
	if _deck.remove_one(which, code):
		_refresh_deck()


func _on_search_changed(_text: String) -> void:
	_refresh_catalogue()


func _on_filter_changed(_index: int) -> void:
	_refresh_catalogue()


func _on_back() -> void:
	chose.emit(BACK_DESTINATION)


func _on_new() -> void:
	_deck = DeckModel.new()
	(get_node(PATH_NAME) as LineEdit).text = DEFAULT_DECK_NAME
	show_message("")
	_refresh_deck()


func _on_save() -> void:
	var wanted: String = (get_node(PATH_NAME) as LineEdit).text
	var safe: String = YdkIo.sanitise_name(wanted)
	var error: Error = YdkIo.save(_deck, safe)
	if error != OK:
		show_message("Could not save '%s' (error %d)." % [safe, error])
		return
	(get_node(PATH_NAME) as LineEdit).text = safe
	show_message("Saved %s to %s." % [safe + YdkIo.EXTENSION, YdkIo.deck_dir()])
	_refresh_saved_list()


func _on_saved_selected(index: int) -> void:
	var saved: OptionButton = get_node(PATH_SAVED) as OptionButton
	# Item 0 is the placeholder, so that selecting it again can reload.
	if index <= 0:
		return
	var picked: String = saved.get_item_text(index)
	var loaded: DeckModel = YdkIo.load_deck(picked)
	if loaded == null:
		show_message("Could not read '%s'." % picked)
		return
	_deck = loaded
	(get_node(PATH_NAME) as LineEdit).text = picked
	show_message("Loaded %s." % picked)
	saved.select(0)
	_refresh_deck()


# ----------------------------------------------------------------------------------------------
# Refresh
# ----------------------------------------------------------------------------------------------

func _refresh_catalogue() -> void:
	if _catalogue_list == null:
		return

	var needle: String = (get_node(PATH_SEARCH) as LineEdit).text.strip_edges().to_lower()
	var kind: KIND = (get_node(PATH_KIND) as OptionButton).selected as KIND

	var shown: Array[Dictionary] = []
	for entry: Dictionary in _catalogue:
		if not needle.is_empty() and not str(entry["search"]).contains(needle):
			continue
		if not _matches_kind(int(entry["type"]), kind):
			continue
		shown.append(entry)

	_catalogue_list.set_entries(shown)
	(get_node(PATH_FOUND) as Label).text = "%d of %d cards" % [shown.size(), _catalogue.size()]


func _refresh_deck() -> void:
	for which: int in [DeckModel.LIST.MAIN, DeckModel.LIST.EXTRA, DeckModel.LIST.SIDE]:
		var list: VirtualCardList = _deck_lists[which]
		if list == null:
			continue

		var rows: Array[Dictionary] = []
		var grouped: Dictionary = _deck.counts_by_code(which as DeckModel.LIST)
		for code: int in grouped:
			var info: Dictionary = _info(code)
			rows.append({
				"code": code,
				"name": str(info.get("name", "Card %d" % code)),
				"note": "x%d" % int(grouped[code]),
			})
		list.set_entries(rows)

		var low: int = int(_limits.get(["main_min", "extra_min", "side_min"][which], 0))
		var high: int = int(_limits.get(["main_max", "extra_max", "side_max"][which], 0))
		(get_node(PATH_HEADER[which]) as Label).text = "%s  %d  (%d-%d)" % [
			LIST_TITLE[which], _deck.size(which as DeckModel.LIST), low, high]

	_last_result = DeckValidator.validate(_deck, _info_callable(), _limits)
	_apply_verdict(_last_result)
	deck_changed.emit(_last_result)


func _apply_verdict(result: Dictionary) -> void:
	var label: Label = get_node(PATH_VERDICT) as Label
	label.text = format_verdict(result)
	label.add_theme_color_override("font_color", COLOR_OK if bool(result["ok"]) else COLOR_BAD)


func _refresh_saved_list() -> void:
	var saved: OptionButton = get_node(PATH_SAVED) as OptionButton
	saved.clear()
	saved.add_item("Open...")
	for name: String in YdkIo.list_decks():
		saved.add_item(name)
	saved.select(0)


func _attach_art() -> void:
	if _catalogue_list != null:
		_catalogue_list.art = _art
	for list: VirtualCardList in _deck_lists:
		if list != null:
			list.art = _art


# ----------------------------------------------------------------------------------------------
# Formatting - the only place a structured issue becomes a sentence
# ----------------------------------------------------------------------------------------------

## One line summarising a `DeckValidator` result. Static so a lobby or a duel-start gate can
## phrase an issue list the same way without instantiating an editor.
static func format_verdict(result: Dictionary) -> String:
	if result.is_empty():
		return ""

	var counts: Dictionary = result.get("counts", {})
	var summary: String = "%d main, %d extra, %d side" % [
		int(counts.get("main", 0)), int(counts.get("extra", 0)), int(counts.get("side", 0))]

	if bool(result.get("ok", false)):
		return "Legal: %s." % summary

	var issues: Array = result.get("issues", [])
	var parts: PackedStringArray = PackedStringArray()
	for i: int in mini(issues.size(), MAX_SPELLED_ISSUES):
		parts.append(describe_issue(issues[i] as Dictionary))
	if issues.size() > MAX_SPELLED_ISSUES:
		parts.append("and %d more" % (issues.size() - MAX_SPELLED_ISSUES))

	return "%s - %s" % [summary, "  ".join(parts)]


## One issue, in words. The validator never produces a string; this is where that ends.
static func describe_issue(issue: Dictionary) -> String:
	var kind: int = int(issue.get("issue", -1))
	var count: int = int(issue.get("count", 0))
	var limit: int = int(issue.get("limit", 0))
	var code: int = int(issue.get("code", 0))
	var card: String = str(issue.get("name", ""))
	if card.is_empty():
		card = "card %d" % code

	match kind:
		DeckValidator.ISSUE.MAIN_TOO_SMALL:
			return "main deck needs %d more" % (limit - count)
		DeckValidator.ISSUE.MAIN_TOO_LARGE:
			return "main deck is %d over" % (count - limit)
		DeckValidator.ISSUE.EXTRA_TOO_SMALL:
			return "extra deck needs %d more" % (limit - count)
		DeckValidator.ISSUE.EXTRA_TOO_LARGE:
			return "extra deck is %d over" % (count - limit)
		DeckValidator.ISSUE.SIDE_TOO_SMALL:
			return "side deck needs %d more" % (limit - count)
		DeckValidator.ISSUE.SIDE_TOO_LARGE:
			return "side deck is %d over" % (count - limit)
		DeckValidator.ISSUE.TOO_MANY_COPIES:
			return "%d copies of %s (max %d)" % [count, card, limit]
		DeckValidator.ISSUE.WRONG_LIST:
			var belongs: int = int(issue.get("belongs", DeckModel.LIST.MAIN))
			return "%s belongs in the %s deck" % [card, DeckModel.LIST_NAMES[belongs]]
		DeckValidator.ISSUE.TOKEN_NOT_ALLOWED:
			return "%s is a Token" % card
		DeckValidator.ISSUE.UNKNOWN_CODE:
			return "passcode %d is not in the card database" % code
	return "unknown problem %d" % kind


## The short type word a catalogue row shows on its right. Deliberately coarse: it is a glance
## aid next to the name, not the card's full type line - `CardPreview` is where that lives.
static func kind_label(type: int) -> String:
	if (type & DuelEnums.TYPE.TOKEN) != 0:
		return "Token"
	if (type & DuelEnums.TYPE.MONSTER) != 0:
		if (type & DuelEnums.TYPE.FUSION) != 0:
			return "Fusion"
		if (type & DuelEnums.TYPE.SYNCHRO) != 0:
			return "Synchro"
		if (type & DuelEnums.TYPE.XYZ) != 0:
			return "Xyz"
		if (type & DuelEnums.TYPE.LINK) != 0:
			return "Link"
		if (type & DuelEnums.TYPE.RITUAL) != 0:
			return "Ritual"
		return "Monster"
	if (type & DuelEnums.TYPE.SPELL) != 0:
		return "Spell"
	if (type & DuelEnums.TYPE.TRAP) != 0:
		return "Trap"
	return ""


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

func _matches_kind(type: int, kind: KIND) -> bool:
	match kind:
		KIND.MONSTER:
			return (type & DuelEnums.TYPE.MONSTER) != 0
		KIND.SPELL:
			return (type & DuelEnums.TYPE.SPELL) != 0
		KIND.TRAP:
			return (type & DuelEnums.TYPE.TRAP) != 0
		KIND.EXTRA:
			return DeckModel.is_extra_deck_type(type)
	return true


func _target() -> TARGET:
	return (get_node(PATH_TARGET) as OptionButton).selected as TARGET


## The catalogue first - it is already in memory - then the fallback lookup for a code loaded
## from a file the catalogue does not cover. `{}` when neither knows the card, which is exactly
## what the validator reports as `UNKNOWN_CODE`.
func _info(code: int) -> Dictionary:
	if _by_code.has(code):
		return _by_code[code]
	if _info_for.is_valid():
		var info: Variant = _info_for.call(code)
		if info is Dictionary:
			return info as Dictionary
	return {}


func _info_callable() -> Callable:
	return Callable(self, "_info")


func _mount_list(slot_path: String, node_name: String) -> VirtualCardList:
	var slot: Node = get_node(slot_path)
	var list: VirtualCardList = VirtualCardList.new()
	list.name = node_name
	list.art = _art
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot.add_child(list)
	return list
