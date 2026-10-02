extends Node3D

## A real ocgcore duel answered by touching the board.
##
##   godot --path game res://scenes/duel_touch.tscn                # play it
##   godot --headless --path game res://scenes/duel_touch.tscn     # self-checks, then quits
##
## Layer: L5. Like `scenes/duel_3d.gd` it is allowed to see L1, L3 and L4 at once, because
## wiring them together is all it does. Nothing under `game/view/` or `game/platform/` may do
## the same; this file is the seam that keeps V1 true.
##
## -------------------------------------------------------------------------------------------
## What is different from duel_3d
## -------------------------------------------------------------------------------------------
## `duel_3d.gd` answers selections from a hardcoded `_plan()`. This one does not answer them at
## all. It parks them on a `SelectionController` and waits:
##
##   KaibaCore.poll_event()          Level-1 DuelEvent
##     -> DuelState.apply()           L3 model, instant and authoritative
##     -> EventTranslator.translate() Level-2 intents, lossy and disposable (V9)
##        -> AnimationDirector        L4, animates, allowed to lag
##     -> MSG_SELECT_* only:  SelectionController.set_pending()
##
##   TouchSource / MouseSource       a finger or a cursor
##     -> InputIntent                 a card handle or an anchor. Never a screen coordinate.
##        -> SelectionController.resolve()
##           -> KaibaCore.respond()   when the taps so far add up to an answer
##
## The two halves meet only at `SelectionController`, and it is pure data (V2). That is the
## whole point of ARCHITECTURE.md section 10 rules 3 and 5: the duel cannot tell whether the
## answer came from a thumb, a mouse, a VR controller, or - as in the headless run below - from
## a synthesised intent.
##
## -------------------------------------------------------------------------------------------
## The headless run
## -------------------------------------------------------------------------------------------
## A headless process has no finger. `_synthesise_intent()` builds one: it decides which card it
## would like to touch and then expresses that as an `InputIntent` carrying that card's handle,
## exactly as `InputSource._pick()` would have. It never builds a response - it does not know
## how. Everything from the intent onwards is the same code a real tap runs through, which is
## what makes the headless pass evidence that the real path works.
##
## Both seats are answered from the same controller. There is no AI yet, so this is a hot-seat
## duel; `duel_real.gd` and `duel_3d.gd` do the same.

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"
## Searched in order, as in `scenes/duel_real.gd`. The library scripts (constant.lua,
## utility.lua, proc_*.lua) sit at the collection root; card scripts in the three folders below.
const SCRIPT_ROOTS: Array[String] = [
	"res://../data/base/script",
	"res://../data/base/script/official",
	"res://../data/base/script/unofficial",
	"res://../data/base/script/pre-release",
]

## Chosen because it actually offers choices. A level 4 vanilla in hand is offered as both
## `summon` and `mset`; Pot of Greed as both `activate` and `sset`; the level 8 as nothing until
## two monsters are on the field. A deck of one card would answer every prompt the same way and
## prove nothing about mapping a tap to a list.
const BEATERS: Array[int] = [11091375, 14898066, 33256280, 35052053]
const BIG: int = 89631139
const POT_OF_GREED: int = 55144522
const DECK_SIZE: int = 40

const START_LP: int = 8000
const START_HAND: int = 5
const DRAW_COUNT: int = 1

const FIRST_SELECT_EVENT: int = DuelEnums.EV.SELECT_BATTLECMD
const LAST_SELECT_EVENT: int = DuelEnums.EV.SELECT_UNSELECT_CARD

const MAX_EVENTS_PER_FRAME: int = 64
const IDLE_FRAMES_BEFORE_GIVING_UP: int = 900
const MAX_FRAMES: int = 5400

## Headless animates at a twentieth of the budgeted speed. Nothing about the input path depends
## on how long a tween lasts, and a full-speed duel would take minutes to verify.
const HEADLESS_DURATION_SCALE: float = 0.05

## How many synthesised intents one selection may absorb before it is called stuck. A multi-card
## selection legitimately eats several; a selection that eats a dozen is not being answered.
const MAX_INTENTS_PER_SELECTION: int = 16

@onready var _board: BoardView = $World3D/BoardView
@onready var _director: AnimationDirector = $AnimationDirector
@onready var _rig: CameraRig = $World3D/CameraRig
@onready var _touch: TouchSource = $InputLayer/TouchSource
@onready var _mouse: MouseSource = $InputLayer/MouseSource

var _core: Object = null
var _state: DuelState = DuelState.new()
var _translator: EventTranslator = EventTranslator.new()
var _selection: SelectionController = null

var _headless: bool = false
var _failures: PackedStringArray = PackedStringArray()

var _running: bool = false
var _stopping: bool = false
var _frames: int = 0
var _idle_frames: int = 0
var _event_count: int = 0
var _suppressed_logs: int = 0

## Intents fed into this one pending selection, so a stuck prompt is reported rather than spun.
var _intents_this_selection: int = 0

# --- what the headless finger has already done -------------------------------------------------
var _activated: bool = false
var _summoned: bool = false
var _attacked: bool = false

# --- evidence the checks below assert ----------------------------------------------------------
var _answers_from_intents: int = 0
var _commands_from_taps: int = 0
var _places_from_taps: int = 0
var _blocked_zone_answered: bool = false
var _monster_reached_field: bool = false
var _damage_dealt: int = 0
var _retries: int = 0

# --- picker probe ------------------------------------------------------------------------------
var _picker_proved: bool = false
var _picker_anchor: String = ""
var _picker_expected_anchor: String = ""
var _picker_attempts: int = 0


func _ready() -> void:
	set_process(false)
	_headless = DisplayServer.get_name() == "headless" or OS.get_cmdline_args().has("--headless")

	_selection = SelectionController.new(_state)

	_rig.activate()
	_director.bind(_board)
	# Advisory only: the director suggests a framing, the rig decides whether to take it. A VR
	# rig ignores every cue, because moving a camera a person's head is not moving is how you
	# make them sick (CameraRig.cue()).
	_director.camera_cue.connect(_rig.cue)
	_director.camera_cue.connect(_on_camera_cue)

	if _headless:
		_director.duration_scale = HEADLESS_DURATION_SCALE
	_director.queue_drained.connect(_on_queue_drained)

	# Both sources are wired and both are harmless on the wrong device: Godot only emits
	# `InputEventScreenTouch` on a touch screen and only `InputEventMouse*` with a pointer. The
	# duel never learns which one spoke (ARCHITECTURE.md section 10 rule 3).
	for source: InputSource in [_touch, _mouse]:
		source.bind(_rig, _board)
		source.intent.connect(_on_intent)

	_start_duel()


func _process(_delta: float) -> void:
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

	if _headless:
		_probe_picker()

	# One synthesised touch per frame. Spreading them out rather than looping here keeps the
	# animation director and the board doing what they would do under a real player's hands.
	if _headless and _selection.is_waiting():
		_drive_headless()
		return

	if drained > 0:
		_idle_frames = 0
		return
	_idle_frames += 1
	if _idle_frames >= IDLE_FRAMES_BEFORE_GIVING_UP:
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

	# `res://../` leaves the project directory, so it has to be globalised before FileAccess
	# will see it. The native side resolves the same path for itself.
	if not FileAccess.file_exists(ProjectSettings.globalize_path(CDB_PATH)):
		_fail("%s is missing; see docs/DATA.md" % CDB_PATH)
		_stop("no card database")
		return

	var loaded: Dictionary = _core.load_card_database(CDB_PATH)
	if not bool(loaded.get("ok", false)):
		_fail("could not load %s: %s" % [CDB_PATH, loaded.get("error", "?")])
		_stop("no card database")
		return
	print("[touch] card database loaded: %d cards" % int(loaded.get("count", 0)))
	for root: String in SCRIPT_ROOTS:
		_core.add_script_root(root)

	var started: Dictionary = _core.start_duel({
		"start_lp": START_LP,
		"start_hand": START_HAND,
		"draw_count": DRAW_COUNT,
		"deck_p0": _build_deck(),
		"deck_p1": _build_deck(),
	})
	if not bool(started.get("ok", false)):
		_fail("start_duel failed: %s" % started.get("error", "?"))
		_stop("duel did not start")
		return

	# ocgcore never emits MSG_START (AGENTS.md section 8b.1); the host synthesises it.
	_state.apply({
		"t": DuelEnums.EV.START,
		"lp": [START_LP, START_LP],
		"deck": [DECK_SIZE, DECK_SIZE],
		"extra": [0, 0],
		"first": 0,
	})
	_board.sync_from_state(_state)
	print("[touch] duel started. Tap a card to play it; right click / two-finger tap cancels.")
	_running = true
	set_process(true)


func _build_deck() -> PackedInt32Array:
	var deck: PackedInt32Array = PackedInt32Array()
	for index: int in DECK_SIZE:
		if index % 10 == 0:
			deck.append(BIG)
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
			# `DuelThread::emit_error` also uses 1002 and carries no "log_type", unlike the
			# ocgcore log passthrough. That one is a real failure and must not be swallowed.
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
	var intents: Array[Dictionary] = _translator.translate(event, _state)
	if not intents.is_empty():
		_director.enqueue(intents)

	match type:
		DuelEnums.EV.MOVE:
			var to: Dictionary = event.get("to", {})
			if int(to.get("loc", 0)) == DuelEnums.LOCATION.MZONE:
				_monster_reached_field = true
		DuelEnums.EV.DAMAGE:
			_damage_dealt = int(event.get("amount", 0))
		DuelEnums.EV.RETRY:
			# Silent on the wire and never resent (AGENTS.md section 8b trap 8), so counting it
			# is the only way a wrong answer ever becomes visible.
			_retries += 1
			_fail("ocgcore rejected a response; the last answer was malformed for its selection")
			_stop("retry")
			return

	if type < FIRST_SELECT_EVENT or type > LAST_SELECT_EVENT:
		return

	# A selection. It is NOT answered here - that is the whole difference from duel_3d.
	_selection.set_pending(event)
	_intents_this_selection = 0
	print("[touch] %s -- %s" % [DuelEnums.ev_name(type), _selection.pending_prompt()])
	if not SelectionController.can_answer(type):
		print("[touch]   (no intent can express this selection; falling back to a default)")


# ----------------------------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------------------------

## The single entry point for everything the player does. A real `TouchSource` signal and a
## synthesised headless intent arrive here identically, which is what makes the headless run
## evidence about the real path rather than about a parallel one.
func _on_intent(data: Dictionary) -> void:
	var kind: String = str(data.get("kind", ""))

	if not _selection.is_waiting():
		# Outside a selection a tap has nothing to answer. A preview still has somewhere to go
		# once a HUD exists; for now it is logged and dropped.
		if kind == InputSource.KIND_POINT_AT:
			print("[touch] point at %s" % str(data.get("anchor", "-")))
		return

	var type: int = _selection.pending_type()
	var answer: Dictionary = _selection.resolve(data)
	if answer.is_empty():
		return

	var responded: Dictionary = _core.respond(type, answer)
	if not bool(responded.get("ok", false)):
		_fail("respond(%s, %s) failed: %s" % [
			DuelEnums.ev_name(type), str(answer), responded.get("error", "?")])
		_stop("respond failed")
		return

	_answers_from_intents += 1
	match type:
		DuelEnums.EV.SELECT_IDLECMD, DuelEnums.EV.SELECT_BATTLECMD:
			if answer.has("index"):
				_commands_from_taps += 1
		DuelEnums.EV.SELECT_PLACE:
			_places_from_taps += 1
			_check_places_were_legal(answer)

	print("[touch]   answered %s with %s" % [DuelEnums.ev_name(type), str(answer)])
	_selection.clear()
	_idle_frames = 0

	if _attacked and _damage_dealt > 0:
		_stop("the opening finished: a monster was summoned and attacked from input alone")


## The silent failure this whole exercise exists to avoid: answering `MSG_SELECT_PLACE` with a
## zone whose `flag` bit is set earns `MSG_RETRY`, and a retry does not resend the request.
## Re-checking the answer against the request we just answered turns that into a named failure.
func _check_places_were_legal(answer: Dictionary) -> void:
	var event: Dictionary = _selection.pending_event()
	var flag: int = int(event.get("flag", 0))
	var asking: int = int(event.get("player", 0))
	for entry: Variant in (answer.get("places", []) as Array):
		var place: Dictionary = entry as Dictionary
		if SelectionController.is_place_free(flag, asking,
				int(place["con"]), int(place["loc"]), int(place["seq"])):
			continue
		_blocked_zone_answered = true
		_fail("SELECT_PLACE answered with blocked zone %s against flag 0x%x" % [str(place), flag])


# ----------------------------------------------------------------------------------------------
# The headless finger
# ----------------------------------------------------------------------------------------------

## Feeds one synthesised `InputIntent` into `_on_intent()`.
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


## Decides which card this run would like to touch, and says so in the input vocabulary.
##
## It is a plan, like `duel_3d.gd`'s `_plan()`, but it stops one step earlier: it chooses a
## *card*, never a response. Turning "this card" into `{"cmd": "summon", "index": 2}` is
## `SelectionController`'s job, and if this function could do it the test would be proving
## nothing.
func _synthesise_intent() -> Dictionary:
	var event: Dictionary = _selection.pending_event()

	match _selection.pending_type():
		DuelEnums.EV.SELECT_IDLECMD:
			# Activating a scripted card first proves the Lua collection loaded; summoning next
			# proves a hand card maps to the `summon` list and not to `mset`.
			if not _activated and not (event.get("activate", []) as Array).is_empty():
				_activated = true
				return _tap(event, "activate", 0)
			if not _summoned and not (event.get("summon", []) as Array).is_empty():
				_summoned = true
				return _tap(event, "summon", 0)
			return {"kind": InputSource.KIND_CONFIRM}

		DuelEnums.EV.SELECT_BATTLECMD:
			if not _attacked and not (event.get("attack", []) as Array).is_empty():
				_attacked = true
				return _tap(event, "attack", 0)
			return {"kind": InputSource.KIND_CANCEL}

		DuelEnums.EV.SELECT_PLACE:
			# A tap on bare felt. The anchor is all a zone tap ever carries.
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
			# -1 is only accepted when the chain was not forced; the controller knows that and
			# turns a forced cancel into a real index.
			return {"kind": InputSource.KIND_CANCEL}

	# Everything else - position, yes/no, option, sum - is a confirm. For SELECT_SUM that is
	# what hands the request to the subset-sum solver.
	return {"kind": InputSource.KIND_CONFIRM}


## Builds the `InputIntent` a tap on the `index`-th entry of `event[key]` would have produced.
##
## The handle comes out of `DuelState` by looking up the zone the request named, which is the
## same handle `BoardView` stamped onto the `CardView` standing there - so this is the picker's
## output, reached the other way round.
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
# Reconciliation and reporting
# ----------------------------------------------------------------------------------------------

## The reconciliation point (ARCHITECTURE.md section 5). Safe only here: `sync_from_state()`
## recycles the very card views a tween would otherwise still be holding.
func _on_queue_drained() -> void:
	if _running:
		_board.sync_from_state(_state)


func _stop(reason: String) -> void:
	if _stopping:
		return
	_stopping = true
	_running = false
	set_process(false)

	_director.skip_all()
	_board.sync_from_state(_state)

	print("[touch] %s" % reason)
	print("[touch] %d events, %d answers from input, %d core log lines suppressed" % [
		_event_count, _answers_from_intents, _suppressed_logs])
	print(_state.describe())

	_check_results()

	if _core != null:
		_core.end_duel()

	if _failures.is_empty():
		print("[touch] all checks passed")
	else:
		print("[touch] %d check(s) failed" % _failures.size())

	# A windowed run stays up so the board can be played with; a headless one is a test.
	if _headless:
		get_tree().quit(0 if _failures.is_empty() else 1)


func _check_results() -> void:
	if not _headless:
		return

	_expect(_answers_from_intents > 0,
		"at least one real selection was answered from an InputIntent (got %d)" % _answers_from_intents)
	_expect(_commands_from_taps > 0,
		"a tapped card became a command plus a list index (got %d)" % _commands_from_taps)
	_expect(_places_from_taps > 0,
		"a zone tap answered SELECT_PLACE (got %d)" % _places_from_taps)
	_expect(not _blocked_zone_answered,
		"no answered zone had its flag bit set")
	_expect(_retries == 0, "ocgcore accepted every answer (no MSG_RETRY)")
	_expect(_activated, "a scripted card in hand was tapped and activated")
	_expect(_summoned and _monster_reached_field, "a tapped hand card reached a monster zone")
	_expect(_damage_dealt > 0, "the summoned monster attacked for %d" % _damage_dealt)

	# The end-to-end claim: after reconciliation the board shows what the model holds.
	var mismatches: PackedStringArray = PackedStringArray()
	for player: int in range(DuelEnums.PLAYER_COUNT):
		for sequence: int in range(DuelEnums.MAIN_MONSTER_ZONES):
			var anchor: String = "MZ_P%d_%d" % [player, sequence]
			var card: DuelCard = _state.main_monster[player][sequence] as DuelCard
			var view: CardView = _board.view_at(anchor)
			if card == null and view == null:
				continue
			if card == null or view == null:
				mismatches.append(anchor)
				continue
			if card.is_face_up() and view.card_id != card.code:
				mismatches.append("%s shows %s, model holds %s" % [
					anchor, view.describe(), card.short_label()])
	_expect(mismatches.is_empty(), "every monster zone matches DuelState%s" % (
		"" if mismatches.is_empty() else " (%s)" % ", ".join(mismatches)))

	# A card parked in the pool must not be pickable, or a tap could resolve to a card that is
	# not on the board - which shows up three selections later as a silent MSG_RETRY.
	var pool_leaks: int = 0
	for child: Node in _board.card_pool().get_children():
		var view: CardView = child as CardView
		if view != null and not view.visible and view.is_pickable():
			pool_leaks += 1
	_expect(pool_leaks == 0, "every parked card has its collider off (%d leaked)" % pool_leaks)


## Proves the raycast path the headless run cannot otherwise exercise.
##
## Everything else here feeds `SelectionController` a synthesised `InputIntent`, which is honest
## about the duel logic but says nothing about whether a finger would ever have produced that
## intent. This closes that gap from the other end: take a card that is actually on the board,
## ask the camera where it appears on screen, and push that screen point through the same
## `_pick()` a real tap uses. If the handle that comes back is the card we started from, the
## collider, the layer mask, the camera projection and the handle binding are all correct.
##
## Runs once. A headless frame has a camera and a populated board only after the opening draw
## has been animated, so it retries until a card is placed rather than asserting on frame one.
func _probe_picker() -> void:
	if _picker_proved or _picker_attempts > 600:
		return
	_picker_attempts += 1

	var camera: Camera3D = _rig.camera() if _rig != null else null
	if camera == null or _touch == null or not _touch.is_bound():
		return

	# Deliberately never a pile. A deck is thirty-odd cards resting within a millimetre of each
	# other, and the pick colliders carry a fingertip margin, so their boxes overlap: the ray can
	# legitimately enter a lower card before the one `view_at()` calls the top. That ambiguity is
	# inherent to stacked piles and does not matter - nobody taps a specific card inside a deck.
	# Monster zones and hand slots are spread out, so a hit there is unambiguous and worth
	# asserting on.
	var subject: CardView = null
	for anchor_name: String in [_picker_expected_anchor, "MZ_P0_0", "MZ_P0_1", "MZ_P0_2", "HAND_P0"]:
		if anchor_name == "":
			continue
		var candidate: CardView = _board.view_at(anchor_name)
		if candidate != null and candidate.handle != 0:
			subject = candidate
			_picker_anchor = anchor_name
			break
	if subject == null:
		return

	# unproject_position is the exact inverse of the project_ray_* pair _pick() uses, so this
	# screen point is where a finger would have to land to hit this card.
	var screen: Vector2 = camera.unproject_position(subject.global_position)
	if camera.is_position_behind(subject.global_position):
		return

	var hit: Dictionary = _touch._pick(screen)
	_picker_proved = true

	_expect(not hit.is_empty(), "the picker resolved a screen point to something")
	_expect(int(hit.get("handle", 0)) == subject.handle,
		"the picker returned the card that is actually at %s (expected handle %d, got %d)"
			% [_picker_anchor, subject.handle, int(hit.get("handle", 0))])
	_expect(str(hit.get("anchor", "")) == _picker_anchor,
		"the picker reported the right anchor (expected %s, got %s)"
			% [_picker_anchor, str(hit.get("anchor", ""))])


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("  PASS  %s" % what)
	else:
		_fail(what)


func _fail(what: String) -> void:
	print("  FAIL  %s" % what)
	_failures.append(what)


## Counts framing cues so the headless run proves the path exists rather than leaving a signal
## that nothing listens to.
var _cues_seen: int = 0


func _on_camera_cue(kind: String, _world_position: Vector3) -> void:
	if kind != CameraRig.CUE_SETTLE:
		_cues_seen += 1
