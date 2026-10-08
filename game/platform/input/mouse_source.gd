class_name MouseSource
extends InputSource

## The desktop input source. Second priority after Android (AGENTS.md section 2), and the one
## that gets used while developing, which is most of why it exists.
##
## Layer: L5. It decides **when** to pick and nothing else; `InputSource` owns the raycast and
## the `InputIntent` shapes.
##
## -------------------------------------------------------------------------------------------
## Bindings (EDOPro-style)
## -------------------------------------------------------------------------------------------
##   hover               POINT_AT - side panel preview, updates as the mouse moves
##   left click           SELECT_CARD / SELECT_ZONE - "play this card" / "choose this zone"
##   middle click         SELECT_ALT - "set this card"
##   Shift + left click   SELECT_ALT, the discoverable alias
##   right click          CANCEL
##   Enter / Space        CONFIRM
##   Escape               CANCEL


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
			if event.shift_pressed:
				select_alt_at(event.position)
			else:
				select_at(event.position)
		MOUSE_BUTTON_MIDDLE:
			select_alt_at(event.position)
		MOUSE_BUTTON_RIGHT:
			cancel()


func _on_motion(event: InputEventMouseMotion) -> void:
	point_at_if_changed(event.position)


func _on_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			confirm()
		KEY_ESCAPE:
			cancel()
