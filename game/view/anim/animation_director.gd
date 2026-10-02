class_name AnimationDirector
extends Node

## Plays a queue of Level-2 `VisualIntent` dictionaries against a `BoardView`.
##
## Layer: L4 (AGENTS.md section 4). **V1: nothing here names `KaibaCore`, `MsgParser` or
## anything under `native/`.** It consumes intents and it reads `BoardView`; it has never heard
## of ocgcore, of an event stream, or of a response.
##
## **V9**: an intent is disposable. Nothing in this file is ever written to a replay, which is
## exactly why animation timing can be retuned without invalidating the replay library.
##
## -------------------------------------------------------------------------------------------
## The blocking rule
## -------------------------------------------------------------------------------------------
## Every intent carries `blocking`. The contract, from `EventTranslator`: *"blocking means the
## next intent waits for this one"*. It says nothing about what the blocking intent itself has
## to wait for, and that asymmetry is deliberate - it is what makes a five-card draw play as one
## beat instead of five.
##
## So the pump is a single barrier, not a per-intent dependency graph:
##
##   while the queue is not empty and the barrier is down:
##       pop an intent and start it
##       if it was blocking, raise the barrier and stop popping
##
## The barrier comes down when that one intent's `Tween` finishes. While it is up nothing new
## starts; while it is down intents keep starting and simply overlap. At most one blocking
## intent can ever be in flight, because nothing starts after one until it is done.
##
## A `DRAW` of five therefore starts all five - four non-blocking, then the fifth which raises
## the barrier - and the sixth intent waits for the fifth to land. That is the behaviour
## `EventTranslator._translate_draw` was written to produce.
##
## A `duration` of zero is honoured without a frame of delay: `KIND_SUMMON_COMPLETE` budgets
## 0.0 seconds, and routing it through a `Tween` would cost it a frame each time and turn a
## pure sequencing marker into a stutter.
##
## -------------------------------------------------------------------------------------------
## Card identity, and the hole in it
## -------------------------------------------------------------------------------------------
## An intent names a card by `card_id` and names places by anchor (V11). It carries no handle
## to a particular card instance, so this class resolves "which quad is this about" from the
## anchors: the card at `from_anchor` is the one that moves. That is right for zones and for
## the top of a pile, and it is a guess for anything else - two copies of the same card in one
## hand are indistinguishable, and a face-down card has `card_id == 0`.
##
## The guess is deliberately cheap because it does not have to be right for long: `DuelState`
## is authoritative, and `BoardView.sync_from_state()` rebuilds the board from it whenever this
## director goes idle. Animation is allowed to lag and allowed to be approximate
## (ARCHITECTURE.md section 5); the model is not.

## Emitted on every busy -> idle transition: the queue is empty and nothing is still moving.
## The right moment to reconcile the board against `DuelState`.
signal queue_drained

## Diagnostics and HUD cues. Carries the intent itself, which is already disposable.
## Advisory framing hint. The director knows a monster was summoned; only a `CameraRig` knows
## whether moving the camera is safe, so this is a cue and not a command. A VR rig must ignore
## it entirely — see `CameraRig.cue()`.
signal camera_cue(kind: String, world_position: Vector3)

signal intent_started(intent: Dictionary)
signal intent_finished(intent: Dictionary)

## Multiplies every `duration` an intent asks for. 1.0 plays at the budgeted speed; the headless
## self-check turns it right down so a duel does not take its wall-clock time to verify.
@export var duration_scale: float = 1.0

## Height of the arc a travelling card follows. Cards slid flat across the table clip through
## the ones already on it.
@export var travel_arc: float = 0.06

## How far an attacking monster lunges towards its target, as a fraction of the distance.
@export var attack_lunge: float = 0.55

var _board: BoardView = null
var _queue: Array[Dictionary] = []

## id -> {"intent", "tween", "finish", "blocking"}. Keyed by id rather than held in an Array
## because the only lookup is "the animation this `Tween` belongs to".
var _running: Dictionary = {}
var _next_id: int = 1

## True while a blocking intent is in flight. The whole rule, in one bool.
var _barrier: bool = false

var _idle: bool = true
var _unknown_kinds: Dictionary = {}


## The board this director animates. Must be set before the first `enqueue()`.
func bind(board: BoardView) -> void:
	_board = board


func enqueue(intents: Array) -> void:
	for value: Variant in intents:
		if value is Dictionary:
			_queue.append(value as Dictionary)
			_idle = false
	_pump()


## Abandons the animation and leaves the board where the animation would have put it.
##
## Everything in flight is killed and finished on the spot, then everything still queued is
## applied instantly. The board therefore ends up in the same state as if the whole queue had
## played out, which is the only behaviour a "skip" can have without desynchronising the view
## from `DuelState`.
func skip_all() -> void:
	for key: Variant in _running.keys():
		var entry: Dictionary = _running[key] as Dictionary
		var tween: Tween = entry.get("tween", null) as Tween
		if tween != null and tween.is_valid():
			tween.kill()
		_settle(entry)
	_running.clear()
	_barrier = false

	var pending: Array[Dictionary] = _queue
	_queue = []
	for intent: Dictionary in pending:
		_begin(intent, true)

	_drain_check()


func is_idle() -> bool:
	return _queue.is_empty() and _running.is_empty()


func _process(_delta: float) -> void:
	_pump()


# ----------------------------------------------------------------------------------------------
# Pump
# ----------------------------------------------------------------------------------------------

func _pump() -> void:
	while not _queue.is_empty() and not _barrier:
		_begin(_queue.pop_front(), false)
	_drain_check()


func _drain_check() -> void:
	if _idle:
		return
	if not is_idle():
		return
	_idle = true
	queue_drained.emit()
	# Nothing left to watch, so suggest returning to the resting frame.
	camera_cue.emit(CameraRig.CUE_SETTLE, Vector3.ZERO)


## Suggests a framing for the intents worth looking at.
##
## Deliberately a short list. Cueing on every move would mean cueing on every card that goes to
## the graveyard during a long chain, and the camera would spend the duel twitching.
func _emit_camera_cue(intent: Dictionary) -> void:
	var kind: String = str(intent.get("kind", ""))
	var cue: String = ""
	match kind:
		EventTranslator.KIND_SUMMON:
			cue = CameraRig.CUE_SUMMON
		EventTranslator.KIND_ATTACK:
			cue = CameraRig.CUE_ATTACK
		EventTranslator.KIND_BATTLE:
			cue = CameraRig.CUE_DAMAGE
		_:
			return

	# Frame where the action lands, falling back to where it came from.
	var anchor_name: String = str(intent.get("to_anchor", intent.get("anchor", "")))
	if anchor_name == "":
		anchor_name = str(intent.get("from_anchor", ""))
	if anchor_name == "":
		return
	camera_cue.emit(cue, _board.anchor_position(anchor_name))


## Starts one intent. `instant` collapses it to its end state with no tween, which is both the
## zero-duration path and the `skip_all()` path.
func _begin(intent: Dictionary, instant: bool) -> void:
	if _board == null:
		push_warning("[AnimationDirector] no board bound; dropping intent %s" % intent.get("kind", "?"))
		return

	var duration: float = 0.0 if instant else maxf(0.0, float(intent.get("duration", 0.0))) * duration_scale
	var entry: Dictionary = {
		"intent": intent,
		"tween": null,
		"finish": Callable(),
		"blocking": bool(intent.get("blocking", false)),
	}

	intent_started.emit(intent)
	_emit_camera_cue(intent)
	_build(intent, entry, duration)

	var tween: Tween = entry["tween"] as Tween
	if duration <= 0.0:
		if tween != null and tween.is_valid():
			tween.kill()
		entry["tween"] = null
		_settle(entry)
		return

	# An intent that animates nothing still costs its budgeted time. Without this, a blocking
	# `KIND_TURN_START` - which has no card and no anchor to move - would release the barrier in
	# the same frame it took it, and the turn banner would flash past. `blocking` controls who
	# waits; `duration` controls how long. The two are independent and both have to be honoured.
	if tween == null:
		tween = create_tween()
		tween.tween_interval(duration)
		entry["tween"] = tween

	var id: int = _next_id
	_next_id += 1
	_running[id] = entry
	if entry["blocking"]:
		_barrier = true
	tween.finished.connect(_on_tween_finished.bind(id))


func _on_tween_finished(id: int) -> void:
	if not _running.has(id):
		return
	var entry: Dictionary = _running[id] as Dictionary
	_running.erase(id)
	if entry["blocking"]:
		_barrier = false
	_settle(entry)
	_pump()


## Runs an animation's end state exactly once, whether it got there by playing out, by being
## skipped, or by having no duration at all.
func _settle(entry: Dictionary) -> void:
	var finish: Callable = entry["finish"]
	if finish.is_valid():
		finish.call()
		entry["finish"] = Callable()
	intent_finished.emit(entry["intent"] as Dictionary)


# ----------------------------------------------------------------------------------------------
# Intent handlers
# ----------------------------------------------------------------------------------------------

## Fills `entry` with a `Tween` and a finish `Callable`. Either may be absent: an intent with
## nothing to animate still consumes its duration, which is how pacing survives the fact that
## most of the stream has no card in it.
func _build(intent: Dictionary, entry: Dictionary, duration: float) -> void:
	var kind: String = str(intent.get("kind", ""))

	if kind == EventTranslator.KIND_ATTACK:
		_build_attack(intent, entry, duration)
		return
	if kind == EventTranslator.KIND_BATTLE:
		_build_battle(intent, entry, duration)
		return
	if intent.has("from_anchor") and intent.has("to_anchor"):
		_build_motion(intent, entry, duration)
		return
	if intent.has("anchor") and intent.has("card_id"):
		_build_in_place(intent, entry, duration)
		return

	# Pure pacing: SUMMON_COMPLETE, PHASE_CHANGE, TURN_START, LP_CHANGE, ATTACK_CANCEL. Nothing
	# on the board moves, but the beat is still worth its budgeted time.
	if not _is_known_kind(kind):
		_warn_unknown(kind)


## A card travelling between two anchors. Covers almost everything: MOVE, SUMMON, SET's travel,
## TRIBUTE, DISCARD, DESTROY, DRAW, TO_GRAVE, BANISH, CREATE, REMOVE and the rest.
func _build_motion(intent: Dictionary, entry: Dictionary, duration: float) -> void:
	var from_anchor: String = str(intent["from_anchor"])
	var to_anchor: String = str(intent["to_anchor"])
	var card_id: int = int(intent.get("card_id", 0))

	var view: CardView = _claim(from_anchor, card_id, str(intent.get("from_face", "")), int(intent.get("handle", 0)))
	if view == null:
		return

	# The destination may reveal a card that travelled face-down. Resolving art from the id at
	# the moment of use is the V11/V12 contract.
	if card_id != 0:
		view.set_card_id(card_id)
	_board.apply_face(view, str(intent.get("face", "")))

	var leaving: bool = to_anchor == BoardView.ANCHOR_NOWHERE
	var target: Transform3D = _landing(to_anchor, view)

	if leaving:
		entry["finish"] = func() -> void:
			view.global_transform = target
			_board.release_view(view)
	else:
		entry["finish"] = func() -> void:
			_board.place_view(view, to_anchor)

	if duration <= 0.0:
		return
	entry["tween"] = _arc(view, target, duration)


## A card that stays where it is but changes: SET, SUMMON_ANNOUNCE, POS_CHANGE, FLIP.
func _build_in_place(intent: Dictionary, entry: Dictionary, duration: float) -> void:
	var anchor: String = str(intent["anchor"])
	var card_id: int = int(intent.get("card_id", 0))

	var view: CardView = _claim(anchor, card_id, str(intent.get("from_face", "")), int(intent.get("handle", 0)))
	if view == null:
		return
	if card_id != 0:
		view.set_card_id(card_id)
	_board.apply_face(view, str(intent.get("face", "")))

	var target: Transform3D = _landing(anchor, view)
	entry["finish"] = func() -> void:
		_board.place_view(view, anchor)

	if duration <= 0.0:
		return

	# Lifted off the table and set back down, so a flip or a reposition reads as a deliberate
	# beat rather than as a card snapping through the surface.
	var raised: Transform3D = target.translated(Vector3(0.0, travel_arc * 0.5, 0.0))
	var tween: Tween = create_tween()
	tween.tween_property(view, "global_transform", raised, duration * 0.5)
	tween.tween_property(view, "global_transform", target, duration * 0.5)
	entry["tween"] = tween


## The attacker lunges at its target and comes back. It does not move zones: whatever the attack
## destroys arrives separately as its own MOVE intent.
func _build_attack(intent: Dictionary, entry: Dictionary, duration: float) -> void:
	var from_anchor: String = str(intent.get("from_anchor", ""))
	var to_anchor: String = str(intent.get("to_anchor", ""))
	var view: CardView = _board.view_at(from_anchor)
	if view == null or duration <= 0.0:
		return

	var home: Transform3D = view.global_transform
	var toward: Vector3 = _board.anchor_position(to_anchor) - home.origin
	var lunge: Transform3D = home.translated(toward * attack_lunge + Vector3(0.0, travel_arc, 0.0))

	var tween: Tween = create_tween()
	tween.tween_property(view, "global_transform", lunge, duration * 0.4)
	tween.tween_property(view, "global_transform", home, duration * 0.6)
	entry["tween"] = tween
	entry["finish"] = func() -> void:
		view.global_transform = home


## Damage calculation. Both combatants shudder; destruction is a separate intent.
func _build_battle(intent: Dictionary, entry: Dictionary, duration: float) -> void:
	var view: CardView = _board.view_at(str(intent.get("from_anchor", "")))
	if view == null or duration <= 0.0:
		return

	var home: Transform3D = view.global_transform
	var shove: Transform3D = home.translated(Vector3(0.0, travel_arc * 0.3, 0.0))
	var tween: Tween = create_tween()
	tween.tween_property(view, "global_transform", shove, duration * 0.25)
	tween.tween_property(view, "global_transform", home, duration * 0.25)
	tween.tween_property(view, "global_transform", shove, duration * 0.25)
	tween.tween_property(view, "global_transform", home, duration * 0.25)
	entry["tween"] = tween
	entry["finish"] = func() -> void:
		view.global_transform = home


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## Takes the card at an anchor out of the board's occupancy so it can be flown somewhere, or
## conjures one if the board does not have it. Conjuring is normal, not a failure: the first
## thing a duel does is draw five cards out of a deck nothing has rendered yet.
## Takes the view that should move.
##
## Prefers the intent's `handle`, which names one physical card exactly. Falls back to the top
## of the anchor's pile when no handle is available - correct for piles, a guess for a hand.
func _claim(anchor: String, card_id: int, face: String, handle: int = 0) -> CardView:
	var view: CardView = _board.take_view_by_handle(handle)
	if view != null:
		return view

	view = _board.take_view(anchor)
	if view != null:
		view.handle = handle
		return view

	view = _board.card_pool().acquire()
	if view == null:
		return null
	view.handle = handle
	view.set_card_id(card_id)
	_board.apply_face(view, face)
	view.global_transform = _board.rest_transform(anchor, 0, 1, view)
	return view


## Where a card lands at an anchor: on top of whatever is already parked there. The count can
## still be stale by the time the tween ends if several cards are flying into the same pile, so
## `BoardView.place_view()` re-seats the whole stack on arrival. This only has to be close.
func _landing(anchor: String, view: CardView) -> Transform3D:
	var index: int = _board.occupant_count(anchor)
	return _board.rest_transform(anchor, index, index + 1, view)


## Travel as two halves through a raised midpoint. A straight line between two zones passes
## through every card between them.
func _arc(view: CardView, target: Transform3D, duration: float) -> Tween:
	var start: Transform3D = view.global_transform
	var middle: Transform3D = target
	middle.origin = start.origin.lerp(target.origin, 0.5) + Vector3(0.0, travel_arc, 0.0)

	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(view, "global_transform", middle, duration * 0.5)
	tween.tween_property(view, "global_transform", target, duration * 0.5)
	return tween


## Kinds that are expected to animate nothing. Listing them keeps the unknown-kind warning
## meaningful: it should mean "nobody taught the director about this", not "this one has no
## card in it". Same reasoning as `DuelState.PASSIVE_EVENTS` (V13).
const SILENT_KINDS: Array[String] = [
	EventTranslator.KIND_SUMMON_COMPLETE,
	EventTranslator.KIND_PHASE_CHANGE,
	EventTranslator.KIND_TURN_START,
	EventTranslator.KIND_LP_CHANGE,
	EventTranslator.KIND_ATTACK_CANCEL,
]


func _is_known_kind(kind: String) -> bool:
	return SILENT_KINDS.has(kind) or EventTranslator.PROFILES.has(kind)


func _warn_unknown(kind: String) -> void:
	if _unknown_kinds.has(kind):
		return
	_unknown_kinds[kind] = true
	push_warning("[AnimationDirector] no animation for intent kind \"%s\"; timing it out" % kind)
