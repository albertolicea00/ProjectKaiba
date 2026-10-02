class_name ImpactRing
extends FxEffect

## A shockwave: a bright ring that expands across the felt and thins out.
##
## Layer: L4. **V6: metres.** Like `GroundFlash` it is seated with a `BoardView` anchor
## transform, whose local +Z is already up.
##
## -------------------------------------------------------------------------------------------
## Why a ring and not a bigger flash
## -------------------------------------------------------------------------------------------
## A disc says "something is here". A ring says "something happened here, now" - the expansion
## carries the timing, which is the whole job of an impact effect. They are used together: the
## flash is the hit, the ring is the consequence travelling outwards.
##
## -------------------------------------------------------------------------------------------
## What it costs
## -------------------------------------------------------------------------------------------
## One `MeshInstance3D` wearing the shared `FxMesh.ring()` - 96 triangles - and one additive
## unshaded material. The expansion is a node scale, so the mesh is never rebuilt.

## Where a shockwave starts and stops, in metres. A card is 59 mm x 86 mm, so a ring that ends
## at 13 cm has travelled a card and a half out of the zone: clearly past it, nowhere near the
## 1.20 m table edge.
const DEFAULT_START_RADIUS: float = 0.022
const DEFAULT_END_RADIUS: float = 0.130

## Same reasoning as `GroundFlash.SURFACE_LIFT`, a hair higher so the two do not z-fight when
## an impact spawns both at the same zone.
const SURFACE_LIFT: float = 0.0009

## Expansion is eased out hard: a shockwave is fastest at the instant it is born.
const EXPANSION_POWER: float = 0.45

var start_radius: float = DEFAULT_START_RADIUS
var end_radius: float = DEFAULT_END_RADIUS

var _ring: MeshInstance3D = null
var _material: StandardMaterial3D = null


func seat_at(seat: Transform3D, from_radius: float, to_radius: float, colour: Color) -> void:
	start_radius = from_radius
	end_radius = to_radius
	_material.albedo_color = colour
	global_transform = seat.translated_local(Vector3(0.0, 0.0, SURFACE_LIFT))


func _prepare() -> void:
	_material = FxEffect.glow_material(Color(0.95, 0.80, 0.40))
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.mesh = FxMesh.ring()
	_ring.material_override = _material
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	_advance(0.0)


func _advance(t: float) -> void:
	var u: float = clampf(t, 0.0, 1.0)
	var spread: float = pow(u, EXPANSION_POWER)
	var scale: float = lerpf(start_radius, end_radius, spread)
	_ring.scale = Vector3(scale, scale, 1.0)
	# Fades linearly against an expansion that is not linear, so the ring is already most of
	# the way out while it is still bright and spends its last third barely visible.
	var colour: Color = _material.albedo_color
	colour.a = 1.0 - u
	_material.albedo_color = colour
