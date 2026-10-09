class_name SelectionController
extends RefCounted

## Turns `InputIntent` dictionaries into the response intents `KaibaCore.respond()` expects.
##
## Layer: L3 (AGENTS.md section 4). **V2 applies in full**: nothing here names `Node3D`,
## `CardView`, `BoardView`, a `Texture`, a `PackedScene` or anything else from the scene tree.
## It works on dictionaries, card handles and anchor strings, and it would run identically in a
## headless replay verifier with no renderer at all.
##
## -------------------------------------------------------------------------------------------
## What it sits between
## -------------------------------------------------------------------------------------------
##
##   InputSource  --InputIntent-->  SelectionController  --intent-->  KaibaCore.respond()
##      (L5)                               (L3)                            (L1)
##
## The duel parks on an `MSG_SELECT_*`; `set_pending()` is handed that event; taps arrive; when
## enough of them have arrived to constitute an answer, `resolve()` returns the intent and the
## caller sends it. Until then it returns `{}` - a tap that does not finish an answer is not an
## error, it is the normal middle of a multi-card selection.
##
## Every key this file produces was read off `native/src/response_builder.cpp`, and every
## validation rule off `native/vendor/ocgcore/playerop.cpp`. Neither was guessed at, because a
## wrong answer is not reported as a wrong answer: ocgcore replies `MSG_RETRY` and does **not**
## resend the selection (AGENTS.md section 8b traps 8 and 9), so the duel simply appears to hang.
##
## -------------------------------------------------------------------------------------------
## How a tapped card becomes a list index
## -------------------------------------------------------------------------------------------
## An `InputIntent` carries a `handle`. A selection event carries lists of
## `{"card": code, "at": {con, loc, seq, pos}}`. The bridge is `DuelState`: the handle names a
## `DuelCard`, the card knows its controller / location / sequence, and that triple plus the
## passcode is matched against every entry of every list the request offers.
##
## It has to be the handle and not the passcode. Two copies of one card in a hand share a
## passcode, and a face-down card reports `0` - `duel_card.gd` says the same thing at more
## length. The passcode is still compared when both sides know it, as a second opinion that
## catches a `DuelState` that has drifted out of step with the engine.
##
## Without a bound `DuelState` the anchor is used instead, which is enough for a zone
## (`MZ_P0_3` names exactly one slot) but not for a pile: `HAND_P0` does not say *which* card in
## the hand. That fallback exists so this class degrades rather than crashes, not as a design.
##
## -------------------------------------------------------------------------------------------
## What it cannot answer yet
## -------------------------------------------------------------------------------------------
## `MSG_SELECT_OPTION` needs an intent that names an option, and `MSG_SORT_CARD` needs one that
## names an order. The six-verb vocabulary has no way to express either, so both are answered
## with their least-destructive default (first option, decline the sort) and flagged by
## `can_answer()`. `MSG_SELECT_COUNTER`, `MSG_SELECT_UNSELECT_CARD` and the `MSG_ANNOUNCE_*`
## family are not answered at all - `MsgParser` does not even parse them yet.

# ----------------------------------------------------------------------------------------------
# InputIntent vocabulary. Mirrors `platform/input/input_source.gd`; duplicated as plain strings
# rather than imported, because L3 must not reach up to L5 to learn what a tap is called.
# ----------------------------------------------------------------------------------------------

const KIND_SELECT_CARD: String = "SELECT_CARD"
## "Play this card the other way." Same card, same fields as SELECT_CARD; what differs is which
## of the commands ocgcore offered for it the player meant.
const KIND_SELECT_ALT: String = "SELECT_ALT"
const KIND_SELECT_ZONE: String = "SELECT_ZONE"
const KIND_POINT_AT: String = "POINT_AT"
const KIND_CONFIRM: String = "CONFIRM"
const KIND_CANCEL: String = "CANCEL"

## Which idle-phase list a tapped card is checked against, in order. A card in hand is offered
## in several at once - a monster as both `summon` and `mset`, a spell as both `activate` and
## `sset` - and nothing in the request says which the player meant.
##
## The order encodes "the most committal reading of a tap wins", which is what one gesture can
## express. `IDLE_ALT_PRIORITY` is the other half of the answer: the vocabulary now has a second
## verb, so the player says which reading they meant instead of this table guessing.
const IDLE_PRIORITY: Array[String] = ["activate", "summon", "spsummon", "mset", "sset", "repos"]

## The same lists, in the order a `SELECT_ALT` reads them: set before play.
##
## This closed a real hole rather than adding a convenience. With `IDLE_PRIORITY` alone there
## was **no way to set a monster at all** - a monster in hand is offered as both `summon` and
## `mset`, and `summon` always won; the only card a player could ever set was a trap, because a
## trap appears in `sset` and in nothing else.
##
## The tail is the fallback, and it is what makes the gesture safe to use on any card: a card
## the engine offered only one way still plays that way rather than doing nothing. Setting is a
## *preference*, not a demand, because the alternative is a gesture that silently fails on a
## monster already on the field and the player cannot tell why.
const IDLE_ALT_PRIORITY: Array[String] = ["mset", "sset", "summon", "activate", "spsummon", "repos"]

## Same, for the battle phase. Attacking is what a tap in the battle phase means.
const BATTLE_PRIORITY: Array[String] = ["attack", "activate"]

## ocgcore's own bound: `sequence > 7 - ismzone` (playerop.cpp, Processors::SelectPlace).
const MAX_MZONE_SEQUENCE: int = 6
const MAX_SZONE_SEQUENCE: int = 7

var _state: DuelState = null

## The `MSG_SELECT_*` event the duel is parked on, or `{}`.
var _pending: Dictionary = {}
var _type: int = 0

## Indices into the request's `cards` list gathered so far. SELECT_CARD / TRIBUTE / SUM.
var _picks: Array[int] = []

## Zones gathered so far, each `{con, loc, seq}`. SELECT_PLACE.
var _places: Array[Dictionary] = []


func _init(state: DuelState = null) -> void:
	_state = state


## The model used to turn a card handle into a location. Optional, but a selection that names
## cards cannot be answered from a tap without it.
func bind_state(state: DuelState) -> void:
	_state = state


# ----------------------------------------------------------------------------------------------
# Pending selection
# ----------------------------------------------------------------------------------------------

## Parks the controller on a selection. Anything gathered for the previous one is dropped:
## picks are only ever meaningful against the request that offered them.
func set_pending(event: Dictionary) -> void:
	_pending = event
	_type = int(event.get("t", 0))
	_picks = []
	_places = []


## Forgets the pending selection. Call it once the answer has been sent.
func clear() -> void:
	_pending = {}
	_type = 0
	_picks = []
	_places = []


func is_waiting() -> bool:
	return _type != 0


## `DuelEnums.EV` value of the pending selection, or `0`.
func pending_type() -> int:
	return _type


## The request itself, for a HUD that wants to highlight what is on offer. Read-only by
## convention; nothing here copies it, because the duel scene owns the event anyway.
func pending_event() -> Dictionary:
	return _pending


## Indices gathered so far, for highlighting. A copy: a HUD must not be able to edit the answer.
func picks() -> Array[int]:
	return _picks.duplicate()


## Zones gathered so far, each `{con, loc, seq}`. A copy, for the same reason.
func places() -> Array[Dictionary]:
	return _places.duplicate(true)


## Selections `resolve()` can answer in full. `SELECT_OPTION` and the two sort selections are
## deliberately absent: they are answered with a default rather than with the player's choice,
## because no `InputIntent` can carry one. See the header note.
const ANSWERABLE: Array[int] = [
	DuelEnums.EV.SELECT_IDLECMD,
	DuelEnums.EV.SELECT_BATTLECMD,
	DuelEnums.EV.SELECT_PLACE,
	DuelEnums.EV.SELECT_CARD,
	DuelEnums.EV.SELECT_TRIBUTE,
	DuelEnums.EV.SELECT_SUM,
	DuelEnums.EV.SELECT_YESNO,
	DuelEnums.EV.SELECT_EFFECTYN,
	DuelEnums.EV.SELECT_CHAIN,
	DuelEnums.EV.SELECT_POSITION,
	DuelEnums.EV.SELECT_OPTION,
]


## True when `resolve()` can produce the player's own answer for this selection type. False
## means the caller is on its own - see the header note on what the vocabulary cannot express.
static func can_answer(event_type: int) -> bool:
	return ANSWERABLE.has(event_type)


## Short line for a HUD or a console log. Empty when nothing is pending.
func pending_prompt() -> String:
	if not is_waiting():
		return ""

	match _type:
		DuelEnums.EV.SELECT_IDLECMD:
			return "Main phase: tap a card to play it%s" % _advance_hint("to_bp", "battle phase")
		DuelEnums.EV.SELECT_BATTLECMD:
			return "Battle phase: tap a monster to attack%s" % _advance_hint("to_m2", "main phase 2")
		DuelEnums.EV.SELECT_PLACE:
			var wanted: int = maxi(1, int(_pending.get("count", 1)))
			return "Choose %d zone(s): %d picked, %d free" % [
				wanted, _places.size(), free_places().size()]
		DuelEnums.EV.SELECT_CARD:
			return "Select %s: %d picked%s" % [
				_range_text(), _picks.size(), _cancel_hint()]
		DuelEnums.EV.SELECT_TRIBUTE:
			return "Tribute %s: %d picked worth %d%s" % [
				_range_text(), _picks.size(), _tribute_total(), _cancel_hint()]
		DuelEnums.EV.SELECT_SUM:
			return "Select cards summing to %d: %d picked, confirm to solve" % [
				int(_pending.get("acc", 0)), _picks.size()]
		DuelEnums.EV.SELECT_YESNO, DuelEnums.EV.SELECT_EFFECTYN:
			var desc: int = int(_pending.get("desc", 0))
			var card: int = int(_pending.get("card", 0))
			if desc == 0 and card == 0:
				return "Yes or no? (confirm = yes, cancel = no)"
			return "Yes or no? card=%d desc=%d (confirm = yes, cancel = no)" % [card, desc]
		DuelEnums.EV.SELECT_CHAIN:
			var count: int = _list("chains").size()
			if bool(_pending.get("forced", false)):
				return "Chain is forced: pick one of %d effects" % count
			return "Respond with an effect? %d available, cancel to pass" % count
		DuelEnums.EV.SELECT_POSITION:
			return "Choose a battle position (confirm = attack, cancel = defense)"
		DuelEnums.EV.SELECT_OPTION:
			return "Choose an option: %d offered, confirm takes the first" % _list("options").size()
		DuelEnums.EV.SORT_CARD, DuelEnums.EV.SORT_CHAIN:
			return "Sort %d cards (not expressible yet; confirm declines)" % _list("cards").size()

	return "Waiting on %s" % DuelEnums.ev_name(_type)


# ----------------------------------------------------------------------------------------------
# Resolution
# ----------------------------------------------------------------------------------------------

## `InputIntent` -> the intent `KaibaCore.respond()` expects, or `{}` when this tap did not
## complete an answer.
##
## `{}` is the normal return for most taps. A three-card selection answers on the third one; a
## tap on a card the request never offered answers on none of them.
## The answer this selection would have if the player had no real choice, or `{}` when they do.
##
## ocgcore hands priority to the other player after almost every action, and it does so whether
## or not that player has anything to respond with - it only short-circuits for `DUEL_SIMPLE_AI`
## (`playerop.cpp:460`). So a duel is full of `MSG_SELECT_CHAIN` prompts offering **zero**
## effects, which the prompt itself admits: "0 available, cancel to pass". Asking a person to
## decline nothing, once per action, is noise that makes the real decisions harder to notice.
##
## Only genuinely empty, non-forced chains qualify. `spe_count` does **not** hide options: EDOPro
## reads `specount == 0x7f` purely to switch its trigger panel on (`duelclient.cpp:2132`), and
## the options themselves always come from the list length. A forced chain with an empty list
## would be a contradiction, so it is left alone rather than guessed at - a wrong auto-answer
## costs the player a legal play, which is far worse than one extra tap.
func auto_answer() -> Dictionary:
	if not is_waiting():
		return {}
	if _type != DuelEnums.EV.SELECT_CHAIN:
		return {}
	if bool(_pending.get("forced", false)):
		return {}
	if not _list("chains").is_empty():
		return {}
	return {"cancel": true}


## Cards the pending selection is actually offering, by handle. Empty when it names no cards.
##
## Needs the model, because a selection event does **not** carry handles. `MsgParser` writes
## `{"card": code, "at": loc_info}` - handles are minted by `DuelState` and stamped onto Level-2
## intents by `EventTranslator`, which is a later stage entirely. Reading `"handle"` off these
## entries would quietly return nothing on every call.
##
## L4 uses this to light what can be acted on, so "there is something to do" is visible without
## reading the prompt.
func actionable_handles(state: DuelState) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if not is_waiting() or state == null:
		return out

	for key: String in OFFER_LISTS:
		for entry: Variant in _list(key):
			var at: Dictionary = (entry as Dictionary).get("at", {}) as Dictionary
			if at.is_empty():
				continue
			var card: DuelCard = state.card_at(
				int(at.get("con", 0)), int(at.get("loc", 0)), int(at.get("seq", 0)))
			if card != null and card.handle != 0 and not out.has(card.handle):
				out.append(card.handle)
	return out


## Every key under which a selection event can list cards it is offering. One place, because a
## list added to `MsgParser` and forgotten here goes dark rather than wrong, which is harder to
## notice than a crash.
const OFFER_LISTS: Array[String] = [
	"chains", "cards", "must",
	"summon", "spsummon", "mset", "sset", "repos", "activate", "attack",
]


## Human-readable labels for the command list keys. Used by the action menu to present
## choices the player actually recognises.
const ACTION_LABELS: Dictionary = {
	"summon": "Normal Summon",
	"spsummon": "Special Summon",
	"mset": "Set (face-down)",
	"sset": "Set",
	"activate": "Activate",
	"repos": "Change Position",
	"attack": "Attack",
}


## Every action the pending selection offers for the card identified by `handle`.
##
## Returns an array of `{"key": String, "label": String, "index": int}`. Empty when the
## card is not offered in any list, or no selection is pending, or the selection is not an
## idle or battle command.
func available_actions_for(handle: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_waiting() or _state == null or handle == 0:
		return out

	var card: DuelCard = _card_by_handle(handle)
	if card == null:
		return out

	var where: Dictionary = {
		"con": card.controller,
		"loc": card.location,
		"seq": card.sequence,
		"code": card.code,
	}

	var keys: Array[String] = []
	match _type:
		DuelEnums.EV.SELECT_IDLECMD:
			keys.assign(IDLE_PRIORITY)
		DuelEnums.EV.SELECT_BATTLECMD:
			keys.assign(BATTLE_PRIORITY)
		_:
			return out

	for key: String in keys:
		var index: int = _index_in_list(key, where)
		if index >= 0:
			out.append({
				"key": key,
				"label": ACTION_LABELS.get(key, key),
				"index": index,
			})
	return out


## Builds the response for a specific action the player chose from the action menu.
func resolve_action(cmd: String, index: int) -> Dictionary:
	if not is_waiting():
		return {}
	match _type:
		DuelEnums.EV.SELECT_IDLECMD, DuelEnums.EV.SELECT_BATTLECMD:
			return {"cmd": cmd, "index": index}
	return {}


func resolve(input: Dictionary) -> Dictionary:
	if not is_waiting():
		return {}

	var kind: String = str(input.get("kind", ""))
	# A preview is not an answer, ever. It exists so a HUD can show a card without the duel
	# interpreting the gesture as a decision.
	if kind == KIND_POINT_AT or kind == "":
		return {}

	# Outside the idle phase there is no "other way" to play a card, and a gesture that does
	# nothing wherever it is not special is a gesture players stop trusting. So every other
	# selection reads SELECT_ALT as the plain selection it also is. The intent is unchanged; only
	# the local reading of it is.
	if kind == KIND_SELECT_ALT and _type != DuelEnums.EV.SELECT_IDLECMD:
		kind = KIND_SELECT_CARD

	match _type:
		DuelEnums.EV.SELECT_IDLECMD:
			var priority: Array[String] = IDLE_ALT_PRIORITY if kind == KIND_SELECT_ALT else IDLE_PRIORITY
			return _resolve_command(input, priority, "to_bp", "to_ep")
		DuelEnums.EV.SELECT_BATTLECMD:
			return _resolve_command(input, BATTLE_PRIORITY, "to_m2", "to_ep")
		DuelEnums.EV.SELECT_PLACE:
			return _resolve_place(input, kind)
		DuelEnums.EV.SELECT_CARD, DuelEnums.EV.SELECT_TRIBUTE:
			return _resolve_card_list(input, kind)
		DuelEnums.EV.SELECT_SUM:
			return _resolve_sum(input, kind)
		DuelEnums.EV.SELECT_YESNO, DuelEnums.EV.SELECT_EFFECTYN:
			return _resolve_yes_no(kind)
		DuelEnums.EV.SELECT_CHAIN:
			return _resolve_chain(input, kind)
		DuelEnums.EV.SELECT_POSITION:
			return _resolve_position(kind)
		DuelEnums.EV.SELECT_OPTION:
			# No intent names an option, so the only honest answer is the first one.
			return {"index": 0} if kind == KIND_CONFIRM else {}
		DuelEnums.EV.SORT_CARD, DuelEnums.EV.SORT_CHAIN:
			# Likewise: no intent expresses an order, and declining keeps the engine's own.
			return {"cancel": true} if kind == KIND_CONFIRM or kind == KIND_CANCEL else {}

	return {}


## MSG_SELECT_IDLECMD and MSG_SELECT_BATTLECMD. Both answer `{"cmd": name, "index": N}` where
## `name` is one of the list keys the request carries (response_builder.cpp, IDLE_COMMANDS /
## BATTLE_COMMANDS - the names there are deliberately the same strings `MsgParser` uses).
func _resolve_command(input: Dictionary, priority: Array[String], advance: String, finish: String) -> Dictionary:
	var kind: String = str(input.get("kind", ""))
	# Which priority list to walk was decided by the caller; from here a card is a card.
	if kind == KIND_SELECT_ALT:
		kind = KIND_SELECT_CARD

	if kind == KIND_CONFIRM:
		if bool(_pending.get(advance, false)):
			return {"cmd": advance}
		if bool(_pending.get(finish, false)):
			return {"cmd": finish}
		return {}

	if kind == KIND_CANCEL:
		# The only way to reach the end phase while a battle phase is also on offer. A stray
		# cancel ending the phase is survivable; having no gesture that can end a turn is not.
		if bool(_pending.get(finish, false)):
			return {"cmd": finish}
		return {}

	if kind != KIND_SELECT_CARD:
		return {}

	var where: Dictionary = _locate(input)
	if where.is_empty():
		return {}

	for key: String in priority:
		var index: int = _index_in_list(key, where)
		if index >= 0:
			return {"cmd": key, "index": index}
	return {}


## MSG_SELECT_PLACE. The answer is `{"places": [{con, loc, seq}, ...], "count": N}`.
##
## The request's `flag` is the whole difficulty: a **set** bit means the zone is NOT selectable,
## and the sides are relative to `event["player"]`, not to absolute player 0. Answering with a
## blocked zone yields `MSG_RETRY`, which is silent. See `is_place_free()`.
func _resolve_place(input: Dictionary, kind: String) -> Dictionary:
	var wanted: int = maxi(1, int(_pending.get("count", 1)))

	if kind == KIND_CANCEL:
		# The engine never accepts a cancelled place, so this can only mean "start over".
		_places = []
		return {}

	if kind == KIND_CONFIRM:
		if _places.size() == wanted:
			return _place_answer(wanted)
		return {}

	# A zone tap is the normal case, but a tap on a card is treated as a tap on the zone it is
	# standing in: a player aiming at an occupied slot is still aiming at the slot.
	var zone: Dictionary = _zone_of_input(input)
	if zone.is_empty():
		return {}
	if not _is_free(zone):
		return {}
	if _places.any(func(entry: Dictionary) -> bool: return _same_zone(entry, zone)):
		return {}

	_places.append(zone)
	if _places.size() >= wanted:
		return _place_answer(wanted)
	return {}


## MSG_SELECT_CARD and MSG_SELECT_TRIBUTE. Both answer `{"indices": [...]}`, and both accept
## `{"cancel": true}` only when the request said so.
##
## The two differ in how ocgcore counts the answer (playerop.cpp):
##
##   SELECT_CARD     min <= list.size() <= max
##   SELECT_TRIBUTE  list.size() <= max  and  sum of release_param >= min
##
## so a tribute that is worth two counts twice towards `min` while still occupying one index.
## Counting cards for both is correct only while every `release_param` is 1.
func _resolve_card_list(input: Dictionary, kind: String) -> Dictionary:
	if kind == KIND_CANCEL:
		if not _picks.is_empty():
			_picks = []
			return {}
		if bool(_pending.get("cancelable", false)):
			return {"cancel": true}
		return {}

	if kind == KIND_CONFIRM:
		return {"indices": _picks.duplicate()} if _card_answer_is_valid() else {}

	if kind != KIND_SELECT_CARD and kind != KIND_SELECT_ZONE:
		return {}

	var index: int = _index_in_list("cards", _locate(input))
	if index < 0:
		return {}

	# Tapping a picked card unpicks it. Without this there is no way to undo one pick out of
	# three short of cancelling the whole selection.
	var at: int = _picks.find(index)
	if at >= 0:
		_picks.remove_at(at)
		return {}

	var maximum: int = int(_pending.get("max", 0))
	if maximum > 0 and _picks.size() >= maximum:
		return {}
	_picks.append(index)

	# Submit the moment the answer is complete and cannot legally grow. For the overwhelmingly
	# common `min == max == 1` that makes a single tap the whole interaction.
	if maximum > 0 and _picks.size() == maximum and _card_answer_is_valid():
		return {"indices": _picks.duplicate()}
	return {}


## MSG_SELECT_SUM. Answers `{"indices": [...]}` and is never cancelable - ocgcore calls
## `parse_response_cards(false)` for it, so a `{"cancel": true}` would be rejected outright.
##
## Taps gather; `CONFIRM` hands what has been gathered to the solver, which completes it into a
## subset that lands exactly on the target. A tap that happens to complete a valid subset by
## itself submits immediately.
func _resolve_sum(input: Dictionary, kind: String) -> Dictionary:
	if kind == KIND_CANCEL:
		_picks = []
		return {}

	if kind == KIND_CONFIRM:
		var solved: Array[int] = _solve_sum(_picks)
		return {"indices": solved} if not solved.is_empty() else {}

	if kind != KIND_SELECT_CARD and kind != KIND_SELECT_ZONE:
		return {}

	var index: int = _index_in_list("cards", _locate(input))
	if index < 0:
		return {}
	var at: int = _picks.find(index)
	if at >= 0:
		_picks.remove_at(at)
		return {}
	_picks.append(index)

	if _sum_is_exact(_picks):
		return {"indices": _picks.duplicate()}
	return {}


## MSG_SELECT_YESNO and MSG_SELECT_EFFECTYN. The engine rejects anything but literally 0 or 1.
func _resolve_yes_no(kind: String) -> Dictionary:
	match kind:
		KIND_CONFIRM:
			return {"answer": 1}
		KIND_CANCEL:
			return {"answer": 0}
	return {}


## MSG_SELECT_CHAIN. `{"cancel": true}` becomes -1, which ocgcore accepts only when the request
## was not `forced`; a forced chain answered with -1 is a silent `MSG_RETRY`.
func _resolve_chain(input: Dictionary, kind: String) -> Dictionary:
	var forced: bool = bool(_pending.get("forced", false))
	var chains: Array = _list("chains")

	match kind:
		KIND_CANCEL:
			if forced:
				return {"index": 0} if not chains.is_empty() else {}
			return {"cancel": true}
		KIND_CONFIRM:
			return {"index": 0} if not chains.is_empty() else {}
		KIND_SELECT_CARD:
			var index: int = _index_in_list("chains", _locate(input))
			return {"index": index} if index >= 0 else {}
	return {}


## MSG_SELECT_POSITION. The answer must be exactly one `POS_*` bit, and one the request offered
## - the engine rejects a position it did not list.
##
## Two gestures cannot express four positions. Confirm takes the first face-up position offered,
## cancel the first defensive one; a real HUD will put four buttons here and call `respond()`
## itself.
func _resolve_position(kind: String) -> Dictionary:
	var offered: int = int(_pending.get("positions", 0))
	if offered == 0:
		offered = DuelEnums.POSITION.FACEUP_ATTACK

	var order: Array[int] = []
	match kind:
		KIND_CONFIRM:
			order = [
				DuelEnums.POSITION.FACEUP_ATTACK,
				DuelEnums.POSITION.FACEUP_DEFENSE,
				DuelEnums.POSITION.FACEDOWN_DEFENSE,
				DuelEnums.POSITION.FACEDOWN_ATTACK,
			]
		KIND_CANCEL:
			order = [
				DuelEnums.POSITION.FACEDOWN_DEFENSE,
				DuelEnums.POSITION.FACEUP_DEFENSE,
				DuelEnums.POSITION.FACEUP_ATTACK,
				DuelEnums.POSITION.FACEDOWN_ATTACK,
			]
		_:
			return {}

	for bit: int in order:
		if (offered & bit) != 0:
			return {"position": bit}
	return {}


# ----------------------------------------------------------------------------------------------
# Zones
# ----------------------------------------------------------------------------------------------

## Decodes an anchor back into `{con, loc, seq}`. The exact inverse of
## `EventTranslator.anchor_of()` over the zone anchors; pile anchors have no sequence and return
## `{}` because a pile is not a place.
##
## Both sides of this pair are L3 and the grammar is a string vocabulary, not a scene type, so
## inverting it here breaks nothing (V2).
static func zone_of_anchor(anchor: String) -> Dictionary:
	var parts: PackedStringArray = anchor.split("_")
	if parts.size() < 2 or not parts[1].begins_with("P"):
		return {}
	var player_text: String = parts[1].substr(1)
	if not player_text.is_valid_int():
		return {}
	var player: int = player_text.to_int()
	if player < 0 or player >= DuelEnums.PLAYER_COUNT:
		return {}

	var tail: int = -1
	if parts.size() >= 3 and parts[2].is_valid_int():
		tail = parts[2].to_int()

	match parts[0]:
		"MZ":
			if tail < 0 or tail >= DuelEnums.MAIN_MONSTER_ZONES:
				return {}
			return {"con": player, "loc": DuelEnums.LOCATION.MZONE, "seq": tail}
		"EMZ":
			if tail < 0 or tail >= DuelEnums.EXTRA_MONSTER_ZONES:
				return {}
			return {"con": player, "loc": DuelEnums.LOCATION.MZONE,
				"seq": DuelEnums.MAIN_MONSTER_ZONES + tail}
		"ST":
			if tail < 0 or tail >= DuelEnums.SPELL_TRAP_ZONES:
				return {}
			return {"con": player, "loc": DuelEnums.LOCATION.SZONE, "seq": tail}
		"FZ":
			return {"con": player, "loc": DuelEnums.LOCATION.SZONE,
				"seq": DuelEnums.FIELD_ZONE_SEQUENCE}
		"PZ":
			if tail < 0 or tail > 1:
				return {}
			return {"con": player, "loc": DuelEnums.LOCATION.SZONE,
				"seq": DuelEnums.PENDULUM_LEFT_SEQUENCE + tail}
	return {}


## Whether `MSG_SELECT_PLACE` will accept this zone, decoded from the request's own mask.
##
## Verbatim from ocgcore's validation (playerop.cpp, Processors::SelectPlace):
##
##     to_check = 1 << sequence
##     if location is SZONE:          to_check <<= 8
##     if not the asking player's side: to_check <<= 16
##     a SET bit means the zone is NOT selectable
##
## `asking_player` is `event["player"]`. The sides in the mask are **relative** to them, so the
## same absolute controller is a different bit depending on who was asked. Reading the mask as
## absolute is the subtle version of the bug AGENTS.md section 8b trap 9 describes, and it only
## shows up when the opponent is the one being asked.
static func is_place_free(flag: int, asking_player: int, con: int, loc: int, seq: int) -> bool:
	if loc != DuelEnums.LOCATION.MZONE and loc != DuelEnums.LOCATION.SZONE:
		return false
	var limit: int = MAX_MZONE_SEQUENCE if loc == DuelEnums.LOCATION.MZONE else MAX_SZONE_SEQUENCE
	if seq < 0 or seq > limit:
		return false

	var bit: int = 1 << seq
	if loc == DuelEnums.LOCATION.SZONE:
		bit <<= 8
	if con != asking_player:
		bit <<= 16
	return (flag & bit) == 0


## Every zone the pending `MSG_SELECT_PLACE` will accept, in `{con, loc, seq}` form. For a HUD
## that wants to light up the legal slots, and for the prompt.
func free_places() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _type != DuelEnums.EV.SELECT_PLACE:
		return out

	var flag: int = int(_pending.get("flag", 0))
	var asking: int = int(_pending.get("player", 0))
	for player: int in range(DuelEnums.PLAYER_COUNT):
		for seq: int in range(MAX_MZONE_SEQUENCE + 1):
			if is_place_free(flag, asking, player, DuelEnums.LOCATION.MZONE, seq):
				out.append({"con": player, "loc": DuelEnums.LOCATION.MZONE, "seq": seq})
		for seq: int in range(MAX_SZONE_SEQUENCE + 1):
			if is_place_free(flag, asking, player, DuelEnums.LOCATION.SZONE, seq):
				out.append({"con": player, "loc": DuelEnums.LOCATION.SZONE, "seq": seq})
	return out


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## `InputIntent` -> `{con, loc, seq, code}`, the terms a request's card entries are written in.
##
## The handle is the real answer; the anchor is a fallback for when no `DuelState` is bound.
## See the header note on why the passcode cannot do this job.
func _locate(input: Dictionary) -> Dictionary:
	var handle: int = int(input.get("handle", 0))
	if handle != 0 and _state != null:
		var card: DuelCard = _card_by_handle(handle)
		if card != null:
			return {
				"con": card.controller,
				"loc": card.location,
				"seq": card.sequence,
				"code": card.code,
			}

	var zone: Dictionary = zone_of_anchor(str(input.get("anchor", "")))
	if zone.is_empty():
		return {}
	zone["code"] = int(input.get("card_id", 0))
	return zone


## The zone an intent points at, whether it tapped bare felt or the card standing in it.
func _zone_of_input(input: Dictionary) -> Dictionary:
	var where: Dictionary = _locate(input)
	if where.is_empty():
		return {}
	var loc: int = int(where.get("loc", 0))
	if loc != DuelEnums.LOCATION.MZONE and loc != DuelEnums.LOCATION.SZONE:
		return {}
	return {"con": int(where["con"]), "loc": loc, "seq": int(where["seq"])}


func _is_free(zone: Dictionary) -> bool:
	return is_place_free(
		int(_pending.get("flag", 0)),
		int(_pending.get("player", 0)),
		int(zone["con"]), int(zone["loc"]), int(zone["seq"]))


func _place_answer(count: int) -> Dictionary:
	var answer: Dictionary = {"places": _places.duplicate(true), "count": count}
	_places = []
	return answer


static func _same_zone(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("con", -1)) == int(b.get("con", -2)) \
		and int(a.get("loc", -1)) == int(b.get("loc", -2)) \
		and int(a.get("seq", -1)) == int(b.get("seq", -2))


## Index of `where` inside the request's `key` list, or -1.
##
## Matched on controller + location + sequence, with the passcode as a cross-check only when
## both sides know it: a face-down card reports `0` on the wire and would otherwise never match.
func _index_in_list(key: String, where: Dictionary) -> int:
	if where.is_empty():
		return -1
	var list: Array = _list(key)
	for index: int in range(list.size()):
		if not (list[index] is Dictionary):
			continue
		var entry: Dictionary = list[index]
		var at_value: Variant = entry.get("at", {})
		if not (at_value is Dictionary):
			continue
		var at: Dictionary = at_value
		if at.is_empty():
			continue
		if int(at.get("con", -1)) != int(where.get("con", -2)):
			continue
		if int(at.get("loc", -1)) != int(where.get("loc", -2)):
			continue
		if int(at.get("seq", -1)) != int(where.get("seq", -2)):
			continue
		var offered: int = int(entry.get("card", 0))
		var known: int = int(where.get("code", 0))
		if offered != 0 and known != 0 and offered != known:
			continue
		return index
	return -1


## The `DuelCard` carrying this handle, or `null`. Linear over the board, which is at most a
## couple of hundred cards and only ever walked on a tap.
func _card_by_handle(handle: int) -> DuelCard:
	if _state == null or handle == 0:
		return null

	for player: int in range(DuelEnums.PLAYER_COUNT):
		for pile: Array in [
			_state.hand[player], _state.graveyard[player], _state.banished[player],
			_state.deck[player], _state.extra_deck[player],
		]:
			for entry: Variant in pile:
				var card: DuelCard = entry as DuelCard
				if card != null and card.handle == handle:
					return card

		for slots: Array in [
			_state.main_monster[player], _state.extra_monster[player], _state.spell_trap[player],
		]:
			for entry: Variant in slots:
				var card: DuelCard = entry as DuelCard
				if card != null and card.handle == handle:
					return card

		var field: DuelCard = _state.field_zone[player] as DuelCard
		if field != null and field.handle == handle:
			return field

	return null


## Whether the gathered picks are an answer ocgcore will accept. See `_resolve_card_list()` for
## why the two selection types count differently.
func _card_answer_is_valid() -> bool:
	var minimum: int = int(_pending.get("min", 0))
	var maximum: int = int(_pending.get("max", 0))
	if maximum > 0 and _picks.size() > maximum:
		return false
	if _type == DuelEnums.EV.SELECT_TRIBUTE:
		return _tribute_total() >= minimum
	return _picks.size() >= minimum


## Sum of `release_param` over the gathered picks. A card worth two tributes counts twice
## towards `min` while still occupying a single index in the answer (msg_parser.cpp,
## parse_select_card).
func _tribute_total() -> int:
	var cards: Array = _list("cards")
	var total: int = 0
	for index: int in _picks:
		if index < 0 or index >= cards.size():
			continue
		total += maxi(1, int((cards[index] as Dictionary).get("release_param", 1)))
	return total


## True when `indices` already lands exactly on the sum the request asked for.
func _sum_is_exact(indices: Array[int]) -> bool:
	var cards: Array = _list("cards")
	var minimum: int = maxi(1, int(_pending.get("min", 1)))
	var maximum: int = int(_pending.get("max", 0))
	if indices.size() < minimum:
		return false
	if maximum > 0 and indices.size() > maximum:
		return false

	var target: int = _sum_target()
	# Each card may count as either of its two alternatives, so "does this set reach the total"
	# is itself a small search.
	var reachable: Dictionary = {0: true}
	for index: int in indices:
		if index < 0 or index >= cards.size():
			return false
		var param: int = int((cards[index] as Dictionary).get("sum_param", 0))
		var next: Dictionary = {}
		for option: int in [param & 0xffff, (param >> 16) & 0xffff]:
			if option <= 0:
				continue
			for partial: Variant in reachable:
				next[int(partial) + option] = true
		reachable = next
	return reachable.has(target)


## `acc` minus what the engine's own `must` list already contributes. Those cards are forced in
## and are **not** addressable by the answer, so counting them as selectable is an off-by-N that
## only surfaces as `MSG_RETRY` (msg_parser.cpp, parse_select_sum).
func _sum_target() -> int:
	var target: int = int(_pending.get("acc", 0))
	for entry: Variant in _list("must"):
		target -= int((entry as Dictionary).get("sum_param", 0)) & 0xffff
	return target


## Completes `required` into a subset of the offered cards that sums exactly to the target.
## Empty when no such subset exists.
##
## Ported from `scenes/duel_selectors.gd` `_solve_sum` / `_dfs_sum`, with one addition: the
## cards the player already tapped cannot be skipped, so confirming extends the player's
## selection rather than replacing it with whatever the search found first.
func _solve_sum(required: Array[int]) -> Array[int]:
	var cards: Array = _list("cards")
	var target: int = _sum_target()
	if target <= 0:
		return []

	var must_keep: Dictionary = {}
	for index: int in required:
		if index >= 0 and index < cards.size():
			must_keep[index] = true

	var chosen: Array[int] = []
	var minimum: int = maxi(1, int(_pending.get("min", 1)))
	var maximum: int = int(_pending.get("max", 0))
	if _dfs_sum(cards, 0, target, chosen, minimum, maximum, must_keep):
		return chosen
	return []


func _dfs_sum(cards: Array, i: int, remaining: int, chosen: Array[int], min_n: int, max_n: int,
		must_keep: Dictionary) -> bool:
	if remaining == 0:
		if chosen.size() < min_n or (max_n > 0 and chosen.size() > max_n):
			return false
		for index: Variant in must_keep:
			if not chosen.has(int(index)):
				return false
		return true
	if remaining < 0 or i >= cards.size():
		return false
	if max_n > 0 and chosen.size() >= max_n:
		return false

	# `sum_param` packs two alternatives in its low and high 16 bits (field.cpp:2619). A card
	# whose Level may be read as either contributes whichever one makes the total work.
	var param: int = int((cards[i] as Dictionary).get("sum_param", 0))
	var options: Array[int] = [param & 0xffff, (param >> 16) & 0xffff]
	for option: int in options:
		if option <= 0:
			continue
		chosen.append(i)
		if _dfs_sum(cards, i + 1, remaining - option, chosen, min_n, max_n, must_keep):
			return true
		chosen.pop_back()
		if options[0] == options[1]:
			break

	# A card the player picked by hand is not optional, so the "skip it" branch is closed.
	if must_keep.has(i):
		return false
	return _dfs_sum(cards, i + 1, remaining, chosen, min_n, max_n, must_keep)


func _list(key: String) -> Array:
	var value: Variant = _pending.get(key, [])
	return value as Array if value is Array else []


func _range_text() -> String:
	var minimum: int = int(_pending.get("min", 0))
	var maximum: int = int(_pending.get("max", 0))
	if maximum <= 0 or maximum == minimum:
		return "%d" % minimum
	return "%d-%d" % [minimum, maximum]


func _cancel_hint() -> String:
	return ", cancel to decline" if bool(_pending.get("cancelable", false)) else ""


func _advance_hint(key: String, label: String) -> String:
	return ", confirm for %s" % label if bool(_pending.get(key, false)) else ", confirm to end"
