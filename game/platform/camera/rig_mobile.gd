class_name RigMobile
extends CameraRig

## The phone rig: the default camera for the MVP (AGENTS.md section 2 - Android first).
##
## Layer: L5. It is a `CameraRig` with different numbers and nothing else. That is the whole
## point of ARCHITECTURE.md section 10 rule 2: swapping `RigMobile` for `RigPC` or `RigVR` is a
## change of script on one node, because a rig is only ever a set of constants plus whatever
## owns the transform.
##
## The numbers are tuned for a phone held in landscape, and they are metres, not screen
## fractions. Nothing here measures the window (rule 4):
##
##   distance 0.92 m    far enough that the 1.20 m table fits across a 16:9 frame at this fov,
##                      close enough that a 59 mm card is still readable.
##   elevation 52 deg   steeper than a seated human. A phone is read nearly flat-on, and a
##                      shallower angle turns the far player's row into slivers.
##   focus z +0.02      biased a hair towards the near player, so their hand and their spell
##                      row are the part of the board that is dead centre.
##   fov 52 deg         vertical. Wider than that and the table bows at the corners on a
##                      phone's short focal length.

const MOBILE_DISTANCE: float = 0.92
const MOBILE_ELEVATION: float = 52.0
const MOBILE_FOCUS: Vector3 = Vector3(0.0, 0.0, 0.02)
const MOBILE_FIELD_OF_VIEW: float = 52.0


func _init() -> void:
	# Assigned in `_init` rather than as export defaults so a `.tscn` that overrides one of them
	# still wins: scene property values are applied after the object is constructed.
	distance = MOBILE_DISTANCE
	elevation = MOBILE_ELEVATION
	focus = MOBILE_FOCUS
	field_of_view = MOBILE_FIELD_OF_VIEW


# ---------------------------------------------------------------------------------------------
# Dynamic framing
#
# A phone screen is small, so the camera earns its keep by leaning toward whatever just happened
# and then returning. Every move is a tween on the same exported properties the static rig uses,
# so there is exactly one place that turns numbers into a transform.
#
# Kept deliberately gentle. The reference is Master Duel, which nudges; a camera that swoops on
# every summon is exhausting by turn three and unreadable on a 6-inch screen.
# ---------------------------------------------------------------------------------------------

## How far the rig may drift from its resting focus, in metres. Past this the far half of the
## board starts leaving the frame on a 16:9 phone.
const MAX_DRIFT: float = 0.11

## Pulled in by this much while leaning. Enough to read the card that is acting.
const CLOSE_IN: float = 0.07

const LEAN_TIME: float = 0.35
const SETTLE_TIME: float = 0.55

var _move: Tween = null


func cue(kind: String, world_position: Vector3) -> void:
	match kind:
		CUE_SETTLE:
			_tween_to(MOBILE_FOCUS, MOBILE_DISTANCE, SETTLE_TIME)
		CUE_SUMMON, CUE_ATTACK, CUE_DAMAGE:
			# Only the horizontal part: lifting the focus would tilt the table out of frame.
			var toward := Vector3(world_position.x, MOBILE_FOCUS.y, world_position.z)
			var offset := toward - MOBILE_FOCUS
			if offset.length() > MAX_DRIFT:
				offset = offset.normalized() * MAX_DRIFT
			_tween_to(MOBILE_FOCUS + offset, MOBILE_DISTANCE - CLOSE_IN, LEAN_TIME)
		_:
			pass


## One tween at a time. A second cue arriving mid-move retargets rather than stacking, so a
## chain of five effects does not queue five camera moves to play out after the chain is over.
func _tween_to(target_focus: Vector3, target_distance: float, seconds: float) -> void:
	if _move != null and _move.is_valid():
		_move.kill()
	if not is_inside_tree():
		focus = target_focus
		distance = target_distance
		return
	_move = create_tween()
	_move.set_parallel(true)
	_move.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_move.tween_property(self, "focus", target_focus, seconds)
	_move.tween_property(self, "distance", target_distance, seconds)
