extends SceneTree

## Selector coverage against the real card collection.
##
##   make test-selectors
##
## `ResponseBuilder` implements twelve selections, but only four of them were ever reached by a
## running duel: the rest were written by reading ocgcore's `else` branches and had no way to be
## executed, because a duel of vanilla monsters never prompts for them.
##
## Each scenario below builds a deck whose only purpose is to force one specific prompt, then
## asserts the engine both asked and accepted the answer. A selection that is answered wrongly
## comes back as MSG_RETRY, which is silent (AGENTS.md section 8b trap 8), so the retry counter
## is itself an assertion.

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"
const SCRIPT_ROOTS: Array[String] = [
	"res://../data/base/script",
	"res://../data/base/script/official",
	"res://../data/base/script/unofficial",
	"res://../data/base/script/pre-release",
]

# Level 4 vanillas: summonable with no tribute, no effects to interfere.
const BEATER_A: int = 11091375 # Luster Dragon
const BEATER_B: int = 14898066 # Vorse Raider
# Level 8 vanilla: needs two tributes, which is what makes SELECT_TRIBUTE appear.
const BLUE_EYES: int = 89631139
# Sends one monster from the deck to the graveyard: SELECT_CARD over a hidden zone.
const FOOLISH_BURIAL: int = 81439173
# Ritual pair. proc_ritual.lua picks tributes with Group.SelectWithSumEqual, which is the only
# path in the whole collection that reaches MSG_SELECT_SUM. The monster is Level 8, so two
# Level 4 beaters are a valid, non-obvious sum.
const RITUAL_SPELL: int = 94377247 # Curse of the Masked Beast
const RITUAL_MONSTER: int = 49064413 # The Masked Beast, Level 8

const POLL_BUDGET: int = 6000

var _core: Object = null
var _seen: Dictionary = {}
var _retries: int = 0
var _failures: PackedStringArray = PackedStringArray()


func _init() -> void:
	_core = ClassDB.instantiate(CORE_CLASS)
	if _core == null:
		push_error("KaibaCore is not registered; the GDExtension did not load.")
		quit(1)
		return

	var loaded: Dictionary = _core.load_card_database(CDB_PATH)
	if not loaded["ok"]:
		push_error("could not load %s: %s" % [CDB_PATH, loaded["error"]])
		quit(1)
		return
	for root: String in SCRIPT_ROOTS:
		_core.add_script_root(root)
	print("[sel] database: %d cards" % loaded["count"])

	_scenario("tribute summon", _deck_tribute(), [DuelEnums.EV.SELECT_TRIBUTE])
	_scenario("deck search", _deck_search(), [DuelEnums.EV.SELECT_CARD])
	_scenario("ritual summon", _deck_ritual(), [DuelEnums.EV.SELECT_SUM, DuelEnums.EV.SELECT_POSITION])

	_report()


# --------------------------------------------------------------------------------------------
# Decks
# --------------------------------------------------------------------------------------------

func _deck_tribute() -> PackedInt32Array:
	var deck: PackedInt32Array = PackedInt32Array()
	for i in 40:
		deck.append(BLUE_EYES if i % 4 == 0 else (BEATER_A if i % 2 == 0 else BEATER_B))
	return deck


func _deck_search() -> PackedInt32Array:
	var deck: PackedInt32Array = PackedInt32Array()
	for i in 40:
		deck.append(FOOLISH_BURIAL if i % 3 == 0 else BEATER_A)
	return deck


func _deck_ritual() -> PackedInt32Array:
	var deck: PackedInt32Array = PackedInt32Array()
	for i in 40:
		if i % 4 == 0:
			deck.append(RITUAL_SPELL)
		elif i % 4 == 1:
			deck.append(RITUAL_MONSTER)
		else:
			deck.append(BEATER_A if i % 2 == 0 else BEATER_B)
	return deck


# --------------------------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------------------------

func _scenario(label: String, deck: PackedInt32Array, wanted: Array) -> void:
	var started: Dictionary = _core.start_duel({
		"start_lp": 8000, "start_hand": 5, "draw_count": 1,
		"deck_p0": deck, "deck_p1": deck,
	})
	if not started["ok"]:
		_fail("%s: start_duel failed: %s" % [label, started["error"]])
		return

	var before: int = _retries
	var found: Dictionary = {}
	var polls: int = 0

	while polls < POLL_BUDGET:
		var event: Variant = _core.poll_event()
		if event == null:
			polls += 1
			OS.delay_msec(1)
			continue

		var t: int = event["t"]
		if t == 1002 or t == 1003:
			continue
		if t == DuelEnums.EV.RETRY:
			_retries += 1
			continue
		if t == DuelEnums.EV.WIN:
			break
		if t < 10 or t > 26:
			continue

		_seen[t] = int(_seen.get(t, 0)) + 1
		found[t] = true

		var answer: Dictionary = _answer(t, event)
		if answer.is_empty():
			break
		var responded: Dictionary = _core.respond(t, answer)
		if not responded["ok"]:
			_fail("%s: respond(%d) rejected the intent: %s" % [label, t, responded["error"]])
			break
		polls = 0

		if wanted.all(func(w: int) -> bool: return found.has(w)):
			break

	_core.end_duel()

	for want: int in wanted:
		_check(found.has(want), "%s reached %s" % [label, _name_of(want)])
	_check(_retries == before, "%s produced no MSG_RETRY (engine accepted every answer)" % label)


## Answers any selection sensibly. This is the seed of a real agent, not just test plumbing:
## every branch is a decision a player has to make.
func _answer(t: int, event: Dictionary) -> Dictionary:
	match t:
		DuelEnums.EV.SELECT_CHAIN:
			return {"index": 0} if bool(event.get("forced", false)) else {"cancel": true}

		DuelEnums.EV.SELECT_IDLECMD:
			# Activating comes first: every scenario here is driven by a card effect.
			if not (event.get("activate", []) as Array).is_empty():
				return {"cmd": "activate", "index": 0}
			var summon: Array = event.get("summon", [])
			if not summon.is_empty():
				# Prefer the tribute summon when the engine offers it; that is the whole
				# point of the first scenario, and it only appears once two monsters are out.
				for i in summon.size():
					if int((summon[i] as Dictionary).get("card", 0)) == BLUE_EYES:
						return {"cmd": "summon", "index": i}
				return {"cmd": "summon", "index": 0}
			return {"cmd": "to_ep"}

		DuelEnums.EV.SELECT_BATTLECMD:
			return {"cmd": "to_ep"}

		DuelEnums.EV.SELECT_PLACE:
			return _pick_place(event)

		DuelEnums.EV.SELECT_POSITION:
			# Answer with a bit the request actually offered; anything else is rejected.
			var offered: int = int(event.get("positions", 0x1))
			for bit: int in [0x1, 0x4, 0x2, 0x8]:
				if (offered & bit) != 0:
					return {"position": bit}
			return {"position": 0x1}

		DuelEnums.EV.SELECT_CARD, DuelEnums.EV.SELECT_TRIBUTE:
			return _pick_cards(event)

		DuelEnums.EV.SELECT_SUM:
			return _solve_sum(event)

		DuelEnums.EV.SELECT_EFFECTYN, DuelEnums.EV.SELECT_YESNO:
			return {"answer": 1}

		DuelEnums.EV.SELECT_OPTION:
			return {"index": 0}

		DuelEnums.EV.SORT_CARD:
			return {"cancel": true}

	_fail("no answer written for selection %d" % t)
	return {}


## Takes the fewest cards the request will accept, lowest indices first.
##
## For SELECT_SUM the indices address the *selectable* list only: the engine prepends the
## must-select cards itself, so concatenating the two lists for display and answering with
## those indices is an off-by-N waiting to happen.
func _pick_cards(event: Dictionary) -> Dictionary:
	var cards: Array = event.get("cards", [])
	var minimum: int = maxi(1, int(event.get("min", 1)))
	var indices: Array[int] = []
	for i in mini(minimum, cards.size()):
		indices.append(i)
	if indices.is_empty():
		return {"cancel": true}
	return {"indices": indices}


## Chooses cards whose parameters land exactly on the requested total.
##
## Counting to `min` and answering with the first indices is not enough here, and the engine
## says so only through MSG_RETRY. Two details make it harder than it looks:
##
##   - `must` cards are added by the engine itself and are not addressable by the answer, but
##     they do count toward the total, so subtract them first.
##   - `sum_param` packs two alternatives, low and high 16 bits (`field.cpp:2619`). A card
##     whose Level may be treated as either value contributes whichever one fits.
func _solve_sum(event: Dictionary) -> Dictionary:
	var target: int = int(event.get("acc", 0))
	for entry: Variant in event.get("must", []):
		target -= int((entry as Dictionary).get("sum_param", 0)) & 0xffff

	var cards: Array = event.get("cards", [])
	var min_n: int = maxi(1, int(event.get("min", 1)))
	var max_n: int = int(event.get("max", 0))

	var chosen: Array[int] = []
	if target > 0 and _dfs_sum(cards, 0, target, chosen, min_n, max_n):
		return {"indices": chosen}

	_fail("no subset of the offered cards sums to %d" % target)
	return {"cancel": true}


func _dfs_sum(cards: Array, i: int, remaining: int, chosen: Array[int], min_n: int, max_n: int) -> bool:
	if remaining == 0:
		return chosen.size() >= min_n and (max_n <= 0 or chosen.size() <= max_n)
	if remaining < 0 or i >= cards.size():
		return false
	if max_n > 0 and chosen.size() >= max_n:
		return false

	var param: int = int((cards[i] as Dictionary).get("sum_param", 0))
	var options: Array[int] = [param & 0xffff, (param >> 16) & 0xffff]
	for opt: int in options:
		if opt <= 0:
			continue
		chosen.append(i)
		if _dfs_sum(cards, i + 1, remaining - opt, chosen, min_n, max_n):
			return true
		chosen.pop_back()
		if options[0] == options[1]:
			break

	return _dfs_sum(cards, i + 1, remaining, chosen, min_n, max_n)


## Picks the first zone the request's own mask leaves open. See AGENTS.md section 8b trap 9.
func _pick_place(event: Dictionary) -> Dictionary:
	var flag: int = int(event.get("flag", 0))
	var me: int = int(event.get("player", 0))
	for seq: int in range(7):
		if (flag & (1 << seq)) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.MZONE, "seq": seq}], "count": 1}
	for seq: int in range(8):
		if (flag & (1 << (8 + seq))) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.SZONE, "seq": seq}], "count": 1}
	_fail("SELECT_PLACE offered no free zone (flag 0x%x)" % flag)
	return {}


# --------------------------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------------------------

func _name_of(t: int) -> String:
	for key: String in DuelEnums.EV.keys():
		if DuelEnums.EV[key] == t:
			return key
	return str(t)


func _check(condition: bool, what: String) -> void:
	if condition:
		print("  PASS  %s" % what)
	else:
		_fail(what)


func _fail(what: String) -> void:
	print("  FAIL  %s" % what)
	_failures.append(what)


func _report() -> void:
	print("[sel] selections exercised against live ocgcore:")
	var names: Array[String] = []
	for t: int in _seen.keys():
		names.append("%s x%d" % [_name_of(t), int(_seen[t])])
	names.sort()
	for n: String in names:
		print("        %s" % n)
	if _failures.is_empty():
		print("[sel] all checks passed")
		quit(0)
	else:
		print("[sel] %d check(s) failed" % _failures.size())
		quit(1)
