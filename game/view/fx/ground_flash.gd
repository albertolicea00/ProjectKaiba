class_name GroundFlash
extends FxEffect

## A disc of light that blooms on the table under a zone and fades.
##
## Layer: L4. **V6: metres.** The caller hands in the zone's own `Transform3D`, whose local +Z
## already points at the sky (`BoardView`'s anchor convention), so the disc lies flat without
## this class knowing which way up the table is.
##
## -------------------------------------------------------------------------------------------
## What it costs
## -------------------------------------------------------------------------------------------
## One `MeshInstance3D` wearing the shared `FxMesh.disc()` - 20 triangles - and one additive
## unshaded material. No texture, no shader, no particle system. Two of these can be on screen
## at once in the worst case the MVP can produce (a summon landing while a battle resolves).

## Radius the disc reaches, in metres. A monster zone is 59 mm wide and the column pitch is
## 72 mm, so 7 cm spills just past the card and just short of its neighbours - which is what
## makes it read as *this* zone lighting up rather than as the row lighting up.
const DEFAULT_RADIUS: float = 0.070

## Radius it starts at, as a fraction of the final one. Starting from nothing reads as a dot
## expanding; starting from most of the way reads as a flash, which is what this is.
const START_FRACTION: float = 0.55

## Height above the table top. The cards themselves float at `BoardView.CARD_LIFT` (1.2 mm), so
## this sits just under them: the glow belongs to the felt, not to the card standing on it.
const SURFACE_LIFT: float = 0.0006

var radius: float = DEFAULT_RADIUS

var _quad: MeshInstance3D = null
var _material: StandardMaterial3D = null


## Puts the disc flat on a zone. `seat` is `BoardView.anchor_transform()` for that zone.
func seat_at(seat: Transform3D, disc_radius: float, colour: Color) -> void:
	radius = disc_radius
	_material.albedo_color = colour
	# Local +Z is up at every anchor, so "just above the felt" is a local-Z offset.
	global_transform = seat.translated_local(Vector3(0.0, 0.0, SURFACE_LIFT))


func _prepare() -> void:
	_material = FxEffect.glow_material(Color(1.0, 0.88, 0.55))
	_quad = MeshInstance3D.new()
	_quad.name = "Disc"
	_quad.mesh = FxMesh.disc()
	_quad.material_override = _material
	# Nothing casts or receives shadows from a glow, and a mobile renderer charges for both.
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)
	_advance(0.0)


## Grows a little and fades a lot. The alpha curve is quadratic so most of the brightness is
## spent in the first third - a linear fade reads as a light being dimmed rather than as an
## impact.
func _advance(t: float) -> void:
	var u: float = clampf(t, 0.0, 1.0)
	var scale: float = radius * lerpf(START_FRACTION, 1.0, u)
	_quad.scale = Vector3(scale, scale, 1.0)
	var fade: float = (1.0 - u) * (1.0 - u)
	var colour: Color = _material.albedo_color
	colour.a = fade
	_material.albedo_color = colour
