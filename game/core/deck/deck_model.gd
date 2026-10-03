class_name DeckModel
extends RefCounted

## A deck as three ordered lists of card codes. Nothing else.
##
## Layer: **L3** (AGENTS.md section 4, "deck"). V2 applies in its strictest form here: no
## `Node`, no `Texture`, no `PackedScene`, no scene tree. This class cannot even look a card up -
## it has no database and no core - so every method that needs to know what a card *is* takes
## the card's `type` bitmask as an argument and the caller supplies it. That is deliberate: it
## is what lets the same model be filled from a `.ydk` file, from a network packet or from a
## test fixture without any of them dragging a card database behind them.
##
## -------------------------------------------------------------------------------------------
## Order is part of the data
## -------------------------------------------------------------------------------------------
## The lists are ordered, duplicates included, and `append()` preserves the order it is given.
## A `.ydk` round trip has to come back byte-identical (`ydk_io.gd`), and the opening hand of a
## duel is drawn off the top of the main deck before it is shuffled, so "a multiset of codes"
## is not a sufficient representation. `PackedInt32Array` rather than `Array[int]` because a
## deck list is exactly what `KaibaCore.start_duel()` wants and the conversion is then free.
##
## -------------------------------------------------------------------------------------------
## Routing, and the one term that looks redundant
## -------------------------------------------------------------------------------------------
## `is_extra_deck_type()` is EDOPro's rule, transcribed from `gframe/deck_manager.cpp`:
##
##     (type & (TYPE_FUSION | TYPE_SYNCHRO | TYPE_XYZ)) || (type & TYPE_LINK && type & TYPE_MONSTER)
##
## The `TYPE_MONSTER` term on the Link branch is **not** redundant and must not be "simplified"
## away: `TYPE_LINK` (0x4000000) is also set on Link Spells in the Rush/Speed card pool, and
## those belong in the main deck. Fusion, Synchro and Xyz carry no such ambiguity, which is why
## only the Link branch is qualified.
##
## **Ritual monsters go in the main deck.** In EDOPro this is a per-host setting
## (`RITUAL_LOCATION` in `deck_manager.cpp`: DEFAULT / MAIN / EXTRA, where DEFAULT means "extra
## only for Rush cards"). Under modern OCG/TCG rules a Ritual monster is a main-deck card, which
## is the DEFAULT branch for every non-Rush card, so that is what this file implements. If Rush
## or a host-configurable ritual location ever arrives, this is the single function to change.

## The three lists. The integer values are indices into `LIST_NAMES` and are used as array
## indices internally, so they must stay 0, 1, 2 and contiguous.
enum LIST {
	MAIN = 0,
	EXTRA = 1,
	SIDE = 2,
}

## Lower case, matching the `.ydk` section markers and the keys `DeckValidator` reports counts
## under. Indexed by `LIST`.
const LIST_NAMES: Array[String] = ["main", "extra", "side"]

## Index 0 is main, 1 extra, 2 side. Kept as one array so every list operation is the same two
## lines instead of a three-way branch that can disagree with itself.
var _lists: Array[PackedInt32Array] = [
	PackedInt32Array(),
	PackedInt32Array(),
	PackedInt32Array(),
]


# ----------------------------------------------------------------------------------------------
# Classification
# ----------------------------------------------------------------------------------------------

## EDOPro's extra-deck test, verbatim. `type` is the `TYPE_*` bitmask as
## `KaibaCore.get_card_info()` reports it.
static func is_extra_deck_type(type: int) -> bool:
	if (type & (DuelEnums.TYPE.FUSION | DuelEnums.TYPE.SYNCHRO | DuelEnums.TYPE.XYZ)) != 0:
		return true
	# Both terms required. See the header: a Link *Spell* is a main-deck card.
	return (type & DuelEnums.TYPE.LINK) != 0 and (type & DuelEnums.TYPE.MONSTER) != 0


## Where `add()` would put a card of this type. Never answers SIDE: nothing is ever sided
## automatically, the player chooses that.
static func list_for_type(type: int) -> LIST:
	return LIST.EXTRA if is_extra_deck_type(type) else LIST.MAIN


## True for a card that may not be in any deck at all. Tokens are produced by effects; a `.ydk`
## naming one is a corrupt file, not a legal deck. `DeckValidator` reports it, this only names it.
static func is_token_type(type: int) -> bool:
	return (type & DuelEnums.TYPE.TOKEN) != 0


## True when `type` is a Ritual **monster**. `TYPE_RITUAL` alone is also set on Ritual Spells,
## which are ordinary main-deck spells, so the monster bit has to be checked as well - the same
## shape of trap as the Link branch above.
static func is_ritual_monster_type(type: int) -> bool:
	return (type & DuelEnums.TYPE.RITUAL) != 0 and (type & DuelEnums.TYPE.MONSTER) != 0


# ----------------------------------------------------------------------------------------------
# Reading
# ----------------------------------------------------------------------------------------------

## The list, in order, as a copy. Callers mutate through this class, never through the array.
func cards(which: LIST) -> PackedInt32Array:
	return _lists[int(which)].duplicate()


func size(which: LIST) -> int:
	return _lists[int(which)].size()


## Main + extra + side.
func total() -> int:
	return _lists[0].size() + _lists[1].size() + _lists[2].size()


func is_empty() -> bool:
	return total() == 0


## Copies of `code` in one list.
func count_in(which: LIST, code: int) -> int:
	var found: int = 0
	for entry: int in _lists[int(which)]:
		if entry == code:
			found += 1
	return found


## Copies of `code` across all three lists. This is the number the 3-copy rule is measured
## against - EDOPro counts main, extra and side together, so a fourth copy cannot be parked in
## the side deck.
func count(code: int) -> int:
	return count_in(LIST.MAIN, code) + count_in(LIST.EXTRA, code) + count_in(LIST.SIDE, code)


func contains(code: int) -> bool:
	return count(code) > 0


## `code -> copies`, in first-appearance order, for one list. The editor draws one row per
## distinct card with a copy count rather than three identical rows.
func counts_by_code(which: LIST) -> Dictionary:
	var out: Dictionary = {}
	for entry: int in _lists[int(which)]:
		out[entry] = int(out.get(entry, 0)) + 1
	return out


## Every code in the deck, main then extra then side, in order. The shape `start_duel()` and the
## art pre-loader want.
func all_codes() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.append_array(_lists[0])
	out.append_array(_lists[1])
	out.append_array(_lists[2])
	return out


# ----------------------------------------------------------------------------------------------
# Writing
# ----------------------------------------------------------------------------------------------

## Puts `code` at the end of `which` with no questions asked. This is the parser's door: a
## `.ydk` file says which section a code was written under and that is authoritative, even when
## it disagrees with the card's type. A file with a Fusion in `#main` has to survive the round
## trip and then be *reported* by `DeckValidator`, not silently corrected - a loader that
## shuffles cards between sections to make them legal destroys the evidence of the bug.
func append(which: LIST, code: int) -> void:
	_lists[int(which)].append(code)


## Routes by type and returns the list it chose. The editor's "add this card" door.
func add(code: int, type: int) -> LIST:
	var which: LIST = list_for_type(type)
	append(which, code)
	return which


## Explicit placement, for the side deck. A side deck legally holds main-deck and extra-deck
## cards alike, so there is nothing to route.
func add_to(which: LIST, code: int) -> void:
	append(which, code)


## Removes the **last** copy of `code` from `which`. Last rather than first so that repeatedly
## adding and removing one card leaves the rest of the list where it was. Returns false when
## there was no copy to remove.
func remove_one(which: LIST, code: int) -> bool:
	var list: PackedInt32Array = _lists[int(which)]
	for i: int in range(list.size() - 1, -1, -1):
		if list[i] == code:
			list.remove_at(i)
			_lists[int(which)] = list
			return true
	return false


## Removes one entry by position. Returns false for an index outside the list.
func remove_at(which: LIST, index: int) -> bool:
	var list: PackedInt32Array = _lists[int(which)]
	if index < 0 or index >= list.size():
		return false
	list.remove_at(index)
	_lists[int(which)] = list
	return true


## Removes every copy of `code` from every list. Returns how many went.
func remove_all(code: int) -> int:
	var removed: int = 0
	for which: int in [LIST.MAIN, LIST.EXTRA, LIST.SIDE]:
		while remove_one(which as LIST, code):
			removed += 1
	return removed


func clear() -> void:
	_lists = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]


## Replaces one whole list, in order. Used by the editor's undo of a bulk operation and by the
## tests; the parser uses `append()`.
func set_cards(which: LIST, codes: PackedInt32Array) -> void:
	_lists[int(which)] = codes.duplicate()


## A deep copy. `duplicate()` is taken by `RefCounted`'s own API shape in other engines and
## `Object.duplicate()` does not exist here, so the name is spelled out.
func copy() -> DeckModel:
	var other: DeckModel = DeckModel.new()
	for which: int in [LIST.MAIN, LIST.EXTRA, LIST.SIDE]:
		other.set_cards(which as LIST, _lists[which])
	return other


## Content equality, order included. `==` on two `DeckModel`s is identity, which is never what a
## round-trip test means.
func equals(other: DeckModel) -> bool:
	if other == null:
		return false
	for which: int in [LIST.MAIN, LIST.EXTRA, LIST.SIDE]:
		if _lists[which] != other.cards(which as LIST):
			return false
	return true


func _to_string() -> String:
	return "DeckModel(main %d, extra %d, side %d)" % [
		_lists[0].size(), _lists[1].size(), _lists[2].size()]
