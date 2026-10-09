class_name PassiveAgent
extends RefCounted
## An opponent that never does anything on purpose.
##
## Layer: L3 (AGENTS.md section 4). Dictionaries in, dictionaries out - no scene tree, no core.
##
## -------------------------------------------------------------------------------------------
## What it is for
## -------------------------------------------------------------------------------------------
## Solo mode needs a second seat that is not you. There is no AI yet, and pretending otherwise
## by routing Solo to a hot seat made the two modes identical - which is exactly what a player
## noticed first. This is the smallest thing that is honestly different: the opponent draws,
## passes, and ends its turn, so you can practise your own plays against a wall that never
## interrupts.
##
## It is deliberately **not** a bad AI. A bad AI makes moves you then have to reason about; a
## wall makes none, which is more useful for testing your own line and is honest about having
## no opinion. `heuristic_agent.gd` (ARCHITECTURE.md Phase 2) is the one that will play.
##
## -------------------------------------------------------------------------------------------
## Why it answers rather than declines
## -------------------------------------------------------------------------------------------
## Several prompts cannot be passed: a forced chain, a place the engine demands, a tribute it
## requires for a summon already committed. Answering "nothing" there is not neutral - it is a
## rejected response, and ocgcore does not re-send a selection it turned down (AGENTS.md
## section 8b trap 8), so the duel would freeze. Every branch below returns something the
## engine will accept.

## Answers one selection. `state` resolves card locations to nothing here, but is taken so the
## signature matches the agent interface a thinking opponent will need.
static func answer(event: Dictionary, _state: DuelState = null) -> Dictionary:
	var type: int = int(event.get("t", -1))

	match type:
		DuelEnums.EV.SELECT_IDLECMD:
			# Straight to the end of the turn. Battle is skipped too: a passive seat that
			# attacked would be making a decision, which is the thing it is here not to do.
			return {"cmd": "to_ep"}

		DuelEnums.EV.SELECT_BATTLECMD:
			return {"cmd": "to_ep"}

		DuelEnums.EV.SELECT_CHAIN:
			# A forced chain has to be answered with a real index; declining it is refused.
			if bool(event.get("forced", false)):
				return {"index": 0}
			return {"cancel": true}

		DuelEnums.EV.SELECT_EFFECTYN, DuelEnums.EV.SELECT_YESNO:
			return {"answer": 0}

		DuelEnums.EV.SELECT_OPTION:
			return {"index": 0}

		DuelEnums.EV.SELECT_POSITION:
			# Whichever position the request actually offered; the engine rejects any other.
			var offered: int = int(event.get("positions", DuelEnums.POSITION.FACEUP_ATTACK))
			for bit: int in [DuelEnums.POSITION.FACEUP_ATTACK, DuelEnums.POSITION.FACEUP_DEFENSE,
					DuelEnums.POSITION.FACEDOWN_DEFENSE, DuelEnums.POSITION.FACEDOWN_ATTACK]:
				if (offered & bit) != 0:
					return {"position": bit}
			return {"position": DuelEnums.POSITION.FACEUP_ATTACK}

		DuelEnums.EV.SELECT_PLACE:
			return _first_free_place(event)

		DuelEnums.EV.SELECT_CARD, DuelEnums.EV.SELECT_TRIBUTE:
			return _take_minimum(event)

		DuelEnums.EV.SELECT_SUM:
			return _solve_sum(event)

		DuelEnums.EV.SORT_CARD, DuelEnums.EV.SORT_CHAIN:
			return {"cancel": true}

		DuelEnums.EV.SELECT_COUNTER:
			var counter_cards: Array = event.get("cards", []) as Array
			if counter_cards.is_empty():
				return {}
			var total_needed: int = int(event.get("count", 0))
			var counters: Array[int] = []
			counters.resize(counter_cards.size())
			counters.fill(0)
			if not counters.is_empty():
				counters[0] = mini(total_needed, int((counter_cards[0] as Dictionary).get("max", total_needed)))
				total_needed -= counters[0]
				for ci: int in range(1, counter_cards.size()):
					if total_needed <= 0:
						break
					var take: int = mini(total_needed, int((counter_cards[ci] as Dictionary).get("max", total_needed)))
					counters[ci] = take
					total_needed -= take
			return {"counters": counters}

		DuelEnums.EV.SELECT_UNSELECT_CARD:
			if bool(event.get("cancelable", false)):
				return {"cancel": true}
			return {"index": 0}

		DuelEnums.EV.ANNOUNCE_RACE:
			var avail_race: int = int(event.get("available", 0))
			for bit: int in range(26):
				if (avail_race & (1 << bit)) != 0:
					return {"race": 1 << bit}
			return {}

		DuelEnums.EV.ANNOUNCE_ATTRIB:
			var avail_attr: int = int(event.get("available", 0))
			for bit: int in range(8):
				if (avail_attr & (1 << bit)) != 0:
					return {"attribute": 1 << bit}
			return {}

		DuelEnums.EV.ANNOUNCE_CARD:
			var card_opts: Array = event.get("options", []) as Array
			if card_opts.is_empty():
				return {}
			return {"code": int(card_opts[0])}

		DuelEnums.EV.ANNOUNCE_NUMBER:
			return {"index": 0}

	return {}


## The first zone the request's own mask leaves open. See AGENTS.md section 8b trap 9: a set bit
## means the zone is **not** selectable, and the sides are relative to the asking player.
static func _first_free_place(event: Dictionary) -> Dictionary:
	var flag: int = int(event.get("flag", 0))
	var me: int = int(event.get("player", 0))

	for sequence: int in range(7):
		if (flag & (1 << sequence)) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.MZONE, "seq": sequence}], "count": 1}
	for sequence: int in range(8):
		if (flag & (1 << (8 + sequence))) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.SZONE, "seq": sequence}], "count": 1}
	return {}


## The fewest cards the request will accept, lowest indices first.
static func _take_minimum(event: Dictionary) -> Dictionary:
	var cards: Array = event.get("cards", []) as Array
	var minimum: int = maxi(1, int(event.get("min", 1)))
	var indices: Array[int] = []
	for index: int in mini(minimum, cards.size()):
		indices.append(index)
	if indices.is_empty():
		return {"cancel": true} if bool(event.get("cancelable", false)) else {}
	return {"indices": indices}


## Cards whose parameters land exactly on the requested total.
##
## `must` cards are added by the engine and are not addressable by the answer, but they count
## toward the total. `sum_param` packs two alternatives in its low and high 16 bits
## (`field.cpp:2619`): a card whose Level may be read either way contributes whichever fits.
static func _solve_sum(event: Dictionary) -> Dictionary:
	var target: int = int(event.get("acc", 0))
	for entry: Variant in event.get("must", []):
		target -= int((entry as Dictionary).get("sum_param", 0)) & 0xffff

	var cards: Array = event.get("cards", []) as Array
	var chosen: Array[int] = []
	if target > 0 and _search_sum(cards, 0, target, chosen,
			maxi(1, int(event.get("min", 1))), int(event.get("max", 0))):
		return {"indices": chosen}
	return {"cancel": true}


static func _search_sum(cards: Array, index: int, remaining: int, chosen: Array[int],
		minimum: int, maximum: int) -> bool:
	if remaining == 0:
		return chosen.size() >= minimum and (maximum <= 0 or chosen.size() <= maximum)
	if remaining < 0 or index >= cards.size():
		return false
	if maximum > 0 and chosen.size() >= maximum:
		return false

	var param: int = int((cards[index] as Dictionary).get("sum_param", 0))
	var options: Array[int] = [param & 0xffff, (param >> 16) & 0xffff]
	for option: int in options:
		if option <= 0:
			continue
		chosen.append(index)
		if _search_sum(cards, index + 1, remaining - option, chosen, minimum, maximum):
			return true
		chosen.pop_back()
		if options[0] == options[1]:
			break

	return _search_sum(cards, index + 1, remaining, chosen, minimum, maximum)
