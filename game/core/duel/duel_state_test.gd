extends SceneTree

## Self-checking tests for the L3 duel model. No framework, no dependencies, no scene tree.
##
##   godot --headless --path game --script res://core/duel/duel_state_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, so it can be wired into
## a Makefile target as a gate.
##
## Every event fed in below is shaped exactly the way `native/src/msg_parser.cpp` emits it -
## that file is the authority on field names, and a test written against a guessed shape would
## pass while the real duel broke. The one exception is START, which ocgcore never emits at all
## (AGENTS.md section 8b.1): the host synthesises it, so its shape is defined by `DuelState`.
##
## EXPECTED NOISE: the V13 case deliberately feeds unimplemented and malformed events, so a
## handful of WARNING lines in the output are the test working, not failing.

var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0

var _translator: EventTranslator = EventTranslator.new()


func _init() -> void:
	print("== DuelState / EventTranslator tests ==")

	_case_start()
	_case_opening_draw()
	_case_move_hand_to_monster_zone()
	_case_move_monster_to_graveyard()
	_case_pos_change()
	_case_life_points()
	_case_phase_and_turn()
	_case_unknown_event()

	_case_translate_summon_move()
	_case_translate_reason_precedence()
	_case_translate_draw()
	_case_translate_pos_change_flip()
	_case_translate_attack()
	_case_translate_battle()
	_case_translate_life_points()
	_case_translate_anchors()
	_case_translate_ignored()

	print("== %d cases, %d failed ==" % [_cases_run, _cases_failed])
	quit(1 if _cases_failed > 0 else 0)


# ----------------------------------------------------------------------------------------------
# DuelState
# ----------------------------------------------------------------------------------------------

func _case_start() -> void:
	_begin("start sets life points, deck sizes and the first player")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(1))

	_equal("life points p0", state.life_points[0], 8000)
	_equal("life points p1", state.life_points[1], 8000)
	_equal("deck p0", state.deck[0].size(), 40)
	_equal("deck p1", state.deck[1].size(), 40)
	_equal("extra deck p0", state.extra_deck[0].size(), 0)
	_equal("turn player", state.turn_player, 1)
	_equal("turn count", state.turn_count, 0)
	_equal("hand p0", state.hand[0].size(), 0)
	_equal("not finished", state.is_finished, false)
	_equal("main monster zones", state.main_monster[0].size(), 5)
	_equal("extra monster zones", state.extra_monster[0].size(), 2)
	_equal("spell trap zones", state.spell_trap[0].size(), 5)
	_end()


func _case_opening_draw() -> void:
	_begin("opening draw moves five cards per player out of the deck")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))
	state.apply(_event_draw(0, [1001, 1002, 1003, 1004, 1005]))
	# The host blanks what this viewer may not see (V7), so the opponent's draw arrives as
	# five zeroed codes rather than as no event at all.
	state.apply(_event_draw(1, [0, 0, 0, 0, 0]))

	_equal("hand p0", state.hand[0].size(), 5)
	_equal("hand p1", state.hand[1].size(), 5)
	_equal("deck p0", state.deck[0].size(), 35)
	_equal("deck p1", state.deck[1].size(), 35)

	var first: DuelCard = state.hand[0][0] as DuelCard
	_equal("first drawn code", first.code, 1001)
	_equal("first drawn location", first.location, DuelEnums.LOCATION.HAND)
	_equal("first drawn controller", first.controller, 0)
	_equal("first drawn sequence", first.sequence, 0)
	_equal("first drawn is public", first.is_public, true)
	_equal("last drawn sequence", (state.hand[0][4] as DuelCard).sequence, 4)

	var hidden: DuelCard = state.hand[1][0] as DuelCard
	_equal("opponent card code", hidden.code, 0)
	_equal("opponent card is not public", hidden.is_public, false)
	_end()


func _case_move_hand_to_monster_zone() -> void:
	_begin("hand to monster zone move summons and resequences the hand")
	var state: DuelState = _state_with_hand()
	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 2, DuelEnums.POSITION.FACEDOWN_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.SUMMON,
	})

	_equal("hand shrank", state.hand[0].size(), 4)

	var summoned: DuelCard = state.card_at(0, DuelEnums.LOCATION.MZONE, 1)
	_check("monster zone 1 is occupied", summoned != null, "card_at returned null")
	if summoned != null:
		_equal("summoned code", summoned.code, 1003)
		_equal("summoned controller", summoned.controller, 0)
		_equal("summoned location", summoned.location, DuelEnums.LOCATION.MZONE)
		_equal("summoned sequence", summoned.sequence, 1)
		_equal("summoned position", summoned.position, DuelEnums.POSITION.FACEUP_ATTACK)
		_equal("summoned is public", summoned.is_public, true)

	_check("monster zone 0 still empty", state.card_at(0, DuelEnums.LOCATION.MZONE, 0) == null, "zone 0 was filled")
	_equal("hand codes after move", _codes(state.hand[0]), [1001, 1002, 1004, 1005])
	_equal("hand resequenced", _sequences(state.hand[0]), [0, 1, 2, 3])
	_end()


func _case_move_monster_to_graveyard() -> void:
	_begin("destroyed monster leaves the zone and lands in the graveyard")
	var state: DuelState = _state_with_monster()
	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEUP_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.GRAVE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.DESTROY | DuelEnums.REASON.BATTLE,
	})

	_check("monster zone 1 emptied", state.card_at(0, DuelEnums.LOCATION.MZONE, 1) == null, "zone still occupied")
	_equal("graveyard size", state.graveyard[0].size(), 1)
	if state.graveyard[0].size() == 1:
		var buried: DuelCard = state.graveyard[0][0] as DuelCard
		_equal("graveyard code", buried.code, 1003)
		_equal("graveyard location", buried.location, DuelEnums.LOCATION.GRAVE)
		_equal("graveyard sequence", buried.sequence, 0)
	_end()


func _case_pos_change() -> void:
	_begin("position change rewrites the card in place")
	var state: DuelState = _state_with_monster()

	# Wire shape: msg_parser.cpp normalises the loose controller/location/byte-sequence triple
	# into "at", and repeats the new position at the top level as "pos".
	state.apply({
		"t": DuelEnums.EV.POS_CHANGE,
		"card": 1003,
		"at": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEUP_DEFENSE),
		"prev_pos": DuelEnums.POSITION.FACEUP_ATTACK,
		"pos": DuelEnums.POSITION.FACEUP_DEFENSE,
	})

	var card: DuelCard = state.card_at(0, DuelEnums.LOCATION.MZONE, 1)
	_check("card still in zone", card != null, "card_at returned null")
	if card != null:
		_equal("position after change", card.position, DuelEnums.POSITION.FACEUP_DEFENSE)
		_equal("still public", card.is_public, true)

	# Face-down to face-up: the reveal must flip is_public too.
	state.apply({
		"t": DuelEnums.EV.POS_CHANGE,
		"card": 1003,
		"at": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEDOWN_DEFENSE),
		"prev_pos": DuelEnums.POSITION.FACEUP_DEFENSE,
		"pos": DuelEnums.POSITION.FACEDOWN_DEFENSE,
	})
	card = state.card_at(0, DuelEnums.LOCATION.MZONE, 1)
	_equal("face-down position", card.position, DuelEnums.POSITION.FACEDOWN_DEFENSE)
	_equal("face-down is not public", card.is_public, false)

	# The flattened spelling is still accepted, so a hand-written event or an older host does
	# not silently become a no-op.
	state.apply({
		"t": DuelEnums.EV.POS_CHANGE,
		"card": 1003,
		"con": 0,
		"loc": DuelEnums.LOCATION.MZONE,
		"seq": 1,
		"prev_pos": DuelEnums.POSITION.FACEDOWN_DEFENSE,
		"pos": DuelEnums.POSITION.FACEUP_ATTACK,
	})
	card = state.card_at(0, DuelEnums.LOCATION.MZONE, 1)
	_equal("flattened form applied", card.position, DuelEnums.POSITION.FACEUP_ATTACK)
	_end()


func _case_life_points() -> void:
	_begin("damage, recovery and absolute life point updates")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))

	state.apply({"t": DuelEnums.EV.DAMAGE, "player": 0, "amount": 1200})
	_equal("after damage", state.life_points[0], 6800)
	_equal("other player untouched", state.life_points[1], 8000)

	state.apply({"t": DuelEnums.EV.RECOVER, "player": 0, "amount": 300})
	_equal("after recover", state.life_points[0], 7100)

	# LPUPDATE is the new total, not a delta (libduel.cpp Duel.SetLP).
	state.apply({"t": DuelEnums.EV.LPUPDATE, "player": 1, "lp": 4000})
	_equal("after absolute update", state.life_points[1], 4000)

	# Overkill damage clamps at zero rather than going negative; ocgcore reports the loss
	# separately with WIN.
	state.apply({"t": DuelEnums.EV.DAMAGE, "player": 1, "amount": 99999})
	_equal("clamped at zero", state.life_points[1], 0)
	_equal("still not finished", state.is_finished, false)
	_end()


func _case_phase_and_turn() -> void:
	_begin("phase and turn markers advance the clock")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))

	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": 0})
	_equal("turn count after first turn", state.turn_count, 1)
	_equal("turn player", state.turn_player, 0)

	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.DRAW})
	_equal("draw phase", state.phase, DuelEnums.PHASE.DRAW)

	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.MAIN1})
	_equal("main phase 1", state.phase, DuelEnums.PHASE.MAIN1)

	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": 1})
	_equal("turn count after second turn", state.turn_count, 2)
	_equal("turn player handed over", state.turn_player, 1)
	_end()


## V13: an opcode nobody taught DuelState about warns once and changes nothing.
func _case_unknown_event() -> void:
	_begin("unknown events warn and never mutate the board (V13)")
	print("        (WARNING lines below are expected)")
	var state: DuelState = _state_with_monster()
	var before: String = JSON.stringify(state.snapshot())

	# A real opcode that is simply not implemented yet.
	state.apply({"t": DuelEnums.EV.EQUIP, "card": 1003, "at": _loc(0, DuelEnums.LOCATION.SZONE, 0)})
	_equal("board unchanged after EQUIP", JSON.stringify(state.snapshot()), before)
	_check("EQUIP warned", state._warned_types.has(DuelEnums.EV.EQUIP), "no warning recorded")

	# An opcode that is not in the table at all.
	state.apply({"t": 31337, "whatever": true})
	_equal("board unchanged after nonsense opcode", JSON.stringify(state.snapshot()), before)
	_check("nonsense opcode warned", state._warned_types.has(31337), "no warning recorded")

	# A malformed event with no type tag.
	state.apply({})
	_equal("board unchanged after typeless event", JSON.stringify(state.snapshot()), before)
	_check("typeless event warned", state._warned_types.has(-1), "no warning recorded")

	# A passive event is expected and must NOT warn, otherwise the warning stops meaning
	# anything. HINT drives the UI, not the board.
	state.apply({"t": DuelEnums.EV.HINT, "hint_type": 1, "player": 0, "data": 27})
	_equal("board unchanged after HINT", JSON.stringify(state.snapshot()), before)
	_check("HINT did not warn", not state._warned_types.has(DuelEnums.EV.HINT), "passive event warned")
	_end()


# ----------------------------------------------------------------------------------------------
# EventTranslator
# ----------------------------------------------------------------------------------------------

func _case_translate_summon_move() -> void:
	_begin("translate: hand to monster zone with REASON.SUMMON becomes a SUMMON intent")
	var intents: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.MOVE,
		"card": 89631139,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 2, DuelEnums.POSITION.FACEDOWN_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 2, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.SUMMON,
	})

	_equal("one intent", intents.size(), 1)
	if intents.size() != 1:
		_end()
		return
	var intent: Dictionary = intents[0]
	_equal("kind", intent.get("kind", ""), EventTranslator.KIND_SUMMON)
	_equal("card id", intent.get("card_id", 0), 89631139)
	_equal("from anchor", intent.get("from_anchor", ""), "HAND_P0")
	_equal("to anchor", intent.get("to_anchor", ""), "MZ_P0_2")
	_equal("face", intent.get("face", ""), "UP_ATK")
	_equal("blocking", intent.get("blocking", false), true)
	_equal("player", intent.get("player", -1), 0)
	_equal("provenance", intent.get("ev", 0), DuelEnums.EV.MOVE)
	_check("no visual resource leaked into L3 (V2/V12)", not intent.has("visual"), "intent carries a visual")
	_end()


## RELEASE must beat SUMMON: a tribute summon's material arrives as RELEASE | SUMMON, and
## classifying it as a summon would animate the tributed monster as if it were being played.
func _case_translate_reason_precedence() -> void:
	_begin("translate: REASON precedence puts tribute before summon")
	var tribute: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.GRAVE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.RELEASE | DuelEnums.REASON.SUMMON,
	})
	_equal("tribute kind", tribute[0].get("kind", ""), EventTranslator.KIND_TRIBUTE)

	var destroyed: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.GRAVE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.DESTROY | DuelEnums.REASON.BATTLE,
	})
	_equal("destroy kind", destroyed[0].get("kind", ""), EventTranslator.KIND_DESTROY)

	var returned: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.HAND, 0, 0),
		"reason": DuelEnums.REASON.RETURN,
	})
	_equal("destination fallback kind", returned[0].get("kind", ""), EventTranslator.KIND_TO_HAND)

	var token: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.MOVE,
		"card": 0,
		"from": _loc(0, 0, 0, 0),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 3, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.RULE,
	})
	_equal("created from nowhere", token[0].get("kind", ""), EventTranslator.KIND_CREATE)
	_equal("nowhere anchor", token[0].get("from_anchor", ""), "NOWHERE")
	_end()


func _case_translate_draw() -> void:
	_begin("translate: one intent per drawn card, only the last one blocks")
	var intents: Array[Dictionary] = _translator.translate(_event_draw(1, [0, 0, 0]))

	_equal("three intents", intents.size(), 3)
	if intents.size() != 3:
		_end()
		return
	_equal("kind", intents[0].get("kind", ""), EventTranslator.KIND_DRAW)
	_equal("from anchor", intents[0].get("from_anchor", ""), "DECK_P1")
	_equal("to anchor", intents[0].get("to_anchor", ""), "HAND_P1")
	_equal("first index", intents[0].get("index", -1), 0)
	_equal("count", intents[0].get("count", 0), 3)
	_equal("first does not block", intents[0].get("blocking", true), false)
	_equal("second does not block", intents[1].get("blocking", true), false)
	_equal("last blocks", intents[2].get("blocking", false), true)
	_end()


func _case_translate_pos_change_flip() -> void:
	_begin("translate: face-down to face-up is a FLIP, everything else a POS_CHANGE")
	var flip: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.POS_CHANGE,
		"card": 1003,
		"at": _loc(0, DuelEnums.LOCATION.MZONE, 4, DuelEnums.POSITION.FACEUP_ATTACK),
		"prev_pos": DuelEnums.POSITION.FACEDOWN_DEFENSE,
		"pos": DuelEnums.POSITION.FACEUP_ATTACK,
	})
	_equal("flip kind", flip[0].get("kind", ""), EventTranslator.KIND_FLIP)
	_equal("flip anchor", flip[0].get("anchor", ""), "MZ_P0_4")
	_equal("flip from face", flip[0].get("from_face", ""), "DOWN_DEF")
	_equal("flip to face", flip[0].get("face", ""), "UP_ATK")

	var turn: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.POS_CHANGE,
		"card": 1003,
		"at": _loc(1, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_DEFENSE),
		"prev_pos": DuelEnums.POSITION.FACEUP_ATTACK,
		"pos": DuelEnums.POSITION.FACEUP_DEFENSE,
	})
	_equal("reposition kind", turn[0].get("kind", ""), EventTranslator.KIND_POS_CHANGE)
	_equal("reposition anchor", turn[0].get("anchor", ""), "MZ_P1_0")
	_end()


func _case_translate_attack() -> void:
	_begin("translate: direct attack targets the player, otherwise the defending zone")
	var direct: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.ATTACK,
		"from": _loc(1, DuelEnums.LOCATION.MZONE, 2, DuelEnums.POSITION.FACEUP_ATTACK),
		"direct": true,
	})
	_equal("attack kind", direct[0].get("kind", ""), EventTranslator.KIND_ATTACK)
	_equal("attacker anchor", direct[0].get("from_anchor", ""), "MZ_P1_2")
	_equal("direct target", direct[0].get("to_anchor", ""), "PLAYER_P0")
	_equal("direct flag", direct[0].get("direct", false), true)

	var targeted: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.ATTACK,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"direct": false,
		"to": _loc(1, DuelEnums.LOCATION.MZONE, 3, DuelEnums.POSITION.FACEUP_DEFENSE),
	})
	_equal("defender anchor", targeted[0].get("to_anchor", ""), "MZ_P1_3")
	_equal("not direct", targeted[0].get("direct", true), false)
	_end()


func _case_translate_battle() -> void:
	_begin("translate: battle carries both combatants' numbers")
	var intents: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.BATTLE,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEUP_ATTACK),
		"from_atk": 3000,
		"from_def": 2500,
		"from_destroyed": false,
		"direct": false,
		"to": _loc(1, DuelEnums.LOCATION.MZONE, 2, DuelEnums.POSITION.FACEUP_ATTACK),
		"to_atk": 1800,
		"to_def": 1500,
		"to_destroyed": true,
	})
	_equal("battle kind", intents[0].get("kind", ""), EventTranslator.KIND_BATTLE)
	_equal("attacker attack", intents[0].get("from_attack", 0), 3000)
	_equal("attacker survives", intents[0].get("from_destroyed", true), false)
	_equal("defender attack", intents[0].get("to_attack", 0), 1800)
	_equal("defender destroyed", intents[0].get("to_destroyed", false), true)
	_equal("battle blocks", intents[0].get("blocking", false), true)
	_end()


func _case_translate_life_points() -> void:
	_begin("translate: damage and recovery carry a delta, LPUPDATE an absolute value")
	var damage: Array[Dictionary] = _translator.translate({"t": DuelEnums.EV.DAMAGE, "player": 0, "amount": 1200})
	_equal("damage kind", damage[0].get("kind", ""), EventTranslator.KIND_LP_CHANGE)
	_equal("damage mode", damage[0].get("mode", ""), EventTranslator.LP_DAMAGE)
	_equal("damage delta", damage[0].get("delta", 0), -1200)
	_equal("damage anchor", damage[0].get("anchor", ""), "PLAYER_P0")

	var recover: Array[Dictionary] = _translator.translate({"t": DuelEnums.EV.RECOVER, "player": 1, "amount": 500})
	_equal("recover mode", recover[0].get("mode", ""), EventTranslator.LP_RECOVER)
	_equal("recover delta", recover[0].get("delta", 0), 500)

	var absolute: Array[Dictionary] = _translator.translate({"t": DuelEnums.EV.LPUPDATE, "player": 1, "lp": 4000})
	_equal("update mode", absolute[0].get("mode", ""), EventTranslator.LP_SET)
	_equal("update value", absolute[0].get("value", 0), 4000)
	_check("no delta on an absolute update", not absolute[0].has("delta"), "delta was invented")
	_end()


func _case_translate_anchors() -> void:
	_begin("translate: anchor grammar covers extra zones, field zone and xyz materials")
	_equal("extra monster zone", EventTranslator.anchor_of(_loc(0, DuelEnums.LOCATION.MZONE, 5, 0)), "EMZ_P0_0")
	_equal("spell trap zone", EventTranslator.anchor_of(_loc(1, DuelEnums.LOCATION.SZONE, 3, 0)), "ST_P1_3")
	_equal("field zone", EventTranslator.anchor_of(_loc(1, DuelEnums.LOCATION.SZONE, 5, 0)), "FZ_P1")
	_equal("graveyard", EventTranslator.anchor_of(_loc(0, DuelEnums.LOCATION.GRAVE, 7, 0)), "GY_P0")
	_equal("nowhere", EventTranslator.anchor_of(_loc(0, 0, 0, 0)), "NOWHERE")

	# LOCATION.OVERLAY means "xyz material": seq is the host's zone, pos the stack index.
	var attach: Array[Dictionary] = _translator.translate({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.MZONE | DuelEnums.LOCATION.OVERLAY, 2, 1),
		"reason": DuelEnums.REASON.XYZ,
	})
	_equal("attach kind", attach[0].get("kind", ""), EventTranslator.KIND_ATTACH)
	_equal("attach anchor", attach[0].get("to_anchor", ""), "OVL_MZ_P0_2_1")
	_end()


func _case_translate_ignored() -> void:
	_begin("translate: events with no visual consequence produce nothing")
	_equal("hint", _translator.translate({"t": DuelEnums.EV.HINT, "hint_type": 1, "player": 0, "data": 27}).size(), 0)
	_equal("idle command", _translator.translate({"t": DuelEnums.EV.SELECT_IDLECMD, "player": 0}).size(), 0)
	_equal("shuffle deck", _translator.translate({"t": DuelEnums.EV.SHUFFLE_DECK, "player": 0}).size(), 0)
	_equal("no type tag", _translator.translate({}).size(), 0)
	_equal("lifecycle event", _translator.translate({"t": 1000}).size(), 0)

	# The summon family is covered, so it must NOT come back empty.
	_equal("summoning", _translator.translate({
		"t": DuelEnums.EV.SUMMONING,
		"card": 1003,
		"at": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
	}).size(), 1)
	_equal("summoned", _translator.translate({"t": DuelEnums.EV.SUMMONED}).size(), 1)
	_equal("new turn", _translator.translate({"t": DuelEnums.EV.NEW_TURN, "player": 0}).size(), 1)
	_equal("new phase", _translator.translate({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.MAIN1}).size(), 1)
	_end()


# ----------------------------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------------------------

## START is host-synthesised; ocgcore never emits it (AGENTS.md section 8b.1).
func _event_start(first_player: int) -> Dictionary:
	return {
		"t": DuelEnums.EV.START,
		"lp": [8000, 8000],
		"deck": [40, 40],
		"extra": [0, 0],
		"first": first_player,
	}


## Wire shape of MSG_DRAW: the per-card key is "card", not "code" (msg_parser.cpp parse_draw).
func _event_draw(player: int, codes: Array) -> Dictionary:
	var cards: Array = []
	for code: int in codes:
		cards.append({"card": code, "pos": DuelEnums.POSITION.FACEDOWN_ATTACK})
	return {"t": DuelEnums.EV.DRAW, "player": player, "cards": cards, "count": cards.size()}


func _loc(controller: int, location: int, sequence: int, position: int = 0) -> Dictionary:
	return {"con": controller, "loc": location, "seq": sequence, "pos": position}


## A started duel where player 0 holds five known cards.
func _state_with_hand() -> DuelState:
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))
	state.apply(_event_draw(0, [1001, 1002, 1003, 1004, 1005]))
	return state


## The same, with card 1003 summoned face-up attack into monster zone 1.
func _state_with_monster() -> DuelState:
	var state: DuelState = _state_with_hand()
	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 2, DuelEnums.POSITION.FACEDOWN_ATTACK),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEUP_ATTACK),
		"reason": DuelEnums.REASON.SUMMON,
	})
	return state


func _codes(pile: Array) -> Array:
	var out: Array = []
	for entry: Variant in pile:
		out.append((entry as DuelCard).code)
	return out


func _sequences(pile: Array) -> Array:
	var out: Array = []
	for entry: Variant in pile:
		out.append((entry as DuelCard).sequence)
	return out


# ----------------------------------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------------------------------

func _begin(name: String) -> void:
	_case_name = name
	_case_failures = PackedStringArray()


func _check(label: String, passed: bool, detail: String) -> void:
	if passed:
		return
	_case_failures.append("%s (%s)" % [label, detail])


func _equal(label: String, actual: Variant, expected: Variant) -> void:
	_check(label, _same(actual, expected), "expected %s, got %s" % [str(expected), str(actual)])


## Godot's `==` on Array and Dictionary is identity, not content, so compare the serialised
## form instead. Scalars fall through to a plain comparison.
func _same(actual: Variant, expected: Variant) -> bool:
	if actual is Array or actual is Dictionary or expected is Array or expected is Dictionary:
		return JSON.stringify(actual) == JSON.stringify(expected)
	return actual == expected


func _end() -> void:
	_cases_run += 1
	if _case_failures.is_empty():
		print("PASS  %s" % _case_name)
		return
	_cases_failed += 1
	print("FAIL  %s" % _case_name)
	for failure: String in _case_failures:
		print("        %s" % failure)
