class_name InputSource
extends Node

## Turns "the user did something at a point on the screen" into an `InputIntent`, and emits it.
##
## Layer: L5 (AGENTS.md section 4). This is the only place in the whole project allowed to hold
## a screen coordinate and a camera at the same time, and the reason it exists is
## **ARCHITECTURE.md section 10 rule 5**:
##
##     No screen raycasts in L3/L4. Selection means `InputSource` resolves to a card
##     reference, not to coordinates.
##
## So the raycast happens *here*, behind `_pick()`, and the only thing that leaves this node is
## a card handle or an anchor name. `TouchSource`, `MouseSource` and one day `XRSource` differ
## in **when** they pick; none of them interprets what came back. That is what makes the VR port
## an added subclass instead of a rewrite: an `XRSource` picks along a controller ray in world
## space, never projects a screen point, and L3 cannot tell the difference.
##
## -------------------------------------------------------------------------------------------
## The `InputIntent` vocabulary
## -------------------------------------------------------------------------------------------
##
##   {"kind": "SELECT_CARD", "handle": int, "card_id": int, "anchor": String}
##   {"kind": "SELECT_ALT",  "handle": int, "card_id": int, "anchor": String}
##   {"kind": "SELECT_ZONE", "anchor": String}
##   {"kind": "POINT_AT",    "anchor": String, "handle": int}
##   {"kind": "CONFIRM"}
##   {"kind": "CANCEL"}
##
## `SELECT_ALT` is "play this card the other way". It carries exactly the same fields as
## `SELECT_CARD` and means the same card; what differs is which of the commands the engine
## offered for that card the player wants. ocgcore offers a monster in hand as both `summon`
## and `mset`, and a spell as both `activate` and `sset`, and nothing in the request says which
## one a tap meant. With one gesture the only consistent rule is "the face-up one wins", which
## left **no way at all to set a monster** - a tap could only ever set a trap, because a trap
## appears in `sset` alone. That is a hole in the input vocabulary, not in the rules layer, and
## this is the verb that fills it.
##
## **An `InputIntent` never carries a screen coordinate.** Not as a convenience, not for a
## tooltip, not "just for now". The moment one does, every consumer downstream gains the right
## to look at it, and rule 5 is gone.
##
## `handle` is the stable per-card identity `DuelState` mints (`core/duel/duel_card.gd`).
## `card_id` cannot do that job: two copies of a card in one hand share it, and a face-down card
## reports `0`. `card_id` rides along only so a consumer can sanity-check the handle against the
## code the engine offered.
##
## `anchor` is the `EventTranslator.anchor_of()` grammar - `MZ_P0_3`, `HAND_P1`, `ST_P0_0` - the
## one vocabulary L3 and L4 already share. It is the empty string when the user hit nothing.
##
## -------------------------------------------------------------------------------------------
## What a subclass does
## -------------------------------------------------------------------------------------------
## It calls `select_at()`, `point_at()`, `confirm()` or `cancel()` and nothing else. It must not
## poll raw pointer positions from `_process`: input arrives in `_input` / `_unhandled_input`,
## and anything that needs to measure time does it with a `Timer`, not by sampling a position
## every frame.

## The one thing this node emits. `data` is an `InputIntent` as described above.
signal intent(data: Dictionary)

const KIND_SELECT_CARD: String = "SELECT_CARD"
const KIND_SELECT_ALT: String = "SELECT_ALT"
const KIND_SELECT_ZONE: String = "SELECT_ZONE"
const KIND_POINT_AT: String = "POINT_AT"
const KIND_CONFIRM: String = "CONFIRM"
const KIND_CANCEL: String = "CANCEL"


# ----------------------------------------------------------------------------------------------
# The binding table
# ----------------------------------------------------------------------------------------------

## Every verb in the vocabulary, with the gesture that produces it on each device.
##
## **This table is the source, not a description of one.** `TouchSource` and `MouseSource`
## implement what it says, `ui/controls/controls_screen.gd` renders it, and `ui/ui_test.gd`
## asserts that every `KIND_*` constant above appears in it. A controls screen written by hand
## drifts the first time somebody adds a gesture, and a controls screen that lies is worse than
## no controls screen at all - the player stops trusting the one place that was supposed to tell
## them what the app does.
##
## Keys, all `String`:
##
##   kind    the `InputIntent` kind this binding produces
##   label   the verb, as a player would name it
##   does    what the duel does with it
##   touch   the gesture on a phone, or "" where the device has none
##   pc      the gesture on a desktop, or "" where the device has none
##
## An empty column is a statement, not an omission: it means that device genuinely cannot
## produce that verb today, and the screen prints so. Filling one in with a gesture that is not
## implemented is the one edit this table must never take.
##
## Both columns are always present, always labelled, and the screen never asks how big the
## window is to decide which to show (ARCHITECTURE.md section 10 rule 4). A phone that is cast
## to a monitor, a desktop with a touchscreen and a tablet with a keyboard are all one build.
const BINDINGS: Array[Dictionary] = [
	{
		"kind": KIND_POINT_AT,
		"label": "Look at a card",
		"does": "Shows the card up close with its name, stats and effect text. Never counts as an answer.",
		"touch": "Tap the card",
		"pc": "Left click",
	},
	{
		"kind": KIND_SELECT_CARD,
		"label": "Play a card",
		"does": "Opens the action menu during your turn, showing what you can do with the card.",
		"touch": "Press and hold the card",
		"pc": "Hold left click on the card",
	},
	{
		"kind": KIND_SELECT_ALT,
		"label": "Set a card",
		"does": "Plays it the other way: set a monster face-down, set a spell instead of activating it.",
		"touch": "Short drag downwards on the card",
		"pc": "Middle click, or Shift + left click",
	},
	{
		"kind": KIND_SELECT_ZONE,
		"label": "Choose a zone",
		"does": "Answers a request for a place - where a summoned monster goes, which zone to set into.",
		"touch": "Hold on the empty zone",
		"pc": "Hold left click on the empty zone",
	},
	{
		"kind": KIND_CONFIRM,
		"label": "Confirm",
		"does": "Says yes, finishes a multi-card selection, or moves to the next phase.",
		"touch": "Yes / Confirm button on the prompt",
		"pc": "Enter or Space, or the Yes / Confirm button",
	},
	{
		"kind": KIND_CANCEL,
		"label": "Cancel",
		"does": "Says no, drops what has been picked so far, or ends the turn.",
		"touch": "Two-finger tap",
		"pc": "Right click, or Escape",
	},
]


## The row of `BINDINGS` for `kind`, or `{}`. Lookup rather than a second table, so there is
## still exactly one place a gesture is written down.
static func binding_for(kind: String) -> Dictionary:
	for row: Dictionary in BINDINGS:
		if str(row.get("kind", "")) == kind:
			return row
	return {}

## No anchor. A tap on the sky, or on felt far from every zone.
const ANCHOR_NONE: String = ""

## How far the pick ray travels, in metres. The whole board is 1.2 m across and the camera sits
## under a metre from it, so this is generous by an order of magnitude.
const PICK_RAY_LENGTH: float = 10.0

## How close to a zone's centre a tap on the empty table has to land to count as that zone, in
## metres. Half the column pitch plus a little: a tap in the gutter between two zones resolves
## to the nearer one, a tap off the field resolves to nothing.
const ZONE_SNAP_RADIUS: float = 0.045

## Deepest pile a tap can address. `BoardView` never renders more than `DECK_VIEW_LIMIT` cards
## of one pile, so looking further is wasted work.
const MAX_SLOTS_PER_ANCHOR: int = 8

var _rig: CameraRig = null
var _board: BoardView = null

## Last thing `point_at_if_changed()` resolved to, so a continuously moving pointer emits one
## preview per target instead of one per motion event.
var _last_point_handle: int = 0
var _last_point_anchor: String = ANCHOR_NONE


## Hands this source the two things it needs: the camera to project through and the board to
## resolve a hit against. A source that has not been bound emits nothing rather than crashing.
func bind(rig: CameraRig, board: BoardView) -> void:
	_rig = rig
	_board = board


func is_bound() -> bool:
	return _rig != null and _board != null


# ----------------------------------------------------------------------------------------------
# What subclasses call
# ----------------------------------------------------------------------------------------------

## A tap / click landed here. Emits `SELECT_CARD` when it hit a card, `SELECT_ZONE` when it hit
## bare table inside a zone, and nothing at all when it hit neither.
func select_at(screen_position: Vector2) -> void:
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty():
		return
	if int(hit.get("handle", 0)) != 0:
		intent.emit({
			"kind": KIND_SELECT_CARD,
			"handle": int(hit["handle"]),
			"card_id": int(hit.get("card_id", 0)),
			"anchor": str(hit.get("anchor", ANCHOR_NONE)),
		})
		return
	var anchor: String = str(hit.get("anchor", ANCHOR_NONE))
	if anchor == ANCHOR_NONE:
		return
	intent.emit({"kind": KIND_SELECT_ZONE, "anchor": anchor})


## The same tap, meaning "the other way round". Emits `SELECT_ALT` when it hit a card and
## nothing otherwise: bare table has no second reading, so a drag that landed on felt is simply
## not an answer. The pick is identical to `select_at()` - the difference is entirely in the
## verb, which is the point. L3 decides what "the other way" means for the selection it is
## holding; this node does not know and must not guess.
func select_alt_at(screen_position: Vector2) -> void:
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty():
		return
	var handle: int = int(hit.get("handle", 0))
	if handle == 0:
		return
	intent.emit({
		"kind": KIND_SELECT_ALT,
		"handle": handle,
		"card_id": int(hit.get("card_id", 0)),
		"anchor": str(hit.get("anchor", ANCHOR_NONE)),
	})


## A hover or a long press landed here. Same raycast, no commitment: `POINT_AT` is a request to
## show something, never an answer to a selection.
func point_at(screen_position: Vector2) -> void:
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty():
		return
	intent.emit({
		"kind": KIND_POINT_AT,
		"anchor": str(hit.get("anchor", ANCHOR_NONE)),
		"handle": int(hit.get("handle", 0)),
	})


## `point_at()`, but silent while the ray keeps resolving to the same thing. A pointer that
## moves continuously - a mouse, later a VR controller - would otherwise emit hundreds of
## identical previews a second.
##
## It lives here rather than in the subclass so that a source still never inspects a pick
## result: the comparison is on identity alone, and no caller learns what was hit.
func point_at_if_changed(screen_position: Vector2) -> void:
	var hit: Dictionary = _pick(screen_position)
	var handle: int = int(hit.get("handle", 0))
	var anchor: String = str(hit.get("anchor", ANCHOR_NONE))
	if handle == _last_point_handle and anchor == _last_point_anchor:
		return
	_last_point_handle = handle
	_last_point_anchor = anchor
	if hit.is_empty():
		return
	intent.emit({"kind": KIND_POINT_AT, "anchor": anchor, "handle": handle})


func confirm() -> void:
	intent.emit({"kind": KIND_CONFIRM})


func cancel() -> void:
	intent.emit({"kind": KIND_CANCEL})


# ----------------------------------------------------------------------------------------------
# The raycast
# ----------------------------------------------------------------------------------------------

## Screen point -> `{handle, card_id, anchor}`. Empty when the ray left the world entirely.
##
## Two stages, in order:
##
##   1. A physics ray masked to `CardView.PICK_LAYER`. Only cards are on that layer and only
##      cards that are actually on the board - a pooled card's collider is off - so a hit here
##      is a card, with no further checking.
##   2. Failing that, the ray is intersected with the table plane (y = 0) analytically. No
##      collider is involved, because the table has none and giving it one would mean a pick
##      ray could hit the furniture. The resulting point resolves to the nearest zone within
##      `ZONE_SNAP_RADIUS`, which is how an *empty* zone gets tapped.
##
## The anchor is found by comparing the hit against the rest position of every slot `BoardView`
## currently holds, rather than against the anchor centres: the fifth card of a fanned hand sits
## 20 cm from `HAND_P0` and nearer the banish pile than to its own anchor, so "closest anchor"
## is simply the wrong question. "Closest card slot" is the right one, and `BoardView` already
## computes exactly those positions for its own layout.
func _pick(screen_position: Vector2) -> Dictionary:
	if not is_bound():
		return {}
	var camera: Camera3D = _rig.camera()
	if camera == null or not _board.is_inside_tree():
		return {}

	var origin: Vector3 = camera.project_ray_origin(screen_position)
	var direction: Vector3 = camera.project_ray_normal(screen_position)

	var view: CardView = _cast_card(origin, direction)
	if view != null:
		return {
			"handle": view.handle,
			"card_id": view.card_id,
			"anchor": _anchor_nearest(view.global_position, INF),
		}

	var ground: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if ground == null:
		return {}
	return {
		"handle": 0,
		"card_id": 0,
		"anchor": _anchor_nearest(ground as Vector3, ZONE_SNAP_RADIUS),
	}


## The nearest `CardView` along the ray, or `null`. Masked to the card layer, areas only: the
## pick volume is an `Area3D` so that a card can be aimed at without becoming a physical object
## that other things could collide with.
func _cast_card(origin: Vector3, direction: Vector3) -> CardView:
	var space: PhysicsDirectSpaceState3D = _board.get_world_3d().direct_space_state
	if space == null:
		return null

	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction * PICK_RAY_LENGTH, CardView.PICK_LAYER)
	query.collide_with_areas = true
	query.collide_with_bodies = false

	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null

	# The collider is the card's `Area3D`; the card itself is its parent. Walking up rather than
	# trusting one level keeps this working if the volume is ever nested deeper.
	var node: Node = hit.get("collider") as Node
	while node != null:
		if node is CardView:
			return node as CardView
		node = node.get_parent()
	return null


## Anchor whose nearest occupied slot is closest to `point`, or `ANCHOR_NONE` when nothing is
## within `radius` metres.
##
## `BoardView.rest_transform()` is the same function the board uses to seat a card, so this asks
## "which slot is the user pointing at" in exactly the terms the board laid out. An anchor with
## no occupants is still considered at its own centre, which is what makes tapping an empty
## monster zone work.
func _anchor_nearest(point: Vector3, radius: float) -> String:
	var best: String = ANCHOR_NONE
	# Compared squared throughout; `INF * INF` is still `INF`, so an unbounded search needs no
	# special case.
	var best_distance: float = radius * radius

	for anchor: String in _board.anchor_names():
		if anchor == BoardView.ANCHOR_NOWHERE:
			continue
		var count: int = mini(maxi(_board.occupant_count(anchor), 1), MAX_SLOTS_PER_ANCHOR)
		for index: int in range(count):
			var slot: Vector3 = _board.rest_transform(anchor, index, count, null).origin
			var distance: float = slot.distance_squared_to(point)
			if distance < best_distance:
				best_distance = distance
				best = anchor

	return best
