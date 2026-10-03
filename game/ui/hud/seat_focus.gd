class_name SeatFocus
extends RefCounted

## Which seat a hot-seat duel is being *shown* from, and which seat the engine is *asking*.
## They are two different questions and conflating them is what makes a hot-seat duel
## unplayable.
##
## Layer: L5 shell. Pure data: no scene tree, no core, no rules (V1, V3). It is fed the same
## Level-1 `DuelEvent` dictionaries `DuelState.apply()` gets and the pending selection the
## scene parks on `SelectionController`, and it answers three questions:
##
##     focus.seat_in_view        which seat the camera and the HUD belong to
##     focus.decision_seat       which seat the engine is waiting on, or NOBODY
##     focus.is_asking_offscreen()   whether those two disagree
##
## -------------------------------------------------------------------------------------------
## The rule: flip on turn change, never on a prompt
## -------------------------------------------------------------------------------------------
## The tempting implementation is "point the camera at whoever is being asked". It does not
## survive contact with a real duel. The non-turn player is handed priority constantly - every
## `MSG_SELECT_CHAIN` after every action - so a camera driven by `decision_seat` would swing
## twice per summon and settle never.
##
## So `observe()` moves the view on `NEW_TURN` and on nothing else. A prompt for the seat that
## is not in view is announced instead: the player reads the far half of the board upside down
## for one decision, which is strictly better than a camera that is always in motion.
##
## This is the same rule the animation layer already follows. `CameraRig.cue()` is advisory
## because a VR rig must be free to ignore every framing command; a mode whose legibility
## depended on continuous camera movement could not be ported to VR at all.

## `decision_seat` when nothing is pending. Not `PLAYER.NONE`, which is a real ocgcore value
## meaning "a draw", and would read as a seat here.
const NOBODY: int = -1

## Seat names. Player ids stay absolute all the way up from ocgcore, so these are positions at
## the table and never "you" / "them" - in a hot seat duel both seats are the same person and
## "You" on both halves of the screen is exactly the confusion this mode exists to remove.
const SEAT_NAMES: Array[String] = ["Player 1", "Player 2"]

## Every `DuelEnums.PHASE` bit, named. A lookup and never an index: `PHASE` is a bit flag, so
## `PHASE_NAMES[state.phase]` is the only correct access and `PHASE_NAMES.values()[n]` is a bug.
##
## The five battle values are named as the steps they are, rather than all collapsing to
## "Battle phase", because the battle step is where a hot-seat player most needs to know what
## the engine is waiting for. `PHASE_BATTLE` (0x80) is the battle phase's End Step: ocgcore
## assigns `infos.phase = PHASE_BATTLE` only after the last battle step has resolved
## (`native/vendor/ocgcore/processor.cpp:2755`, and again at :1807).
const PHASE_NAMES: Dictionary = {
	DuelEnums.PHASE.DRAW: "Draw phase",
	DuelEnums.PHASE.STANDBY: "Standby phase",
	DuelEnums.PHASE.MAIN1: "Main phase 1",
	DuelEnums.PHASE.BATTLE_START: "Battle phase - start step",
	DuelEnums.PHASE.BATTLE_STEP: "Battle phase - battle step",
	DuelEnums.PHASE.DAMAGE: "Battle phase - damage step",
	DuelEnums.PHASE.DAMAGE_CAL: "Battle phase - damage calculation",
	DuelEnums.PHASE.BATTLE: "Battle phase - end step",
	DuelEnums.PHASE.MAIN2: "Main phase 2",
	DuelEnums.PHASE.END: "End phase",
}

## What shows before `NEW_PHASE` has ever arrived. Never an empty string: a readout that goes
## blank reads as a broken HUD, and this mode is for finding real bugs.
const PHASE_UNSTARTED: String = "Not started"

## The six stages a player actually thinks in, in order, each with the phase bits that belong
## to it. The whole battle phase is one stage on the strip; which step inside it is live is the
## separate line `phase_name()` produces.
const TRACK: Array[Dictionary] = [
	{"label": "Draw", "bits": DuelEnums.PHASE.DRAW},
	{"label": "Standby", "bits": DuelEnums.PHASE.STANDBY},
	{"label": "Main 1", "bits": DuelEnums.PHASE.MAIN1},
	{"label": "Battle", "bits": (
		DuelEnums.PHASE.BATTLE_START | DuelEnums.PHASE.BATTLE_STEP | DuelEnums.PHASE.DAMAGE
		| DuelEnums.PHASE.DAMAGE_CAL | DuelEnums.PHASE.BATTLE)},
	{"label": "Main 2", "bits": DuelEnums.PHASE.MAIN2},
	{"label": "End", "bits": DuelEnums.PHASE.END},
]

## Separator between stages on the strip. The live stage is additionally bracketed and
## upper-cased, so the readout survives being read as plain text in a log.
const TRACK_JOIN: String = "  >  "

# ----------------------------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------------------------

## The seat the camera and the HUD belong to. Changed only by `observe()` seeing a `NEW_TURN`.
var seat_in_view: int = DuelEnums.PLAYER.P0

## The turn player as last announced. Tracked here as well as in `DuelState` so this object can
## be reasoned about - and tested - without a model behind it.
var turn_player: int = DuelEnums.PLAYER.P0

## The seat the engine is waiting on, or `NOBODY`. Taken from the pending event's `player`
## field, which is the only authority on who is being asked.
var decision_seat: int = NOBODY

## The pending selection's event type, and the prompt `SelectionController` wrote for it.
var decision_event: int = 0
var decision_prompt: String = ""

## How many times the view has changed seats. A hot-seat duel that never flips and one that
## flips on every chain prompt look identical from a single frame; this is what a headless run
## can assert on.
var flips: int = 0

## Set once the duel has been won. The overlay exists to say whose decision is next, and after
## a win there is no next: leaving the line reading "taking this turn" states something false
## about a duel that is over. `DuelHud` reports *what happened*; this reports *what to do*, and
## the honest answer becomes "nothing".
var finished: bool = false

## Set when ocgcore turned the last answer down and the same selection has been put back.
##
## Worth saying out loud rather than silently re-asking: from the player's side a rejected tap
## and an ignored tap look identical, and "nothing happened" is the single most confusing thing
## an interface can do.
var rejected: bool = false


# ----------------------------------------------------------------------------------------------
# The event stream
# ----------------------------------------------------------------------------------------------

## Feeds one Level-1 event in. Returns `true` when the seat in view has just changed, which is
## the caller's cue to run its transition - this object never animates anything.
##
## Only `START` and `NEW_TURN` can move the view. Everything else, selections included, is
## observed for the readout and changes nothing about where the camera is.
func observe(event: Dictionary) -> bool:
	match int(event.get("t", -1)):
		DuelEnums.EV.START:
			turn_player = _seat(event.get("first", DuelEnums.PLAYER.P0))
			return _look_at(turn_player)
		DuelEnums.EV.NEW_TURN:
			turn_player = _seat(event.get("player", DuelEnums.PLAYER.P0))
			return _look_at(turn_player)
		DuelEnums.EV.WIN:
			# No seat flip. Moving the board at the moment the duel ends would read as another
			# turn starting, which is the opposite of what just happened.
			finished = true
			clear_pending()
	return false


## Records the selection the duel is now waiting on. `prompt` is
## `SelectionController.pending_prompt()` verbatim - this object does not write prompts, it
## only says whose they are.
## Records that the engine refused the last answer. Cleared by the next accepted one.
func note_rejected() -> void:
	rejected = true


func set_pending(event: Dictionary, prompt: String) -> void:
	decision_event = int(event.get("t", 0))
	decision_seat = _seat(event.get("player", DuelEnums.PLAYER.P0))
	decision_prompt = prompt


func clear_pending() -> void:
	rejected = false
	decision_event = 0
	decision_seat = NOBODY
	decision_prompt = ""


func is_waiting() -> bool:
	return decision_seat != NOBODY


## The case the banner exists for: somebody is being asked, and it is not the half of the board
## the camera is behind.
func is_asking_offscreen() -> bool:
	return is_waiting() and decision_seat != seat_in_view


# ----------------------------------------------------------------------------------------------
# Text
# ----------------------------------------------------------------------------------------------

static func seat_name(player: int) -> String:
	if player < 0 or player >= SEAT_NAMES.size():
		return "Nobody"
	return SEAT_NAMES[player]


## Name of a phase bit. Falls back to `DuelEnums.phase_name()` rather than to an empty string,
## so a phase this table has not been taught shows up as `PHASE(512)` on screen instead of
## silently blanking the readout (the spirit of V13).
static func phase_name(phase: int) -> String:
	if phase == 0:
		return PHASE_UNSTARTED
	if PHASE_NAMES.has(phase):
		return str(PHASE_NAMES[phase])
	return DuelEnums.phase_name(phase)


## The whole flow on one line with the live stage bracketed:
##   `draw  >  standby  >  [MAIN 1]  >  battle  >  main 2  >  end`
static func track_text(phase: int) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for stage: Dictionary in TRACK:
		var label: String = str(stage["label"])
		if phase != 0 and (phase & int(stage["bits"])) != 0:
			parts.append("[%s]" % label.to_upper())
		else:
			parts.append(label.to_lower())
	return TRACK_JOIN.join(parts)


## The line that must be legible at a glance at all times. Says which seat the board is being
## shown from and whether that seat is the one taking its turn, because acting for the wrong
## side is the single most common hot-seat mistake.
func view_text() -> String:
	if finished:
		return "%s - the duel is over" % seat_name(seat_in_view).to_upper()
	var role: String = "taking this turn" if seat_in_view == turn_player else "waiting"
	return "%s - %s" % [seat_name(seat_in_view).to_upper(), role]


## Who is being asked, for the persistent indicator. Driven by the pending event's `player`
## field and by nothing else.
func decision_text() -> String:
	if finished:
		return "the duel is over"
	if rejected and is_waiting():
		return "%s - that answer was refused, choose again" % seat_name(decision_seat).to_upper()
	if not is_waiting():
		return "nobody is being asked"
	return "%s must decide" % seat_name(decision_seat).to_upper()


## Title of the banner raised for a prompt belonging to the seat that is not in view.
func banner_title() -> String:
	if not is_asking_offscreen():
		return ""
	return "%s IS BEING ASKED" % seat_name(decision_seat).to_upper()


## The rest of that banner: what is being asked, and the reminder that the camera deliberately
## did not move for it.
func banner_detail() -> String:
	if not is_asking_offscreen():
		return ""
	var what: String = decision_prompt
	if what.is_empty():
		what = "Waiting on %s" % DuelEnums.ev_name(decision_event)
	return "%s\nThe board is still shown from %s - answer on the far half." % [
		what, seat_name(seat_in_view)]


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

func _look_at(player: int) -> bool:
	if player == seat_in_view:
		return false
	seat_in_view = player
	flips += 1
	return true


## A seat is 0 or 1. `PLAYER.NONE` and `PLAYER.ALL` are real ocgcore values that can reach a
## `player` field; neither is a chair, so they are clamped rather than shown.
func _seat(value: Variant) -> int:
	return clampi(int(value), 0, DuelEnums.PLAYER_COUNT - 1)
