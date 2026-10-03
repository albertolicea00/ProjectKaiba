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
##   left click           SELECT_CARD / SELECT_ZONE
##   middle click         SELECT_ALT - "set this card"
##   Shift + left click   SELECT_ALT, the discoverable alias
##   right click          CANCEL
##   move                 POINT_AT, but only when the thing under the cursor actually changed
##   Enter / Space        CONFIRM
##   Escape               CANCEL
##
## Two bindings for one verb on purpose. Middle click is the fast one and the one a player
## keeps; Shift + click is the one they can be *told*, and the one that still works on a
## trackpad, which has no middle button at all. Neither is a mode: both are a single click that
## resolves immediately, so nothing on screen has to change to advertise which one is armed.
##
## The two keys are not decoration. A mouse has no gesture that means "yes, that is my whole
## answer", and several selections - `MSG_SELECT_YESNO`, a multi-card `MSG_SELECT_CARD` - cannot
## be answered without one. See the note in `core/duel/selection_controller.gd` on what the
## vocabulary still cannot express.
##
## -------------------------------------------------------------------------------------------
## Hover
## -------------------------------------------------------------------------------------------
## Emitting `POINT_AT` on every motion event would be a few hundred intents a second, each one
## waking whatever a HUD does with a preview. So a move only re-picks after `HOVER_SLOP` pixels,
## and only emits when the pick resolved to something different from last time. The filter is on
## the *result* rather than on a timer: what a consumer cares about is "the cursor is now over a
## different card", and that is exactly what this reports.

## Pixels the cursor must travel before the hover is recomputed.
const HOVER_SLOP: float = 4.0

var _last_hover_position: Vector2 = Vector2(-INF, -INF)


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
	if not event.pressed:
		return
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			# Shift is read here rather than tracked as state: a modifier that is remembered
			# between events is a mode, and a mode that is invisible is a trap.
			if event.shift_pressed:
				select_alt_at(event.position)
			else:
				select_at(event.position)
		MOUSE_BUTTON_MIDDLE:
			select_alt_at(event.position)
		MOUSE_BUTTON_RIGHT:
			cancel()


func _on_motion(event: InputEventMouseMotion) -> void:
	if event.position.distance_to(_last_hover_position) < HOVER_SLOP:
		return
	_last_hover_position = event.position
	point_at_if_changed(event.position)


func _on_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			confirm()
		KEY_ESCAPE:
			cancel()
