class_name TouchSource
extends InputSource

## The phone input source. Android first (AGENTS.md section 2), so this is the one that has to
## be right.
##
## Layer: L5. It decides **when** to pick and nothing else; `InputSource` owns the raycast and
## the `InputIntent` shapes. See that file's header for the vocabulary and for why no intent may
## ever carry a screen coordinate.
##
## -------------------------------------------------------------------------------------------
## Gestures
## -------------------------------------------------------------------------------------------
##   tap                 SELECT_CARD / SELECT_ZONE at the lifted finger
##   long press >500 ms  POINT_AT, and the following lift is swallowed
##   two-finger tap      CANCEL
##
## A drag past `TAP_SLOP` pixels is not a tap: it cancels both the tap and the pending long
## press. That is a camera gesture a later rig will want, and letting it fall through as a tap
## would mean every attempt to look at the board played a card.
##
## -------------------------------------------------------------------------------------------
## Why a Timer and not `_process`
## -------------------------------------------------------------------------------------------
## The long press needs elapsed time, and the obvious way to get it is to remember where the
## finger went down and compare clocks every frame. That is polling a raw pointer position
## outside `_input`, which is the habit ARCHITECTURE.md section 10 rule 5 exists to prevent -
## once a position is readable per-frame, something eventually reads it to make a decision. A
## one-shot `Timer` started on touch-down and stopped on lift gives the same gesture with no
## per-frame position anywhere.
##
## `TAP_SLOP` is the one screen-space number in this file, and it stays here: it describes a
## finger, not the board. An `XRSource` will have a slop measured in centimetres instead, and
## nothing downstream will notice.

## Press longer than this and the gesture becomes a preview instead of a selection.
const LONG_PRESS_SECONDS: float = 0.5

## How far a finger may travel and still count as a tap, in pixels. A touch screen reports a
## few pixels of wander on any real finger.
const TAP_SLOP: float = 24.0

## Fingers currently down: touch index -> starting position.
var _touches: Dictionary = {}

## Where the gesture started. Only meaningful while exactly one finger is down.
var _origin: Vector2 = Vector2.ZERO

## Set once a second finger joins, so the lift resolves as CANCEL instead of as two taps. Stays
## set until every finger is off the glass.
var _multi_touch: bool = false

## Set by a drag past the slop, or by the long press firing. Either way the lift must not also
## select.
var _consumed: bool = false

var _long_press: Timer = null


func _ready() -> void:
	_long_press = Timer.new()
	_long_press.name = "LongPress"
	_long_press.one_shot = true
	_long_press.wait_time = LONG_PRESS_SECONDS
	_long_press.timeout.connect(_on_long_press)
	add_child(_long_press)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_origin = event.position
			_consumed = false
			_multi_touch = false
			_long_press.start()
		else:
			# A second finger means this was never a tap. Stop the preview from firing under it.
			_multi_touch = true
			_long_press.stop()
		return

	_touches.erase(event.index)
	_long_press.stop()

	# Resolve only when the last finger leaves, so a two-finger tap is one gesture rather than
	# two independent lifts.
	if not _touches.is_empty():
		return

	if _multi_touch:
		_multi_touch = false
		_consumed = false
		cancel()
		return

	if _consumed:
		_consumed = false
		return

	if event.position.distance_to(_origin) <= TAP_SLOP:
		select_at(event.position)


func _on_drag(event: InputEventScreenDrag) -> void:
	if _touches.has(event.index):
		_touches[event.index] = event.position
	if _multi_touch or _consumed:
		return
	if event.position.distance_to(_origin) > TAP_SLOP:
		# Past the slop this is a drag, not a press. Whatever a later rig does with it, it is
		# not a selection.
		_consumed = true
		_long_press.stop()


func _on_long_press() -> void:
	if _multi_touch or _touches.size() != 1:
		return
	_consumed = true
	point_at(_origin)
