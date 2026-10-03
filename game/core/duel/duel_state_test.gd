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

	_case_handle_distinguishes_copies()
	_case_handle_survives_face_down()
	_case_handle_survives_zone_chain()
	_case_handle_shuffle_keeps_the_set()
	_case_handle_never_reused()
	_case_translate_stamps_handles()
	_case_spell_zones_never_turn_a_card()

	_case_selection_idlecmd_maps_a_tap_to_a_list_index()
	_case_selection_battlecmd_and_phase_advance()
	_case_selection_place_reads_the_flag()
	_case_selection_place_never_offers_a_blocked_zone()
	_case_selection_place_sides_are_relative_to_the_asker()
	_case_selection_multi_pick_card()
	_case_selection_tribute_counts_release_param()
	_case_selection_sum_solver()
	_case_selection_yes_no_and_chain()
	_case_selection_ignores_previews_and_idle_taps()

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


# ----------------------------------------------------------------------------------------------
# Card handles
#
# `card_id` cannot identify a physical card: two copies share it and a face-down card reports 0.
# These cases pin the property L4 depends on - one card, one handle, for the whole duel.
# ----------------------------------------------------------------------------------------------

func _case_handle_distinguishes_copies() -> void:
	_begin("two copies of one code get distinct handles")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))
	state.apply(_event_draw(0, [7777, 7777, 7777]))

	var hand: Array = state.hand[0]
	var first: DuelCard = hand[0] as DuelCard
	var second: DuelCard = hand[1] as DuelCard

	_check("both are the same card code", first.code == second.code, "codes differ")
	_check("handles differ", first.handle != second.handle,
		"both reported handle %d" % first.handle)
	_check("neither handle is zero", first.handle != 0 and second.handle != 0, "a handle was 0")

	var moved: int = first.handle
	var untouched: int = second.handle
	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": 7777,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 0),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 0, DuelEnums.POSITION.FACEUP_ATTACK),
	})

	var on_field: DuelCard = state.card_at(0, DuelEnums.LOCATION.MZONE, 0)
	_check("the moved copy kept its handle", on_field != null and on_field.handle == moved,
		"expected %d, got %s" % [moved, str(on_field.handle) if on_field else "null"])
	_check("the other copy was not disturbed",
		(state.hand[0][0] as DuelCard).handle == untouched, "the remaining copy changed identity")
	_end()


func _case_handle_survives_face_down() -> void:
	_begin("a face-down card keeps one handle across a move and a flip")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))
	# code 0 is exactly the case card_id cannot express: the viewer is not allowed to see it.
	state.apply(_event_draw(0, [0]))

	var before: int = (state.hand[0][0] as DuelCard).handle
	_check("a hidden card still gets a handle", before != 0, "handle was 0")

	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": 0,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 0),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 2, DuelEnums.POSITION.FACEDOWN_DEFENSE),
	})
	var set_card: DuelCard = state.card_at(0, DuelEnums.LOCATION.MZONE, 2)
	_check("handle survived the set", set_card != null and set_card.handle == before,
		"handle changed on move")

	state.apply({
		"t": DuelEnums.EV.POS_CHANGE,
		"card": 0,
		"at": _loc(0, DuelEnums.LOCATION.MZONE, 2, DuelEnums.POSITION.FACEUP_ATTACK),
		"prev_pos": DuelEnums.POSITION.FACEDOWN_DEFENSE,
		"pos": DuelEnums.POSITION.FACEUP_ATTACK,
	})
	var flipped: DuelCard = state.card_at(0, DuelEnums.LOCATION.MZONE, 2)
	_check("handle survived the flip", flipped != null and flipped.handle == before,
		"handle changed on position change")
	_end()


func _case_handle_survives_zone_chain() -> void:
	_begin("a handle survives hand -> monster zone -> graveyard")
	var state: DuelState = _state_with_hand()
	var original: int = (state.hand[0][2] as DuelCard).handle

	state.apply({
		"t": DuelEnums.EV.MOVE, "card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 2),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 1, DuelEnums.POSITION.FACEUP_ATTACK),
	})
	state.apply({
		"t": DuelEnums.EV.MOVE, "card": 1003,
		"from": _loc(0, DuelEnums.LOCATION.MZONE, 1),
		"to": _loc(0, DuelEnums.LOCATION.GRAVE, 0),
	})

	var grave: Array = state.graveyard[0]
	_check("the card reached the graveyard", grave.size() == 1, "graveyard holds %d" % grave.size())
	_check("handle unchanged across both moves",
		grave.size() == 1 and (grave[0] as DuelCard).handle == original,
		"expected %d" % original)
	_end()


func _case_handle_shuffle_keeps_the_set() -> void:
	_begin("a shuffle preserves the set of handles, not their order")
	var state: DuelState = _state_with_hand()

	var before: Array[int] = []
	for entry: Variant in state.hand[0]:
		before.append((entry as DuelCard).handle)
	before.sort()

	state.apply({
		"t": DuelEnums.EV.SHUFFLE_HAND, "player": 0,
		"codes": [1005, 1004, 1003, 1002, 1001],
	})

	var after: Array[int] = []
	for entry: Variant in state.hand[0]:
		after.append((entry as DuelCard).handle)
	after.sort()

	_equal("hand size unchanged", state.hand[0].size(), 5)
	_check("the same handles are still in hand", before == after,
		"before %s, after %s" % [str(before), str(after)])
	_end()


func _case_handle_never_reused() -> void:
	_begin("handles are unique for a duel and restart with reset()")
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))
	state.apply(_event_draw(0, [1, 2, 3]))
	state.apply(_event_draw(1, [4, 5, 6]))

	var seen: Dictionary = {}
	for player: int in 2:
		for entry: Variant in state.hand[player]:
			var handle: int = (entry as DuelCard).handle
			_check("handle %d is not a duplicate" % handle, not seen.has(handle),
				"handle %d was issued twice" % handle)
			seen[handle] = true
	_equal("six distinct handles", seen.size(), 6)

	# Discarding a card must not free its handle for the next one.
	state.apply({
		"t": DuelEnums.EV.MOVE, "card": 1,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 0),
		"to": _loc(0, DuelEnums.LOCATION.GRAVE, 0),
	})
	state.apply(_event_draw(0, [7]))
	var fresh: int = (state.hand[0][state.hand[0].size() - 1] as DuelCard).handle
	_check("a later card does not reuse a retired handle", not seen.has(fresh),
		"handle %d was reused" % fresh)

	# The counter must restart, not continue. Asserting a specific number would be asserting how
	# many DuelCards START happens to materialise, which is not what this case is about.
	var highest: int = 0
	for player: int in 2:
		for pile: Array in [state.hand[player], state.deck[player], state.graveyard[player]]:
			for entry: Variant in pile:
				highest = maxi(highest, (entry as DuelCard).handle)

	state.reset()
	state.apply(_event_start(0))
	var first_after_reset: int = (state.deck[0][0] as DuelCard).handle
	_equal("reset restarts the counter at 1", first_after_reset, 1)
	_check("post-reset handles do not continue the old duel", first_after_reset < highest,
		"got %d, previous duel reached %d" % [first_after_reset, highest])
	_end()


func _case_translate_stamps_handles() -> void:
	_begin("translate(event, state) attaches the handle of the card involved")
	var translator: EventTranslator = EventTranslator.new()
	var state: DuelState = DuelState.new()
	state.apply(_event_start(0))

	# Order matters: apply() first, then translate, so the card is already at its destination
	# (docs/ARCHITECTURE.md section 5 step 4).
	var draw: Dictionary = _event_draw(0, [2001, 2002])
	state.apply(draw)
	var drawn_intents: Array[Dictionary] = translator.translate(draw, state)

	var handles: Array[int] = []
	for intent: Dictionary in drawn_intents:
		if intent.has("handle"):
			handles.append(int(intent["handle"]))
	_equal("one handle per drawn card", handles.size(), 2)
	_check("the two draw intents name different cards",
		handles.size() == 2 and handles[0] != handles[1], "both intents named the same card")

	var expected: int = (state.hand[0][0] as DuelCard).handle
	var move: Dictionary = {
		"t": DuelEnums.EV.MOVE, "card": 2001,
		"from": _loc(0, DuelEnums.LOCATION.HAND, 0),
		"to": _loc(0, DuelEnums.LOCATION.MZONE, 3, DuelEnums.POSITION.FACEUP_ATTACK),
	}
	state.apply(move)
	var move_intents: Array[Dictionary] = translator.translate(move, state)
	_check("the move intent carries a handle",
		move_intents.size() > 0 and move_intents[0].has("handle"), "no handle stamped")
	_check("it is the handle the card already had",
		move_intents.size() > 0 and int(move_intents[0].get("handle", 0)) == expected,
		"expected %d" % expected)

	# Without a model the intents must come back exactly as before.
	var bare: Array[Dictionary] = translator.translate(move)
	_check("translate without a state stamps nothing",
		bare.size() > 0 and not bare[0].has("handle"), "a handle appeared with no model")


	_end()


# ----------------------------------------------------------------------------------------------
# SelectionController
# ----------------------------------------------------------------------------------------------
#
# `SelectionController` is pure data (V2): it maps an `InputIntent` onto the response intent
# `KaibaCore.respond()` expects, with `DuelState` as the only thing it reads. So it can be
# tested exactly like the model - feed it a request shaped the way `msg_parser.cpp` emits one,
# feed it a tap, and compare the dictionary that comes out.
#
# That matters more here than anywhere else in the project, because ocgcore does not report a
# wrong answer as a wrong answer. It replies `MSG_RETRY` and does **not** resend the selection
# (AGENTS.md section 8b traps 8 and 9), so a mistake in this file does not look like a mistake:
# the duel just stops. A unit test is the only place a bad answer is ever visible.

func _case_selection_idlecmd_maps_a_tap_to_a_list_index() -> void:
	_begin("a tapped hand card becomes an idle command plus the index of its own list entry")
	var state: DuelState = _state_with_hand()
	# The opponent needs a hand too, so that tapping one of their cards is a real tap on a real
	# card rather than a lookup that fails for the wrong reason.
	state.apply(_event_draw(1, [0, 0, 0, 0, 0]))
	var controller: SelectionController = SelectionController.new(state)

	# Shaped as msg_parser.cpp parse_select_idlecmd writes it. `summon` and `mset` offer the
	# same two monsters, which is the real ambiguity a single tap has to resolve; `activate`
	# offers a spell that `sset` also offers.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_IDLECMD,
		"player": 0,
		"summon": [
			{"card": 1002, "at": _loc(0, DuelEnums.LOCATION.HAND, 1)},
			{"card": 1004, "at": _loc(0, DuelEnums.LOCATION.HAND, 3)},
		],
		"spsummon": [],
		"repos": [],
		"mset": [
			{"card": 1002, "at": _loc(0, DuelEnums.LOCATION.HAND, 1)},
			{"card": 1004, "at": _loc(0, DuelEnums.LOCATION.HAND, 3)},
		],
		"sset": [{"card": 1005, "at": _loc(0, DuelEnums.LOCATION.HAND, 4)}],
		"activate": [{"card": 1005, "at": _loc(0, DuelEnums.LOCATION.HAND, 4), "desc": 0, "mode": 0}],
		"to_bp": true,
		"to_ep": true,
		"can_shuffle": true,
	})

	_check("the controller is waiting", controller.is_waiting(), "not waiting")
	_check("the prompt says something", controller.pending_prompt() != "", "empty prompt")

	# The second entry of `summon`, not the second card of the hand: the index addresses the
	# request's list, and the two orders have no reason to agree.
	_equal("tapping the fourth hand card answers summon index 1",
		controller.resolve(_tap_hand(state, 0, 3)), {"cmd": "summon", "index": 1})

	# A card offered in two lists resolves by IDLE_PRIORITY, which puts activating first.
	_equal("a spell offered as both activate and sset resolves to activate",
		controller.resolve(_tap_hand(state, 0, 4)), {"cmd": "activate", "index": 0})

	# A card the request never offered is not an answer, and must not become one by accident.
	_equal("tapping a card no list offered answers nothing",
		controller.resolve(_tap_hand(state, 0, 0)), {})

	# A tap on the opponent's side of the board likewise.
	_equal("tapping the opponent's hand answers nothing",
		controller.resolve(_tap_hand(state, 1, 0)), {})

	_equal("confirm advances to the battle phase", controller.resolve(_confirm()), {"cmd": "to_bp"})
	_equal("cancel ends the phase", controller.resolve(_cancel()), {"cmd": "to_ep"})
	_end()


func _case_selection_battlecmd_and_phase_advance() -> void:
	_begin("a tapped monster becomes an attack, and confirm advances when to_bp is absent")
	var state: DuelState = _state_with_monster()
	var controller: SelectionController = SelectionController.new(state)

	# `attack` entries carry an 8-bit sequence and a direct flag (msg_parser.cpp), but the shape
	# at this layer is the same {card, at} every list uses.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_BATTLECMD,
		"player": 0,
		"activate": [],
		"attack": [{"card": 1003, "at": _loc(0, DuelEnums.LOCATION.MZONE, 1), "direct": true}],
		"to_m2": false,
		"to_ep": true,
	})

	var monster: DuelCard = state.main_monster[0][1] as DuelCard
	_equal("tapping the monster answers attack index 0",
		controller.resolve(_tap(monster, "MZ_P0_1")), {"cmd": "attack", "index": 0})
	_equal("confirm falls through to the end phase when main phase 2 is not offered",
		controller.resolve(_confirm()), {"cmd": "to_ep"})
	_end()


func _case_selection_place_reads_the_flag() -> void:
	_begin("SELECT_PLACE answers only zones the request's own flag leaves open")
	var controller: SelectionController = SelectionController.new(DuelState.new())

	# A spell activation: every monster zone blocked (bits 0-6), spell/trap zone 0 occupied
	# (bit 8), the field and pendulum zones blocked (bits 13-15), the whole opponent half
	# blocked (bits 16-31). AGENTS.md section 8b trap 9.
	#
	# Delivered as msg_parser.cpp delivers it: `static_cast<int32_t>` of the uint32, so a mask
	# with the top bit set arrives negative. Sign extension sets bits 32-63 too, which is
	# harmless because no bit above 31 is ever tested - but a decoder that compared the mask
	# for equality, or shifted it right, would be wrong here and nowhere else.
	var flag: int = -7809 # 0xFFFFE17F as a signed int32
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_PLACE, "player": 0, "count": 1, "flag": flag,
	})

	_equal("the free list is exactly the four open spell zones", controller.free_places(), [
		{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 1},
		{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 2},
		{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 3},
		{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 4},
	])

	# This is the whole point: a monster zone looks like the obvious place for a tap to land,
	# and answering a spell activation with one earns a silent MSG_RETRY.
	_equal("a tap on a blocked monster zone answers nothing",
		controller.resolve(_tap_zone("MZ_P0_2")), {})
	_equal("a tap on the occupied spell zone answers nothing",
		controller.resolve(_tap_zone("ST_P0_0")), {})
	_equal("a tap on the opponent's half answers nothing",
		controller.resolve(_tap_zone("ST_P1_3")), {})
	_check("nothing was gathered from the rejected taps", controller.places().is_empty(),
		"gathered %s" % str(controller.places()))

	_equal("a tap on an open spell zone completes the answer",
		controller.resolve(_tap_zone("ST_P0_3")),
		{"places": [{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 3}], "count": 1})

	# Two zones at once: the first tap gathers, the second completes.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_PLACE, "player": 0, "count": 2, "flag": flag,
	})
	_equal("the first of two zones only gathers", controller.resolve(_tap_zone("ST_P0_1")), {})
	_equal("tapping the same zone twice does not count twice",
		controller.resolve(_tap_zone("ST_P0_1")), {})
	_equal("the second zone completes the answer",
		controller.resolve(_tap_zone("ST_P0_4")), {
			"places": [
				{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 1},
				{"con": 0, "loc": DuelEnums.LOCATION.SZONE, "seq": 4},
			],
			"count": 2,
		})
	_end()


func _case_selection_place_never_offers_a_blocked_zone() -> void:
	_begin("no flag, however shaped, can produce a zone whose bit is set")
	var controller: SelectionController = SelectionController.new(DuelState.new())

	# Every zone on the board, tapped against several masks. The assertion is not "the right
	# zone came back" but the stronger "a blocked zone never came back", which is the failure
	# mode that is invisible at runtime.
	var anchors: PackedStringArray = PackedStringArray()
	for player: int in range(DuelEnums.PLAYER_COUNT):
		for sequence: int in range(DuelEnums.MAIN_MONSTER_ZONES):
			anchors.append("MZ_P%d_%d" % [player, sequence])
		for sequence: int in range(DuelEnums.EXTRA_MONSTER_ZONES):
			anchors.append("EMZ_P%d_%d" % [player, sequence])
		for sequence: int in range(DuelEnums.SPELL_TRAP_ZONES):
			anchors.append("ST_P%d_%d" % [player, sequence])
		anchors.append("FZ_P%d" % player)

	var masks: Array[int] = [
		0,            # nothing blocked
		0x7F,         # the asker's monster zones
		0x3F00,       # the asker's spell zones
		-65536,       # 0xFFFF0000: the whole far half
		-1,           # everything blocked
		0x2A | 0x1500, # an alternating pattern, to catch an off-by-one in the shift
	]

	var leaked: PackedStringArray = PackedStringArray()
	for asking: int in range(DuelEnums.PLAYER_COUNT):
		for mask: int in masks:
			controller.set_pending({
				"t": DuelEnums.EV.SELECT_PLACE, "player": asking, "count": 1, "flag": mask,
			})
			for anchor: String in anchors:
				var answer: Dictionary = controller.resolve(_tap_zone(anchor))
				if answer.is_empty():
					continue
				for entry: Variant in (answer["places"] as Array):
					var place: Dictionary = entry as Dictionary
					if SelectionController.is_place_free(mask, asking,
							int(place["con"]), int(place["loc"]), int(place["seq"])):
						continue
					leaked.append("%s under flag 0x%x asked by p%d" % [anchor, mask, asking])

			# And the same claim from the other direction: everything the controller advertises
			# as free has to survive its own check.
			controller.set_pending({
				"t": DuelEnums.EV.SELECT_PLACE, "player": asking, "count": 1, "flag": mask,
			})
			for entry: Variant in controller.free_places():
				var place: Dictionary = entry as Dictionary
				if not SelectionController.is_place_free(mask, asking,
						int(place["con"]), int(place["loc"]), int(place["seq"])):
					leaked.append("free_places offered %s under flag 0x%x" % [str(place), mask])

	_check("no blocked zone was ever produced", leaked.is_empty(),
		"leaked: %s" % ", ".join(leaked))

	# A mask with nothing set must still let a tap through, or the test above would pass by
	# virtue of answering nothing at all.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_PLACE, "player": 0, "count": 1, "flag": 0,
	})
	_equal("an unblocked monster zone is still answerable",
		controller.resolve(_tap_zone("MZ_P0_2")),
		{"places": [{"con": 0, "loc": DuelEnums.LOCATION.MZONE, "seq": 2}], "count": 1})
	_end()


func _case_selection_place_sides_are_relative_to_the_asker() -> void:
	_begin("the flag's high half means the opponent of whoever was asked, not player 1")
	var controller: SelectionController = SelectionController.new(DuelState.new())

	# Bits 0-6 set, nothing else. For player 0 that blocks P0's monster zones; for player 1 it
	# blocks P1's. Reading the mask as absolute gets this exactly backwards and the bug only
	# ever shows when the opponent is the one being asked.
	for asking: int in range(DuelEnums.PLAYER_COUNT):
		var other: int = 1 - asking
		controller.set_pending({
			"t": DuelEnums.EV.SELECT_PLACE, "player": asking, "count": 1, "flag": 0x7F,
		})
		_equal("p%d's own monster zone is blocked when p%d is asked" % [asking, asking],
			controller.resolve(_tap_zone("MZ_P%d_0" % asking)), {})
		_equal("p%d's monster zone is open when p%d is asked" % [other, asking],
			controller.resolve(_tap_zone("MZ_P%d_0" % other)),
			{"places": [{"con": other, "loc": DuelEnums.LOCATION.MZONE, "seq": 0}], "count": 1})
	_end()


func _case_selection_multi_pick_card() -> void:
	_begin("SELECT_CARD gathers taps, confirms at min, submits at max and unpicks on a retap")
	var state: DuelState = _state_with_hand()
	var controller: SelectionController = SelectionController.new(state)

	var request: Dictionary = {
		"t": DuelEnums.EV.SELECT_CARD,
		"player": 0,
		"cancelable": true,
		"min": 2,
		"max": 3,
		"cards": [
			{"card": 1001, "at": _loc(0, DuelEnums.LOCATION.HAND, 0)},
			{"card": 1003, "at": _loc(0, DuelEnums.LOCATION.HAND, 2)},
			{"card": 1005, "at": _loc(0, DuelEnums.LOCATION.HAND, 4)},
		],
	}
	controller.set_pending(request)

	_equal("the first pick does not answer", controller.resolve(_tap_hand(state, 0, 2)), {})
	_equal("one index gathered", controller.picks(), [1])
	_equal("confirming below the minimum answers nothing", controller.resolve(_confirm()), {})

	_equal("the second pick still does not answer, because max is 3",
		controller.resolve(_tap_hand(state, 0, 4)), {})
	_equal("two indices gathered", controller.picks(), [1, 2])
	_equal("confirming at the minimum submits both",
		controller.resolve(_confirm()), {"indices": [1, 2]})

	# Retapping removes a pick. Without it the only way out of a wrong third selection is to
	# throw the whole answer away.
	controller.set_pending(request)
	controller.resolve(_tap_hand(state, 0, 2))
	_equal("retapping a picked card unpicks it", controller.resolve(_tap_hand(state, 0, 2)), {})
	_equal("nothing is gathered any more", controller.picks(), [])

	# The third pick fills the request, so it submits without a confirm.
	controller.resolve(_tap_hand(state, 0, 0))
	controller.resolve(_tap_hand(state, 0, 2))
	_equal("the third pick submits on its own",
		controller.resolve(_tap_hand(state, 0, 4)), {"indices": [0, 1, 2]})

	# Cancel clears first and only declines once there is nothing to clear, so a cancel meant as
	# "undo that" cannot throw away the whole selection.
	controller.set_pending(request)
	controller.resolve(_tap_hand(state, 0, 0))
	_equal("cancel with picks gathered only clears them", controller.resolve(_cancel()), {})
	_equal("the picks are gone", controller.picks(), [])
	_equal("cancel with nothing gathered declines", controller.resolve(_cancel()), {"cancel": true})

	# ... but only when the request said it may be declined.
	var forced: Dictionary = request.duplicate()
	forced["cancelable"] = false
	controller.set_pending(forced)
	_equal("a selection that is not cancelable cannot be declined",
		controller.resolve(_cancel()), {})
	_end()


func _case_selection_tribute_counts_release_param() -> void:
	_begin("SELECT_TRIBUTE counts release_param towards min, not the number of cards")
	var state: DuelState = _state_with_monster()
	var controller: SelectionController = SelectionController.new(state)

	# ocgcore validates a tribute answer as `sum of release_param >= min` and
	# `list.size() <= max` (playerop.cpp, Processors::SelectTribute). A double-tribute monster
	# therefore satisfies a two-tribute summon on its own, while still occupying one index.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_TRIBUTE,
		"player": 0,
		"cancelable": false,
		"min": 2,
		"max": 2,
		"cards": [
			{"card": 1003, "at": _loc(0, DuelEnums.LOCATION.MZONE, 1), "release_param": 2},
		],
	})

	var monster: DuelCard = state.main_monster[0][1] as DuelCard
	_equal("tapping the double tribute gathers it", controller.resolve(_tap(monster, "MZ_P0_1")), {})
	_equal("one index gathered", controller.picks(), [0])
	_equal("confirming submits it, because it is worth two",
		controller.resolve(_confirm()), {"indices": [0]})
	_end()


func _case_selection_sum_solver() -> void:
	_begin("SELECT_SUM solves for the exact total, honouring must cards and both alternatives")
	var controller: SelectionController = SelectionController.new(DuelState.new())

	# Four candidates for a total of 8 using exactly two cards. 4+4 is the only pair that works.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_SUM, "player": 0, "exact_count": true,
		"acc": 8, "min": 2, "max": 2, "must": [],
		"cards": [
			{"card": 1, "at": _loc(0, DuelEnums.LOCATION.HAND, 0), "sum_param": 3},
			{"card": 2, "at": _loc(0, DuelEnums.LOCATION.HAND, 1), "sum_param": 4},
			{"card": 3, "at": _loc(0, DuelEnums.LOCATION.HAND, 2), "sum_param": 6},
			{"card": 4, "at": _loc(0, DuelEnums.LOCATION.HAND, 3), "sum_param": 4},
		],
	})
	_equal("confirm solves the subset sum", controller.resolve(_confirm()), {"indices": [1, 3]})

	# `must` cards are supplied by the engine, are not addressable by the answer, and still
	# count towards the total (msg_parser.cpp parse_select_sum). Target here is 8 - 3 = 5.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_SUM, "player": 0, "exact_count": true,
		"acc": 8, "min": 1, "max": 1,
		"must": [{"card": 9, "at": _loc(0, DuelEnums.LOCATION.MZONE, 0), "sum_param": 3}],
		"cards": [
			{"card": 1, "at": _loc(0, DuelEnums.LOCATION.HAND, 0), "sum_param": 4},
			{"card": 2, "at": _loc(0, DuelEnums.LOCATION.HAND, 1), "sum_param": 5},
		],
	})
	_equal("the must list is subtracted before solving",
		controller.resolve(_confirm()), {"indices": [1]})

	# `sum_param` packs two alternatives in its low and high 16 bits (field.cpp:2619). Card 0
	# can count as 2 or as 7; only the high alternative reaches the total.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_SUM, "player": 0, "exact_count": true,
		"acc": 7, "min": 1, "max": 1, "must": [],
		"cards": [
			{"card": 1, "at": _loc(0, DuelEnums.LOCATION.HAND, 0), "sum_param": 2 | (7 << 16)},
		],
	})
	_equal("a card counts as whichever of its two values fits",
		controller.resolve(_confirm()), {"indices": [0]})

	# No subset reaches the total, so nothing is sent. Sending a wrong answer would be a silent
	# MSG_RETRY; sending none at least leaves the prompt visible.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_SUM, "player": 0, "exact_count": true,
		"acc": 11, "min": 1, "max": 2, "must": [],
		"cards": [{"card": 1, "at": _loc(0, DuelEnums.LOCATION.HAND, 0), "sum_param": 4}],
	})
	_equal("an unreachable total answers nothing", controller.resolve(_confirm()), {})
	_end()


func _case_selection_yes_no_and_chain() -> void:
	_begin("confirm and cancel carry yes/no, and a forced chain can never be declined")
	var controller: SelectionController = SelectionController.new(DuelState.new())

	controller.set_pending({"t": DuelEnums.EV.SELECT_YESNO, "player": 0, "desc": 0})
	_equal("confirm is yes", controller.resolve(_confirm()), {"answer": 1})
	_equal("cancel is no", controller.resolve(_cancel()), {"answer": 0})

	controller.set_pending({
		"t": DuelEnums.EV.SELECT_EFFECTYN, "player": 0,
		"card": 1001, "at": _loc(0, DuelEnums.LOCATION.HAND, 0), "desc": 0,
	})
	_equal("the same two answers serve EFFECTYN", controller.resolve(_confirm()), {"answer": 1})

	var chain_entry: Dictionary = {
		"card": 1001, "at": _loc(0, DuelEnums.LOCATION.SZONE, 0), "desc": 0, "mode": 0,
	}
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_CHAIN, "player": 0, "forced": false,
		"spe_count": 0, "hint_timing": 0, "other_hint_timing": 0, "chains": [chain_entry],
	})
	_equal("cancel declines an optional chain", controller.resolve(_cancel()), {"cancel": true})

	# -1 is only accepted when the chain was not forced; answering a forced chain with it is a
	# silent MSG_RETRY, so a cancel has to become a real index instead.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_CHAIN, "player": 0, "forced": true,
		"spe_count": 0, "hint_timing": 0, "other_hint_timing": 0, "chains": [chain_entry],
	})
	_equal("cancelling a forced chain picks the first effect instead",
		controller.resolve(_cancel()), {"index": 0})
	_end()


func _case_selection_ignores_previews_and_idle_taps() -> void:
	_begin("a preview is never an answer, and neither is a tap with nothing pending")
	var state: DuelState = _state_with_hand()
	var controller: SelectionController = SelectionController.new(state)

	_check("nothing is pending to begin with", not controller.is_waiting(), "already waiting")
	_equal("a tap with no selection pending answers nothing",
		controller.resolve(_tap_hand(state, 0, 0)), {})
	_equal("so does a confirm", controller.resolve(_confirm()), {})
	_equal("the prompt is empty", controller.pending_prompt(), "")

	controller.set_pending({
		"t": DuelEnums.EV.SELECT_IDLECMD, "player": 0,
		"summon": [{"card": 1001, "at": _loc(0, DuelEnums.LOCATION.HAND, 0)}],
		"spsummon": [], "repos": [], "mset": [], "sset": [], "activate": [],
		"to_bp": false, "to_ep": true,
	})
	_equal("POINT_AT at a summonable card answers nothing", controller.resolve({
		"kind": SelectionController.KIND_POINT_AT,
		"anchor": "HAND_P0",
		"handle": (state.hand[0][0] as DuelCard).handle,
	}), {})
	_equal("the same card tapped does answer",
		controller.resolve(_tap_hand(state, 0, 0)), {"cmd": "summon", "index": 0})

	controller.clear()
	_check("clear() stops the controller waiting", not controller.is_waiting(), "still waiting")
	_end()


# --- InputIntent builders ----------------------------------------------------------------------
#
# These are the dictionaries `InputSource` emits, written out by hand. They carry a handle and an
# anchor and never a screen coordinate (ARCHITECTURE.md section 10 rule 5), which is exactly why
# an L3 test can build one at all.

func _tap(card: DuelCard, anchor: String) -> Dictionary:
	return {
		"kind": SelectionController.KIND_SELECT_CARD,
		"handle": card.handle,
		"card_id": card.code,
		"anchor": anchor,
	}


func _tap_hand(state: DuelState, player: int, index: int) -> Dictionary:
	return _tap(state.hand[player][index] as DuelCard, "HAND_P%d" % player)


func _tap_zone(anchor: String) -> Dictionary:
	return {"kind": SelectionController.KIND_SELECT_ZONE, "anchor": anchor}


func _confirm() -> Dictionary:
	return {"kind": SelectionController.KIND_CONFIRM}


func _cancel() -> Dictionary:
	return {"kind": SelectionController.KIND_CANCEL}



func _case_spell_zones_never_turn_a_card() -> void:
	_begin("a set spell sits upright, only monsters turn sideways")

	# ocgcore has one `position` field for every card type, so a *set* spell or trap arrives as
	# FACEDOWN_DEFENSE - the same value a defending monster carries. Reading that bit straight
	# into a rotation is what laid every set spell on its side in its zone.
	_check("a set spell is reported as defence by the model",
		(DuelEnums.POSITION.FACEDOWN_DEFENSE & DuelEnums.POSITION.DEFENSE) != 0,
		"the engine's set-spell position no longer carries the defence bit")

	_check("but its zone refuses the turn",
		not BoardView.zone_turns("ST_P0_2"), "ST_P0_2 would be drawn sideways")
	_check("and so does the field zone",
		not BoardView.zone_turns("FZ_P0"), "FZ_P0 would be drawn sideways")

	_check("while a monster zone still turns",
		BoardView.zone_turns("MZ_P0_0"), "a defending monster would stay upright")
	_check("including the extra monster zones",
		BoardView.zone_turns("EMZ_P0_1"), "EMZ_P0_1 would stay upright")
	_end()


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
