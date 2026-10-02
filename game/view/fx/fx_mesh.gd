class_name FxMesh
extends RefCounted

## The two shapes every effect in `game/view/fx/` is built from, generated once and shared.
##
## Layer: L4 (AGENTS.md section 4). **V1: nothing here names `KaibaCore`, `MsgParser` or
## anything under `native/`.** **V6: metres, never screen space** - these meshes are authored at
## radius 1.0 and scaled into centimetres by the node that wears them.
##
## -------------------------------------------------------------------------------------------
## Why vertex colours instead of a texture
## -------------------------------------------------------------------------------------------
## There are no particle textures and no shaders in this project, and a flat additive quad with
## a hard square edge reads as a square, not as a glow. A radial falloff is therefore baked into
## the vertex colours: opaque at the centre of a disc, transparent at its rim, and a bright band
## between two transparent edges for a ring. With `vertex_color_use_as_albedo` the interpolator
## does the gradient for free, with no sampler, no texture memory and no shader compile.
##
## -------------------------------------------------------------------------------------------
## Cost
## -------------------------------------------------------------------------------------------
## One `ArrayMesh` each, for the whole process, built on first use:
##
##   disc   `DISC_SEGMENTS` triangles           (20 tris,  21 verts)
##   ring   `RING_SEGMENTS` * 4 triangles       (96 tris,  72 verts)
##
## For scale, ARCHITECTURE.md section 9 budgets 12k triangles per monster avatar and six avatars
## on screen. Every effect this file can produce, all at once, is under 1% of one avatar.

## Enough that a 10 cm disc has no visible facets on a phone, few enough that the mesh is
## negligible. 20 segments is an 18-degree step; at 10 cm radius the chord sags 0.4 mm.
const DISC_SEGMENTS: int = 20

const RING_SEGMENTS: int = 24

## Inner and outer edge of the ring, as a fraction of its radius. The band is 28% of the radius
## wide, which keeps a shockwave reading as a line rather than as a filled disc as it expands.
const RING_INNER: float = 0.86
const RING_OUTER: float = 1.14

static var _disc: ArrayMesh = null
static var _ring: ArrayMesh = null


## A unit-radius disc in local XY, normal along local +Z, opaque at the centre and transparent
## at the rim. Shared: never modify the returned mesh.
static func disc() -> ArrayMesh:
	if _disc == null:
		_disc = _build_disc()
	return _disc


## A unit-radius ring in local XY, normal along local +Z, transparent at both edges and opaque
## along the middle of the band. Shared: never modify the returned mesh.
static func ring() -> ArrayMesh:
	if _ring == null:
		_ring = _build_ring()
	return _ring


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

static func _build_disc() -> ArrayMesh:
	var vertices: PackedVector3Array = PackedVector3Array()
	var colours: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	vertices.append(Vector3.ZERO)
	colours.append(Color(1.0, 1.0, 1.0, 1.0))
	for step: int in range(DISC_SEGMENTS):
		var angle: float = TAU * float(step) / float(DISC_SEGMENTS)
		vertices.append(Vector3(cos(angle), sin(angle), 0.0))
		colours.append(Color(1.0, 1.0, 1.0, 0.0))

	for step: int in range(DISC_SEGMENTS):
		indices.append(0)
		indices.append(1 + step)
		indices.append(1 + (step + 1) % DISC_SEGMENTS)

	return _surface(vertices, colours, indices)


static func _build_ring() -> ArrayMesh:
	var vertices: PackedVector3Array = PackedVector3Array()
	var colours: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	# Three concentric loops: transparent, opaque, transparent. Written loop-major so the index
	# arithmetic below is a plain stride.
	var radii: Array[float] = [RING_INNER, 1.0, RING_OUTER]
	var alphas: Array[float] = [0.0, 1.0, 0.0]
	for loop: int in range(radii.size()):
		for step: int in range(RING_SEGMENTS):
			var angle: float = TAU * float(step) / float(RING_SEGMENTS)
			vertices.append(Vector3(cos(angle) * radii[loop], sin(angle) * radii[loop], 0.0))
			colours.append(Color(1.0, 1.0, 1.0, alphas[loop]))

	for band: int in range(radii.size() - 1):
		var inner: int = band * RING_SEGMENTS
		var outer: int = (band + 1) * RING_SEGMENTS
		for step: int in range(RING_SEGMENTS):
			var next: int = (step + 1) % RING_SEGMENTS
			indices.append(inner + step)
			indices.append(outer + step)
			indices.append(outer + next)
			indices.append(inner + step)
			indices.append(outer + next)
			indices.append(inner + next)

	return _surface(vertices, colours, indices)


## No normals and no UVs on purpose: every material that wears these is unshaded and untextured,
## so both would be dead weight in the vertex buffer.
static func _surface(
	vertices: PackedVector3Array,
	colours: PackedColorArray,
	indices: PackedInt32Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
