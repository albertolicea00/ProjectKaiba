class_name EventTranslator
extends RefCounted

## Level 1 -> Level 2. Turns one `DuelEvent` into zero or more `VisualIntent` dictionaries.
##
## Layer: L3 (AGENTS.md section 4). Pure function of its argument: no state, no signals, no
## scene tree (V2). Nothing here may name `Node3D`, `Texture`, `PackedScene`, `Resource` or
## `VisualDefinition`; if adding a 3D model required editing this file, V12 would already be
## broken.
##
## **V9: nothing this file produces is ever written to a replay.** Level 2 is lossy, enriched
## and disposable by design - it exists so animation can change without invalidating the replay
## library. A replay stores the Level-1 events that came in, never the intents that came out.
##
## -------------------------------------------------------------------------------------------
## The intent shape
## -------------------------------------------------------------------------------------------
## Every intent carries at least:
##
##   "kind"      String, one of the KIND_* constants below. The only field L4 must switch on.
##   "duration"  float, seconds the animation is budgeted. A hint, not a contract.
##   "blocking"  bool, whether the next intent waits for this one to finish.
##   "ev"        int, the `DuelEnums.EV` value this intent came from. Diagnostics only.
##
## and then, where they make sense:
##
##   "card_id"      int passcode. `0` means face-down / not revealed to this viewer, which is
##                  not an error: L4 shows a card back. **This is the only card identity L3
##                  hands out** (V11) - the view resolves art and models from it (V12).
##   "from_anchor"  String, see the anchor grammar below.
##   "to_anchor"    String.
##   "anchor"       String, for intents that touch a single place.
##   "face"         String, one of UP_ATK / DOWN_ATK / UP_DEF / DOWN_DEF / UNKNOWN.
##   "from_face"    String, the face before the event.
##   "player"       int, 0 or 1.
##
## The `"visual"` key from the ARCHITECTURE.md section 7 example is **deliberately absent**.
## A `VisualDefinition` is a Resource owned by L4; resolving one here would put an asset
## reference inside L3 and break V2, V11 and V12 at once. L4 resolves it from `card_id`.
##
## Player ids are the ABSOLUTE ones ocgcore emitted, never rotated so that "the viewer is
## player 0" (same rule as `native/src/duel_event.h`). Flipping the board to the local
## player's perspective is a presentation concern and belongs to L4/L5.
##
## -------------------------------------------------------------------------------------------
## Anchor grammar
## -------------------------------------------------------------------------------------------
## An anchor names a place on the board as a stable String. L4 maps anchors to transforms; it
## is the only coupling between the two layers, and it is one-way.
##
##   DECK_P0  HAND_P0  GY_P0  BANISH_P0  EXTRA_P0   piles, no slot index
##   MZ_P0_2        main monster zone, ocgcore MZONE sequence 0..4
##   EMZ_P0_0       extra monster zone, ocgcore MZONE sequence 5..6
##   ST_P0_3        spell & trap zone, ocgcore SZONE sequence 0..4
##   FZ_P0          field spell zone, ocgcore SZONE sequence 5
##   PZ_P0_0        separate pendulum zone, SZONE sequence 6..7. MR3 only; under MR4/MR5
##                  pendulum cards sit in ST_Pn_0 and ST_Pn_4 and this never appears.
##   OVL_MZ_P0_2_1  xyz material: host zone, then the index in its stack
##   PLAYER_P1      the player themselves - direct attacks, life point readouts
##   NOWHERE        `loc == 0`: the card did not exist before, or has left the model
##
## -------------------------------------------------------------------------------------------
## Coverage
## -------------------------------------------------------------------------------------------
## MOVE, SET, SUMMONING / SUMMONED / SPSUMMONING / SPSUMMONED / FLIPSUMMONING / FLIPSUMMONED,
## DRAW, ATTACK, ATTACK_DISABLED, BATTLE, POS_CHANGE, DAMAGE, RECOVER, LPUPDATE, NEW_TURN,
## NEW_PHASE. Everything else returns an empty array - silently. An event with no visual
## consequence is not an error, so there is no warning here; V13's warning is `DuelState`'s
## job, and warning twice for one event would only double the noise.
##
## Field names are taken from the parse functions in `native/src/msg_parser.cpp`, which is the
## authority. Nothing is guessed.

# ----------------------------------------------------------------------------------------------
# Intent kinds
# ----------------------------------------------------------------------------------------------

## Fallback for a MOVE whose reason and destination say nothing in particular.
const KIND_MOVE: String = "MOVE"

const KIND_SUMMON: String = "SUMMON"
const KIND_SPECIAL_SUMMON: String = "SPECIAL_SUMMON"
const KIND_SET: String = "SET"
const KIND_TRIBUTE: String = "TRIBUTE"
const KIND_DISCARD: String = "DISCARD"
const KIND_DESTROY: String = "DESTROY"
const KIND_MATERIAL: String = "MATERIAL"
const KIND_ATTACH: String = "ATTACH"
const KIND_DETACH: String = "DETACH"
const KIND_CREATE: String = "CREATE"
const KIND_REMOVE: String = "REMOVE"
const KIND_TO_GRAVE: String = "TO_GRAVE"
const KIND_BANISH: String = "BANISH"
const KIND_TO_HAND: String = "TO_HAND"
const KIND_TO_DECK: String = "TO_DECK"
const KIND_TO_EXTRA: String = "TO_EXTRA"
const KIND_PLACE_MONSTER: String = "PLACE_MONSTER"
const KIND_PLACE_SPELL: String = "PLACE_SPELL"

## The engine is about to summon. The card is not on the field yet; the MOVE that puts it there
## follows. This is the beat where a 3D model gets its entrance.
const KIND_SUMMON_ANNOUNCE: String = "SUMMON_ANNOUNCE"

## The summon resolved. Payload-free in ocgcore (AGENTS.md section 8b.4), so this intent carries
## no card: it closes whatever KIND_SUMMON_ANNOUNCE opened.
const KIND_SUMMON_COMPLETE: String = "SUMMON_COMPLETE"

const KIND_DRAW: String = "DRAW"
const KIND_POS_CHANGE: String = "POS_CHANGE"

## Face-down to face-up. Worth its own kind: it is the one position change with a reveal.
const KIND_FLIP: String = "FLIP"

const KIND_ATTACK: String = "ATTACK"
const KIND_ATTACK_CANCEL: String = "ATTACK_CANCEL"
const KIND_BATTLE: String = "BATTLE"
const KIND_LP_CHANGE: String = "LP_CHANGE"
const KIND_TURN_START: String = "TURN_START"
const KIND_PHASE_CHANGE: String = "PHASE_CHANGE"

## An equip card attaching to a monster. `MsgParser` has decoded `MSG_EQUIP` since batch 2 and
## the sound set carries `equip.wav`, but nothing emitted a kind for it, so the event reached L3
## and stopped there.
const KIND_EQUIP: String = "EQUIP"

## A coin toss or a die roll. Both are player-visible outcomes a card asked for, and both have
## their own sound; neither had a kind.
const KIND_COIN_TOSS: String = "COIN_TOSS"
const KIND_DICE_ROLL: String = "DICE_ROLL"

## `KIND_SUMMON_ANNOUNCE` subkinds, so L4 can pick a different entrance per summon type.
const SUMMON_NORMAL: String = "NORMAL"
const SUMMON_SPECIAL: String = "SPECIAL"
const SUMMON_FLIP: String = "FLIP"

## `KIND_LP_CHANGE` modes. DAMAGE and RECOVER carry a delta; LPUPDATE is an absolute total
## (`Duel.SetLP`, libduel.cpp) and carries `"value"` with no delta, because this class is
## stateless and cannot know the previous total. The authoritative number is in `DuelState`.
const LP_DAMAGE: String = "DAMAGE"
const LP_RECOVER: String = "RECOVER"
const LP_SET: String = "SET"

const FACE_UP_ATTACK: String = "UP_ATK"
const FACE_DOWN_ATTACK: String = "DOWN_ATK"
const FACE_UP_DEFENSE: String = "UP_DEF"
const FACE_DOWN_DEFENSE: String = "DOWN_DEF"

## No position byte was sent, or the engine sent a mask rather than a single position. Not an
## error: most pile destinations have no meaningful face.
const FACE_UNKNOWN: String = "UNKNOWN"

const ANCHOR_NOWHERE: String = "NOWHERE"

# ----------------------------------------------------------------------------------------------
# Animation budget
# ----------------------------------------------------------------------------------------------

## Seconds and blocking per kind. Tuning numbers, nothing more: they never reach `DuelState`,
## they are never serialised and changing one cannot desynchronise a duel. `blocking` means
## "the next intent waits for this one"; a false here is what lets several cards fly at once.
const PROFILES: Dictionary = {
	KIND_MOVE: {"duration": 0.45, "blocking": false},
	KIND_SUMMON: {"duration": 1.4, "blocking": true},
	KIND_SPECIAL_SUMMON: {"duration": 1.4, "blocking": true},
	KIND_SET: {"duration": 0.6, "blocking": true},
	KIND_TRIBUTE: {"duration": 0.7, "blocking": true},
	KIND_DISCARD: {"duration": 0.5, "blocking": false},
	KIND_DESTROY: {"duration": 0.9, "blocking": true},
	KIND_MATERIAL: {"duration": 0.5, "blocking": false},
	KIND_ATTACH: {"duration": 0.5, "blocking": false},
	KIND_DETACH: {"duration": 0.5, "blocking": false},
	KIND_CREATE: {"duration": 0.6, "blocking": true},
	KIND_REMOVE: {"duration": 0.3, "blocking": false},
	KIND_TO_GRAVE: {"duration": 0.5, "blocking": false},
	KIND_BANISH: {"duration": 0.6, "blocking": false},
	KIND_TO_HAND: {"duration": 0.5, "blocking": false},
	KIND_TO_DECK: {"duration": 0.4, "blocking": false},
	KIND_TO_EXTRA: {"duration": 0.4, "blocking": false},
	KIND_PLACE_MONSTER: {"duration": 0.6, "blocking": true},
	KIND_PLACE_SPELL: {"duration": 0.5, "blocking": true},
	KIND_SUMMON_ANNOUNCE: {"duration": 0.8, "blocking": true},
	KIND_SUMMON_COMPLETE: {"duration": 0.0, "blocking": false},
	KIND_DRAW: {"duration": 0.45, "blocking": false},
	KIND_POS_CHANGE: {"duration": 0.4, "blocking": true},
	KIND_FLIP: {"duration": 0.6, "blocking": true},
	KIND_ATTACK: {"duration": 0.9, "blocking": true},
	KIND_ATTACK_CANCEL: {"duration": 0.3, "blocking": true},
	KIND_BATTLE: {"duration": 1.2, "blocking": true},
	KIND_LP_CHANGE: {"duration": 0.7, "blocking": false},
	KIND_TURN_START: {"duration": 1.0, "blocking": true},
	KIND_PHASE_CHANGE: {"duration": 0.35, "blocking": false},
	KIND_EQUIP: {"duration": 0.3, "blocking": false},
	KIND_COIN_TOSS: {"duration": 0.6, "blocking": true},
	KIND_DICE_ROLL: {"duration": 0.6, "blocking": true},
}

const DEFAULT_PROFILE: Dictionary = {"duration": 0.4, "blocking": false}

# ----------------------------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------------------------

## Translates one Level-1 `DuelEvent` into 0..N Level-2 `VisualIntent` dictionaries, in the
## order they should play. An event with no visual consequence returns an empty array.
## Turns one Level-1 event into zero or more Level-2 intents.
##
## `state` is optional and must be the model **after** `apply()` has run on this same event
## (docs/ARCHITECTURE.md section 5 step 4). When supplied, every intent that names a card also
## carries `"handle"`, the stable identity of the physical card involved, so L4 can follow one
## card across moves instead of guessing from `card_id` — which it cannot do for two copies in
## a hand, nor for a face-down card, where `card_id` is 0.
##
## Without `state` the intents are exactly as before, so a caller that only wants shapes (the
## test suite) needs no model.
func translate(event: Dictionary, state: DuelState = null) -> Array[Dictionary]:
	var intents: Array[Dictionary] = []
	if not event.has("t"):
		return intents

	var type: int = _as_int(event["t"], -1)

	match type:
		DuelEnums.EV.MOVE:
			_translate_move(event, intents)
		DuelEnums.EV.SET:
			_translate_set(event, intents)
		DuelEnums.EV.SUMMONING:
			_translate_summoning(event, intents, SUMMON_NORMAL)
		DuelEnums.EV.SPSUMMONING:
			_translate_summoning(event, intents, SUMMON_SPECIAL)
		DuelEnums.EV.FLIPSUMMONING:
			_translate_summoning(event, intents, SUMMON_FLIP)
		DuelEnums.EV.SUMMONED:
			_translate_summoned(intents, SUMMON_NORMAL)
		DuelEnums.EV.SPSUMMONED:
			_translate_summoned(intents, SUMMON_SPECIAL)
		DuelEnums.EV.FLIPSUMMONED:
			_translate_summoned(intents, SUMMON_FLIP)
		DuelEnums.EV.DRAW:
			_translate_draw(event, intents)
		DuelEnums.EV.POS_CHANGE:
			_translate_pos_change(event, intents)
		DuelEnums.EV.ATTACK:
			_translate_attack(event, intents)
		DuelEnums.EV.ATTACK_DISABLED:
			intents.append(_base(KIND_ATTACK_CANCEL))
		DuelEnums.EV.BATTLE:
			_translate_battle(event, intents)
		DuelEnums.EV.DAMAGE:
			_translate_lp_delta(event, intents, LP_DAMAGE, -1)
		DuelEnums.EV.RECOVER:
			_translate_lp_delta(event, intents, LP_RECOVER, 1)
		DuelEnums.EV.LPUPDATE:
			_translate_lp_set(event, intents)
		DuelEnums.EV.NEW_TURN:
			_translate_new_turn(event, intents)
		DuelEnums.EV.NEW_PHASE:
			_translate_new_phase(event, intents)
		DuelEnums.EV.EQUIP:
			_translate_equip(event, intents)
		DuelEnums.EV.TOSS_COIN:
			_translate_toss(event, intents, KIND_COIN_TOSS)
		DuelEnums.EV.TOSS_DICE:
			_translate_toss(event, intents, KIND_DICE_ROLL)
		_:
			return intents

	# Stamp the provenance once, here, rather than in every handler.
	for intent: Dictionary in intents:
		intent["ev"] = type

	if state != null:
		_stamp_handles(event, intents, state, type)

	return intents


## Attaches the stable card handle to every intent that names a card.
##
## Resolution is positional: the model has already been updated, so the card this event is about
## is the one now standing at the event's destination. `handle` is omitted rather than set to 0
## when nothing resolves — 0 must never read as a real identity.
func _stamp_handles(event: Dictionary, intents: Array[Dictionary], state: DuelState, type: int) -> void:
	if type == DuelEnums.EV.DRAW:
		_stamp_draw_handles(event, intents, state)
		return

	# Destination first: after apply() the card is at "to" for a move, "at" for an in-place
	# change. "from" is the fallback for ATTACK and BATTLE, where the attacker is the subject.
	var info: Dictionary = {}
	for key: String in ["to", "at", "from"]:
		var candidate: Variant = event.get(key)
		if candidate is Dictionary and not (candidate as Dictionary).is_empty():
			info = candidate
			break
	if info.is_empty():
		return

	var card: DuelCard = state.card_at(
		_as_int(info.get("con", 0), 0),
		_as_int(info.get("loc", 0), 0),
		_as_int(info.get("seq", 0), 0))
	if card == null or card.handle == 0:
		return

	for intent: Dictionary in intents:
		if intent.has("card_id"):
			intent["handle"] = card.handle


## A draw moves several cards at once and produces one intent per card, in order.
##
## The drawn cards are the last `count` entries of the hand, because `DuelState` appends them in
## the order the engine listed them. Zipping the two is exact; there is nothing to guess here.
func _stamp_draw_handles(event: Dictionary, intents: Array[Dictionary], state: DuelState) -> void:
	var drawn: int = _as_int(event.get("count", 0), 0)
	if drawn <= 0:
		return
	var hand: Array = state.pile_for(_as_int(event.get("player", 0), 0), DuelEnums.LOCATION.HAND)
	if hand.size() < drawn:
		return

	var first: int = hand.size() - drawn
	var index: int = 0
	for intent: Dictionary in intents:
		if not intent.has("card_id"):
			continue
		if index >= drawn:
			break
		var card: DuelCard = hand[first + index] as DuelCard
		if card != null and card.handle != 0:
			intent["handle"] = card.handle
		index += 1


# ----------------------------------------------------------------------------------------------
# Handlers
# ----------------------------------------------------------------------------------------------

## `{t, card, from: loc_info, to: loc_info, reason}` - msg_parser.cpp `parse_move`.
func _translate_move(event: Dictionary, out: Array[Dictionary]) -> void:
	var from_info: Dictionary = _loc(event.get("from", {}))
	var to_info: Dictionary = _loc(event.get("to", {}))
	var reason: int = _as_int(event.get("reason", 0), 0)

	var intent: Dictionary = _base(move_kind(from_info, to_info, reason))
	intent["card_id"] = _as_int(event.get("card", 0), 0)
	intent["from_anchor"] = anchor_of(from_info)
	intent["to_anchor"] = anchor_of(to_info)
	intent["from_face"] = face_of(_as_int(from_info["pos"], 0))
	intent["face"] = face_of(_as_int(to_info["pos"], 0))
	# The destination owns the card afterwards; a MOVE out of nowhere has only an origin.
	intent["player"] = _as_int(to_info["con"], 0) if _as_int(to_info["loc"], 0) != 0 else _as_int(from_info["con"], 0)
	intent["reason"] = reason
	out.append(intent)


## `{t, card, at: loc_info}` - msg_parser.cpp `parse_card_at`. The travel to the zone arrives
## separately as MOVE; this is the "it is face-down now" beat.
func _translate_set(event: Dictionary, out: Array[Dictionary]) -> void:
	var at_info: Dictionary = _loc(event.get("at", {}))
	var intent: Dictionary = _base(KIND_SET)
	intent["card_id"] = _as_int(event.get("card", 0), 0)
	intent["anchor"] = anchor_of(at_info)
	intent["face"] = face_of(_as_int(at_info["pos"], 0))
	intent["player"] = _as_int(at_info["con"], 0)
	out.append(intent)


## `{t, card, at: loc_info}` for all three announcing opcodes. `card == 0` on SPSUMMONING means
## the summoning card is not revealed to this viewer.
func _translate_summoning(event: Dictionary, out: Array[Dictionary], subkind: String) -> void:
	var at_info: Dictionary = _loc(event.get("at", {}))
	var intent: Dictionary = _base(KIND_SUMMON_ANNOUNCE)
	intent["summon_kind"] = subkind
	intent["card_id"] = _as_int(event.get("card", 0), 0)
	intent["anchor"] = anchor_of(at_info)
	intent["face"] = face_of(_as_int(at_info["pos"], 0))
	intent["player"] = _as_int(at_info["con"], 0)
	out.append(intent)


## Payload-free sequencing marker (AGENTS.md section 8b.4). There is nothing to carry but the
## fact that the summon finished.
func _translate_summoned(out: Array[Dictionary], subkind: String) -> void:
	var intent: Dictionary = _base(KIND_SUMMON_COMPLETE)
	intent["summon_kind"] = subkind
	out.append(intent)


## `{t, player, cards: [{card, pos}, ...], count}` - msg_parser.cpp `parse_draw`.
##
## One intent per card so the director can stagger them. Only the last blocks, which makes the
## whole draw play as a single beat without serialising five card flights end to end.
func _translate_draw(event: Dictionary, out: Array[Dictionary]) -> void:
	var player: int = _as_int(event.get("player", 0), 0)
	var drawn: Array = _as_array(event.get("cards", []))

	for index: int in range(drawn.size()):
		var entry: Dictionary = drawn[index] if drawn[index] is Dictionary else {}
		var intent: Dictionary = _base(KIND_DRAW)
		intent["card_id"] = _as_int(entry.get("card", entry.get("code", 0)), 0)
		intent["from_anchor"] = "DECK_P%d" % player
		intent["to_anchor"] = "HAND_P%d" % player
		intent["face"] = face_of(_as_int(entry.get("pos", 0), 0))
		intent["player"] = player
		intent["index"] = index
		intent["count"] = drawn.size()
		intent["blocking"] = index == drawn.size() - 1
		out.append(intent)


## `{t, card, at: loc_info, prev_pos, pos}` - msg_parser.cpp `parse_pos_change`. Note that `at`
## is NOT a packed loc_info on the wire (AGENTS.md section 8b.3); the parser has already
## normalised it into one, with `pos` holding the new position.
func _translate_pos_change(event: Dictionary, out: Array[Dictionary]) -> void:
	var at_info: Dictionary = _loc(event.get("at", {}))
	var previous: int = _as_int(event.get("prev_pos", 0), 0)
	var current: int = _as_int(event.get("pos", _as_int(at_info["pos"], 0)), 0)

	var was_down: bool = (previous & DuelEnums.POSITION.FACEDOWN) != 0
	var is_up: bool = (current & DuelEnums.POSITION.FACEUP) != 0

	var intent: Dictionary = _base(KIND_FLIP if was_down and is_up else KIND_POS_CHANGE)
	intent["card_id"] = _as_int(event.get("card", 0), 0)
	intent["anchor"] = anchor_of(at_info)
	intent["from_face"] = face_of(previous)
	intent["face"] = face_of(current)
	intent["player"] = _as_int(at_info["con"], 0)
	out.append(intent)


## `{t, from: loc_info, direct: bool, to?: loc_info}` - msg_parser.cpp `parse_attack`. A zeroed
## target loc_info means a direct attack, so `to` is absent rather than pointing at zone 0
## (AGENTS.md section 8b.6).
##
## ASSUMPTION, flagged: on a direct attack the defender is taken to be the other player,
## `1 - attacker`. That holds for every 1v1 duel, which is the whole MVP scope; a tag duel
## would need the real target and ocgcore does not put it in this message.
func _translate_attack(event: Dictionary, out: Array[Dictionary]) -> void:
	var from_info: Dictionary = _loc(event.get("from", {}))
	var attacker: int = _as_int(from_info["con"], 0)
	var is_direct: bool = bool(event.get("direct", not event.has("to")))

	var intent: Dictionary = _base(KIND_ATTACK)
	intent["from_anchor"] = anchor_of(from_info)
	intent["direct"] = is_direct
	intent["player"] = attacker
	if is_direct:
		intent["to_anchor"] = "PLAYER_P%d" % (1 - attacker)
	else:
		intent["to_anchor"] = anchor_of(_loc(event.get("to", {})))
	out.append(intent)


## `{t, from, from_atk, from_def, from_destroyed, direct, to?, to_atk?, to_def?, to_destroyed?}`
## - msg_parser.cpp `parse_battle`. The defender block is absent entirely on a direct attack.
func _translate_battle(event: Dictionary, out: Array[Dictionary]) -> void:
	var from_info: Dictionary = _loc(event.get("from", {}))
	var attacker: int = _as_int(from_info["con"], 0)
	var is_direct: bool = bool(event.get("direct", not event.has("to")))

	var intent: Dictionary = _base(KIND_BATTLE)
	intent["from_anchor"] = anchor_of(from_info)
	intent["from_attack"] = _as_int(event.get("from_atk", 0), 0)
	intent["from_defense"] = _as_int(event.get("from_def", 0), 0)
	intent["from_destroyed"] = bool(event.get("from_destroyed", false))
	intent["direct"] = is_direct
	intent["player"] = attacker

	if is_direct:
		intent["to_anchor"] = "PLAYER_P%d" % (1 - attacker)
	else:
		intent["to_anchor"] = anchor_of(_loc(event.get("to", {})))
		intent["to_attack"] = _as_int(event.get("to_atk", 0), 0)
		intent["to_defense"] = _as_int(event.get("to_def", 0), 0)
		intent["to_destroyed"] = bool(event.get("to_destroyed", false))
	out.append(intent)


## DAMAGE and RECOVER: `{t, player, amount}`. `sign` is -1 or +1.
func _translate_lp_delta(event: Dictionary, out: Array[Dictionary], mode: String, sign: int) -> void:
	var player: int = _as_int(event.get("player", 0), 0)
	var amount: int = _as_int(event.get("amount", 0), 0)

	var intent: Dictionary = _base(KIND_LP_CHANGE)
	intent["mode"] = mode
	intent["player"] = player
	intent["anchor"] = "PLAYER_P%d" % player
	intent["amount"] = amount
	intent["delta"] = sign * amount
	out.append(intent)


## LPUPDATE: `{t, player, lp}`. Absolute total, no delta - see the LP_SET note above.
func _translate_lp_set(event: Dictionary, out: Array[Dictionary]) -> void:
	var player: int = _as_int(event.get("player", 0), 0)

	var intent: Dictionary = _base(KIND_LP_CHANGE)
	intent["mode"] = LP_SET
	intent["player"] = player
	intent["anchor"] = "PLAYER_P%d" % player
	intent["value"] = _as_int(event.get("lp", 0), 0)
	out.append(intent)


## `{t, player}`. The turn counter lives in `DuelState`; this is only the banner cue.
func _translate_new_turn(event: Dictionary, out: Array[Dictionary]) -> void:
	var player: int = _as_int(event.get("player", 0), 0)
	var intent: Dictionary = _base(KIND_TURN_START)
	intent["player"] = player
	intent["anchor"] = "PLAYER_P%d" % player
	out.append(intent)


## `{t, phase}`. `phase` is a `DuelEnums.PHASE` bit flag, never an ordinal.
func _translate_new_phase(event: Dictionary, out: Array[Dictionary]) -> void:
	var phase: int = _as_int(event.get("phase", 0), 0)
	var intent: Dictionary = _base(KIND_PHASE_CHANGE)
	intent["phase"] = phase
	intent["phase_name"] = DuelEnums.phase_name(phase)
	out.append(intent)


# ----------------------------------------------------------------------------------------------
# Classification
# ----------------------------------------------------------------------------------------------

## Which kind of move this is. Precedence matters and is not arbitrary:
##
##  1. structural cases first - a card that did not exist, or that left the model entirely;
##  2. then the overlay bit, because an xyz attach is a move into another card, not a zone;
##  3. then `reason`, most specific first. A tribute summon's material arrives as
##     `RELEASE | SUMMON` (see `DuelEnums.REASON`), so RELEASE must be tested before SUMMON or
##     every tributed monster would animate as if it were being summoned;
##  4. only then the destination, which is the weakest signal of the three.
static func move_kind(from_info: Dictionary, to_info: Dictionary, reason: int) -> String:
	var from_location: int = _as_int(from_info.get("loc", 0), 0)
	var to_location: int = _as_int(to_info.get("loc", 0), 0)

	if to_location == 0:
		return KIND_REMOVE
	if (to_location & DuelEnums.LOCATION.OVERLAY) != 0:
		return KIND_ATTACH
	if (from_location & DuelEnums.LOCATION.OVERLAY) != 0:
		return KIND_DETACH
	if from_location == 0:
		return KIND_CREATE

	if (reason & DuelEnums.REASON.RELEASE) != 0:
		return KIND_TRIBUTE
	if (reason & DuelEnums.REASON.DISCARD) != 0:
		return KIND_DISCARD
	if (reason & DuelEnums.REASON.DESTROY) != 0:
		return KIND_DESTROY
	if (reason & _MATERIAL_REASONS) != 0:
		return KIND_MATERIAL
	if (reason & DuelEnums.REASON.SUMMON) != 0:
		return KIND_SUMMON
	if (reason & DuelEnums.REASON.SPSUMMON) != 0:
		return KIND_SPECIAL_SUMMON

	match to_location & ~DuelEnums.LOCATION.OVERLAY:
		DuelEnums.LOCATION.GRAVE:
			return KIND_TO_GRAVE
		DuelEnums.LOCATION.REMOVED:
			return KIND_BANISH
		DuelEnums.LOCATION.HAND:
			return KIND_TO_HAND
		DuelEnums.LOCATION.DECK:
			return KIND_TO_DECK
		DuelEnums.LOCATION.EXTRA:
			return KIND_TO_EXTRA
		DuelEnums.LOCATION.MZONE:
			return KIND_PLACE_MONSTER
		DuelEnums.LOCATION.SZONE:
			return KIND_PLACE_SPELL
		_:
			return KIND_MOVE


## Reasons that mean "consumed as summoning material". Any of them sends the card to the
## graveyard or the overlay stack as part of someone else's summon, which wants one shared
## animation rather than six.
const _MATERIAL_REASONS: int = (
	DuelEnums.REASON.MATERIAL
	| DuelEnums.REASON.FUSION
	| DuelEnums.REASON.SYNCHRO
	| DuelEnums.REASON.XYZ
	| DuelEnums.REASON.LINK
	| DuelEnums.REASON.RITUAL
)


## The anchor naming a `loc_info`. Public: L4 needs the same grammar to place a card it reads
## straight out of `DuelState`.
static func anchor_of(info: Dictionary) -> String:
	var location: int = _as_int(info.get("loc", 0), 0)
	if location == 0:
		return ANCHOR_NOWHERE

	var player: int = _as_int(info.get("con", 0), 0)
	var sequence: int = _as_int(info.get("seq", 0), 0)

	# An xyz material hangs off a host card: `seq` is the host's zone and `pos` is the index in
	# its stack (AGENTS.md section 8b.7).
	if (location & DuelEnums.LOCATION.OVERLAY) != 0:
		var host: String = anchor_of({
			"con": player,
			"loc": location & ~DuelEnums.LOCATION.OVERLAY,
			"seq": sequence,
			"pos": 0,
		})
		return "OVL_%s_%d" % [host, _as_int(info.get("pos", 0), 0)]

	match location:
		DuelEnums.LOCATION.DECK:
			return "DECK_P%d" % player
		DuelEnums.LOCATION.HAND:
			return "HAND_P%d" % player
		DuelEnums.LOCATION.GRAVE:
			return "GY_P%d" % player
		DuelEnums.LOCATION.REMOVED:
			return "BANISH_P%d" % player
		DuelEnums.LOCATION.EXTRA:
			return "EXTRA_P%d" % player
		DuelEnums.LOCATION.MZONE:
			if sequence >= DuelEnums.MAIN_MONSTER_ZONES:
				return "EMZ_P%d_%d" % [player, sequence - DuelEnums.MAIN_MONSTER_ZONES]
			return "MZ_P%d_%d" % [player, sequence]
		DuelEnums.LOCATION.SZONE:
			if sequence == DuelEnums.FIELD_ZONE_SEQUENCE:
				return "FZ_P%d" % player
			if sequence >= DuelEnums.PENDULUM_LEFT_SEQUENCE:
				return "PZ_P%d_%d" % [player, sequence - DuelEnums.PENDULUM_LEFT_SEQUENCE]
			return "ST_P%d_%d" % [player, sequence]
		_:
			return "%s_P%d" % [DuelEnums.location_name(location), player]


## The face string for a `DuelEnums.POSITION` value. Anything that is not exactly one of the
## four positions - a mask, or a zero meaning "no position byte was sent" - is UNKNOWN.
static func face_of(position: int) -> String:
	match position:
		DuelEnums.POSITION.FACEUP_ATTACK:
			return FACE_UP_ATTACK
		DuelEnums.POSITION.FACEDOWN_ATTACK:
			return FACE_DOWN_ATTACK
		DuelEnums.POSITION.FACEUP_DEFENSE:
			return FACE_UP_DEFENSE
		DuelEnums.POSITION.FACEDOWN_DEFENSE:
			return FACE_DOWN_DEFENSE
		_:
			return FACE_UNKNOWN


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## A fresh intent carrying only the three fields every intent has. `PROFILES` is a `const`, so
## it is read-only at runtime; the duplicate is required, not defensive.
static func _base(kind: String) -> Dictionary:
	var profile: Dictionary = PROFILES.get(kind, DEFAULT_PROFILE)
	return {
		"kind": kind,
		"duration": float(profile["duration"]),
		"blocking": bool(profile["blocking"]),
	}


## An equip card binding to its target. Both ends are packed loc_infos (msg_parser.cpp).
func _translate_equip(event: Dictionary, intents: Array[Dictionary]) -> void:
	var intent: Dictionary = _base(KIND_EQUIP)
	intent["from_anchor"] = anchor_of(event.get("from", {}))
	intent["to_anchor"] = anchor_of(event.get("to", {}))
	intent["blocking"] = false
	intents.append(intent)


## A coin toss or die roll. The results are the point - a card resolves differently on them, so
## they travel to L4 rather than being collapsed into "something was tossed".
func _translate_toss(event: Dictionary, intents: Array[Dictionary], kind: String) -> void:
	var intent: Dictionary = _base(kind)
	intent["player"] = _as_int(event.get("player", 0), 0)
	intent["results"] = event.get("results", [])
	intent["blocking"] = false
	intents.append(intent)


## Normalises a `loc_info` so every handler can index it without checking. Accepts the wire
## spelling (`con`/`loc`/`seq`/`pos`) and the long one a hand-written event might use.
static func _loc(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {"con": 0, "loc": 0, "seq": 0, "pos": 0}
	var source: Dictionary = value as Dictionary
	return {
		"con": _as_int(source.get("con", source.get("controller", 0)), 0),
		"loc": _as_int(source.get("loc", source.get("location", 0)), 0),
		"seq": _as_int(source.get("seq", source.get("sequence", 0)), 0),
		"pos": _as_int(source.get("pos", source.get("position", 0)), 0),
	}


static func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is bool:
		return 1 if value else 0
	return fallback


static func _as_array(value: Variant) -> Array:
	if value is Array:
		return value as Array
	return []
