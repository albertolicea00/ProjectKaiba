extends Node3D

## A hot-seat duel you can actually read: one person answers both seats, and the mode's whole
## job is making it obvious which seat that currently is.
##
##   godot --path game res://scenes/solo_test.tscn                # play it
##   godot --headless --path game res://scenes/solo_test.tscn     # self-checks, then quits
##
## Layer: L5. Like `scenes/duel_touch.gd` it is allowed to see L1, L3, L4 and L5 at once,
## because wiring them together is all it does. Nothing under `game/ui/`, `game/view/` or
## `game/platform/` may do the same; this file is the seam that keeps V1 true.
##
## -------------------------------------------------------------------------------------------
## What this adds over duel_touch
## -------------------------------------------------------------------------------------------
## `duel_touch.gd` already plays a real duel from touch input and already answers both seats
## from one `SelectionController`. It is the regression gate for the input path and is left
## alone. What it does not do is tell you *whose* half of the board you are looking at: the
## camera never leaves seat 0 and `DuelHud.local_player` is fixed, so a duel played from both
## sides is mechanically correct and visually unreadable.
##
## Three things are added here, and all three are presentation:
##
##   1. `SeatFocus`     the policy: which seat is in view, which seat is being asked.
##   2. `HotSeatBanner` the overlay: seat colour, phase and step, who must decide, and the
##                      banner for a prompt belonging to the half that is not in view.
##   3. the flip        a readable camera transition on turn change, built from `CameraRig`'s
##                      public exports so the rig itself stays a swappable slot.
##
## -------------------------------------------------------------------------------------------
## The camera rule, and why it is not "follow the prompt"
## -------------------------------------------------------------------------------------------
## **The camera flips on turn change only. Never on a mid-turn prompt.**
##
## `CameraRig.seat` mirrors the view and would happily follow `SeatFocus.decision_seat`. It
## must not: the non-turn player is handed priority constantly through `MSG_SELECT_CHAIN`, so
## the camera would swing on nearly every action and settle never. Instead an off-seat prompt
## raises a banner and lights the zones involved, and the player reads the far half upside down
## for that one decision.
##
## This is the same rule the animation layer follows. `CameraRig.cue()` is advisory precisely
## so a VR rig can ignore every framing command - moving a camera that a person's head is not
## moving is how you make them sick - and a mode whose legibility depended on constant camera
## motion would not survive that port.
##
## -------------------------------------------------------------------------------------------
## Honesty
## -------------------------------------------------------------------------------------------
## No cheats, no undo, no peek past the model.
##
## Both hands are drawn face-up, because in a hot seat duel both of them are yours - you are
## testing the game, not playing against someone. That is a view decision about cards you are
## already entitled to see, and it is the only reason `reveal_both_hands` exists.
##
## It is **not** a hole in invariant V7. Hidden information is blanked by `HostService` before
## an event leaves the host, so a networked client never receives the opposing hand's codes in
## the first place; there would be nothing here to reveal. A card the model reports as code 0
## still draws as a back, and a face-down card is drawn from the model's own position bits from
## both seats. A test mode that lied about visibility would hide exactly the bugs it exists to
## find.
##
## -------------------------------------------------------------------------------------------
## The headless run
## -------------------------------------------------------------------------------------------
## Headless has no renderer and no finger, so the checks are about state. `_synthesise_intent()`
## builds the `InputIntent` a tap would have produced and everything from there on is the code a
## real tap runs through. The run plays several turns so that a turn change - and the seat flip
## it causes - actually happens, and then asserts on what the focus and the overlay hold.

signal chose(destination: String)

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"
const SCRIPT_ROOTS: Array[String] = [
	"res://../data/base/script",
	"res://../data/base/script/official",
	"res://../data/base/script/unofficial",
	"res://../data/base/script/pre-release",
]

## A diverse deck for testing: level 4 beaters, a tribute monster, draw spell, equip spell,
## field-clearing spell, attack-negating trap, and the trap that validates face-down rendering.
const BEATERS: Array[int] = [11091375, 14898066, 33256280, 35052053]
const BIG: int = 89631139
const POT_OF_GREED: int = 55144522
const DARK_HOLE: int = 53129443
const NEGATE_ATTACK: int = 14315573
const AXE_OF_DESPAIR: int = 40619825

## Trap Hole. Validates face-down rendering: a trap is only ever offered in `sset`, making
## it the one card a player can set from input alone regardless of priority resolution.
const TRAP_HOLE: int = 4206964
const DECK_SIZE: int = 40

## Set when a chosen deck is loaded, for the log line and the HUD.
## Prompts answered without asking, because they offered nothing to choose.
var _auto_passed: int = 0

## Prompts the passive opponent answered for itself, in Solo.
var _opponent_answers: int = 0

var _preview: CardPreview = null
var _action_menu: ActionMenu = null
var _pile_browser: PileBrowser = null
var _duel_log: DuelLog = null

var _deck_name: String = ""
var _extra_for_play: PackedInt32Array = PackedInt32Array()
var _chain_handles: Dictionary = {}
var _last_hint_card: String = ""
var _last_hint_msg: String = ""
var _system_strings: Dictionary = {}
var _victory_strings: Dictionary = {}
var _counter_strings: Dictionary = {}
var _setname_strings: Dictionary = {}

const START_LP: int = 8000
const START_HAND: int = 5
const DRAW_COUNT: int = 1

const FIRST_SELECT_EVENT: int = DuelEnums.EV.SELECT_BATTLECMD
const LAST_SELECT_EVENT: int = DuelEnums.EV.SELECT_UNSELECT_CARD

const MAX_EVENTS_PER_FRAME: int = 64
const IDLE_FRAMES_BEFORE_GIVING_UP: int = 900
const MAX_FRAMES: int = 20000
const MAX_INTENTS_PER_SELECTION: int = 16

const HEADLESS_DURATION_SCALE: float = 0.05

## How many seat flips the headless run wants before it is satisfied. Two means the view
## followed the turn player out to the other seat and back, which is a full cycle; one would
## only prove it can leave.
const FLIPS_WANTED: int = 2

## Turn 1 for the first player, turn 2 for the other, turn 3 back again.
const TURNS_WANTED: int = 3

# --- the flip ---------------------------------------------------------------------------------

## Seconds each half of the camera transition takes. The view rises to near top-down, changes
## seat at the apex where the half-turn is barely a rotation, and settles back down. A snap
## across the table is disorienting; this reads as the board being turned round.
const FLIP_SECONDS: float = 0.45

## Elevation at the apex, in degrees above the table. `CameraRig` clamps at 89.
const FLIP_ELEVATION: float = 88.0

const HUD_SCENE: PackedScene = preload("res://ui/hud/duel_hud.tscn")
const PREVIEW_SCENE: PackedScene = preload("res://ui/preview/card_preview.tscn")

## Both seats are yours. Off for Solo, where the far seat is answered by `PassiveAgent` and the
## camera never leaves yours.
##
## One scene, two modes, because the only honest difference between them *is* who answers the
## other seat - everything else, the board, the input, the rules, is identical. Two scripts
## would have been two places for that to drift.
@export var hot_seat: bool = true

## The seat you play when `hot_seat` is off.
const LOCAL_SEAT: int = 0
const BANNER_SCENE: PackedScene = preload("res://ui/hud/hot_seat_banner.tscn")

@onready var _board: BoardView = $World3D/BoardView
@onready var _director: AnimationDirector = $AnimationDirector
@onready var _rig: CameraRig = $World3D/CameraRig
@onready var _touch: TouchSource = $InputLayer/TouchSource
@onready var _mouse: MouseSource = $InputLayer/MouseSource

var _art: CardArt = null
var _audio: AudioDirector = null
var _hud: DuelHud = null
var _banner: HotSeatBanner = null

var _core: Object = null
var _state: DuelState = DuelState.new()
var _translator: EventTranslator = EventTranslator.new()
var _selection: SelectionController = null
var _focus: SeatFocus = SeatFocus.new()

var _headless: bool = false
var _failures: PackedStringArray = PackedStringArray()

var _running: bool = false
var _stopping: bool = false
var _frames: int = 0
var _idle_frames: int = 0
var _event_count: int = 0
var _suppressed_logs: int = 0
var _intents_this_selection: int = 0

## The selection most recently handed to `SelectionController`, for re-arming after a RETRY.
var _last_selection: Dictionary = {}

## Base elevation the rig was authored with, restored at the end of every flip.
var _rest_elevation: float = 0.0
var _flip_tween: Tween = null

# --- what the headless player has already done ------------------------------------------------
var _set_trap: bool = false
var _summoned: bool = false

# --- evidence ---------------------------------------------------------------------------------

## Every prompt seen, as `{"seat": int, "in_view": int, "event": int}`, recorded at the moment
## the prompt arrived. The off-seat ones are the whole point: the view must not have moved.
var _prompts: Array[Dictionary] = []
var _offscreen_prompts: int = 0
var _camera_moved_on_prompt: int = 0
var _decision_mismatches: int = 0

## phase bit -> the string the readout produced for it.
var _phases_seen: Dictionary = {}
var _blank_phase_readouts: int = 0

## Seat the view held when each `NEW_TURN` was applied, against the turn player it named.
var _turn_changes: int = 0
var _seat_lagged_turn: int = 0

## Face-down cards checked from both seats, and any that leaked their face.
var _facedown_checks: int = 0
var _set_zones_audited: int = 0
var _facedown_leaks: PackedStringArray = PackedStringArray()
var _sideways_sets: PackedStringArray = PackedStringArray()

var _answers_from_intents: int = 0
var _retries: int = 0


func _ready() -> void:
	set_process(false)
	_headless = DisplayServer.get_name() == "headless" or OS.get_cmdline_args().has("--headless")

	_load_system_strings()
	_selection = SelectionController.new(_state)

	_rest_elevation = _rig.elevation
	_rig.activate()

	_hud = HUD_SCENE.instantiate() as DuelHud
	add_child(_hud)
	# Hot seat: both hands belong to whoever is holding the device. See Honesty above.
	_board.reveal_both_hands = true

	# The only route to CONFIRM on a phone. `TouchSource` emits none - there is no finger
	# gesture for it - so without these a handheld player cannot say yes to an optional effect
	# or close a multi-card selection, and the duel parks with no way out.
	_hud.confirmed.connect(func() -> void: _on_intent({"kind": InputSource.KIND_CONFIRM}))
	_hud.cancelled.connect(func() -> void: _on_intent({"kind": InputSource.KIND_CANCEL}))
	_hud.phase_pressed.connect(_on_phase_pressed)
	_hud.menu_pressed.connect(_offer_surrender)

	# Solo watches one half all duel; hot seat turns the board on every turn change.
	_focus.follow_turn = hot_seat

	_preview = PREVIEW_SCENE.instantiate() as CardPreview
	add_child(_preview)
	_setup_side_preview()

	_action_menu = ActionMenu.new()
	_action_menu.name = "ActionMenu"
	add_child(_action_menu)
	_action_menu.action_chosen.connect(_on_action_chosen)
	_action_menu.dismissed.connect(_on_action_dismissed)

	_pile_browser = PileBrowser.new()
	_pile_browser.name = "PileBrowser"
	_pile_browser.card_selected.connect(_on_pile_card_selected)
	add_child(_pile_browser)

	if not _headless:
		_duel_log = DuelLog.new()
		_duel_log.name = "DuelLog"
		add_child(_duel_log)

	_hud.bind(_state)

	# A separate layer from the HUD on purpose: `DuelHud` is what a networked client shows,
	# where there is one local seat and none of this applies. Everything the banner draws is
	# specific to one person playing both halves.
	_banner = BANNER_SCENE.instantiate() as HotSeatBanner
	add_child(_banner)
	_banner.bind(_state, _focus)

	_art = CardArt.new()
	CardView.art_source = _art

	_director.bind(_board)
	# Advisory only - the rig decides whether to take a cue (CameraRig.cue()).
	_director.camera_cue.connect(_rig.cue)
	if _headless:
		_director.duration_scale = HEADLESS_DURATION_SCALE
	_director.queue_drained.connect(_on_queue_drained)

	_audio = AudioDirector.new()
	_audio.name = "AudioDirector"
	add_child(_audio)
	_audio.bind(_director)
	_audio.set_music_context(AudioDirector.MUSIC_DUEL)

	for source: InputSource in [_touch, _mouse]:
		source.bind(_rig, _board)
		source.intent.connect(_on_intent)

	_apply_seat(_focus.seat_in_view)
	_start_duel()


func _process(_delta: float) -> void:
	if _art != null:
		_board.refresh_art(_art)

	if _hud != null:
		_hud.refresh()
		var prompt: String = _selection.pending_prompt() if _selection != null else ""
		if not prompt.is_empty():
			if not _last_hint_msg.is_empty():
				prompt = "%s — %s" % [_last_hint_msg, prompt]
			elif not _last_hint_card.is_empty():
				prompt = "[%s] %s" % [_last_hint_card, prompt]
		_hud.set_prompt(prompt)
	if _banner != null:
		_banner.refresh()

	_frames += 1
	if _frames > MAX_FRAMES:
		_stop("frame budget exhausted")
		return
	if not _running:
		return

	var drained: int = 0
	while drained < MAX_EVENTS_PER_FRAME:
		var event: Variant = _core.poll_event()
		if event == null:
			break
		drained += 1
		_handle(event as Dictionary)
		if _stopping:
			return

	if _headless and _selection.is_waiting():
		_drive_headless()
		return

	if drained > 0:
		_idle_frames = 0
		return
	_idle_frames += 1
	if _headless and _idle_frames >= IDLE_FRAMES_BEFORE_GIVING_UP:
		_stop("no further events; the duel thread has gone quiet")


# ----------------------------------------------------------------------------------------------
# Duel
# ----------------------------------------------------------------------------------------------

func _start_duel() -> void:
	if not ClassDB.class_exists(CORE_CLASS):
		_fail("%s is not registered; the GDExtension did not load. Run: make host" % CORE_CLASS)
		_stop("no core")
		return
	_core = ClassDB.instantiate(CORE_CLASS)

	if not FileAccess.file_exists(ProjectSettings.globalize_path(CDB_PATH)):
		_fail("%s is missing; see docs/DATA.md" % CDB_PATH)
		_stop("no card database")
		return

	var loaded: Dictionary = _core.load_card_database(CDB_PATH)
	if not bool(loaded.get("ok", false)):
		_fail("could not load %s: %s" % [CDB_PATH, loaded.get("error", "?")])
		_stop("no card database")
		return
	print("[solo] card database loaded: %d cards" % int(loaded.get("count", 0)))
	for root: String in SCRIPT_ROOTS:
		_core.add_script_root(root)

	# Resolved once: both seats play the same list, and asking twice would parse the file twice.
	var main_deck: PackedInt32Array = _deck_for_play()
	var opp_deck: PackedInt32Array = main_deck.duplicate()
	if not _headless:
		_shuffle_array(main_deck)
		_shuffle_array(opp_deck)
	if _art != null:
		_art.preload_codes(main_deck)

	var started: Dictionary = _core.start_duel({
		"start_lp": START_LP,
		"start_hand": START_HAND,
		"draw_count": DRAW_COUNT,
		"deck_p0": main_deck,
		"deck_p1": opp_deck,
		"extra_p0": _extra_for_play,
		"extra_p1": _extra_for_play,
	})
	if not bool(started.get("ok", false)):
		_fail("start_duel failed: %s" % started.get("error", "?"))
		_stop("duel did not start")
		return

	# ocgcore never emits MSG_START (AGENTS.md section 8b.1); the host synthesises it.
	_handle({
		"t": DuelEnums.EV.START,
		"lp": [START_LP, START_LP],
		"deck": [main_deck.size(), main_deck.size()],
		"extra": [0, 0],
		"first": 0,
	})
	_board.sync_from_state(_state)
	var seating: String = (
		"Both seats are yours; the frame colour is whose half you are looking at."
		if hot_seat
		else "You are Player 1. The opponent passes and ends its turn - it has no opinion yet.")
	print("[solo] %s - %d main, %d extra. %s" % [
		_deck_name if not _deck_name.is_empty() else "built-in deck",
		main_deck.size(), _extra_for_play.size(), seating])
	_running = true
	set_process(true)


## The deck both seats play.
##
## Whatever the player chose in the picker, loaded from its `.ydk` every time rather than
## cached - the file is the truth, so editing it in EDOPro and coming back picks up the edit.
## Falls back to the built-in list when no deck is installed, so a fresh checkout still boots
## into a playable duel instead of a dead end.
func _deck_for_play() -> PackedInt32Array:
	# The headless audit asserts things only the built-in list can produce - a trap is the only
	# card a tap can *set*, because ocgcore offers every monster as both `summon` and `mset` and
	# every spell as both `activate` and `sset`, so a tap always lands on the face-up command.
	# Running the audit against whatever deck happens to be installed would make a green gate
	# depend on the player's deck folder, which is the opposite of what a gate is for.
	if _headless:
		return _build_deck()

	var entry: Dictionary = DeckLibrary.chosen()
	if entry.is_empty():
		return _build_deck()

	var deck: DeckModel = DeckLibrary.load_deck(entry)
	var main: PackedInt32Array = deck.cards(DeckModel.LIST.MAIN)
	if main.is_empty():
		return _build_deck()

	_deck_name = str(entry.get("name", ""))
	_extra_for_play = deck.cards(DeckModel.LIST.EXTRA)
	return main


static func _shuffle_array(arr: PackedInt32Array) -> void:
	for i: int in range(arr.size() - 1, 0, -1):
		var j: int = randi_range(0, i)
		var tmp: int = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## The built-in fallback: a diverse deck that exercises summon, set, equip, field-clear,
## attack negation and draw. Gives both players enough variety to test all gameplay paths.
func _build_deck() -> PackedInt32Array:
	var deck: PackedInt32Array = PackedInt32Array()
	for index: int in DECK_SIZE:
		if index % 10 == 0:
			deck.append(BIG)
		elif index == 7 or index == 21:
			deck.append(TRAP_HOLE)
		elif index == 14:
			deck.append(NEGATE_ATTACK)
		elif index == 28:
			deck.append(DARK_HOLE)
		elif index == 3 or index == 23:
			deck.append(AXE_OF_DESPAIR)
		elif index % 5 == 0:
			deck.append(POT_OF_GREED)
		else:
			deck.append(BEATERS[index % BEATERS.size()])
	return deck


func _handle(event: Dictionary) -> void:
	var type: int = int(event.get("t", -1))

	# 1000-1099 are DuelThread lifecycle events, not ocgcore opcodes.
	match type:
		1000:
			return
		1001:
			_stop("duel ended cleanly")
			return
		1002, 1003:
			if type == 1002 and not event.has("log_type"):
				_fail("core error at stage '%s': %s" % [event.get("stage", "?"), event.get("detail", "?")])
				_stop("core reported a fatal error")
				return
			_suppressed_logs += 1
			return

	_event_count += 1

	# L3 first - the model is authoritative and updates instantly. Then Level 2, which is lossy
	# and never stored (V9), and only after `apply()` so handles resolve at the destination.
	_state.apply(event)
	_log_event(type, event)
	var intents: Array[Dictionary] = _translator.translate(event, _state)
	if not intents.is_empty():
		_director.enqueue(intents)

	# The view policy. `observe()` moves the seat on START and NEW_TURN and on nothing else.
	# `observe()` always tracks the turn player - the HUD needs that either way - but the board
	# only turns in hot seat. In Solo you are Player 1 for the whole duel, and a camera that
	# swung to the opponent's half on their turn would be showing you a board you cannot act on.
	if _focus.observe(event) and hot_seat:
		_begin_flip()

	match type:
		DuelEnums.EV.START:
			if _hud != null and not _headless:
				_hud.show_duel_start()
			if _audio != null:
				_audio.play_effect("playerenter")
		DuelEnums.EV.NEW_TURN:
			_turn_changes += 1
			if _focus.seat_in_view != _state.turn_player:
				_seat_lagged_turn += 1
			if _hud != null and not _headless:
				_hud.show_turn_banner(_state.turn_player)
			_stop_if_satisfied()
			if _stopping:
				return
		DuelEnums.EV.ATTACK:
			_show_combat(event)
			var atk_card: DuelCard = _card_at_loc(event.get("from", {}))
			if atk_card != null:
				_board.set_card_indicator(atk_card.handle, "attack")
				var atk_at: Dictionary = event.get("from", {}) as Dictionary
				if not atk_at.is_empty():
					_board.flash_zone(EventTranslator.anchor_of(atk_at), Color(1.0, 0.3, 0.3, 0.9))
			var def_card: DuelCard = _card_at_loc(event.get("to", {}))
			if def_card != null:
				_board.set_card_indicator(def_card.handle, "target")
				var def_at: Dictionary = event.get("to", {}) as Dictionary
				if not def_at.is_empty():
					_board.flash_zone(EventTranslator.anchor_of(def_at), Color(1.0, 0.6, 0.2, 0.9))
				if atk_card != null:
					_board.add_target_line(atk_card.handle, def_card.handle, Color(1.0, 0.3, 0.3, 0.9))
		DuelEnums.EV.BATTLE:
			_show_combat(event)
			if bool(event.get("direct", false)):
				var battle_player: int = int(event.get("from_player", int(event.get("player", 0))))
				var target_player: int = 1 - battle_player
				if _hud != null:
					_hud.flash_lp_text(target_player, true)
		DuelEnums.EV.NEW_PHASE:
			if _hud != null:
				_hud.set_combat(null, null)
			_board.clear_card_indicators()
			_board.clear_card_chain_numbers()
			_board.clear_target_lines()
			_record_phase()
		DuelEnums.EV.SUMMONING, DuelEnums.EV.SPSUMMONING, DuelEnums.EV.FLIPSUMMONING:
			var summon_card: DuelCard = _card_at_loc(event.get("at", {}))
			if summon_card != null:
				_board.set_card_indicator(summon_card.handle, "act")
				if not _headless:
					_preview_code(summon_card.code)
			var summon_at: Dictionary = event.get("at", {}) as Dictionary
			if not summon_at.is_empty():
				var summon_colour: Color = Color(1.0, 0.55, 0.85, 1.0) if type == DuelEnums.EV.SPSUMMONING else Color(0.72, 0.84, 1.0, 1.0)
				_board.flash_zone(EventTranslator.anchor_of(summon_at), summon_colour)
			if type == DuelEnums.EV.SPSUMMONING and _hud != null and not _headless:
				_hud.flash_screen(Color(0.5, 0.2, 0.7, 0.2))
			elif type == DuelEnums.EV.FLIPSUMMONING and _hud != null and not _headless:
				_hud.flash_screen(Color(0.9, 0.8, 0.2, 0.2))
		DuelEnums.EV.SUMMONED, DuelEnums.EV.SPSUMMONED, DuelEnums.EV.FLIPSUMMONED:
			_board.clear_card_indicators()
			_board.clear_target_lines()
			if _preview != null and not _headless:
				_preview.hide_card()
		DuelEnums.EV.CHAINING:
			var chain_card: DuelCard = _card_at_loc(event.get("at", {}))
			if chain_card != null:
				_board.set_card_indicator(chain_card.handle, "chain")
				var chain_num: int = int(event.get("chain_size", 0))
				if chain_num > 0:
					_board.set_card_chain_number(chain_card.handle, chain_num)
					_chain_handles[chain_num] = chain_card.handle
					if chain_num >= 2 and _hud != null and not _headless:
						_hud.flash_screen(Color(0.2, 0.4, 0.8, 0.12 + 0.04 * chain_num))
				if not _headless:
					_preview_code(chain_card.code)
				var at_info: Dictionary = event.get("at", {}) as Dictionary
				if not at_info.is_empty():
					_board.flash_zone(EventTranslator.anchor_of(at_info), Color(0.4, 0.85, 1.0, 1.0))
		DuelEnums.EV.CHAIN_SOLVING:
			var solving_idx: int = int(event.get("chain_index", 0))
			if _chain_handles.has(solving_idx):
				_board.set_card_indicator(int(_chain_handles[solving_idx]), "act")
		DuelEnums.EV.CHAINED:
			var chained_idx: int = int(event.get("chain_index", 0))
			if _chain_handles.has(chained_idx):
				_board.set_card_indicator(int(_chain_handles[chained_idx]), "chain")
		DuelEnums.EV.CHAIN_SOLVED:
			var solved_idx: int = int(event.get("chain_index", 0))
			if _chain_handles.has(solved_idx):
				_board.clear_card_indicator(int(_chain_handles[solved_idx]))
		DuelEnums.EV.CHAIN_END:
			_board.clear_card_indicators()
			_board.clear_card_chain_numbers()
			_board.clear_target_lines()
			_chain_handles.clear()
			if _preview != null and not _headless:
				_preview.hide_card()
		DuelEnums.EV.DRAW:
			var draw_player: int = int(event.get("player", 0))
			_board.flash_zone("DECK_P%d" % draw_player, Color(0.5, 0.7, 1.0, 0.7))
			_board.flash_zone("HAND_P%d" % draw_player, Color(0.4, 0.65, 0.9, 0.5))
		DuelEnums.EV.SHUFFLE_DECK:
			var shuf_player: int = int(event.get("player", 0))
			_board.flash_zone("DECK_P%d" % shuf_player, Color(0.6, 0.5, 0.8, 0.6))
		DuelEnums.EV.SHUFFLE_HAND:
			var shuf_h_player: int = int(event.get("player", 0))
			_board.flash_zone("HAND_P%d" % shuf_h_player, Color(0.6, 0.5, 0.8, 0.6))
		DuelEnums.EV.TOSS_COIN, DuelEnums.EV.TOSS_DICE:
			var toss_player: int = int(event.get("player", 0))
			_board.flash_zone("DECK_P%d" % toss_player, Color(1.0, 0.85, 0.3, 0.8))
		DuelEnums.EV.SHUFFLE_SET_CARD:
			if _audio != null:
				_audio.play_effect("shuffle")
			var ssc_to: Array = event.get("to", []) as Array
			for loc: Dictionary in ssc_to:
				if not loc.is_empty():
					_board.flash_zone(EventTranslator.anchor_of(loc), Color(0.8, 0.7, 1.0, 0.7))
			_board.sync_from_state(_state)
		DuelEnums.EV.EQUIP:
			var equip_card: DuelCard = _card_at_loc(event.get("from", {}))
			if equip_card != null:
				_board.set_card_indicator(equip_card.handle, "equip")
			var equipped_monster: DuelCard = _card_at_loc(event.get("to", {}))
			if equipped_monster != null:
				_board.set_card_indicator(equipped_monster.handle, "equip")
			if equip_card != null and equipped_monster != null:
				_board.add_target_line(equip_card.handle, equipped_monster.handle, Color(0.3, 0.8, 1.0, 0.7))
		DuelEnums.EV.BECOME_TARGET:
			var targets: Array = event.get("cards", [])
			for loc: Dictionary in targets:
				var tgt: DuelCard = _card_at_loc(loc)
				if tgt != null:
					_board.set_card_indicator(tgt.handle, "target")
					var tgt_at: Dictionary = loc as Dictionary
					if not tgt_at.is_empty():
						_board.flash_zone(EventTranslator.anchor_of(tgt_at), Color(1.0, 0.3, 0.3, 0.7))
		DuelEnums.EV.CHAIN_NEGATED, DuelEnums.EV.CHAIN_DISABLED:
			var neg_chain: int = int(event.get("chain_index", 0))
			if _chain_handles.has(neg_chain):
				_board.set_card_indicator(int(_chain_handles[neg_chain]), "negated")
			_board.clear_card_chain_numbers()
		DuelEnums.EV.CARD_TARGET:
			var card_tgt: DuelCard = _card_at_loc(event.get("to", {}))
			if card_tgt != null:
				_board.set_card_indicator(card_tgt.handle, "target")
				var ct_at: Dictionary = event.get("to", {}) as Dictionary
				if not ct_at.is_empty():
					_board.flash_zone(EventTranslator.anchor_of(ct_at), Color(1.0, 0.4, 0.2, 0.7))
				var tgt_src: DuelCard = _card_at_loc(event.get("from", {}))
				if tgt_src != null:
					_board.add_target_line(tgt_src.handle, card_tgt.handle)
		DuelEnums.EV.CANCEL_TARGET:
			var cancel_tgt: DuelCard = _card_at_loc(event.get("to", {}))
			if cancel_tgt != null:
				_board.clear_card_indicator(cancel_tgt.handle)
		DuelEnums.EV.CARD_SELECTED:
			var sel_cards: Array = event.get("cards", [])
			for sel_loc: Dictionary in sel_cards:
				var sel_card: DuelCard = _card_at_loc(sel_loc)
				if sel_card != null:
					_board.set_card_indicator(sel_card.handle, "target")
					if not sel_loc.is_empty():
						_board.flash_zone(EventTranslator.anchor_of(sel_loc), Color(1.0, 0.5, 0.2, 0.6))
		DuelEnums.EV.BE_CHAIN_TARGET:
			var bct_cards: Array = event.get("cards", [])
			for bct_loc: Dictionary in bct_cards:
				var bct_card: DuelCard = _card_at_loc(bct_loc)
				if bct_card != null:
					_board.set_card_indicator(bct_card.handle, "chaintarget")
					if not bct_loc.is_empty():
						_board.flash_zone(EventTranslator.anchor_of(bct_loc), Color(1.0, 0.3, 0.3, 0.7))
		DuelEnums.EV.UNEQUIP:
			var uneq_card: DuelCard = _card_at_loc(event.get("from", {}))
			if uneq_card != null:
				_board.clear_card_indicator(uneq_card.handle)
		DuelEnums.EV.CONFIRM_EXTRATOP:
			if not _headless:
				_show_confirm_cards(event, false)
		DuelEnums.EV.FIELD_DISABLED:
			_board.set_disabled_zones(int(event.get("flag", 0)))
		DuelEnums.EV.PAY_LPCOST:
			var pay_player: int = int(event.get("player", 0))
			if _hud != null:
				_hud.show_lp_change(pay_player, -int(event.get("amount", 0)))
				_hud.flash_lp_text(pay_player, true)
			if _audio != null:
				_audio.play_effect("damage")
		DuelEnums.EV.CONFIRM_CARDS, DuelEnums.EV.CONFIRM_DECKTOP:
			if not _headless:
				_show_confirm_cards(event, type == DuelEnums.EV.CONFIRM_DECKTOP)
			if _audio != null:
				_audio.play_effect("flip")
		DuelEnums.EV.ADD_COUNTER, DuelEnums.EV.REMOVE_COUNTER:
			var cnt_card: DuelCard = _card_at_loc(event.get("at", {}))
			if cnt_card != null:
				_board.flash_zone(EventTranslator.anchor_of(event.get("at", {})),
					Color(1.0, 0.85, 0.3, 0.8) if type == DuelEnums.EV.ADD_COUNTER else Color(0.7, 0.4, 0.4, 0.8))
			_board.sync_from_state(_state)
		DuelEnums.EV.MOVE:
			var move_from: Dictionary = event.get("from", {}) as Dictionary
			var move_to: Dictionary = event.get("to", {}) as Dictionary
			var move_reason: int = int(event.get("reason", 0))
			if not move_from.is_empty():
				var from_loc: int = int(move_from.get("loc", 0))
				if (from_loc == DuelEnums.LOCATION.MZONE or from_loc == DuelEnums.LOCATION.SZONE) \
						and (move_reason & DuelEnums.REASON.DESTROY) != 0:
					_board.flash_zone(EventTranslator.anchor_of(move_from), Color(1.0, 0.15, 0.15, 0.9))
			if not move_to.is_empty():
				var to_loc: int = int(move_to.get("loc", 0))
				if to_loc == DuelEnums.LOCATION.MZONE or to_loc == DuelEnums.LOCATION.SZONE:
					var move_colour: Color = Color(0.8, 0.4, 0.4, 0.7)
					if (move_reason & DuelEnums.REASON.DESTROY) != 0:
						move_colour = Color(1.0, 0.2, 0.2, 0.9)
					elif to_loc == DuelEnums.LOCATION.SZONE:
						move_colour = Color(0.4, 0.8, 0.5, 0.7)
					_board.flash_zone(EventTranslator.anchor_of(move_to), move_colour)
				elif to_loc == DuelEnums.LOCATION.GRAVE:
					var gy_player: int = int(move_to.get("con", 0))
					_board.flash_zone("GY_P%d" % gy_player, Color(0.6, 0.4, 0.6, 0.6))
				elif to_loc == DuelEnums.LOCATION.REMOVED:
					var ban_player: int = int(move_to.get("con", 0))
					_board.flash_zone("BANISH_P%d" % ban_player, Color(0.4, 0.3, 0.6, 0.6))
				elif to_loc == DuelEnums.LOCATION.HAND:
					var hand_player: int = int(move_to.get("con", 0))
					_board.flash_zone("HAND_P%d" % hand_player, Color(0.4, 0.65, 0.9, 0.5))
		DuelEnums.EV.UPDATE_DATA, DuelEnums.EV.UPDATE_CARD:
			_board.sync_from_state(_state)
		DuelEnums.EV.WIN:
			_board.clear_card_indicators()
			_board.clear_card_chain_numbers()
			_board.clear_target_lines()
			_board.clear_highlights()
			if _hud != null:
				_hud.show_result(_state.winner)
			if _audio != null:
				var is_local_win: bool = int(event.get("player", -1)) == LOCAL_SEAT
				_audio.set_music_context("win" if is_local_win else "lose")
		DuelEnums.EV.DAMAGE:
			var dmg_amount: int = int(event.get("amount", 0))
			var dmg_player: int = int(event.get("player", 0))
			if _hud != null:
				_hud.show_lp_change(dmg_player, -dmg_amount)
				_hud.flash_lp_text(dmg_player, true)
				if dmg_amount >= DuelHud.DAMAGE_FLASH_THRESHOLD:
					_hud.flash_damage()
			if _audio != null:
				_audio.play_effect("damage")
		DuelEnums.EV.RECOVER:
			var rec_player: int = int(event.get("player", 0))
			if _hud != null:
				_hud.show_lp_change(rec_player, int(event.get("amount", 0)))
				_hud.flash_lp_text(rec_player, false)
			if _audio != null:
				_audio.play_effect("gainlp")
		DuelEnums.EV.RETRY:
			# ocgcore turned the last answer down. It is well-formed - `respond()` already said
			# so - but out of range for what was offered, typically a tap on a card the engine
			# did not list. The engine does **not** re-send the selection, so re-arm the one we
			# are still holding rather than waiting for a prompt that will never come.
			#
			# Not fatal here. A person mis-tapping is ordinary; ending their duel over it would
			# be absurd. The headless audit still counts retries, so a self-driving run that
			# produces one is still a failure.
			_retries += 1
			_rearm_after_retry()
			return

	if type == DuelEnums.EV.HINT:
		var hint_type: int = int(event.get("hint_type", 0))
		var hint_data: int = int(event.get("data", 0))
		if hint_type == 1:
			var ev_str: String = _system_string(hint_data)
			if not ev_str.is_empty() and _duel_log != null:
				_duel_log.append_system(ev_str)
		elif hint_type == 2:
			var msg_str: String = _system_string(hint_data)
			if not msg_str.is_empty() and _duel_log != null:
				_duel_log.append(msg_str)
		elif hint_type == 3:
			_last_hint_msg = _system_string(hint_data)
		elif hint_type == 4:
			var op_str: String = _system_string(hint_data)
			if not op_str.is_empty() and _duel_log != null:
				_duel_log.append_system("Opponent: %s" % op_str)
		elif hint_type == 5:
			_last_hint_card = _card_name(hint_data) if hint_data != 0 else ""
		elif hint_type == 6:
			var race_str: String = _system_string(hint_data)
			if not race_str.is_empty() and _duel_log != null:
				_duel_log.append_system("Race: %s" % race_str)
		elif hint_type == 7:
			var attr_str: String = _system_string(hint_data)
			if not attr_str.is_empty() and _duel_log != null:
				_duel_log.append_system("Attribute: %s" % attr_str)
		elif hint_type == 8:
			if hint_data != 0 and _duel_log != null:
				_duel_log.append_system("Card: %s" % _card_name(hint_data))
		elif hint_type == 9:
			if _duel_log != null:
				_duel_log.append_system("Number: %d" % hint_data)
		elif hint_type == 10:
			if hint_data != 0 and _duel_log != null:
				_duel_log.append_system("Declared: %s" % _card_name(hint_data))
		elif hint_type == 11 and hint_data != 0:
			_board.flash_zone_mask(hint_data, Color(0.5, 1.0, 0.7, 0.8))
		return

	if _headless and _set_trap and _set_zones_audited == 0:
		_audit_facedown()

	if type == DuelEnums.EV.ROCK_PAPER_SCISSORS:
		_answer_pending(type, {"hand": randi_range(1, 3)})
		return

	if not _is_selection_event(type):
		return

	_on_selection(event)


## Puts the attacker's and defender's numbers on screen for the length of a battle.
##
## The HUD cannot discover this on its own: ATTACK and BATTLE are passive events, so they leave
## no trace in `DuelState` and `refresh()` has nothing to read. Without this hook `set_combat()`
## is a complete feature with no caller - the same shape as a static nobody assigns, and just as
## invisible, because everything still builds and every test still passes.
func _show_combat(event: Dictionary) -> void:
	if _hud == null:
		return

	var attacker: DuelCard = _card_at_loc(event.get("from", {}))
	if attacker == null:
		_hud.set_combat(null, null)
		return

	# A direct attack carries no defender; the engine zeroes the loc_info and the parser reports
	# it as `direct`. Passing null is what makes the readout say so rather than inventing a
	# target.
	var defender: DuelCard = null
	if not bool(event.get("direct", false)):
		defender = _card_at_loc(event.get("to", {}))

	_hud.set_combat(attacker, defender)


func _is_selection_event(type: int) -> bool:
	if type >= FIRST_SELECT_EVENT and type <= LAST_SELECT_EVENT:
		return true
	return type == DuelEnums.EV.ANNOUNCE_RACE or type == DuelEnums.EV.ANNOUNCE_ATTRIB \
		or type == DuelEnums.EV.ANNOUNCE_CARD or type == DuelEnums.EV.ANNOUNCE_NUMBER


func _card_at_loc(info: Variant) -> DuelCard:
	if not (info is Dictionary) or (info as Dictionary).is_empty():
		return null
	var at: Dictionary = info
	return _state.card_at(
		int(at.get("con", 0)), int(at.get("loc", 0)), int(at.get("seq", 0)))


## Shows a card large, with its name, stats and effect text from the database.
##
## Reads the passcode off the **view**, not the model. A `CardView` already carries 0 for
## anything the viewer is not entitled to see, so this cannot reveal a face-down card to the
## player it is hidden from. Judging visibility again here - from the model and a seat - would
## be a second chance to get that wrong, and the cost of getting it wrong is showing someone
## their opponent's set trap.
func _on_pile_card_selected(card: Dictionary) -> void:
	var code: int = int(card.get("code", 0))
	if code != 0:
		_preview_code(code)


func _preview_code(card_code: int) -> void:
	if _preview == null or card_code == 0:
		return
	var info: Dictionary = _core.get_card_info(card_code) if _core != null else {}
	_enrich_setcodes(info)
	var face: Texture2D = _art.texture_for(card_code) if _art != null else null
	_preview.show_card(info, face)


func _preview_handle(handle: int) -> void:
	if _preview == null:
		return

	var view: CardView = _board.view_by_handle(handle)
	if view == null or view.card_id == 0:
		_preview.hide_card()
		return

	var info: Dictionary = _core.get_card_info(view.card_id) if _core != null else {}
	_enrich_setcodes(info)
	_enrich_live_stats(info, handle)
	var face: Texture2D = _art.texture_for(view.card_id) if _art != null else null
	_preview.show_card(info, face)


func _enrich_live_stats(info: Dictionary, handle: int) -> void:
	if handle == 0:
		return
	for p: int in range(DuelEnums.PLAYER_COUNT):
		for zone: Array in [_state.monster_zone[p], _state.extra_monster_zone[p], _state.spell_trap_zone[p]]:
			for card: Variant in zone:
				if card is DuelCard and (card as DuelCard).handle == handle:
					var dc: DuelCard = card as DuelCard
					if dc.attack >= 0:
						info["live_attack"] = dc.attack
					if dc.defense >= 0:
						info["live_defense"] = dc.defense
					if not dc.counters.is_empty():
						var counter_text: PackedStringArray = PackedStringArray()
						for ct_key: Variant in dc.counters:
							var ct_id: int = int(ct_key)
							var ct_val: int = int(dc.counters[ct_key])
							counter_text.append("%s: %d" % [_counter_name(ct_id), ct_val])
						info["counter_text"] = ", ".join(counter_text)
					if not dc.overlay_codes.is_empty():
						info["overlay_count"] = dc.overlay_codes.size()
					return
		var fz: DuelCard = _state.field_zone[p] as DuelCard
		if fz != null and fz.handle == handle:
			return


func _enrich_setcodes(info: Dictionary) -> void:
	var codes: PackedInt32Array = info.get("setcodes", PackedInt32Array()) as PackedInt32Array
	if codes.is_empty():
		return
	var names: PackedStringArray = PackedStringArray()
	for sc: int in codes:
		if sc != 0 and _setname_strings.has(sc):
			names.append(str(_setname_strings[sc]))
	if not names.is_empty():
		info["setcode_names"] = names


## Opens the action menu for a card during an idle or battle command selection.
func _show_action_menu(handle: int) -> void:
	if _action_menu == null or _core == null:
		return

	var actions: Array[Dictionary] = _selection.available_actions_for(handle)
	if actions.is_empty():
		# No actions available for this card; show preview instead.
		_preview_handle(handle)
		return

	var view: CardView = _board.view_by_handle(handle)
	var card_name: String = ""
	if view != null and view.card_id != 0:
		var info: Dictionary = _core.get_card_info(view.card_id)
		card_name = str(info.get("name", ""))

	_action_menu.show_actions(card_name, actions)


## The player picked an action from the menu.
func _on_action_chosen(cmd: String, index: int) -> void:
	if cmd == "_surrender":
		_do_surrender()
		return
	if cmd == "_yesno":
		if not _selection.is_waiting():
			return
		var type: int = _selection.pending_type()
		_answers_from_intents += 1
		_answer_pending(type, {"answer": index})
		return
	if cmd == "_option" or cmd == "_chain":
		if not _selection.is_waiting():
			return
		var type: int = _selection.pending_type()
		_answers_from_intents += 1
		_answer_pending(type, {"index": index})
		return
	if cmd == "_position":
		if not _selection.is_waiting():
			return
		var type: int = _selection.pending_type()
		_answers_from_intents += 1
		_answer_pending(type, {"position": index})
		return
	if cmd == "_sort":
		if not _selection.is_waiting():
			return
		var input: Dictionary = {"kind": "SELECT_CARD", "handle": 0, "anchor": "", "card_id": 0}
		var cards: Array = _last_selection.get("cards", []) as Array
		if index >= 0 and index < cards.size():
			var entry: Dictionary = cards[index] as Dictionary
			var at: Dictionary = entry.get("at", {}) as Dictionary
			input["card_id"] = int(entry.get("card", 0))
			if _state != null:
				var card: DuelCard = _state.card_at(
					int(at.get("con", 0)), int(at.get("loc", 0)), int(at.get("seq", 0)))
				if card != null:
					input["handle"] = card.handle
		var answer: Dictionary = _selection.resolve(input)
		if not answer.is_empty():
			_answers_from_intents += 1
			_answer_pending(_selection.pending_type(), answer)
		return
	if cmd == "_counter":
		if not _selection.is_waiting():
			return
		var input: Dictionary = {"kind": "SELECT_CARD", "handle": 0, "anchor": "", "card_id": 0}
		var cards: Array = _last_selection.get("cards", []) as Array
		if index >= 0 and index < cards.size():
			var entry: Dictionary = cards[index] as Dictionary
			var at: Dictionary = entry.get("at", {}) as Dictionary
			input["card_id"] = int(entry.get("card", 0))
			if _state != null:
				var card: DuelCard = _state.card_at(
					int(at.get("con", 0)), int(at.get("loc", 0)), int(at.get("seq", 0)))
				if card != null:
					input["handle"] = card.handle
		var answer: Dictionary = _selection.resolve(input)
		if not answer.is_empty():
			_answers_from_intents += 1
			_answer_pending(_selection.pending_type(), answer)
		else:
			_show_counter_dialog(_last_selection)
		return
	if cmd == "_race":
		if not _selection.is_waiting():
			return
		_answers_from_intents += 1
		_answer_pending(_selection.pending_type(), {"race": index})
		return
	if cmd == "_attrib":
		if not _selection.is_waiting():
			return
		_answers_from_intents += 1
		_answer_pending(_selection.pending_type(), {"attribute": index})
		return
	if cmd == "_number":
		if not _selection.is_waiting():
			return
		_answers_from_intents += 1
		_answer_pending(_selection.pending_type(), {"index": index})
		return
	if cmd == "_card":
		if not _selection.is_waiting():
			return
		_answers_from_intents += 1
		_answer_pending(_selection.pending_type(), {"code": index})
		return
	if not _selection.is_waiting():
		return
	var type: int = _selection.pending_type()
	var answer: Dictionary = _selection.resolve_action(cmd, index)
	if answer.is_empty():
		return
	_answers_from_intents += 1
	_answer_pending(type, answer)


## The action menu was dismissed without picking an action. For chain dialogs this means
## "pass" — cancel the chain. For everything else (idle command, surrender) it is harmless.
func _on_action_dismissed() -> void:
	if not _selection.is_waiting():
		return
	var type: int = _selection.pending_type()
	if type == DuelEnums.EV.SELECT_CHAIN:
		if not bool(_last_selection.get("forced", false)):
			_answers_from_intents += 1
			_answer_pending(type, {"cancel": true})
	elif type == DuelEnums.EV.SELECT_YESNO or type == DuelEnums.EV.SELECT_EFFECTYN:
		_answers_from_intents += 1
		_answer_pending(type, {"answer": 0})
	elif type == DuelEnums.EV.SORT_CARD or type == DuelEnums.EV.SORT_CHAIN:
		_answers_from_intents += 1
		_answer_pending(type, {"cancel": true})


## Long press on the deck offers to surrender and return to the menu.
func _offer_surrender() -> void:
	if _action_menu == null:
		return
	var surrender_actions: Array[Dictionary] = [{
		"key": "_surrender",
		"label": "Surrender",
		"index": 0,
	}]
	_action_menu.show_actions("Deck", surrender_actions)


## Decodes the options in a SELECT_OPTION event and presents them as an action menu.
##
## Each option value encodes `(card_code << 4) | string_index`, where `string_index` selects
## one of the card's sixteen per-effect labels from the database text table.
func _show_option_dialog(event: Dictionary) -> void:
	if _action_menu == null or _core == null:
		return
	var options: Array = event.get("options", []) as Array
	var actions: Array[Dictionary] = []
	for i: int in range(options.size()):
		var option: int = int(options[i])
		var code: int = option >> 4
		var string_idx: int = option & 0xf
		var label_text: String = "Option %d" % (i + 1)
		if code != 0:
			var info: Dictionary = _core.get_card_info(code)
			var strings: PackedStringArray = info.get("strings", PackedStringArray()) as PackedStringArray
			if string_idx < strings.size() and not strings[string_idx].is_empty():
				label_text = strings[string_idx]
			elif not str(info.get("name", "")).is_empty():
				label_text = str(info.get("name", ""))
		actions.append({"key": "_option", "label": label_text, "index": i})
		if i == 0 and code != 0 and not _headless:
			_preview_code(code)
	_action_menu.show_actions("Choose an effect", actions)


## Reconfigures the CardPreview as a non-modal side panel on the left edge, matching EDOPro's
## always-visible card info panel.
func _setup_side_preview() -> void:
	if _preview == null:
		return
	var dimmer: Control = _preview.get_node_or_null("Root/Dimmer") as Control
	if dimmer != null:
		dimmer.visible = false
	var root: Control = _preview.get_node_or_null("Root") as Control
	if root != null:
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame: Control = _preview.get_node_or_null("Root/Frame") as Control
	if frame != null:
		frame.anchor_left = 0.0
		frame.anchor_top = 0.0
		frame.anchor_right = 0.26
		frame.anchor_bottom = 1.0
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel: Control = _preview.get_node_or_null("Root/Frame/Panel") as Control
	if panel != null:
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE


## Shows available chain effects in the action menu when the player can respond.
func _show_chain_dialog(event: Dictionary) -> void:
	if _action_menu == null or _core == null:
		return
	var chains: Array = event.get("chains", []) as Array
	var forced: bool = bool(event.get("forced", false))
	var actions: Array[Dictionary] = []
	for i: int in range(chains.size()):
		var entry: Dictionary = chains[i] as Dictionary
		var code: int = int(entry.get("card", 0))
		var label_text: String = "Effect %d" % (i + 1)
		if code != 0:
			var info: Dictionary = _core.get_card_info(code)
			var name: String = str(info.get("name", ""))
			if not name.is_empty():
				label_text = name
			var desc_code: int = int(entry.get("desc", 0))
			if desc_code != 0:
				var string_idx: int = desc_code & 0xf
				var desc_card: int = desc_code >> 4
				if desc_card != 0:
					var desc_info: Dictionary = _core.get_card_info(desc_card)
					var strings: PackedStringArray = desc_info.get("strings", PackedStringArray()) as PackedStringArray
					if string_idx < strings.size() and not strings[string_idx].is_empty():
						label_text = "%s: %s" % [name, strings[string_idx]]
		actions.append({"key": "_chain", "label": label_text, "index": i})
		if i == 0 and code != 0 and not _headless:
			_preview_code(code)
	var title: String = "Activate effect (forced)" if forced else "Activate effect?"
	_action_menu.show_actions(title, actions)


## Shows the available battle positions in the action menu.
func _show_position_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var offered: int = int(event.get("positions", 0))
	var actions: Array[Dictionary] = []
	if (offered & DuelEnums.POSITION.FACEUP_ATTACK) != 0:
		actions.append({"key": "_position", "label": "Face-up Attack", "index": DuelEnums.POSITION.FACEUP_ATTACK})
	if (offered & DuelEnums.POSITION.FACEDOWN_ATTACK) != 0:
		actions.append({"key": "_position", "label": "Face-down Attack", "index": DuelEnums.POSITION.FACEDOWN_ATTACK})
	if (offered & DuelEnums.POSITION.FACEUP_DEFENSE) != 0:
		actions.append({"key": "_position", "label": "Face-up Defense", "index": DuelEnums.POSITION.FACEUP_DEFENSE})
	if (offered & DuelEnums.POSITION.FACEDOWN_DEFENSE) != 0:
		actions.append({"key": "_position", "label": "Face-down Defense", "index": DuelEnums.POSITION.FACEDOWN_DEFENSE})
	var pos_code: int = int(event.get("card", 0))
	var card_name: String = "Card"
	if pos_code != 0 and _core != null:
		var info: Dictionary = _core.get_card_info(pos_code)
		card_name = str(info.get("name", card_name))
	if pos_code != 0 and not _headless:
		_preview_code(pos_code)
	_action_menu.show_actions(card_name, actions)


func _show_confirm_cards(event: Dictionary, is_deck_top: bool) -> void:
	if _pile_browser == null or _core == null:
		return
	var card_list: Array = event.get("cards", [])
	if card_list.is_empty():
		return
	var cards: Array[Dictionary] = []
	for entry: Variant in card_list:
		var d: Dictionary = entry as Dictionary
		if d == null:
			continue
		var code: int = int(d.get("card", 0))
		if code == 0:
			continue
		var info: Dictionary = _core.get_card_info(code)
		cards.append(info)
	if cards.is_empty():
		return
	var title: String = "Top of Deck" if is_deck_top else "Revealed Cards"
	_pile_browser.show_pile(title, cards)


## Common system strings used by SELECT_YESNO. These are stable ocgcore protocol values
## defined in strings.conf; only the yes/no-relevant subset is kept here.
const _YESNO_STRINGS: Dictionary = {
	30: "A replay occurred, continue the attack?",
	31: "Attack directly?",
	32: "Conduct another Battle Phase?",
	90: "Normal Summon without Tribute(s)?",
	91: "Use your additional Normal Summon?",
	92: "Use an opponent's monster?",
	93: "Continue choosing materials?",
	94: "Activate this card's effect now?",
	95: "Use the effect of \"%ls\"?",
	96: "Use the effect of \"%ls\" to avoid destruction?",
	97: "Place \"%ls\" in the Spell & Trap Zone?",
	98: "Apply a cost replacing effect?",
	100: "Go first?",
	101: "Go second?",
	200: "Use the effect of \"%ls\"?",
	210: "Continue selecting cards?",
	218: "Pay LP with the effect of \"%ls\", instead?",
	219: "Detach Xyz Material(s) with the effect of \"%ls\", instead?",
	220: "Remove Counter(s) with the effect of \"%ls\", instead?",
	221: "Activate the Trigger Effect of \"%ls\"?",
}

const _SELECT_STRINGS: Dictionary = {
	500: "Select the card(s) to Tribute",
	501: "Select the card(s) to discard",
	502: "Select the card(s) to destroy",
	503: "Select the card(s) to banish",
	504: "Select the card(s) to send to the GY",
	505: "Select the card(s) to return to the hand",
	506: "Select the card(s) to add to your hand",
	507: "Select the card(s) to return to the Deck",
	508: "Select the card(s) to Normal Summon",
	509: "Select the card(s) to Special Summon",
	510: "Select the card(s) to Set",
	511: "Select the card(s) to use as Fusion Material",
	512: "Select the card(s) to use as Synchro Material",
	513: "Select the card(s) to use as Xyz Material",
	514: "Select a face-up card(s)",
	515: "Select a face-down card(s)",
	516: "Select a monster(s) in Attack Position",
	517: "Select a monster(s) in Defense Position",
	518: "Select the card(s) to equip",
	519: "Select the Xyz Material(s) to detach",
	520: "Select the monster(s) to change control",
	521: "Select the card(s) to replace",
	526: "Select the card(s) to reveal",
	527: "Select the card(s) to place on the field",
	528: "Select a monster to change its battle position",
	529: "Select your card",
	530: "Select the card(s) to use as Link Material",
	531: "Select the monster to change its Attribute",
	532: "Select the card(s) to shuffle into the Deck",
	533: "Select the card(s) to add to the Extra Deck",
}


## Shows a yes/no dialog for SELECT_YESNO and SELECT_EFFECTYN events.
##
## Decodes the `desc` field to show a meaningful question instead of a generic prompt.
## desc < 256 → system string; desc >= 256 → (card_code << 4) | string_index.
func _show_yesno_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var desc: int = int(event.get("desc", 0))
	var card_code: int = int(event.get("card", 0))
	var title: String = "Activate?"

	if desc != 0 and desc < 256:
		var sys_str: String = _system_string(desc)
		title = sys_str if not sys_str.is_empty() else ("Question #%d" % desc)
		if card_code != 0 and _core != null:
			var info: Dictionary = _core.get_card_info(card_code)
			var name: String = str(info.get("name", ""))
			if not name.is_empty():
				title = title.replace("%ls", name)
				if not title.contains(name):
					title = "%s — %s" % [name, title]
	elif desc >= 256:
		var desc_card: int = desc >> 4
		var string_idx: int = desc & 0xf
		if desc_card != 0 and _core != null:
			var info: Dictionary = _core.get_card_info(desc_card)
			var strings: PackedStringArray = info.get("strings", PackedStringArray()) as PackedStringArray
			var name: String = str(info.get("name", ""))
			if string_idx < strings.size() and not strings[string_idx].is_empty():
				title = strings[string_idx]
				if not name.is_empty():
					title = "%s: %s" % [name, title]
			elif not name.is_empty():
				title = "Use the effect of %s?" % name
	elif card_code != 0 and _core != null:
		var info: Dictionary = _core.get_card_info(card_code)
		var name: String = str(info.get("name", ""))
		if not name.is_empty():
			title = "Use the effect of %s?" % name

	if card_code != 0 and not _headless:
		_preview_code(card_code)

	var actions: Array[Dictionary] = [
		{"key": "_yesno", "label": "Yes", "index": 1},
		{"key": "_yesno", "label": "No", "index": 0},
	]
	_action_menu.show_actions(title, actions)


const _RACE_NAMES: Dictionary = {
	DuelEnums.RACE.WARRIOR: "Warrior",
	DuelEnums.RACE.SPELLCASTER: "Spellcaster",
	DuelEnums.RACE.FAIRY: "Fairy",
	DuelEnums.RACE.FIEND: "Fiend",
	DuelEnums.RACE.ZOMBIE: "Zombie",
	DuelEnums.RACE.MACHINE: "Machine",
	DuelEnums.RACE.AQUA: "Aqua",
	DuelEnums.RACE.PYRO: "Pyro",
	DuelEnums.RACE.ROCK: "Rock",
	DuelEnums.RACE.WINGEDBEAST: "Winged Beast",
	DuelEnums.RACE.PLANT: "Plant",
	DuelEnums.RACE.INSECT: "Insect",
	DuelEnums.RACE.THUNDER: "Thunder",
	DuelEnums.RACE.DRAGON: "Dragon",
	DuelEnums.RACE.BEAST: "Beast",
	DuelEnums.RACE.BEASTWARRIOR: "Beast-Warrior",
	DuelEnums.RACE.DINOSAUR: "Dinosaur",
	DuelEnums.RACE.FISH: "Fish",
	DuelEnums.RACE.SEASERPENT: "Sea Serpent",
	DuelEnums.RACE.REPTILE: "Reptile",
	DuelEnums.RACE.PSYCHIC: "Psychic",
	DuelEnums.RACE.DIVINE: "Divine-Beast",
	DuelEnums.RACE.CREATORGOD: "Creator God",
	DuelEnums.RACE.WYRM: "Wyrm",
	DuelEnums.RACE.CYBERSE: "Cyberse",
	DuelEnums.RACE.ILLUSION: "Illusion",
	DuelEnums.RACE.CYBORG: "Cyborg",
	DuelEnums.RACE.MAGICALKNIGHT: "Magical Knight",
	DuelEnums.RACE.HIGHDRAGON: "High Dragon",
	DuelEnums.RACE.OMEGAPSYCHIC: "Omega Psychic",
	DuelEnums.RACE.CELESTIALWARRIOR: "Celestial Warrior",
	DuelEnums.RACE.GALAXY: "Galaxy",
	DuelEnums.RACE.YOKAI: "Yokai",
}


const _ATTRIBUTE_NAMES: Dictionary = {
	DuelEnums.ATTRIBUTE.EARTH: "EARTH",
	DuelEnums.ATTRIBUTE.WATER: "WATER",
	DuelEnums.ATTRIBUTE.FIRE: "FIRE",
	DuelEnums.ATTRIBUTE.WIND: "WIND",
	DuelEnums.ATTRIBUTE.LIGHT: "LIGHT",
	DuelEnums.ATTRIBUTE.DARK: "DARK",
	DuelEnums.ATTRIBUTE.DIVINE: "DIVINE",
}


func _show_sort_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var cards: Array = event.get("cards", []) as Array
	var actions: Array[Dictionary] = []
	for i: int in range(cards.size()):
		var entry: Dictionary = cards[i] as Dictionary
		var code: int = int(entry.get("card", 0))
		var label_text: String = "Card %d" % (i + 1)
		if code != 0 and _core != null:
			var info: Dictionary = _core.get_card_info(code)
			var name: String = str(info.get("name", ""))
			if not name.is_empty():
				label_text = name
		actions.append({"key": "_sort", "label": label_text, "index": i})
	_action_menu.show_actions("Tap to set order", actions)


func _show_counter_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var cards: Array = event.get("cards", []) as Array
	var needed: int = int(event.get("count", 0))
	var actions: Array[Dictionary] = []
	for i: int in range(cards.size()):
		var entry: Dictionary = cards[i] as Dictionary
		var code: int = int(entry.get("card", 0))
		var cap: int = int(entry.get("counter_count", 0))
		var label_text: String = "Card %d (max %d)" % [i + 1, cap]
		if code != 0 and _core != null:
			var info: Dictionary = _core.get_card_info(code)
			var name: String = str(info.get("name", ""))
			if not name.is_empty():
				label_text = "%s (max %d)" % [name, cap]
		actions.append({"key": "_counter", "label": label_text, "index": i})
	_action_menu.show_actions("Remove %d counter(s)" % needed, actions)


func _show_announce_race_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var available: int = int(event.get("available", 0))
	var needed: int = int(event.get("count", 1))
	var actions: Array[Dictionary] = []
	for race_val: int in _RACE_NAMES:
		if (available & race_val) != 0:
			actions.append({"key": "_race", "label": _RACE_NAMES[race_val], "index": race_val})
	_action_menu.show_actions("Declare %d type(s)" % needed, actions)


func _show_announce_attrib_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var available: int = int(event.get("available", 0))
	var needed: int = int(event.get("count", 1))
	var actions: Array[Dictionary] = []
	for attr_val: int in _ATTRIBUTE_NAMES:
		if (available & attr_val) != 0:
			actions.append({"key": "_attrib", "label": _ATTRIBUTE_NAMES[attr_val], "index": attr_val})
	_action_menu.show_actions("Declare %d attribute(s)" % needed, actions)


func _show_announce_card_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var options: Array = event.get("options", []) as Array
	var actions: Array[Dictionary] = []
	for i: int in range(options.size()):
		var code: int = int(options[i])
		var name: String = _card_name(code)
		actions.append({"key": "_card", "label": name, "index": code})
	_action_menu.show_actions("Declare a card", actions)


func _show_announce_number_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var options: Array = event.get("options", []) as Array
	var actions: Array[Dictionary] = []
	for i: int in range(options.size()):
		actions.append({"key": "_number", "label": str(int(options[i])), "index": i})
	_action_menu.show_actions("Choose a number", actions)


func _show_sum_dialog(event: Dictionary) -> void:
	if _action_menu == null:
		return
	var cards: Array = event.get("cards", []) as Array
	var target: int = int(event.get("acc", 0))
	var must: Array = event.get("must", []) as Array
	var actions: Array[Dictionary] = []
	for i: int in range(cards.size()):
		var entry: Dictionary = cards[i] as Dictionary
		var code: int = int(entry.get("card", 0))
		var sum_param: int = int(entry.get("sum_param", 0))
		var low: int = sum_param & 0xffff
		var high: int = (sum_param >> 16) & 0xffff
		var val_text: String = str(low) if low == high or high == 0 else "%d/%d" % [low, high]
		var label_text: String = "%s (Lv %s)" % [_card_name(code), val_text]
		actions.append({"key": "_sort", "label": label_text, "index": i})
		if i == 0 and code != 0 and not _headless:
			_preview_code(code)
	var must_text: String = ""
	if not must.is_empty():
		var must_names: PackedStringArray = PackedStringArray()
		for m: Dictionary in must:
			must_names.append(_card_name(int(m.get("card", 0))))
		must_text = " (Must: %s)" % ", ".join(must_names)
	_action_menu.show_actions("Select for total %d%s" % [target, must_text], actions)


## Shows phase buttons matching the available phase transitions in the event.
func _update_phase_buttons(event: Dictionary) -> void:
	if _hud == null:
		return
	var type: int = _selection.pending_type()
	var commands: Array[String] = []
	if type == DuelEnums.EV.SELECT_IDLECMD:
		if bool(event.get("to_bp", false)):
			commands.append("to_bp")
		if bool(event.get("to_ep", false)):
			commands.append("to_ep")
	elif type == DuelEnums.EV.SELECT_BATTLECMD:
		if bool(event.get("to_m2", false)):
			commands.append("to_m2")
		if bool(event.get("to_ep", false)):
			commands.append("to_ep")
	_hud.set_phase_commands(commands)


## A phase button was clicked (BP, M2, EP).
func _on_phase_pressed(cmd: String) -> void:
	if not _selection.is_waiting():
		return
	var type: int = _selection.pending_type()
	if type != DuelEnums.EV.SELECT_IDLECMD and type != DuelEnums.EV.SELECT_BATTLECMD:
		return
	var answer: Dictionary = {"cmd": cmd}
	_answers_from_intents += 1
	_answer_pending(type, answer)


func _do_surrender() -> void:
	print("[solo] player surrendered")
	_stop("surrendered")
	chose.emit("menu")


func _try_browse_pile(anchor: String) -> bool:
	if _pile_browser == null or _core == null:
		return false
	var pile_name: String = ""
	var player: int = -1
	var location: int = 0
	if anchor.begins_with("GY_P"):
		pile_name = "Graveyard"
		player = int(anchor.substr(4))
		location = DuelEnums.LOCATION.GRAVE
	elif anchor.begins_with("EXTRA_P"):
		pile_name = "Extra Deck"
		player = int(anchor.substr(7))
		location = DuelEnums.LOCATION.EXTRA
	elif anchor.begins_with("BANISH_P"):
		pile_name = "Banished"
		player = int(anchor.substr(8))
		location = DuelEnums.LOCATION.REMOVED
	else:
		return false

	var pile: Array = _state.pile_for(player, location)
	var cards: Array[Dictionary] = []
	for entry: Variant in pile:
		var card: DuelCard = entry as DuelCard
		if card == null:
			continue
		if card.code == 0:
			cards.append({"code": 0, "name": "Face-down card", "type": 0})
		else:
			var info: Dictionary = _core.get_card_info(card.code)
			cards.append({
				"code": card.code,
				"name": str(info.get("name", "Card %d" % card.code)),
				"type": int(info.get("type", 0)),
			})
	var seat_name: String = "Player %d" % (player + 1)
	_pile_browser.show_pile("%s - %s" % [seat_name, pile_name], cards)
	return true


## Puts the rejected selection back in front of the player.
##
## The camera deliberately does not move: this is the same decision they were already looking
## at, and swinging the board would suggest something new had happened.
func _rearm_after_retry() -> void:
	if _last_selection.is_empty():
		return
	_selection.set_pending(_last_selection)
	_intents_this_selection = 0
	_focus.set_pending(_last_selection, _selection.pending_prompt())
	_focus.note_rejected()
	_board.clear_highlights()
	_board.highlight_cards(_selection.actionable_handles(_state))
	_banner.refresh()
	_idle_frames = 0


## A selection has arrived. It is parked, never answered here, and it never moves the camera.
func _on_selection(event: Dictionary) -> void:
	_selection.set_pending(event)

	# ocgcore passes priority after almost every action, whether or not the other seat has
	# anything to respond with - so a duel is full of prompts offering zero effects, which the
	# prompt itself admits: "0 available, cancel to pass". Answer those before anyone sees them.
	# One extra tap per action sounds small until it is every action, and it buries the prompts
	# that do matter among ones that never did.
	var trivial: Dictionary = _selection.auto_answer()
	if not trivial.is_empty():
		_auto_passed += 1
		_answer_pending(_selection.pending_type(), trivial)
		return

	# Solo: the far seat is not yours, so it answers itself. `PassiveAgent` draws, passes and
	# ends its turn - deliberately an opponent with no opinion rather than a bad one, because a
	# bad opponent makes moves you then have to reason about while practising your own.
	if not hot_seat and int(event.get("player", LOCAL_SEAT)) != LOCAL_SEAT:
		var reply: Dictionary = PassiveAgent.answer(event, _state)
		if not reply.is_empty():
			_opponent_answers += 1
			_answer_pending(_selection.pending_type(), reply)
			return
	# Kept so a rejected answer can be re-asked. ocgcore does not re-send a selection it turned
	# down (AGENTS.md section 8b trap 8), so if we forget it here there is nothing left to
	# answer and the duel looks frozen.
	_last_selection = event.duplicate(true)
	_intents_this_selection = 0

	var seat_before: int = _focus.seat_in_view
	_focus.set_pending(event, _selection.pending_prompt())

	# Light what the engine is actually offering, so "there is something to do" is a glance
	# rather than a sentence. Resolved through the model because a selection event carries
	# locations, not handles.
	_board.highlight_cards(_selection.actionable_handles(_state))

	if _focus.decision_seat != int(event.get("player", 0)):
		_decision_mismatches += 1
	if _focus.seat_in_view != seat_before:
		_camera_moved_on_prompt += 1

	_prompts.append({
		"event": _focus.decision_event,
		"seat": _focus.decision_seat,
		"in_view": _focus.seat_in_view,
	})
	if _focus.is_asking_offscreen():
		_offscreen_prompts += 1

	_highlight_for(event)
	_banner.refresh()
	_update_phase_buttons(event)

	if not _headless:
		var pending: int = _selection.pending_type()
		if pending == DuelEnums.EV.SELECT_OPTION:
			_show_option_dialog(event)
		elif pending == DuelEnums.EV.SELECT_CHAIN:
			var chains: Array = event.get("chains", []) as Array
			if not chains.is_empty():
				_show_chain_dialog(event)
		elif pending == DuelEnums.EV.SELECT_POSITION:
			_show_position_dialog(event)
		elif pending == DuelEnums.EV.SELECT_YESNO or pending == DuelEnums.EV.SELECT_EFFECTYN:
			_show_yesno_dialog(event)
		elif pending == DuelEnums.EV.SORT_CARD or pending == DuelEnums.EV.SORT_CHAIN:
			_show_sort_dialog(event)
		elif pending == DuelEnums.EV.SELECT_COUNTER:
			_show_counter_dialog(event)
		elif pending == DuelEnums.EV.ANNOUNCE_RACE:
			_show_announce_race_dialog(event)
		elif pending == DuelEnums.EV.ANNOUNCE_ATTRIB:
			_show_announce_attrib_dialog(event)
		elif pending == DuelEnums.EV.ANNOUNCE_CARD:
			_show_announce_card_dialog(event)
		elif pending == DuelEnums.EV.ANNOUNCE_NUMBER:
			_show_announce_number_dialog(event)
		elif pending == DuelEnums.EV.SELECT_SUM:
			_show_sum_dialog(event)

	print("[solo] %s -> %s (looking from %s)%s" % [
		DuelEnums.ev_name(_focus.decision_event),
		SeatFocus.seat_name(_focus.decision_seat),
		SeatFocus.seat_name(_focus.seat_in_view),
		"  [BANNER]" if _focus.is_asking_offscreen() else ""])


## Lights the zones a prompt is about, so an off-seat decision can be read without turning the
## board. Only anchors that actually carry a zone marker are offered: a hand is not a zone and
## `BoardView` would warn about it.
func _highlight_for(event: Dictionary) -> void:
	var markers: PackedStringArray = _board.zone_marker_names()
	var wanted: Dictionary = {}

	for key: String in ["summon", "mset", "sset", "spsummon", "repos", "activate", "attack",
			"cards", "chains"]:
		for entry: Variant in (event.get(key, []) as Array):
			var at: Dictionary = (entry as Dictionary).get("at", {}) as Dictionary
			if at.is_empty():
				continue
			var anchor: String = EventTranslator.anchor_of(at)
			if markers.has(anchor):
				wanted[anchor] = true

	var ev_type: int = int(event.get("t", 0))
	if ev_type == DuelEnums.EV.SELECT_PLACE or ev_type == DuelEnums.EV.SELECT_DISFIELD:
		for place: Dictionary in _selection.free_places():
			var anchor: String = EventTranslator.anchor_of(place)
			if markers.has(anchor):
				wanted[anchor] = true

	var anchors: PackedStringArray = PackedStringArray()
	for anchor: Variant in wanted:
		anchors.append(str(anchor))
	_board.highlight_zones(anchors)


# ----------------------------------------------------------------------------------------------
# The flip
# ----------------------------------------------------------------------------------------------

## Turns the board round to the new turn player. Built entirely from `CameraRig`'s exported
## properties, so the rig stays a slot a VR origin can be dropped into (ARCHITECTURE.md
## section 10 rule 2) and nothing here knows what a camera is.
func _begin_flip() -> void:
	var seat: int = _focus.seat_in_view
	var seconds: float = FLIP_SECONDS * (HEADLESS_DURATION_SCALE if _headless else 1.0)

	_banner.announce("Turn %d - the board is turning to %s" % [
		maxi(_state.turn_count, 1), SeatFocus.seat_name(seat)])

	if _flip_tween != null and _flip_tween.is_valid():
		_flip_tween.kill()

	if seconds <= 0.0:
		_apply_seat(seat)
		_rig.elevation = _rest_elevation
		_banner.announce("")
		return

	_flip_tween = create_tween()
	_flip_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_flip_tween.tween_property(_rig, "elevation", FLIP_ELEVATION, seconds)
	# At the apex the view is almost straight down, where a half turn about the table centre is
	# a rotation rather than a jump across the room.
	_flip_tween.tween_callback(_apply_seat.bind(seat))
	_flip_tween.tween_property(_rig, "elevation", _rest_elevation, seconds)
	_flip_tween.tween_callback(_banner.announce.bind(""))


## Hands the new seat to everything that is allowed to know about it. One place, so the camera,
## the HUD's idea of "you" and the hand the board draws face-up can never disagree.
func _apply_seat(seat: int) -> void:
	_rig.seat = seat
	_hud.local_player = seat
	# Which hand faces the camera. Both are legible either way in this mode - see Honesty above -
	# so this is orientation, not permission. A face-down card is face-down from both seats.
	_board.viewer_player = seat
	if _running:
		_board.sync_from_state(_state)
	_banner.refresh()


# ----------------------------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------------------------

func _on_intent(data: Dictionary) -> void:
	if _stopping or not _running:
		return

	# Dismiss the action menu on any intent while it is open. The player tapped elsewhere.
	if _action_menu != null and _action_menu.is_open():
		_action_menu.hide_menu()
		return

	if _pile_browser != null and _pile_browser.is_open():
		_pile_browser.hide_browser()
		return

	var kind: String = str(data.get("kind", ""))

	# Hover / long press = preview. Always safe, always available.
	if kind == InputSource.KIND_POINT_AT:
		_preview_handle(int(data.get("handle", 0)))
		return

	# Click on deck = surrender. Click on GY/Extra/Banished = browse pile.
	if kind == InputSource.KIND_SELECT_CARD or kind == InputSource.KIND_SELECT_ZONE:
		var anchor: String = str(data.get("anchor", ""))
		if anchor.begins_with("DECK_"):
			_offer_surrender()
			return
		if _try_browse_pile(anchor):
			return

	if not _selection.is_waiting():
		# Outside a selection, clicking a card previews it.
		if kind == InputSource.KIND_SELECT_CARD:
			_preview_handle(int(data.get("handle", 0)))
		return

	var type: int = _selection.pending_type()

	if not _headless and kind == InputSource.KIND_SELECT_CARD:
		var handle: int = int(data.get("handle", 0))
		if handle != 0:
			_preview_handle(handle)
		if type == DuelEnums.EV.SELECT_IDLECMD or type == DuelEnums.EV.SELECT_BATTLECMD:
			if handle != 0:
				_show_action_menu(handle)
				return

	var answer: Dictionary = _selection.resolve(data)
	if answer.is_empty():
		return

	_answers_from_intents += 1
	_answer_pending(type, answer)


## Sends one answer and clears everything that was describing the question.
##
## Shared by the input path and the auto-pass so the two cannot drift: an answer that forgot to
## clear the pending selection would leave the board lit for a decision that is already made.
func _answer_pending(type: int, answer: Dictionary) -> void:
	if _core == null or not _core.is_duel_running():
		# Not a failure: the duel finished while an answer was in flight. Saying so beats
		# letting the engine report "no duel is running" as though the player did something
		# wrong.
		_selection.clear()
		_focus.clear_pending()
		return

	var responded: Dictionary = _core.respond(type, answer)
	if not bool(responded.get("ok", false)):
		_fail("respond(%s, %s) failed: %s" % [
			DuelEnums.ev_name(type), str(answer), responded.get("error", "?")])
		_stop("respond failed")
		return

	_selection.clear()
	_focus.clear_pending()
	_board.clear_highlights()
	_board.clear_card_highlights()
	_last_hint_card = ""
	_last_hint_msg = ""
	if _hud != null:
		_hud.set_phase_commands([])
	_banner.refresh()
	_idle_frames = 0

	_stop_if_satisfied()


func _card_name(code: int) -> String:
	if code == 0 or _core == null:
		return "?"
	var info: Dictionary = _core.get_card_info(code)
	var n: String = str(info.get("name", ""))
	return n if not n.is_empty() else "#%d" % code


func _move_verb(from_loc: int, to_loc: int, reason: int) -> String:
	if (reason & DuelEnums.REASON.DESTROY) != 0:
		return "was destroyed"
	if (reason & DuelEnums.REASON.RELEASE) != 0:
		return "was tributed"
	if (reason & DuelEnums.REASON.DISCARD) != 0:
		return "was discarded"
	if (reason & DuelEnums.REASON.RETURN) != 0:
		if to_loc == DuelEnums.LOCATION.HAND:
			return "returned to hand"
		if to_loc == DuelEnums.LOCATION.DECK:
			return "returned to deck"
	if to_loc == DuelEnums.LOCATION.REMOVED:
		return "was banished"
	if to_loc == DuelEnums.LOCATION.GRAVE:
		return "was sent to GY"
	if to_loc == DuelEnums.LOCATION.HAND:
		return "was added to hand"
	if to_loc == DuelEnums.LOCATION.DECK:
		return "was returned to deck"
	if to_loc == DuelEnums.LOCATION.EXTRA:
		return "was returned to Extra Deck"
	return "%s -> %s" % [DuelEnums.location_name(from_loc), DuelEnums.location_name(to_loc)]


func _decode_desc(desc: int) -> String:
	if desc == 0:
		return ""
	if desc < 256:
		return _system_string(desc)
	var desc_card: int = desc >> 4
	var string_idx: int = desc & 0xf
	if desc_card != 0 and _core != null:
		var info: Dictionary = _core.get_card_info(desc_card)
		var strings: PackedStringArray = info.get("strings", PackedStringArray()) as PackedStringArray
		var name: String = str(info.get("name", ""))
		if string_idx < strings.size() and not strings[string_idx].is_empty():
			if not name.is_empty():
				return "%s: %s" % [name, strings[string_idx]]
			return strings[string_idx]
		if not name.is_empty():
			return name
	return ""


func _counter_name(counter_type: int) -> String:
	if _counter_strings.has(counter_type):
		return str(_counter_strings[counter_type])
	return "Counter"

func _system_string(id: int) -> String:
	if _system_strings.has(id):
		return str(_system_strings[id])
	if _SELECT_STRINGS.has(id):
		return str(_SELECT_STRINGS[id])
	if _YESNO_STRINGS.has(id):
		return str(_YESNO_STRINGS[id])
	return ""


func _load_system_strings() -> void:
	var path: String = "res://../data/base/strings.conf"
	if not FileAccess.file_exists(path):
		path = "res://../.workspace/EDOPro/config/strings.conf"
	if not FileAccess.file_exists(path):
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()
		if line.begins_with("!system "):
			var rest: String = line.substr(8)
			var space: int = rest.find(" ")
			if space >= 1:
				_system_strings[int(rest.left(space))] = rest.substr(space + 1)
		elif line.begins_with("!victory "):
			var rest: String = line.substr(9)
			var space: int = rest.find(" ")
			if space >= 1:
				var key: String = rest.left(space)
				var id: int = int(key) if not key.begins_with("0x") else key.hex_to_int()
				_victory_strings[id] = rest.substr(space + 1)
		elif line.begins_with("!counter "):
			var rest: String = line.substr(9)
			var space: int = rest.find(" ")
			if space >= 1:
				var key: String = rest.left(space)
				var id: int = int(key) if not key.begins_with("0x") else key.hex_to_int()
				_counter_strings[id] = rest.substr(space + 1)
		elif line.begins_with("!setname "):
			var rest: String = line.substr(9)
			var space: int = rest.find(" ")
			if space >= 1:
				var key: String = rest.left(space)
				var id: int = int(key) if not key.begins_with("0x") else key.hex_to_int()
				_setname_strings[id] = rest.substr(space + 1)


func _log_event(type: int, event: Dictionary) -> void:
	if _duel_log == null:
		return
	var code: int = int(event.get("card", 0))
	var player: int = int(event.get("player", 0))
	var seat: String = "P%d" % player
	match type:
		DuelEnums.EV.NEW_TURN:
			_duel_log.append_separator("Turn %d — %s" % [_state.turn_count, seat])
			if _audio != null:
				_audio.play_effect("nextturn")
		DuelEnums.EV.NEW_PHASE:
			var phase: int = int(event.get("phase", 0))
			_duel_log.append_system(DuelHud.PHASE_NAMES.get(phase, "Phase 0x%x" % phase) as String)
			if _audio != null:
				_audio.play_effect("phase")
		DuelEnums.EV.SUMMONING, DuelEnums.EV.SPSUMMONING, DuelEnums.EV.FLIPSUMMONING:
			var verb: String = "Summons"
			if type == DuelEnums.EV.SPSUMMONING:
				verb = "Special Summons"
				if _audio != null:
					_audio.play_effect("specialsummon")
			elif type == DuelEnums.EV.FLIPSUMMONING:
				verb = "Flip Summons"
				if _audio != null:
					_audio.play_effect("flip")
			else:
				if _audio != null:
					_audio.play_effect("summon")
			_duel_log.append_action("%s: %s %s" % [seat, verb, _card_name(code)])
		DuelEnums.EV.SET:
			var set_loc: int = int((event.get("at", {}) as Dictionary).get("loc", 0))
			var set_what: String = "a monster" if set_loc == DuelEnums.LOCATION.MZONE else "a card"
			_duel_log.append("%s Sets %s" % [seat, set_what])
			if _audio != null:
				_audio.play_effect("set")
		DuelEnums.EV.CHAINING:
			var chain_num_log: int = int(event.get("chain_size", 0))
			_duel_log.append_action("%s Chain %d: %s" % [seat, chain_num_log, _card_name(code)])
			if _audio != null:
				_audio.play_effect("activate")
		DuelEnums.EV.CHAIN_NEGATED:
			_duel_log.append_damage("%s negated" % _card_name(code))
			if _audio != null:
				_audio.play_effect("destroyed")
		DuelEnums.EV.ATTACK:
			var is_direct: bool = bool(event.get("direct", false))
			var atk_name: String = _card_name(code) if code != 0 else "?"
			if is_direct:
				_duel_log.append_action("%s: %s attacks directly!" % [seat, atk_name])
			else:
				var def_loc: Dictionary = event.get("to", {}) as Dictionary
				var def_c: DuelCard = _card_at_loc(def_loc)
				var def_name: String = _card_name(def_c.code) if def_c != null and def_c.code != 0 else "?"
				_duel_log.append_action("%s: %s attacks %s" % [seat, atk_name, def_name])
			if _audio != null:
				_audio.play_effect("attack")
		DuelEnums.EV.BATTLE:
			var is_direct: bool = bool(event.get("direct", false))
			var atk_val: int = int(event.get("from_atk", 0))
			if is_direct:
				_duel_log.append_action("ATK %d DIRECT ATTACK" % atk_val)
			else:
				var def_val: int = int(event.get("to_atk", 0))
				var def_dval: int = int(event.get("to_def", 0))
				_duel_log.append_action("ATK %d vs ATK %d / DEF %d" % [atk_val, def_val, def_dval])
		DuelEnums.EV.DAMAGE:
			_duel_log.append_damage("%s takes %d damage" % [seat, int(event.get("amount", 0))])
			if _audio != null:
				_audio.play_effect("damage")
		DuelEnums.EV.RECOVER:
			_duel_log.append_positive("%s recovers %d LP" % [seat, int(event.get("amount", 0))])
			if _audio != null:
				_audio.play_effect("gainlp")
		DuelEnums.EV.DRAW:
			var count: int = int(event.get("count", 1))
			_duel_log.append("%s draws %d card(s)" % [seat, count])
			if _audio != null:
				_audio.play_effect("draw")
		DuelEnums.EV.MOVE:
			if code != 0:
				var from_d: Dictionary = event.get("from", {}) as Dictionary
				var to_d: Dictionary = event.get("to", {}) as Dictionary
				var from_loc: int = int(from_d.get("loc", 0))
				var to_loc: int = int(to_d.get("loc", 0))
				var reason: int = int(event.get("reason", 0))
				if from_loc != 0 and to_loc != 0:
					var verb: String = _move_verb(from_loc, to_loc, reason)
					_duel_log.append("%s %s" % [_card_name(code), verb])
					if _audio != null:
						if to_loc == DuelEnums.LOCATION.GRAVE \
								and (from_loc == DuelEnums.LOCATION.MZONE or from_loc == DuelEnums.LOCATION.SZONE):
							_audio.play_effect("destroyed")
						elif to_loc == DuelEnums.LOCATION.REMOVED:
							_audio.play_effect("destroyed")
		DuelEnums.EV.POS_CHANGE:
			if code != 0:
				var new_pos: int = int(event.get("pos", 0))
				var pos_name: String = "ATK" if (new_pos & DuelEnums.POSITION.ATTACK) != 0 else "DEF"
				var face_name: String = "face-up" if (new_pos & DuelEnums.POSITION.FACEUP) != 0 else "face-down"
				_duel_log.append("%s -> %s %s" % [_card_name(code), face_name, pos_name])
				var pos_loc: Dictionary = event.get("at", {}) as Dictionary
				if not pos_loc.is_empty():
					var pos_col: Color = Color(0.4, 0.75, 1.0, 0.6) if (new_pos & DuelEnums.POSITION.ATTACK) != 0 else Color(0.3, 0.5, 0.9, 0.6)
					_board.flash_zone(EventTranslator.anchor_of(pos_loc), pos_col)
				if _audio != null:
					if (new_pos & DuelEnums.POSITION.FACEUP) != 0:
						_audio.play_effect("flip")
					else:
						_audio.play_effect("set")
		DuelEnums.EV.EQUIP:
			var equip_from: DuelCard = _card_at_loc(event.get("from", {}))
			var equip_to: DuelCard = _card_at_loc(event.get("to", {}))
			if equip_from != null and equip_to != null:
				_duel_log.append("%s equipped to %s" % [
					_card_name(equip_from.code), _card_name(equip_to.code)])
				_board.add_target_line(equip_from.handle, equip_to.handle, Color(0.3, 0.9, 0.5, 0.7))
				_board.set_card_indicator(equip_from.handle, "equip")
			if _audio != null:
				_audio.play_effect("equip")
		DuelEnums.EV.BECOME_TARGET:
			var targets: Array = event.get("cards", [])
			if not targets.is_empty():
				var names: PackedStringArray = PackedStringArray()
				for loc: Dictionary in targets:
					var tgt: DuelCard = _card_at_loc(loc)
					if tgt != null:
						names.append(_card_name(tgt.code))
				if not names.is_empty():
					_duel_log.append("Targeted: %s" % ", ".join(names))
		DuelEnums.EV.CARD_TARGET:
			var ct_from: DuelCard = _card_at_loc(event.get("from", {}))
			var ct_to: DuelCard = _card_at_loc(event.get("to", {}))
			if ct_from != null and ct_to != null:
				_duel_log.append("%s targets %s" % [_card_name(ct_from.code), _card_name(ct_to.code)])
		DuelEnums.EV.PAY_LPCOST:
			_duel_log.append_damage("%s pays %d LP" % [seat, int(event.get("amount", 0))])
		DuelEnums.EV.CHAIN_DISABLED:
			_duel_log.append("Chain link disabled")
		DuelEnums.EV.CHAIN_SOLVING:
			var solving_log: int = int(event.get("chain_index", 0))
			_duel_log.append_action("Resolving chain link %d" % solving_log)
		DuelEnums.EV.ATTACK_DISABLED:
			_duel_log.append("Attack disabled")
			if _audio != null:
				_audio.play_effect("destroyed")
		DuelEnums.EV.TOSS_COIN:
			var results: Array = event.get("results", [])
			var labels: PackedStringArray = PackedStringArray()
			for r: int in results:
				labels.append("Heads" if r == 1 else "Tails")
			_duel_log.append("Coin: %s" % ", ".join(labels))
			if _audio != null:
				_audio.play_effect("coinflip")
		DuelEnums.EV.TOSS_DICE:
			var results: Array = event.get("results", [])
			var labels: PackedStringArray = PackedStringArray()
			for r: int in results:
				labels.append(str(r))
			_duel_log.append("Dice: %s" % ", ".join(labels))
			if _audio != null:
				_audio.play_effect("diceroll")
		DuelEnums.EV.ADD_COUNTER:
			var ct: int = int(event.get("counter_type", 0))
			_duel_log.append("%s +%d" % [_counter_name(ct), int(event.get("count", 0))])
			if _audio != null:
				_audio.play_effect("addcounter")
		DuelEnums.EV.REMOVE_COUNTER:
			var ct: int = int(event.get("counter_type", 0))
			_duel_log.append("%s -%d" % [_counter_name(ct), int(event.get("count", 0))])
			if _audio != null:
				_audio.play_effect("removecounter")
		DuelEnums.EV.SHUFFLE_DECK:
			_duel_log.append("%s shuffles deck" % seat)
			if _audio != null:
				_audio.play_effect("shuffle")
		DuelEnums.EV.SHUFFLE_HAND:
			_duel_log.append("%s shuffles hand" % seat)
			if _audio != null:
				_audio.play_effect("shuffle")
		DuelEnums.EV.SHUFFLE_SET_CARD:
			_duel_log.append("Set cards shuffled")
		DuelEnums.EV.SHUFFLE_EXTRA:
			_duel_log.append("%s shuffles extra deck" % seat)
			if _audio != null:
				_audio.play_effect("shuffle")
		DuelEnums.EV.CHAIN_SOLVED:
			var solved_name: String = _card_name(code)
			if solved_name != "?":
				_duel_log.append("Resolved: %s" % solved_name)
		DuelEnums.EV.DAMAGE_STEP_START:
			_duel_log.append_system("Damage Step")
		DuelEnums.EV.DAMAGE_STEP_END:
			_duel_log.append_system("End Damage Step")
		DuelEnums.EV.REMOVE_CARDS:
			var rem_cards: Array = event.get("cards", [])
			if not rem_cards.is_empty():
				var rnames: PackedStringArray = PackedStringArray()
				for loc: Dictionary in rem_cards:
					var rc: DuelCard = _card_at_loc(loc)
					if rc != null and rc.code != 0:
						rnames.append(_card_name(rc.code))
				if not rnames.is_empty():
					_duel_log.append("Removed: %s" % ", ".join(rnames))
		DuelEnums.EV.SWAP:
			var swap_code1: int = int(event.get("card", 0))
			var swap_code2: int = int(event.get("card2", 0))
			if swap_code1 != 0 and swap_code2 != 0:
				_duel_log.append("%s swapped with %s" % [_card_name(swap_code1), _card_name(swap_code2)])
			var swap_from: DuelCard = _card_at_loc(event.get("from", {}))
			var swap_to: DuelCard = _card_at_loc(event.get("to", {}))
			if swap_from != null:
				_board.set_card_indicator(swap_from.handle, "act")
			if swap_to != null:
				_board.set_card_indicator(swap_to.handle, "act")
			if swap_from != null and swap_to != null:
				_board.add_target_line(swap_from.handle, swap_to.handle, Color(0.9, 0.7, 0.2, 0.7))
		DuelEnums.EV.RANDOM_SELECTED:
			var rand_cards: Array = event.get("cards", [])
			for loc: Dictionary in rand_cards:
				var rc: DuelCard = _card_at_loc(loc)
				if rc != null:
					_board.set_card_indicator(rc.handle, "target")
			if not rand_cards.is_empty():
				var rnames: PackedStringArray = PackedStringArray()
				for loc: Dictionary in rand_cards:
					var rc: DuelCard = _card_at_loc(loc)
					if rc != null:
						rnames.append(_card_name(rc.code))
				if not rnames.is_empty():
					_duel_log.append("Randomly selected: %s" % ", ".join(rnames))
		DuelEnums.EV.CONFIRM_CARDS, DuelEnums.EV.CONFIRM_DECKTOP:
			var revealed: Array = event.get("cards", [])
			if not revealed.is_empty():
				var names: PackedStringArray = PackedStringArray()
				for entry: Variant in revealed:
					var d: Dictionary = entry as Dictionary
					if d != null:
						names.append(_card_name(int(d.get("card", 0))))
				_duel_log.append("Revealed: %s" % ", ".join(names))
		DuelEnums.EV.MISSED_EFFECT:
			if code != 0:
				_duel_log.append("%s missed timing" % _card_name(code), Color(0.7, 0.5, 0.5))
		DuelEnums.EV.UNEQUIP:
			_duel_log.append("Unequipped: %s" % _card_name(code))
			if _audio != null:
				_audio.play_effect("equip")
		DuelEnums.EV.SWAP_GRAVE_DECK:
			_duel_log.append("%s swaps GY and Deck" % seat)
			if _audio != null:
				_audio.play_effect("shuffle")
		DuelEnums.EV.REVERSE_DECK:
			_duel_log.append("Decks reversed")
			if _audio != null:
				_audio.play_effect("shuffle")
		DuelEnums.EV.DECK_TOP:
			var dtcode: int = int(event.get("card", 0))
			if dtcode != 0:
				_duel_log.append("Deck top: %s" % _card_name(dtcode))
		DuelEnums.EV.CONFIRM_EXTRATOP:
			var ext_cards: Array = event.get("cards", [])
			if not ext_cards.is_empty():
				var ext_names: PackedStringArray = PackedStringArray()
				for entry: Variant in ext_cards:
					var d: Dictionary = entry as Dictionary
					if d != null:
						ext_names.append(_card_name(int(d.get("code", 0))))
				_duel_log.append("Extra top: %s" % ", ".join(ext_names))
		DuelEnums.EV.FIELD_DISABLED:
			_duel_log.append_system("Field zones updated")
		DuelEnums.EV.HAND_RES:
			var rps_names: Array[String] = ["?", "Rock", "Paper", "Scissors"]
			var h0: int = int(event.get("hand0", 0))
			var h1: int = int(event.get("hand1", 0))
			_duel_log.append_system("RPS: P0=%s P1=%s" % [rps_names[clampi(h0, 0, 3)], rps_names[clampi(h1, 0, 3)]])
		DuelEnums.EV.LPUPDATE:
			_duel_log.append_system("%s LP: %d" % [seat, int(event.get("lp", 0))])
		DuelEnums.EV.CARD_HINT:
			var ch_card: DuelCard = _card_at_loc(event.get("at", {}))
			var ch_type: int = int(event.get("hint_type", 0))
			var ch_data: int = int(event.get("data", 0))
			if ch_card != null and ch_card.code != 0:
				if ch_type == 6 or ch_type == 7:
					var desc_text: String = _decode_desc(ch_data)
					var action: String = "+" if ch_type == 6 else "-"
					var colour: Color = Color(0.6, 0.8, 1.0) if ch_type == 6 else Color(0.7, 0.7, 0.7)
					if not desc_text.is_empty():
						_duel_log.append("%s %s: %s" % [action, _card_name(ch_card.code), desc_text], colour)
					else:
						var label: String = "effect applied" if ch_type == 6 else "effect removed"
						_duel_log.append("%s %s: %s" % [action, _card_name(ch_card.code), label], colour)
		DuelEnums.EV.PLAYER_HINT:
			var ph_type: int = int(event.get("hint_type", 0))
			var ph_data: int = int(event.get("data", 0))
			if ph_type == 6 or ph_type == 7:
				var desc_text: String = _decode_desc(ph_data)
				var colour: Color = Color(0.6, 0.8, 1.0) if ph_type == 6 else Color(0.7, 0.7, 0.7)
				var label: String = "restriction applied" if ph_type == 6 else "restriction removed"
				if not desc_text.is_empty():
					_duel_log.append("%s: %s" % [seat, desc_text], colour)
				else:
					_duel_log.append("%s: %s" % [seat, label], colour)
		DuelEnums.EV.WIN:
			var winner: int = int(event.get("player", -1))
			var reason: int = int(event.get("reason", 0))
			var reason_text: String = str(_victory_strings.get(reason, "")) if _victory_strings.has(reason) else ""
			if not reason_text.is_empty():
				_duel_log.append_system("=== P%d wins — %s ===" % [winner, reason_text])
			else:
				_duel_log.append_system("=== P%d wins ===" % winner)


## A full turn cycle is turn 1 for the first player, turn 2 for the other - which is the flip -
## and turn 3 back again, which is the flip home. Anything less proves the view can leave but
## not that it comes back.
func _stop_if_satisfied() -> void:
	if not _headless or _stopping:
		return
	if _turn_changes < TURNS_WANTED:
		return
	if hot_seat and _focus.flips < FLIPS_WANTED:
		return
	if not _set_trap or _set_zones_audited == 0:
		return
	_stop("a full turn cycle played out and the view followed the turn player both ways")


## Whether this idle request offers a trap to set, and where in the `sset` list it is. A spell
## would be offered as `activate` first, so only a trap can be reached this way.
func _trap_in(event: Dictionary) -> bool:
	return _trap_index(event) >= 0


func _trap_index(event: Dictionary) -> int:
	var list: Array = event.get("sset", []) as Array
	for index: int in range(list.size()):
		var at: Dictionary = (list[index] as Dictionary).get("at", {}) as Dictionary
		var card: DuelCard = _state.card_at(
			int(at.get("con", 0)), int(at.get("loc", 0)), int(at.get("seq", 0)))
		if card != null and card.code == TRAP_HOLE:
			return index
	return -1


# ----------------------------------------------------------------------------------------------
# The headless player
# ----------------------------------------------------------------------------------------------

func _drive_headless() -> void:
	_intents_this_selection += 1
	if _intents_this_selection > MAX_INTENTS_PER_SELECTION:
		_fail("%s absorbed %d intents without producing an answer" % [
			DuelEnums.ev_name(_selection.pending_type()), _intents_this_selection - 1])
		_stop("selection stuck")
		return

	var intent: Dictionary = _synthesise_intent()
	if intent.is_empty():
		_fail("no intent could be synthesised for %s" % DuelEnums.ev_name(_selection.pending_type()))
		_stop("nothing to touch")
		return
	_on_intent(intent)


## Chooses a card, never a response. Turning "this card" into a command plus a list index is
## `SelectionController`'s job; if this function did it the run would prove nothing.
##
## A confirm on an idle or battle command is "advance the phase", so repeated confirms walk the
## turn out to its end phase and into the next one - which is how this run reaches a turn change
## without scripting the duel.
func _synthesise_intent() -> Dictionary:
	var event: Dictionary = _selection.pending_event()

	match _selection.pending_type():
		DuelEnums.EV.SELECT_IDLECMD:
			# Set a trap whenever one is available. The face-down audit runs at the end of
			# the duel, so at least one must still be on the board at that point. With cards
			# like Dark Hole in the deck a single early set can be destroyed long before the
			# audit, so keep setting them.
			if _trap_in(event):
				_set_trap = true
				return _tap(event, "sset", _trap_index(event))
			if not _summoned and not (event.get("summon", []) as Array).is_empty():
				_summoned = true
				return _tap(event, "summon", 0)
			return {"kind": InputSource.KIND_CONFIRM}

		DuelEnums.EV.SELECT_BATTLECMD:
			return {"kind": InputSource.KIND_CONFIRM}

		DuelEnums.EV.SELECT_PLACE, DuelEnums.EV.SELECT_DISFIELD:
			var free: Array[Dictionary] = _selection.free_places()
			if free.is_empty():
				return {"kind": InputSource.KIND_CANCEL}
			return {
				"kind": InputSource.KIND_SELECT_ZONE,
				"anchor": EventTranslator.anchor_of(free[0]),
			}

		DuelEnums.EV.SELECT_CARD, DuelEnums.EV.SELECT_TRIBUTE:
			var picked: Array[int] = _selection.picks()
			if picked.size() >= maxi(1, int(event.get("min", 1))):
				return {"kind": InputSource.KIND_CONFIRM}
			var cards: Array = event.get("cards", []) as Array
			for index: int in range(cards.size()):
				if not picked.has(index):
					return _tap(event, "cards", index)
			return {"kind": InputSource.KIND_CONFIRM}

		DuelEnums.EV.SELECT_CHAIN:
			return {"kind": InputSource.KIND_CANCEL}

	return {"kind": InputSource.KIND_CONFIRM}


func _tap(event: Dictionary, key: String, index: int) -> Dictionary:
	var list: Array = event.get(key, []) as Array
	if index < 0 or index >= list.size():
		return {}
	var entry: Dictionary = list[index] as Dictionary
	var at: Dictionary = entry.get("at", {}) as Dictionary
	if at.is_empty():
		return {}

	var card: DuelCard = _state.card_at(
		int(at.get("con", 0)), int(at.get("loc", 0)), int(at.get("seq", 0)))
	if card == null:
		_fail("DuelState has no card at %s, which the engine offered as %s[%d]" % [str(at), key, index])
		return {}

	return {
		"kind": InputSource.KIND_SELECT_CARD,
		"handle": card.handle,
		"card_id": card.code,
		"anchor": EventTranslator.anchor_of(at),
	}


# ----------------------------------------------------------------------------------------------
# Evidence
# ----------------------------------------------------------------------------------------------

## The phase readout, recorded as the readout itself produces it. Asserting on `PHASE_NAMES`
## would be asserting on the table; this asserts on what reaches the screen.
func _record_phase() -> void:
	var phase: int = _state.phase
	var text: String = SeatFocus.phase_name(phase)
	_phases_seen[phase] = text
	if text.strip_edges().is_empty() or text.begins_with("PHASE("):
		_blank_phase_readouts += 1


## Re-reads every face-down card on the board from both seats. The claim is narrow and exact: a
## card the model holds face-down is drawn face-down whichever seat the camera is behind, and a
## set spell or trap is not laid on its side.
func _audit_facedown() -> void:
	var restore: int = _board.viewer_player

	for seat: int in range(DuelEnums.PLAYER_COUNT):
		_board.viewer_player = seat
		_board.sync_from_state(_state)

		for player: int in range(DuelEnums.PLAYER_COUNT):
			for sequence: int in range(DuelEnums.MAIN_MONSTER_ZONES):
				_audit_zone(_state.main_monster[player][sequence],
					"MZ_P%d_%d" % [player, sequence], seat)
			for sequence: int in range(DuelEnums.SPELL_TRAP_ZONES):
				_audit_zone(_state.spell_trap[player][sequence],
					"ST_P%d_%d" % [player, sequence], seat)

			# A deck is face-down for everybody, and stays that way when the camera changes
			# sides. It is the cheapest standing proof that the flip is a camera move and not
			# a visibility switch - a mode that leaked one would leak the other.
			if not _state.deck[player].is_empty():
				_audit_pile("DECK_P%d" % player, seat)

	_board.viewer_player = restore
	_board.sync_from_state(_state)


## Every card drawn at a pile anchor must be a back. Unlike a zone there is no per-card model
## position to compare against: the pile itself is face-down, so any face at all is a leak.
func _audit_pile(anchor: String, seat: int) -> void:
	var view: CardView = _board.view_at(anchor)
	if view == null:
		_facedown_leaks.append("%s has no view from seat %d" % [anchor, seat])
		return
	_facedown_checks += 1
	if view.face_up:
		_facedown_leaks.append("%s showed a face from seat %d" % [anchor, seat])
	if view.card_id != 0:
		_facedown_leaks.append("%s carried a passcode from seat %d" % [anchor, seat])


func _audit_zone(slot: Variant, anchor: String, seat: int) -> void:
	var card: DuelCard = slot as DuelCard
	if card == null or not card.is_face_down():
		return
	var view: CardView = _board.view_at(anchor)
	if view == null:
		_facedown_leaks.append("%s has no view from seat %d" % [anchor, seat])
		return

	_facedown_checks += 1
	if view.face_up:
		_facedown_leaks.append("%s showed its face from seat %d" % [anchor, seat])
	if view.card_id != 0:
		_facedown_leaks.append("%s carried its passcode from seat %d" % [anchor, seat])

	if not BoardView.zone_turns(anchor):
		_set_zones_audited += 1

	# `BoardView.zone_turns()` is the one place that decides this. A set spell or trap is
	# `FACEDOWN_DEFENSE` in the model because position is one field shared by every card type,
	# and reading that bit straight into a rotation lays it on its side in its zone.
	if view.defense and not BoardView.zone_turns(anchor):
		_sideways_sets.append("%s from seat %d" % [anchor, seat])


# ----------------------------------------------------------------------------------------------
# Reporting
# ----------------------------------------------------------------------------------------------

func _on_queue_drained() -> void:
	if _running:
		_board.sync_from_state(_state)


func _stop(reason: String) -> void:
	if _stopping:
		return
	_stopping = true
	_running = false
	set_process(false)

	if _flip_tween != null and _flip_tween.is_valid():
		_flip_tween.kill()
	_rig.elevation = _rest_elevation

	_director.skip_all()
	_board.sync_from_state(_state)

	# Close the duel *before* auditing it. The audit prints the verdict, and anything that could
	# still fail after that line has already made the verdict wrong - which is how "all checks
	# passed" ended up printed above five failures.
	if _action_menu != null:
		_action_menu.hide_menu()
	if _core != null:
		_core.end_duel()
	_selection.clear()
	_focus.clear_pending()
	_board.clear_card_highlights()

	print("[solo] %s" % reason)
	print("[solo] %d events, %d answers from input, %d auto-passed, %d by the opponent, %d turn changes, %d seat flips" % [
		_event_count, _answers_from_intents, _auto_passed, _opponent_answers,
		_turn_changes, _focus.flips])
	print(_state.describe())

	_probe_combat_readout()
	_probe_preview()
	_probe_input_after_teardown()
	_check_results()

	if _art != null:
		_art.shutdown()

	if _failures.is_empty():
		print("[solo] all checks passed")
	else:
		print("[solo] %d check(s) failed" % _failures.size())

	if _headless:
		get_tree().quit(0 if _failures.is_empty() else 1)


## Drives the battle readout directly, because the gate cannot otherwise tell a wired hook from
## an unwired one: `set_combat()` arrived complete and with no caller, every gate still green.
func _probe_combat_readout() -> void:
	if _hud == null:
		_fail("no HUD to show a battle on")
		return

	var attacker := DuelCard.new()
	attacker.code = 11091375
	attacker.attack = 1900
	attacker.defense = 1600

	_hud.set_combat(attacker, null)
	_expect(_hud.combat_is_visible(), "a battle puts its numbers on screen")
	_expect(_hud.combat_text().contains("1900"),
		"the readout shows the attacking number (got %s)" % _hud.combat_text())
	_expect(_hud.combat_text().to_upper().contains("DIRECT"),
		"an attack with no defender says so (got %s)" % _hud.combat_text())

	_hud.set_combat(null, null)
	_expect(not _hud.combat_is_visible(), "and it leaves when the battle does")


## Points at a visible card and at a hidden one, and checks what each is willing to say.
##
## The headless run emits no POINT_AT of its own, so without this the preview path never
## executes under the gate - the same blind spot that let input-after-teardown ship.
##
## The second half is the one that matters. A preview that reads the model instead of the view
## would happily print an opponent's set trap, and nothing else in this suite would notice.
func _probe_preview() -> void:
	if _preview == null:
		_fail("no card preview was created")
		return

	var visible_handle: int = 0
	var hidden_handle: int = 0
	for anchor_name: String in ["HAND_P0", "MZ_P0_0", "MZ_P0_1", "MZ_P0_2", "ST_P0_0", "ST_P0_1"]:
		var view: CardView = _board.view_at(anchor_name)
		if view == null or view.handle == 0:
			continue
		if view.card_id != 0 and visible_handle == 0:
			visible_handle = view.handle
		elif view.card_id == 0 and hidden_handle == 0:
			hidden_handle = view.handle

	if visible_handle != 0:
		_preview_handle(visible_handle)
		_expect(_preview.is_showing(), "pointing at a readable card opens the preview")
		_expect(_preview.shown_code() != 0,
			"the preview names the card it opened on (got code %d)" % _preview.shown_code())

	if hidden_handle != 0:
		_preview_handle(hidden_handle)
		_expect(not _preview.is_showing(),
			"a card showing its back tells the preview nothing (code %d leaked)"
				% _preview.shown_code())

	# A handle nothing is bound to must close it rather than leaving the last card up.
	_preview_handle(0)
	_expect(not _preview.is_showing(), "pointing at nothing closes the preview")


## Fires a tap after the duel is closed, and asserts it goes nowhere.
##
## The headless run cannot reach this state on its own - it stops deterministically and nothing
## taps afterwards - so without this probe the bug is invisible to the gate by construction.
## That is exactly how it shipped: a human kept tapping after the duel ended, every tap reached
## `respond()` on a dead duel, and the log read "all checks passed" above five failures.
##
## Input arrives by signal, so `set_process(false)` does not stop it. Only the guard does.
func _probe_input_after_teardown() -> void:
	var before: int = _failures.size()

	for kind: String in [InputSource.KIND_CONFIRM, InputSource.KIND_CANCEL,
			InputSource.KIND_SELECT_CARD, InputSource.KIND_SELECT_ALT]:
		_on_intent({"kind": kind, "handle": 1, "card_id": 0, "anchor": "MZ_P0_0"})

	_expect(_failures.size() == before,
		"input after the duel closes goes nowhere (%d taps reached the engine)"
			% (_failures.size() - before))


func _check_results() -> void:
	if not _headless:
		return

	_audit_facedown()

	_expect(_set_trap, "a card was set face-down from input alone")

	_expect(_answers_from_intents > 0,
		"selections were answered from InputIntents (got %d)" % _answers_from_intents)
	_expect(_retries == 0, "ocgcore accepted every answer (no MSG_RETRY)")

	_expect(_turn_changes >= FLIPS_WANTED,
		"the duel played through %d turn changes" % _turn_changes)
	# The two modes want opposite things here, so both are asserted rather than one being
	# skipped: Solo's promise is that the board never turns, and a skipped check would let that
	# promise quietly break the first time someone reused `_begin_flip()`.
	if not hot_seat:
		_expect(_focus.flips == 0,
			"the board never turned in solo (got %d flips)" % _focus.flips)
		_expect(_focus.seat_in_view == LOCAL_SEAT,
			"you stayed in your own seat all duel (ended on %d)" % _focus.seat_in_view)
		return

	_expect(_focus.flips >= FLIPS_WANTED,
		"the seat in view followed the turn player across %d turn changes (got %d flips)"
			% [_turn_changes, _focus.flips])
	_expect(_seat_lagged_turn == 0,
		"the seat in view matched the new turn player on every NEW_TURN (%d did not)"
			% _seat_lagged_turn)

	_expect(_camera_moved_on_prompt == 0,
		"no prompt moved the seat in view (%d did)" % _camera_moved_on_prompt)
	_expect(_prompts.size() > 0, "at least one prompt was recorded (got %d)" % _prompts.size())
	_expect(_decision_mismatches == 0,
		"the decision indicator named the seat every event named (%d did not)"
			% _decision_mismatches)
	print("[solo]   %d prompts, %d of them for the seat that was not in view" % [
		_prompts.size(), _offscreen_prompts])

	_expect(_phases_seen.size() > 0, "the phase readout was exercised (%d distinct phases)"
		% _phases_seen.size())
	_expect(_blank_phase_readouts == 0,
		"every phase the duel entered had a name (%d blanks)" % _blank_phase_readouts)
	for phase: Variant in _phases_seen:
		print("[solo]   phase 0x%X -> %s" % [int(phase), str(_phases_seen[phase])])

	_expect(_facedown_checks > 0,
		"face-down cards were audited from both seats (%d checks)" % _facedown_checks)
	_expect(_set_zones_audited > 0,
		"a set spell or trap zone was among them (%d)" % _set_zones_audited)
	_expect(_facedown_leaks.is_empty(),
		"no face-down card revealed itself%s" % (
			"" if _facedown_leaks.is_empty() else " (%s)" % ", ".join(_facedown_leaks)))
	_expect(_sideways_sets.is_empty(),
		"no set spell or trap was drawn sideways%s" % (
			"" if _sideways_sets.is_empty() else " (%s)" % ", ".join(_sideways_sets)))

	_expect(_banner.seat_colour() != Color.BLACK,
		"the overlay is painting the seat in view a colour of its own")


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("  PASS  %s" % what)
	else:
		_fail(what)


func _fail(what: String) -> void:
	print("  FAIL  %s" % what)
	_failures.append(what)
