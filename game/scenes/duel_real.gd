extends SceneTree

## Phase 1 integration check against the real card database.
##
##   make duel-real
##
## Unlike `duel_smoke.gd`, this one loads `data/base/cards.cdb` and plays a scripted opening:
## normal summon, choose a zone, pass to battle, attack directly. It is the first test where
## ocgcore knows what the cards actually are, so level, type and ATK all matter.
##
## Lua card scripts are still absent (docs/DATA.md), so effects do not fire. Vanilla monsters
## have no effects anyway, which is exactly why the deck below is all vanilla.

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"
## Searched in order. The library scripts (constant.lua, utility.lua, proc_*.lua) sit at the
## repository root; card scripts live in the three collection folders below it.
const SCRIPT_ROOTS: Array[String] = [
	"res://../data/base/script",
	"res://../data/base/script/official",
	"res://../data/base/script/unofficial",
	"res://../data/base/script/pre-release",
]

## Level 4 vanilla beaters: summonable with no tribute and no effects to misfire.
const BEATERS: Array[int] = [11091375, 14898066, 33256280, 35052053]
## Level 8 vanilla, needs two tributes. Present so the deck is not uniform.
const BIG: int = 89631139
## Pot of Greed. A scripted card on purpose: if the Lua collection is missing or the library
## scripts never loaded, it simply never appears as activatable and the check below fails.
const POT_OF_GREED: int = 55144522

const DECK_SIZE: int = 40
const POLL_BUDGET: int = 4000

var _core: Object = null
var _pending: Dictionary = {}
var _has_summoned: bool = false
var _attacked: bool = false
var _activated_pot: bool = false
var _effect_draw: int = 0
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
	print("[real] card database loaded: %d cards" % loaded["count"])
	for root: String in SCRIPT_ROOTS:
		_core.add_script_root(root)

	var deck: PackedInt32Array = PackedInt32Array()
	for i in DECK_SIZE:
		if i % 10 == 0:
			deck.append(BIG)
		elif i % 5 == 0:
			deck.append(POT_OF_GREED)
		else:
			deck.append(BEATERS[i % BEATERS.size()])

	var started: Dictionary = _core.start_duel({
		"start_lp": 8000, "start_hand": 5, "draw_count": 1,
		"deck_p0": deck, "deck_p1": deck,
	})
	if not started["ok"]:
		push_error("start_duel failed: %s" % started["error"])
		quit(1)
		return
	print("[real] duel started")

	_run()
	_report()


## Answers whatever selection the engine parks on, dispatched by type rather than by a fixed
## step counter.
##
## Step counting was the first attempt and it was wrong: after a normal summon ocgcore gives the
## opponent priority with MSG_SELECT_CHAIN before returning to the idle prompt. Any plan that
## assumes a fixed sequence of selections will desynchronise the moment the engine inserts one.
func _plan(event_type: int, event: Dictionary) -> Dictionary:
	match event_type:
		DuelEnums.EV.SELECT_CHAIN:
			# Decline to respond. The engine only accepts -1 when the chain was not forced;
			# a forced one has to be answered with a real index.
			if bool(event.get("forced", false)):
				return {"index": 0}
			return {"cancel": true}

		DuelEnums.EV.SELECT_IDLECMD:
			# Activating a scripted card is the real proof that the Lua collection loaded.
			var activate: Array = event.get("activate", [])
			if not _activated_pot:
				_expect(activate.size() > 0,
					"a scripted card in hand is activatable, so card scripts ran (got %d)" % activate.size())
				if activate.size() > 0:
					_activated_pot = true
					return {"cmd": "activate", "index": 0}
			if not _has_summoned:
				var summon: Array = event.get("summon", [])
				_expect(summon.size() > 0, "a level 4 vanilla in hand is summonable (got %d)" % summon.size())
				if summon.is_empty():
					return {"cmd": "to_ep"}
				_has_summoned = true
				return {"cmd": "summon", "index": 0}
			if bool(event.get("to_bp", false)):
				return {"cmd": "to_bp"}
			return {"cmd": "to_ep"}

		DuelEnums.EV.SELECT_PLACE:
			return _pick_place(event)

		DuelEnums.EV.SELECT_POSITION:
			return {"position": 0x1} # face-up attack

		DuelEnums.EV.SELECT_BATTLECMD:
			var attack: Array = event.get("attack", [])
			if attack.is_empty():
				return {"cmd": "to_ep"}
			_attacked = true
			return {"cmd": "attack", "index": 0}

		DuelEnums.EV.SELECT_EFFECTYN, DuelEnums.EV.SELECT_YESNO:
			return {"answer": 0}

	_fail("no plan for selection type %d" % event_type)
	return {}


## Picks the first legal zone out of the request's own mask.
##
## Hardcoding a monster zone is what the first version did, and it fails the moment the
## selection is for a spell: the engine answers MSG_RETRY and, because a retry does not
## re-send the selection, the duel looks hung. See AGENTS.md section 8b trap 9 for the layout.
func _pick_place(event: Dictionary) -> Dictionary:
	var flag: int = int(event.get("flag", 0))
	var me: int = int(event.get("player", 0))

	for seq: int in range(7):
		if (flag & (1 << seq)) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.MZONE, "seq": seq}], "count": 1}
	for seq: int in range(8):
		if (flag & (1 << (8 + seq))) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.SZONE, "seq": seq}], "count": 1}

	_fail("SELECT_PLACE offered no free zone on our side (flag 0x%x)" % flag)
	return {}


func _run() -> void:
	var polls: int = 0
	var summoned_code: int = 0
	var damage_dealt: int = 0

	while polls < POLL_BUDGET:
		var event: Variant = _core.poll_event()
		if event == null:
			polls += 1
			OS.delay_msec(2)
			continue

		var t: int = event["t"]
		# Core log noise: no Lua scripts, so every card reports a missing initial_effect.
		if t == 1002 or t == 1003:
			continue

		match t:
			DuelEnums.EV.MOVE:
				var to: Dictionary = event.get("to", {})
				if int(to.get("loc", 0)) == DuelEnums.LOCATION.MZONE:
					summoned_code = int(event["card"])
					print("[real] MOVE  card %d -> MZONE seq %d" % [summoned_code, int(to.get("seq", -1))])
			DuelEnums.EV.SUMMONED:
				print("[real] SUMMONED")
			DuelEnums.EV.ATTACK:
				print("[real] ATTACK direct=%s" % str(event.get("direct", false)))
			DuelEnums.EV.DRAW:
				if _activated_pot and _effect_draw == 0 and int(event["player"]) == 0:
					_effect_draw = int(event["count"])
					print("[real] DRAW from a card effect: %d cards" % _effect_draw)
			DuelEnums.EV.DAMAGE:
				damage_dealt = int(event["amount"])
				print("[real] DAMAGE player %d takes %d" % [int(event["player"]), damage_dealt])
			DuelEnums.EV.RETRY:
				_fail("ocgcore rejected a response; the last answer was malformed for its selection")
				return

		if t < 10 or t > 26:
			continue

		# A selection. Answer it from the plan.
		_pending = event
		var answer: Dictionary = _plan(t, event)
		if answer.is_empty():
			print("[real] no answer for selection %d; stopping" % t)
			break
		var responded: Dictionary = _core.respond(t, answer)
		if not responded["ok"]:
			_fail("respond(%d, %s) failed: %s" % [t, str(answer), responded["error"]])
			return
		polls = 0
		if _attacked and damage_dealt > 0:
			break

	_expect(_activated_pot, "a scripted card was offered and activated")
	_expect(_effect_draw == 2, "the activated effect drew exactly 2 (got %d)" % _effect_draw)
	_expect(_has_summoned, "the idle prompt offered a normal summon")
	_expect(summoned_code != 0, "a monster reached the monster zone")
	_expect(damage_dealt == 1900, "a direct attack by a 1900 ATK beater dealt 1900 (got %d)" % damage_dealt)


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("  PASS  %s" % what)
	else:
		_fail(what)


func _fail(what: String) -> void:
	print("  FAIL  %s" % what)
	_failures.append(what)


func _report() -> void:
	_core.end_duel()
	if _failures.is_empty():
		print("[real] all checks passed")
		quit(0)
	else:
		print("[real] %d check(s) failed" % _failures.size())
		quit(1)
