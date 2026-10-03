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
##   short drag down     SELECT_ALT on the card the drag started on - "set this"
##   long press >500 ms  POINT_AT, and the following lift is swallowed
##   two-finger tap      CANCEL
##
## A drag past `TAP_SLOP` pixels is not a tap: it cancels both the tap and the pending long
## press. That is a camera gesture a later rig will want, and letting it fall through as a tap
## would mean every attempt to look at the board played a card.
##
## -------------------------------------------------------------------------------------------
## Why a downward drag is the set gesture
## -------------------------------------------------------------------------------------------
## The obvious alternative is a double tap, and it is the wrong one: a double tap makes **every
## ordinary tap** wait out the double-tap window to find out whether it was single. Summoning a
## monster is the most common thing a player does in this game, and it would acquire a delay in
## order to pay for the second most common. A drag costs a tap nothing - the decision is made
## from geometry the finger has already produced by the time it lifts.
##
## Downward, specifically, because the metaphor is laying the card flat on the table, and
## because it is the one direction nothing else wants: a drag up out of the hand is how a
## future "drag a card onto a zone" would read, and sideways is a camera pan.
##
## The gesture is judged once, at the lift, from the release position against `_origin`. Judging
## it continuously would let a finger arm and disarm it on the way down, which is a gesture the
## player cannot see and therefore cannot aim.
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

## How far down a finger must travel for the gesture to mean "set this card", in pixels.
##
## Three times `TAP_SLOP`. The lower bound is the slop itself - anything at or under it is
## indistinguishable from the wander a real finger puts on a tap - and one multiple of clearance
## above it would make a slightly sloppy tap into a face-down monster, which is a mistake the
## player cannot undo and may not even notice until the card is flipped. The upper bound is the
## card: at the board distance the rig uses, a hand card is roughly 150 px tall, so 72 px is
## about half a card and still reads as a flick rather than a haul. It is deliberately a
## different *order* of movement from a tap, not a slightly bigger one.
const SET_DRAG_DISTANCE: float = 72.0

## How much more vertical than horizontal the drag has to be. 2:1 is a cone of about 27 degrees
## either side of straight down - loose enough for a thumb, which arcs, and tight enough that a
## diagonal camera swipe is not a set.
const SET_DRAG_RATIO: float = 2.0

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

## Set once the long press has fired. Distinct from `_consumed` because a preview has already
## answered the gesture, so the lift must do nothing at all - not even read as a set drag.
var _previewed: bool = false

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
			_previewed = false
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
		_previewed = false
		cancel()
		return

	var previewed: bool = _previewed
	var consumed: bool = _consumed
	_previewed = false
	_consumed = false

	# The preview already answered this gesture.
	if previewed:
		return

	# Checked before `consumed`, because a set drag is exactly the kind of drag that sets it.
	if is_set_drag(_origin, event.position):
		select_alt_at(_origin)
		return

	if consumed:
		return

	if event.position.distance_to(_origin) <= TAP_SLOP:
		select_at(event.position)


## Does the movement from `origin` to `release` read as "set this card"?
##
## Static and public so the suite can assert the gesture's shape without synthesising touch
## events through the whole tree, and so the one definition of the gesture is the one that runs.
static func is_set_drag(origin: Vector2, release: Vector2) -> bool:
	var delta: Vector2 = release - origin
	# Screen y grows downwards, so "down" is positive.
	if delta.y < SET_DRAG_DISTANCE:
		return false
	return absf(delta.y) >= SET_DRAG_RATIO * absf(delta.x)


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
	_previewed = true
	point_at(_origin)
