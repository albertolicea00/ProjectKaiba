class_name MouseSource
extends InputSource

## The desktop input source. Second priority after Android (AGENTS.md section 2), and the one
## that gets used while developing, which is most of why it exists.
##
## Layer: L5. It decides **when** to pick and nothing else; `InputSource` owns the raycast and
## the `InputIntent` shapes.
##
## -------------------------------------------------------------------------------------------
## Bindings
## -------------------------------------------------------------------------------------------
##   left click           POINT_AT (preview) when released quickly
##   left hold >500 ms    SELECT_CARD / SELECT_ZONE - "play this card"
##   middle click         SELECT_ALT - "set this card"
##   Shift + left click   SELECT_ALT, the discoverable alias
##   right click          CANCEL
##   Enter / Space        CONFIRM
##   Escape               CANCEL
##
## Hover no longer previews. Preview is triggered by a quick left click, matching the
## touch model where a tap shows the card up close. The deliberate action of playing
## goes through a held click, which during an idle or battle command triggers the action
## menu at the scene level.

## How long a click must be held before it becomes a select rather than a preview.
const LONG_PRESS_SECONDS: float = 0.4

## Pixels the cursor must travel while held before the gesture is treated as a camera
## drag rather than a click or a hold.
const CLICK_SLOP: float = 8.0

var _left_down: bool = false
var _left_origin: Vector2 = Vector2.ZERO
var _left_consumed: bool = false
var _long_press: Timer = null


func _ready() -> void:
	_long_press = Timer.new()
	_long_press.name = "LongPress"
	_long_press.one_shot = true
	_long_press.wait_time = LONG_PRESS_SECONDS
	_long_press.timeout.connect(_on_long_press)
	add_child(_long_press)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_on_key(event as InputEventKey)


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

func _on_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_left_down = true
				_left_origin = event.position
				_left_consumed = false
				if event.shift_pressed:
					_left_consumed = true
					_long_press.stop()
					select_alt_at(event.position)
				else:
					_long_press.start()
			else:
				_long_press.stop()
				var consumed: bool = _left_consumed
				_left_down = false
				_left_consumed = false
				if consumed:
					return
				if event.position.distance_to(_left_origin) <= CLICK_SLOP:
					point_at(event.position)
		MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				select_alt_at(event.position)
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				cancel()


func _on_motion(event: InputEventMouseMotion) -> void:
	if _left_down and not _left_consumed:
		if event.position.distance_to(_left_origin) > CLICK_SLOP:
			_left_consumed = true
			_long_press.stop()


func _on_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			confirm()
		KEY_ESCAPE:
			cancel()


func _on_long_press() -> void:
	if not _left_down or _left_consumed:
		return
	_left_consumed = true
	select_at(_left_origin)
