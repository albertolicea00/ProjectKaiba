extends Node3D

## Phase 2 skeleton: a real ocgcore duel rendered on a real-scale 3D board.
##
##   godot --headless --path game res://scenes/duel_3d.tscn     # self-checks, then quits
##   godot --path game res://scenes/duel_3d.tscn                # watch it play
##
## Layer: L5. It is allowed to know about L1 (`KaibaCore`), L3 (`DuelState`, `EventTranslator`)
## and L4 (`BoardView`, `AnimationDirector`) at once, because wiring them together is the only
## thing it does. **Nothing under `game/view/` or `game/platform/` may do the same** - that is
## V1, and this file is the seam that keeps it true: the core's events go in one side, Level-2
## intents come out, and the view layer never sees the other half.
##
## -------------------------------------------------------------------------------------------
## The pipeline, once per polled event
## -------------------------------------------------------------------------------------------
##   KaibaCore.poll_event()  ->  Level-1 DuelEvent
##     -> DuelState.apply(event)                     L3 model, authoritative, instant
##     -> EventTranslator.translate(event)           Level-2 intents, lossy and disposable (V9)
##        -> AnimationDirector.enqueue(intents)      L4, animates, allowed to lag
##   AnimationDirector.queue_drained
##     -> BoardView.sync_from_state(DuelState)       reconciliation (ARCHITECTURE.md section 5)
##
## The two state models never argue, because the view is rebuilt from the model every time the
## animation queue empties. Animation is a presentation of the truth, not a second copy of it.
##
## -------------------------------------------------------------------------------------------
## Answering selections
## -------------------------------------------------------------------------------------------
## `_plan()` is the same approach as `scenes/duel_real.gd`: dispatch on the selection *type*,
## never on a step counter. ocgcore inserts selections that a fixed script does not expect - the
## opponent gets priority with `MSG_SELECT_CHAIN` after a normal summon - and any plan that
## assumes a fixed order desynchronises the first time it happens. `_pick_place()` likewise
## reads the request's own mask rather than hardcoding a zone, because answering a spell
## activation with a monster zone earns a silent `MSG_RETRY` (AGENTS.md section 8b traps 8 and
## 9). This is a scripted stand-in; the real `heuristic_agent` is Phase 2's other half.

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"
const SCRIPT_ROOTS: Array[String] = [
	"res://../data/base/script",
	"res://../data/base/script/official",
	"res://../data/base/script/unofficial",
	"res://../data/base/script/pre-release",
]

## Same deck as `scenes/duel_real.gd`: level 4 vanilla beaters that summon without tributes, one
## level 8 so the deck is not uniform, and Pot of Greed because a scripted card proves the Lua
## collection actually loaded.
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

## Headless has no wall clock to spare: a duel that animates at its budgeted speed would take
## minutes to verify. Nothing about the blocking rule depends on how long a tween lasts.
const HEADLESS_DURATION_SCALE: float = 0.05

var _art: CardArt = null

@onready var _board: BoardView = $World3D/BoardView
@onready var _director: AnimationDirector = $AnimationDirector

## Built in `_ready()`; see there for why it is not in the scene file.
var _audio: AudioDirector = null
@onready var _rig: CameraRig = $World3D/CameraRig

var _core: Object = null
var _state: DuelState = DuelState.new()
var _translator: EventTranslator = EventTranslator.new()

var _headless: bool = false
var _failures: PackedStringArray = PackedStringArray()

var _has_cdb: bool = false
var _activated_pot: bool = false
var _has_summoned: bool = false
var _attacked: bool = false
var _damage_dealt: int = 0
var _monster_reached_field: bool = false

var _event_count: int = 0
var _intent_count: int = 0
var _suppressed_logs: int = 0
var _idle_frames: int = 0
var _frames: int = 0
var _drains: int = 0
var _running: bool = false
var _stopping: bool = false

## Monotonic counter stamped on every `intent_started` / `intent_finished`. Frame numbers are
## too coarse to prove the blocking rule - several intents legitimately start in one frame - so
## the probe below orders events by this instead.
var _sequence: int = 0
var _probe_started: Dictionary = {}
var _probe_finished: Dictionary = {}


func _ready() -> void:
	set_process(false)
	_headless = DisplayServer.get_name() == "headless" or OS.get_cmdline_args().has("--headless")

	_rig.activate()
	# One cache for the whole duel; CardView reads it through a static so every view shares it,
	# which is the only way the LRU budget means anything. It configures its own roots and picks
	# sd on Android / hd elsewhere, so there is nothing to pass in.
	_art = CardArt.new()
	CardView.art_source = _art

	_director.bind(_board)
	# Advisory only: the director suggests a framing, the rig decides whether to take it. A VR
	# rig ignores every cue, because moving a camera a person's head is not moving is how you
	# make them sick (CameraRig.cue()).
	_director.camera_cue.connect(_rig.cue)
	_director.camera_cue.connect(_on_camera_cue)

	if _headless:
		_director.duration_scale = HEADLESS_DURATION_SCALE
	_director.queue_drained.connect(_on_queue_drained)
	_director.intent_started.connect(_on_intent_started)
	_director.intent_finished.connect(_on_intent_finished)

	# Sound. It listens to the same `intent_started` stream the animation runs on and to nothing
	# else, so what is heard and what is seen cannot drift apart (see `audio_director.gd`). The
	# node is built here rather than placed in the `.tscn` because it has no editable state worth
	# serialising - its pools, buses and bank are all built in `initialise()`.
	_audio = AudioDirector.new()
	_audio.name = "AudioDirector"
	add_child(_audio)
	_audio.bind(_director)
	# `win` and `lose` exist and are reachable, but neither of these harness scenes decides a
	# winner - they stop on a probe result, not on a duel result. The context stays `duel`.
	_audio.set_music_context(AudioDirector.MUSIC_DUEL)

	print("[duel3d] board %.2f m x %.2f m, cards %.3f m x %.3f m" % [
		_board.table_footprint().x, _board.table_footprint().y,
		CardView.CARD_WIDTH, CardView.CARD_HEIGHT,
	])

	_check_table()
	_check_anchors()
	_start_director_probe()


func _process(_delta: float) -> void:
	if _art != null:
		_board.refresh_art(_art)

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

	if drained > 0:
		_idle_frames = 0
		return

	_idle_frames += 1
	if _idle_frames >= IDLE_FRAMES_BEFORE_GIVING_UP:
		_stop("no further events; the duel thread has gone quiet")


# ----------------------------------------------------------------------------------------------
# Self-checks
# ----------------------------------------------------------------------------------------------

## A headless run draws nothing, so the only way to know the board is right is to measure it.
func _check_table() -> void:
	var footprint: Vector2 = _board.table_footprint()
	_expect(is_equal_approx(footprint.x, 1.20) and is_equal_approx(footprint.y, 0.75),
		"table is 1.20 m x 0.75 m at real-world scale (got %.3f x %.3f)" % [footprint.x, footprint.y])
	_expect(is_equal_approx(CardView.CARD_WIDTH, 0.059) and is_equal_approx(CardView.CARD_HEIGHT, 0.086),
		"cards are 8.6 cm x 5.9 cm")

	# A zone wide enough to hold the card it is named after. Column pitch below the card width
	# would mean neighbouring monsters overlapping, which no amount of art fixes later.
	_expect(BoardView.COLUMN_PITCH > CardView.CARD_WIDTH,
		"column pitch %.3f m clears the %.3f m card width" % [BoardView.COLUMN_PITCH, CardView.CARD_WIDTH])
	_expect(BoardView.ROW_PITCH > CardView.CARD_HEIGHT,
		"row pitch %.3f m clears the %.3f m card height" % [BoardView.ROW_PITCH, CardView.CARD_HEIGHT])

	# Every zone that is supposed to sit on the table has to fit on it, measured against the
	# card's long edge because a defense-position card is turned sideways. The hand and the
	# player anchor are excluded on purpose: both deliberately sit past the near edge, which is
	# where a seated player's hands actually are.
	var widest: float = 0.0
	var deepest: float = 0.0
	for anchor: String in _board.anchor_names():
		if anchor.begins_with("PLAYER_P") or anchor.begins_with("HAND_P") or anchor == BoardView.ANCHOR_NOWHERE:
			continue
		var position: Vector3 = _board.anchor_position(anchor)
		widest = maxf(widest, absf(position.x) + CardView.CARD_HEIGHT * 0.5)
		deepest = maxf(deepest, absf(position.z) + CardView.CARD_HEIGHT * 0.5)
	_expect(widest <= 1.20 * 0.5,
		"every zone fits across the table (needs %.3f m of the 0.600 m half-width)" % widest)
	_expect(deepest <= 0.75 * 0.5,
		"every zone fits along the table (needs %.3f m of the 0.375 m half-depth)" % deepest)


## Two zones at the same point would make the whole anchor grammar meaningless: a card sent to
## `GY_P0` would land on `DECK_P0` and nobody would be able to tell.
func _check_anchors() -> void:
	var names: PackedStringArray = _board.anchor_names()
	var seen: Dictionary = {}
	var collisions: PackedStringArray = PackedStringArray()

	for anchor: String in names:
		var position: Vector3 = _board.anchor_position(anchor)
		var key: String = "%.4f|%.4f|%.4f" % [position.x, position.y, position.z]
		if seen.has(key):
			collisions.append("%s == %s" % [anchor, seen[key]])
		seen[key] = anchor

	_expect(collisions.is_empty(),
		"all %d anchors resolve to distinct positions%s" % [
			names.size(),
			"" if collisions.is_empty() else " (collisions: %s)" % ", ".join(collisions),
		])

	# Every anchor `EventTranslator.anchor_of()` can produce must resolve. These are built by
	# calling it, not by retyping its output, so the two cannot drift apart.
	var required: PackedStringArray = PackedStringArray()
	for player: int in range(DuelEnums.PLAYER_COUNT):
		for sequence: int in range(DuelEnums.MZONE_SLOTS):
			required.append(EventTranslator.anchor_of({"con": player, "loc": DuelEnums.LOCATION.MZONE, "seq": sequence, "pos": 0}))
		for sequence: int in range(DuelEnums.SPELL_TRAP_ZONES + 1):
			required.append(EventTranslator.anchor_of({"con": player, "loc": DuelEnums.LOCATION.SZONE, "seq": sequence, "pos": 0}))
		for location: int in [DuelEnums.LOCATION.DECK, DuelEnums.LOCATION.HAND, DuelEnums.LOCATION.GRAVE,
				DuelEnums.LOCATION.REMOVED, DuelEnums.LOCATION.EXTRA]:
			required.append(EventTranslator.anchor_of({"con": player, "loc": location, "seq": 0, "pos": 0}))
		required.append("PLAYER_P%d" % player)

	var missing: PackedStringArray = PackedStringArray()
	for anchor: String in required:
		if not names.has(anchor):
			missing.append(anchor)
	_expect(missing.is_empty(),
		"every anchor EventTranslator can emit has a marker%s" % (
			"" if missing.is_empty() else " (missing: %s)" % ", ".join(missing)))

	# Player 1's half is player 0's half turned half a turn about the table centre.
	var near: Vector3 = _board.anchor_position("MZ_P0_0")
	var far: Vector3 = _board.anchor_position("MZ_P1_0")
	_expect(near.distance_to(Vector3(-far.x, far.y, -far.z)) < 0.0005,
		"player 1's board is player 0's mirrored through the table centre")

	# An unknown anchor must resolve, not crash (V13's spirit applied to the anchor grammar).
	print("[duel3d] the next warning is this check doing its job")
	var nowhere: Vector3 = _board.anchor_position("NOT_AN_ANCHOR_P9")
	_expect(nowhere.is_equal_approx(_board.anchor_position(BoardView.ANCHOR_NOWHERE)),
		"an unrecognised anchor falls back to NOWHERE instead of crashing")

	# The overlay grammar is computed, not a marker, so check it lands on its host.
	var host: Vector3 = _board.anchor_position("MZ_P0_2")
	var material: Vector3 = _board.anchor_position("OVL_MZ_P0_2_0")
	_expect(material.distance_to(host) > 0.0 and material.distance_to(host) < 0.05,
		"an xyz material sits just off its host zone")


## Proves the blocking rule with three intents that must overlap followed by one that must not.
##
## Ordering is checked against a monotonic counter rather than frame numbers: several intents
## starting in the same frame is the *correct* behaviour for the non-blocking ones, so a frame
## number cannot distinguish "overlapped" from "waited".
func _start_director_probe() -> void:
	var intents: Array[Dictionary] = [
		_probe_intent(0, EventTranslator.KIND_DRAW, false, "DECK_P0", "HAND_P0"),
		_probe_intent(1, EventTranslator.KIND_DRAW, false, "DECK_P0", "HAND_P0"),
		_probe_intent(2, EventTranslator.KIND_DRAW, true, "DECK_P0", "HAND_P0"),
		_probe_intent(3, EventTranslator.KIND_SUMMON, true, "HAND_P0", "MZ_P0_2"),
		_probe_intent(4, EventTranslator.KIND_PHASE_CHANGE, false, "", ""),
	]
	_director.enqueue(intents)
	set_process(true)


func _probe_intent(index: int, kind: String, blocking: bool, from_anchor: String, to_anchor: String) -> Dictionary:
	var intent: Dictionary = {
		"kind": kind,
		"duration": 0.12,
		"blocking": blocking,
		"probe": index,
		"card_id": BEATERS[index % BEATERS.size()],
		"face": EventTranslator.FACE_UP_ATTACK,
	}
	if from_anchor != "":
		intent["from_anchor"] = from_anchor
		intent["to_anchor"] = to_anchor
	else:
		intent.erase("card_id")
	return intent


func _finish_director_probe() -> void:
	for index: int in range(5):
		if not _probe_started.has(index) or not _probe_finished.has(index):
			_fail("probe intent %d both started and finished" % index)
			return

	_expect(_probe_started[1] < _probe_finished[0] and _probe_started[2] < _probe_finished[0],
		"non-blocking intents overlap: all three draws were in flight at once")
	_expect(_probe_started[3] > _probe_finished[2],
		"a blocking intent holds the queue: the summon started only after the blocking draw landed")
	_expect(_probe_started[4] > _probe_finished[3],
		"the intent after a blocking one waits for it too")
	_expect(_director.is_idle(), "the director is idle once the queue is drained")
	_expect(_drains == 1, "queue_drained fired exactly once for the batch (got %d)" % _drains)

	# `skip_all()` must leave the board where the animation would have left it, not half way.
	_director.enqueue([_probe_intent(5, EventTranslator.KIND_MOVE, true, "HAND_P0", "GY_P0")])
	_director.skip_all()
	_expect(_director.is_idle(), "skip_all() empties the queue and stops everything in flight")

	_board.card_pool().release_all()
	_start_duel()


# ----------------------------------------------------------------------------------------------
# Duel
# ----------------------------------------------------------------------------------------------

func _start_duel() -> void:
	if not ClassDB.class_exists(CORE_CLASS):
		_fail("%s is not registered; the GDExtension did not load. Run: make host" % CORE_CLASS)
		_stop("no core")
		return
	_core = ClassDB.instantiate(CORE_CLASS)

	# `res://../` escapes the project directory, so it has to be globalised before a plain
	# `FileAccess` check will see it. The native side resolves the same path for itself.
	_has_cdb = FileAccess.file_exists(ProjectSettings.globalize_path(CDB_PATH))
	if _has_cdb:
		var loaded: Dictionary = _core.load_card_database(CDB_PATH)
		if not bool(loaded.get("ok", false)):
			_fail("could not load %s: %s" % [CDB_PATH, loaded.get("error", "?")])
			_stop("no card database")
			return
		print("[duel3d] card database loaded: %d cards" % int(loaded.get("count", 0)))
		for root: String in SCRIPT_ROOTS:
			_core.add_script_root(root)
	else:
		# docs/DATA.md: without a cdb every code is just a number and no effect fires. The
		# board still renders, which is the point of this scene, so this is a warning and not
		# a failure.
		print("[duel3d] no cards.cdb; running codes-only (see docs/DATA.md)")

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

	# ocgcore never emits MSG_START (AGENTS.md section 8b.1); the host synthesises it. Without
	# it the model would show zero life points and an empty deck for the whole duel.
	_state.apply({
		"t": DuelEnums.EV.START,
		"lp": [START_LP, START_LP],
		"deck": [DECK_SIZE, DECK_SIZE],
		"extra": [0, 0],
		"first": 0,
	})
	_board.sync_from_state(_state)
	print("[duel3d] duel started, seed = %s" % str(started.get("seed", [])))
	_running = true


func _build_deck() -> PackedInt32Array:
	var deck: PackedInt32Array = PackedInt32Array()
	for index: int in DECK_SIZE:
		if not _has_cdb:
			deck.append(BIG)
		elif index % 10 == 0:
			deck.append(BIG)
		elif index % 5 == 0:
			deck.append(POT_OF_GREED)
		else:
			deck.append(BEATERS[index % BEATERS.size()])
	return deck


func _handle(event: Dictionary) -> void:
	var type: int = int(event.get("t", -1))

	# 1000-1099 are DuelThread lifecycle events, not ocgcore opcodes. Feeding them to DuelState
	# would only trip its V13 warning.
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

	# L3 first: the model is authoritative and updates instantly.
	_state.apply(event)

	# Then Level 2, which is lossy, enriched and never stored (V9).
	# After apply(), so the translator resolves handles from the card's destination.
	var intents: Array[Dictionary] = _translator.translate(event, _state)
	if not intents.is_empty():
		_intent_count += intents.size()
		_director.enqueue(intents)

	match type:
		DuelEnums.EV.MOVE:
			var to: Dictionary = event.get("to", {})
			if int(to.get("loc", 0)) == DuelEnums.LOCATION.MZONE:
				_monster_reached_field = true
		DuelEnums.EV.DAMAGE:
			_damage_dealt = int(event.get("amount", 0))
		DuelEnums.EV.RETRY:
			_fail("ocgcore rejected a response; the last answer was malformed for its selection")
			_stop("retry")
			return

	if type < FIRST_SELECT_EVENT or type > LAST_SELECT_EVENT:
		return

	var answer: Dictionary = _plan(type, event)
	if answer.is_empty():
		_stop("no plan for selection %s" % DuelEnums.ev_name(type))
		return
	var responded: Dictionary = _core.respond(type, answer)
	if not bool(responded.get("ok", false)):
		_fail("respond(%d, %s) failed: %s" % [type, str(answer), responded.get("error", "?")])
		_stop("respond failed")
		return

	if _attacked and _damage_dealt > 0:
		_stop("the scripted opening finished")


## Dispatch on the selection type, never on a step counter. See the header note.
func _plan(event_type: int, event: Dictionary) -> Dictionary:
	match event_type:
		DuelEnums.EV.SELECT_CHAIN:
			# -1 is only accepted when the chain was not forced; a forced one needs a real index.
			if bool(event.get("forced", false)):
				return {"index": 0}
			return {"cancel": true}

		DuelEnums.EV.SELECT_IDLECMD:
			var activate: Array = event.get("activate", [])
			if _has_cdb and not _activated_pot and activate.size() > 0:
				_activated_pot = true
				return {"cmd": "activate", "index": 0}
			if not _has_summoned:
				var summon: Array = event.get("summon", [])
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
			return {"position": DuelEnums.POSITION.FACEUP_ATTACK}

		DuelEnums.EV.SELECT_BATTLECMD:
			var attack: Array = event.get("attack", [])
			if attack.is_empty():
				return {"cmd": "to_ep"}
			_attacked = true
			return {"cmd": "attack", "index": 0}

		DuelEnums.EV.SELECT_EFFECTYN, DuelEnums.EV.SELECT_YESNO:
			return {"answer": 0}

	_fail("no plan for selection type %s" % DuelEnums.ev_name(event_type))
	return {}


## Picks the first legal zone out of the request's own mask. A set bit means NOT selectable, and
## the sides are relative to `event["player"]` (AGENTS.md section 8b trap 9).
func _pick_place(event: Dictionary) -> Dictionary:
	var flag: int = int(event.get("flag", 0))
	var me: int = int(event.get("player", 0))

	for sequence: int in range(DuelEnums.MZONE_SLOTS):
		if (flag & (1 << sequence)) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.MZONE, "seq": sequence}], "count": 1}
	for sequence: int in range(DuelEnums.SZONE_SLOTS):
		if (flag & (1 << (8 + sequence))) == 0:
			return {"places": [{"con": me, "loc": DuelEnums.LOCATION.SZONE, "seq": sequence}], "count": 1}

	_fail("SELECT_PLACE offered no free zone on our side (flag 0x%x)" % flag)
	return {}


# ----------------------------------------------------------------------------------------------
# Director callbacks
# ----------------------------------------------------------------------------------------------

func _on_intent_started(intent: Dictionary) -> void:
	_sequence += 1
	if intent.has("probe"):
		_probe_started[int(intent["probe"])] = _sequence


func _on_intent_finished(intent: Dictionary) -> void:
	_sequence += 1
	if intent.has("probe"):
		_probe_finished[int(intent["probe"])] = _sequence


## The reconciliation point (ARCHITECTURE.md section 5). Safe only here: `sync_from_state()`
## recycles the very card views a tween would otherwise still be holding.
func _on_queue_drained() -> void:
	_drains += 1
	if not _running:
		if _drains == 1:
			_finish_director_probe()
		return
	_board.sync_from_state(_state)


# ----------------------------------------------------------------------------------------------
# Reporting
# ----------------------------------------------------------------------------------------------

func _stop(reason: String) -> void:
	if _stopping:
		return
	_stopping = true
	_running = false
	set_process(false)

	_director.skip_all()
	_board.sync_from_state(_state)

	print("[duel3d] %s" % reason)
	print("[duel3d] %d events, %d intents, %d core log lines suppressed" % [
		_event_count, _intent_count, _suppressed_logs,
	])
	print(_state.describe())

	_check_board_tracks_model()

	if _core != null:
		_core.end_duel()

	if _failures.is_empty():
		print("[duel3d] all checks passed")
	else:
		print("[duel3d] %d check(s) failed" % _failures.size())

	# A windowed run stays up so the board can be looked at; a headless one is a test and has
	# to report an exit code.
	if _headless:
		get_tree().quit(0 if _failures.is_empty() else 1)


## The end-to-end claim: after reconciliation the board shows what the model holds. This is the
## only check that spans L1 -> L3 -> L4 in one assertion.
func _check_board_tracks_model() -> void:
	if _core == null:
		return

	var mismatches: PackedStringArray = PackedStringArray()
	var occupied: int = 0
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
			occupied += 1
			if card.is_face_up() and view.card_id != card.code:
				mismatches.append("%s shows %s, model holds %s" % [anchor, view.describe(), card.short_label()])

	_expect(mismatches.is_empty(),
		"every monster zone on the board matches DuelState%s" % (
			"" if mismatches.is_empty() else " (%s)" % ", ".join(mismatches)))
	# Only meaningful once something actually reached a monster zone. The scripted opening
	# summons and then attacks directly, so nothing leaves the field before we stop.
	if _monster_reached_field:
		_expect(occupied > 0, "a monster that reached the field is rendered in its zone")
	_expect(not _board.card_pool().has_grown(),
		"the card pool never had to allocate mid-duel (%d created, %d in use)" % [
			_board.card_pool().created_count(), _board.card_pool().active_count()])

	if _has_cdb:
		_expect(_damage_dealt > 0, "the scripted opening dealt battle damage (got %d)" % _damage_dealt)


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
