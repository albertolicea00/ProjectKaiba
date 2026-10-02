class_name CardPool
extends Node3D

## Recycles `CardView` nodes so the board never allocates while something is moving.
##
## Layer: L4 (AGENTS.md section 4). **V1: nothing here may name `KaibaCore`, `MsgParser` or
## anything under `native/`.**
##
## -------------------------------------------------------------------------------------------
## Why a pool at all
## -------------------------------------------------------------------------------------------
## ARCHITECTURE.md section 9: "`AvatarPool` pre-instantiates; never `load()` mid-animation."
## The same rule applies to the 2D fallback, and for the same reason - the target is a mid-range
## Android phone, where a resource load inside an animation frame is a visible hitch. Everything
## this pool hands out was built in `_ready()`: `CardView` shares one `QuadMesh` across every
## instance, so prewarming a hundred cards costs a hundred transforms and two materials each,
## not a hundred meshes.
##
## `acquire()` past the prewarm still works - it grows rather than returning null, because a
## missing card is a worse bug than a late allocation - but it warns, because a pool that grows
## during a duel was sized wrong.
##
## -------------------------------------------------------------------------------------------
## Ownership
## -------------------------------------------------------------------------------------------
## Every `CardView` stays a child of this node for its whole life, parked or in flight. Nothing
## reparents cards onto zone anchors. Two reasons: reparenting mid-tween changes the meaning of
## the property a `Tween` is already interpolating, and a card flying from one player's hand to
## the other's graveyard has no single sensible parent while it is in the air. Anchors supply a
## `Transform3D`; they do not adopt anything.

## Cards built up front. Sized for the worst board the MVP can show at once: two hands (~12),
## both fields (24), the visible top of six piles (~24), and headroom for cards in flight.
@export var prewarm_count: int = 96

## Hard stop on growth, so a bug that leaks cards shows up as a warning and a missing card
## rather than as an out-of-memory crash on a phone.
@export var maximum_count: int = 512

## Where parked cards sit. Below the table, out of every camera's way; `visible` is false too,
## but a sane transform means a card that is acquired and not yet placed does not flash across
## the board from wherever it was last used.
const PARKING_POSITION: Vector3 = Vector3(0.0, -0.5, 0.0)

var _free: Array[CardView] = []
var _busy: Dictionary = {}
var _created: int = 0
var _grew: bool = false


func _ready() -> void:
	_prewarm()


## A card ready to be placed. Visible, parked, with no identity yet - the caller sets the
## `card_id` and the transform.
func acquire() -> CardView:
	var view: CardView = null
	if _free.is_empty():
		view = _grow_one()
		if view == null:
			return null
	else:
		view = _free.pop_back()

	_busy[view.get_instance_id()] = view
	view.set_card_id(0)
	view.set_orientation(false, false)
	view.transform = Transform3D(Basis.IDENTITY, PARKING_POSITION)
	view.visible = true
	return view


## Returns a card to the pool. Releasing a card twice is harmless and silent: the director and a
## `BoardView` resync can both decide the same card is finished with, and making that a warning
## would mean warning on correct behaviour.
func release(view: CardView) -> void:
	if view == null:
		return
	var key: int = view.get_instance_id()
	if not _busy.has(key):
		return
	_busy.erase(key)
	view.visible = false
	view.transform = Transform3D(Basis.IDENTITY, PARKING_POSITION)
	_free.push_back(view)


## Parks every card that is currently out. Used by `BoardView.sync_from_state()`, which rebuilds
## the whole board from the model rather than diffing it.
func release_all() -> void:
	for key: Variant in _busy.keys():
		var view: CardView = _busy[key] as CardView
		if view == null:
			continue
		view.visible = false
		view.transform = Transform3D(Basis.IDENTITY, PARKING_POSITION)
		_free.push_back(view)
	_busy.clear()


func active_count() -> int:
	return _busy.size()


func created_count() -> int:
	return _created


## True if the pool ever had to allocate past `prewarm_count`. The headless self-check asserts
## this stayed false: a pool that grew during a duel is a sizing bug, not a crash.
func has_grown() -> bool:
	return _grew


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

func _prewarm() -> void:
	while _created < prewarm_count:
		var view: CardView = _make()
		if view == null:
			return
		_free.push_back(view)


func _grow_one() -> CardView:
	if not _grew:
		_grew = true
		push_warning(
			"[CardPool] prewarm of %d cards was not enough; growing mid-duel. "
			% prewarm_count
			+ "Raise prewarm_count rather than leaving this to allocate during an animation."
		)
	return _make()


func _make() -> CardView:
	if _created >= maximum_count:
		push_error("[CardPool] refusing to exceed maximum_count (%d)" % maximum_count)
		return null
	var view: CardView = CardView.new()
	view.name = "Card%03d" % _created
	view.visible = false
	view.transform = Transform3D(Basis.IDENTITY, PARKING_POSITION)
	add_child(view)
	_created += 1
	return view
