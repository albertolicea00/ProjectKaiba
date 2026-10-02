class_name FxLayer
extends Node3D

## Owns every live `FxEffect` and guarantees that none of them outlives the beat that asked for
## it.
##
## Layer: L4 (AGENTS.md section 4). **V1: nothing here names `KaibaCore`, `MsgParser` or anything
## under `native/`.** **V6: no screen-space coordinates** - effects are seated with `BoardView`
## anchor transforms, in metres.
##
## -------------------------------------------------------------------------------------------
## Why effects are not children of the cards they decorate
## -------------------------------------------------------------------------------------------
## Same reason `CardPool` keeps every `CardView` parented to itself: a card that is flying from
## a hand to a graveyard has no sensible parent while it is in the air, and reparenting changes
## the meaning of a transform a `Tween` is already interpolating. An effect is seated in world
## space once and stays there; the card it belongs to is free to move, or to be recycled, or to
## be destroyed, without the effect noticing.
##
## -------------------------------------------------------------------------------------------
## Lifetime
## -------------------------------------------------------------------------------------------
## Exactly one path out, for both the natural end and the skipped one: the effect emits
## `finished`, this node takes it out of the tree and frees it. `clear()` is `skip_all()`'s
## counterpart - it stops everything on the spot, which is what makes "a skipped animation must
## not leave a particle system running" true by construction rather than by discipline.
##
## `live_count()` exists so a headless self-check can assert that, because a leaked effect has
## no other symptom until the frame budget is gone.

## Hard stop on concurrent effects. The director never asks for more than a handful - a summon
## landing is two, a battle is four - so hitting this means something is spawning in a loop.
## A dropped effect is a cosmetic loss; an unbounded one is a dead phone.
const MAX_LIVE: int = 24

var _live: Array[FxEffect] = []
var _warned_full: bool = false


## A disc of light blooming on the table under a zone.
func flash(seat: Transform3D, radius: float, colour: Color, seconds: float) -> GroundFlash:
	var effect: GroundFlash = GroundFlash.new()
	if not _adopt(effect, seconds):
		return null
	effect.seat_at(seat, radius, colour)
	effect.play(seconds)
	return effect


## A shockwave expanding across the felt from a zone.
func ring(
	seat: Transform3D,
	from_radius: float,
	to_radius: float,
	colour: Color,
	seconds: float) -> ImpactRing:
	var effect: ImpactRing = ImpactRing.new()
	if not _adopt(effect, seconds):
		return null
	effect.seat_at(seat, from_radius, to_radius, colour)
	effect.play(seconds)
	return effect


## A one-shot spray of debris out of a zone.
func shards(seat: Transform3D, colour: Color, seconds: float) -> ShardBurst:
	var effect: ShardBurst = ShardBurst.new()
	if not _adopt(effect, seconds):
		return null
	effect.seat_at(seat, colour, seconds)
	effect.play(seconds)
	return effect


## Ends everything on the spot. `AnimationDirector.skip_all()` calls this; so does a drain, so a
## stray effect can never survive into the next beat.
func clear() -> void:
	# A copy, because `stop()` emits `finished`, which mutates `_live` from under the loop.
	var snapshot: Array[FxEffect] = _live.duplicate()
	for effect: FxEffect in snapshot:
		if is_instance_valid(effect):
			effect.stop()
	_live.clear()


## How many effects are still playing. Zero while the board is at rest.
func live_count() -> int:
	return _live.size()


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## Puts a freshly built effect into the tree and into the live list, or refuses it.
func _adopt(effect: FxEffect, seconds: float) -> bool:
	if _live.size() >= MAX_LIVE:
		if not _warned_full:
			_warned_full = true
			push_warning(
				"[FxLayer] %d effects already live; dropping new ones. " % MAX_LIVE
				+ "Something is spawning an effect per frame.")
		effect.free()
		return false
	if seconds <= 0.0:
		# Nothing to see and nothing to clean up afterwards. Refusing here rather than adding
		# and immediately retiring keeps the zero-duration path free of a tree round trip.
		effect.free()
		return false
	_live.append(effect)
	add_child(effect)
	effect.finished.connect(_retire.bind(effect))
	return true


## The single exit. Called from `FxEffect.finished`, whether that came from the tween running
## out or from `clear()`.
func _retire(effect: FxEffect) -> void:
	_live.erase(effect)
	if not is_instance_valid(effect):
		return
	if effect.get_parent() == self:
		remove_child(effect)
	effect.queue_free()
