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
