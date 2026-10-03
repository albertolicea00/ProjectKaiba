class_name HotSeatBanner
extends CanvasLayer

## The overlay that makes a hot-seat duel readable: which seat the board is being shown from,
## how far through the turn the engine is, and who it is waiting on.
##
## Layer: L5 shell. It reads a `DuelState` and a `SeatFocus` and nothing else - no core, no
## transport, no rules (V1, V3) - and it never writes to either.
##
## Three calls drive it, and nothing else does:
##
##     banner.bind(state, focus)   # once, when the duel starts
##     banner.refresh()            # whenever the model or the focus may have moved
##     banner.announce(text)       # a turn change in progress; "" hands the banner back
##
## It sits alongside `DuelHud` rather than inside it. `DuelHud` is the duel's HUD and is what a
## networked client will show, where there is exactly one local seat and none of this applies.
## Everything here is specific to one person playing both halves, so it is a separate layer
## that the solo test scene adds and a real duel does not.
##
## ------------------------------------------------------------------------------------------
## Why nothing in this file measures the screen - ARCHITECTURE.md section 10, rule 4
## ------------------------------------------------------------------------------------------
## Same rule as `ui/hud/duel_hud.gd`, same reason: in Phase 7 this layer is re-instantiated in
## a `SubViewport` on a quad above the table, whose pixel size is a legibility choice and not a
## screen. Anchors, containers and size flags only. If it looks wrong somewhere, the fix is a
## size flag, never a measurement.

## Seat colours. Two hues that stay distinguishable for the common colour-vision deficiencies
## (amber against blue, not red against green), because this colour is load-bearing: it is the
## thing the eye catches before any text is read.
const SEAT_COLOURS: Array[Color] = [
	Color(0.98, 0.69, 0.28),
	Color(0.44, 0.70, 1.00),
]

## Alpha of the seat-coloured frame drawn around the whole view. Strong enough to be read
## peripherally, weak enough not to compete with the board.
const EDGE_ALPHA: float = 0.85

## Thickness of that frame, in the HUD's own units. A constant, not a fraction of anything
## measured.
const EDGE_WIDTH: int = 7

## What the seat line reads before a duel is bound. Never an empty string, for the same reason
## the phase readout is never blank: a widget that goes quiet reads as a broken one.
const NO_DUEL: String = "no duel bound"

@onready var _edge: Panel = $Edge
@onready var _seat_chip: PanelContainer = $Root/Column/TopBand/SeatChip
@onready var _seat_caption: Label = $Root/Column/TopBand/SeatChip/Box/Caption
@onready var _seat_value: Label = $Root/Column/TopBand/SeatChip/Box/Value
@onready var _decision_chip: PanelContainer = $Root/Column/TopBand/DecisionChip
@onready var _decision_value: Label = $Root/Column/TopBand/DecisionChip/Box/Value
@onready var _decision_detail: Label = $Root/Column/TopBand/DecisionChip/Box/Detail
@onready var _track: Label = $Root/Column/PhaseBand/PhasePanel/Box/Track
@onready var _step: Label = $Root/Column/PhaseBand/PhasePanel/Box/Step
@onready var _banner: PanelContainer = $Root/Column/BottomBand/Banner
@onready var _banner_title: Label = $Root/Column/BottomBand/Banner/Box/Title
@onready var _banner_detail: Label = $Root/Column/BottomBand/Banner/Box/Detail

var _state: DuelState = null
var _focus: SeatFocus = null

## Set by `announce()`. While it is non-empty it owns the banner, because a seat flip in
## progress is more urgent than any prompt that could be pending behind it.
var _announcement: String = ""


func _ready() -> void:
	refresh()


# ----------------------------------------------------------------------------------------------
# The whole public surface
# ----------------------------------------------------------------------------------------------

## Points the overlay at a duel. Both arguments may be `null`, which blanks it rather than
## crashing - that is what an overlay built before its duel exists should show.
func bind(state: DuelState, focus: SeatFocus) -> void:
	_state = state
	_focus = focus
	refresh()


## Re-reads the model and the focus. Idempotent and cheap enough to call every frame.
func refresh() -> void:
	if not is_node_ready():
		return
	_paint_seat()
	_paint_phase()
	_paint_decision()
	_paint_banner()


## Takes over the banner with a transition message - "Turn 3: the board is flipping to Player
## 2". Passing `""` hands the banner back to whatever prompt is pending.
func announce(text: String) -> void:
	_announcement = text
	if not is_node_ready():
		return
	_paint_banner()


## The colour this overlay is painting the frame, for a caller that wants to match something to
## it. Derived from the seat in view; there is deliberately no setter.
func seat_colour() -> Color:
	var seat: int = _focus.seat_in_view if _focus != null else DuelEnums.PLAYER.P0
	return SEAT_COLOURS[clampi(seat, 0, SEAT_COLOURS.size() - 1)]


# ----------------------------------------------------------------------------------------------
# Painting
# ----------------------------------------------------------------------------------------------

## The seat in view, stated twice over: in words on the chip, and as a frame around the entire
## view in that seat's colour. Twice on purpose - the words are what you read when you look,
## the frame is what tells you without looking that the side changed under you.
func _paint_seat() -> void:
	var colour: Color = seat_colour()

	var frame: StyleBoxFlat = _edge.get_theme_stylebox("panel") as StyleBoxFlat
	if frame != null:
		frame.border_color = Color(colour.r, colour.g, colour.b, EDGE_ALPHA)
		frame.set_border_width_all(EDGE_WIDTH)

	var chip: StyleBoxFlat = _seat_chip.get_theme_stylebox("panel") as StyleBoxFlat
	if chip != null:
		chip.border_color = Color(colour.r, colour.g, colour.b, EDGE_ALPHA)

	_seat_value.add_theme_color_override("font_color", colour)
	_seat_value.text = _focus.view_text() if _focus != null else NO_DUEL
	_seat_caption.text = "Board shown from"


## The phase strip and the exact step. Two lines because they answer different questions: the
## strip is "how far through the turn are we", the step is "what is the engine actually in".
func _paint_phase() -> void:
	var phase: int = _state.phase if _state != null else 0
	_track.text = SeatFocus.track_text(phase)
	_step.text = SeatFocus.phase_name(phase)


## Whose decision it is. Driven by the pending event's `player` field through `SeatFocus`, and
## tinted with that seat's colour so "who" is answered before the sentence is read.
func _paint_decision() -> void:
	if _focus == null or not _focus.is_waiting():
		_decision_chip.visible = false
		return

	_decision_chip.visible = true
	var colour: Color = SEAT_COLOURS[clampi(_focus.decision_seat, 0, SEAT_COLOURS.size() - 1)]
	_decision_value.add_theme_color_override("font_color", colour)
	_decision_value.text = _focus.decision_text()
	_decision_detail.text = _focus.decision_prompt


## The banner. An announcement wins; otherwise it appears only for a prompt belonging to the
## seat that is not in view, which is the one case where the screen alone would mislead.
func _paint_banner() -> void:
	if not _announcement.is_empty():
		_banner.visible = true
		_banner_title.text = _announcement
		_banner_detail.text = ""
		return

	if _focus == null or not _focus.is_asking_offscreen():
		_banner.visible = false
		_banner_title.text = ""
		_banner_detail.text = ""
		return

	var colour: Color = SEAT_COLOURS[clampi(_focus.decision_seat, 0, SEAT_COLOURS.size() - 1)]
	var box: StyleBoxFlat = _banner.get_theme_stylebox("panel") as StyleBoxFlat
	if box != null:
		box.border_color = Color(colour.r, colour.g, colour.b, EDGE_ALPHA)
	_banner_title.add_theme_color_override("font_color", colour)

	_banner.visible = true
	_banner_title.text = _focus.banner_title()
	_banner_detail.text = _focus.banner_detail()
