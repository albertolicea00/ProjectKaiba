extends Node

## Phase 1 console driver: a real ocgcore duel printed as a board, not as a packet dump.
##
##   godot --headless --path game res://scenes/headless_duel.tscn
##
## What it proves, which `duel_smoke.gd` does not: that the Level-1 event stream coming off the
## native thread actually drives the L3 model. `duel_smoke.gd` stops at "the events parse";
## this one stops at "the board is right".
##
## Layer: L5. It may know about L3 (`DuelState`, `EventTranslator`) and about L1 (`KaibaCore`);
## nothing in L3 knows about this file. There is no `BoardView` yet, so `describe()` stands in
## for L4.
##
## There is no cards.cdb and no Lua scripts yet (docs/DATA.md), so every card is a bare code
## with no effects. That is expected here: the subject is the pipe, not the card pool.

const CORE_CLASS: String = "KaibaCore"

## Blue-Eyes White Dragon, forty times. Without a database a code is just a number, and a
## single repeated code makes the hand trivially readable in the dump.
const DECK_CARD: int = 89631139
const DECK_SIZE: int = 40

const START_LP: int = 8000
const START_HAND: int = 5
const DRAW_COUNT: int = 1

## Drained per frame. The queue can hold hundreds of core log lines, and a frame that never
## returns would make the driver look hung.
const MAX_EVENTS_PER_FRAME: int = 256

## Frames with an empty queue before we conclude the duel thread has nothing more to say. At
## 60fps this is about ten seconds, which is far longer than ocgcore needs to open a duel.
const IDLE_FRAMES_BEFORE_GIVING_UP: int = 600

## `MSG_SELECT_*`, the opcodes that block the duel thread waiting for a response. Answering one
## is the ResponseBuilder's job in Phase 2; until it exists, reaching one is where this driver
## stops. Range taken from `DuelEnums.EV`: SELECT_BATTLECMD (10) through SELECT_UNSELECT_CARD (26).
const FIRST_SELECT_EVENT: int = 10
const LAST_SELECT_EVENT: int = 26

var _core: Object = null
var _state: DuelState = DuelState.new()
var _translator: EventTranslator = EventTranslator.new()

var _board_digest: String = ""
var _event_count: int = 0
var _suppressed_logs: int = 0
var _idle_frames: int = 0
var _stopping: bool = false


func _ready() -> void:
	set_process(false)

	_core = _instantiate_core()
	if _core == null:
		get_tree().quit(1)
		return

	var deck: PackedInt32Array = PackedInt32Array()
	for index: int in DECK_SIZE:
		deck.append(DECK_CARD)

	var result: Dictionary = _core.start_duel({
		"start_lp": START_LP,
		"start_hand": START_HAND,
		"draw_count": DRAW_COUNT,
		"deck_p0": deck,
		"deck_p1": deck,
	})

	if not bool(result.get("ok", false)):
		push_error("[duel] start_duel failed: %s" % result.get("error", "unknown"))
		get_tree().quit(1)
		return

	print("[duel] started, seed = %s" % str(result.get("seed", [])))

	# ocgcore never emits MSG_START (AGENTS.md section 8b.1) - the host synthesises it from the
	# duel configuration, and for Phase 1 this driver *is* the host. Without it `DuelState`
	# would show zero life points and an empty deck for the whole duel.
	#
	# "first" is a placeholder: the engine decides who starts and tells us with MSG_NEW_TURN,
	# which arrives a few events later and overwrites this.
	_state.apply({
		"t": DuelEnums.EV.START,
		"lp": [START_LP, START_LP],
		"deck": [DECK_SIZE, DECK_SIZE],
		"extra": [0, 0],
		"first": 0,
	})
	_print_board("initial board")

	set_process(true)


func _process(_delta: float) -> void:
	if _stopping:
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

	if drained > 0:
		_idle_frames = 0
		return

	_idle_frames += 1
	if _idle_frames >= IDLE_FRAMES_BEFORE_GIVING_UP:
		_stop("no further events; the duel thread has gone quiet")


# ----------------------------------------------------------------------------------------------
# Event handling
# ----------------------------------------------------------------------------------------------

func _handle(event: Dictionary) -> void:
	var type: int = int(event.get("t", -1))

	# 1000-1099 are DuelThread lifecycle events, not ocgcore opcodes (duel_thread.h). They are
	# L1 plumbing; feeding them to DuelState would only trip its V13 warning.
	match type:
		1000:
			print("[duel] core reports the duel is live")
			return
		1001:
			_stop("duel ended cleanly")
			return
		1002, 1003:
			# Without card scripts every single card logs a missing `initial_effect`, which
			# would bury the duel itself. Suppressed exactly as duel_smoke.gd does.
			#
			# The one exception: `DuelThread::emit_error` also uses 1002 and carries no
			# "log_type", unlike the ocgcore log passthrough. That one is a real setup or
			# teardown failure and must never be swallowed.
			if type == 1002 and not event.has("log_type"):
				push_error("[duel] core error at stage '%s': %s" % [
					event.get("stage", "?"), event.get("detail", "?"),
				])
				_stop("core reported a fatal error")
				return
			_suppressed_logs += 1
			return

	_event_count += 1
	print("[duel] %3d  %-16s %s" % [_event_count, DuelEnums.ev_name(type), _brief(event)])

	_state.apply(event)

	# Level 2 (V9: never stored, never sent - this is the throwaway half of the model). Printing
	# the kinds is how we check the translator against a real event stream rather than a
	# synthetic one.
	var intents: Array[Dictionary] = _translator.translate(event)
	if not intents.is_empty():
		print("           intents: %s" % _intent_summary(intents))

	_print_board_if_changed()

	if type >= FIRST_SELECT_EVENT and type <= LAST_SELECT_EVENT:
		_stop("reached a blocking selection (%s); the ResponseBuilder arrives in Phase 2"
			% DuelEnums.ev_name(type))


func _stop(reason: String) -> void:
	if _stopping:
		return
	_stopping = true
	set_process(false)

	print("[duel] %s" % reason)
	_print_board("final board")
	print("[duel] %d events applied, %d core log lines suppressed" % [_event_count, _suppressed_logs])

	if _core != null:
		_core.end_duel()
	get_tree().quit(0)


# ----------------------------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------------------------

## Prints the board only when something actually moved. Most of the opening stream is phase and
## hint traffic that changes nothing, and reprinting an identical board for each would hide the
## events that matter.
func _print_board_if_changed() -> void:
	var digest: String = JSON.stringify(_state.snapshot())
	if digest == _board_digest:
		return
	_board_digest = digest
	print(_state.describe())


func _print_board(label: String) -> void:
	print("[duel] %s" % label)
	_board_digest = JSON.stringify(_state.snapshot())
	print(_state.describe())


## One line per event payload. Arrays collapse to their size: a 40-card list adds nothing here.
func _brief(event: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for key: Variant in event.keys():
		if key == "t":
			continue
		var value: Variant = event[key]
		if value is Array:
			parts.append("%s=[%d]" % [key, (value as Array).size()])
		else:
			parts.append("%s=%s" % [key, str(value)])
	return ", ".join(parts)


func _intent_summary(intents: Array[Dictionary]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for intent: Dictionary in intents:
		var kind: String = str(intent.get("kind", "?"))
		if intent.has("from_anchor") and intent.has("to_anchor"):
			parts.append("%s %s->%s" % [kind, intent["from_anchor"], intent["to_anchor"]])
		elif intent.has("anchor"):
			parts.append("%s @%s" % [kind, intent["anchor"]])
		else:
			parts.append(kind)
	return ", ".join(parts)


# ----------------------------------------------------------------------------------------------
# Core handle
# ----------------------------------------------------------------------------------------------

## `ClassDB.instantiate` rather than `KaibaCore.new()`, deliberately: with the GDExtension
## missing, the literal class name would be a parse error and this whole file would fail to
## load, taking the diagnostic below with it. Same reasoning as `scenes/main.gd`.
func _instantiate_core() -> Object:
	if not ClassDB.class_exists(CORE_CLASS):
		push_error(
			"%s is not registered. The GDExtension did not load. " % CORE_CLASS
			+ "Check that game/bin/ holds a library matching this platform, then run: make host"
		)
		return null
	return ClassDB.instantiate(CORE_CLASS)
