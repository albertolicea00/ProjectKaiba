extends Node

## Host for the deck editor: the one place that is allowed to know both the card database and
## the editor.
##
##   godot --path game res://scenes/deck_editor.tscn                # use it
##   godot --headless --path game res://scenes/deck_editor.tscn     # self-checks, then quits
##
## Layer: **L5**. Like `scenes/duel_touch.gd`, this file is a seam and may see L1, L3 and L4 at
## once because wiring them together is all it does. `game/ui/deck_editor/` may not, and does
## not (V1) - which is why this file exists rather than the editor simply looking cards up for
## itself. The editor has to keep working over a deck that arrived from a LAN host or out of a
## replay, neither of which has a live core behind it.
##
## -------------------------------------------------------------------------------------------
## Where the catalogue comes from, and why it is not the database
## -------------------------------------------------------------------------------------------
## The native core can answer `get_card_info(code)` for any passcode but **cannot enumerate**:
## there is no "list every card" call on it, and `card_db.cpp` keeps its map private. So the set
## of passcodes to offer has to come from somewhere else, and the honest options are both on
## disk:
##
##   `data/base/pics/cards/sd/<code>.jpg`     14 595 files, one per printable card
##   `data/base/script/*/c<code>.lua`         13 541 files, cards that have an effect script
##
## Art is used first because it is the closer match to "cards a player can put in a deck" - a
## vanilla monster has no script but does have a face - and because listing one directory costs
## about 120 ms against 260 ms for three. The script folders are the fallback for a checkout
## with no artwork, where a nameless but usable catalogue beats an empty one.
##
## Measured on this machine: 14 595 filenames in ~120 ms, then 14 243 `get_card_info()` calls
## in ~54 ms. The remaining 352 art files have no row in `cards.cdb` and are dropped. Cheap
## enough to do once on open, which is why there is no progress bar; if the gap between the cdb
## (14 759 rows) and the catalogue (14 243) ever matters, the fix is an enumeration call on the
## core, not a bigger directory scan.

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"

const EDITOR_SCENE: PackedScene = preload("res://ui/deck_editor/deck_editor.tscn")

## Tried in order; the first that yields any passcode wins. Each entry is
## `[directory, suffix, filename prefix to strip]`.
const CATALOGUE_SOURCES: Array = [
	["res://../data/base/pics/cards/sd", ".jpg", ""],
	["res://../data/base/pics/cards/hd", ".jpg", ""],
	["res://../data/base/script/official", ".lua", "c"],
]

## Forwarded so `SceneRouter` can hear the editor's Back button without knowing its type.
signal chose(destination: String)

var _core: Object = null
var _art: CardArt = null
var _editor: DeckEditor = null
var _headless: bool = false
var _failures: PackedStringArray = PackedStringArray()
var _checked: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless" or OS.get_cmdline_args().has("--headless")

	_editor = EDITOR_SCENE.instantiate() as DeckEditor
	add_child(_editor)
	_editor.chose.connect(func(destination: String) -> void: chose.emit(destination))

	_art = CardArt.new()

	var catalogue: Array[Dictionary] = _build_catalogue()
	_editor.bind(catalogue, _info_for, _art)

	# The standard format. A LAN host sends its own `DeckSizes` and the lobby will call
	# `set_limits()` with them; see the header of `core/deck/deck_validator.gd`.
	_editor.set_limits(DeckValidator.default_limits())

	if catalogue.is_empty():
		_editor.show_message(
			"No card pool found. The editor needs data/base/cards.cdb and either "
			+ "data/base/pics/cards/ or data/base/script/. See docs/DATA.md.")


func _exit_tree() -> void:
	if _art != null:
		_art.shutdown()
		_art = null
	_core = null


## The router's way of putting a line of text on whatever is on screen.
func show_message(text: String) -> void:
	if _editor != null:
		_editor.show_message(text)


# ----------------------------------------------------------------------------------------------
# Card data
# ----------------------------------------------------------------------------------------------

func _info_for(code: int) -> Dictionary:
	if _core == null:
		return {}
	return _core.get_card_info(code)


## Every passcode on disk, with the database row behind it, trimmed to what the editor needs.
## The full row is deliberately **not** kept: `get_card_info()` carries sixteen effect strings
## per card, and holding 14 243 of those is a quarter of a million `String`s for data only the
## preview panel ever reads - and it reads it one card at a time, through `_info_for`.
func _build_catalogue() -> Array[Dictionary]:
	var started: int = Time.get_ticks_msec()
	var out: Array[Dictionary] = []

	if not _open_core():
		return out

	var codes: PackedInt32Array = _codes_on_disk()
	if codes.is_empty():
		return out

	var dropped: int = 0
	for code: int in codes:
		var info: Dictionary = _core.get_card_info(code)
		if info.is_empty():
			dropped += 1
			continue
		out.append({
			"code": code,
			"name": str(info.get("name", "")),
			"type": int(info.get("type", 0)),
			"alias": int(info.get("alias", 0)),
		})

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)

	print("[decks] catalogue: %d cards (%d passcodes on disk had no database row) in %d ms" % [
		out.size(), dropped, Time.get_ticks_msec() - started])
	return out


func _open_core() -> bool:
	if not ClassDB.class_exists(CORE_CLASS):
		push_error("%s is not registered. The GDExtension did not load; run: make host" % CORE_CLASS)
		return false

	_core = ClassDB.instantiate(CORE_CLASS)
	var loaded: Dictionary = _core.load_card_database(CDB_PATH)
	if not bool(loaded.get("ok", false)):
		push_warning("[decks] %s could not be loaded: %s" % [CDB_PATH, str(loaded.get("error", ""))])
		_core = null
		return false
	return true


## The first source that yields anything. Not a union: the second scan would cost more than it
## adds (measured: 20 207 filenames across all five folders resolve to 14 261 database rows,
## eighteen more than art alone, for three times the wall clock).
func _codes_on_disk() -> PackedInt32Array:
	for source: Array in CATALOGUE_SOURCES:
		var codes: PackedInt32Array = _codes_in(str(source[0]), str(source[1]), str(source[2]))
		if not codes.is_empty():
			return codes
	return PackedInt32Array()


## `DirAccess` cannot walk `res://../`, so the path is globalised first - the same reason
## `core/registry/card_art.gd` does it. The art tree is outside the Godot project on purpose
## (it is not imported and has no UID), so this is the only route to its filenames.
static func _codes_in(dir: String, suffix: String, strip_prefix: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var handle: DirAccess = DirAccess.open(ProjectSettings.globalize_path(dir))
	if handle == null:
		return out

	handle.list_dir_begin()
	var entry: String = handle.get_next()
	while entry != "":
		if entry.ends_with(suffix):
			var base: String = entry.get_basename()
			if not strip_prefix.is_empty() and base.begins_with(strip_prefix):
				base = base.substr(strip_prefix.length())
			var code: int = base.to_int()
			if code > 0:
				out.append(code)
		entry = handle.get_next()
	handle.list_dir_end()
	return out


# ----------------------------------------------------------------------------------------------
# The headless self-check
# ----------------------------------------------------------------------------------------------
#
# Proves the wiring, not the rules: `core/deck/deck_test.gd` owns the parser, the router and the
# validator. What is checked here is that the editor binds to a real catalogue, that a tap
# reaches the model and the verdict, and that the list really is virtualised.

func _process(_delta: float) -> void:
	if not _headless or _checked:
		return
	_checked = true
	_run_checks()
	get_tree().quit(1 if not _failures.is_empty() else 0)


func _run_checks() -> void:
	print("== deck editor wiring ==")

	var catalogue: VirtualCardList = _editor.catalogue_list()
	_check("the catalogue has cards", catalogue.entry_count() > 100,
		"%d entries" % catalogue.entry_count())

	# The whole point of VirtualCardList: thousands of entries, a screenful of nodes.
	_check("the list is virtualised", catalogue.pooled_rows() <= VirtualCardList.MAX_ROWS,
		"%d rows instantiated for %d entries" % [catalogue.pooled_rows(), catalogue.entry_count()])
	_check("and far fewer nodes than entries", catalogue.pooled_rows() < catalogue.entry_count(),
		"%d rows for %d entries" % [catalogue.pooled_rows(), catalogue.entry_count()])

	# A tap on an extra-deck monster has to land in the extra list. The signal emitted below
	# is the one a row press emits, so everything downstream of it is the real path. The cards
	# are found in the catalogue rather than hardcoded.
	var fusion: int = _first_matching(func(type: int) -> bool:
		return (type & DuelEnums.TYPE.FUSION) != 0)
	var normal: int = _first_matching(func(type: int) -> bool:
		return (type & DuelEnums.TYPE.SPELL) != 0)

	_check("found a Fusion monster in the catalogue", fusion > 0, "none")
	_check("found a Spell in the catalogue", normal > 0, "none")

	if fusion > 0 and normal > 0:
		_editor.catalogue_list().activated.emit(fusion)
		_editor.catalogue_list().activated.emit(normal)
		var deck: DeckModel = _editor.deck()
		_check("the Fusion went to the extra deck", deck.count_in(DeckModel.LIST.EXTRA, fusion) == 1,
			"extra holds %d" % deck.size(DeckModel.LIST.EXTRA))
		_check("the Spell went to the main deck", deck.count_in(DeckModel.LIST.MAIN, normal) == 1,
			"main holds %d" % deck.size(DeckModel.LIST.MAIN))

		# Live verdict: two cards is not a legal deck and the line has to say so.
		var verdict: Dictionary = _editor.verdict()
		_check("the verdict is live", not verdict.is_empty(), "no result")
		_check("and reports an illegal deck", not bool(verdict.get("ok", true)), "it said legal")
		_check("the verdict line is written", not _editor.verdict_text().is_empty(), "empty")

		# Tapping the deck row takes it back out.
		_editor.list_for(DeckModel.LIST.EXTRA).activated.emit(fusion)
		_check("tapping a deck row removes a copy",
			_editor.deck().count_in(DeckModel.LIST.EXTRA, fusion) == 0,
			"extra still holds %d" % _editor.deck().size(DeckModel.LIST.EXTRA))

	if _failures.is_empty():
		print("all checks passed")
		return
	for failure: String in _failures:
		print("FAIL  %s" % failure)


func _first_matching(predicate: Callable) -> int:
	var list: VirtualCardList = _editor.catalogue_list()
	for i: int in list.entry_count():
		var entry: Dictionary = list.entry_at(i)
		if bool(predicate.call(int(entry.get("type", 0)))):
			return int(entry.get("code", 0))
	return 0


func _check(label: String, passed: bool, detail: String) -> void:
	if passed:
		print("PASS  %s" % label)
		return
	_failures.append("%s (%s)" % [label, detail])
