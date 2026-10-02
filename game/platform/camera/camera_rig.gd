class_name CameraRig
extends Node3D

## The camera slot. One of these, and never a bare `Camera3D`, is what a duel scene contains.
##
## Layer: L5 (AGENTS.md section 4). **V1: nothing here names `KaibaCore`, `MsgParser` or
## anything under `native/`.** **V6: no screen-space anywhere.**
##
## -------------------------------------------------------------------------------------------
## Why the scene holds a rig and not a camera (ARCHITECTURE.md section 10 rule 2)
## -------------------------------------------------------------------------------------------
## `RigVR` will be an `XROrigin3D` with an `XRCamera3D` under it, and the headset - not this
## code - will own the transform. If a duel scene contained a `Camera3D` node directly, the VR
## port would have to surgically remove it from a saved scene and rewire everything that
## referenced it. A rig is a swappable child: `duel_3d.tscn` holds a node, the subclass decides
## what a camera is.
##
## So this base class **creates** its `Camera3D` in code. Nothing is saved into a `.tscn`, which
## is what makes the swap a one-line change of script.
##
## -------------------------------------------------------------------------------------------
## No auto-framing, on purpose
## -------------------------------------------------------------------------------------------
## The obvious convenience here would be "fit the board to the screen", and it is exactly what
## ARCHITECTURE.md section 10 rule 4 forbids: a widget that reads `get_viewport().size` to make
## a decision does not survive the move to VR, where there is no viewport size in that sense.
## Each rig carries fixed, tuned numbers in metres instead. A phone rig and a PC rig differ by
## their constants, not by a runtime measurement of the window.

## Point on the table the camera looks at, in rig-local metres. Slightly towards the near player
## because their own board is what they are reading most of the time.
@export var focus: Vector3 = Vector3(0.0, 0.0, 0.05):
	set(value):
		focus = value
		_apply()

## Eye distance from `focus`, in metres. A real person reading a card at this table is roughly
## this far from it.
@export var distance: float = 0.95:
	set(value):
		distance = maxf(0.05, value)
		_apply()

## Angle above the table plane. 90 is straight down, 0 is table level.
@export var elevation: float = 46.0:
	set(value):
		elevation = clampf(value, 5.0, 89.0)
		_apply()

## Which seat the camera sits behind. Player 1's view is the same rig rotated half a turn about
## the table centre, which is the same mirror `BoardView` uses for the far half of the board.
@export var seat: int = 0:
	set(value):
		seat = clampi(value, 0, 1)
		_apply()

@export var field_of_view: float = 50.0:
	set(value):
		field_of_view = clampf(value, 10.0, 120.0)
		_apply()

## A card is 0.3 mm thick and the whole board is 1.2 m across, so Godot's 0.05 m default near
## plane would clip the front row. Everything here is centimetres; the frustum has to be too.
const NEAR_PLANE: float = 0.01
const FAR_PLANE: float = 20.0

var _camera: Camera3D = null


func _ready() -> void:
	_ensure_camera()
	_apply()


## The camera this rig owns. `RigVR` will return its `XRCamera3D` from here and nothing that
## calls this has to care.
func camera() -> Camera3D:
	_ensure_camera()
	return _camera


## Makes this rig's camera the active one. Called by the duel scene rather than relying on
## `current = true` being saved in a `.tscn` that is not supposed to contain a camera at all.
func activate() -> void:
	_ensure_camera()
	_camera.current = true


func _ensure_camera() -> void:
	if _camera != null:
		return
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.near = NEAR_PLANE
	_camera.far = FAR_PLANE
	add_child(_camera)


## Places the eye on a circle around `focus` at `elevation` degrees, looking back at it. Virtual
## so a rig that does not own its transform - `RigVR` - can make this a no-op.
## Cue kinds a rig may choose to react to. Advisory only - see `cue()`.
const CUE_SUMMON: String = "SUMMON"
const CUE_ATTACK: String = "ATTACK"
const CUE_DAMAGE: String = "DAMAGE"
const CUE_SETTLE: String = "SETTLE"


## Tells the rig that something interesting is happening at a point on the table.
##
## **This is a suggestion, not an instruction, and the distinction is load-bearing.** The base
## rig ignores every cue and holds still. `RigMobile` leans toward the action. `RigVR` must keep
## ignoring them: moving a camera that a person's head is not moving is the textbook way to
## induce motion sickness, so the one thing a VR rig may never do is accept a framing command
## from the game.
##
## That is why `AnimationDirector` emits cues rather than calling `look_at` on a camera. The
## director knows a monster was summoned; only the rig knows whether moving is safe.
func cue(_kind: String, _world_position: Vector3) -> void:
	pass


func _apply() -> void:
	if _camera == null:
		return
	var angle: float = deg_to_rad(elevation)
	var behind: float = cos(angle) * distance
	var above: float = sin(angle) * distance
	# Player 0 sits at +Z; player 1 is the same seat rotated half a turn about the table centre.
	var side: float = 1.0 if seat == 0 else -1.0
	var eye: Vector3 = Vector3(0.0, above, behind * side) + Vector3(focus.x * side, focus.y, focus.z * side)

	_camera.fov = field_of_view
	_camera.transform = Transform3D(Basis.IDENTITY, eye).looking_at(
		Vector3(focus.x * side, focus.y, focus.z * side), Vector3.UP)
