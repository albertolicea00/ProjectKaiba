class_name DuelCard
extends RefCounted

## One card as the UI-side model knows it. Pure data.
##
## Layer: L3 (AGENTS.md section 4). This class holds **no scene-tree types** — no `Node3D`, no
## `Texture`, no `PackedScene`, no `VisualDefinition`, no zone node, no material. Only the card
## id and where the card is. That is invariants V2 and V11, and it is what makes V12 true:
## adding or removing a 3D model must not touch a line of L1-L3.
##
## The field names mirror `kaiba::core_utils::Query` in `native/src/core_utils.h`, which in turn
## mirrors ocgcore's `QUERY_*` block, so a query Dictionary coming across the GDExtension
## boundary can be applied key-for-key with no translation table. Only `Dictionary` and
## `PackedByteArray` cross that boundary (V14).
##
## A card the local player may not see is still a DuelCard: `code == 0` and `is_public == false`
## mean "something is there, we do not know what". The host strips hidden fields before the
## transport (V7), so the client never has the data to leak in the first place.

## Passcode. `0` means unknown - a face-down card, or any card in a pile we cannot see.
## Stable identity for this physical card, unique within a duel and preserved across every
## move. `0` means "not yet stamped" and must never be treated as a real handle.
##
## Minted by `DuelState`, never by ocgcore: the engine identifies a card only by where it is
## standing right now. The handle is derived from the Level-1 event stream as the duel replays,
## so it never enters the replay format and invariant V9 is untouched.
##
## It exists because `card_id` cannot identify a card: two copies in one hand share it, and a
## face-down card reports `0`.
var handle: int = 0

var code: int = 0

## Controller: 0 or 1. Not the owner. A stolen monster is controlled by the thief.
var controller: int = 0

## `DuelEnums.LOCATION` value. Single location, never a mask, except that an xyz material is
## stored in its host's `overlay_codes` rather than carrying the `OVERLAY` bit here.
var location: int = 0

## Slot index in a zone, or index in a pile.
var sequence: int = 0

## `DuelEnums.POSITION` value.
var position: int = 0

var attack: int = 0
var defense: int = 0
var base_attack: int = 0
var base_defense: int = 0

var level: int = 0
var rank: int = 0
var link: int = 0
var lscale: int = 0
var rscale: int = 0

var attribute: int = 0

## `DuelEnums.RACE` mask. 64-bit since ocgcore v11.
var race: int = 0

## `DuelEnums.TYPE` mask. Always a mask: a Normal Monster is `MONSTER | NORMAL`.
var type: int = 0

## Passcodes of the xyz materials attached to this card, bottom first.
var overlay_codes: PackedInt64Array = PackedInt64Array()

## Counters on this card, `counter_type -> count`.
var counters: Dictionary = {}

## Whether the local player is allowed to know `code`. Set from `QUERY_IS_PUBLIC`.
var is_public: bool = false


## Builds a card from a Level-1 query Dictionary. See `apply_query` for the accepted keys.
static func from_query(data: Dictionary) -> DuelCard:
	var card := DuelCard.new()
	card.apply_query(data)
	return card


## Overwrites only the fields present in `data`. Absent keys keep their current value, which is
## what makes a partial `UPDATE_CARD` safe to apply on top of an existing card.
##
## Unknown keys are ignored rather than rejected: the native query layer may learn new `QUERY_*`
## flags before this file does, and a wider event must never break a duel (V13).
func apply_query(data: Dictionary) -> void:
	code = _int_or(data, "code", code)
	controller = _int_or(data, "controller", _int_or(data, "controler", controller))
	location = _int_or(data, "location", location)
	sequence = _int_or(data, "sequence", _int_or(data, "seq", sequence))
	position = _int_or(data, "position", position)
	attack = _int_or(data, "attack", attack)
	defense = _int_or(data, "defense", defense)
	base_attack = _int_or(data, "base_attack", base_attack)
	base_defense = _int_or(data, "base_defense", base_defense)
	level = _int_or(data, "level", level)
	rank = _int_or(data, "rank", rank)
	link = _int_or(data, "link", link)
	lscale = _int_or(data, "lscale", lscale)
	rscale = _int_or(data, "rscale", rscale)
	attribute = _int_or(data, "attribute", attribute)
	race = _int_or(data, "race", race)
	type = _int_or(data, "type", type)

	# `overlay_cards` is the ocgcore / core_utils.h spelling; `overlay_codes` is ours. Accept
	# both so a rename on either side degrades into a no-op instead of silent data loss.
	if data.has("overlay_codes"):
		overlay_codes = _to_int_array(data["overlay_codes"])
	elif data.has("overlay_cards"):
		overlay_codes = _to_int_array(data["overlay_cards"])

	if data.has("counters") and data["counters"] is Dictionary:
		counters = (data["counters"] as Dictionary).duplicate()

	if data.has("is_public"):
		is_public = bool(data["is_public"])


## True when this card occupies a monster zone, main or extra.
func is_monster_zone() -> bool:
	return location == DuelEnums.LOCATION.MZONE


func is_face_up() -> bool:
	return (position & DuelEnums.POSITION.FACEUP) != 0


func is_face_down() -> bool:
	return (position & DuelEnums.POSITION.FACEDOWN) != 0


func is_defense() -> bool:
	return (position & DuelEnums.POSITION.DEFENSE) != 0


## Deep copy. `snapshot()` and any test that wants a before/after comparison needs this;
## assigning a DuelCard copies the reference, not the card.
func clone() -> DuelCard:
	var copy := DuelCard.new()
	copy.code = code
	copy.controller = controller
	copy.location = location
	copy.sequence = sequence
	copy.position = position
	copy.attack = attack
	copy.defense = defense
	copy.base_attack = base_attack
	copy.base_defense = base_defense
	copy.level = level
	copy.rank = rank
	copy.link = link
	copy.lscale = lscale
	copy.rscale = rscale
	copy.attribute = attribute
	copy.race = race
	copy.type = type
	copy.overlay_codes = overlay_codes.duplicate()
	copy.counters = counters.duplicate()
	copy.is_public = is_public
	return copy


func to_dict() -> Dictionary:
	return {
		"code": code,
		"controller": controller,
		"location": location,
		"sequence": sequence,
		"position": position,
		"attack": attack,
		"defense": defense,
		"base_attack": base_attack,
		"base_defense": base_defense,
		"level": level,
		"rank": rank,
		"link": link,
		"attribute": attribute,
		"race": race,
		"type": type,
		"overlay_codes": Array(overlay_codes),
		"counters": counters.duplicate(),
		"is_public": is_public,
	}


## One-line form for the console board dump. Deliberately short: `describe()` prints five of
## these per row.
func short_label() -> String:
	var name_part: String = "?" if code == 0 else str(code)
	var parts: PackedStringArray = [name_part]
	if (type & DuelEnums.TYPE.MONSTER) != 0 or attack != 0 or defense != 0:
		parts.append("%d/%d" % [attack, defense])
	parts.append(_position_tag())
	if overlay_codes.size() > 0:
		parts.append("xyz%d" % overlay_codes.size())
	if not counters.is_empty():
		parts.append("ctr%d" % _counter_total())
	return " ".join(parts)


func _position_tag() -> String:
	match position:
		DuelEnums.POSITION.FACEUP_ATTACK:
			return "UA"
		DuelEnums.POSITION.FACEDOWN_ATTACK:
			return "DA"
		DuelEnums.POSITION.FACEUP_DEFENSE:
			return "UD"
		DuelEnums.POSITION.FACEDOWN_DEFENSE:
			return "DD"
		_:
			return "--"


func _counter_total() -> int:
	var total: int = 0
	for key: Variant in counters:
		total += int(counters[key])
	return total


func _int_or(data: Dictionary, key: String, fallback: int) -> int:
	if not data.has(key):
		return fallback
	var value: Variant = data[key]
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is bool:
		return 1 if value else 0
	return fallback


func _to_int_array(value: Variant) -> PackedInt64Array:
	var out := PackedInt64Array()
	if value is PackedInt64Array:
		return (value as PackedInt64Array).duplicate()
	if value is PackedInt32Array:
		for item: int in (value as PackedInt32Array):
			out.append(item)
		return out
	if value is Array:
		for item: Variant in (value as Array):
			if item is int or item is float:
				out.append(int(item))
		return out
	return out
