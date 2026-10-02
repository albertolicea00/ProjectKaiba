class_name CardView
extends Node3D

## One card on the table, at real-world scale.
##
## Layer: L4 (AGENTS.md section 4). Reads nothing. It is told what to be - a `card_id`, a face
## and a position - and it never asks anybody anything. **V1: this file must never name
## `KaibaCore`, `MsgParser` or anything under `native/`.**
##
## -------------------------------------------------------------------------------------------
## Scale
## -------------------------------------------------------------------------------------------
## A Yu-Gi-Oh! card is 59 mm x 86 mm. Those millimetres are Godot units here, because
## ARCHITECTURE.md section 10 rule 1 says the board is built at real-world scale from day one:
## a VR port that has to rescale the art is a full art redo. Do not "round up to something
## easier to work with".
##
## -------------------------------------------------------------------------------------------
## Orientation
## -------------------------------------------------------------------------------------------
## The card's own frame has the quad in local XY with the face normal along local +Z, the card's
## top edge along local +Y. Lying the card flat on the table is **not** this node's job: the
## zone anchor carries that part of the rotation (`BoardView` rotates every anchor so its local
## +Z points at the sky). This node contributes only the two rotations that belong to the card
## itself:
##
##   defense    90 degrees about local Z - the card turns sideways in its zone.
##   face-down  180 degrees about local Y - the card flips over, back side up.
##
## Composed as `R_z(defense) * R_y(face_down)`, so the Y flip happens first in the card's own
## frame and the Z turn after it. Getting that order backwards puts a face-down defense card's
## long edge along the wrong axis.
##
## The caller multiplies: `global_basis = anchor_basis * orientation()`.
##
## -------------------------------------------------------------------------------------------
## Art
## -------------------------------------------------------------------------------------------
## No artwork yet - `data/base/pics/` exists but wiring textures is Phase 4 work. A face-up card
## is a flat colour derived from its `card_id`; a face-down card shows the shared back colour.
## `_front_colour()` is the stand-in for `VisualRegistry.resolve()` (ARCHITECTURE.md section 9):
## **the visual is resolved from `card_id` at the moment of use and never stored anywhere below
## this layer** (V11, V12). Replacing it with a real texture lookup touches this function and
## nothing else.
##
## -------------------------------------------------------------------------------------------
## Picking
## -------------------------------------------------------------------------------------------
## The two quads have no collider, so nothing can be aimed at them. This node carries one
## `Area3D` holding a box the size of the card plus a margin, purely as a raycast target for
## `InputSource._pick()`.
##
## Two rules make it safe:
##
##   - It sits alone on `PICK_LAYER`. A pick ray masked to that layer cannot hit the table, the
##     felt, or anything a later phase puts in the world - only cards.
##   - Its layer follows `visible`, so a card parked in the `CardPool` is not pickable. A pooled
##     card still exists, still has a transform and would still answer a ray; a tap resolving to
##     a card that is not on the board is the kind of bug that only shows up as a silent
##     `MSG_RETRY` three selections later.
##
## This node still reads nothing and decides nothing (V1): it is a target, and whoever fires the
## ray is the one that owns the meaning of the hit.

## Card face, in metres. 59 mm x 86 mm. See the Scale note above.
const CARD_WIDTH: float = 0.059
const CARD_HEIGHT: float = 0.086

## Collision layer the pick volume lives on, and nothing else. Bit 1 (layer 2 in the inspector)
## leaves layer 1 free for whatever physics the world grows later; a pick query masks to exactly
## this value so it can never pick up a stray collider.
const PICK_LAYER: int = 1 << 1

## Grown around the card on every side so a fingertip that lands just past the edge still counts
## as a hit. 8 mm is roughly the gutter between two zones, so neighbouring cards still cannot
## overlap each other's volume.
const PICK_MARGIN: float = 0.008

## Thickness of the pick volume. Far larger than the card so a ray arriving at a grazing angle
## still passes through it, small enough that a card lying flat cannot be hit through the table.
const PICK_DEPTH: float = 0.006

## Separation between the front and back quads. A real card is about 0.3 mm; this is only here
## to keep the two faces out of each other's depth buffer.
const CARD_THICKNESS: float = 0.0004

## Reverse side. The classic brown/orange back, not a placeholder magenta: a face-down card is a
## normal game state and should not read as an error.
const BACK_COLOUR: Color = Color(0.42, 0.26, 0.14)

## A card whose `card_id` is 0 - face-down, or simply not revealed to this viewer. Not an error
## (see `EventTranslator`'s note on `card_id`), so it gets a neutral grey rather than a warning.
const UNKNOWN_COLOUR: Color = Color(0.55, 0.55, 0.58)

## Passcode of the card currently shown. `0` means "not revealed to this viewer".
## Stable identity of the card this view is currently showing, minted by `DuelState` and
## carried on the intent. `0` means "not bound to a model card".
##
## This is what makes one card followable: `card_id` cannot do it, because two copies in a
## hand share it and a face-down card reports 0.
var handle: int = 0

var card_id: int = 0

## False means the back is up.
var face_up: bool = false

## True means defense position: the card is turned 90 degrees in its zone.
var defense: bool = false

## The only face that ever changes. The back is the same for every card in the game, so it is
## built once and never touched again.
var _front_material: StandardMaterial3D = null

## The raycast target. See the Picking note above.
var _pick_area: Area3D = null

## One `QuadMesh` shared by every card ever created. Built once, on the first card; after that
## a `CardPool` can hand out hundreds of cards without allocating any geometry, which is half of
## why the pool can promise never to `load()` mid-animation.
static var _shared_mesh: QuadMesh = null

## One `BoxShape3D` shared by every card, for the same reason as the mesh.
static var _shared_pick_shape: BoxShape3D = null


func _init() -> void:
	_build()
	# `CardPool` acquires and releases cards by toggling `visible`, and it is not this node's
	# business to know that. Following the signal instead means any owner that hides a card
	# gets the collider turned off for free.
	visibility_changed.connect(_refresh_pickable)


func _ready() -> void:
	_refresh_pickable()


## The two rotations a card owns, in the card's own frame. Multiply an anchor's basis by this to
## get the card's world basis. See the Orientation note above for why the order is fixed.
func orientation() -> Basis:
	var turn: Basis = Basis.from_euler(Vector3(0.0, 0.0, (PI * 0.5) if defense else 0.0))
	var flip: Basis = Basis.from_euler(Vector3(0.0, 0.0 if face_up else PI, 0.0))
	return turn * flip


## Sets both orientation flags at once. It does not move the node: composing them with the
## anchor basis is the caller's business, which is what lets a tween interpolate towards the
## result instead of snapping to it.
func set_orientation(is_face_up: bool, is_defense: bool) -> void:
	face_up = is_face_up
	defense = is_defense


## Swaps which card this view shows. Cheap: it only re-tints a material. Called at the moment of
## use, never cached below L4 (V11).
func set_card_id(value: int) -> void:
	card_id = value
	_front_material.albedo_color = _front_colour()


func describe() -> String:
	return "card %d %s%s" % [
		card_id,
		"up" if face_up else "down",
		" def" if defense else "",
	]


## True while a pick ray can hit this card. False for a card parked in the pool.
func is_pickable() -> bool:
	return _pick_area != null and _pick_area.collision_layer != 0


## The `Area3D` a pick ray reports as the collider. `InputSource` walks back up from it to this
## node; nothing else should need it.
func pick_area() -> Area3D:
	return _pick_area


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## Stand-in for `VisualRegistry.resolve()` (ARCHITECTURE.md section 9). Deterministic so the same
## card is the same colour in every duel and in every replay of it, and spread over the hue
## circle by the golden ratio so two cards drawn together rarely collide.
func _front_colour() -> Color:
	if card_id == 0:
		return UNKNOWN_COLOUR
	var hue: float = fposmod(float(card_id) * 0.6180339887498949, 1.0)
	return Color.from_hsv(hue, 0.45, 0.88)


func _build() -> void:
	if _shared_mesh == null:
		_shared_mesh = QuadMesh.new()
		_shared_mesh.size = Vector2(CARD_WIDTH, CARD_HEIGHT)

	_front_material = _make_material(_front_colour())

	var front: MeshInstance3D = MeshInstance3D.new()
	front.name = "Front"
	front.mesh = _shared_mesh
	front.material_override = _front_material
	front.position = Vector3(0.0, 0.0, CARD_THICKNESS * 0.5)
	add_child(front)

	# Turned to face local -Z, so flipping the card 180 degrees about Y is what brings it up.
	var back: MeshInstance3D = MeshInstance3D.new()
	back.name = "Back"
	back.mesh = _shared_mesh
	back.material_override = _make_material(BACK_COLOUR)
	back.position = Vector3(0.0, 0.0, -CARD_THICKNESS * 0.5)
	back.rotation = Vector3(0.0, PI, 0.0)
	add_child(back)

	_build_pick_volume()


## The box a pick ray hits. It lives in the card's own frame - local XY is the face, local Z the
## thickness - so a defense card's volume turns with it and a face-down card's with it too,
## without this function knowing either rotation exists.
func _build_pick_volume() -> void:
	if _shared_pick_shape == null:
		_shared_pick_shape = BoxShape3D.new()
		_shared_pick_shape.size = Vector3(
			CARD_WIDTH + PICK_MARGIN * 2.0,
			CARD_HEIGHT + PICK_MARGIN * 2.0,
			PICK_DEPTH)

	var shape := CollisionShape3D.new()
	shape.name = "PickShape"
	shape.shape = _shared_pick_shape

	_pick_area = Area3D.new()
	_pick_area.name = "PickArea"
	# It is a target, never a sensor: it reports nothing, detects nothing and costs no overlap
	# bookkeeping. Only `intersect_ray` ever asks it anything.
	_pick_area.monitoring = false
	_pick_area.monitorable = false
	_pick_area.collision_mask = 0
	_pick_area.collision_layer = PICK_LAYER
	_pick_area.add_child(shape)
	add_child(_pick_area)


## Layer `PICK_LAYER` while the card is on the board, layer 0 - which no query can match - while
## it is parked. Driven by `visibility_changed`, so the pool never has to know this exists.
func _refresh_pickable() -> void:
	if _pick_area == null:
		return
	var on_board: bool = visible and (not is_inside_tree() or is_visible_in_tree())
	_pick_area.collision_layer = PICK_LAYER if on_board else 0


## Unshaded on purpose. The board has one directional light and no art yet; shading flat colours
## would only make neighbouring zones harder to tell apart.
func _make_material(colour: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material
