class_name DuelState
extends RefCounted

## The authoritative UI-side model of the board.
##
## Layer: L3 (AGENTS.md section 4). `apply()` is the single entry point: feed it Level-1
## `DuelEvent` dictionaries in order and the board follows. It is deterministic, it touches
## nothing but its own fields, it emits no signals and it never reaches into the scene tree
## (V2, V11). Two state models exist on purpose: this one updates the instant an event is
## applied, while `BoardView` chases it with animation and may lag (ARCHITECTURE.md section 5).
## `BoardView` reads only from here, never from `KaibaCore` (V5).
##
## An unknown or unhandled event type warns once and changes nothing. It never crashes and
## never aborts the duel (V13).
##
## -------------------------------------------------------------------------------------------
## Level-1 payload shapes
## -------------------------------------------------------------------------------------------
## ARCHITECTURE.md section 7 specifies only `MOVE`. The rest are defined here, derived field for
## field from the ocgcore wire layout so that `MsgParser` on the native side has an unambiguous
## target. Cited sources are in `native/vendor/ocgcore/`.
##
## Shared: `loc_info` is `{"con": int, "loc": int, "seq": int, "pos": int}`, matching
## `card::get_info_location` (card.cpp:222) and `kaiba::core_utils::loc_info`.
##
##   START        {t, lp: [int, int], deck: [int, int], extra: [int, int], first: int}
##                Host-generated; ocgcore never emits MSG_START. Field order follows EDOPro's
##                `generic_duel.cpp` writer: playertype, lp0, lp1, deck0, extra0, deck1, extra1.
##   DRAW         {t, player: int, cards: [{"card": int, "pos": int}, ...], count: int}
##                operations.cpp:482. The per-entry key is "card", not "code": that is what
##                `MsgParser::parse_draw` writes. "code" is still accepted so a hand-written
##                event in a test or a tool keeps working.
##   MOVE         {t, card: int, from: loc_info, to: loc_info, reason: int}   field.cpp:280
##                `from.loc == 0` means the card did not exist before (token, new card).
##                Either side may carry `LOCATION.OVERLAY`, in which case `seq` is the host's
##                zone and `pos` is the index among its xyz materials.
##   POS_CHANGE   {t, card: int, at: loc_info, prev_pos: int, pos: int}       operations.cpp:5308
##                The wire form is NOT a packed loc_info - the sequence is a single byte and
##                the two positions follow it (AGENTS.md section 8b.3). `MsgParser` normalises
##                that into "at" before we see it, with "at.pos" holding the new position.
##   SET          {t, card: int, at: loc_info}                                operations.cpp:2742
##   NEW_TURN     {t, player: int}                                            processor.cpp:3334
##   NEW_PHASE    {t, phase: int}                                             processor.cpp:3365
##   DAMAGE       {t, player: int, amount: int}                               operations.cpp:603
##   RECOVER      {t, player: int, amount: int}                               operations.cpp:674
##   LPUPDATE     {t, player: int, lp: int}        absolute, not a delta      libduel.cpp:48
##   UPDATE_DATA  {t, player: int, loc: int, cards: [query, ...]}
##                Host-generated from OCG_DuelQueryLocation. A `query` is a DuelCard field dict
##                (see `DuelCard.apply_query`); `seq` selects the slot, otherwise array order
##                is used. An entry of `{}` or `null` marks an empty slot.
##   UPDATE_CARD  {t, player: int, loc: int, seq: int, data: query}
##                Host-generated from OCG_DuelQuery.
##   SHUFFLE_HAND {t, player: int, codes: [int, ...]}  new order               field.cpp:970
##   SHUFFLE_EXTRA  same shape as SHUFFLE_HAND                                 field.cpp:970
##   SHUFFLE_DECK {t, player: int}                                             field.cpp:990
##   SHUFFLE_SET_CARD {t, loc: int, from: [loc_info, ...], to: [loc_info, ...]} libduel.cpp:1423
##   WIN          {t, player: int, reason: int}   player may be PLAYER.NONE    processor.cpp:4420
##
## Every handler tolerates missing and wrong-typed keys. A malformed event is a bug upstream,
## but it must not take the duel down with it.

## Per-player containers. Index 0 and 1 are the players. GDScript cannot express
## `Array[Array[DuelCard]]`, so the inner arrays are untyped; their elements are `DuelCard`.
## Zone arrays (`main_monster`, `extra_monster`, `spell_trap`) are fixed-size and hold `null`
## for an empty slot. Pile arrays grow and never hold `null`.

## Cards in hand, draw order.
var hand: Array[Array] = []

## 5 main monster zones per player. `null` for empty.
var main_monster: Array[Array] = []

## 2 extra monster zones per player. ocgcore addresses these as MZONE sequences 5 and 6.
## Physically the two zones are shared between players under MR5; we key them by the
## controller ocgcore reports and leave the overlap for the view layer to resolve.
var extra_monster: Array[Array] = []

## 5 spell & trap zones per player. Under MR4/MR5 the pendulum zones are slots 0 and 4 of this
## array (`field::get_pzone_index` returns `seq * 4`), so they need no separate storage.
var spell_trap: Array[Array] = []

## One field spell zone per player. `DuelCard` or `null`. ocgcore addresses it as SZONE
## sequence 5 (`field.cpp:556`).
var field_zone: Array = []

var graveyard: Array[Array] = []
var banished: Array[Array] = []

## Face-down placeholders. The deck is hidden information: the host sends us a count at START,
## never the contents, so these carry `code == 0` until something reveals them. Index 0 is the
## bottom of the deck and the last index is the top, mirroring ocgcore's `list_main`.
var deck: Array[Array] = []

var extra_deck: Array[Array] = []

var life_points: Array[int] = [0, 0]
var turn_player: int = 0
var turn_count: int = 0

## `DuelEnums.PHASE` value. A bit flag, not an ordinal - never compare phases with `<`.
var phase: int = 0

var is_finished: bool = false

## Valid only once `is_finished`. `DuelEnums.PLAYER.NONE` is a draw.
var winner: int = DuelEnums.PLAYER.NONE
var win_reason: int = 0

## Event types that are real and expected but carry no board state: they drive animation or
## input, not the model. Listing them keeps the V13 warning meaningful - a warning should mean
## "nobody taught DuelState about this", not "this one is just not ours".
const PASSIVE_EVENTS: Array[int] = [
	DuelEnums.EV.RETRY,
	DuelEnums.EV.HINT,
	DuelEnums.EV.WAITING,
	DuelEnums.EV.SELECT_BATTLECMD,
	DuelEnums.EV.SELECT_IDLECMD,
	DuelEnums.EV.SELECT_EFFECTYN,
	DuelEnums.EV.SELECT_YESNO,
	DuelEnums.EV.SELECT_OPTION,
	DuelEnums.EV.SELECT_CARD,
	DuelEnums.EV.SELECT_CHAIN,
	DuelEnums.EV.SELECT_PLACE,
	DuelEnums.EV.SELECT_POSITION,
	DuelEnums.EV.SELECT_TRIBUTE,
	DuelEnums.EV.SELECT_COUNTER,
	DuelEnums.EV.SELECT_SUM,
	DuelEnums.EV.SELECT_DISFIELD,
	DuelEnums.EV.SELECT_UNSELECT_CARD,
	DuelEnums.EV.SORT_CARD,
	DuelEnums.EV.SORT_CHAIN,
	DuelEnums.EV.CONFIRM_DECKTOP,
	DuelEnums.EV.CONFIRM_CARDS,
	DuelEnums.EV.CONFIRM_EXTRATOP,
	DuelEnums.EV.SUMMONING,
	DuelEnums.EV.SUMMONED,
	DuelEnums.EV.SPSUMMONING,
	DuelEnums.EV.SPSUMMONED,
	DuelEnums.EV.FLIPSUMMONING,
	DuelEnums.EV.FLIPSUMMONED,
	DuelEnums.EV.CHAINING,
	DuelEnums.EV.CHAINED,
	DuelEnums.EV.CHAIN_SOLVING,
	DuelEnums.EV.CHAIN_SOLVED,
	DuelEnums.EV.CHAIN_END,
	DuelEnums.EV.CHAIN_NEGATED,
	DuelEnums.EV.CHAIN_DISABLED,
	DuelEnums.EV.CARD_SELECTED,
	DuelEnums.EV.RANDOM_SELECTED,
	DuelEnums.EV.BECOME_TARGET,
	DuelEnums.EV.ATTACK,
	DuelEnums.EV.BATTLE,
	DuelEnums.EV.ATTACK_DISABLED,
	DuelEnums.EV.DAMAGE_STEP_START,
	DuelEnums.EV.DAMAGE_STEP_END,
	DuelEnums.EV.MISSED_EFFECT,
	DuelEnums.EV.BE_CHAIN_TARGET,
	DuelEnums.EV.CARD_HINT,
	DuelEnums.EV.PLAYER_HINT,
	DuelEnums.EV.SHOW_HINT,
	DuelEnums.EV.TOSS_COIN,
	DuelEnums.EV.TOSS_DICE,
	DuelEnums.EV.EQUIP,
	DuelEnums.EV.CARD_TARGET,
	DuelEnums.EV.CANCEL_TARGET,
	DuelEnums.EV.SWAP,
	DuelEnums.EV.REMOVE_CARDS,
	DuelEnums.EV.ANNOUNCE_RACE,
	DuelEnums.EV.ANNOUNCE_ATTRIB,
	DuelEnums.EV.ANNOUNCE_CARD,
	DuelEnums.EV.ANNOUNCE_NUMBER,
]

## Event types already warned about, so the warning fires once per type and a repeating
## unhandled opcode does not drown the log.
## Monotonic, never reused within a duel. Reset only by `reset()`.
var _next_handle: int = 0

var _warned_types: Dictionary = {}


func _init() -> void:
	reset()


## Returns the board to its pre-duel state. Also the only place zone sizes are decided.
func reset() -> void:
	_next_handle = 0
	hand = []
	main_monster = []
	extra_monster = []
	spell_trap = []
	graveyard = []
	banished = []
	deck = []
	extra_deck = []
	field_zone = []

	for player: int in range(DuelEnums.PLAYER_COUNT):
		hand.append([])
		graveyard.append([])
		banished.append([])
		deck.append([])
		extra_deck.append([])
		main_monster.append(_empty_slots(DuelEnums.MAIN_MONSTER_ZONES))
		extra_monster.append(_empty_slots(DuelEnums.EXTRA_MONSTER_ZONES))
		spell_trap.append(_empty_slots(DuelEnums.SPELL_TRAP_ZONES))
		field_zone.append(null)

	life_points = [0, 0]
	turn_player = 0
	turn_count = 0
	phase = 0
	is_finished = false
	winner = DuelEnums.PLAYER.NONE
	win_reason = 0
	_warned_types = {}


# ---------------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------------

## Applies one Level-1 `DuelEvent`. The only mutator of this class from the outside.
func apply(event: Dictionary) -> void:
	if not event.has("t"):
		_warn_once(-1, "event has no \"t\" key: %s" % [event])
		return

	var type: int = _as_int(event["t"], -1)

	match type:
		DuelEnums.EV.START:
			_on_start(event)
		DuelEnums.EV.DRAW:
			_on_draw(event)
		DuelEnums.EV.MOVE:
			_on_move(event)
		DuelEnums.EV.POS_CHANGE:
			_on_pos_change(event)
		DuelEnums.EV.SET:
			_on_set(event)
		DuelEnums.EV.NEW_TURN:
			_on_new_turn(event)
		DuelEnums.EV.NEW_PHASE:
			_on_new_phase(event)
		DuelEnums.EV.DAMAGE:
			_on_damage(event)
		DuelEnums.EV.RECOVER:
			_on_recover(event)
		DuelEnums.EV.LPUPDATE:
			_on_lp_update(event)
		DuelEnums.EV.UPDATE_DATA:
			_on_update_data(event)
		DuelEnums.EV.UPDATE_CARD:
			_on_update_card(event)
		DuelEnums.EV.SHUFFLE_HAND:
			_on_shuffle_pile(event, DuelEnums.LOCATION.HAND)
		DuelEnums.EV.SHUFFLE_EXTRA:
			_on_shuffle_pile(event, DuelEnums.LOCATION.EXTRA)
		DuelEnums.EV.SHUFFLE_DECK:
			_on_shuffle_deck(event)
		DuelEnums.EV.SHUFFLE_SET_CARD:
			_on_shuffle_set_card(event)
		DuelEnums.EV.PAY_LPCOST:
			_on_pay_lpcost(event)
		DuelEnums.EV.ADD_COUNTER:
			_on_add_counter(event)
		DuelEnums.EV.REMOVE_COUNTER:
			_on_remove_counter(event)
		DuelEnums.EV.WIN:
			_on_win(event)
		_:
			if not PASSIVE_EVENTS.has(type):
				_warn_once(type, "unhandled event %s" % DuelEnums.ev_name(type))


# ---------------------------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------------------------

func _on_start(event: Dictionary) -> void:
	reset()

	var lp: Array = _as_array(event.get("lp", []))
	for player: int in range(DuelEnums.PLAYER_COUNT):
		life_points[player] = _as_int(lp[player], 8000) if player < lp.size() else 8000

	var deck_counts: Array = _as_array(event.get("deck", []))
	var extra_counts: Array = _as_array(event.get("extra", []))
	for player: int in range(DuelEnums.PLAYER_COUNT):
		var deck_count: int = _as_int(deck_counts[player], 0) if player < deck_counts.size() else 0
		var extra_count: int = _as_int(extra_counts[player], 0) if player < extra_counts.size() else 0
		deck[player] = _hidden_pile(player, DuelEnums.LOCATION.DECK, deck_count)
		extra_deck[player] = _hidden_pile(player, DuelEnums.LOCATION.EXTRA, extra_count)

	turn_player = _player_of(event, "first")
	turn_count = 0
	phase = 0
	is_finished = false
	winner = DuelEnums.PLAYER.NONE
	win_reason = 0


## Moves `cards.size()` cards off the top of the deck into the hand, revealing the codes the
## event carries. Drawing from an empty deck does not deck out here: ocgcore decides that and
## tells us with WIN. We just stop taking placeholders.
func _on_draw(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	var drawn: Array = _as_array(event.get("cards", []))

	for entry: Variant in drawn:
		var data: Dictionary = entry if entry is Dictionary else {}
		var card: DuelCard = null
		if not deck[player].is_empty():
			card = deck[player].pop_back() as DuelCard
		else:
			card = _new_card()
		# "card" is the wire spelling (msg_parser.cpp parse_draw); "code" is the DuelCard field
		# name and is accepted as a fallback.
		card.code = _as_int(data.get("card", data.get("code", card.code)), card.code)
		card.position = _as_int(data.get("pos", DuelEnums.POSITION.FACEDOWN_ATTACK), DuelEnums.POSITION.FACEDOWN_ATTACK)
		card.is_public = (card.position & DuelEnums.POSITION.FACEUP) != 0 or card.code != 0
		_append_to_pile(hand[player], card, player, DuelEnums.LOCATION.HAND)

	_resequence(deck[player])


func _on_move(event: Dictionary) -> void:
	var code: int = _as_int(event.get("card", 0), 0)
	var from_info: Dictionary = _as_loc_info(event.get("from", {}))
	var to_info: Dictionary = _as_loc_info(event.get("to", {}))

	var card: DuelCard = _take_from(from_info)
	if card == null:
		card = _new_card()
	if code != 0:
		card.code = code
	_put_into(card, to_info)


func _on_pos_change(event: Dictionary) -> void:
	var info: Dictionary = _as_loc_info(event.get("at", event))
	var card: DuelCard = _card_at(info)
	if card == null:
		return
	var code: int = _as_int(event.get("card", 0), 0)
	if code != 0:
		card.code = code
	card.position = _as_int(event.get("pos", card.position), card.position)
	card.is_public = (card.position & DuelEnums.POSITION.FACEUP) != 0


## MSG_SET announces that a card was Set. The movement itself arrives as MOVE, so all this does
## is flip the card face-down and drop what we think we know about it: an opponent must not keep
## seeing a code the engine just hid.
func _on_set(event: Dictionary) -> void:
	var info: Dictionary = _as_loc_info(event.get("at", event))
	var card: DuelCard = _card_at(info)
	if card == null:
		return
	var position: int = _as_int(event.get("pos", 0), 0)
	if position != 0:
		card.position = position
	elif not card.is_face_down():
		card.position = DuelEnums.POSITION.FACEDOWN_DEFENSE if card.is_monster_zone() else DuelEnums.POSITION.FACEDOWN_ATTACK
	card.is_public = false


func _on_new_turn(event: Dictionary) -> void:
	turn_player = _player_of(event, "player")
	turn_count += 1


func _on_new_phase(event: Dictionary) -> void:
	phase = _as_int(event.get("phase", phase), phase)


func _on_damage(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	life_points[player] = maxi(0, life_points[player] - _as_int(event.get("amount", 0), 0))


func _on_recover(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	life_points[player] += _as_int(event.get("amount", 0), 0)


## Absolute, not a delta: `Duel.SetLP` writes the new total (libduel.cpp:48). Negative LP is
## clamped at zero by ocgcore before it sends this, but clamp again rather than trust it.
func _on_lp_update(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	life_points[player] = maxi(0, _as_int(event.get("lp", life_points[player]), life_points[player]))


func _on_pay_lpcost(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	life_points[player] = maxi(0, life_points[player] - _as_int(event.get("amount", 0), 0))


func _on_add_counter(event: Dictionary) -> void:
	var at: Dictionary = event.get("at", {}) as Dictionary
	if at.is_empty():
		return
	var card: DuelCard = _card_at(at)
	if card == null:
		return
	var counter_type: int = _as_int(event.get("counter_type", 0), 0)
	var count: int = _as_int(event.get("count", 0), 0)
	card.counters[counter_type] = int(card.counters.get(counter_type, 0)) + count


func _on_remove_counter(event: Dictionary) -> void:
	var at: Dictionary = event.get("at", {}) as Dictionary
	if at.is_empty():
		return
	var card: DuelCard = _card_at(at)
	if card == null:
		return
	var counter_type: int = _as_int(event.get("counter_type", 0), 0)
	var count: int = _as_int(event.get("count", 0), 0)
	var current: int = int(card.counters.get(counter_type, 0))
	var remaining: int = maxi(0, current - count)
	if remaining > 0:
		card.counters[counter_type] = remaining
	else:
		card.counters.erase(counter_type)


## Refreshes a whole location from a query batch. Entries carry their own `seq` where the host
## provides one; otherwise array order is the slot order, which is how OCG_DuelQueryLocation
## lays a field location out.
func _on_update_data(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	var location: int = _as_int(event.get("loc", 0), 0)
	var entries: Array = _as_array(event.get("cards", []))

	for index: int in range(entries.size()):
		var entry: Variant = entries[index]
		if not (entry is Dictionary):
			continue
		var data: Dictionary = entry as Dictionary
		if data.is_empty():
			continue
		var sequence: int = _as_int(data.get("seq", index), index)
		_apply_query(player, location, sequence, data)


func _on_update_card(event: Dictionary) -> void:
	var player: int = _player_of(event, "player")
	var location: int = _as_int(event.get("loc", 0), 0)
	var sequence: int = _as_int(event.get("seq", 0), 0)
	var data: Variant = event.get("data", {})
	if data is Dictionary:
		_apply_query(player, location, sequence, data as Dictionary)


## Reorders a visible pile to the order the engine reports. Hand and extra deck only: the deck
## is face-down placeholders, so its shuffle is unobservable.
func _on_shuffle_pile(event: Dictionary, location: int) -> void:
	var player: int = _player_of(event, "player")
	var codes: Array = _as_array(event.get("codes", []))
	var pile: Array = hand[player] if location == DuelEnums.LOCATION.HAND else extra_deck[player]

	if codes.is_empty():
		return

	# Rebuild rather than permute: the engine's list is the truth, and a count mismatch here
	# means we lost an event somewhere. Adopt the engine's count instead of guessing.
	var rebuilt: Array = []
	for index: int in range(codes.size()):
		var card: DuelCard = pile[index] as DuelCard if index < pile.size() else _new_card()
		card.code = _as_int(codes[index], 0)
		card.is_public = card.code != 0
		rebuilt.append(card)

	if location == DuelEnums.LOCATION.HAND:
		hand[player] = rebuilt
	else:
		extra_deck[player] = rebuilt
	_stamp_pile(rebuilt, player, location)


## No observable state change: the deck holds face-down placeholders. Handled explicitly so it
## does not look unimplemented.
func _on_shuffle_deck(_event: Dictionary) -> void:
	pass


## Permutes face-down cards among their zones. `from[i]` ends up where `to[i]` says.
func _on_shuffle_set_card(event: Dictionary) -> void:
	var sources: Array = _as_array(event.get("from", []))
	var targets: Array = _as_array(event.get("to", []))
	var count: int = mini(sources.size(), targets.size())
	if count == 0:
		return

	var lifted: Array = []
	for index: int in range(count):
		lifted.append(_take_from(_as_loc_info(sources[index])))
	for index: int in range(count):
		var card: DuelCard = lifted[index] as DuelCard
		if card != null:
			_put_into(card, _as_loc_info(targets[index]))


func _on_win(event: Dictionary) -> void:
	is_finished = true
	winner = _as_int(event.get("player", DuelEnums.PLAYER.NONE), DuelEnums.PLAYER.NONE)
	win_reason = _as_int(event.get("reason", 0), 0)


# ---------------------------------------------------------------------------------------------
# Zone access
# ---------------------------------------------------------------------------------------------

## Creates a card already carrying a fresh handle.
##
## Every `DuelCard` in this model must come from here. One built with `DuelCard.new()` directly
## would carry handle 0 and silently lose its identity the first time it moved.
func _new_card() -> DuelCard:
	var card := DuelCard.new()
	_next_handle += 1
	card.handle = _next_handle
	return card


## The card at a location, or `null`. Reads through the `OVERLAY` bit to the host monster.
func card_at(player: int, location: int, sequence: int) -> DuelCard:
	return _card_at({"con": player, "loc": location, "seq": sequence, "pos": 0})


## The pile backing a pile location, or `null` for zone locations. The returned Array is the
## live one - mutate it only through `apply()`.
func pile_for(player: int, location: int) -> Array:
	if player < 0 or player >= DuelEnums.PLAYER_COUNT:
		return []
	match location:
		DuelEnums.LOCATION.HAND:
			return hand[player]
		DuelEnums.LOCATION.DECK:
			return deck[player]
		DuelEnums.LOCATION.GRAVE:
			return graveyard[player]
		DuelEnums.LOCATION.REMOVED:
			return banished[player]
		DuelEnums.LOCATION.EXTRA:
			return extra_deck[player]
		_:
			return []


func _card_at(info: Dictionary) -> DuelCard:
	var player: int = _clamp_player(info.get("con", 0))
	var location: int = _as_int(info.get("loc", 0), 0)
	var sequence: int = _as_int(info.get("seq", 0), 0)

	if (location & DuelEnums.LOCATION.OVERLAY) != 0:
		return _card_at({
			"con": player,
			"loc": location & ~DuelEnums.LOCATION.OVERLAY,
			"seq": sequence,
			"pos": 0,
		})

	match location:
		DuelEnums.LOCATION.MZONE:
			return _monster_slot(player, sequence)
		DuelEnums.LOCATION.SZONE:
			return _spell_slot(player, sequence)
		_:
			var pile: Array = pile_for(player, location)
			if sequence >= 0 and sequence < pile.size():
				return pile[sequence] as DuelCard
			return null


func _monster_slot(player: int, sequence: int) -> DuelCard:
	if sequence >= 0 and sequence < DuelEnums.MAIN_MONSTER_ZONES:
		return main_monster[player][sequence] as DuelCard
	if sequence >= DuelEnums.MAIN_MONSTER_ZONES and sequence < DuelEnums.MZONE_SLOTS:
		return extra_monster[player][sequence - DuelEnums.MAIN_MONSTER_ZONES] as DuelCard
	return null


func _spell_slot(player: int, sequence: int) -> DuelCard:
	if sequence >= 0 and sequence < DuelEnums.SPELL_TRAP_ZONES:
		return spell_trap[player][sequence] as DuelCard
	if sequence == DuelEnums.FIELD_ZONE_SEQUENCE:
		return field_zone[player] as DuelCard
	# Separate pendulum zones (MR3 only). Out of model; see the note on `spell_trap`.
	return null


func _set_zone_slot(player: int, location: int, sequence: int, card: DuelCard) -> void:
	if location == DuelEnums.LOCATION.MZONE:
		if sequence >= 0 and sequence < DuelEnums.MAIN_MONSTER_ZONES:
			main_monster[player][sequence] = card
		elif sequence >= DuelEnums.MAIN_MONSTER_ZONES and sequence < DuelEnums.MZONE_SLOTS:
			extra_monster[player][sequence - DuelEnums.MAIN_MONSTER_ZONES] = card
		else:
			_warn_once(DuelEnums.EV.MOVE, "monster zone sequence %d out of range" % sequence)
	elif location == DuelEnums.LOCATION.SZONE:
		if sequence >= 0 and sequence < DuelEnums.SPELL_TRAP_ZONES:
			spell_trap[player][sequence] = card
		elif sequence == DuelEnums.FIELD_ZONE_SEQUENCE:
			field_zone[player] = card
		else:
			_warn_once(DuelEnums.EV.MOVE, "spell/trap zone sequence %d out of model (MR3 pendulum zone)" % sequence)


# ---------------------------------------------------------------------------------------------
# Movement primitives
# ---------------------------------------------------------------------------------------------

## Detaches the card named by `info` and returns it, or `null` when there was nothing there -
## which is normal: `from.loc == 0` is how a token or a newly created card announces itself.
func _take_from(info: Dictionary) -> DuelCard:
	var location: int = _as_int(info.get("loc", 0), 0)
	if location == 0:
		return null

	var player: int = _clamp_player(info.get("con", 0))
	var sequence: int = _as_int(info.get("seq", 0), 0)

	if (location & DuelEnums.LOCATION.OVERLAY) != 0:
		return _detach_overlay(player, location & ~DuelEnums.LOCATION.OVERLAY, sequence, _as_int(info.get("pos", 0), 0))

	if location == DuelEnums.LOCATION.MZONE or location == DuelEnums.LOCATION.SZONE:
		var card: DuelCard = _card_at(info)
		if card != null:
			_set_zone_slot(player, location, sequence, null)
		return card

	var pile: Array = pile_for(player, location)
	if pile.is_empty():
		return null
	var index: int = sequence if sequence >= 0 and sequence < pile.size() else pile.size() - 1
	var taken: DuelCard = pile[index] as DuelCard
	pile.remove_at(index)
	_resequence(pile)
	return taken


## Attaches `card` at `info`, stamping controller, location, sequence and position.
func _put_into(card: DuelCard, info: Dictionary) -> void:
	var location: int = _as_int(info.get("loc", 0), 0)
	if location == 0:
		# Left the field entirely without a destination. ocgcore does not normally do this;
		# dropping the card is the only sane reading.
		return

	var player: int = _clamp_player(info.get("con", 0))
	var sequence: int = _as_int(info.get("seq", 0), 0)
	var position: int = _as_int(info.get("pos", 0), 0)

	if (location & DuelEnums.LOCATION.OVERLAY) != 0:
		_attach_overlay(card, player, location & ~DuelEnums.LOCATION.OVERLAY, sequence, position)
		return

	card.controller = player
	card.location = location
	if position != 0:
		card.position = position
	card.is_public = (card.position & DuelEnums.POSITION.FACEUP) != 0 and card.code != 0

	if location == DuelEnums.LOCATION.MZONE or location == DuelEnums.LOCATION.SZONE:
		card.sequence = sequence
		_set_zone_slot(player, location, sequence, card)
		return

	var pile: Array = pile_for(player, location)
	if location == DuelEnums.LOCATION.DECK:
		# `field::add_card`: sequence 1 is the bottom of the deck, everything else the top.
		# Index 0 of our array is the bottom, so "top" is an append.
		if sequence == 1:
			pile.insert(0, card)
		else:
			pile.append(card)
	else:
		# Hand, graveyard, banished and extra deck are all push_back in `field::add_card`.
		pile.append(card)
	_resequence(pile)


func _attach_overlay(card: DuelCard, player: int, host_location: int, host_sequence: int, index: int) -> void:
	var host: DuelCard = _card_at({"con": player, "loc": host_location, "seq": host_sequence, "pos": 0})
	if host == null:
		_warn_once(DuelEnums.EV.MOVE, "overlay target missing at p%d %s[%d]" % [player, DuelEnums.location_name(host_location), host_sequence])
		return
	var slot: int = clampi(index, 0, host.overlay_codes.size())
	host.overlay_codes.insert(slot, card.code)


func _detach_overlay(player: int, host_location: int, host_sequence: int, index: int) -> DuelCard:
	var host: DuelCard = _card_at({"con": player, "loc": host_location, "seq": host_sequence, "pos": 0})
	if host == null or host.overlay_codes.is_empty():
		return null
	var slot: int = clampi(index, 0, host.overlay_codes.size() - 1)
	var card := _new_card()
	card.code = host.overlay_codes[slot]
	card.is_public = card.code != 0
	host.overlay_codes.remove_at(slot)
	return card


func _apply_query(player: int, location: int, sequence: int, data: Dictionary) -> void:
	var card: DuelCard = _card_at({"con": player, "loc": location, "seq": sequence, "pos": 0})
	if card == null:
		# The host may describe a slot we have not seen filled yet. Create it rather than drop
		# the information: a missing card is worse than an extra one (V13).
		card = _new_card()
		card.controller = player
		card.location = location
		card.sequence = sequence
		card.apply_query(data)
		_put_into(card, {"con": player, "loc": location, "seq": sequence, "pos": card.position})
		return
	card.apply_query(data)
	card.controller = player
	card.location = location
	card.sequence = sequence


# ---------------------------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------------------------

## Full board as plain data. For tests and for dumping a desync into a bug report; nothing in
## the running game should need it.
func snapshot() -> Dictionary:
	var players: Array = []
	for player: int in range(DuelEnums.PLAYER_COUNT):
		players.append({
			"life_points": life_points[player],
			"hand": _pile_snapshot(hand[player]),
			"main_monster": _slots_snapshot(main_monster[player]),
			"extra_monster": _slots_snapshot(extra_monster[player]),
			"spell_trap": _slots_snapshot(spell_trap[player]),
			"field_zone": (field_zone[player] as DuelCard).to_dict() if field_zone[player] != null else null,
			"graveyard": _pile_snapshot(graveyard[player]),
			"banished": _pile_snapshot(banished[player]),
			"deck_count": deck[player].size(),
			"extra_deck": _pile_snapshot(extra_deck[player]),
		})
	return {
		"turn_player": turn_player,
		"turn_count": turn_count,
		"phase": phase,
		"is_finished": is_finished,
		"winner": winner,
		"win_reason": win_reason,
		"players": players,
	}


## Compact text board dump for the Phase 1 console driver. Fixed-width so consecutive dumps
## line up and a diff of two of them is readable.
func describe() -> String:
	var lines: PackedStringArray = []
	var header: String = "=== turn %d | player %d | %s ===" % [turn_count, turn_player, DuelEnums.phase_name(phase)]
	if is_finished:
		header += "  [FINISHED winner=%s reason=%d]" % [_winner_label(), win_reason]
	lines.append(header)

	for player: int in range(DuelEnums.PLAYER_COUNT):
		var marker: String = "*" if player == turn_player else " "
		lines.append("%sP%d  LP %-5d | hand %-2d | deck %-2d | extra %-2d | GY %-2d | banish %-2d" % [
			marker, player, life_points[player], hand[player].size(), deck[player].size(),
			extra_deck[player].size(), graveyard[player].size(), banished[player].size(),
		])
		lines.append("    MZ %s  EMZ %s" % [_row(main_monster[player]), _row(extra_monster[player])])
		lines.append("    ST %s  FZ %s" % [_row(spell_trap[player]), _slot_text(field_zone[player])])
		lines.append("    hand: %s" % _pile_text(hand[player]))
	return "\n".join(lines)


func _row(slots: Array) -> String:
	var parts: PackedStringArray = []
	for slot: Variant in slots:
		parts.append("[%s]" % _slot_text(slot))
	return "".join(parts)


func _slot_text(slot: Variant) -> String:
	if slot == null:
		return "          .          "
	return "%-21s" % (slot as DuelCard).short_label()


func _pile_text(pile: Array) -> String:
	if pile.is_empty():
		return "-"
	var parts: PackedStringArray = []
	for entry: Variant in pile:
		var card := entry as DuelCard
		parts.append("?" if card.code == 0 else str(card.code))
	return ", ".join(parts)


func _winner_label() -> String:
	if winner == DuelEnums.PLAYER.NONE:
		return "draw"
	return "P%d" % winner


func _pile_snapshot(pile: Array) -> Array:
	var out: Array = []
	for entry: Variant in pile:
		out.append((entry as DuelCard).to_dict())
	return out


func _slots_snapshot(slots: Array) -> Array:
	var out: Array = []
	for slot: Variant in slots:
		out.append((slot as DuelCard).to_dict() if slot != null else null)
	return out


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

func _empty_slots(count: int) -> Array:
	var slots: Array = []
	slots.resize(count)
	return slots


func _hidden_pile(player: int, location: int, count: int) -> Array:
	var pile: Array = []
	for index: int in range(maxi(0, count)):
		var card := _new_card()
		card.controller = player
		card.location = location
		card.sequence = index
		card.position = DuelEnums.POSITION.FACEDOWN_DEFENSE
		card.is_public = false
		pile.append(card)
	return pile


func _append_to_pile(pile: Array, card: DuelCard, player: int, location: int) -> void:
	card.controller = player
	card.location = location
	pile.append(card)
	_resequence(pile)


func _stamp_pile(pile: Array, player: int, location: int) -> void:
	for index: int in range(pile.size()):
		var card := pile[index] as DuelCard
		card.controller = player
		card.location = location
		card.sequence = index


func _resequence(pile: Array) -> void:
	for index: int in range(pile.size()):
		(pile[index] as DuelCard).sequence = index


## Reads a `loc_info` out of a payload. Accepts it nested (`{"from": {...}}`, `{"at": {...}}`)
## or flattened onto the event itself; callers pass `event.get("at", event)` to get both.
func _as_loc_info(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {"con": 0, "loc": 0, "seq": 0, "pos": 0}
	var source: Dictionary = value as Dictionary
	return {
		"con": _as_int(source.get("con", source.get("controller", 0)), 0),
		"loc": _as_int(source.get("loc", source.get("location", 0)), 0),
		"seq": _as_int(source.get("seq", source.get("sequence", 0)), 0),
		"pos": _as_int(source.get("pos", source.get("position", 0)), 0),
	}


func _player_of(event: Dictionary, key: String) -> int:
	return _clamp_player(event.get(key, 0))


func _clamp_player(value: Variant) -> int:
	return clampi(_as_int(value, 0), 0, DuelEnums.PLAYER_COUNT - 1)


func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is bool:
		return 1 if value else 0
	return fallback


func _as_array(value: Variant) -> Array:
	if value is Array:
		return value as Array
	if value is PackedInt64Array:
		return Array(value as PackedInt64Array)
	if value is PackedInt32Array:
		return Array(value as PackedInt32Array)
	return []


## One warning per event type, then silence. V13: unimplemented opcodes log and continue.
func _warn_once(type: int, message: String) -> void:
	if _warned_types.has(type):
		return
	_warned_types[type] = true
	push_warning("[DuelState] %s" % message)
