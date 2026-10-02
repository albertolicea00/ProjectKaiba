class_name ShardBurst
extends FxEffect

## A monster coming apart: a one-shot spray of small bright shards thrown out of a zone.
##
## Layer: L4. **V6: metres** - the emission box is sized in card widths and the velocities are
## in metres per second, because a 2 m/s shard on a 1.20 m table leaves the board in half a
## second.
##
## -------------------------------------------------------------------------------------------
## CPU particles, not GPU
## -------------------------------------------------------------------------------------------
## `GPUParticles3D` needs a `ParticleProcessMaterial`, which compiles a shader the first time it
## is seen. ARCHITECTURE.md section 9's rule for the avatar pool - never `load()` mid-animation -
## is the same rule: a shader compile inside the frame a monster is destroyed is a visible hitch
## on a mid-range phone. `CPUParticles3D` costs a loop over `SHARD_COUNT` floats per frame and
## draws as one instanced batch.
##
## -------------------------------------------------------------------------------------------
## What it costs
## -------------------------------------------------------------------------------------------
## `SHARD_COUNT` boxes of 12 triangles each - 168 triangles - as a single `MultiMesh` draw, plus
## 14 particles of CPU integration per frame. ARCHITECTURE.md section 9 budgets 12k triangles
## per avatar and six avatars; one burst is 1.4% of one of them.

## Few enough to be free, many enough to read as debris rather than as confetti. A destroyed
## monster is on screen for well under a second, so detail past this is not perceived.
const SHARD_COUNT: int = 14

## A shard is roughly a sixth of a card, and flat, because it is a piece of one.
const SHARD_SIZE: Vector3 = Vector3(0.009, 0.013, 0.0008)

## Thrown out of a volume the size of the card that just broke.
const EMISSION_EXTENTS: Vector3 = Vector3(0.028, 0.004, 0.040)

## Metres per second. At the upper bound a shard covers 16 cm in the 0.45 s it lives, which puts
## it clear of the zone and nowhere near the next player's half.
const SPEED_MIN: float = 0.16
const SPEED_MAX: float = 0.42

## Deliberately a quarter of real gravity. Shards that fall at 9.8 m/s² on a table this size are
## gone before the eye registers them; this lets the spray hang long enough to be read.
const FALL: float = 2.4

var _particles: CPUParticles3D = null


## Points the burst at a zone. `seat` is `BoardView.anchor_transform()`; the shards are thrown
## along world up regardless, because a card lying flat breaks upwards whichever way its zone
## is turned.
func seat_at(seat: Transform3D, colour: Color, seconds: float) -> void:
	global_position = seat.origin
	# Identity basis, not the seat's: `direction` and `gravity` below are world-space, and
	# inheriting the anchor's rotation would fire player 1's shards into the table.
	global_basis = Basis.IDENTITY
	_particles.lifetime = maxf(seconds, 0.05)
	_particles.color = colour


func _prepare() -> void:
	var shard: BoxMesh = BoxMesh.new()
	shard.size = SHARD_SIZE

	var material: StandardMaterial3D = FxEffect.glow_material(Color.WHITE)
	# `color_ramp` arrives as a per-instance colour, which a `StandardMaterial3D` only reads
	# when it is told to treat vertex colour as albedo. Without this the ramp - and therefore
	# the fade - does nothing at all.
	material.vertex_color_use_as_albedo = true

	_particles = CPUParticles3D.new()
	_particles.name = "Shards"
	_particles.mesh = shard
	_particles.material_override = material
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.amount = SHARD_COUNT
	_particles.one_shot = true
	# Every shard leaves in the same frame: a monster does not disintegrate gradually, it is
	# destroyed at one instant and the pieces travel from there.
	_particles.explosiveness = 1.0
	_particles.emitting = false
	# World space, so the shards keep flying along their own paths if the node is moved.
	_particles.local_coords = false

	_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_particles.emission_box_extents = EMISSION_EXTENTS
	_particles.direction = Vector3.UP
	_particles.spread = 55.0
	_particles.initial_velocity_min = SPEED_MIN
	_particles.initial_velocity_max = SPEED_MAX
	_particles.gravity = Vector3(0.0, -FALL, 0.0)
	_particles.angular_velocity_min = -220.0
	_particles.angular_velocity_max = 220.0
	_particles.scale_amount_min = 0.7
	_particles.scale_amount_max = 1.3
	_particles.scale_amount_curve = _shrink_curve()
	_particles.color_ramp = _fade_ramp()
	add_child(_particles)


## Shards are born at full size and are gone by the end, so the spray does not stop - it
## dissolves.
func _shrink_curve() -> Curve:
	var curve: Curve = Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.65, 0.6))
	curve.add_point(Vector2(1.0, 0.0))
	return curve


func _fade_ramp() -> Gradient:
	var ramp: Gradient = Gradient.new()
	ramp.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	ramp.add_point(0.25, Color(1.0, 1.0, 1.0, 0.85))
	return ramp


## The burst is fired once, at t = 0, and then simply lives out `lifetime`. There is nothing to
## interpolate: `CPUParticles3D` integrates its own particles.
func _advance(t: float) -> void:
	if t <= 0.0 and not _particles.emitting:
		_particles.restart()


## The reason this class exists as something more than a node: a particle system left emitting
## after `skip_all()` is exactly the leak the director's contract forbids.
func _silence() -> void:
	_particles.emitting = false
	visible = false
