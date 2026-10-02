class_name CardFlight
extends RefCounted

## One card's motion between two transforms, as a pure function of `t` in [0, 1].
##
## Layer: L4 (AGENTS.md section 4). **V1: nothing here names `KaibaCore`, `MsgParser` or anything
## under `native/`.** **V6: metres, never screen space.**
##
## -------------------------------------------------------------------------------------------
## Why this is not a `tween_property` on `global_transform`
## -------------------------------------------------------------------------------------------
## A `Tween` interpolating a `Transform3D` interpolates the basis **component by component**.
## That is fine for a translation and wrong for a rotation: halfway through a 180-degree turn
## the two bases cancel and the card collapses to a sliver before popping back out. Every card
## that flips - a summon arriving face-up, a set going face-down, a flip summon, a position
## change - goes through exactly that rotation, which is why the old "slide from A to B" look
## was the only one that ever worked.
##
## So the rotation is a quaternion slerp and the position is interpolated separately, and the
## whole pose is written by `apply()` from a `tween_method`.
##
## -------------------------------------------------------------------------------------------
## The one invariant
## -------------------------------------------------------------------------------------------
## **`pose(1.0)` is `to`, bit for bit**, for any flight that does not deliberately end somewhere
## else (`spin`, `end_scale`). Not "within a millimetre" - exactly, with no accumulated float
## drift from a sine that is 1.2e-16 instead of 0 at t = 1.
##
## That is what lets `AnimationDirector` ask `BoardView` for a card's resting transform, fly the
## card away from it and know that the card lands back on it. An attacker that returns to "very
## nearly" its zone is an attacker that has drifted a hair out of its zone after six turns.
##
## -------------------------------------------------------------------------------------------
## The shape controls
## -------------------------------------------------------------------------------------------
##   `bulge`      a world-space displacement added as `bulge * sin(PI * t)`: zero at both ends,
##                full at the middle. A travel arc, a landing rebound and a recoil overshoot are
##                all the same thing pointed in different directions.
##   `swell`      how much wider the card is at t = 0, decaying quadratically. This is the
##                impact squash: a card lying flat has no visible thickness, so the only squash
##                that reads is one in the plane of the card.
##   `spin`       extra rotation about the card's own normal, accumulated linearly. Destruction
##                only.
##   `end_scale`  uniform scale at t = 1. Destruction only.
##   `fade_from` / `fade_to`   card opacity, written through `CardView.set_opacity()`.

## The card this flight drives. `apply()` writes to it; `pose()` never touches it.
var view: CardView = null

var from: Transform3D = Transform3D.IDENTITY:
	set(value):
		from = value
		_from_turn = value.basis.get_rotation_quaternion()

var to: Transform3D = Transform3D.IDENTITY:
	set(value):
		to = value
		_to_turn = value.basis.get_rotation_quaternion()

var bulge: Vector3 = Vector3.ZERO
var swell: float = 0.0
var spin: float = 0.0
var end_scale: float = 1.0
var fade_from: float = 1.0
var fade_to: float = 1.0

var _from_turn: Quaternion = Quaternion.IDENTITY
var _to_turn: Quaternion = Quaternion.IDENTITY


## The usual case: fly this card from here to there.
static func between(card: CardView, start: Transform3D, finish: Transform3D) -> CardFlight:
	var flight: CardFlight = CardFlight.new()
	flight.view = card
	flight.from = start
	flight.to = finish
	return flight


## A flight that goes nowhere, used for a settle: the card is already home and only the `bulge`
## and `swell` shapes play out before it returns to exactly where it started.
static func settling(card: CardView, home: Transform3D) -> CardFlight:
	return CardFlight.between(card, home, home)


func pose(t: float) -> Transform3D:
	var u: float = clampf(t, 0.0, 1.0)
	if u >= 1.0 and spin == 0.0 and end_scale == 1.0:
		# Exact rather than merely close. See the invariant note above.
		return to

	var origin: Vector3 = from.origin.lerp(to.origin, u)
	if bulge != Vector3.ZERO:
		origin += bulge * sin(PI * u)

	var basis: Basis = Basis(_from_turn.slerp(_to_turn, u))
	if spin != 0.0:
		# About the card's own normal - local +Z is the face direction (`CardView`'s frame), so
		# this is the card turning in its own plane rather than tumbling.
		basis = basis.rotated(basis.z.normalized(), spin * u)

	var size: float = lerpf(1.0, end_scale, u)
	var squash: float = swell * (1.0 - u) * (1.0 - u)
	if size != 1.0 or squash != 0.0:
		basis = basis.scaled_local(Vector3(size + squash, size + squash, size))

	return Transform3D(basis, origin)


## Poses the card. This is what a `tween_method` calls, sixty times a second.
func apply(t: float) -> void:
	if view == null:
		return
	view.global_transform = pose(t)
	if fade_from != fade_to:
		view.set_opacity(lerpf(fade_from, fade_to, clampf(t, 0.0, 1.0)))
