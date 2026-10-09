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

## Anchor prefixes that identify a spell/trap row and a field zone. Used by `zone_turns()`:
## cards parked here are never drawn sideways.
const ANCHOR_SPELL_PREFIX: String = "ST_"
const ANCHOR_FIELD_PREFIX: String = "FZ_"

# ----------------------------------------------------------------------------------------------
# Zone markers
# ----------------------------------------------------------------------------------------------
#
# A bare table cannot tell a player where a card is allowed to go, so every playable zone gets a
# painted outline. Three things make this more than decoration:
#
#   1. The outline is placed by copying the `Marker3D` transform of the anchor it represents,
#      not by recomputing the layout. A marker therefore cannot drift away from where a card
#      actually lands: there is only one piece of arithmetic and both read it.
#   2. The outline's *shape* carries the zone's role, not just its colour. Colour alone fails
#      for a colour-blind player and fails again under the warm table light, so a monster zone
#      is a closed frame, a spell & trap zone is the same frame with open corners, and a pile is
#      four corner brackets with nothing between them. Each is recognisable in a silhouette.
#   3. A zone that is a legal target for the pending selection lights up through
#      `highlight_zones()`, which is a material swap and nothing else.
#
# Cost, stated rather than assumed. 34 markers = 34 draw calls, all unlit, untextured and under
# a hundred vertices each. They share four `ArrayMesh`es and four `StandardMaterial3D`s between
# them, so the whole set allocates eight resources no matter how many zones exist. The obvious
# next step - one `MultiMeshInstance3D` per role, three draw calls for the board - was tried and
# rejected: Godot's headless dummy renderer does not store MultiMesh instance buffers, so
# `get_instance_transform()` reads back zero and the "every marker sits on its anchor" check
# below could not exist. A marker that cannot be verified is worth less than 31 draw calls.

## Roles a zone can have. The grammar in `_role_of()` maps anchor names onto these, and nothing
## else in the file branches on zone identity.
enum ZoneRole {
	MONSTER,
	SPELL_TRAP,
	PILE,
}

## Grown around the card so the outline frames it instead of hiding underneath it. 3 mm leaves a
## 7 mm gap between neighbouring zone outlines at the 72 mm column pitch, which is what stops the
## board reading as one continuous grid.
const ZONE_MARGIN: float = 0.003

## Outer footprint of a zone outline: 65 mm x 92 mm.
const ZONE_SIZE: Vector2 = Vector2(
	CardView.CARD_WIDTH + ZONE_MARGIN * 2.0,
	CardView.CARD_HEIGHT + ZONE_MARGIN * 2.0)

## The extra monster zones are one physical pair shared by both players, and `ROW_EXTRA_MONSTER`
## nudges each owner's anchor 8 mm towards them so every anchor stays distinct. Drawing two
## identical 65 mm outlines 16 mm apart would put their left and right edges in exactly the same
## place and leave them fighting for the depth buffer. Player 1's outline is inset instead, so
## the pair reads as one shared zone drawn twice - which is what it is - with no coincident
## geometry anywhere.
const ZONE_SHARED_INSET: float = 0.004

## Above the table top (y = 0) and below the cards (`CARD_LIFT`, 1.2 mm). Both margins matter:
## at the table's height the outline z-fights the felt, at the card's height it z-fights the art.
const MARKER_LIFT: float = 0.0004

## Border thickness per role. The monster frame is the heaviest because it is the row a player
## reads first.
const MARKER_BORDER_MONSTER: float = 0.0020
const MARKER_BORDER_SPELL: float = 0.0015
const MARKER_BORDER_PILE: float = 0.0022

## Fraction of each side a spell & trap zone's dash actually covers, centred, leaving the corners
## open.
const MARKER_DASH_RATIO: float = 0.55

## Fraction of each side a pile's corner bracket covers. Two opposite brackets must not meet, so
## this has to stay below 0.5.
const MARKER_CORNER_RATIO: float = 0.30

## The playing surface. Dark navy-green like EDOPro's field.
const FELT_COLOUR: Color = Color(0.05, 0.09, 0.08)

## Where a user-supplied field background lives, outside res://.
const FIELD_TEXTURE_PATH: String = "res://../data/base/textures/field_bg.png"

## Role colours. EDOPro-style: warm amber for monsters, teal for spell & trap, muted slate
## for piles.
const COLOUR_MONSTER: Color = Color(0.85, 0.60, 0.18)
const COLOUR_SPELL_TRAP: Color = Color(0.18, 0.65, 0.58)
const COLOUR_PILE: Color = Color(0.40, 0.48, 0.60)

## A zone the pending selection will accept. One colour for every role: once a zone is a legal
## target, "which kind of zone is it" has stopped being the question.
const COLOUR_HIGHLIGHT: Color = Color(0.52, 0.90, 1.00)
const COLOUR_DISABLED: Color = Color(0.70, 0.15, 0.15)

## Which seat the camera belongs to. Only affects whether that player's hand is drawn face-up;
## the board itself is never rotated to put the viewer at player 0, because player ids stay
## absolute all the way up from ocgcore (see `EventTranslator`'s note on player ids).
@export var viewer_player: int = 0

## Hot seat: both hands belong to the same person, so both are readable.
##
## Off by default, because a networked client must never see the opposing hand - that is
## invariant V7, and the only honest place to enforce it is `HostService`, which blanks the code
## before the event ever leaves the host. This flag is a *view* decision about cards the viewer
## is already entitled to see, not a peek past the filter: a card the model reports as code 0
## still draws as a back, here as everywhere.
@export var reveal_both_hands: bool = false

var _anchors: Node3D = null
var _table: MeshInstance3D = null
var _default_field_texture: Texture2D = null
var _active_field_code: int = 0
var _pool: CardPool = null

## Parent of the zone outlines. A separate node from `ZoneAnchors` on purpose: `anchor_names()`
## walks the anchors' children and is the vocabulary L3 and L4 share, so a marker must never be
## able to appear in it.
var _markers: Node3D = null

## anchor -> `ZoneRole`. Also the set of anchors that have a marker at all.
var _marker_roles: Dictionary = {}

## `ZoneRole` -> `StandardMaterial3D`, plus one shared highlight material. Shared, so highlighting
## is a pointer swap and never allocates.
var _role_materials: Dictionary = {}
var _highlight_material: StandardMaterial3D = null
var _disabled_material: StandardMaterial3D = null

## anchor -> true for every currently highlighted zone.
var _highlighted: Dictionary = {}

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
# Zone markers
# ----------------------------------------------------------------------------------------------

## Lights up every named zone and turns off every zone not named. One call sets the whole state,
## so a caller never has to remember what it lit last time.
##
## Accepts the same anchor grammar as everything else, aliases included: `PZ_P0_0` lights the
## spell & trap zone it actually is. An anchor with no marker - a hand, a player, a typo - warns
## once and is skipped, never crashes (V13's spirit).
func highlight_zones(anchors: PackedStringArray) -> void:
	_ensure_built()

	var wanted: Dictionary = {}
	for anchor: String in anchors:
		var resolved: String = _alias(anchor)
		if _marker_roles.has(resolved):
			wanted[resolved] = true
		elif not _warned_anchors.has(anchor):
			_warned_anchors[anchor] = true
			push_warning("[BoardView] \"%s\" has no zone marker; not highlighting it" % anchor)

	_highlighted = wanted
	for anchor: Variant in _marker_roles:
		_paint_marker(str(anchor))


func clear_highlights() -> void:
	highlight_zones(PackedStringArray())


## Every zone that has an outline, in creation order.
func zone_marker_names() -> PackedStringArray:
	_ensure_built()
	var names: PackedStringArray = PackedStringArray()
	for child: Node in _markers.get_children():
		names.append(child.name)
	return names


## World transform of a zone outline as it is actually built, read off the node rather than
## recomputed, so a check against `anchor_transform()` measures the geometry instead of
## re-stating the intent. Identity for an anchor with no marker.
func zone_marker_transform(anchor: String) -> Transform3D:
	_ensure_built()
	var marker: Node = _markers.get_node_or_null(NodePath(anchor))
	if marker is MeshInstance3D:
		return (marker as MeshInstance3D).global_transform
	return Transform3D.IDENTITY


## The role a zone outline was drawn with, or `-1` when the anchor has no marker.
func zone_marker_role(anchor: String) -> int:
	_ensure_built()
	return int(_marker_roles.get(anchor, -1))


## The zones currently lit, in creation order.
func highlighted_zones() -> PackedStringArray:
	_ensure_built()
	var names: PackedStringArray = PackedStringArray()
	for child: Node in _markers.get_children():
		if _highlighted.has(str(child.name)):
			names.append(child.name)
	return names


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


## Lights exactly the cards the pending selection is offering, and unlights everything else.
##
## Takes the whole set rather than one card at a time so there is no way to leave a stale rim
## burning on a card from a decision that is already made - the common shape of this bug.
func highlight_cards(handles: PackedInt32Array) -> void:
	var wanted: Dictionary = {}
	for handle: int in handles:
		wanted[handle] = true

	for key: Variant in _occupants.keys():
		for entry: Variant in (_occupants[key] as Array):
			var view: CardView = entry as CardView
			if view != null:
				view.set_highlighted(wanted.has(view.handle))


## Puts every card out. Called whenever a selection is answered.
func clear_card_highlights() -> void:
	highlight_cards(PackedInt32Array())


func set_card_indicator(handle: int, type: String) -> void:
	var view: CardView = view_by_handle(handle)
	if view != null:
		view.set_indicator(type)


func clear_card_indicator(handle: int) -> void:
	var view: CardView = view_by_handle(handle)
	if view != null:
		view.clear_indicator()


func clear_card_indicators() -> void:
	for key: Variant in _occupants.keys():
		for entry: Variant in (_occupants[key] as Array):
			var view: CardView = entry as CardView
			if view != null:
				view.clear_indicator()


func set_card_chain_number(handle: int, number: int) -> void:
	var view: CardView = view_by_handle(handle)
	if view != null:
		view.set_chain_number(number)


func clear_card_chain_numbers() -> void:
	for key: Variant in _occupants.keys():
		for entry: Variant in (_occupants[key] as Array):
			var view: CardView = entry as CardView
			if view != null:
				view.clear_chain_number()


## Marks zones as disabled (field-disabled bitmask from ocgcore).
## The u32 flag: low 16 = player 0, high 16 = player 1.
## Per player: bits 0-4 = MZ 0-4, bits 5-6 = EMZ 0-1, bits 8-12 = ST 0-4, bit 13 = FZ.
func set_disabled_zones(flag: int) -> void:
	_ensure_built()
	if _disabled_material == null:
		_disabled_material = _make_marker_material(COLOUR_DISABLED)
	for player: int in range(DuelEnums.PLAYER_COUNT):
		var bits: int = (flag >> (player * 16)) & 0xFFFF
		for seq: int in range(DuelEnums.MAIN_MONSTER_ZONES):
			_set_zone_disabled("MZ_P%d_%d" % [player, seq], (bits & (1 << seq)) != 0)
		for seq: int in range(DuelEnums.EXTRA_MONSTER_ZONES):
			_set_zone_disabled("EMZ_P%d_%d" % [player, seq], (bits & (1 << (5 + seq))) != 0)
		for seq: int in range(DuelEnums.SPELL_TRAP_ZONES):
			_set_zone_disabled("ST_P%d_%d" % [player, seq], (bits & (1 << (8 + seq))) != 0)
		_set_zone_disabled("FZ_P%d" % player, (bits & (1 << 13)) != 0)


func _set_zone_disabled(anchor: String, disabled: bool) -> void:
	var marker: Node = _markers.get_node_or_null(NodePath(anchor))
	if marker is MeshInstance3D:
		var mi: MeshInstance3D = marker as MeshInstance3D
		if disabled:
			mi.material_override = _disabled_material
			mi.visible = true
		elif not _highlighted.has(anchor):
			var role: int = int(_marker_roles.get(anchor, -1))
			mi.material_override = _role_materials.get(role) as StandardMaterial3D
			mi.visible = false


## Offers the art cache to every card currently on the board.
##
## Cheap enough to call every frame: `CardView.refresh_art()` compares against the texture it
## already has and only writes the material when that changed. This is how a card that was drawn
## before its face finished decoding picks the face up a few frames later, without anything
## having to track which loads are outstanding.
func refresh_art(art: CardArt) -> void:
	for key: Variant in _occupants.keys():
		for entry: Variant in (_occupants[key] as Array):
			var view: CardView = entry as CardView
			if view != null:
				view.refresh_art(art)


## The view showing a card, without detaching it. `null` when nothing on the board is bound to
## that handle.
##
## This is what the card preview reads. Asking the **view** rather than the model is the whole
## safety argument: a `CardView` already carries 0 for anything the viewer is not allowed to
## see, so a preview built from it cannot reveal more than the board does. Judging visibility a
## second time, from `DuelCard.is_face_up()` and a seat, would be a second chance to get it
## wrong - and getting it wrong means showing a face-down card to the player it is hidden from.
func view_by_handle(handle: int) -> CardView:
	if handle == 0:
		return null
	for key: Variant in _occupants.keys():
		for entry: Variant in (_occupants[key] as Array):
			var view: CardView = entry as CardView
			if view != null and view.handle == handle:
				return view
	return null


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
## Whether a card parked at this anchor is ever drawn turned sideways.
##
## Only a monster is. ocgcore represents a **set** spell or trap as `FACEDOWN_DEFENSE`, because
## `position` is one field shared by every card type - so reading the defence bit straight into
## a rotation lays every set spell and trap on its side in its zone. A real one sits upright.
##
## Decided by the zone rather than by the card's type because the zone is what the view already
## knows, and because it stays right for anything unusual that ends up in a spell zone.
static func zone_turns(anchor: String) -> bool:
	return not (anchor.begins_with(ANCHOR_SPELL_PREFIX) or anchor.begins_with(ANCHOR_FIELD_PREFIX))


func apply_face(view: CardView, face: String, anchor: String = "") -> void:
	if view == null:
		return
	var turns: bool = zone_turns(anchor)
	if face == EventTranslator.FACE_UP_ATTACK:
		view.set_orientation(true, false)
	elif face == EventTranslator.FACE_DOWN_ATTACK:
		view.set_orientation(false, false)
	elif face == EventTranslator.FACE_UP_DEFENSE:
		view.set_orientation(true, turns)
	elif face == EventTranslator.FACE_DOWN_DEFENSE:
		view.set_orientation(false, turns)
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

	_update_field_spell_bg(state)


func _update_field_spell_bg(state: DuelState) -> void:
	if _table == null:
		return
	var field_code: int = 0
	for player: int in range(DuelEnums.PLAYER_COUNT):
		var card: DuelCard = state.field_zone[player] as DuelCard
		if card != null and card.is_face_up() and card.code != 0:
			field_code = card.code
			break
	if field_code == _active_field_code:
		return
	_active_field_code = field_code
	var mat: StandardMaterial3D = _table.material_override as StandardMaterial3D
	if mat == null:
		return
	if field_code != 0 and CardView.art_source != null:
		var art_tex: Texture2D = CardView.art_source.texture_for(field_code)
		if art_tex != null:
			mat.albedo_texture = art_tex
			mat.albedo_color = Color(1.0, 1.0, 1.0, 0.6)
			return
	mat.albedo_texture = _default_field_texture
	mat.albedo_color = Color.WHITE if _default_field_texture != null else FELT_COLOUR


func _sync_zone(slot: Variant, anchor: String) -> void:
	var card: DuelCard = slot as DuelCard
	if card == null:
		return
	var view: CardView = _pool.acquire()
	if view == null:
		return
	view.set_card_id(card.code if card.is_face_up() else 0)
	view.handle = card.handle
	view.set_orientation(card.is_face_up(), card.is_defense() and zone_turns(anchor))
	place_view(view, anchor)

	if card.is_face_up() and (card.type & DuelEnums.TYPE.MONSTER) != 0:
		view.set_stats(card.attack, card.defense, card.base_attack, card.base_defense)
	else:
		view.clear_stats()

	if card.is_face_up() and (card.type & DuelEnums.TYPE.PENDULUM) != 0 \
			and card.lscale > 0:
		view.set_pendulum_scales(card.lscale, card.rscale)
	else:
		view.clear_pendulum_scales()

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
		var revealed: bool = (reveal_both_hands or player == viewer_player) and card.code != 0
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
	_default_field_texture = _load_field_texture()
	if _default_field_texture != null:
		felt.albedo_texture = _default_field_texture
		felt.albedo_color = Color.WHITE
	else:
		felt.albedo_color = FELT_COLOUR
	felt.roughness = 0.92
	_table.material_override = felt

	_anchors = Node3D.new()
	_anchors.name = "ZoneAnchors"
	add_child(_anchors)
	_build_anchors()

	_markers = get_node_or_null("ZoneMarkers") as Node3D
	if _markers == null:
		_markers = Node3D.new()
		_markers.name = "ZoneMarkers"
		add_child(_markers)
	_build_zone_markers()

	_pool = get_node_or_null("CardPool") as CardPool
	if _pool == null:
		_pool = CardPool.new()
		_pool.name = "CardPool"
		add_child(_pool)


func _load_field_texture() -> Texture2D:
	var path: String = ProjectSettings.globalize_path(FIELD_TEXTURE_PATH)
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.new()
	if image.load(path) != OK:
		return null
	return ImageTexture.create_from_image(image)


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
# Zone marker construction
# ----------------------------------------------------------------------------------------------

## One outline per playable zone, for both seats. Hands, the player anchors and NOWHERE get
## none: nothing is "placed" there in the sense a zone outline means.
##
## The four meshes and four materials are built once here and handed to every marker that wants
## them, so the node count is the only thing that grows with the board.
func _build_zone_markers() -> void:
	_marker_roles.clear()
	_highlighted.clear()
	for child: Node in _markers.get_children():
		_markers.remove_child(child)
		child.queue_free()

	_role_materials = {
		ZoneRole.MONSTER: _make_marker_material(COLOUR_MONSTER),
		ZoneRole.SPELL_TRAP: _make_marker_material(COLOUR_SPELL_TRAP),
		ZoneRole.PILE: _make_marker_material(COLOUR_PILE),
	}
	_highlight_material = _make_marker_material(COLOUR_HIGHLIGHT)

	# A closed frame, an open-cornered frame and four corner brackets. Built at the full zone
	# footprint and shared by every marker of that role.
	var meshes: Dictionary = {
		ZoneRole.MONSTER: _marker_mesh(ZoneRole.MONSTER, ZONE_SIZE),
		ZoneRole.SPELL_TRAP: _marker_mesh(ZoneRole.SPELL_TRAP, ZONE_SIZE),
		ZoneRole.PILE: _marker_mesh(ZoneRole.PILE, ZONE_SIZE),
	}
	# The fourth: player 1's share of the two shared extra monster zones. See ZONE_SHARED_INSET.
	var inset_size: Vector2 = ZONE_SIZE - Vector2(ZONE_SHARED_INSET, ZONE_SHARED_INSET) * 2.0
	var inset_extra_monster: ArrayMesh = _marker_mesh(ZoneRole.MONSTER, inset_size)

	for player: int in range(DuelEnums.PLAYER_COUNT):
		for sequence: int in range(DuelEnums.MAIN_MONSTER_ZONES):
			_add_marker("MZ_P%d_%d" % [player, sequence], meshes[ZoneRole.MONSTER])
		for sequence: int in range(DuelEnums.EXTRA_MONSTER_ZONES):
			_add_marker("EMZ_P%d_%d" % [player, sequence],
				inset_extra_monster if player == 1 else meshes[ZoneRole.MONSTER])
		for sequence: int in range(DuelEnums.SPELL_TRAP_ZONES):
			_add_marker("ST_P%d_%d" % [player, sequence], meshes[ZoneRole.SPELL_TRAP])
		_add_marker("FZ_P%d" % player, meshes[ZoneRole.SPELL_TRAP])
		_add_marker("GY_P%d" % player, meshes[ZoneRole.PILE])
		_add_marker("BANISH_P%d" % player, meshes[ZoneRole.PILE])
		_add_marker("DECK_P%d" % player, meshes[ZoneRole.PILE])
		_add_marker("EXTRA_P%d" % player, meshes[ZoneRole.PILE])


## Seats one outline on the anchor of the same name.
##
## The transform is **copied off the `Marker3D`**, never recomputed. That is the whole reason
## this cannot drift: `_build_anchors()` owns the arithmetic, and a marker is only ever a reader
## of its result. The single adjustment is a lift along the anchor's local +Z, which is the
## direction `_flat_basis()` points at the sky.
func _add_marker(anchor: String, mesh: ArrayMesh) -> void:
	var seat: Marker3D = _anchors.get_node_or_null(NodePath(anchor)) as Marker3D
	if seat == null:
		push_warning("[BoardView] no anchor \"%s\" to put a zone marker on" % anchor)
		return

	var role: int = _role_of(anchor)
	var marker: MeshInstance3D = MeshInstance3D.new()
	marker.name = anchor
	marker.mesh = mesh
	marker.transform = seat.transform.translated_local(Vector3(0.0, 0.0, MARKER_LIFT))
	# A 2 mm flat outline has nothing to cast and nothing worth lighting. Both off on a mobile
	# target is the difference between free and not.
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_markers.add_child(marker)

	_marker_roles[anchor] = role
	_paint_marker(anchor)


## Anchor grammar -> role. Monster zones and extra monster zones hold monsters; the spell & trap
## zones and the field zone hold spells and traps; everything else with an outline is a pile.
func _role_of(anchor: String) -> int:
	if anchor.begins_with("MZ_P") or anchor.begins_with("EMZ_P"):
		return ZoneRole.MONSTER
	if anchor.begins_with("ST_P") or anchor.begins_with("FZ_P"):
		return ZoneRole.SPELL_TRAP
	return ZoneRole.PILE


## Points one marker at the shared material its current state calls for. No material is created
## here, which is what keeps highlighting free.
func _paint_marker(anchor: String) -> void:
	var marker: MeshInstance3D = _markers.get_node_or_null(NodePath(anchor)) as MeshInstance3D
	if marker == null:
		return
	marker.material_override = (
		_highlight_material if _highlighted.has(anchor)
		else _role_materials[_marker_roles.get(anchor, ZoneRole.PILE)])


## Unlit, like the card faces, and for the same reason: an outline is a painted marking on a
## playmat, not a lit surface. Shading it would make the far half of the board dimmer than the
## near half, and "is that zone legal" is not a question a player should answer by squinting.
func _make_marker_material(colour: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	# The outline lies in the anchor's XY plane with its normal at the sky. Both seats look at
	# it from above, but a camera that dips below the table edge would otherwise see it vanish.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


## The geometry for one role, centred on the origin and lying in local XY - the same plane a
## `CardView`'s quad occupies, because both are seated on the same anchor basis.
##
## Role is shape, not just colour:
##
##   MONSTER      a closed frame. The row that matters most reads as a solid slot.
##   SPELL_TRAP   the same frame with its corners open. Same footprint, unmistakably not a
##                monster zone even in a greyscale screenshot.
##   PILE         four corner brackets and nothing between them. A well, not a slot - which is
##                what a graveyard or a deck is.
func _marker_mesh(role: int, size: Vector2) -> ArrayMesh:
	var vertices: PackedVector3Array = PackedVector3Array()
	match role:
		ZoneRole.MONSTER:
			_append_frame(vertices, size, MARKER_BORDER_MONSTER, 1.0)
		ZoneRole.SPELL_TRAP:
			_append_frame(vertices, size, MARKER_BORDER_SPELL, MARKER_DASH_RATIO)
		_:
			_append_corners(vertices, size, MARKER_BORDER_PILE, MARKER_CORNER_RATIO)

	var normals: PackedVector3Array = PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3(0.0, 0.0, 1.0))

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Four border bars. `ratio` is how much of each side the bar actually covers, centred: 1.0 is a
## closed frame, anything less leaves the corners open.
func _append_frame(out: PackedVector3Array, size: Vector2, thickness: float, ratio: float) -> void:
	var half: Vector2 = size * 0.5
	var span_x: float = half.x * ratio
	var span_y: float = (half.y - thickness) * ratio

	_append_quad(out, -span_x, -half.y, span_x, -half.y + thickness)
	_append_quad(out, -span_x, half.y - thickness, span_x, half.y)
	_append_quad(out, -half.x, -span_y, -half.x + thickness, span_y)
	_append_quad(out, half.x - thickness, -span_y, half.x, span_y)


## Four L-shaped corner brackets. `ratio` is the arm length as a fraction of the side it runs
## along, so it has to stay under 0.5 or opposite brackets meet and the shape stops reading as
## corners.
func _append_corners(out: PackedVector3Array, size: Vector2, thickness: float, ratio: float) -> void:
	var half: Vector2 = size * 0.5
	var arm: Vector2 = size * ratio

	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			var corner: Vector2 = Vector2(half.x * sx, half.y * sy)
			# The horizontal arm runs the full way into the corner; the vertical one starts
			# where it ends, so the corner square is covered exactly once.
			_append_span(out, corner, Vector2(-arm.x * sx, -thickness * sy))
			_append_span(out,
				corner + Vector2(0.0, -thickness * sy),
				Vector2(-thickness * sx, -(arm.y - thickness) * sy))


## A rectangle in local XY at z = 0, as two triangles. Winding is irrelevant: these materials
## disable culling.
func _append_quad(out: PackedVector3Array, min_x: float, min_y: float, max_x: float, max_y: float) -> void:
	var a: Vector3 = Vector3(min_x, min_y, 0.0)
	var b: Vector3 = Vector3(max_x, min_y, 0.0)
	var c: Vector3 = Vector3(max_x, max_y, 0.0)
	var d: Vector3 = Vector3(min_x, max_y, 0.0)
	out.append_array([a, b, c, a, c, d])


## Same thing, expressed as a corner plus a signed extent, which is how the bracket arms are
## easiest to state. The extent may run either way; `_append_quad` is handed a normalised
## rectangle regardless.
func _append_span(out: PackedVector3Array, corner: Vector2, extent: Vector2) -> void:
	var other: Vector2 = corner + extent
	_append_quad(out,
		minf(corner.x, other.x), minf(corner.y, other.y),
		maxf(corner.x, other.x), maxf(corner.y, other.y))


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
