class_name DuelHud
extends CanvasLayer

## What a duel in progress looks like to the person playing it: both life point totals, the turn
## number and whose turn it is, the current phase, and whatever the duel is asking for right now.
##
## Layer: L5 shell (AGENTS.md section 4). It reads `DuelState` and nothing else - no `KaibaCore`,
## no transport, no rules (V3) - and it never writes to the model.
##
## Three calls drive it, and nothing else does:
##
##     hud.bind(state)                              # once, when the duel starts
##     hud.refresh()                                # whenever the model may have moved
##     hud.set_prompt(selection.pending_prompt())   # whenever the pending selection changed
##
## ------------------------------------------------------------------------------------------
## Why nothing in this file measures the screen - ARCHITECTURE.md section 10, rule 4
## ------------------------------------------------------------------------------------------
## No widget may ask the viewport or the window how large it is in order to decide anything:
## not a layout, not a font size, not an "is this a phone" branch. Everything below is anchors,
## containers and size flags, and the project's `canvas_items` stretch mode does the scaling.
##
## The reason is VR, and honouring it costs nothing today. In Phase 7 this whole CanvasLayer is
## re-instantiated inside a `SubViewport` painted on a quad floating above the table. That
## viewport's pixel size is an arbitrary texture resolution picked for legibility at arm's
## length; it has no relation to any screen and no aspect ratio worth branching on. Code that
## sized itself from those numbers would be silently wrong there and would have to be rewritten
## - which is the rewrite rule 4 exists to prevent.
##
## So if this HUD ever looks wrong at some resolution, the fix is an anchor, a size flag or a
## container. Never a measurement. Please do not "fix" it by reading the screen dimensions.
##
## ------------------------------------------------------------------------------------------
## Rolling life points
## ------------------------------------------------------------------------------------------
## `DuelState` holds the current total and only that. What was on screen a moment ago is this
## HUD's business, so the previous value lives here and the label travels to the new one rather
## than snapping - a 2000 point hit should be visible as an event, not as a different number.

## Seconds a life point change takes to finish rolling. Long enough to read as a change, short
## enough that the HUD is never meaningfully behind the model.
const ROLL_SECONDS: float = 0.45

## Floor on the roll speed, in life points per second, so that a 100 point cost still ticks
## instead of resolving within a frame.
const MIN_ROLL_SPEED: float = 400.0

## Stand-in for a field there is no model to fill in yet.
const EMPTY: String = "-"

## Opacity of the seat that is not taking its turn.
const DIM_INACTIVE: float = 0.5

## `DuelEnums.PHASE` is a bit flag, never an ordinal, so this is a lookup and not an index.
## Phases the player never sees separately (the battle sub-steps) are still named, because a
## HUD that goes blank mid-battle reads as a bug.
const PHASE_NAMES: Dictionary = {
	DuelEnums.PHASE.DRAW: "Draw phase",
	DuelEnums.PHASE.STANDBY: "Standby phase",
	DuelEnums.PHASE.MAIN1: "Main phase 1",
	DuelEnums.PHASE.BATTLE_START: "Battle phase",
	DuelEnums.PHASE.BATTLE_STEP: "Battle step",
	DuelEnums.PHASE.DAMAGE: "Damage step",
	DuelEnums.PHASE.DAMAGE_CAL: "Damage calculation",
	DuelEnums.PHASE.BATTLE: "Battle phase",
	DuelEnums.PHASE.MAIN2: "Main phase 2",
	DuelEnums.PHASE.END: "End phase",
}

@onready var _top_panel: PanelContainer = $Root/Column/TopRow/TopSeat
@onready var _top_seat: Label = $Root/Column/TopRow/TopSeat/Box/Seat
@onready var _top_life: Label = $Root/Column/TopRow/TopSeat/Box/Life
@onready var _turn_label: Label = $Root/Column/TopRow/Turn/Box/Count
@onready var _phase_label: Label = $Root/Column/TopRow/Turn/Box/Phase
@onready var _bottom_panel: PanelContainer = $Root/Column/BottomRow/BottomSeat
@onready var _bottom_seat: Label = $Root/Column/BottomRow/BottomSeat/Box/Seat
@onready var _bottom_life: Label = $Root/Column/BottomRow/BottomSeat/Box/Life
@onready var _prompt_panel: PanelContainer = $Root/Column/BottomRow/Prompt
@onready var _prompt_label: Label = $Root/Column/BottomRow/Prompt/Text

## Which seat belongs to the person holding the device. `DuelState` does not know and should not
## - it is a board model, not a client - so it is configuration here. A hot seat duel leaves it
## at P0 and reads "You" for the bottom half of the board, which is where P0 sits.
var local_player: int = DuelEnums.PLAYER.P0:
	set(value):
		local_player = clampi(value, 0, DuelEnums.PLAYER_COUNT - 1)
		refresh()

var _state: DuelState = null
var _prompt: String = ""

## Life points as drawn, as the model has them, and how fast the first is chasing the second.
var _shown: Array[float] = [0.0, 0.0]
var _target: Array[int] = [0, 0]
var _speed: Array[float] = [0.0, 0.0]

## A fresh binding snaps instead of rolling: nobody wants to watch 8000 points count up from
## zero because the HUD was attached a frame late.
var _snap: bool = true


func _ready() -> void:
	set_process(false)
	refresh()
	_paint_prompt()


# ----------------------------------------------------------------------------------------------
# The whole public surface
# ----------------------------------------------------------------------------------------------

## Points the HUD at a duel. Passing `null` is legal and blanks it; that is what a HUD built
## before its duel exists should show.
func bind(state: DuelState) -> void:
	_state = state
	_snap = true
	refresh()


## Re-reads the model. Cheap enough to call every frame and idempotent, so a caller that cannot
## tell whether anything changed should just call it.
func refresh() -> void:
	if not is_node_ready():
		return
	_refresh_life()
	_refresh_turn()
	_refresh_phase()


## The pending prompt, verbatim from `SelectionController.pending_prompt()`. An empty string
## means nothing is being asked, and the prompt gets out of the way rather than showing a stale
## question.
func set_prompt(text: String) -> void:
	_prompt = text
	if not is_node_ready():
		return
	_paint_prompt()


## Finishes any running life point roll immediately. For a scene change, and for tests that
## would otherwise have to wait out an animation to read a number.
func settle() -> void:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		_shown[player] = float(_target[player])
	_paint_life()
	set_process(false)


# ----------------------------------------------------------------------------------------------
# Life points
# ----------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_advance_roll(delta)
	if not _is_rolling():
		set_process(false)


## Separated from `_process` so the roll can be stepped deterministically from a test.
func _advance_roll(delta: float) -> void:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		_shown[player] = move_toward(_shown[player], float(_target[player]), _speed[player] * delta)
	_paint_life()


func _is_rolling() -> bool:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		if absf(_shown[player] - float(_target[player])) >= 0.5:
			return true
	return false


func _refresh_life() -> void:
	_top_seat.text = _seat_name(_opponent())
	_bottom_seat.text = _seat_name(local_player)

	if _state == null:
		_top_life.text = EMPTY
		_bottom_life.text = EMPTY
		return

	for player: int in range(DuelEnums.PLAYER_COUNT):
		var value: int = _state.life_points[player]
		if _snap:
			_shown[player] = float(value)
			_speed[player] = 0.0
		elif value != _target[player]:
			_speed[player] = maxf(MIN_ROLL_SPEED, absf(float(value) - _shown[player]) / ROLL_SECONDS)
		_target[player] = value

	_snap = false
	_paint_life()
	set_process(_is_rolling())


func _paint_life() -> void:
	if _state == null:
		return
	_top_life.text = str(roundi(_shown[_opponent()]))
	_bottom_life.text = str(roundi(_shown[local_player]))


# ----------------------------------------------------------------------------------------------
# Turn and phase
# ----------------------------------------------------------------------------------------------

func _refresh_turn() -> void:
	if _state == null:
		_turn_label.text = EMPTY
		_top_panel.modulate.a = 1.0
		_bottom_panel.modulate.a = 1.0
		return

	if _state.is_finished:
		_turn_label.text = _result_text()
	elif _state.turn_count <= 0:
		# START has arrived but NEW_TURN has not: there is a first player, not yet a turn 1.
		_turn_label.text = "Duel start"
	else:
		_turn_label.text = "Turn %d - %s" % [_state.turn_count, _turn_owner_text()]

	var active: bool = not _state.is_finished
	_top_panel.modulate.a = 1.0 if (active and _state.turn_player == _opponent()) else DIM_INACTIVE
	_bottom_panel.modulate.a = 1.0 if (active and _state.turn_player == local_player) else DIM_INACTIVE


func _refresh_phase() -> void:
	if _state == null or _state.phase == 0:
		_phase_label.text = EMPTY
		return
	# Falls back to the enum name rather than going blank: an unmapped phase is a HUD gap, and a
	# raw `PHASE(128)` on screen says so out loud instead of hiding it (same spirit as V13).
	if PHASE_NAMES.has(_state.phase):
		_phase_label.text = PHASE_NAMES[_state.phase]
	else:
		_phase_label.text = DuelEnums.phase_name(_state.phase)


func _turn_owner_text() -> String:
	return "your turn" if _state.turn_player == local_player else "opponent's turn"


func _result_text() -> String:
	if _state.winner == DuelEnums.PLAYER.NONE:
		return "Duel over - draw"
	return "Duel over - you win" if _state.winner == local_player else "Duel over - you lose"


# ----------------------------------------------------------------------------------------------
# Prompt
# ----------------------------------------------------------------------------------------------

func _paint_prompt() -> void:
	_prompt_label.text = _prompt
	_prompt_panel.visible = not _prompt.is_empty()


# ----------------------------------------------------------------------------------------------
# Seats
# ----------------------------------------------------------------------------------------------

func _opponent() -> int:
	return 1 - local_player


func _seat_name(player: int) -> String:
	return "You" if player == local_player else "Opponent"
