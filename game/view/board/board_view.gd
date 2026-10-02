class_name BoardView
extends Node3D

## The 3D board: the table, one `Marker3D` per zone, and the `CardPool` whose quads sit on them.
##
## Layer: L4 (AGENTS.md section 4).
##
## **V1**: nothing here names `KaibaCore`, `MsgParser` or anything under `native/`.
## **V5**: the only model this reads is `DuelState`. `sync_from_state()` is the single place
##   that reads it, and it reads - never writes.
## **V6**: no screen-space coordinates anywhere below this node. Everything is metres in world
##   space. No `get_viewport()`, no `unproject_position`, no mouse.
## **V11/V12**: a card is a `card_id` and a zone. Art is resolved from the id at the moment of
##   use, inside `CardView`. Nothing resembling a `VisualDefinition` is stored here or below.
##
## -------------------------------------------------------------------------------------------
## Real-world scale (ARCHITECTURE.md section 10 rule 1)
## -------------------------------------------------------------------------------------------
## Table 1.20 m x 0.75 m, cards 59 mm x 86 mm, Godot units are metres. Every number below is a
## real measurement, which is the whole point: a VR port must be able to put a human at this
## table without rescaling anything. Column pitch 72 mm = a 59 mm card plus a 13 mm gutter; row
## pitch 100 mm = an 86 mm card plus a 14 mm gutter. Those are playmat proportions, not
## arbitrary spacing.
##
## -------------------------------------------------------------------------------------------
## Axes and the mirror
## -------------------------------------------------------------------------------------------
## X runs along the long edge of the table, Z from one player to the other, Y up. The table top
## is the plane y = 0. Player 0 sits at +Z and looks towards -Z.
##
## Player 1's half is **derived**, never typed out twice: it is player 0's half rotated 180
## degrees about the Y axis through the centre of the table, which is physically what the second
## seat is. So `(x, y, z)` becomes `(-x, y, -z)` and the basis picks up a 180-degree Y turn.
## Writing the second half by hand is how the two halves drift apart.
##
## -------------------------------------------------------------------------------------------
## Anchor grammar
## -------------------------------------------------------------------------------------------
## The anchor strings are produced by `EventTranslator.anchor_of()` and are the only vocabulary
## shared between L3 and L4 (ARCHITECTURE.md section 7). Every anchor it can emit resolves here:
##
##   MZ_Pn_0..4    main monster zones        Marker3D
##   EMZ_Pn_0..1   extra monster zones       Marker3D
##   ST_Pn_0..4    spell & trap zones        Marker3D
##   FZ_Pn         field spell zone          Marker3D
##   HAND_Pn DECK_Pn GY_Pn BANISH_Pn EXTRA_Pn   piles, fanned or stacked by slot index
##   PLAYER_Pn     the player themselves, for direct attacks and life points
##   NOWHERE       off the board, below the table: where a card that does not exist yet comes
##                 from and where a card that has left the model goes
##   OVL_<host>_<i>   xyz material, computed from its host zone
##   PZ_Pn_0/1     MR3 separate pendulum zones. Aliased onto ST_Pn_0 and ST_Pn_4 because that
##                 is literally where they are under MR4/MR5, which is the only rule set the
##                 MVP runs. If MR3 is ever supported they need real markers.
##
## An anchor nobody recognises warns once and resolves to NOWHERE. V13's spirit: an unknown
## name must not crash the board.
##
## -------------------------------------------------------------------------------------------
## Two models, deliberately (ARCHITECTURE.md section 5)
## -------------------------------------------------------------------------------------------
## `DuelState` is correct the instant an event is applied. This board chases it with animation
## and is allowed to lag. `sync_from_state()` is the reconciliation: it throws the board away
## and rebuilds it from the model. Call it when `AnimationDirector` is idle, never mid-flight -
## it recycles the very `CardView`s a tween may be holding.

# ----------------------------------------------------------------------------------------------
# Measurements. All metres.
# ----------------------------------------------------------------------------------------------

## ARCHITECTURE.md section 4 and section 10 rule 1. Do not change without reading both.
const TABLE_SIZE: Vector2 = Vector2(1.20, 0.75)
const TABLE_THICKNESS: float = 0.02

const CARD_SIZE: Vector2 = Vector2(CardView.CARD_WIDTH, CardView.CARD_HEIGHT)

## 59 mm card + 13 mm gutter.
const COLUMN_PITCH: float = 0.072

## 86 mm card + 14 mm gutter.
const ROW_PITCH: float = 0.100

## Field spell / extra deck on one side, graveyard / deck / banished on the other.
const OUTER_COLUMN: float = 3.0 * COLUMN_PITCH

## Rows, measured from the centre line towards player 0.
##
## The extra monster zones are physically *shared* between the players under MR5, so both
## players' EMZ anchors want to be the same point. They are nudged 8 mm towards their owner
## instead: close enough to read as the centre row, far enough apart that every anchor on the
## board resolves to a distinct position, and honest about the fact that only one of the two can
## be occupied at a time.
const ROW_EXTRA_MONSTER: float = 0.008
const ROW_MONSTER: float = 0.100
const ROW_SPELL: float = 0.200
const ROW_PILE: float = 0.300
const ROW_HAND: float = 0.330

## The hand sits off the table edge, lifted and tilted towards its owner. Not a screen-space
## decision (V6): it is where a seated player actually holds cards.
const HAND_LIFT: float = 0.015
const HAND_TILT: float = 20.0

## Life point readout and direct-attack target. Past the table edge, at roughly chest height
## for someone sitting at it.
const PLAYER_OFFSET: Vector3 = Vector3(0.0, 0.09, 0.42)

## Below the table. `EventTranslator.ANCHOR_NOWHERE`.
const NOWHERE_OFFSET: Vector3 = Vector3(0.0, -0.25, 0.0)

## Cards float this far above the table top so the quads do not fight the table for the depth
## buffer.
const CARD_LIFT: float = 0.0012

## Vertical pitch inside a face-down stack. A real card is about 0.3 mm; this is exaggerated so
## a stack of six reads as a stack rather than as one card.
const STACK_PITCH: float = 0.0016

## How much of a pile is actually drawn. A 40-card graveyard rendered card by card would cost 40
## quads to show one visible face.
const PILE_VIEW_LIMIT: int = 4
const DECK_VIEW_LIMIT: int = 6
const OVERLAY_VIEW_LIMIT: int = 3

## Spacing between cards in a fanned hand, and the width the fan is allowed to occupy.
const HAND_SPACING: float = 0.050
const HAND_MAX_WIDTH: float = 0.420

const ANCHOR_NOWHERE: String = "NOWHERE"

## Which seat the camera belongs to. Only affects whether that player's hand is drawn face-up;
## the board itself is never rotated to put the viewer at player 0, because player ids stay
## absolute all the way up from ocgcore (see `EventTranslator`'s note on player ids).
@export var viewer_player: int = 0

var _anchors: Node3D = null
var _table: MeshInstance3D = null
var _pool: CardPool = null

## anchor name -> Array of `CardView`, bottom of the stack first. Zone anchors hold at most one.
var _occupants: Dictionary = {}

var _warned_anchors: Dictionary = {}


func _ready() -> void:
	_ensure_built()


# ----------------------------------------------------------------------------------------------
# Anchors
# ----------------------------------------------------------------------------------------------

## World position of an anchor. The one function `EventTranslator`'s grammar is required to
## resolve against, and the only thing `AnimationDirector` needs to move a card.
func anchor_position(anchor: String) -> Vector3:
	return anchor_transform(anchor).origin


## World transform of an anchor: position plus the orientation a card lying in that zone takes.
## Every anchor's local +Z points at the sky, so a `CardView`'s own rotation composes onto this
## without the card ever needing to know which way is up.
func anchor_transform(anchor: String) -> Transform3D:
	_ensure_built()

	var marker: Node = _anchors.get_node_or_null(NodePath(anchor))
	if marker is Marker3D:
		return (marker as Marker3D).global_transform

	var resolved: String = _alias(anchor)
	if resolved != anchor:
		return anchor_transform(resolved)

	var overlay: Dictionary = _parse_overlay(anchor)
	if not overlay.is_empty():
		var host: Transform3D = anchor_transform(str(overlay["host"]))
		var index: int = int(overlay["index"])
		return host.translated_local(Vector3(0.0, -0.013 * float(index + 1), -0.0006 * float(index + 1)))

	if anchor != ANCHOR_NOWHERE and not _warned_anchors.has(anchor):
		_warned_anchors[anchor] = true
		push_warning("[BoardView] unknown anchor \"%s\"; resolving to NOWHERE" % anchor)
	return (_anchors.get_node("NOWHERE") as Marker3D).global_transform


## Where the `index`-th card of a pile sits. Zone anchors ignore the index, hands fan along the
## table edge and piles stack upwards.
func slot_transform(anchor: String, index: int, count: int) -> Transform3D:
	var base: Transform3D = anchor_transform(anchor)
	if index <= 0 and count <= 1:
		return base

	if anchor.begins_with("HAND_P"):
		var span: float = minf(HAND_SPACING, HAND_MAX_WIDTH / float(maxi(count, 1)))
		var offset: float = (float(index) - (float(maxi(count, 1)) - 1.0) * 0.5) * span
		return base.translated_local(Vector3(offset, 0.0, 0.0))

	if _is_pile(anchor):
		# Local +Z is up at every anchor, so a stack grows along local +Z.
		return base.translated_local(Vector3(0.0, 0.0, STACK_PITCH * float(index)))

	return base


## Every anchor that exists as a real marker, in creation order. The headless self-check walks
## this to prove no two zones share a position.
func anchor_names() -> PackedStringArray:
	_ensure_built()
	var names: PackedStringArray = PackedStringArray()
	for child: Node in _anchors.get_children():
		names.append(child.name)
	return names


## Table footprint as actually built, read back off the mesh rather than off the constant, so
## the self-check measures the geometry instead of re-stating the intent.
func table_footprint() -> Vector2:
	_ensure_built()
	var box: BoxMesh = _table.mesh as BoxMesh
	if box == null:
		return Vector2.ZERO
	return Vector2(box.size.x, box.size.z)


func card_pool() -> CardPool:
	_ensure_built()
	return _pool


# ----------------------------------------------------------------------------------------------
# Occupancy
# ----------------------------------------------------------------------------------------------

## The card currently shown at an anchor, or the top of its pile. `null` if the anchor is empty.
func view_at(anchor: String) -> CardView:
	var stack: Array = _occupants.get(anchor, []) as Array
	if stack.is_empty():
		return null
	return stack[stack.size() - 1] as CardView


## How many cards are parked at an anchor. Cards in flight are not counted - they belong to
## whoever is animating them until it hands them back.
func occupant_count(anchor: String) -> int:
	return (_occupants.get(anchor, []) as Array).size()


## Detaches the top card of an anchor and hands it over. The caller owns it until it calls
## `place_view()` or `release_view()`; that is the window in which `AnimationDirector` holds a
## card in flight.
func take_view(anchor: String) -> CardView:
	var stack: Array = _occupants.get(anchor, []) as Array
	if stack.is_empty():
		return null
	var view: CardView = stack.pop_back() as CardView
	_reflow(anchor)
	return view


## Detaches the view showing a specific model card, wherever it is parked.
##
## This is the precise counterpart to `take_view()`, which can only take the top of a pile.
## Moving the third card out of a hand animates the third card, not whatever happened to be
## on top. Returns `null` when no view is bound to that handle, which is the normal case for
## a card that has not been rendered yet.
func take_view_by_handle(handle: int) -> CardView:
	if handle == 0:
		return null
	for key: Variant in _occupants.keys():
		var stack: Array = _occupants[key] as Array
		for index: int in stack.size():
			var view: CardView = stack[index] as CardView
			if view != null and view.handle == handle:
				stack.remove_at(index)
				_reflow(str(key))
				return view
	return null


## Parks a card at an anchor and snaps it to the right slot.
func place_view(view: CardView, anchor: String) -> void:
	if view == null:
		return
	if not _occupants.has(anchor):
		_occupants[anchor] = []
	var stack: Array = _occupants[anchor] as Array
	if not stack.has(view):
		stack.append(view)
	_reflow(anchor)


## Returns a card to the pool, wherever it currently is.
func release_view(view: CardView) -> void:
	if view == null:
		return
	for anchor: Variant in _occupants.keys():
		var stack: Array = _occupants[anchor] as Array
		var at: int = stack.find(view)
		if at >= 0:
			stack.remove_at(at)
			_reflow(str(anchor))
			break
	_pool.release(view)


## Decodes an `EventTranslator` FACE_* string onto a card. The one place in L4 that knows that
## vocabulary, so the rest of the view layer deals in two booleans.
func apply_face(view: CardView, face: String) -> void:
	if view == null:
		return
	if face == EventTranslator.FACE_UP_ATTACK:
		view.set_orientation(true, false)
	elif face == EventTranslator.FACE_DOWN_ATTACK:
		view.set_orientation(false, false)
	elif face == EventTranslator.FACE_UP_DEFENSE:
		view.set_orientation(true, true)
	elif face == EventTranslator.FACE_DOWN_DEFENSE:
		view.set_orientation(false, true)
	# Anything else is FACE_UNKNOWN: no position byte was sent. Most pile destinations have no
	# meaningful face, and overwriting the card's current one would be a guess.


## Snaps a card to a slot, with no animation. `AnimationDirector` tweens towards exactly this
## transform, which is why the two cannot disagree about where a card belongs.
func rest_transform(anchor: String, index: int, count: int, view: CardView) -> Transform3D:
	var slot: Transform3D = slot_transform(anchor, index, count)
	var lift: float = CARD_LIFT if _is_on_table(anchor) else 0.0
	var basis: Basis = slot.basis * (view.orientation() if view != null else Basis.IDENTITY)
	return Transform3D(basis, slot.origin + Vector3(0.0, lift, 0.0))


# ----------------------------------------------------------------------------------------------
# Reconciliation (V5)
# ----------------------------------------------------------------------------------------------

## Rebuilds the whole board from the model. The authoritative resync: animation may lag or get
## a card wrong, this cannot.
##
## It recycles every card view, so it must not run while anything is in flight - wire it to
## `AnimationDirector.queue_drained`, not to the event stream.
##
## Full rebuild rather than a diff on purpose. A diff needs stable per-card identity, and an
## intent carries `card_id` only (V11) - two copies of the same card in the same pile are
## indistinguishable, and a face-down card has no id at all. Rebuilding sidesteps the question
## entirely, and at a hundred quads it is not worth optimising.
func sync_from_state(state: DuelState) -> void:
	_ensure_built()
	if state == null:
		return

	_pool.release_all()
	_occupants.clear()

	for player: int in range(DuelEnums.PLAYER_COUNT):
		for sequence: int in range(DuelEnums.MAIN_MONSTER_ZONES):
			_sync_zone(state.main_monster[player][sequence], "MZ_P%d_%d" % [player, sequence])
		for sequence: int in range(DuelEnums.EXTRA_MONSTER_ZONES):
			_sync_zone(state.extra_monster[player][sequence], "EMZ_P%d_%d" % [player, sequence])
		for sequence: int in range(DuelEnums.SPELL_TRAP_ZONES):
			_sync_zone(state.spell_trap[player][sequence], "ST_P%d_%d" % [player, sequence])
		_sync_zone(state.field_zone[player], "FZ_P%d" % player)

		_sync_hand(state.hand[player], player)
		_sync_pile(state.graveyard[player], "GY_P%d" % player, PILE_VIEW_LIMIT, true)
		_sync_pile(state.banished[player], "BANISH_P%d" % player, PILE_VIEW_LIMIT, true)
		_sync_pile(state.deck[player], "DECK_P%d" % player, DECK_VIEW_LIMIT, false)
		_sync_pile(state.extra_deck[player], "EXTRA_P%d" % player, PILE_VIEW_LIMIT, false)


func _sync_zone(slot: Variant, anchor: String) -> void:
	var card: DuelCard = slot as DuelCard
	if card == null:
		return
	var view: CardView = _pool.acquire()
	if view == null:
		return
	view.set_card_id(card.code if card.is_face_up() else 0)
	view.handle = card.handle
	view.set_orientation(card.is_face_up(), card.is_defense())
	place_view(view, anchor)

	var materials: int = mini(card.overlay_codes.size(), OVERLAY_VIEW_LIMIT)
	for index: int in range(materials):
		var material_view: CardView = _pool.acquire()
		if material_view == null:
			return
		material_view.set_card_id(int(card.overlay_codes[index]))
		material_view.set_orientation(true, false)
		place_view(material_view, "OVL_%s_%d" % [anchor, index])


## A hand is drawn face-up only for the seat the camera belongs to, and only for cards whose
## code we actually know. Everything else is a back - which is the honest rendering, not a
## privacy measure: hidden-information filtering happens in `HostService` before the bytes ever
## reach this process (V7).
func _sync_hand(cards: Array, player: int) -> void:
	var anchor: String = "HAND_P%d" % player
	for index: int in range(cards.size()):
		var card: DuelCard = cards[index] as DuelCard
		if card == null:
			continue
		var view: CardView = _pool.acquire()
		if view == null:
			return
		var revealed: bool = player == viewer_player and card.code != 0
		view.set_card_id(card.code if revealed else 0)
		view.handle = card.handle
		view.set_orientation(revealed, false)
		place_view(view, anchor)


func _sync_pile(cards: Array, anchor: String, limit: int, face_up: bool) -> void:
	var shown: int = mini(cards.size(), limit)
	var first: int = cards.size() - shown
	for index: int in range(first, cards.size()):
		var card: DuelCard = cards[index] as DuelCard
		if card == null:
			continue
		var view: CardView = _pool.acquire()
		if view == null:
			return
		view.set_card_id(card.code if face_up else 0)
		view.handle = card.handle
		view.set_orientation(face_up, false)
		place_view(view, anchor)


# ----------------------------------------------------------------------------------------------
# Construction
# ----------------------------------------------------------------------------------------------

## Everything this node owns is built in code rather than saved into `duel_3d.tscn`. The layout
## is arithmetic - mirrored halves, a column pitch, a row pitch - and arithmetic saved as 39
## hand-placed markers is arithmetic that will drift the first time someone nudges one in the
## editor.
func _ensure_built() -> void:
	if _anchors != null:
		return

	_table = get_node_or_null("Table") as MeshInstance3D
	if _table == null:
		_table = MeshInstance3D.new()
		_table.name = "Table"
		add_child(_table)
	var top: BoxMesh = BoxMesh.new()
	top.size = Vector3(TABLE_SIZE.x, TABLE_THICKNESS, TABLE_SIZE.y)
	_table.mesh = top
	# Sunk so that the playing surface, not the centre of the slab, is the plane y = 0.
	_table.position = Vector3(0.0, -TABLE_THICKNESS * 0.5, 0.0)
	var felt: StandardMaterial3D = StandardMaterial3D.new()
	felt.albedo_color = Color(0.09, 0.13, 0.11)
	felt.roughness = 1.0
	_table.material_override = felt

	_anchors = Node3D.new()
	_anchors.name = "ZoneAnchors"
	add_child(_anchors)
	_build_anchors()

	_pool = get_node_or_null("CardPool") as CardPool
	if _pool == null:
		_pool = CardPool.new()
		_pool.name = "CardPool"
		add_child(_pool)


func _build_anchors() -> void:
	_add_anchor(ANCHOR_NOWHERE, Transform3D(_flat_basis(), NOWHERE_OFFSET))

	for player: int in range(DuelEnums.PLAYER_COUNT):
		for sequence: int in range(DuelEnums.MAIN_MONSTER_ZONES):
			_add_player_anchor("MZ_P%d_%d" % [player, sequence], player,
				_flat(_column(sequence), ROW_MONSTER))

		# Extra monster zones sit on the MZ columns 1 and 3, which is where MR5 puts them.
		_add_player_anchor("EMZ_P%d_0" % player, player, _flat(_column(1), ROW_EXTRA_MONSTER))
		_add_player_anchor("EMZ_P%d_1" % player, player, _flat(_column(3), ROW_EXTRA_MONSTER))

		for sequence: int in range(DuelEnums.SPELL_TRAP_ZONES):
			_add_player_anchor("ST_P%d_%d" % [player, sequence], player,
				_flat(_column(sequence), ROW_SPELL))

		_add_player_anchor("FZ_P%d" % player, player, _flat(-OUTER_COLUMN, ROW_MONSTER))
		_add_player_anchor("EXTRA_P%d" % player, player, _flat(-OUTER_COLUMN, ROW_SPELL))
		_add_player_anchor("GY_P%d" % player, player, _flat(OUTER_COLUMN, ROW_MONSTER))
		_add_player_anchor("DECK_P%d" % player, player, _flat(OUTER_COLUMN, ROW_SPELL))
		_add_player_anchor("BANISH_P%d" % player, player, _flat(OUTER_COLUMN, ROW_PILE))

		var hand: Transform3D = Transform3D(
			Basis.from_euler(Vector3(deg_to_rad(HAND_TILT), 0.0, 0.0)) * _flat_basis(),
			Vector3(0.0, HAND_LIFT, ROW_HAND))
		_add_player_anchor("HAND_P%d" % player, player, hand)

		_add_player_anchor("PLAYER_P%d" % player, player,
			Transform3D(_flat_basis(), PLAYER_OFFSET))


## Adds player 0's transform as given, and player 1's as the same thing rotated half a turn
## about the table's centre.
func _add_player_anchor(anchor: String, player: int, p0: Transform3D) -> void:
	_add_anchor(anchor, p0 if player == 0 else _mirror(p0))


func _add_anchor(anchor: String, local: Transform3D) -> void:
	var marker: Marker3D = Marker3D.new()
	marker.name = anchor
	marker.transform = local
	_anchors.add_child(marker)
	_occupants[anchor] = []


## A card lying flat on the table: local +Z points at the sky, local +Y points away from player
## 0. Every anchor starts from this, so a `CardView` only ever has to supply its own two
## rotations.
func _flat_basis() -> Basis:
	return Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0))


func _flat(x: float, z: float) -> Transform3D:
	return Transform3D(_flat_basis(), Vector3(x, 0.0, z))


## Player 1 is player 0 rotated 180 degrees about the Y axis through the centre of the table.
func _mirror(value: Transform3D) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), Vector3.ZERO) * value


## X of main monster / spell & trap zone `sequence`, counted from the owner's left.
func _column(sequence: int) -> float:
	return (float(sequence) - float(DuelEnums.MAIN_MONSTER_ZONES - 1) * 0.5) * COLUMN_PITCH


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## Re-seats every card at an anchor after the stack changed size, so a fanned hand re-centres
## and a pile closes its gap.
func _reflow(anchor: String) -> void:
	var stack: Array = _occupants.get(anchor, []) as Array
	for index: int in range(stack.size()):
		var view: CardView = stack[index] as CardView
		if view == null:
			continue
		view.global_transform = rest_transform(anchor, index, stack.size(), view)


func _is_pile(anchor: String) -> bool:
	return (
		anchor.begins_with("DECK_P")
		or anchor.begins_with("GY_P")
		or anchor.begins_with("BANISH_P")
		or anchor.begins_with("EXTRA_P")
	)


## Whether cards at this anchor rest on the table top and therefore need the depth-fight lift.
## Hands, players and NOWHERE are already off the surface.
func _is_on_table(anchor: String) -> bool:
	return not (
		anchor.begins_with("HAND_P")
		or anchor.begins_with("PLAYER_P")
		or anchor == ANCHOR_NOWHERE
	)


## MR3 separate pendulum zones onto the MR4/MR5 spell & trap slots they became. See the anchor
## grammar note above.
func _alias(anchor: String) -> String:
	if not anchor.begins_with("PZ_P"):
		return anchor
	var parts: PackedStringArray = anchor.split("_")
	if parts.size() != 3:
		return anchor
	var player: String = parts[1]
	return "ST_%s_%d" % [player, 0 if parts[2] == "0" else DuelEnums.SPELL_TRAP_ZONES - 1]


## `OVL_MZ_P0_2_1` -> `{"host": "MZ_P0_2", "index": 1}`. Empty for anything else.
func _parse_overlay(anchor: String) -> Dictionary:
	if not anchor.begins_with("OVL_"):
		return {}
	var body: String = anchor.substr(4)
	var cut: int = body.rfind("_")
	if cut <= 0:
		return {}
	var tail: String = body.substr(cut + 1)
	if not tail.is_valid_int():
		return {}
	return {"host": body.substr(0, cut), "index": tail.to_int()}
