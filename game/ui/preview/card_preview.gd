class_name CardPreview
extends CanvasLayer

## One card, shown large: its face, its name, its stats and its effect text.
##
## Layer: L5 shell (AGENTS.md section 4).
##
## -------------------------------------------------------------------------------------------
## V1 - this file has never heard of the core
## -------------------------------------------------------------------------------------------
## **Nothing under `game/ui/`, `game/view/` or `game/platform/` may name `KaibaCore`.** This
## widget is handed a `Dictionary` and a `Texture2D` and renders them. It does not look a card
## up, it does not know where card data comes from, and it cannot be given a passcode and asked
## to find out - `show_card()` takes no code, on purpose.
##
## Whoever owns the core does the lookup:
##
##     var info: Dictionary = core.get_card_info(code)       # L5 duel scene, not here
##     preview.show_card(info, art.texture_for(code))
##
## The shortcut - a `core` reference on this node, or an autoload singleton it could reach -
## would work today and would make this widget unusable the first time a card is previewed from
## a replay, from a deck list, or across the network, none of which have a live core to ask.
##
## -------------------------------------------------------------------------------------------
## Why nothing here measures the screen - ARCHITECTURE.md section 10, rule 4
## -------------------------------------------------------------------------------------------
## No widget may ask the viewport or the window how large it is in order to decide anything.
## The panel is positioned with fractional anchors and laid out with containers; the card face
## keeps its 59:86 shape through an `AspectRatioContainer` rather than through any arithmetic on
## a resolution. In Phase 7 this `CanvasLayer` is re-instantiated inside a `SubViewport` painted
## on a quad floating over the table, whose pixel size is an arbitrary texture resolution with
## no aspect ratio worth branching on. Anything sized from a screen measurement would be wrong
## there and would have to be rewritten - which is the rewrite rule 4 exists to prevent.
##
## `ui/ui_test.gd` greps this directory for those measurements. If the preview ever looks wrong
## at some resolution, the fix is an anchor, a size flag or a container. Never a measurement.
##
## -------------------------------------------------------------------------------------------
## What `get_card_info()` carries, and what is done with it
## -------------------------------------------------------------------------------------------
## Shown:   name, type, attribute, race, level/rank/link rating, attack, defense, link markers,
##          pendulum scales, desc.
## Not shown, deliberately:
##   `strings`   sixteen per-effect labels. They name the *choices* a card offers while an
##               effect is being selected ("Draw 2 cards", "Destroy 1 card"); printed as a block
##               under a card's text they read as duplicated effect text. They belong on the
##               selection prompt, not here.
##   `setcodes`  numeric archetype ids. Resolved to names via `setcode_names` key when the
##               caller enriches the info dict from a setname string table.
##   `alias`     the passcode this card is an alternate artwork of. A player cares about the
##               card, not which printing it is.
##   `ot`        OCG / TCG availability. A format badge, and there is no format selector yet.
##   `category`  the deck editor's effect-category bitmask. A search filter, not card text.
##
## Every field is read with `get()` and a default. A `get_card_info()` result is **not** always
## complete: `KaibaCore` fills the numeric half from `OCG_CardData` and the text half from the
## cdb's text table, and returns whichever of the two it found. A row with text but no data, or
## the reverse, is a real state and must render rather than crash.

## Shown in place of a name when the dictionary carries nothing usable. An empty panel would
## read as a bug; this reads as "that card is not in the database", which is the truth.
const UNKNOWN_NAME: String = "Unknown card"
const UNKNOWN_DESC: String = "No card data for this code."

## Stand-in for a field there is no data to fill in. Same convention as `ui/hud/duel_hud.gd`.
const EMPTY: String = "-"

## Separator between the parts of a one-line field. U+00B7, which every Latin font has.
const PART_SEPARATOR: String = " · "

## Node paths, as constants so a test can address the same labels this file writes to and the
## two cannot drift apart.
const PATH_ROOT: String = "Root"
const PATH_FACE: String = "Root/Frame/Panel/Body/Art/Face"
const PATH_NO_ART: String = "Root/Frame/Panel/Body/Art/NoArt"
const PATH_NAME: String = "Root/Frame/Panel/Body/Text/CardName"
const PATH_TYPE: String = "Root/Frame/Panel/Body/Text/TypeLine"
const PATH_TRAITS: String = "Root/Frame/Panel/Body/Text/TraitLine"
const PATH_STATS: String = "Root/Frame/Panel/Body/Text/StatLine"
const PATH_MARKERS: String = "Root/Frame/Panel/Body/Text/MarkerLine"
const PATH_SCALES: String = "Root/Frame/Panel/Body/Text/ScaleLine"
const PATH_DESC: String = "Root/Frame/Panel/Body/Text/DescScroll/Desc"

# ----------------------------------------------------------------------------------------------
# Vocabulary
#
# Every value below was read out of `core/duel/duel_enums.gd`, which is itself a verbatim copy of
# `native/vendor/ocgcore/ocgapi_constants.h`. Nothing here is a remembered number.
# ----------------------------------------------------------------------------------------------

## Monster subtypes, in the order a type line reads them: how it is summoned first, then what it
## additionally is, then Normal / Effect last - which is how the printed card does it.
const MONSTER_SUBTYPES: Array = [
	[DuelEnums.TYPE.RITUAL, "Ritual"],
	[DuelEnums.TYPE.FUSION, "Fusion"],
	[DuelEnums.TYPE.SYNCHRO, "Synchro"],
	[DuelEnums.TYPE.XYZ, "Xyz"],
	[DuelEnums.TYPE.LINK, "Link"],
	[DuelEnums.TYPE.PENDULUM, "Pendulum"],
	[DuelEnums.TYPE.TOON, "Toon"],
	[DuelEnums.TYPE.SPIRIT, "Spirit"],
	[DuelEnums.TYPE.UNION, "Union"],
	[DuelEnums.TYPE.GEMINI, "Gemini"],
	[DuelEnums.TYPE.TUNER, "Tuner"],
	[DuelEnums.TYPE.FLIP, "Flip"],
	[DuelEnums.TYPE.MAXIMUM, "Maximum"],
	[DuelEnums.TYPE.SPSUMMON, "Special Summon"],
	[DuelEnums.TYPE.TOKEN, "Token"],
	[DuelEnums.TYPE.NORMAL, "Normal"],
	[DuelEnums.TYPE.EFFECT, "Effect"],
]

## Spell and trap subtypes. A spell or trap with none of these set is a Normal one: the cdb
## stores it as bare `TYPE_SPELL` / `TYPE_TRAP` with no second bit, so "Normal" has to be
## inferred from the absence rather than read from a flag.
const SPELL_TRAP_SUBTYPES: Array = [
	[DuelEnums.TYPE.QUICKPLAY, "Quick-Play"],
	[DuelEnums.TYPE.CONTINUOUS, "Continuous"],
	[DuelEnums.TYPE.EQUIP, "Equip"],
	[DuelEnums.TYPE.FIELD, "Field"],
	[DuelEnums.TYPE.COUNTER, "Counter"],
	[DuelEnums.TYPE.RITUAL, "Ritual"],
	[DuelEnums.TYPE.TRAPMONSTER, "Trap Monster"],
]

## `ATTRIBUTE_*`. Upper case because that is how the printed card prints them.
const ATTRIBUTE_WORDS: Dictionary = {
	DuelEnums.ATTRIBUTE.EARTH: "EARTH",
	DuelEnums.ATTRIBUTE.WATER: "WATER",
	DuelEnums.ATTRIBUTE.FIRE: "FIRE",
	DuelEnums.ATTRIBUTE.WIND: "WIND",
	DuelEnums.ATTRIBUTE.LIGHT: "LIGHT",
	DuelEnums.ATTRIBUTE.DARK: "DARK",
	DuelEnums.ATTRIBUTE.DIVINE: "DIVINE",
}

## `RACE_*`. The enum names are run together (`BEASTWARRIOR`); these are the words actually
## printed on a card, which is why this is a table and not a `capitalize()` call.
const RACE_WORDS: Dictionary = {
	DuelEnums.RACE.WARRIOR: "Warrior",
	DuelEnums.RACE.SPELLCASTER: "Spellcaster",
	DuelEnums.RACE.FAIRY: "Fairy",
	DuelEnums.RACE.FIEND: "Fiend",
	DuelEnums.RACE.ZOMBIE: "Zombie",
	DuelEnums.RACE.MACHINE: "Machine",
	DuelEnums.RACE.AQUA: "Aqua",
	DuelEnums.RACE.PYRO: "Pyro",
	DuelEnums.RACE.ROCK: "Rock",
	DuelEnums.RACE.WINGEDBEAST: "Winged Beast",
	DuelEnums.RACE.PLANT: "Plant",
	DuelEnums.RACE.INSECT: "Insect",
	DuelEnums.RACE.THUNDER: "Thunder",
	DuelEnums.RACE.DRAGON: "Dragon",
	DuelEnums.RACE.BEAST: "Beast",
	DuelEnums.RACE.BEASTWARRIOR: "Beast-Warrior",
	DuelEnums.RACE.DINOSAUR: "Dinosaur",
	DuelEnums.RACE.FISH: "Fish",
	DuelEnums.RACE.SEASERPENT: "Sea Serpent",
	DuelEnums.RACE.REPTILE: "Reptile",
	DuelEnums.RACE.PSYCHIC: "Psychic",
	DuelEnums.RACE.DIVINE: "Divine-Beast",
	DuelEnums.RACE.CREATORGOD: "Creator God",
	DuelEnums.RACE.WYRM: "Wyrm",
	DuelEnums.RACE.CYBERSE: "Cyberse",
	DuelEnums.RACE.ILLUSION: "Illusion",
	DuelEnums.RACE.CYBORG: "Cyborg",
	DuelEnums.RACE.MAGICALKNIGHT: "Magical Knight",
	DuelEnums.RACE.HIGHDRAGON: "High Dragon",
	DuelEnums.RACE.OMEGAPSYCHIC: "Omega Psychic",
	DuelEnums.RACE.CELESTIALWARRIOR: "Celestial Warrior",
	DuelEnums.RACE.GALAXY: "Galaxy",
	DuelEnums.RACE.YOKAI: "Yokai",
}

## `LINK_MARKER_*` from `native/vendor/ocgcore/ocgapi_constants.h`, lines 197-204.
##
## **They are written as octal literals in the header** (`0001`, `0010`, `0040`, `0400`), which
## is the one thing about them that bites: `0010` is 8, not 10, and `0400` is 256, not 400. The
## decimal values below are the octal ones converted. The grid also skips `0020` (16) - that is
## the centre of the 3x3, where the monster itself sits, and no card has it.
##
## These belong in `core/duel/duel_enums.gd` with the rest of the mirrored header, and should be
## moved there the next time that file is open. They are here only because this change does not
## own it.
const LINK_MARKERS: Array = [
	[64, "Top-Left"],      # LINK_MARKER_TOP_LEFT     0100
	[128, "Top"],          # LINK_MARKER_TOP          0200
	[256, "Top-Right"],    # LINK_MARKER_TOP_RIGHT    0400
	[8, "Left"],           # LINK_MARKER_LEFT         0010
	[32, "Right"],         # LINK_MARKER_RIGHT        0040
	[1, "Bottom-Left"],    # LINK_MARKER_BOTTOM_LEFT  0001
	[2, "Bottom"],         # LINK_MARKER_BOTTOM       0002
	[4, "Bottom-Right"],   # LINK_MARKER_BOTTOM_RIGHT 0004
]

## Raised when the preview is dismissed by a tap on itself, so the owner can forget it is open
## without polling `is_showing()`.
signal dismissed

var _root: Control = null
var _face: TextureRect = null
var _no_art: Label = null
var _name: Label = null
var _type: Label = null
var _traits: Label = null
var _stats: Label = null
var _markers: Label = null
var _scales: Label = null
var _desc: Label = null

## The code currently on display, or 0. Diagnostics only - nothing branches on it.
var _code: int = 0


func _ready() -> void:
	_resolve()
	hide_card()


# ----------------------------------------------------------------------------------------------
# The three calls that drive it
# ----------------------------------------------------------------------------------------------

## Shows `info` - a `get_card_info()`-shaped `Dictionary` - with `face` as its artwork.
##
## `face` may be `null`: the card has no art on disk, or `CardArt` has not decoded it yet, or the
## card is face-down and the viewer was never told what it is. The panel says so rather than
## showing an empty rectangle.
##
## An empty `info` is a supported argument, not a caller error. `get_card_info()` answers `{}`
## for a code the database does not have - a token, a card from a newer set, a passcode that
## reached us over the network - and the preview has to say that out loud.
func show_card(info: Dictionary, face: Texture2D) -> void:
	_resolve()
	if _root == null:
		return

	_code = int(info.get("code", 0))
	var known: bool = not info.is_empty()

	_name.text = _name_of(info)
	var type_text: String = type_line(int(info.get("type", 0))) if info.has("type") else EMPTY
	var setcode_names: PackedStringArray = info.get("setcode_names", PackedStringArray()) as PackedStringArray
	if not setcode_names.is_empty():
		type_text += "\n" + " / ".join(setcode_names)
	_type.text = type_text
	# A dictionary with no text row at all is as text-less as an empty one, so both land on
	# the same sentence rather than on an empty paragraph.
	var desc: String = str(info.get("desc", "")).strip_edges()
	_desc.text = desc if not desc.is_empty() else UNKNOWN_DESC

	var type: int = int(info.get("type", 0))
	var is_monster: bool = info.has("type") and (type & DuelEnums.TYPE.MONSTER) != 0

	_set_line(_traits, _trait_line(info) if is_monster else "")
	_set_line(_stats, _stat_line(info) if is_monster else "")
	_set_line(_markers,
		_marker_line(int(info.get("link_marker", 0)))
		if is_monster and (type & DuelEnums.TYPE.LINK) != 0 else "")
	_set_line(_scales,
		"Pendulum Scale %d / %d" % [int(info.get("lscale", 0)), int(info.get("rscale", 0))]
		if is_monster and (type & DuelEnums.TYPE.PENDULUM) != 0 else "")

	_face.texture = face
	_face.visible = face != null
	_no_art.visible = face == null

	_root.visible = true


func hide_card() -> void:
	_resolve()
	if _root == null:
		return
	_code = 0
	_root.visible = false
	# Dropped so a hidden preview is not the last thing keeping an evicted face alive.
	_face.texture = null


func is_showing() -> bool:
	return _root != null and _root.visible


## The passcode on display, or 0. For logs and tests; nothing in this file branches on it.
func shown_code() -> int:
	return _code


# ----------------------------------------------------------------------------------------------
# Decoding. Static so a test can check the words without building a panel.
# ----------------------------------------------------------------------------------------------

## `"Monster / Synchro / Tuner / Effect"`, `"Spell / Quick-Play"`, `"Trap / Normal"`.
##
## The base word is decided by `TYPE_MONSTER` first. A card carrying both the monster bit and a
## spell or trap bit is a monster as far as a player is concerned - it is the thing standing in
## a monster zone - and that is what a preview is about. The cdb stores an ordinary trap monster
## as `TYPE_TRAP | TYPE_TRAPMONSTER` with no monster bit, so this branch is not the one that
## handles them; `SPELL_TRAP_SUBTYPES` is.
static func type_line(type: int) -> String:
	if type == 0:
		return EMPTY

	var parts: PackedStringArray = PackedStringArray()
	if (type & DuelEnums.TYPE.MONSTER) != 0:
		parts.append("Monster")
		for entry: Array in MONSTER_SUBTYPES:
			if (type & int(entry[0])) != 0:
				parts.append(str(entry[1]))
	elif (type & DuelEnums.TYPE.SPELL) != 0 or (type & DuelEnums.TYPE.TRAP) != 0:
		parts.append("Spell" if (type & DuelEnums.TYPE.SPELL) != 0 else "Trap")
		var before: int = parts.size()
		for entry: Array in SPELL_TRAP_SUBTYPES:
			if (type & int(entry[0])) != 0:
				parts.append(str(entry[1]))
		if parts.size() == before:
			parts.append("Normal")
	else:
		return EMPTY

	return " / ".join(parts)


## `"DARK"`. Joined with `/` in the impossible-but-cheap case of more than one bit, and `""` for
## a card that has no attribute - which is every spell and every trap.
static func attribute_name(attribute: int) -> String:
	return _words_for(ATTRIBUTE_WORDS, attribute)


## `"Winged Beast"`. 64-bit: `RACE_YOKAI` lives above bit 32 and GDScript's `int` is signed
## 64-bit, so the mask survives the boundary intact (V14).
static func race_name(race: int) -> String:
	return _words_for(RACE_WORDS, race)


## The arrows a Link monster points with, in reading order. Empty for a mask of zero, which no
## real Link monster has but a malformed row might.
static func link_marker_names(mask: int) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry: Array in LINK_MARKERS:
		if (mask & int(entry[0])) != 0:
			out.append(str(entry[1]))
	return out


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## A card with data but no text row still deserves a title. `get_card_info()` fills the two
## halves independently, so this is a reachable state rather than a defensive flourish.
func _name_of(info: Dictionary) -> String:
	var name: String = str(info.get("name", "")).strip_edges()
	if not name.is_empty():
		return name
	if _code != 0:
		return "Card %d" % _code
	return UNKNOWN_NAME


func _trait_line(info: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var attribute: String = attribute_name(int(info.get("attribute", 0)))
	var race: String = race_name(int(info.get("race", 0)))
	if not attribute.is_empty():
		parts.append(attribute)
	if not race.is_empty():
		parts.append(race)
	return PART_SEPARATOR.join(parts)


## `"Level 8 · ATK 3000 · DEF 2500"`.
##
## Three things this must not get wrong:
##
##   - **A Link monster has no defence.** The cdb's `def` column carries its link marker bitmask
##     instead, and `KaibaCore` already moves that into `link_marker` and zeroes `defense`. A
##     "DEF 0" printed here would therefore be a *plausible* lie rather than an obvious one,
##     which is worse. It has no level either: the `level` column holds its link rating.
##   - **An Xyz monster has a Rank, not a Level.** Same column, different word on the card.
##   - **`?` is a value.** ocgcore encodes an unknown ATK or DEF as a negative number, and an
##     unknown Level the same way (`card_db.cpp` negates the low byte, so a "?" level arrives as
##     something like -252, not -4). Printing those integers would be nonsense.
func _stat_line(info: Dictionary) -> String:
	var type: int = int(info.get("type", 0))
	var is_link: bool = (type & DuelEnums.TYPE.LINK) != 0
	var level: int = int(info.get("level", 0))

	var parts: PackedStringArray = PackedStringArray()
	if is_link:
		parts.append("LINK-%s" % _number_or_unknown(level))
	elif (type & DuelEnums.TYPE.XYZ) != 0:
		parts.append("Rank %s" % _number_or_unknown(level))
	else:
		parts.append("Level %s" % _number_or_unknown(level))

	parts.append("ATK %s" % _number_or_unknown(int(info.get("attack", 0))))
	if not is_link:
		parts.append("DEF %s" % _number_or_unknown(int(info.get("defense", 0))))
	return PART_SEPARATOR.join(parts)


func _marker_line(mask: int) -> String:
	var names: PackedStringArray = link_marker_names(mask)
	if names.is_empty():
		return "Markers: none"
	return "Markers: %s" % ", ".join(names)


## A negative stat is ocgcore's "?", not a number. See `_stat_line()`.
static func _number_or_unknown(value: int) -> String:
	return "?" if value < 0 else str(value)


static func _words_for(table: Dictionary, mask: int) -> String:
	if mask == 0:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for bit: Variant in table:
		if (mask & int(bit)) != 0:
			parts.append(str(table[bit]))
	if parts.is_empty():
		return ""
	return " / ".join(parts)


## A line with nothing to say is hidden rather than blanked, so the panel closes up instead of
## leaving a gap where a spell card's ATK would have been.
func _set_line(label: Label, text: String) -> void:
	if label == null:
		return
	label.text = text
	label.visible = not text.is_empty()


## Resolves the node references without `@onready`, so `show_card()` is legal before the node
## has been added to a tree. Idempotent and costs one null check once resolved.
func _resolve() -> void:
	if _root != null:
		return
	_root = get_node_or_null(PATH_ROOT) as Control
	if _root == null:
		return
	_face = get_node_or_null(PATH_FACE) as TextureRect
	_no_art = get_node_or_null(PATH_NO_ART) as Label
	_name = get_node_or_null(PATH_NAME) as Label
	_type = get_node_or_null(PATH_TYPE) as Label
	_traits = get_node_or_null(PATH_TRAITS) as Label
	_stats = get_node_or_null(PATH_STATS) as Label
	_markers = get_node_or_null(PATH_MARKERS) as Label
	_scales = get_node_or_null(PATH_SCALES) as Label
	_desc = get_node_or_null(PATH_DESC) as Label

	if not _root.gui_input.is_connected(_on_root_input):
		_root.gui_input.connect(_on_root_input)


## A tap anywhere on the preview closes it. The whole panel is the dismiss target because the
## alternative - a close button - is a small target on a phone and has no obvious equivalent in
## VR, where this becomes a quad you look at.
func _on_root_input(event: InputEvent) -> void:
	if not is_showing():
		return
	var pressed: bool = (
		(event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if not pressed:
		return
	_root.accept_event()
	hide_card()
	dismissed.emit()
