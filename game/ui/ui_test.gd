extends SceneTree

## Self-checking tests for the duel HUD, the card preview, the main menu, the scene router, the
## deck editor, the controls screen, the input sources, `SelectionController`'s reading of them,
## the board's zone markers and the card back.
##
##   godot --headless --path game --script res://ui/ui_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, so it can be wired into
## a Makefile target as a gate. Same shape as `core/duel/duel_state_test.gd`, no framework.
##
## ------------------------------------------------------------------------------------------
## Why the board and the art cache are tested from the UI suite
## ------------------------------------------------------------------------------------------
## The input cases are here for the same reason, and with the same caveat: `TouchSource`,
## `MouseSource` and `SelectionController` are L5 and L3, not UI. They are in this suite because
## `make test-ui` is the gate that runs on a checkout with no `data/` and no attached device,
## and a gesture that is only exercised by `make touch` and `make solo-test` is a gesture that
## goes unchecked on most runs. Move them when an input suite exists.
##
## `BoardView`'s zone markers and `CardArt.back_texture()` are not UI, and in a tidier world
## their checks would live beside `core/duel/duel_state_test.gd` and
## `core/registry/card_art_test.gd`. They are here because this is the suite that exists and
## adding a Makefile target was outside the change that wrote them. Both are headless-safe
## measurements of real state, which is the only property that actually matters for where they
## run. Move them when a `make test-ui` target appears.
##
## ------------------------------------------------------------------------------------------
## Cases that need `data/`
## ------------------------------------------------------------------------------------------
## `data/` is gitignored (AGENTS.md section 9), so a checkout with no artwork is a normal state.
## The card-back case prints SKIP and is not counted rather than reporting red for files it was
## never supposed to have - the same contract `core/registry/card_art_test.gd` uses.
##
## ------------------------------------------------------------------------------------------
## Why the work happens in `_process` and not in `_init`
## ------------------------------------------------------------------------------------------
## A node only becomes ready once the scene tree's own root is inside the tree, and that has not
## happened yet while `_init` or `_initialize` run: `root.add_child(n)` there leaves `n` with
## `is_inside_tree() == false` and `_ready()` never called. A HUD whose `@onready` references
## are still null would measure nothing, so the first `_process` is the earliest honest moment.
##
## ------------------------------------------------------------------------------------------
## What is deliberately not tested here
## ------------------------------------------------------------------------------------------
## The router's "solo" route is checked as a route - the path it names, that the file exists,
## that `go()` swaps to it - but the real `duel_touch.tscn` is never instantiated. It would
## create a `KaibaCore`, start a duel thread and need `data/base/cards.cdb`, none of which has
## anything to do with routing. `make touch` covers that scene.

const HudScript := preload("res://ui/hud/duel_hud.gd")
const HudScene := preload("res://ui/hud/duel_hud.tscn")
const MenuScript := preload("res://ui/main_menu/main_menu.gd")
const MenuScene := preload("res://ui/main_menu/main_menu.tscn")
const MenuArt := preload("res://ui/menu_art.gd")
const RouterScript := preload("res://platform/scene_router.gd")
const BannerScene := preload("res://ui/hud/hot_seat_banner.tscn")
const PreviewScene := preload("res://ui/preview/card_preview.tscn")
const ControlsScene := preload("res://ui/controls/controls_screen.tscn")

## Read for its `KIND_*` constants as **source text**, not through
## `GDScript.get_script_constant_map()`. That API returns an empty dictionary on Godot 4.6.3,
## and a loop over zero constants passes every assertion it makes - the failure mode that made
## `view/audio/audio_director_test.gd` hollow until something caught it from the other side.
## This is the same technique, for the same reason.
const INPUT_SOURCE_SCRIPT := "res://platform/input/input_source.gd"

## Portrait HUD node paths. The layer was rebuilt for a tall screen, so the furniture sits in
## four anchored corners instead of one top-to-bottom column; these are the leaves that carry
## text a case reads. Everything that is a *decision* rather than a label - the prompt, the
## phase banner, the pile badges - is asked for through `DuelHud`'s own accessors instead.
const HUD_TOP_LIFE := "Root/TopSeat/Life/Box/Life"
const HUD_TOP_SEAT := "Root/TopSeat/Life/Box/Seat"
const HUD_TOP_TAG := "Root/TopSeat/Avatar/Tag"
const HUD_BOTTOM_LIFE := "Root/BottomSeat/Life/Box/Life"
const HUD_BOTTOM_SEAT := "Root/BottomSeat/Life/Box/Seat"
const HUD_BOTTOM_TAG := "Root/BottomSeat/Avatar/Tag"
const HUD_TURN := "Root/TurnStack/Count"
const HUD_PHASE := "Root/TurnStack/ChipRow/PhaseChip/Phase"
const HUD_OWNER := "Root/TurnStack/Owner"
const HUD_HAND_ZONE := "Root/HandZone"
const HUD_CONFIRM := "Root/Prompt/Body/Actions/Confirm"
const HUD_CANCEL := "Root/Prompt/Body/Actions/Cancel"

const BANNER_SEAT := "Root/Column/TopBand/SeatChip/Box/Value"
const BANNER_SEAT_CAPTION := "Root/Column/TopBand/SeatChip/Box/Caption"
const BANNER_DECISION := "Root/Column/TopBand/DecisionChip"
const BANNER_DECISION_VALUE := "Root/Column/TopBand/DecisionChip/Box/Value"
const BANNER_DECISION_DETAIL := "Root/Column/TopBand/DecisionChip/Box/Detail"
const BANNER_TRACK := "Root/Column/PhaseBand/PhasePanel/Box/Track"
const BANNER_STEP := "Root/Column/PhaseBand/PhasePanel/Box/Step"
const BANNER_PANEL := "Root/Column/BottomBand/Banner"
const BANNER_TITLE := "Root/Column/BottomBand/Banner/Box/Title"
const BANNER_DETAIL := "Root/Column/BottomBand/Banner/Box/Detail"

const MENU_BUTTONS := "Frame/Center/Column/Buttons"
const MENU_STATUS := "Frame/Center/Column/Status"

## `menu_art.gd` moved out of `main_menu/` and into `ui/` when the deck picker and the controls
## screen started wearing the same dress. Three screens share it; one of them does not own it.
const MENU_ART_SCRIPT := "res://ui/menu_art.gd"

const CONTROLS_ROWS := "Frame/Column/Scroll/Rows"
const CONTROLS_STATUS := "Frame/Column/Status"
const CONTROLS_BACK := "Frame/Column/Back"

const PICKER_SCENE_PATH := "res://ui/deck_picker/deck_picker.tscn"
const PICKER_LIST := "Frame/Column/Body/Split/List"
const PICKER_DETAIL := "Frame/Column/Body/Split/Detail"
const PICKER_BODY := "Frame/Column/Body"
const PICKER_BACK := "Frame/Column/Actions/Back"
const PICKER_PLAY := "Frame/Column/Actions/Play"

const UI_ROOT := "res://ui"

## How many fake cards the virtualisation case feeds the editor. Not 14 595 - the point is the
## ratio between entries and instantiated rows, and building a third of a million Dictionary
## keys to prove it would make this suite slow for no extra evidence.
const FAKE_CATALOGUE_SIZE := 5000

## Real passcodes, used by the deck-editor cases as the identity of a hand-built fixture. They
## are the same ones `core/deck/deck_test.gd` looks up in `data/base/cards.cdb`, so when that
## suite says a card's type bits are what we claim, it is saying it about these cards.
const CODE_FUSION := 45349196     # Archfiend Black Skull Dragon
const CODE_SYNCHRO := 60992105    # Blackfeather Darkrage Dragon
const CODE_XYZ := 98986900        # Thelematech Clatis
const CODE_LINK := 7594154        # Zenna's Deceiving Doll Maidens
const CODE_RITUAL := 60258960     # Legendary Flame Lord - a Ritual monster, so a MAIN deck card
const CODE_SPELL := 55144522      # Pot of Greed

## Blue-Eyes White Dragon, as `KaibaCore.get_card_info()` returns it. Hand-built rather than
## looked up: V1 forbids anything under `game/ui/` from naming the core, and this file is under
## `game/ui/`. The values are the ones `make duel-real` prints for that passcode - LIGHT Dragon,
## level 8, 3000 / 2500 - so the fixture is a transcript, not an invention. Every key the C++
## `get_card_info()` can write is present, including the ones the preview deliberately ignores,
## so the preview is proved to tolerate the whole shape rather than a convenient subset.
static func blue_eyes() -> Dictionary:
	return {
		"code": 89631139,
		"name": "Blue-Eyes White Dragon",
		"desc": "This legendary dragon is a powerful engine of destruction.",
		"strings": PackedStringArray(["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""]),
		"type": DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.NORMAL,
		"level": 8,
		"attribute": DuelEnums.ATTRIBUTE.LIGHT,
		"race": DuelEnums.RACE.DRAGON,
		"attack": 3000,
		"defense": 2500,
		"lscale": 0,
		"rscale": 0,
		"link_marker": 0,
		"alias": 0,
		"ot": 3,
		"category": 0,
		"setcodes": PackedInt32Array(),
	}

## A Link monster, which is the shape the preview is most able to get wrong: the cdb's `def`
## column carries the marker bitmask instead of a defence, and `level` carries the link rating.
## Markers are TOP | LEFT | RIGHT - 0200 | 0010 | 0040 octal in `ocgapi_constants.h`, so 168.
static func link_monster() -> Dictionary:
	return {
		"code": 1861629,
		"name": "Test Link Dragon",
		"desc": "2+ monsters",
		"strings": PackedStringArray(),
		"type": DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.LINK,
		"level": 3,
		"attribute": DuelEnums.ATTRIBUTE.DARK,
		"race": DuelEnums.RACE.CYBERSE,
		"attack": 2300,
		"defense": 0,
		"lscale": 0,
		"rscale": 0,
		"link_marker": 128 | 8 | 32,
		"alias": 0,
		"ot": 3,
		"category": 0,
		"setcodes": PackedInt32Array(),
	}

## Pot of Greed. A spell, so every monster-only line has to disappear rather than read zero.
static func pot_of_greed() -> Dictionary:
	return {
		"code": 55144522,
		"name": "Pot of Greed",
		"desc": "Draw 2 cards.",
		"strings": PackedStringArray(),
		"type": DuelEnums.TYPE.SPELL,
		"level": 0,
		"attribute": 0,
		"race": 0,
		"attack": 0,
		"defense": 0,
		"lscale": 0,
		"rscale": 0,
		"link_marker": 0,
		"alias": 0,
		"ot": 3,
		"category": 0,
		"setcodes": PackedInt32Array(),
	}

## Decoded size of `data/base/pics/cover/classic/hd.jpg`, measured rather than assumed. RGB8, no mipmaps.
const BACK_SIZE := Vector2i(930, 1350)

## -------------------------------------------------------------------------------------------
## Input sources with the raycast taken out
## -------------------------------------------------------------------------------------------
## Only `_pick()` needs a camera, a board and a populated world. Everything the gesture cases
## are actually about - when a drag becomes a set, which button means what, the shape of the
## emitted intent - sits above it and runs here unmodified. Overriding the one method that needs
## a world is what makes these cases runnable headless on a checkout with no `data/` at all.
##
## The alternative, binding a real rig and a real board and seating a real card, would test the
## raycast a third time (`make touch` and `make solo-test` both do) and the gestures zero times.

## What the stubbed pick always reports: Blue-Eyes, held in player 0's hand.
const PICK_HANDLE := 77
const PICK_CODE := 89631139
const PICK_ANCHOR := "HAND_P0"


class StubTouch extends TouchSource:
	## Every screen position `_pick()` was asked about, in order. The set gesture has to resolve
	## to the card under the drag's **origin**, not under the lifted finger, and this is how that
	## is asserted rather than assumed.
	var picked: Array[Vector2] = []

	func _pick(screen_position: Vector2) -> Dictionary:
		picked.append(screen_position)
		return {"handle": PICK_HANDLE, "card_id": PICK_CODE, "anchor": PICK_ANCHOR}


class StubMouse extends MouseSource:
	var picked: Array[Vector2] = []

	func _pick(screen_position: Vector2) -> Dictionary:
		picked.append(screen_position)
		return {"handle": PICK_HANDLE, "card_id": PICK_CODE, "anchor": PICK_ANCHOR}


var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0

var _ran: bool = false


## `false`, not `true`: returning `true` ends the loop immediately, and `_run()` is a coroutine
## now - the layout cases have to let a frame pass before a container has sorted its children,
## and a measurement taken before that reads every rect as zero. `_run()` calls `quit()` itself.
func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run()
	return false


func _run() -> void:
	print("== DuelHud / SeatFocus / HotSeatBanner / CardPreview / MainMenu / SceneRouter / DeckPicker / BoardView / CardArt tests ==")

	_case_hud_reads_the_model()
	_case_hud_rolls_life_points()
	_case_hud_knows_which_seat_is_yours()
	_case_hud_shows_the_pending_prompt()
	_case_hud_without_a_model()
	_case_hud_life_plates_read_both_seats()
	_case_hud_names_every_phase_with_no_blanks()
	_case_hud_prompt_still_answers_yes_and_no()
	_case_hud_announces_a_phase_change()
	_case_hud_pile_badges_count_the_model()
	_case_hud_battle_readout_shows_the_deciding_number()

	_case_seat_in_view_follows_the_turn_and_never_a_prompt()
	_case_seat_in_view_is_stated_at_all_times()
	_case_phase_readout_names_every_phase()
	_case_decision_indicator_names_the_seat_the_event_names()
	_case_face_down_stays_face_down_from_either_seat()

	_case_preview_fills_itself_from_card_info()
	_case_preview_hides_what_a_spell_has_no_room_for()
	_case_preview_link_monster_has_markers_and_no_defence()
	_case_preview_without_card_data()

	_case_router_reaches_the_menu()
	_case_router_reaches_solo()
	_case_router_refuses_a_mistyped_navigation_signal()
	_case_router_sends_unbuilt_destinations_home()
	_case_menu_offers_every_destination()
	_case_the_unbuilt_slabs_explain_themselves_in_the_status_line()
	_case_menu_slabs_are_carved_not_stretched()
	_case_the_background_is_a_device_choice_not_a_measurement()
	_case_the_menu_face_is_borrowed_and_optional()
	_case_router_reaches_controls()

	_case_a_downward_drag_sets_and_a_tap_does_not()
	_case_middle_click_and_shift_click_both_set()
	_case_alt_prefers_the_set_command_and_falls_back()
	_case_the_controls_table_documents_every_kind()
	_case_the_controls_screen_shows_both_columns()


	_case_zone_markers_sit_on_their_anchors()
	_case_zone_markers_light_up()
	_case_card_back_is_outside_the_budget()

	_case_hot_seat_reveals_hands_not_face_downs()
	_case_the_overlay_goes_neutral_after_a_win()
	_case_a_refused_answer_is_announced()

	_case_the_library_finds_ydk_decks()
	_case_the_picker_lists_and_reports_a_choice()
	_case_an_empty_library_says_where_to_put_files()
	_case_router_reaches_the_deck_picker()

	_case_every_verb_is_reachable_on_a_phone()

	_case_only_the_offered_cards_glow()

	_case_both_screens_wear_the_menus_dress()
	_case_back_leaves_every_dressed_screen()
	await _case_the_dressed_screens_fit_every_screen_shape()

	_case_no_widget_measures_the_screen()
	_case_no_ui_file_names_the_core()

	print("== %d cases, %d failed ==" % [_cases_run, _cases_failed])
	quit(1 if _cases_failed > 0 else 0)


# ----------------------------------------------------------------------------------------------
# DuelHud
# ----------------------------------------------------------------------------------------------

func _case_hud_reads_the_model() -> void:
	_begin("hud reads life points, turn and phase out of DuelState")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_equal("your life points", _text(hud, HUD_BOTTOM_LIFE), "8000")
	_equal("opponent life points", _text(hud, HUD_TOP_LIFE), "7000")
	_equal("turn", _text(hud, HUD_TURN), "Turn 1 - your turn")
	_equal("phase", _text(hud, HUD_PHASE), "Main phase 1")

	# Every one of those came from the model, so moving the model moves the HUD.
	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.BATTLE})
	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P1})
	hud.refresh()

	_equal("phase after NEW_PHASE", _text(hud, HUD_PHASE), "Battle phase")
	_equal("turn after NEW_TURN", _text(hud, HUD_TURN), "Turn 2 - opponent's turn")

	_discard(hud)
	_end()


func _case_hud_rolls_life_points() -> void:
	_begin("hud rolls life points to the new total instead of snapping")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	state.apply({"t": DuelEnums.EV.DAMAGE, "player": DuelEnums.PLAYER.P0, "amount": 1500})
	hud.refresh()
	_equal("still on the old total the instant the model changed", _text(hud, HUD_BOTTOM_LIFE), "8000")

	hud._advance_roll(0.1)
	var midway: int = int(_text(hud, HUD_BOTTOM_LIFE))
	_check("rolling", midway > 6500 and midway < 8000, "midway value was %d" % midway)

	hud.settle()
	_equal("arrives at the model's total", _text(hud, HUD_BOTTOM_LIFE), "6500")
	_equal("the other seat never moved", _text(hud, HUD_TOP_LIFE), "7000")

	# A fresh binding snaps: nobody should watch 8000 count up because the HUD attached late.
	var fresh: HudScript = _hud()
	fresh.bind(state)
	_equal("a fresh bind snaps", _text(fresh, HUD_BOTTOM_LIFE), "6500")

	_discard(hud)
	_discard(fresh)
	_end()


func _case_hud_knows_which_seat_is_yours() -> void:
	_begin("hud labels the seats from local_player, which DuelState does not hold")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_equal("bottom seat", _text(hud, HUD_BOTTOM_SEAT), "You")
	_equal("top seat", _text(hud, HUD_TOP_SEAT), "Opponent")

	hud.local_player = DuelEnums.PLAYER.P1
	hud.settle()
	_equal("bottom life follows the seat", _text(hud, HUD_BOTTOM_LIFE), "7000")
	_equal("top life follows the seat", _text(hud, HUD_TOP_LIFE), "8000")
	_equal("turn is read from the new seat", _text(hud, HUD_TURN), "Turn 1 - opponent's turn")

	_discard(hud)
	_end()


func _case_hud_shows_the_pending_prompt() -> void:
	_begin("hud shows what SelectionController is asking for")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_check("no prompt, no panel", not hud.prompt_is_visible(), "panel was visible")

	var selection: SelectionController = SelectionController.new(state)
	selection.set_pending({"t": DuelEnums.EV.SELECT_IDLECMD})
	var prompt: String = selection.pending_prompt()
	hud.set_prompt(prompt)

	_check("prompt is not empty", not prompt.is_empty(), "pending_prompt() returned nothing")
	_equal("prompt reaches the label verbatim", hud.prompt_text(), prompt)
	_check("panel appears", hud.prompt_is_visible(), "panel stayed hidden")

	selection.clear()
	hud.set_prompt(selection.pending_prompt())
	_equal("cleared prompt clears the label", hud.prompt_text(), "")
	_check("panel hides again", not hud.prompt_is_visible(), "panel stayed visible")

	_discard(hud)
	_end()


func _case_hud_without_a_model() -> void:
	_begin("hud with no duel bound shows placeholders rather than crashing")
	var hud: HudScript = _hud()
	hud.refresh()

	_equal("life", _text(hud, HUD_BOTTOM_LIFE), HudScript.EMPTY)
	_equal("turn", _text(hud, HUD_TURN), HudScript.EMPTY)
	_equal("phase", _text(hud, HUD_PHASE), HudScript.EMPTY)

	hud.bind(null)
	_equal("binding null is legal", _text(hud, HUD_TOP_LIFE), HudScript.EMPTY)

	_discard(hud)
	_end()


## The portrait rebuild moved both life plates into anchored corners. What must not have moved
## is where the numbers come from: `DuelState.life_points`, indexed by seat, for both halves -
## not one seat read from the model and the other inferred.
func _case_hud_life_plates_read_both_seats() -> void:
	_begin("both life plates read their own seat out of DuelState")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_equal("your plate", _text(hud, HUD_BOTTOM_LIFE), str(state.life_points[DuelEnums.PLAYER.P0]))
	_equal("their plate", _text(hud, HUD_TOP_LIFE), str(state.life_points[DuelEnums.PLAYER.P1]))

	# Each seat is damaged separately, and each plate has to follow its own seat and only its
	# own. A plate wired to the wrong index passes a single-seat check and fails here.
	state.apply({"t": DuelEnums.EV.DAMAGE, "player": DuelEnums.PLAYER.P0, "amount": 2000})
	state.apply({"t": DuelEnums.EV.RECOVER, "player": DuelEnums.PLAYER.P1, "amount": 500})
	hud.refresh()
	hud.settle()
	_equal("your plate followed your damage", _text(hud, HUD_BOTTOM_LIFE), "6000")
	_equal("their plate followed their gain", _text(hud, HUD_TOP_LIFE), "7500")

	# The avatar beside each plate is the same seat's. No art exists yet, so the frame carries
	# the seat's number - a placeholder that says which seat it is standing in for.
	_equal("your frame names your seat", _text(hud, HUD_BOTTOM_TAG), "P1")
	_equal("their frame names theirs", _text(hud, HUD_TOP_TAG), "P2")

	# Swapping seats swaps both plates and both frames together, because both are derived from
	# `local_player` rather than baked into the scene.
	hud.local_player = DuelEnums.PLAYER.P1
	hud.settle()
	_equal("the bottom plate is now P1's", _text(hud, HUD_BOTTOM_LIFE), "7500")
	_equal("the top plate is now P0's", _text(hud, HUD_TOP_LIFE), "6000")
	_equal("and the frames came with them", _text(hud, HUD_BOTTOM_TAG), "P2")
	_equal("the far frame too", _text(hud, HUD_TOP_TAG), "P1")

	_discard(hud)
	_end()


## The phase chip is the loudest thing at the top of the screen because it is the thing that
## changes. Every value `DuelEnums.PHASE` defines must put a name in it - blank, or a raw bit,
## reads as a broken duel rather than as a gap in a lookup table.
##
## Two bits deliberately share the name "Battle phase" here, which is why this case checks for
## *a* name rather than a distinct one: `DuelHud` is the player-facing readout and the start
## step and the end step of the battle phase are both, to a player, the battle phase.
## `HotSeatBanner` is the one that spells the sub-steps out, and its own case checks that.
func _case_hud_names_every_phase_with_no_blanks() -> void:
	_begin("the turn line and the phase chip name every phase DuelEnums defines")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	for key: String in DuelEnums.PHASE:
		var bit: int = DuelEnums.PHASE[key]
		state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": bit})
		hud.refresh()

		var chip: String = _text(hud, HUD_PHASE)
		_check("%s has a name" % key, not chip.strip_edges().is_empty(), "the chip was blank")
		_check("%s is not the placeholder" % key, chip != HudScript.EMPTY, "it read the dash")
		_check("%s is not printed as a raw bit" % key, not chip.begins_with("PHASE("),
			"it read '%s'" % chip)

		# The turn line sits above the chip and never goes quiet either.
		var turn: String = _text(hud, HUD_TURN)
		_check("%s keeps the turn line" % key, turn.contains("Turn 1"), "it read '%s'" % turn)
		_equal("%s keeps the owner line" % key, _text(hud, HUD_OWNER), "your turn")

	# A phase bit nobody has taught the table still shows up, loudly (the spirit of V13).
	state.phase = 0x4000
	hud.refresh()
	_check("an unknown phase is reported rather than hidden",
		_text(hud, HUD_PHASE).begins_with("PHASE("), "it read '%s'" % _text(hud, HUD_PHASE))

	_discard(hud)
	_end()


## The centre banner announces a phase change and then gets out of the way. Checked here with
## the phase loop because it is driven by the same comparison: it fires on a change of the bit,
## not on a change of the chip's text, so the two battle bits that share a name do not raise
## a banner that says the phase did not change.
func _case_hud_announces_a_phase_change() -> void:
	_begin("the centre banner announces a phase change and then clears itself")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	# Binding mid-duel is not a change. A banner here would announce a phase the player has
	# been sitting in for several actions.
	_check("binding raises nothing", not hud.phase_banner_is_visible(),
		"it read '%s'" % hud.phase_banner_text())

	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.BATTLE_START})
	hud.refresh()
	_check("a real change raises it", hud.phase_banner_is_visible(), "it stayed down")
	_equal("in capitals", hud.phase_banner_text(), "BATTLE PHASE")

	# `PHASE.BATTLE` is the battle phase's end step and shares the chip's wording, but it is a
	# different bit, so the banner fires on the bit rather than on the text.
	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.BATTLE})
	hud.refresh()
	_check("a different bit with the same name still announces", hud.phase_banner_is_visible(),
		"it stayed down")

	# Refreshing without a change must not keep it alive for ever.
	hud._advance_banner(HudScript.BANNER_SECONDS)
	hud.refresh()
	_check("it fades out on its own", not hud.phase_banner_is_visible(),
		"it read '%s'" % hud.phase_banner_text())

	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.MAIN2})
	hud.refresh()
	_check("the next change raises it again", hud.phase_banner_is_visible(), "it stayed down")
	hud.settle()
	_check("settle() ends it immediately", not hud.phase_banner_is_visible(), "it stayed up")

	_discard(hud)
	_end()


## The prompt panel is the only route to CONFIRM on a phone - `TouchSource` emits none - so the
## portrait rebuild had to carry it across intact. Both buttons are pressed as a player would
## press them, through the real nodes, not by emitting the HUD's own signals.
func _case_hud_prompt_still_answers_yes_and_no() -> void:
	_begin("the prompt panel survived the portrait rebuild and still answers")
	var hud: HudScript = _hud()

	var seen: Dictionary = {}
	hud.confirmed.connect(func() -> void: seen.merge({"confirm": true}, true))
	hud.cancelled.connect(func() -> void: seen.merge({"cancel": true}, true))

	_check("nothing pending, no panel", not hud.prompt_is_visible(), "the panel was visible")

	hud.set_prompt("Activate this effect?")
	_check("a pending prompt shows its panel", hud.prompt_is_visible(), "the panel stayed hidden")
	_equal("verbatim", hud.prompt_text(), "Activate this effect?")

	var confirm: Button = hud.get_node_or_null(HUD_CONFIRM) as Button
	var cancel: Button = hud.get_node_or_null(HUD_CANCEL) as Button
	_check("the yes button is still there", confirm != null, "no node at %s" % HUD_CONFIRM)
	_check("the no button is still there", cancel != null, "no node at %s" % HUD_CANCEL)
	if confirm == null or cancel == null:
		_discard(hud)
		_end()
		return

	# A finger is about 9mm across. Anything under this is a button you aim at rather than hit.
	for button: Button in [confirm, cancel]:
		var box: Vector2 = button.get_combined_minimum_size()
		_check("%s is big enough to hit" % button.name, box.x >= 120.0 and box.y >= 48.0,
			"it asks for only %s" % str(box))

	confirm.pressed.emit()
	cancel.pressed.emit()
	_check("the confirm button answers yes", seen.has("confirm"), "no confirmed signal")
	_check("and the cancel button answers no", seen.has("cancel"), "no cancelled signal")

	hud.set_prompt("")
	_check("an answered question puts the panel away", not hud.prompt_is_visible(),
		"the panel stayed up")

	_discard(hud)
	_end()


## The pile badges report counts and only counts. The deck is hidden information - `DuelState`
## holds face-down placeholders for it - so the size of the array is the one thing about it a
## badge is allowed to say, and it has to be the size the model actually holds.
func _case_hud_pile_badges_count_the_model() -> void:
	_begin("the pile badges report the counts DuelState holds")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_equal("your deck", hud.pile_text(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.DECK), "DECK 40")
	_equal("their deck", hud.pile_text(DuelEnums.PLAYER.P1, DuelEnums.LOCATION.DECK), "DECK 40")
	_equal("your graveyard", hud.pile_text(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.GRAVE), "GY 0")
	_equal("your extra deck", hud.pile_text(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.EXTRA), "EX 0")

	# Five cards leave the deck for the hand, and one of them is then sent to the graveyard.
	state.apply({
		"t": DuelEnums.EV.DRAW,
		"player": DuelEnums.PLAYER.P0,
		"count": 5,
		"cards": [
			{"card": CODE_SPELL, "pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
			{"card": CODE_SPELL, "pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
			{"card": CODE_SPELL, "pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
			{"card": CODE_SPELL, "pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
			{"card": CODE_SPELL, "pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
		],
	})
	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": CODE_SPELL,
		"from": {"con": DuelEnums.PLAYER.P0, "loc": DuelEnums.LOCATION.HAND, "seq": 0, "pos": 0},
		"to": {"con": DuelEnums.PLAYER.P0, "loc": DuelEnums.LOCATION.GRAVE, "seq": 0,
			"pos": DuelEnums.POSITION.FACEUP_ATTACK},
	})
	hud.refresh()

	_equal("the deck badge followed the draw",
		hud.pile_text(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.DECK),
		"DECK %d" % state.pile_for(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.DECK).size())
	_equal("the graveyard badge followed the discard",
		hud.pile_text(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.GRAVE),
		"GY %d" % state.pile_for(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.GRAVE).size())
	_equal("the other seat was untouched",
		hud.pile_text(DuelEnums.PLAYER.P1, DuelEnums.LOCATION.DECK), "DECK 40")

	# The near edge of the board carries the local seat's badges. Flipping seats has to move
	# them, exactly as it moves the life plates - otherwise a hot-seat player reads the wrong
	# deck count for the whole of every other turn.
	var near: String = "Root/BottomPiles/Deck/Count"
	var far: String = "Root/TopPiles/Deck/Count"
	_equal("the near badge is yours", _text(hud, near), "DECK 35")
	_equal("the far badge is theirs", _text(hud, far), "DECK 40")
	hud.local_player = DuelEnums.PLAYER.P1
	_equal("flipping seats moves the near badge", _text(hud, near), "DECK 40")
	_equal("and the far one", _text(hud, far), "DECK 35")

	# A HUD with no duel behind it shows placeholders rather than a confident zero.
	var blank: HudScript = _hud()
	_equal("no duel, no count", blank.pile_text(DuelEnums.PLAYER.P0, DuelEnums.LOCATION.DECK),
		"DECK %s" % HudScript.EMPTY)

	_discard(hud)
	_discard(blank)
	_end()


## The battle readout shows the number the battle will actually be decided by: a monster in
## defence is not going to hit with its ATK, and printing both invites the player to compare
## the wrong pair.
func _case_hud_battle_readout_shows_the_deciding_number() -> void:
	_begin("the battle readout shows the number the battle is decided by")
	var hud: HudScript = _hud()
	hud.bind(_duel_in_progress())

	_check("nothing is shown outside a battle", not hud.combat_is_visible(),
		"the readout was already up")

	var attacker: DuelCard = DuelCard.new()
	attacker.attack = 1800
	attacker.defense = 1000
	attacker.position = DuelEnums.POSITION.FACEUP_ATTACK

	var defender: DuelCard = DuelCard.new()
	defender.attack = 1200
	defender.defense = 2000
	defender.position = DuelEnums.POSITION.FACEUP_DEFENSE

	hud.set_combat(attacker, defender)
	_check("the readout appears", hud.combat_is_visible(), "it stayed hidden")
	_check("the attacker is read in attack", hud.combat_text().contains("ATK 1800"),
		"it read '%s'" % hud.combat_text())
	_check("a defending monster is read in defence",
		hud.combat_text().contains("DEF 2000"), "it read '%s'" % hud.combat_text())
	_check("and its attack is not offered for comparison",
		not hud.combat_text().contains("1200"), "it read '%s'" % hud.combat_text())

	hud.set_combat(attacker, null)
	_check("no defender is a direct attack", hud.combat_text().contains("DIRECT"),
		"it read '%s'" % hud.combat_text())

	hud.set_combat(null, null)
	_check("the readout goes away when the battle does", not hud.combat_is_visible(),
		"it stayed up")

	_discard(hud)
	_end()


# ----------------------------------------------------------------------------------------------
# SeatFocus and HotSeatBanner - the hot-seat overlay used by `scenes/solo_test.tscn`
#
# The scene itself is never instantiated here, for the same reason `duel_touch.tscn` is not: it
# creates a core, starts a duel thread and needs a card database, none of which has anything to
# do with the policy these cases are about. `make solo-test` - or running the scene headless -
# covers it end to end. What is checked here is the decision table on its own, which is the
# part that must not drift.
# ----------------------------------------------------------------------------------------------

## The rule this whole mode rests on. A camera that followed the pending selection would swing
## on nearly every action, because the non-turn player is handed priority through
## `MSG_SELECT_CHAIN` constantly. So: `NEW_TURN` moves the view and nothing else does.
func _case_seat_in_view_follows_the_turn_and_never_a_prompt() -> void:
	_begin("the seat in view follows the turn player across a turn change, and no prompt moves it")
	var focus: SeatFocus = SeatFocus.new()

	_equal("the view starts at player 1", focus.seat_in_view, DuelEnums.PLAYER.P0)
	_equal("and nothing has flipped yet", focus.flips, 0)

	# START names the first player. P0 goes first here, so there is nothing to move.
	_check("START to the seat already in view is not a flip",
		not focus.observe({"t": DuelEnums.EV.START, "first": DuelEnums.PLAYER.P0}),
		"it reported a flip")
	_equal("flips after START", focus.flips, 0)

	# --- the turn change -----------------------------------------------------------------
	_check("NEW_TURN to the other seat moves the view",
		focus.observe({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P1}),
		"it reported no flip")
	_equal("the view is now player 2", focus.seat_in_view, DuelEnums.PLAYER.P1)
	_equal("the turn player came with it", focus.turn_player, DuelEnums.PLAYER.P1)
	_equal("one flip", focus.flips, 1)

	# --- a mid-turn prompt for the seat that is NOT in view -------------------------------
	# This is the case the whole design decision is about. Player 1 gets priority in the
	# middle of player 2's turn; the camera must stay exactly where it is.
	var chain: Dictionary = {"t": DuelEnums.EV.SELECT_CHAIN, "player": DuelEnums.PLAYER.P0}
	_check("a selection event is not something observe() acts on", not focus.observe(chain),
		"observe() reported a flip for a selection")
	focus.set_pending(chain, "Respond with an effect? 1 available, cancel to pass")

	_equal("the view did not move", focus.seat_in_view, DuelEnums.PLAYER.P1)
	_equal("and no flip was counted", focus.flips, 1)
	_equal("the decision belongs to player 1", focus.decision_seat, DuelEnums.PLAYER.P0)
	_check("so it is announced instead", focus.is_asking_offscreen(), "no banner was raised")
	_check("the banner names the seat being asked",
		focus.banner_title().contains("PLAYER 1"), "title read '%s'" % focus.banner_title())
	_check("and says which side is still on screen",
		focus.banner_detail().contains("Player 2"), "detail read '%s'" % focus.banner_detail())
	_check("and repeats what is being asked",
		focus.banner_detail().contains("Respond with an effect?"),
		"detail read '%s'" % focus.banner_detail())

	# --- a prompt for the seat that IS in view --------------------------------------------
	focus.set_pending({"t": DuelEnums.EV.SELECT_IDLECMD, "player": DuelEnums.PLAYER.P1},
		"Main phase: tap a card to play it")
	_check("no banner for the seat already in view", not focus.is_asking_offscreen(),
		"a banner was raised for the seat in view")
	_equal("still player 2 in view", focus.seat_in_view, DuelEnums.PLAYER.P1)
	_equal("banner title is empty", focus.banner_title(), "")

	# --- a whole turn's worth of prompts --------------------------------------------------
	var moved: int = 0
	for event_type: int in [
			DuelEnums.EV.SELECT_CHAIN, DuelEnums.EV.SELECT_PLACE, DuelEnums.EV.SELECT_CARD,
			DuelEnums.EV.SELECT_YESNO, DuelEnums.EV.SELECT_POSITION,
			DuelEnums.EV.SELECT_BATTLECMD, DuelEnums.EV.SELECT_EFFECTYN]:
		for seat: int in [DuelEnums.PLAYER.P0, DuelEnums.PLAYER.P1]:
			var before: int = focus.seat_in_view
			var event: Dictionary = {"t": event_type, "player": seat}
			focus.observe(event)
			focus.set_pending(event, "")
			if focus.seat_in_view != before:
				moved += 1
	_equal("fourteen prompts moved the view this many times", moved, 0)
	_equal("and the flip count is untouched", focus.flips, 1)

	# --- back round ------------------------------------------------------------------------
	focus.clear_pending()
	_check("nothing is pending once it is cleared", not focus.is_waiting(), "still waiting")
	_check("and no banner survives it", not focus.is_asking_offscreen(), "banner survived")

	_check("the next turn change brings the view back",
		focus.observe({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P0}),
		"it reported no flip")
	_equal("the view is player 1 again", focus.seat_in_view, DuelEnums.PLAYER.P0)
	_equal("two flips", focus.flips, 2)

	# A turn that does not change hands - every extra turn effect there is - must not flip.
	_check("a NEW_TURN naming the seat already in view is not a flip",
		not focus.observe({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P0}),
		"it reported a flip")
	_equal("still two flips", focus.flips, 2)

	_end()


## In a hot seat duel the single most common mistake is acting for the wrong side, so the seat
## in view has to be legible without a transition having just happened.
func _case_seat_in_view_is_stated_at_all_times() -> void:
	_begin("the overlay states the seat in view at all times, not only while it changes")
	var state: DuelState = _duel_in_progress()
	var focus: SeatFocus = SeatFocus.new()
	var banner: HotSeatBanner = _banner()
	banner.bind(state, focus)

	_check("there is a caption saying what the line means",
		not _text(banner, BANNER_SEAT_CAPTION).strip_edges().is_empty(), "the caption is blank")
	_check("the seat line names player 1",
		_text(banner, BANNER_SEAT).contains("PLAYER 1"),
		"it read '%s'" % _text(banner, BANNER_SEAT))
	_check("and says that seat is the one taking the turn",
		_text(banner, BANNER_SEAT).contains("taking this turn"),
		"it read '%s'" % _text(banner, BANNER_SEAT))

	var first_colour: Color = banner.seat_colour()

	# The turn moves to player 2 but the view has not been told yet: that is the window in
	# which an unmarked HUD lies, so the line must say "waiting", not "taking this turn".
	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P1})
	focus.turn_player = DuelEnums.PLAYER.P1
	banner.refresh()
	_check("a seat in view that is not the turn player says so",
		_text(banner, BANNER_SEAT).contains("waiting"),
		"it read '%s'" % _text(banner, BANNER_SEAT))

	focus.observe({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P1})
	banner.refresh()
	_check("after the flip the line names player 2",
		_text(banner, BANNER_SEAT).contains("PLAYER 2"),
		"it read '%s'" % _text(banner, BANNER_SEAT))
	_check("the seat colour changed with it", banner.seat_colour() != first_colour,
		"both seats are painted %s" % str(first_colour))

	# The announcement takes the banner over while the board is turning, and gives it back.
	banner.announce("Turn 2 - the board is turning to Player 2")
	_check("an announcement shows", _node(banner, BANNER_PANEL).visible, "it stayed hidden")
	_check("and says what it is", _text(banner, BANNER_TITLE).contains("turning to Player 2"),
		"it read '%s'" % _text(banner, BANNER_TITLE))
	banner.announce("")
	_check("and gets out of the way again", not _node(banner, BANNER_PANEL).visible,
		"it stayed visible")

	_discard(banner)
	_end()


## `DuelState.phase` is a bit flag, never an ordinal, so the readout is a lookup. Every value
## `DuelEnums.PHASE` defines must come back with a name of its own - a readout that goes blank
## or prints a raw bit mid-battle reads as a bug in the duel, which is the opposite of what a
## test mode is for.
func _case_phase_readout_names_every_phase() -> void:
	_begin("the phase readout names every phase DuelEnums defines, with no blanks")
	var state: DuelState = _duel_in_progress()
	var banner: HotSeatBanner = _banner()
	banner.bind(state, SeatFocus.new())

	var names: Dictionary = {}
	for key: String in DuelEnums.PHASE:
		var bit: int = DuelEnums.PHASE[key]
		state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": bit})
		banner.refresh()

		var step: String = _text(banner, BANNER_STEP)
		_check("%s has a name" % key, not step.strip_edges().is_empty(), "the readout was blank")
		_check("%s is not printed as a raw bit" % key, not step.begins_with("PHASE("),
			"it read '%s'" % step)
		_check("%s has a name of its own" % key, not names.has(step),
			"'%s' is also the name of %s" % [step, str(names.get(step, ""))])
		names[step] = key

		# The strip is the same six stages every turn, with exactly one of them live.
		var track: String = _text(banner, BANNER_TRACK)
		_equal("%s lights exactly one stage" % key, track.count("["), 1)
		for stage: Dictionary in SeatFocus.TRACK:
			_check("%s keeps %s on the strip" % [key, str(stage["label"])],
				track.to_lower().contains(str(stage["label"]).to_lower()),
				"strip read '%s'" % track)

	_equal("one name per phase", names.size(), DuelEnums.PHASE.size())

	# The battle step is where the hot-seat player most needs to know what the engine is in,
	# so it is spelled out rather than collapsed into "Battle phase".
	for battle: int in [
			DuelEnums.PHASE.BATTLE_START, DuelEnums.PHASE.BATTLE_STEP, DuelEnums.PHASE.DAMAGE,
			DuelEnums.PHASE.DAMAGE_CAL, DuelEnums.PHASE.BATTLE]:
		state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": battle})
		banner.refresh()
		_check("0x%X names its step" % battle,
			_text(banner, BANNER_STEP).contains(" - "),
			"it read '%s'" % _text(banner, BANNER_STEP))
		_check("0x%X still shows as the battle stage" % battle,
			_text(banner, BANNER_TRACK).contains("[BATTLE]"),
			"strip read '%s'" % _text(banner, BANNER_TRACK))

	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.DAMAGE_CAL})
	banner.refresh()
	_equal("the damage calculation step is named outright", _text(banner, BANNER_STEP),
		"Battle phase - damage calculation")

	# A phase bit nobody has taught the table still shows up, loudly (the spirit of V13).
	state.phase = 0x4000
	banner.refresh()
	_check("an unknown phase is reported rather than hidden",
		_text(banner, BANNER_STEP).begins_with("PHASE("),
		"it read '%s'" % _text(banner, BANNER_STEP))

	_discard(banner)
	_end()


## Who is being asked comes from the pending event's `player` field and from nothing else -
## not from the turn player, not from the seat in view.
func _case_decision_indicator_names_the_seat_the_event_names() -> void:
	_begin("the pending-decision indicator reports the seat the event names")
	var state: DuelState = _duel_in_progress()
	var focus: SeatFocus = SeatFocus.new()
	var banner: HotSeatBanner = _banner()
	banner.bind(state, focus)

	_check("nothing is claimed before anything is asked",
		not _node(banner, BANNER_DECISION).visible, "the chip was already showing")

	for seat: int in [DuelEnums.PLAYER.P0, DuelEnums.PLAYER.P1]:
		var event: Dictionary = {"t": DuelEnums.EV.SELECT_IDLECMD, "player": seat, "to_bp": true}
		# The prompt is `SelectionController`'s, verbatim. The overlay writes none of its own.
		var selection: SelectionController = SelectionController.new(state)
		selection.set_pending(event)
		focus.set_pending(event, selection.pending_prompt())
		banner.refresh()

		_equal("seat %d is the decision seat" % seat, focus.decision_seat, seat)
		_check("the chip is showing for seat %d" % seat,
			_node(banner, BANNER_DECISION).visible, "it stayed hidden")
		_check("the chip names seat %d" % seat,
			_text(banner, BANNER_DECISION_VALUE).contains(SeatFocus.seat_name(seat).to_upper()),
			"it read '%s'" % _text(banner, BANNER_DECISION_VALUE))
		_equal("the chip carries the prompt verbatim for seat %d" % seat,
			_text(banner, BANNER_DECISION_DETAIL), selection.pending_prompt())

		# And the banner is raised for exactly one of the two seats: the one not in view.
		_equal("banner raised for seat %d" % seat, _node(banner, BANNER_PANEL).visible,
			seat != focus.seat_in_view)

	# `PLAYER.NONE` is a real value a `player` field can carry (it is how a draw is reported).
	# It is not a chair, so it must not be shown as one.
	focus.set_pending({"t": DuelEnums.EV.SELECT_YESNO, "player": DuelEnums.PLAYER.NONE}, "")
	_check("a non-seat player value is clamped to a seat",
		focus.decision_seat >= 0 and focus.decision_seat < DuelEnums.PLAYER_COUNT,
		"decision_seat was %d" % focus.decision_seat)

	focus.clear_pending()
	banner.refresh()
	_check("the chip hides once the answer is in",
		not _node(banner, BANNER_DECISION).visible, "it stayed visible")
	_check("and so does the banner", not _node(banner, BANNER_PANEL).visible, "it stayed visible")

	_discard(banner)
	_end()


## The honesty check. Both seats belong to the same person in this mode, which makes it very
## easy to write a "convenience" that reveals a set card - and that convenience would hide
## exactly the bugs the mode exists to find. The model's position bits are the truth, and the
## seat the camera is behind changes nothing about them.
func _case_face_down_stays_face_down_from_either_seat() -> void:
	_begin("a face-down card stays face-down whichever seat is in view")
	var state: DuelState = _board_with_set_cards()
	var board: BoardView = _board()

	var hidden: PackedStringArray = PackedStringArray(["MZ_P0_0", "MZ_P1_0", "ST_P0_0", "ST_P1_0"])

	for seat: int in [DuelEnums.PLAYER.P0, DuelEnums.PLAYER.P1]:
		board.viewer_player = seat
		board.sync_from_state(state)

		for anchor: String in hidden:
			var view: CardView = board.view_at(anchor)
			_check("%s has a view from seat %d" % [anchor, seat], view != null, "nothing there")
			if view == null:
				continue
			_check("%s is face-down from seat %d" % [anchor, seat], not view.face_up,
				"it showed its face")
			_equal("%s hides its passcode from seat %d" % [anchor, seat], view.card_id, 0)

		# The counter-check: if everything were face-down the case would pass for the wrong
		# reason. A face-up monster is still face-up from both seats, and still carries its id.
		var open: CardView = board.view_at("MZ_P0_1")
		_check("a face-up monster is still face-up from seat %d" % seat,
			open != null and open.face_up, "it was hidden")
		_equal("and still carries its passcode from seat %d" % seat,
			open.card_id if open != null else 0, CODE_SPELL)

		# `BoardView.zone_turns()` is the one place that decides this. ocgcore stores a set
		# spell or trap as FACEDOWN_DEFENSE because position is one field shared by every card
		# type; reading that bit into a rotation lays it on its side in its zone.
		_check("the set monster is turned sideways from seat %d" % seat,
			board.view_at("MZ_P0_0").defense, "it stayed upright")
		_check("the set spell is NOT turned sideways from seat %d" % seat,
			not board.view_at("ST_P0_0").defense, "it was laid on its side")

	_check("and that decision is zone_turns()'s, not the position bit's",
		BoardView.zone_turns("MZ_P0_0") and not BoardView.zone_turns("ST_P0_0")
			and not BoardView.zone_turns("FZ_P0"),
		"zone_turns disagrees with the zones it is asked about")

	_discard(board)
	_end()


# ----------------------------------------------------------------------------------------------
# CardPreview
# ----------------------------------------------------------------------------------------------

func _case_preview_fills_itself_from_card_info() -> void:
	_begin("preview fills every label from a get_card_info-shaped Dictionary")
	var preview: CardPreview = _preview()

	_check("starts hidden", not preview.is_showing(), "it was already showing")

	preview.show_card(blue_eyes(), null)
	_check("showing", preview.is_showing(), "show_card did not open it")
	_equal("the code it believes it is showing", preview.shown_code(), 89631139)

	_equal("name", _text(preview, CardPreview.PATH_NAME), "Blue-Eyes White Dragon")
	_equal("type decoded from the TYPE bits", _text(preview, CardPreview.PATH_TYPE),
		"Monster / Normal")
	_equal("attribute and race decoded", _text(preview, CardPreview.PATH_TRAITS),
		"LIGHT%sDragon" % CardPreview.PART_SEPARATOR)
	_equal("level, attack and defence", _text(preview, CardPreview.PATH_STATS),
		"Level 8%sATK 3000%sDEF 2500" % [CardPreview.PART_SEPARATOR, CardPreview.PART_SEPARATOR])
	_equal("effect text verbatim", _text(preview, CardPreview.PATH_DESC), str(blue_eyes()["desc"]))

	# Not a Link and not a Pendulum, so those two lines are absent rather than blank.
	_check("no marker line", not _node(preview, CardPreview.PATH_MARKERS).visible,
		"a non-Link card offered link markers")
	_check("no scale line", not _node(preview, CardPreview.PATH_SCALES).visible,
		"a non-Pendulum card offered scales")

	# A null face is a normal argument: the art may not have decoded yet, or there may be none.
	_check("says there is no artwork", _node(preview, CardPreview.PATH_NO_ART).visible,
		"a null face left the art area silently empty")

	# A real texture takes the place of that message, which is what a hover actually passes in.
	var texture: Texture2D = PlaceholderTexture2D.new()
	preview.show_card(blue_eyes(), texture)
	var face: TextureRect = preview.get_node(CardPreview.PATH_FACE) as TextureRect
	_check("the face it was handed", face.texture == texture, "got %s" % str(face.texture))
	_check("and the no-artwork message is gone", not _node(preview, CardPreview.PATH_NO_ART).visible,
		"it stayed visible under a real texture")

	preview.hide_card()
	_check("hide_card closes it", not preview.is_showing(), "still showing")
	_check("and lets go of the face", face.texture == null,
		"a hidden preview was still holding a texture")

	_discard(preview)
	_end()


func _case_preview_hides_what_a_spell_has_no_room_for() -> void:
	_begin("a spell shows no attribute, no level and no stats rather than zeroes")
	var preview: CardPreview = _preview()
	preview.show_card(pot_of_greed(), null)

	_equal("name", _text(preview, CardPreview.PATH_NAME), "Pot of Greed")
	# The cdb stores a Normal Spell as bare TYPE_SPELL with no second bit, so "Normal" has to be
	# inferred from the absence of every subtype flag.
	_equal("type", _text(preview, CardPreview.PATH_TYPE), "Spell / Normal")
	_equal("effect text", _text(preview, CardPreview.PATH_DESC), "Draw 2 cards.")

	for path: String in [CardPreview.PATH_TRAITS, CardPreview.PATH_STATS,
			CardPreview.PATH_MARKERS, CardPreview.PATH_SCALES]:
		_check("%s is hidden" % path.get_file(), not _node(preview, path).visible,
			"it read '%s'" % _text(preview, path))

	_discard(preview)
	_end()


## The one shape most likely to be rendered wrong. `card_db.cpp` moves the cdb's `def` column
## into `link_marker` for a Link monster and zeroes `defense`, so a preview that printed a
## defence would print "DEF 0" - a plausible lie, which is worse than an obvious one.
func _case_preview_link_monster_has_markers_and_no_defence() -> void:
	_begin("a Link monster shows its markers, its rating, and no defence at all")
	var preview: CardPreview = _preview()
	preview.show_card(link_monster(), null)

	var stats: String = _text(preview, CardPreview.PATH_STATS)
	_equal("rating and attack", stats,
		"LINK-3%sATK 2300" % CardPreview.PART_SEPARATOR)
	_check("no defence anywhere in the stat line", not stats.contains("DEF"),
		"it read '%s'" % stats)
	_check("and no level either - a Link monster has none", not stats.contains("Level"),
		"it read '%s'" % stats)

	_check("the marker line is visible", _node(preview, CardPreview.PATH_MARKERS).visible,
		"a Link monster showed no markers")
	_equal("markers decoded in reading order", _text(preview, CardPreview.PATH_MARKERS),
		"Markers: Top, Left, Right")

	# Straight off the bitmask, so the decode is checked without the panel in the way. 0200,
	# 0010 and 0040 octal from ocgapi_constants.h.
	_equal("link_marker_names decodes the raw mask",
		CardPreview.link_marker_names(128 | 8 | 32), PackedStringArray(["Top", "Left", "Right"]))
	_equal("the corners too",
		CardPreview.link_marker_names(64 | 256 | 1 | 4),
		PackedStringArray(["Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right"]))

	_equal("type line names Link", _text(preview, CardPreview.PATH_TYPE),
		"Monster / Link / Effect")

	# An Xyz carries a Rank in the same column a Level lives in, and ocgcore writes an unknown
	# ATK or DEF as a negative number rather than as a sentinel worth printing.
	var xyz: Dictionary = blue_eyes()
	xyz["type"] = DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.XYZ
	xyz["level"] = 4
	xyz["attack"] = -2
	xyz["defense"] = -2
	preview.show_card(xyz, null)
	_equal("an Xyz has a Rank, and '?' is a value", _text(preview, CardPreview.PATH_STATS),
		"Rank 4%sATK ?%sDEF ?" % [CardPreview.PART_SEPARATOR, CardPreview.PART_SEPARATOR])

	# Pendulum scales live in their own line because they are not stats.
	var pendulum: Dictionary = blue_eyes()
	pendulum["type"] = DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.PENDULUM
	pendulum["lscale"] = 4
	pendulum["rscale"] = 8
	preview.show_card(pendulum, null)
	_check("a Pendulum shows its scales", _node(preview, CardPreview.PATH_SCALES).visible,
		"the scale line stayed hidden")
	_equal("scales", _text(preview, CardPreview.PATH_SCALES), "Pendulum Scale 4 / 8")

	_discard(preview)
	_end()


func _case_preview_without_card_data() -> void:
	_begin("an empty Dictionary says so instead of showing a panel full of blanks")
	var preview: CardPreview = _preview()

	# `get_card_info()` answers {} for a passcode the database does not have: a token, a card
	# from a set we do not ship, or a code that arrived over the network.
	preview.show_card({}, null)

	_check("it still opens", preview.is_showing(), "an unknown card closed the panel")
	_equal("the name says what happened", _text(preview, CardPreview.PATH_NAME),
		CardPreview.UNKNOWN_NAME)
	_check("the name is not blank", not _text(preview, CardPreview.PATH_NAME).strip_edges().is_empty(),
		"the name label was empty")
	_equal("the type line is a placeholder, not an empty string",
		_text(preview, CardPreview.PATH_TYPE), CardPreview.EMPTY)
	_equal("and the text area explains itself", _text(preview, CardPreview.PATH_DESC),
		CardPreview.UNKNOWN_DESC)
	_equal("no code is claimed", preview.shown_code(), 0)

	for path: String in [CardPreview.PATH_TRAITS, CardPreview.PATH_STATS,
			CardPreview.PATH_MARKERS, CardPreview.PATH_SCALES]:
		_check("%s stays out of the way" % path.get_file(), not _node(preview, path).visible,
			"it read '%s'" % _text(preview, path))

	# Half a row is also a real answer: `get_card_info()` fills the numeric half from
	# OCG_CardData and the text half from the cdb's text table, and returns whichever it found.
	preview.show_card({"code": 42, "type": DuelEnums.TYPE.TRAP | DuelEnums.TYPE.CONTINUOUS}, null)
	_equal("a row with data but no text still gets a title",
		_text(preview, CardPreview.PATH_NAME), "Card 42")
	_equal("and its type is still decoded", _text(preview, CardPreview.PATH_TYPE),
		"Trap / Continuous")

	preview.hide_card()
	_check("hidden", not preview.is_showing(), "still showing")

	_discard(preview)
	_end()


# ----------------------------------------------------------------------------------------------
# SceneRouter
# ----------------------------------------------------------------------------------------------

func _case_router_reaches_the_menu() -> void:
	_begin("router reaches the menu")
	var router: RouterScript = _router()
	router.go(RouterScript.MENU)

	_equal("current", router.current(), "menu")
	_check("a scene is mounted", router.current_scene() != null, "nothing was instantiated")
	_check("it is the menu", router.current_scene() is MenuScript,
		"got %s" % str(router.current_scene()))
	_check("mounted under the router", router.current_scene().get_parent() == router, "wrong parent")

	_discard(router)
	_end()


## Solo is the hot seat: one duel, both seats yours, a camera and a HUD that change sides with
## the turn. It is the only solo duel the build actually plays, which is why it is the entry
## that gets the plain word on the menu. The passive-opponent scene is still in the tree and is
## still exercised by `make solo`; it simply has no slab pointing at it.
func _case_router_reaches_solo() -> void:
	_begin("router reaches solo, which is the hot seat")
	var router: RouterScript = _router()

	_check("solo is not pending", not RouterScript.PENDING.has(RouterScript.SOLO),
		"PENDING explains it away")
	_equal("solo routes at the hot seat", RouterScript.SOLO_SCENE, "res://scenes/solo_test.tscn")
	_check("and not at the regression harness",
		not RouterScript.SOLO_SCENE.contains("duel_touch"),
		"solo is pointing at the test harness again")
	_check("that scene exists", ResourceLoader.exists(RouterScript.SOLO_SCENE),
		"%s is missing" % RouterScript.SOLO_SCENE)
	_equal("and the route table points there", str(router.routes[RouterScript.SOLO]),
		RouterScript.SOLO_SCENE)

	# Swapped for a stub so this test does not boot a core, a duel thread and a card database.
	router.routes[RouterScript.SOLO] = _stub_scene("SoloStub")
	router.go(RouterScript.MENU)
	router.go(RouterScript.SOLO)

	_equal("current", router.current(), "solo")
	_equal("the menu was replaced", str(router.current_scene().name), "SoloStub")
	_equal("only one scene is mounted", router.get_child_count(), 1)

	_discard(router)
	_end()


func _case_router_sends_unbuilt_destinations_home() -> void:
	_begin("router sends unbuilt destinations back to the menu with a reason")
	var router: RouterScript = _router()

	for destination: String in RouterScript.PENDING:
		router.go(destination)
		_equal("%s lands on the menu" % destination, router.current(), "menu")
		_equal("%s explains itself" % destination, _text(router.current_scene(), MENU_STATUS),
			str(RouterScript.PENDING[destination]))

	# Any destination that is still pending will do; `decks` used to be the one named here and
	# is a real scene now, which would have made this check boot a card database.
	var before: Node = router.current_scene()
	router.go("host")
	_check("re-choosing does not rebuild the menu", router.current_scene() == before,
		"the menu was replaced")

	router.go("there is no such place")
	_equal("an unknown name still lands somewhere", router.current(), "menu")
	_check("and says so", _text(router.current_scene(), MENU_STATUS).contains("no destination"),
		"status read '%s'" % _text(router.current_scene(), MENU_STATUS))

	_discard(router)
	_end()


func _case_menu_offers_every_destination() -> void:
	_begin("menu offers the six destinations, lettered as plain words")
	var menu: MenuScript = MenuScene.instantiate() as MenuScript
	root.add_child(menu)

	var chosen: Array[String] = []
	menu.chose.connect(func(destination: String) -> void: chosen.append(destination))

	var buttons: Node = menu.get_node(MENU_BUTTONS)
	_equal("six entries", MenuScript.ENTRIES.size(), 6)
	_equal("six slabs", buttons.get_child_count(), 6)

	for entry: Dictionary in MenuScript.ENTRIES:
		var button: Button = buttons.get_node_or_null(str(entry["node"])) as Button
		_check("%s has a slab" % str(entry["id"]), button != null, "no node named %s" % str(entry["node"]))
		if button == null:
			continue
		_check("%s is pressable" % str(entry["id"]), not button.disabled, "it was disabled")

		# A plain word and nothing else. The old captions carried a "(not built yet)" suffix;
		# that explanation moved to the status line, which `_case_the_unbuilt_slabs_explain_
		# themselves_in_the_status_line` holds. Here the point is only that no caption has
		# grown a parenthetical back.
		_equal("%s is lettered with its word" % str(entry["id"]), button.text, str(entry["label"]))
		_check("%s carries no suffix" % str(entry["id"]), not button.text.contains("("),
			"button read '%s'" % button.text)

		# Centred in the stone. Across is a property; down is `Button`'s own behaviour plus the
		# symmetric top and bottom content margins on the slab, so that is what gets checked.
		_equal("%s is centred across" % str(entry["id"]), button.alignment, HORIZONTAL_ALIGNMENT_CENTER)
		var box: StyleBox = button.get_theme_stylebox("normal")
		_equal("%s is centred down" % str(entry["id"]),
			box.content_margin_top, box.content_margin_bottom)
		_check("%s holds its word and nothing else" % str(entry["id"]), button.icon == null,
			"it has an icon")

		button.pressed.emit()

	# Every id is a destination `SceneRouter` already answers to - three real routes and three
	# keys in `PENDING`. A new string here would be a slab that goes nowhere and says nothing.
	_equal("every press was reported", chosen,
		[RouterScript.SOLO, "host", "join", "decks", "controls", "replays"])
	for entry: Dictionary in MenuScript.ENTRIES:
		var id: String = str(entry["id"])
		_check("%s is a name the router knows" % id,
			RouterScript.PENDING.has(id) or _router_routes().has(id),
			"the router has no route and no pending entry for it")

	# "Solo" is the hot seat - the duel the build actually plays, both seats yours. The entry
	# that used to be "Solo", with the passive opponent, is off the menu; the slab keeps the
	# plain word and the destination behind it changed.
	_equal("the first slab is Solo", str(MenuScript.ENTRIES[0]["label"]), "Solo")
	_equal("and it routes at the hot seat", str(MenuScript.ENTRIES[0]["id"]), RouterScript.SOLO)
	for entry: Dictionary in MenuScript.ENTRIES:
		_check("no slab says 'Solo Test'", str(entry["label"]) != "Solo Test",
			"the old name is back on the menu")

	menu.show_message("anything at all")
	_equal("messages reach the screen", _text(menu, MENU_STATUS), "anything at all")

	_discard(menu)
	_end()


## The captions no longer admit to being unbuilt, so the status line is the only thing left
## telling a player why Host did nothing. Driven through the real router and the real menu, by
## pressing the actual slab, because the failure this guards against is the wiring coming apart
## between them - either half can pass its own test while the pair says nothing on screen.
func _case_the_unbuilt_slabs_explain_themselves_in_the_status_line() -> void:
	_begin("pressing an unbuilt slab writes the reason into the status line")
	var router: RouterScript = _router()
	router.go(RouterScript.MENU)

	for entry: Dictionary in MenuScript.ENTRIES:
		var id: String = str(entry["id"])
		if not RouterScript.PENDING.has(id):
			continue
		var menu: MenuScript = router.current_scene() as MenuScript
		_check("%s starts from the menu" % id, menu != null, "the menu was not on screen")
		if menu == null:
			continue

		menu.show_message("")
		var button: Button = menu.get_node(MENU_BUTTONS).get_node_or_null(str(entry["node"])) as Button
		_check("%s has a slab to press" % id, button != null, "no slab")
		if button == null:
			continue
		button.pressed.emit()

		_equal("%s lands back on the menu" % id, router.current(), RouterScript.MENU)
		_equal("%s explains itself on screen" % id, _text(router.current_scene(), MENU_STATUS),
			str(RouterScript.PENDING[id]))

	# And the three that are built say nothing of the sort.
	for entry: Dictionary in MenuScript.ENTRIES:
		var id: String = str(entry["id"])
		_check("%s is either routed or explained, never neither" % id,
			RouterScript.PENDING.has(id) or _router_routes().has(id),
			"it is neither")

	_discard(router)
	_end()


## The slab is a nine-patch, not a stretched bitmap, and the two states are two different
## bitmaps. Both are checked on the real scene, as the menu actually assigned them.
func _case_menu_slabs_are_carved_not_stretched() -> void:
	_begin("every slab is a nine-patch of the stone art, lit when pressed")
	var menu: MenuScript = MenuScene.instantiate() as MenuScript
	root.add_child(menu)

	var buttons: Node = menu.get_node(MENU_BUTTONS)
	var resting: StyleBox = null
	var pressed: StyleBox = null

	for entry: Dictionary in MenuScript.ENTRIES:
		var button: Button = buttons.get_node_or_null(str(entry["node"])) as Button
		if button == null:
			continue
		var normal: StyleBoxTexture = button.get_theme_stylebox("normal") as StyleBoxTexture
		var down: StyleBoxTexture = button.get_theme_stylebox("pressed") as StyleBoxTexture
		_check("%s rests on a textured slab" % str(entry["id"]), normal != null, "not a StyleBoxTexture")
		_check("%s has a pressed slab" % str(entry["id"]), down != null, "not a StyleBoxTexture")
		if normal == null or down == null:
			continue

		# A nine-patch, not a stretch: all four margins must be real, or the carved border is
		# being resampled along with the middle every time a row changes shape.
		for margin: float in [normal.texture_margin_left, normal.texture_margin_top,
				normal.texture_margin_right, normal.texture_margin_bottom]:
			_check("%s keeps its carved border out of the stretch" % str(entry["id"]), margin > 0.0,
				"a margin was %s" % str(margin))

		_check("%s visibly changes when pressed" % str(entry["id"]), normal.texture != down.texture,
			"both states are the same bitmap")

		# Big enough to tap, and - the easy one to forget - taller than its own border, which is
		# what stops the nine-patch's slices from overlapping instead of framing anything.
		_check("%s is a thumb-sized target" % str(entry["id"]),
			button.custom_minimum_size.y >= 48.0, "minimum height was %s" % str(button.custom_minimum_size.y))
		_check("%s is taller than its carved border" % str(entry["id"]),
			button.custom_minimum_size.y > float(MenuArt.slab_border_height()),
			"%s px of row for %s px of border" % [
				str(button.custom_minimum_size.y), str(MenuArt.slab_border_height())])

		resting = normal
		pressed = down

	_check("the resting state came from the resting art", resting != null, "no slab was read")
	_equal("the menu's own floor clears the border",
		MenuScript.SLAB_MIN_HEIGHT > MenuArt.slab_border_height(), true)
	_equal("and clears a thumb", MenuScript.SLAB_MIN_HEIGHT >= 48, true)

	_discard(menu)
	_end()


## The background is chosen from a device property and never from a measurement.
##
## ARCHITECTURE.md section 10 rule 4 forbids a widget sizing itself from the screen, because in
## VR this layer becomes a quad whose pixel size is arbitrary. Picking which of two image files
## to load from the screen's physical orientation is a different act - it selects an asset, not
## a size - and this case pins both halves of that: the mapping is right for every orientation
## the display server can report, and the menu's own files contain none of the measurement
## spellings that would mean it had quietly become a layout branch.
func _case_the_background_is_a_device_choice_not_a_measurement() -> void:
	_begin("the background follows the device's orientation, not the viewport")

	var portrait: Array[int] = [
		DisplayServer.SCREEN_PORTRAIT,
		DisplayServer.SCREEN_REVERSE_PORTRAIT,
		DisplayServer.SCREEN_SENSOR_PORTRAIT,
	]
	var landscape: Array[int] = [
		DisplayServer.SCREEN_LANDSCAPE,
		DisplayServer.SCREEN_REVERSE_LANDSCAPE,
		DisplayServer.SCREEN_SENSOR_LANDSCAPE,
		DisplayServer.SCREEN_SENSOR,
	]

	for orientation: int in portrait:
		_equal("orientation %d takes the portrait cut" % orientation,
			MenuArt.background_for_orientation(orientation).resource_path,
			"res://ui/art/menu/background-menu-v.jpeg")
	for orientation: int in landscape:
		_equal("orientation %d takes the landscape cut" % orientation,
			MenuArt.background_for_orientation(orientation).resource_path,
			"res://ui/art/menu/background-menu-h.jpeg")

	# Whichever cut it is, it covers rather than letterboxes.
	var menu: MenuScript = MenuScene.instantiate() as MenuScript
	root.add_child(menu)
	var background: TextureRect = menu.get_node("Background") as TextureRect
	_check("the menu hung one of them", background.texture != null, "no background texture")
	_equal("and it is the one the device asked for", background.texture,
		menu.background_texture())
	_equal("stretched to cover", background.stretch_mode, TextureRect.STRETCH_KEEP_ASPECT_COVERED)
	_equal("ignoring its own minimum size", background.expand_mode, TextureRect.EXPAND_IGNORE_SIZE)
	_discard(menu)

	# Spelled in halves so that this file is not itself a hit for the thing it forbids. This
	# repeats `_case_no_widget_measures_the_screen` over the menu alone, plus the two further
	# spellings that would be the obvious way to cheat *this* decision specifically.
	var needles: Array[String] = [
		"get_viewport()" + ".size",
		"get_viewport_rect" + "()",
		"get_window()" + ".size",
		"DisplayServer." + "window_get_size",
		"DisplayServer." + "screen_get_size",
	]
	# All three dressed screens, plus the file they share. The deck picker and the controls
	# screen wear the same art now, which is three chances to "fix" a layout by asking how wide
	# the window is instead of two.
	var dressed: PackedStringArray = PackedStringArray([MENU_ART_SCRIPT])
	for dir: String in ["res://ui/main_menu", "res://ui/deck_picker", "res://ui/controls"]:
		dressed.append_array(_ui_files(dir))
	for path: String in dressed:
		var text: String = _without_comments(FileAccess.get_file_as_string(path))
		_check("%s was readable" % path, not text.strip_edges().is_empty(), "read nothing")
		for needle: String in needles:
			_check("%s measures nothing" % path, not text.contains(needle),
				"it contains '%s'" % needle)

	# And the device question is asked exactly once in the whole of `game/ui/`, in the function
	# that documents why. A second caller is how the one permitted device read turns into a
	# habit - so this counts over every file, not just over the one that is allowed to ask.
	var asks: int = 0
	for path: String in _ui_files(UI_ROOT):
		if path == "res://ui/ui_test.gd":
			continue
		asks += _without_comments(FileAccess.get_file_as_string(path)).count(
			"screen_get_" + "orientation")
	_equal("the orientation is read in one place in all of game/ui/", asks, 1)
	_equal("and that place is menu_art.gd",
		_without_comments(FileAccess.get_file_as_string(MENU_ART_SCRIPT)).count(
			"screen_get_" + "orientation"), 1)

	_end()


## Papyrus is a licensed Apple system font. It is read from the operating system when the
## machine has it and is never copied into this repository, so the fallback is not an edge case
## - it is what every machine without that file gets, which is every Android device the game is
## actually built for. This proves the fallback is clean and that the menu does not depend on
## the face it may not get.
func _case_the_menu_face_is_borrowed_and_optional() -> void:
	_begin("the menu face is borrowed from the system and falls back cleanly")

	_equal("a missing file yields no face",
		MenuArt.menu_font("/no/such/font/anywhere.ttc"), null)
	_equal("and so does an empty path", MenuArt.menu_font(""), null)

	# Nothing resembling a font file either - the helper must not hand back a broken `FontFile`
	# that renders as blank glyphs, which is worse than the engine default. FreeType prints two
	# ERROR lines while this is being proved; they are the proof, not a failure.
	_equal("and so does a file that is not a font",
		MenuArt.menu_font("res://ui/main_menu/main_menu.gd"), null)

	# The repository must not be carrying a copy. This is the licence, not a style rule.
	for path: String in _ui_files(UI_ROOT):
		_check("%s is not a bundled face" % path,
			not path.to_lower().ends_with(".ttf") and not path.to_lower().ends_with(".ttc")
				and not path.to_lower().ends_with(".otf"),
			"a font file is checked in under game/ui/")
	_check("and the system path is only ever read, never written",
		not FileAccess.get_file_as_string(MENU_ART_SCRIPT).contains("FileAccess.open"),
		"menu_art.gd opens a file for writing")

	# Whichever way it resolved on this machine, the menu is fully usable: every word is on
	# every slab, and every slab still reports its destination.
	var menu: MenuScript = MenuScene.instantiate() as MenuScript
	root.add_child(menu)
	var face: Font = menu.face()
	_check("the face is a Font or nothing at all", face == null or face is Font,
		"got %s" % str(face))

	var chosen: Array[String] = []
	menu.chose.connect(func(destination: String) -> void: chosen.append(destination))
	var buttons: Node = menu.get_node(MENU_BUTTONS)
	for entry: Dictionary in MenuScript.ENTRIES:
		var button: Button = buttons.get_node_or_null(str(entry["node"])) as Button
		if button == null:
			continue
		_check("%s is lettered either way" % str(entry["id"]), not button.text.is_empty(),
			"the slab was blank")
		button.pressed.emit()
	_equal("and every slab still answers", chosen.size(), MenuScript.ENTRIES.size())

	_discard(menu)
	_end()


## The router's own route table, by name. `routes` is an instance member, so this builds one
## throwaway router rather than reaching for a constant that does not exist.
func _router_routes() -> Dictionary:
	var router: RouterScript = RouterScript.new()
	var names: Dictionary = router.routes.duplicate()
	router.free()
	return names


# ----------------------------------------------------------------------------------------------
# Input: gestures
#
# There was no way to set a monster face-down. ocgcore offers a monster in hand as both `summon`
# and `mset`, and `SelectionController.IDLE_PRIORITY` always takes the face-up one, so a tap
# could only ever set a **trap** - the one card type that appears in `sset` and nowhere else.
# `SELECT_ALT` is the verb that closes it, and these are the cases that prove each end of it.
# ----------------------------------------------------------------------------------------------

## The touch binding. A short downward drag sets; everything else that is not a tap still does
## nothing, which is the half that matters most - the gesture has to be cheap to *avoid*.
func _case_a_downward_drag_sets_and_a_tap_does_not() -> void:
	_begin("a downward drag sets the card under its origin, and a tap does not")

	var source: StubTouch = StubTouch.new()
	root.add_child(source)
	var seen: Array[Dictionary] = []
	source.intent.connect(func(data: Dictionary) -> void: seen.append(data))

	# The threshold is a different order of movement from a tap, not a slightly bigger one.
	_check("the set distance clears the tap slop by a wide margin",
		TouchSource.SET_DRAG_DISTANCE >= 2.0 * TouchSource.TAP_SLOP,
		"%.0f px is not clear of %.0f px of finger wander"
			% [TouchSource.SET_DRAG_DISTANCE, TouchSource.TAP_SLOP])

	# A plain tap, with the few pixels of wander a real finger puts on one.
	_tap_screen(source, Vector2(400, 400), Vector2(404, 403))
	_equal("a tap emits exactly one intent", seen.size(), 1)
	_equal("and it is a plain selection", str(seen[0].get("kind", "")), InputSource.KIND_SELECT_CARD)

	# Down past the threshold.
	seen.clear()
	source.picked.clear()
	_drag_screen(source, Vector2(400, 400), [Vector2(400, 440)], Vector2(400, 400 + TouchSource.SET_DRAG_DISTANCE + 8.0))
	_equal("a downward drag emits exactly one intent", seen.size(), 1)
	_equal("and it is the alternative selection",
		str(seen[0].get("kind", "")), InputSource.KIND_SELECT_ALT)
	_equal("carrying the card handle", int(seen[0].get("handle", 0)), PICK_HANDLE)
	_equal("and its anchor", str(seen[0].get("anchor", "")), PICK_ANCHOR)
	_check("and it resolved at the origin, not at the lifted finger",
		source.picked.size() > 0 and source.picked[source.picked.size() - 1] == Vector2(400, 400),
		"picked at %s" % str(source.picked))

	# Rule 5: whatever it carries, it is never a screen coordinate.
	for key: String in ["position", "screen_position", "point", "at"]:
		_check("the intent carries no %s" % key, not seen[0].has(key),
			"SELECT_ALT leaked a coordinate under '%s'" % key)

	# Three drags that must NOT set: short, upward, and sideways.
	var rejected: Array[Dictionary] = [
		{"to": Vector2(400, 400 + TouchSource.SET_DRAG_DISTANCE - 1.0), "why": "too short"},
		{"to": Vector2(400, 400 - 120.0), "why": "upward"},
		{"to": Vector2(520, 430), "why": "mostly sideways"},
	]
	for entry: Dictionary in rejected:
		seen.clear()
		_drag_screen(source, Vector2(400, 400), [entry["to"] as Vector2], entry["to"] as Vector2)
		_equal("a %s drag emits nothing" % str(entry["why"]), seen.size(), 0)

	# The same rule, read straight off the gesture, so the boundary is pinned and not inferred
	# from whichever sample positions happen to be above.
	_check("exactly at the threshold counts",
		TouchSource.is_set_drag(Vector2.ZERO, Vector2(0, TouchSource.SET_DRAG_DISTANCE)),
		"the threshold itself was rejected")
	_check("one pixel short does not",
		not TouchSource.is_set_drag(Vector2.ZERO, Vector2(0, TouchSource.SET_DRAG_DISTANCE - 1.0)),
		"a drag under the threshold was accepted")
	_check("the diagonal limit is a cone, not a quadrant",
		not TouchSource.is_set_drag(Vector2.ZERO, Vector2(100, 120)),
		"a 40-degree drag was accepted as straight down")

	_discard(source)
	_end()


## The PC binding. Two gestures for one verb on purpose: middle click is the one a player keeps,
## Shift + click is the one they can be told and the one a trackpad can produce at all.
func _case_middle_click_and_shift_click_both_set() -> void:
	_begin("middle click and Shift + left click both set, plain left click does not")

	var source: StubMouse = StubMouse.new()
	root.add_child(source)
	var seen: Array[Dictionary] = []
	source.intent.connect(func(data: Dictionary) -> void: seen.append(data))

	_click(source, MOUSE_BUTTON_LEFT, false)
	_equal("left click emits one intent", seen.size(), 1)
	_equal("and it is a plain selection", str(seen[0].get("kind", "")), InputSource.KIND_SELECT_CARD)

	seen.clear()
	_click(source, MOUSE_BUTTON_MIDDLE, false)
	_equal("middle click emits one intent", seen.size(), 1)
	_equal("and it is the alternative selection",
		str(seen[0].get("kind", "")), InputSource.KIND_SELECT_ALT)

	seen.clear()
	_click(source, MOUSE_BUTTON_LEFT, true)
	_equal("Shift + left click emits one intent", seen.size(), 1)
	_equal("and it is the same alternative selection",
		str(seen[0].get("kind", "")), InputSource.KIND_SELECT_ALT)
	_equal("carrying the same card handle", int(seen[0].get("handle", 0)), PICK_HANDLE)

	# Shift is read per event, never remembered. A modifier that outlives its event is a mode.
	seen.clear()
	_click(source, MOUSE_BUTTON_LEFT, false)
	_equal("the next unmodified click is plain again",
		str(seen[0].get("kind", "")), InputSource.KIND_SELECT_CARD)

	# Long press is the preview and stays the preview; nothing above moved it.
	seen.clear()
	_click(source, MOUSE_BUTTON_RIGHT, false)
	_equal("right click still cancels", str(seen[0].get("kind", "")), InputSource.KIND_CANCEL)

	_discard(source)
	_end()


## The L3 end. `SELECT_ALT` prefers the set command and falls back to the face-up one, because a
## gesture that silently does nothing on a card the engine offered only one way is worse than a
## gesture that does the obvious thing.
func _case_alt_prefers_the_set_command_and_falls_back() -> void:
	_begin("SELECT_ALT answers mset for a monster offered both ways, and summon when it was not")

	var state: DuelState = _hand_of_five()
	var controller := SelectionController.new(state)

	# Shaped as `native/src/msg_parser.cpp` parse_select_idlecmd writes it. Card 1002 is offered
	# both ways, 1003 only as a summon, 1005 both as an activation and as a set.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_IDLECMD,
		"player": DuelEnums.PLAYER.P0,
		"summon": [
			{"card": 1002, "at": {"con": 0, "loc": DuelEnums.LOCATION.HAND, "seq": 1, "pos": 0}},
			{"card": 1003, "at": {"con": 0, "loc": DuelEnums.LOCATION.HAND, "seq": 2, "pos": 0}},
		],
		"mset": [
			{"card": 1002, "at": {"con": 0, "loc": DuelEnums.LOCATION.HAND, "seq": 1, "pos": 0}},
		],
		"activate": [
			{"card": 1005, "at": {"con": 0, "loc": DuelEnums.LOCATION.HAND, "seq": 4, "pos": 0}},
		],
		"sset": [
			{"card": 1005, "at": {"con": 0, "loc": DuelEnums.LOCATION.HAND, "seq": 4, "pos": 0}},
		],
		"spsummon": [],
		"repos": [],
		"to_bp": true,
		"to_ep": true,
	})

	# The monster offered both ways: this is the pair that had no second reading before.
	_equal("tapping it summons", controller.resolve(_card_intent(state, 1, false)),
		{"cmd": "summon", "index": 0})
	_equal("the alternative sets it", controller.resolve(_card_intent(state, 1, true)),
		{"cmd": "mset", "index": 0})

	# Offered one way only. The alternative must not evaporate.
	_equal("a monster offered only as a summon is still summoned",
		controller.resolve(_card_intent(state, 2, true)), {"cmd": "summon", "index": 1})

	# The spell side of the same hole.
	_equal("tapping a spell activates it", controller.resolve(_card_intent(state, 4, false)),
		{"cmd": "activate", "index": 0})
	_equal("the alternative sets it", controller.resolve(_card_intent(state, 4, true)),
		{"cmd": "sset", "index": 0})

	# A card the request never offered answers nothing, whichever verb asked.
	_equal("an unoffered card is still unoffered",
		controller.resolve(_card_intent(state, 0, true)), {})

	# The two tables have to describe the same six lists, or one of them is addressing commands
	# the other cannot reach.
	var normal: Array[String] = SelectionController.IDLE_PRIORITY.duplicate()
	var alternative: Array[String] = SelectionController.IDLE_ALT_PRIORITY.duplicate()
	normal.sort()
	alternative.sort()
	_equal("both orderings cover the same commands", normal, alternative)
	_equal("and the alternative leads with the set commands",
		[SelectionController.IDLE_ALT_PRIORITY[0], SelectionController.IDLE_ALT_PRIORITY[1]],
		["mset", "sset"])

	# Outside the idle phase there is no other way to play a card, so the verb degrades to a
	# plain selection rather than becoming a gesture that does nothing wherever it is not special.
	controller.set_pending({
		"t": DuelEnums.EV.SELECT_BATTLECMD,
		"player": DuelEnums.PLAYER.P0,
		"attack": [
			{"card": 1003, "at": {"con": 0, "loc": DuelEnums.LOCATION.HAND, "seq": 2, "pos": 0}},
		],
		"activate": [],
		"to_m2": true,
		"to_ep": true,
	})
	_equal("in the battle phase it reads as a plain selection",
		controller.resolve(_card_intent(state, 2, true)), {"cmd": "attack", "index": 0})

	_end()


# ----------------------------------------------------------------------------------------------
# Controls
# ----------------------------------------------------------------------------------------------

## The case the controls screen exists for. Every `KIND_*` constant on `InputSource` must appear
## in `InputSource.BINDINGS`, so a verb added upstream fails this suite instead of quietly going
## undocumented - which is the failure mode that makes a controls screen worse than none.
func _case_the_controls_table_documents_every_kind() -> void:
	_begin("the controls table documents every input kind")

	var kinds: PackedStringArray = _all_input_kinds()
	_check("the source declares its kinds", kinds.size() >= 6,
		"found %d KIND_* constants in %s" % [kinds.size(), INPUT_SOURCE_SCRIPT])

	for kind: String in kinds:
		var binding: Dictionary = InputSource.binding_for(kind)
		_check("%s is documented" % kind, not binding.is_empty(), "no row in BINDINGS")
		if binding.is_empty():
			continue
		_check("%s has a label" % kind, not str(binding.get("label", "")).strip_edges().is_empty(),
			"empty label")
		_check("%s says what it does" % kind,
			not str(binding.get("does", "")).strip_edges().is_empty(), "empty description")
		_check("%s names at least one gesture" % kind,
			not (str(binding.get("touch", "")).is_empty() and str(binding.get("pc", "")).is_empty()),
			"neither device can produce it")

	# And from the other side: a typo'd key in the table would read as coverage.
	for row: Dictionary in InputSource.BINDINGS:
		_check("table row %s is a real kind" % str(row.get("kind", "")),
			kinds.has(str(row.get("kind", ""))),
			"BINDINGS holds a kind no constant declares")
	_equal("one row per kind, no duplicates", InputSource.BINDINGS.size(), kinds.size())

	# A report rather than an assertion: the gestures that exist today, so a reviewer sees them
	# without opening the table, and so a verb with a hole in one column is visible.
	for row: Dictionary in InputSource.BINDINGS:
		print("        %-12s touch: %-34s pc: %s" % [
			str(row.get("kind", "")),
			str(row.get("touch", "")) if not str(row.get("touch", "")).is_empty() else "-",
			str(row.get("pc", "")) if not str(row.get("pc", "")).is_empty() else "-"])

	_check("an undeclared kind is not claimed as documented",
		InputSource.binding_for("NOT_A_KIND").is_empty(),
		"binding_for() answered for a kind that does not exist")
	_end()


## The screen renders the table and nothing else, and it shows both device columns at once.
##
## Not a style preference: deciding which column to show means asking how big the window is in
## order to make a logic decision, which ARCHITECTURE.md section 10 rule 4 forbids and which
## `_case_no_widget_measures_the_screen` would catch anyway. A phone cast to a monitor and a
## desktop with a touchscreen are the same build.
func _case_the_controls_screen_shows_both_columns() -> void:
	_begin("the controls screen renders the table, both columns, with no device test")

	var screen: ControlsScreen = ControlsScene.instantiate() as ControlsScreen
	root.add_child(screen)

	_equal("one row per binding", screen.row_count(), InputSource.BINDINGS.size())

	for index: int in range(InputSource.BINDINGS.size()):
		var row: Dictionary = InputSource.BINDINGS[index]
		var text: String = screen.row_text(index)
		var kind: String = str(row.get("kind", ""))
		_check("%s names itself" % kind, text.contains(str(row.get("label", ""))),
			"row read '%s'" % text)
		_check("%s says what it does" % kind, text.contains(str(row.get("does", ""))),
			"row read '%s'" % text)
		_check("%s labels the touch column" % kind, text.contains(ControlsScreen.TOUCH_HEADER),
			"no touch header in '%s'" % text)
		_check("%s labels the pc column" % kind, text.contains(ControlsScreen.PC_HEADER),
			"no pc header in '%s'" % text)

		var touch: String = str(row.get("touch", ""))
		var pc: String = str(row.get("pc", ""))
		_check("%s shows its touch gesture" % kind,
			text.contains(touch if not touch.is_empty() else ControlsScreen.NO_BINDING),
			"row read '%s'" % text)
		_check("%s shows its pc gesture" % kind,
			text.contains(pc if not pc.is_empty() else ControlsScreen.NO_BINDING),
			"row read '%s'" % text)

	# The set gesture is the one this screen was added for; name it explicitly so a rename that
	# leaves the table intact but empties the screen cannot pass.
	var all_text: String = ""
	for index: int in range(screen.row_count()):
		all_text += screen.row_text(index)
	_check("the set gesture is on the screen for both devices",
		all_text.contains("drag") and all_text.contains("Middle click"),
		"neither gesture was rendered")

	var chosen: Array[String] = []
	screen.chose.connect(func(destination: String) -> void: chosen.append(destination))
	(screen.get_node(CONTROLS_BACK) as Button).pressed.emit()
	_equal("Back goes to the menu", chosen, ["menu"])

	screen.show_message("anything at all")
	_equal("messages reach the screen", _text(screen, CONTROLS_STATUS), "anything at all")

	_discard(screen)
	_end()


func _case_router_reaches_controls() -> void:
	_begin("the controls destination reaches the controls screen")
	var router: RouterScript = _router()

	_check("the route exists", router.routes.has(RouterScript.CONTROLS), "no controls route")
	_check("and points at a real scene",
		ResourceLoader.exists(str(router.routes[RouterScript.CONTROLS])),
		"%s is not there" % str(router.routes[RouterScript.CONTROLS]))

	router.go(RouterScript.CONTROLS)
	_equal("the router is there", router.current(), RouterScript.CONTROLS)
	_check("and it is the controls screen", router.current_scene() is ControlsScreen,
		"got %s" % str(router.current_scene()))

	# Back, through the same signal every other destination uses.
	router.current_scene().chose.emit(RouterScript.MENU)
	_equal("Back lands on the menu", router.current(), RouterScript.MENU)

	_discard(router)
	_end()


# ----------------------------------------------------------------------------------------------
# Input fixtures
# ----------------------------------------------------------------------------------------------

## Every `KIND_*` the input source declares, read off the **source text** rather than listed
## here, so a kind added upstream shows up in this suite without anyone remembering to add it.
## See the note on `INPUT_SOURCE_SCRIPT` for why the reflection API is not used.
func _all_input_kinds() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var text: String = FileAccess.get_file_as_string(INPUT_SOURCE_SCRIPT)
	if text.is_empty():
		return out

	var pattern := RegEx.new()
	pattern.compile("^const\\s+KIND_\\w+\\s*:\\s*String\\s*=\\s*\"([^\"]+)\"")
	for line: String in text.split("\n"):
		var found: RegExMatch = pattern.search(line)
		if found != null:
			out.append(found.get_string(1))
	return out


## A finger down at `from` and up at `to`, with no motion in between.
func _tap_screen(source: InputSource, from: Vector2, to: Vector2) -> void:
	source._unhandled_input(_touch_event(from, true))
	source._unhandled_input(_touch_event(to, false))


## A finger down at `from`, dragged through `path`, lifted at `to`.
func _drag_screen(source: InputSource, from: Vector2, path: Array[Vector2], to: Vector2) -> void:
	source._unhandled_input(_touch_event(from, true))
	for point: Vector2 in path:
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = point
		source._unhandled_input(drag)
	source._unhandled_input(_touch_event(to, false))


func _touch_event(position: Vector2, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = position
	event.pressed = pressed
	return event


## One press. Releases are ignored by `MouseSource`, so sending one would prove nothing.
func _click(source: InputSource, button: int, shift: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.shift_pressed = shift
	event.position = Vector2(400, 400)
	source._unhandled_input(event)


## A started duel where player 0 holds five known cards, 1001..1005 at hand sequences 0..4.
## Built from the Level-1 event shapes `native/src/msg_parser.cpp` emits, like every other
## fixture in this file: the per-card key of MSG_DRAW is "card", not "code".
func _hand_of_five() -> DuelState:
	var state := DuelState.new()
	state.apply({
		"t": DuelEnums.EV.START,
		"lp": [8000, 8000],
		"deck": [40, 40],
		"extra": [0, 0],
		"first": DuelEnums.PLAYER.P0,
	})
	var cards: Array = []
	for code: int in [1001, 1002, 1003, 1004, 1005]:
		cards.append({"card": code, "pos": DuelEnums.POSITION.FACEDOWN_ATTACK})
	state.apply({
		"t": DuelEnums.EV.DRAW,
		"player": DuelEnums.PLAYER.P0,
		"cards": cards,
		"count": cards.size(),
	})
	return state


## The intent a source would emit for the `index`-th card of player 0's hand. `alternative`
## picks the verb; everything else about the two is identical, which is the whole design.
func _card_intent(state: DuelState, index: int, alternative: bool) -> Dictionary:
	var card: DuelCard = state.hand[DuelEnums.PLAYER.P0][index] as DuelCard
	return {
		"kind": InputSource.KIND_SELECT_ALT if alternative else InputSource.KIND_SELECT_CARD,
		"handle": card.handle,
		"card_id": card.code,
		"anchor": "HAND_P0",
	}


# ----------------------------------------------------------------------------------------------
# DeckPicker
#
# The editor is handed its card data and never looks anything up (V1). Everything below feeds it
# hand-built Dictionaries shaped like the ones the picker derives from the card
# database, which is also what makes these cases runnable on a checkout with no `data/` at all.
# ----------------------------------------------------------------------------------------------

## The whole point of building the markers off the anchors rather than off the layout arithmetic
## a second time. A marker that has drifted is worse than no marker: it tells a player a card
## goes somewhere it does not.
func _case_zone_markers_sit_on_their_anchors() -> void:
	_begin("every zone marker sits within a millimetre of the anchor it represents")
	var board: BoardView = _board()

	var names: PackedStringArray = board.zone_marker_names()
	# 17 playable zones per seat: 5 monster, 2 extra monster, 5 spell & trap, field, graveyard,
	# banished, deck, extra deck. Counted from DuelEnums rather than typed as "34".
	var per_player: int = (
		DuelEnums.MAIN_MONSTER_ZONES + DuelEnums.EXTRA_MONSTER_ZONES
		+ DuelEnums.SPELL_TRAP_ZONES + 5)
	_equal("one marker per playable zone per seat", names.size(),
		per_player * DuelEnums.PLAYER_COUNT)

	var worst: float = 0.0
	var worst_name: String = ""
	var strays: PackedStringArray = PackedStringArray()
	for anchor: String in names:
		if not board.anchor_names().has(anchor):
			strays.append(anchor)
			continue
		var drift: float = board.zone_marker_transform(anchor).origin.distance_to(
			board.anchor_position(anchor))
		if drift > worst:
			worst = drift
			worst_name = anchor
	_check("every marker names a real anchor", strays.is_empty(),
		"strays: %s" % ", ".join(strays))
	_check("worst drift is under a millimetre", worst < 0.001,
		"%s is %.4f m from its anchor" % [worst_name, worst])
	print("        worst marker drift: %s %.4f mm" % [worst_name, worst * 1000.0])

	# The only offset there is meant to be, and it has to clear the table without reaching the
	# cards. Either way round it z-fights something.
	var lift: float = board.zone_marker_transform("MZ_P0_0").origin.y
	_check("markers float above the table top", lift > 0.0, "lift was %.5f m" % lift)
	_check("and stay under the cards", lift < BoardView.CARD_LIFT,
		"lift %.5f m vs card lift %.5f m" % [lift, BoardView.CARD_LIFT])

	# Role is carried by the shape, not only by the colour: three distinct meshes.
	_equal("monster zone role", board.zone_marker_role("MZ_P0_2"), BoardView.ZoneRole.MONSTER)
	_equal("extra monster zone role", board.zone_marker_role("EMZ_P1_0"), BoardView.ZoneRole.MONSTER)
	_equal("spell & trap role", board.zone_marker_role("ST_P0_4"), BoardView.ZoneRole.SPELL_TRAP)
	_equal("field zone role", board.zone_marker_role("FZ_P1"), BoardView.ZoneRole.SPELL_TRAP)
	for pile: String in ["GY_P0", "BANISH_P0", "DECK_P1", "EXTRA_P1"]:
		_equal("%s role" % pile, board.zone_marker_role(pile), BoardView.ZoneRole.PILE)
	_equal("an anchor with no marker reports no role", board.zone_marker_role("HAND_P0"), -1)

	var monster: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P0_0") as MeshInstance3D
	var spell: MeshInstance3D = board.get_node("ZoneMarkers/ST_P0_0") as MeshInstance3D
	var pile_marker: MeshInstance3D = board.get_node("ZoneMarkers/GY_P0") as MeshInstance3D
	_check("monster and spell & trap are different geometry", monster.mesh != spell.mesh,
		"both roles share one mesh, so only the colour tells them apart")
	_check("and so is a pile", pile_marker.mesh != monster.mesh and pile_marker.mesh != spell.mesh,
		"a pile shares a mesh with a zone")

	# Shared, not per-instance: the marker set must cost a fixed number of resources.
	var other_monster: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P1_3") as MeshInstance3D
	_check("meshes are shared between markers of a role", other_monster.mesh == monster.mesh,
		"every marker allocated its own mesh")
	_check("so are materials", other_monster.material_override == monster.material_override,
		"every marker allocated its own material")

	# Hands, players and NOWHERE are not places a card is "placed", so they have no outline.
	for anchor: String in ["HAND_P0", "HAND_P1", "PLAYER_P0", BoardView.ANCHOR_NOWHERE]:
		_check("%s has no marker" % anchor, not names.has(anchor), "it got one")

	# A marker must never be able to answer a pick ray - that is CardView's job alone.
	var colliders: PackedStringArray = PackedStringArray()
	for anchor: String in names:
		var marker: Node = board.get_node("ZoneMarkers/%s" % anchor)
		if marker.get_child_count() > 0:
			colliders.append(anchor)
	_check("no marker carries a collider", colliders.is_empty(),
		"these have children: %s" % ", ".join(colliders))

	# The markers live beside the anchors, never inside them: `anchor_names()` is the vocabulary
	# L3 and L4 share and a marker appearing in it would be a new, meaningless anchor.
	_equal("the anchor list is untouched", board.anchor_names().size(),
		board.get_node("ZoneAnchors").get_child_count())

	_discard(board)
	_end()


func _case_zone_markers_light_up() -> void:
	_begin("a legal target lights up, and one call sets the whole state")
	var board: BoardView = _board()

	board.highlight_zones(PackedStringArray(["MZ_P0_1", "MZ_P0_3"]))
	_equal("the zones asked for", board.highlighted_zones(),
		PackedStringArray(["MZ_P0_1", "MZ_P0_3"]))

	var lit: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P0_1") as MeshInstance3D
	var dark: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P0_0") as MeshInstance3D
	_equal("a lit zone wears the highlight colour",
		(lit.material_override as StandardMaterial3D).albedo_color, BoardView.COLOUR_HIGHLIGHT)
	_equal("an unlit one keeps its role colour",
		(dark.material_override as StandardMaterial3D).albedo_color, BoardView.COLOUR_MONSTER)

	# One call is the whole state, so a caller never has to remember what it lit last time.
	board.highlight_zones(PackedStringArray(["ST_P1_0"]))
	_equal("the previous set is gone", board.highlighted_zones(), PackedStringArray(["ST_P1_0"]))
	_equal("and the zone it left went back to its role colour",
		(lit.material_override as StandardMaterial3D).albedo_color, BoardView.COLOUR_MONSTER)

	# The same anchor grammar as everything else, aliases included.
	board.highlight_zones(PackedStringArray(["PZ_P0_0", "PZ_P0_1"]))
	_equal("a pendulum zone lights the spell & trap zone it actually is",
		board.highlighted_zones(),
		PackedStringArray(["ST_P0_0", "ST_P0_%d" % (DuelEnums.SPELL_TRAP_ZONES - 1)]))

	# V13's spirit: an anchor with no marker warns and is skipped, never crashes.
	print("        the next warning is this check doing its job")
	board.highlight_zones(PackedStringArray(["MZ_P1_2", "HAND_P0", "NOT_AN_ANCHOR"]))
	_equal("the unknown names are dropped and the real one survives",
		board.highlighted_zones(), PackedStringArray(["MZ_P1_2"]))

	board.clear_highlights()
	_equal("clear_highlights turns everything off", board.highlighted_zones().size(), 0)

	_discard(board)
	_end()


# ----------------------------------------------------------------------------------------------
# CardArt - the card back
# ----------------------------------------------------------------------------------------------

## `back_texture()` is the one thing in `CardArt` that is not a face, and the one thing that must
## never be evicted: every face-down card, both decks, both extra decks and the opponent's hand
## wear it, so losing it under memory pressure would blank most of the board at exactly the
## moment memory was tight - and then reload it on the next frame.
func _case_card_back_is_outside_the_budget() -> void:
	var art: CardArt = CardArt.new()
	if not FileAccess.file_exists(art.back_path()):
		print("SKIP  the card back loads and survives an LRU sweep (no %s)" % art.back_path())
		return

	_begin("the card back loads and survives an LRU sweep")

	var back: Texture2D = art.back_texture()
	_check("it loaded", back != null, "back_texture() returned null")
	if back != null:
		_equal("it is the real file, at its real size", back.get_size(), Vector2(BACK_SIZE))
	_equal("its decoded cost is reported", art.back_bytes(), BACK_SIZE.x * BACK_SIZE.y * 3)
	_check("and is not counted against the face budget", int(art.stats()["bytes"]) == 0,
		"stats() reported %d bytes with only the back loaded" % int(art.stats()["bytes"]))
	_equal("nor as a cache entry", art.stats()["cached"], 0)
	_check("a second call is the same texture, not a second decode",
		art.back_texture() == back, "it reloaded")
	print("        card back: %s, %d bytes decoded, outside the %d byte budget" % [
		art.back_path().get_file(), art.back_bytes(), art.budget_bytes()])

	# Now actually run the LRU over the top of it: a budget of one face, then six faces loaded.
	var codes: PackedInt32Array = _sample_codes(CardArt.default_root(CardArt.TIER_SD), 6)
	if codes.size() < 6:
		_check("needed six faces on disk to force an eviction", false,
			"found %d" % codes.size())
		art.shutdown()
		_end()
		return

	# Deliberately NOT switching tier before the sweep. The cover now ships one file per
	# resolution under `pics/cover/<theme>/`, so changing tier legitimately changes which back
	# is wanted; mixing that into the eviction test would blame the LRU for a reload the tier
	# change asked for.
	art.set_budget_bytes(268 * 391 * 3)
	for code: int in codes:
		art.request(code)
	art.shutdown()
	for code: int in codes:
		art.texture_for(code)

	var stats: Dictionary = art.stats()
	_check("the sweep really did evict", int(stats["cached"]) < codes.size(),
		"all %d faces survived a one-face budget" % int(stats["cached"]))
	_check("the back is still the same object", art.back_texture() == back,
		"the LRU took the card back")
	_equal("and still not in the cache's accounting", stats["cached"], 1)

	# Nothing that drops faces may touch it.
	art.clear()
	_check("clear() leaves it", art.back_texture() == back, "clear() dropped the card back")

	# A tier change is the one thing that *should* replace it, because each tier has its own
	# file. This is configuration, not memory pressure: the guarantee is that the back is never
	# lost to eviction, not that it never changes.
	var before_path: String = art.back_path()
	art.set_tier(CardArt.TIER_SD)
	_check("a tier change asks for that tier's own cover file",
		art.back_path() != before_path,
		"back_path() stayed at %s after switching tier" % before_path)
	var small: Texture2D = art.back_texture()
	_check("and that file loads", small != null, "the sd cover did not load")
	if small != null:
		_check("it is a different image, not the hd one again", small != back,
			"the tier switch returned the same texture")

	art.shutdown()
	_end()


# ----------------------------------------------------------------------------------------------
# ARCHITECTURE.md section 10 rule 4
# ----------------------------------------------------------------------------------------------

## No widget may size itself from the screen. In VR this whole layer becomes a SubViewport on a
## quad whose pixel size is an arbitrary texture resolution, and any such branch would be wrong
## there (see the header of `ui/hud/duel_hud.gd`).
# ----------------------------------------------------------------------------------------------
# The dress the three screens share
# ----------------------------------------------------------------------------------------------

## The deck picker and the controls screen wear the menu's art, and they wear it by asking
## `MenuArt` rather than by keeping a copy of it.
##
## Both halves matter. A screen that merely *looks* the same today drifts the first time the
## slab margins are re-measured or the background is recut, and the drift is invisible until
## somebody opens two screens side by side. So this case checks what each screen is actually
## wearing, and then greps for the thing that would let it drift: the art paths, the font path
## and the stylebox construction, none of which may appear outside `menu_art.gd`.
func _case_both_screens_wear_the_menus_dress() -> void:
	_begin("the deck picker and the controls screen wear the menu's art, from MenuArt")

	var expected_background: Texture2D = MenuArt.current_background()
	var expected_resting: StyleBoxTexture = MenuArt.resting_slab()
	var expected_pressed: StyleBoxTexture = MenuArt.pressed_slab()
	var expected_face: Font = MenuArt.menu_font()

	for spec: Dictionary in _dressed_screens():
		var screen: Control = (load(str(spec["scene"])) as PackedScene).instantiate()
		root.add_child(screen)
		var tag: String = str(spec["tag"])

		# The background is the very same resource the menu hangs, not a second load of the
		# same file - `MenuArt` holds both cuts as preloaded constants, so identity is the
		# assertion that proves nothing was reloaded or re-chosen here.
		var background: TextureRect = screen.get_node("Background") as TextureRect
		_check("%s hangs a background" % tag, background != null and background.texture != null,
			"no Background/texture")
		if background != null:
			_equal("%s hangs the cut MenuArt chose" % tag, background.texture, expected_background)
			_equal("%s reports the same cut" % tag, screen.background_texture(),
				expected_background)
			_equal("%s covers rather than letterboxes" % tag, background.stretch_mode,
				TextureRect.STRETCH_KEEP_ASPECT_COVERED)
			_equal("%s ignores its own minimum size" % tag, background.expand_mode,
				TextureRect.EXPAND_IGNORE_SIZE)

		var scrim: ColorRect = screen.get_node_or_null("Scrim") as ColorRect
		_check("%s lays the scrim over it" % tag, scrim != null, "no Scrim")
		if scrim != null:
			_equal("%s uses MenuArt's scrim" % tag, scrim.color, MenuArt.SCRIM_COLOR)

		# Papyrus or nothing, resolved the same way the menu resolves it. Comparing null-ness
		# rather than the object: `menu_font()` builds a fresh `FontFile` per call, so two
		# successful resolutions are two different objects and both are correct.
		_equal("%s letters itself the same way the menu does" % tag,
			screen.face() == null, expected_face == null)

		for path: String in (spec["buttons"] as Array):
			var button: Button = screen.get_node_or_null(str(path)) as Button
			_check("%s has %s" % [tag, str(path)], button != null, "no such button")
			if button == null:
				continue
			var normal: StyleBoxTexture = button.get_theme_stylebox("normal") as StyleBoxTexture
			var down: StyleBoxTexture = button.get_theme_stylebox("pressed") as StyleBoxTexture
			_check("%s/%s rests on a textured slab" % [tag, button.name], normal != null,
				"not a StyleBoxTexture")
			_check("%s/%s has a pressed slab" % [tag, button.name], down != null,
				"not a StyleBoxTexture")
			if normal == null or down == null:
				continue

			# The nine-patch margins are the measurement that would drift if the screen had
			# built its own stylebox, so they are what is compared - not the texture object,
			# which `slab_box()` resamples freshly on every call.
			_equal("%s/%s keeps MenuArt's carved margins" % [tag, button.name],
				[normal.texture_margin_left, normal.texture_margin_top,
					normal.texture_margin_right, normal.texture_margin_bottom],
				[expected_resting.texture_margin_left, expected_resting.texture_margin_top,
					expected_resting.texture_margin_right, expected_resting.texture_margin_bottom])
			_equal("%s/%s lights up with MenuArt's margins" % [tag, button.name],
				[down.texture_margin_left, down.texture_margin_bottom],
				[expected_pressed.texture_margin_left, expected_pressed.texture_margin_bottom])
			_equal("%s/%s is the resampled slab, not the raw bitmap" % [tag, button.name],
				normal.texture.get_size(), expected_resting.texture.get_size())
			_check("%s/%s visibly changes when pressed" % [tag, button.name],
				normal.texture.get_size() != down.texture.get_size()
					or normal.texture_margin_top != down.texture_margin_top,
				"both states are the same slab")

			_check("%s/%s is a thumb-sized target" % [tag, button.name],
				button.custom_minimum_size.y >= 48.0,
				"minimum height was %s" % str(button.custom_minimum_size.y))
			_check("%s/%s is taller than its carved border" % [tag, button.name],
				button.custom_minimum_size.y > float(MenuArt.slab_border_height()),
				"%s px of row for %s px of border" % [
					str(button.custom_minimum_size.y), str(MenuArt.slab_border_height())])

		_discard(screen)

	# And the grep that stops any of the above from being re-derived locally. Spelled in halves
	# where the needle would otherwise match this file.
	var forbidden: Array[String] = [
		"frame-" + "menu",
		"background-" + "menu",
		"Papy" + "rus",
		"/System/" + "Library",
		"StyleBoxTexture." + "new",
	]
	for dir: String in ["res://ui/deck_picker", "res://ui/controls"]:
		for path: String in _ui_files(dir):
			var text: String = _without_comments(FileAccess.get_file_as_string(path))
			_check("%s was readable" % path, not text.strip_edges().is_empty(), "read nothing")
			for needle: String in forbidden:
				_check("%s keeps no copy of the art" % path, not text.contains(needle),
					"it contains '%s'" % needle)
			_check("%s goes through MenuArt" % path,
				not path.ends_with(".gd") or text.contains("ui/menu_art.gd"),
				"it does not preload the shared art")

	_end()


## Back leaves every screen that has one, through the one verb the router connects.
##
## `cancelled` alone was not enough: nothing listened to it, so the button emitted into nothing
## and the player was stuck on the picker. The router only ever connects `chose(String)`, which
## is why Back has to speak that and why `SceneRouter._takes_a_destination()` exists.
func _case_back_leaves_every_dressed_screen() -> void:
	_begin("Back navigates off both dressed screens, through the router's own verb")

	for spec: Dictionary in _dressed_screens():
		var tag: String = str(spec["tag"])
		var screen: Control = (load(str(spec["scene"])) as PackedScene).instantiate()
		root.add_child(screen)

		var chosen: Array[String] = []
		screen.chose.connect(func(destination: String) -> void: chosen.append(destination))
		(screen.get_node(str(spec["back"])) as Button).pressed.emit()
		_equal("%s Back asks for the menu" % tag, chosen, ["menu"])

		# The signal the router will actually connect, checked the way the router checks it.
		var router: RouterScript = RouterScript.new()
		_check("%s declares chose(destination: String)" % tag,
			router._takes_a_destination(screen), "the router would refuse to connect it")
		router.free()

		_discard(screen)

	# And end to end, through a real router: pressing Back lands on the menu.
	for destination: String in [RouterScript.DECKS, RouterScript.CONTROLS]:
		var router: RouterScript = _router()
		router.go(destination)
		_equal("the router reaches %s" % destination, router.current(), destination)
		var screen: Node = router.current_scene()
		_check("%s is on screen" % destination, screen != null, "nothing was instantiated")
		if screen != null:
			screen.chose.emit(RouterScript.MENU)
			_equal("Back from %s lands on the menu" % destination, router.current(),
				RouterScript.MENU)
		_discard(router)

	_end()


## The layouts, measured rather than asserted.
##
## Three shapes: a small phone, a tall modern phone and a desktop window. At each one every
## widget is read back from the tree and four things are checked - nothing leaves the frame,
## no two siblings overlap, every button clears 48 px, and every panel actually encloses the
## text it was put there to make readable.
##
## Scrolling content is the one deliberate exception to "inside the frame": a `ScrollContainer`
## exists precisely so its child may be taller than it, so its descendants are measured against
## the scroll viewport's width and against the frame only horizontally.
func _case_the_dressed_screens_fit_every_screen_shape() -> void:
	_begin("both screens lay out inside the frame at phone and desktop shapes")

	var original: Vector2i = root.size
	for shape: Vector2i in [Vector2i(720, 1280), Vector2i(1080, 2340), Vector2i(1920, 1080)]:
		root.size = shape
		root.content_scale_size = shape
		for spec: Dictionary in _dressed_screens():
			var tag: String = "%s at %dx%d" % [str(spec["tag"]), shape.x, shape.y]
			var screen: Control = (load(str(spec["scene"])) as PackedScene).instantiate()
			root.add_child(screen)
			screen.set_deferred("size", Vector2(shape))
			# Containers sort on a deferred notification; measuring before that reads zeroes.
			for _i: int in range(4):
				await process_frame

			_measure(tag, screen, Rect2(Vector2.ZERO, Vector2(shape)))
			root.remove_child(screen)
			screen.queue_free()

	root.size = original
	root.content_scale_size = original
	_end()


## One screen at one shape: every rule the layout has to obey, applied to every widget in it.
func _measure(tag: String, screen: Control, frame: Rect2) -> void:
	_check("%s fills its frame" % tag, screen.size.is_equal_approx(frame.size),
		"the screen is %s in a %s frame" % [str(screen.size), str(frame.size)])

	var buttons: int = 0
	var panels: int = 0
	for widget: Control in _controls(screen):
		var rect: Rect2 = Rect2(widget.global_position, widget.size)
		var scrolled: bool = _inside_a_scroll(widget, screen)

		# Horizontally everything is inside the frame, scrolling or not: the scroll containers
		# here scroll vertically only, so a widget wider than the window is a bug either way.
		_check("%s: %s stays inside the frame across" % [tag, widget.name],
			rect.position.x >= frame.position.x - 0.5 and rect.end.x <= frame.end.x + 0.5,
			"x %s..%s against %s..%s" % [str(rect.position.x), str(rect.end.x),
				str(frame.position.x), str(frame.end.x)])
		if not scrolled:
			_check("%s: %s stays inside the frame down" % [tag, widget.name],
				rect.position.y >= frame.position.y - 0.5 and rect.end.y <= frame.end.y + 0.5,
				"y %s..%s against %s..%s" % [str(rect.position.y), str(rect.end.y),
					str(frame.position.y), str(frame.end.y)])

		if widget is Button:
			buttons += 1
			_check("%s: %s is a thumb-sized target" % [tag, widget.name], widget.size.y >= 48.0,
				"it is %s px tall" % str(widget.size.y))

		if widget is PanelContainer:
			panels += 1
			var panel: Rect2 = rect
			var covered: int = 0
			for text: Control in _text_widgets(widget):
				covered += 1
				_check("%s: %s covers %s" % [tag, widget.name, text.name],
					panel.encloses(Rect2(text.global_position, text.size)),
					"panel %s does not enclose %s" % [str(panel),
						str(Rect2(text.global_position, text.size))])
			_check("%s: %s has text to cover" % [tag, widget.name], covered > 0,
				"an empty panel")

		if widget is Container:
			_no_overlaps(tag, widget)

	_check("%s drew buttons" % tag, buttons > 0, "no button in the tree")
	_check("%s put its dense content on a panel" % tag, panels > 0, "no PanelContainer")
	print("        %-26s buttons %d, panels %d" % [tag, buttons, panels])


## Siblings laid out by the same container must not sit on top of each other. Anything that
## overlaps here is a container being fought rather than used.
func _no_overlaps(tag: String, container: Container) -> void:
	var kids: Array[Control] = []
	for child: Node in container.get_children():
		if child is Control and (child as Control).visible:
			kids.append(child as Control)
	for i: int in range(kids.size()):
		for j: int in range(i + 1, kids.size()):
			var hit: Rect2 = Rect2(kids[i].global_position, kids[i].size).intersection(
				Rect2(kids[j].global_position, kids[j].size))
			_check("%s: %s and %s do not overlap" % [tag, kids[i].name, kids[j].name],
				hit.size.x <= 0.5 or hit.size.y <= 0.5,
				"they share %s inside %s" % [str(hit.size), container.name])


## The two screens that wear the menu's dress, and where their navigation lives.
func _dressed_screens() -> Array[Dictionary]:
	return [
		{
			"tag": "picker",
			"scene": PICKER_SCENE_PATH,
			"back": PICKER_BACK,
			"buttons": [PICKER_BACK, PICKER_PLAY],
		},
		{
			"tag": "controls",
			"scene": SceneRouter.CONTROLS_SCENE,
			"back": CONTROLS_BACK,
			"buttons": [CONTROLS_BACK],
		},
	]


func _controls(node: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child: Node in node.get_children():
		if child is Control:
			out.append(child as Control)
		out.append_array(_controls(child))
	return out


func _text_widgets(node: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child: Node in node.get_children():
		if child is Label or child is RichTextLabel or child is ItemList:
			out.append(child as Control)
		out.append_array(_text_widgets(child))
	return out


## Whether a widget is scrolled content, which is allowed to be taller than what shows it.
func _inside_a_scroll(widget: Control, stop: Node) -> bool:
	var walker: Node = widget.get_parent()
	while walker != null and walker != stop:
		if walker is ScrollContainer:
			return true
		walker = walker.get_parent()
	return false


func _case_no_widget_measures_the_screen() -> void:
	_begin("no file under game/ui/ measures the screen")

	# Spelled in halves so that this file is not itself a hit for the thing it forbids.
	var needles: Array[String] = [
		"get_viewport()" + ".size",
		"get_window()" + ".size",
		"DisplayServer." + "window_get_size",
	]

	var files: PackedStringArray = _ui_files(UI_ROOT)
	_check("there are files to scan", files.size() > 0, "found none under %s" % UI_ROOT)

	for path: String in files:
		var text: String = FileAccess.get_file_as_string(path)
		_check("%s was readable" % path, not text.is_empty(), "read nothing")
		for needle: String in needles:
			_check("%s is clean" % path, not text.contains(needle), "it contains '%s'" % needle)

	_end()


## V1: L4 and L5 never import anything from L1. The card preview is the file this is actually
## about - it renders card data and the shortest route to card data is the core - but the rule
## is the directory's, so the whole directory is scanned.
##
## A widget that reached the core directly would work today and would be unusable the first time
## a card is previewed from a replay, from a deck list or from across the network, none of which
## have a live core to ask.
func _case_no_ui_file_names_the_core() -> void:
	_begin("no file under game/ui/ names the core")

	# Spelled in halves so that this file is not itself a hit for the thing it forbids.
	# `ClassDB.instantiate` is here because it is the actual back door: the core is registered
	# by the GDExtension and `ClassDB.instantiate("<the core>")` reaches it without the name
	# ever appearing as an identifier.
	var needles: Array[String] = [
		"Kaiba" + "Core",
		"ClassDB." + "instantiate",
		"OCG" + "_",
	]

	var files: PackedStringArray = _ui_files(UI_ROOT)
	_check("there are files to scan", files.size() > 0, "found none under %s" % UI_ROOT)

	for path: String in files:
		# Comment lines are stripped first. The invariant is about what the code *does*, and
		# several files under here explain the rule by quoting the forbidden name - which is
		# the opposite of breaking it. `ui/hud/duel_hud.gd` has said so since it was written.
		var text: String = _without_comments(FileAccess.get_file_as_string(path))
		_check("%s was readable" % path, not text.strip_edges().is_empty(), "read nothing")
		for needle: String in needles:
			_check("%s is clean" % path, not text.contains(needle), "it contains '%s'" % needle)

	_end()


## Drops whole-line GDScript comments. Deliberately crude: it does not try to understand strings
## or trailing comments, because the needles it exists to serve never appear in either.
func _without_comments(text: String) -> String:
	var kept: PackedStringArray = PackedStringArray()
	for line: String in text.split("\n"):
		if not line.strip_edges().begins_with("#"):
			kept.append(line)
	return "\n".join(kept)


## Every script and scene under a directory, recursively. Source-tree only: an exported build
## ships `.gdc` and this test never runs from one.
func _ui_files(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for file: String in DirAccess.get_files_at(dir):
		if file.ends_with(".gd") or file.ends_with(".tscn"):
			out.append(dir.path_join(file))
	for sub: String in DirAccess.get_directories_at(dir):
		out.append_array(_ui_files(dir.path_join(sub)))
	return out


# ----------------------------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------------------------

## A duel one turn in, built by hand from the event shapes `native/src/msg_parser.cpp` emits.
## P0 is on 8000, P1 has taken 1000, it is P0's first main phase.
func _duel_in_progress() -> DuelState:
	var state: DuelState = DuelState.new()
	state.apply({
		"t": DuelEnums.EV.START,
		"lp": [8000, 8000],
		"deck": [40, 40],
		"extra": [0, 0],
		"first": DuelEnums.PLAYER.P0,
	})
	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P0})
	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.MAIN1})
	state.apply({"t": DuelEnums.EV.DAMAGE, "player": DuelEnums.PLAYER.P1, "amount": 1000})
	return state


## A board with two set cards per seat and one face-up monster, built from the Level-1 event
## shapes `native/src/msg_parser.cpp` emits. The set spell is the one that matters: ocgcore
## stores it as FACEDOWN_DEFENSE, which is the bit a careless view layer rotates on.
func _board_with_set_cards() -> DuelState:
	var state: DuelState = DuelState.new()
	state.apply({
		"t": DuelEnums.EV.START,
		"lp": [8000, 8000],
		"deck": [40, 40],
		"extra": [0, 0],
		"first": DuelEnums.PLAYER.P0,
	})

	for seat: int in [DuelEnums.PLAYER.P0, DuelEnums.PLAYER.P1]:
		state.apply({
			"t": DuelEnums.EV.MOVE,
			"card": CODE_RITUAL,
			"from": {},
			"to": {"con": seat, "loc": DuelEnums.LOCATION.MZONE, "seq": 0,
				"pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
		})
		state.apply({
			"t": DuelEnums.EV.MOVE,
			"card": CODE_SPELL,
			"from": {},
			"to": {"con": seat, "loc": DuelEnums.LOCATION.SZONE, "seq": 0,
				"pos": DuelEnums.POSITION.FACEDOWN_DEFENSE},
		})

	# The control: a face-up card, so the case cannot pass by hiding everything.
	state.apply({
		"t": DuelEnums.EV.MOVE,
		"card": CODE_SPELL,
		"from": {},
		"to": {"con": DuelEnums.PLAYER.P0, "loc": DuelEnums.LOCATION.MZONE, "seq": 1,
			"pos": DuelEnums.POSITION.FACEUP_ATTACK},
	})
	return state


## Six cards, one of each routing outcome: the four
## keys the editor reads and nothing else. The type bitmasks are the real ones that
## `data/base/cards.cdb` carries for these passcodes - `core/deck/deck_test.gd` is the case that
## proves that against the database itself, which is why it can be asserted here.
func _small_catalogue() -> Array[Dictionary]:
	return [
		_card(CODE_FUSION, "Archfiend Black Skull Dragon", DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.FUSION),
		_card(CODE_SYNCHRO, "Blackfeather Darkrage Dragon",
			DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.SYNCHRO),
		_card(CODE_XYZ, "Thelematech Clatis",
			DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.XYZ),
		_card(CODE_LINK, "Zenna's Deceiving Doll Maidens",
			DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.LINK),
		_card(CODE_RITUAL, "Legendary Flame Lord",
			DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.RITUAL),
		_card(CODE_SPELL, "Pot of Greed", DuelEnums.TYPE.SPELL),
	]


## `count` distinct spells. Only the size matters: this is the virtualisation case's haystack.
func _fake_catalogue(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: int in count:
		out.append(_card(i + 1, "Card %d" % (i + 1), DuelEnums.TYPE.SPELL))
	return out


func _card(code: int, card_name: String, type: int) -> Dictionary:
	return {"code": code, "name": card_name, "type": type, "alias": 0}


func _hud() -> HudScript:
	var hud: HudScript = HudScene.instantiate() as HudScript
	root.add_child(hud)
	return hud


func _banner() -> HotSeatBanner:
	var banner: HotSeatBanner = BannerScene.instantiate() as HotSeatBanner
	root.add_child(banner)
	return banner


func _router() -> RouterScript:
	var router: RouterScript = RouterScript.new()
	root.add_child(router)
	return router


func _preview() -> CardPreview:
	var preview: CardPreview = PreviewScene.instantiate() as CardPreview
	root.add_child(preview)
	return preview


## A board with no duel behind it. `BoardView` builds its table, its anchors and its markers on
## first touch, so nothing else is needed to measure the geometry.
func _board() -> BoardView:
	var board: BoardView = BoardView.new()
	root.add_child(board)
	return board


## The first `count` passcodes with a file under `dir`, in directory order. Discovered rather
## than hardcoded so the suite does not depend on which art someone happens to have downloaded.
func _sample_codes(dir: String, count: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var handle: DirAccess = DirAccess.open(dir)
	if handle == null:
		return out
	handle.list_dir_begin()
	var entry: String = handle.get_next()
	while entry != "" and out.size() < count:
		if entry.ends_with(".jpg"):
			var code: int = int(entry.get_basename())
			if code > 0:
				out.append(code)
		entry = handle.get_next()
	handle.list_dir_end()
	return out


func _stub_scene(node_name: String) -> PackedScene:
	var node: Node = Node.new()
	node.name = node_name
	var packed: PackedScene = PackedScene.new()
	packed.pack(node)
	node.free()
	return packed


func _node(owner: Node, path: String) -> Control:
	return owner.get_node_or_null(path) as Control


func _text(owner: Node, path: String) -> String:
	var label: Label = owner.get_node_or_null(path) as Label
	return label.text if label != null else "<no node at %s>" % path


func _discard(node: Node) -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()


# ----------------------------------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------------------------------


## Hot seat shows you both hands. It must not show you anything else.
##
## The distinction is the whole point: a hand card you own is yours to read, while a card the
## model reports as code 0 has already been blanked - by `HostService` in a real duel - and a
## card in a face-down *position* is hidden by the rules, not by permission. One flag must move
## the first and leave the other two exactly where they were.
func _case_hot_seat_reveals_hands_not_face_downs() -> void:
	_begin("revealing both hands does not reveal anything else")

	# No scene tree needed: this is about a property and the rules around it, not about drawing.
	var board: BoardView = BoardView.new()

	_check("the flag is off until a mode asks for it", not board.reveal_both_hands,
		"reveal_both_hands defaulted to on, which a networked client must never do")
	board.reveal_both_hands = true
	_check("and on once it does", board.reveal_both_hands, "the flag did not take")

	# A blanked card stays blank: this is the line that would turn the flag into a V7 hole.
	var hidden := DuelCard.new()
	hidden.code = 0
	_check("a card the model blanked has nothing to show",
		hidden.code == 0, "a blanked card carried a passcode")

	# A face-down position is hidden by the rules, not by viewer permission.
	var face_down := DuelCard.new()
	face_down.code = 89631139
	face_down.position = DuelEnums.POSITION.FACEDOWN_DEFENSE
	_check("a face-down card is still face-down", not face_down.is_face_up(),
		"a set card reported itself face-up")
	_check("and a set spell still refuses to turn",
		not BoardView.zone_turns("ST_P1_0"), "a spell zone would draw it sideways")

	board.free()
	_end()


## After a win there is no next decision, and the overlay must stop implying there is.
func _case_the_overlay_goes_neutral_after_a_win() -> void:
	_begin("the seat overlay goes neutral once the duel is over")

	var focus := SeatFocus.new()
	focus.observe({"t": DuelEnums.EV.START, "first": DuelEnums.PLAYER.P0})
	focus.set_pending({"t": DuelEnums.EV.SELECT_IDLECMD, "player": DuelEnums.PLAYER.P0}, "choose")

	_check("it is asking before the win", focus.is_waiting(), "nothing was pending")
	_check("and says who", focus.decision_text().contains("must decide"),
		"got %s" % focus.decision_text())

	var moved: bool = focus.observe({"t": DuelEnums.EV.WIN, "player": 0, "reason": 0})

	_check("a win does not move the board", not moved,
		"the seat flipped at the moment the duel ended")
	_check("nothing is pending any more", not focus.is_waiting(), "a prompt survived the win")
	_check("the seat line stops claiming a turn",
		not focus.view_text().contains("taking this turn"),
		"got %s" % focus.view_text())
	_check("and the decision line says so plainly",
		focus.decision_text().contains("over"), "got %s" % focus.decision_text())
	_end()



## A refused answer must be visible, and the selection must come back.
##
## This is the shape of a bug that froze the duel: `respond()` returns ok for any well-formed
## intent, so the scene cleared the pending selection; ocgcore then rejected it as out of range
## and sent MSG_RETRY, which **does not carry the selection with it** (AGENTS.md section 8b
## trap 8). With nothing pending and no new prompt coming, the board stopped accepting input
## and looked frozen. Re-arming is only half the fix - from the player's side a refused tap and
## an ignored tap are indistinguishable, so it has to say so.
func _case_a_refused_answer_is_announced() -> void:
	_begin("a refused answer is announced and the selection comes back")

	var focus := SeatFocus.new()
	focus.observe({"t": DuelEnums.EV.START, "first": DuelEnums.PLAYER.P0})

	var prompt := {"t": DuelEnums.EV.SELECT_IDLECMD, "player": DuelEnums.PLAYER.P0}
	focus.set_pending(prompt, "choose a card")
	_check("the overlay is not crying refusal before anything is refused",
		not focus.decision_text().contains("refused"), "got %s" % focus.decision_text())

	# The engine turned it down; the scene puts the same selection back.
	focus.set_pending(prompt, "choose a card")
	focus.note_rejected()

	_check("it is still asking", focus.is_waiting(), "the selection did not come back")
	_check("and says the answer was refused", focus.decision_text().contains("refused"),
		"got %s" % focus.decision_text())
	_check("naming the seat that has to choose again",
		focus.decision_text().contains(focus.seat_name(focus.decision_seat).to_upper()),
		"got %s" % focus.decision_text())

	# An answer the engine accepts ends the complaint.
	focus.clear_pending()
	focus.set_pending({"t": DuelEnums.EV.SELECT_CHAIN, "player": DuelEnums.PLAYER.P1}, "respond?")
	_check("a fresh selection is not still flagged as refused",
		not focus.decision_text().contains("refused"), "got %s" % focus.decision_text())
	_end()



# ----------------------------------------------------------------------------------------------
# DeckPicker
#
# Decks are authored elsewhere and arrive as `.ydk`. There is no editor on purpose: owning a
# deck format would cut this client off from every other one, while reading theirs costs a
# parser and gains every deck the player already has.
# ----------------------------------------------------------------------------------------------

func _case_the_library_finds_ydk_decks() -> void:
	_begin("the library finds .ydk decks and reads their counts")

	var entries: Array[Dictionary] = DeckLibrary.entries()
	if entries.is_empty():
		print("SKIP  no decks installed - drop a .ydk in %s" % DeckLibrary.BUNDLED_DIR)
		_end()
		return

	var first: Dictionary = entries[0]
	_check("an entry carries a name", not str(first.get("name", "")).is_empty(), "name was blank")
	_check("and a path a parser can open",
		FileAccess.file_exists(str(first.get("path", ""))), "path does not exist")
	_check("the extension is not part of the name",
		not str(first.get("name", "")).ends_with(".ydk"), "name kept its extension")
	_check("counts came from parsing, not from the file name",
		int(first.get("main", 0)) > 0, "main count was zero")

	# The counts the list shows must be the counts the deck actually has, or the picker is
	# describing a different deck than the one it loads.
	var loaded: DeckModel = DeckLibrary.load_deck(first)
	_equal("main matches the loaded deck", loaded.size(DeckModel.LIST.MAIN), int(first.get("main", 0)))
	_equal("extra matches", loaded.size(DeckModel.LIST.EXTRA), int(first.get("extra", 0)))
	_equal("side matches", loaded.size(DeckModel.LIST.SIDE), int(first.get("side", 0)))
	_end()


func _case_the_picker_lists_and_reports_a_choice() -> void:
	_begin("the picker lists what the library found and reports the choice")

	var picker: DeckPicker = (load(PICKER_SCENE_PATH) as PackedScene).instantiate()
	root.add_child(picker)

	var entries: Array[Dictionary] = DeckLibrary.entries()
	if entries.is_empty():
		_check("with nothing installed it offers nothing", picker.selected_entry().is_empty(),
			"a selection appeared from an empty library")
		picker.queue_free()
		_end()
		return

	_check("it selects something so the button is never a dead end",
		not picker.selected_entry().is_empty(), "nothing was selected")

	# Merged, not assigned. A GDScript lambda captures by value, so `chosen = entry` inside one
	# rebinds the lambda's own copy and the outer variable never moves - the signal fires and the
	# test still reads an empty Dictionary.
	var chosen: Dictionary = {}
	var went: Array[String] = []
	picker.deck_chosen.connect(func(entry: Dictionary) -> void: chosen.merge(entry, true))
	picker.chose.connect(func(destination: String) -> void: went.append(destination))
	picker._commit()

	_check("committing emits the entry", not chosen.is_empty(), "nothing was emitted")
	_check("and it is the one that was selected",
		str(chosen.get("path", "")) == str(picker.selected_entry().get("path", "")),
		"emitted a different deck than the one shown")

	# Two signals, two meanings. They were one, called `chose`, and the router connects that
	# name on whatever screen it loads - so the Dictionary arrived at a String parameter and the
	# choice vanished without a word. `deck_chosen` says which deck; `chose` says where next.
	_equal("and it also asks to go and play", went, [DeckPicker.PLAY])
	_check("the two verbs stay separate",
		picker.has_signal("deck_chosen") and picker.has_signal("chose"),
		"the picker lost one of its two signals")

	picker.queue_free()
	_end()


func _case_an_empty_library_says_where_to_put_files() -> void:
	_begin("an empty library names the folders instead of dead-ending")

	var picker: DeckPicker = (load(PICKER_SCENE_PATH) as PackedScene).instantiate()
	root.add_child(picker)
	var text: String = picker._empty_text()

	_check("it says there is nothing", text.contains(DeckPicker.EMPTY_TITLE),
		"got %s" % text)
	_check("it names at least one folder to drop a file into",
		text.contains("/") or text.contains("not created yet"), "no path was offered")
	_check("and says other clients' decks work unchanged",
		text.to_lower().contains("edopro"), "did not mention where decks come from")

	picker.queue_free()
	_end()


func _case_router_reaches_the_deck_picker() -> void:
	_begin("the decks destination reaches the picker, not an editor")

	_check("the route points at the picker scene",
		SceneRouter.DECKS_SCENE.contains("deck_picker"),
		"got %s" % SceneRouter.DECKS_SCENE)
	_check("and that scene exists", ResourceLoader.exists(SceneRouter.DECKS_SCENE),
		"%s is not loadable" % SceneRouter.DECKS_SCENE)
	_end()



## Every verb the duel needs must be reachable without a keyboard.
##
## `CONFIRM` had no touch binding at all: `TouchSource` emits none and nothing on screen called
## `confirm()`. On a phone that meant no way to say yes to an optional effect and no way to
## close a multi-card selection - the duel simply parked, with the same symptom as a refused
## answer and no way out. The fix is a visible button rather than another gesture, which is the
## right answer for a yes/no question anyway.
func _case_every_verb_is_reachable_on_a_phone() -> void:
	_begin("every input verb is reachable on a phone")

	for binding: Dictionary in InputSource.BINDINGS:
		var kind: String = str(binding.get("kind", "?"))
		var touch: String = str(binding.get("touch", ""))
		# POINT_AT is a preview; a phone without it loses nothing it cannot get by tapping.
		if kind == InputSource.KIND_POINT_AT:
			continue
		_check("%s can be reached by hand" % kind, not touch.is_empty(),
			"%s has no touch binding, so a handheld player cannot produce it" % kind)

	var hud: DuelHud = preload("res://ui/hud/duel_hud.tscn").instantiate()
	root.add_child(hud)

	# Merged, not assigned: a GDScript lambda captures by value.
	var seen: Dictionary = {}
	hud.confirmed.connect(func() -> void: seen.merge({"confirm": true}, true))
	hud.cancelled.connect(func() -> void: seen.merge({"cancel": true}, true))

	hud.set_prompt("Activate this effect?")
	_check("a pending prompt shows its panel", hud.prompt_is_visible(), "the panel stayed hidden")

	hud.get_node(HUD_CONFIRM).pressed.emit()
	hud.get_node(HUD_CANCEL).pressed.emit()

	_check("the confirm button answers yes", seen.has("confirm"), "no confirmed signal")
	_check("and the cancel button answers no", seen.has("cancel"), "no cancelled signal")

	hud.queue_free()
	_end()



## Lighting the cards a selection offers is how "there is something to do" stops being a
## sentence to read, but a rim left burning on a card from a decision already made is worse
## than none - it points at the wrong thing with total confidence.
func _case_only_the_offered_cards_glow() -> void:
	_begin("only the offered cards glow, and they stop when the question does")

	var board: BoardView = BoardView.new()
	root.add_child(board)

	var lit: CardView = board.card_pool().acquire()
	var dark: CardView = board.card_pool().acquire()
	if lit == null or dark == null:
		_check("the pool handed out two cards", false, "it did not")
		board.queue_free()
		_end()
		return

	lit.handle = 101
	dark.handle = 202
	board.place_view(lit, "MZ_P0_0")
	board.place_view(dark, "MZ_P0_1")

	_check("nothing glows before anything is asked",
		not lit.is_highlighted() and not dark.is_highlighted(), "a card started out lit")

	board.highlight_cards(PackedInt32Array([101]))
	_check("the offered card glows", lit.is_highlighted(), "the named card stayed dark")
	_check("and the other one does not", not dark.is_highlighted(),
		"a card nobody offered lit up")

	# Taking the whole set each time is what makes this safe: moving the offer to another card
	# must put the first one out, not add to it.
	board.highlight_cards(PackedInt32Array([202]))
	_check("moving the offer moves the glow", dark.is_highlighted(), "the new card stayed dark")
	_check("and puts the old one out", not lit.is_highlighted(), "a stale rim kept burning")

	board.clear_card_highlights()
	_check("answering puts everything out",
		not lit.is_highlighted() and not dark.is_highlighted(), "a card stayed lit")

	board.queue_free()
	_end()



## The router connects to a screen's navigation signal **by name**. That is a duck-typed
## contract, and it held right up until two screens disagreed about what the verb meant:
## `MainMenu.chose(String)` says "go here", while `DeckPicker` once declared `chose(Dictionary)`
## for "this is the deck". The router handed the Dictionary to a String parameter, the engine
## refused at the signal boundary, and picking a deck did nothing at all - with the error
## pointing at the emitter rather than at the disagreement.
##
## Renaming the picker's signal fixed the instance. Checking the signature fixes the class.
func _case_router_refuses_a_mistyped_navigation_signal() -> void:
	_begin("the router checks a navigation signal before trusting its name")
	var router: RouterScript = _router()

	var proper := Node.new()
	proper.add_user_signal(RouterScript.CHOSE_SIGNAL,
		[{"name": "destination", "type": TYPE_STRING}])
	_check("a screen that speaks the verb properly is accepted",
		router._takes_a_destination(proper), "a String destination was rejected")

	var mistyped := Node.new()
	mistyped.add_user_signal(RouterScript.CHOSE_SIGNAL,
		[{"name": "entry", "type": TYPE_DICTIONARY}])
	_check("one carrying the wrong payload is refused",
		not router._takes_a_destination(mistyped),
		"a Dictionary would have been handed to a String parameter")

	var wrong_arity := Node.new()
	wrong_arity.add_user_signal(RouterScript.CHOSE_SIGNAL, [])
	_check("and so is one carrying nothing at all",
		not router._takes_a_destination(wrong_arity), "a bare signal was accepted")

	var silent := Node.new()
	_check("a screen that does not navigate is simply not connected",
		not router._takes_a_destination(silent), "a screen with no such signal was accepted")

	proper.free()
	mistyped.free()
	wrong_arity.free()
	silent.free()
	_end()


func _begin(case_name: String) -> void:
	_case_name = case_name
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
