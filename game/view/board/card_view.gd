class_name CardView
extends Node3D

## One card on the table, at real-world scale.
##
## Layer: L4 (AGENTS.md section 4). Reads nothing. It is told what to be - a `card_id`, a face
## and a position - and it never asks anybody anything. **V1: this file must never name
## `KaibaCore`, `MsgParser` or anything under `native/`.**
##
## -------------------------------------------------------------------------------------------
## Scale
## -------------------------------------------------------------------------------------------
## A Yu-Gi-Oh! card is 59 mm x 86 mm. Those millimetres are Godot units here, because
## ARCHITECTURE.md section 10 rule 1 says the board is built at real-world scale from day one:
## a VR port that has to rescale the art is a full art redo. Do not "round up to something
## easier to work with".
##
## -------------------------------------------------------------------------------------------
## Orientation
## -------------------------------------------------------------------------------------------
## The card's own frame has the quad in local XY with the face normal along local +Z, the card's
## top edge along local +Y. Lying the card flat on the table is **not** this node's job: the
## zone anchor carries that part of the rotation (`BoardView` rotates every anchor so its local
## +Z points at the sky). This node contributes only the two rotations that belong to the card
## itself:
##
##   defense    90 degrees about local Z - the card turns sideways in its zone.
##   face-down  180 degrees about local Y - the card flips over, back side up.
##
## Composed as `R_z(defense) * R_y(face_down)`, so the Y flip happens first in the card's own
## frame and the Z turn after it. Getting that order backwards puts a face-down defense card's
## long edge along the wrong axis.
##
## The caller multiplies: `global_basis = anchor_basis * orientation()`.
##
## -------------------------------------------------------------------------------------------
## Art
## -------------------------------------------------------------------------------------------
## A face-up card wears its real face from `data/base/pics/cards/` when `CardArt` has one cached, and
## a flat colour derived from its `card_id` when it does not. Both paths are normal: `CardArt`
## never blocks on disk, so the first look-up of a card almost always answers `null` and the
## face arrives a frame or two later through `refresh_art()`. The placeholder colour is what
## stands in meanwhile, and it is also the permanent answer for a token or any other card with
## no file on disk.
##
## The visual is still resolved from `card_id` at the moment of use and stored nowhere below
## this layer (V11, V12) - `CardArt` is a cache keyed by `card_id`, not a visual bound to a
## model card. `art_source` is where a `CardArt` is handed in without changing `set_card_id()`,
## whose callers sit in files this change does not own.
##
## **A face-down card never carries a face.** Not "its face is rotated away from the camera" -
## the texture is taken off the material entirely whenever `face_up` is false or `card_id` is 0.
## Relying on the geometry would mean one careless `material_override`, one unlit shader or one
## 180-degree tween landing a frame early is enough to leak hidden information, and hidden
## information is the one thing a duel client cannot get wrong (V7).
##
## -------------------------------------------------------------------------------------------
## Picking
## -------------------------------------------------------------------------------------------
## The two quads have no collider, so nothing can be aimed at them. This node carries one
## `Area3D` holding a box the size of the card plus a margin, purely as a raycast target for
## `InputSource._pick()`.
##
## Two rules make it safe:
##
##   - It sits alone on `PICK_LAYER`. A pick ray masked to that layer cannot hit the table, the
##     felt, or anything a later phase puts in the world - only cards.
##   - Its layer follows `visible`, so a card parked in the `CardPool` is not pickable. A pooled
##     card still exists, still has a transform and would still answer a ray; a tap resolving to
##     a card that is not on the board is the kind of bug that only shows up as a silent
##     `MSG_RETRY` three selections later.
##
## This node still reads nothing and decides nothing (V1): it is a target, and whoever fires the
## ray is the one that owns the meaning of the hit.

## Card face, in metres. 59 mm x 86 mm. See the Scale note above.
const CARD_WIDTH: float = 0.059
const CARD_HEIGHT: float = 0.086

## Collision layer the pick volume lives on, and nothing else. Bit 1 (layer 2 in the inspector)
## leaves layer 1 free for whatever physics the world grows later; a pick query masks to exactly
## this value so it can never pick up a stray collider.
const PICK_LAYER: int = 1 << 1

## Grown around the card on every side so a fingertip that lands just past the edge still counts
## as a hit. 8 mm is roughly the gutter between two zones, so neighbouring cards still cannot
## overlap each other's volume.
const PICK_MARGIN: float = 0.008

## Thickness of the pick volume. Far larger than the card so a ray arriving at a grazing angle
## still passes through it, small enough that a card lying flat cannot be hit through the table.
const PICK_DEPTH: float = 0.006

## Separation between the front and back quads. A real card is about 0.3 mm; this is only here
## to keep the two faces out of each other's depth buffer.
const CARD_THICKNESS: float = 0.0004

## Reverse side. The classic brown/orange back, not a placeholder magenta: a face-down card is a
## normal game state and should not read as an error.
const BACK_COLOUR: Color = Color(0.42, 0.26, 0.14)

## How far the highlight border sticks out past the card edge, in metres. 4 mm reads as a rim
## at the rig's board distance without making a lit card look bigger than its zone.
const HIGHLIGHT_MARGIN: float = 0.004

## Behind the card, not in front: a rim that covered the art would make the one card you are
## being asked about the hardest one to read.
const HIGHLIGHT_DEPTH: float = -0.0012

const HIGHLIGHT_COLOUR: Color = Color(1.0, 0.86, 0.35, 1.0)

## A card whose `card_id` is 0 - face-down, or simply not revealed to this viewer. Not an error
## (see `EventTranslator`'s note on `card_id`), so it gets a neutral grey rather than a warning.
const UNKNOWN_COLOUR: Color = Color(0.55, 0.55, 0.58)

## Passcode of the card currently shown. `0` means "not revealed to this viewer".
## Stable identity of the card this view is currently showing, minted by `DuelState` and
## carried on the intent. `0` means "not bound to a model card".
##
## This is what makes one card followable: `card_id` cannot do it, because two copies in a
## hand share it and a face-down card reports 0.
var handle: int = 0

var card_id: int = 0

## False means the back is up.
var face_up: bool = false

## True means defense position: the card is turned 90 degrees in its zone.
var defense: bool = false

## The only face that ever changes. The back is the same for every card in the game, so it is
## built once and never touched again.
var _front_material: StandardMaterial3D = null

## Kept only so `set_opacity()` can reach it. Its colour is still never changed.
var _back_material: StandardMaterial3D = null

## 0 is invisible, 1 is the normal state. See `set_opacity()`.
var _opacity: float = 1.0

## The raycast target. See the Picking note above.
var _pick_area: Area3D = null

## One `QuadMesh` shared by every card ever created. Built once, on the first card; after that
## a `CardPool` can hand out hundreds of cards without allocating any geometry, which is half of
## why the pool can promise never to `load()` mid-animation.
static var _shared_mesh: QuadMesh = null

## One border quad for every card ever lit, same as the face mesh.
static var _highlight_mesh: QuadMesh = null

## The rim, built on first use. A card that is never offered never pays for one.
var _highlight: MeshInstance3D = null

## One `BoxShape3D` shared by every card, for the same reason as the mesh.
static var _shared_pick_shape: BoxShape3D = null

## Where every card looks for its face. Shared rather than per-instance because `set_card_id()`
## is called from `BoardView` and `AnimationDirector` with one argument and those files are not
## this change's to edit; a static keeps their call sites untouched and still gives every card
## the same cache, which is the only way an LRU budget means anything.
##
## `null` is a supported state, not an unconfigured one: with no `CardArt` set, every card falls
## back to its placeholder colour and the board behaves exactly as it did before art existed.
## That is what keeps the headless scenes - which have no reason to touch the disk - cheap.
static var art_source: CardArt = null

## The texture currently on the front material, or `null` for the placeholder colour. Kept so a
## `refresh_art()` on every card every frame is a comparison rather than a material write.
var _front_texture: Texture2D = null

var _stat_label: Label3D = null
var _indicator: Sprite3D = null
var _indicator_type: String = ""

const STAT_FONT_SIZE: int = 48
const STAT_LABEL_OFFSET: Vector3 = Vector3(0.0, -CARD_HEIGHT * 0.42, CARD_THICKNESS * 0.5 + 0.001)
const STAT_COLOUR_NORMAL: Color = Color(1.0, 1.0, 1.0)
const STAT_COLOUR_BOOSTED: Color = Color(0.3, 1.0, 0.3)
const STAT_COLOUR_REDUCED: Color = Color(1.0, 0.3, 0.3)

const INDICATOR_SIZE: float = 0.014
const INDICATOR_OFFSET: Vector3 = Vector3(
	CARD_WIDTH * 0.5 - 0.010, CARD_HEIGHT * 0.5 - 0.010, CARD_THICKNESS * 0.5 + 0.002)
const INDICATOR_PATH_PREFIX: String = "res://../data/base/textures/overlays/"
static var _indicator_textures: Dictionary = {}


func _init() -> void:
	_build()
	# `CardPool` acquires and releases cards by toggling `visible`, and it is not this node's
	# business to know that. Following the signal instead means any owner that hides a card
	# gets the collider turned off - and a half-finished fade undone - for free.
	visibility_changed.connect(_on_visibility_changed)


func _ready() -> void:
	_refresh_pickable()


## The two rotations a card owns, in the card's own frame. Multiply an anchor's basis by this to
## get the card's world basis. See the Orientation note above for why the order is fixed.
func orientation() -> Basis:
	return orientation_for(face_up, defense)


## The same rotation for a face this card is **not** wearing yet.
##
## An animation has to know the pose it is flying towards before it is allowed to put that face
## on the material: `set_orientation()` does both at once, and calling it early is how a
## face-down card gets a frame of its own artwork. Asking here costs nothing and changes
## nothing, which is the whole point.
static func orientation_for(is_face_up: bool, is_defense: bool) -> Basis:
	var turn: Basis = Basis.from_euler(Vector3(0.0, 0.0, (PI * 0.5) if is_defense else 0.0))
	var flip: Basis = Basis.from_euler(Vector3(0.0, 0.0 if is_face_up else PI, 0.0))
	return turn * flip


## Sets both orientation flags at once. It does not move the node: composing them with the
## anchor basis is the caller's business, which is what lets a tween interpolate towards the
## result instead of snapping to it.
func set_orientation(is_face_up: bool, is_defense: bool) -> void:
	face_up = is_face_up
	defense = is_defense
	# Turning a card face-down has to strip its face, not just rotate it away. See the Art note.
	_apply_front(art_source)


## Swaps which card this view shows. Cheap: it re-tints a material and, when `art_source` has
## the face cached, swaps the texture on it. A face that is not cached yet is queued by
## `CardArt` and arrives later through `refresh_art()`; this function never waits for it.
## Called at the moment of use, never cached below L4 (V11).
func set_card_id(value: int) -> void:
	card_id = value
	_apply_front(art_source)


## Re-reads the face for the card this view is already showing. The counterpart to `texture_for()`
## answering `null` on a cold cache: whoever owns the `CardArt` calls this on the cards on the
## board once a load has had time to land, and a card that was wearing a placeholder colour picks
## up its artwork without being re-placed or re-animated.
##
## Idempotent and cheap - no material is written unless the texture actually changed - so calling
## it on every visible card every frame is a supported way to use it.
func refresh_art(art: CardArt) -> void:
	_apply_front(art)
	_apply_back(art)


## Puts the real card back on the reverse side, once.
##
## Every card in the game shares one back, so this is a single texture that `CardArt` keeps
## outside its LRU - a back that got evicted under memory pressure would be absurd. The guard is
## not an optimisation: `refresh_art()` runs every frame for every card on the board, and
## writing an unchanged albedo on all of them sixty times a second is real work on a phone.
func _apply_back(art: CardArt) -> void:
	if _back_material == null or _back_material.albedo_texture != null:
		return
	if art == null:
		return
	var back: Texture2D = art.back_texture()
	if back == null:
		return
	_back_material.albedo_texture = back
	# The brown placeholder tinted the material; with a real image the albedo must be neutral or
	# the back comes out muddy.
	_back_material.albedo_color = Color.WHITE


## How solid this card is, 0 to 1. 1 is the normal state.
##
## Only destruction uses it: a monster that loses a battle burns out rather than sliding to the
## graveyard, and a fade is the only part of that which cannot be expressed as a transform.
##
## Alpha blending is **off** at full opacity and goes back off the moment the fade ends. A
## transparent surface on a mobile tiler is drawn in a separate, unsorted pass, and a hundred
## cards permanently in that pass to serve the one that is currently dying is exactly the kind
## of cost ARCHITECTURE.md section 9 is about.
func set_opacity(value: float) -> void:
	var clamped: float = clampf(value, 0.0, 1.0)
	if is_equal_approx(clamped, _opacity):
		return
	_opacity = clamped
	_apply_opacity(_front_material)
	_apply_opacity(_back_material)


func opacity() -> float:
	return _opacity


func describe() -> String:
	return "card %d %s%s" % [
		card_id,
		"up" if face_up else "down",
		" def" if defense else "",
	]


## True while a pick ray can hit this card. False for a card parked in the pool.
func is_pickable() -> bool:
	return _pick_area != null and _pick_area.collision_layer != 0


## The `Area3D` a pick ray reports as the collider. `InputSource` walks back up from it to this
## node; nothing else should need it.
func pick_area() -> Area3D:
	return _pick_area


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## Stand-in for `VisualRegistry.resolve()` (ARCHITECTURE.md section 9). Deterministic so the same
## card is the same colour in every duel and in every replay of it, and spread over the hue
## circle by the golden ratio so two cards drawn together rarely collide.
func _front_colour() -> Color:
	if card_id == 0:
		return UNKNOWN_COLOUR
	var hue: float = fposmod(float(card_id) * 0.6180339887498949, 1.0)
	return Color.from_hsv(hue, 0.45, 0.88)


## Puts the right thing on the front quad: the card's face if `art` has it, the placeholder
## colour otherwise. The albedo is forced to white under a texture because `StandardMaterial3D`
## multiplies the two, and leaving the per-card tint in place would wash every face a different
## shade of its own id.
func _apply_front(art: CardArt) -> void:
	if _front_material == null:
		return
	var texture: Texture2D = _face_texture(art)
	if texture == _front_texture:
		# Covers the common case of both being null: a face-down card refreshed every frame
		# writes nothing at all.
		if texture == null:
			_front_material.albedo_color = _tinted(_front_colour())
		return
	_front_texture = texture
	_front_material.albedo_texture = texture
	_front_material.albedo_color = _tinted(Color.WHITE if texture != null else _front_colour())


## Every albedo write goes through here so a card that is mid-fade cannot have its alpha undone
## by an unrelated `set_card_id()` or `refresh_art()`.
func _tinted(colour: Color) -> Color:
	return Color(colour.r, colour.g, colour.b, _opacity)


func _apply_opacity(material: StandardMaterial3D) -> void:
	if material == null:
		return
	material.transparency = (
		BaseMaterial3D.TRANSPARENCY_DISABLED if _opacity >= 1.0
		else BaseMaterial3D.TRANSPARENCY_ALPHA)
	material.albedo_color = _tinted(material.albedo_color)


## The face this card is allowed to show, or `null`.
##
## The two guards are the hidden-information rule, and they come first on purpose: a face-down
## card is never even asked for, so nothing can answer. `card_id == 0` is the same question from
## the other side - the viewer was not told what this card is - and the answer is the same.
func _face_texture(art: CardArt) -> Texture2D:
	if art == null or card_id == 0 or not face_up:
		return null
	return art.texture_for(card_id)


func _build() -> void:
	if _shared_mesh == null:
		_shared_mesh = QuadMesh.new()
		_shared_mesh.size = Vector2(CARD_WIDTH, CARD_HEIGHT)

	_front_material = _make_material(_front_colour())

	var front: MeshInstance3D = MeshInstance3D.new()
	front.name = "Front"
	front.mesh = _shared_mesh
	front.material_override = _front_material
	front.position = Vector3(0.0, 0.0, CARD_THICKNESS * 0.5)
	add_child(front)

	# Turned to face local -Z, so flipping the card 180 degrees about Y is what brings it up.
	_back_material = _make_material(BACK_COLOUR)
	var back: MeshInstance3D = MeshInstance3D.new()
	back.name = "Back"
	back.mesh = _shared_mesh
	back.material_override = _back_material
	back.position = Vector3(0.0, 0.0, -CARD_THICKNESS * 0.5)
	back.rotation = Vector3(0.0, PI, 0.0)
	add_child(back)

	_build_pick_volume()


## Lights this card as something the pending selection is offering.
##
## The point is that "there is something to do" should be visible without reading the prompt.
## A duel asks constantly and most of its questions are about one or two specific cards; making
## those cards glow turns a sentence into a glance.
func set_highlighted(on: bool) -> void:
	if not on and _highlight == null:
		return
	_ensure_highlight()
	_highlight.visible = on


func is_highlighted() -> bool:
	return _highlight != null and _highlight.visible


func set_stats(atk: int, def: int, base_atk: int, base_def: int) -> void:
	_ensure_stat_label()
	var atk_col: Color = _stat_colour(atk, base_atk)
	var def_col: Color = _stat_colour(def, base_def)
	if atk_col == STAT_COLOUR_NORMAL and def_col == STAT_COLOUR_NORMAL:
		_stat_label.text = "%d/%d" % [atk, def]
		_stat_label.modulate = STAT_COLOUR_NORMAL
	else:
		_stat_label.text = "%d/%d" % [atk, def]
		_stat_label.modulate = atk_col if atk_col != STAT_COLOUR_NORMAL else def_col
	_stat_label.visible = true


func clear_stats() -> void:
	if _stat_label != null:
		_stat_label.visible = false


func set_indicator(type: String) -> void:
	if type == _indicator_type and _indicator != null and _indicator.visible:
		return
	_ensure_indicator()
	var tex: Texture2D = _load_indicator_texture(type)
	if tex == null:
		_indicator.visible = false
		_indicator_type = ""
		return
	_indicator.texture = tex
	_indicator.visible = true
	_indicator_type = type


func clear_indicator() -> void:
	if _indicator != null:
		_indicator.visible = false
	_indicator_type = ""


func _ensure_indicator() -> void:
	if _indicator != null:
		return
	_indicator = Sprite3D.new()
	_indicator.name = "Indicator"
	_indicator.pixel_size = INDICATOR_SIZE / 128.0
	_indicator.position = INDICATOR_OFFSET
	_indicator.shaded = false
	_indicator.double_sided = false
	_indicator.no_depth_test = true
	_indicator.transparent = true
	_indicator.visible = false
	add_child(_indicator)


static func _load_indicator_texture(type: String) -> Texture2D:
	if _indicator_textures.has(type):
		return _indicator_textures[type] as Texture2D
	var path: String = ProjectSettings.globalize_path(INDICATOR_PATH_PREFIX + type + ".png")
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.new()
	if image.load(path) != OK:
		return null
	var tex: ImageTexture = ImageTexture.create_from_image(image)
	_indicator_textures[type] = tex
	return tex


func _stat_colour(current: int, base: int) -> Color:
	if current > base:
		return STAT_COLOUR_BOOSTED
	if current < base:
		return STAT_COLOUR_REDUCED
	return STAT_COLOUR_NORMAL


func _ensure_stat_label() -> void:
	if _stat_label != null:
		return
	_stat_label = Label3D.new()
	_stat_label.name = "Stats"
	_stat_label.pixel_size = 0.001
	_stat_label.font_size = STAT_FONT_SIZE
	_stat_label.outline_size = 8
	_stat_label.modulate = STAT_COLOUR_NORMAL
	_stat_label.outline_modulate = Color(0, 0, 0, 0.9)
	_stat_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stat_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_stat_label.position = STAT_LABEL_OFFSET
	_stat_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_stat_label.shaded = false
	_stat_label.double_sided = false
	_stat_label.no_depth_test = true
	_stat_label.visible = false
	add_child(_stat_label)


func _ensure_highlight() -> void:
	if _highlight != null:
		return
	if _highlight_mesh == null:
		_highlight_mesh = QuadMesh.new()
		_highlight_mesh.size = Vector2(
			CARD_WIDTH + HIGHLIGHT_MARGIN * 2.0, CARD_HEIGHT + HIGHLIGHT_MARGIN * 2.0)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = HIGHLIGHT_COLOUR
	# Emissive so it reads as lit rather than as a painted border, and so it survives a dim
	# board without the rest of the scene having to be brightened for it.
	material.emission_enabled = true
	material.emission = HIGHLIGHT_COLOUR
	material.emission_energy_multiplier = 1.6

	_highlight = MeshInstance3D.new()
	_highlight.name = "Highlight"
	_highlight.mesh = _highlight_mesh
	_highlight.material_override = material
	_highlight.position = Vector3(0.0, 0.0, HIGHLIGHT_DEPTH)
	_highlight.visible = false
	add_child(_highlight)


## The box a pick ray hits. It lives in the card's own frame - local XY is the face, local Z the
## thickness - so a defense card's volume turns with it and a face-down card's with it too,
## without this function knowing either rotation exists.
func _build_pick_volume() -> void:
	if _shared_pick_shape == null:
		_shared_pick_shape = BoxShape3D.new()
		_shared_pick_shape.size = Vector3(
			CARD_WIDTH + PICK_MARGIN * 2.0,
			CARD_HEIGHT + PICK_MARGIN * 2.0,
			PICK_DEPTH)

	var shape := CollisionShape3D.new()
	shape.name = "PickShape"
	shape.shape = _shared_pick_shape

	_pick_area = Area3D.new()
	_pick_area.name = "PickArea"
	# It is a target, never a sensor: it reports nothing, detects nothing and costs no overlap
	# bookkeeping. Only `intersect_ray` ever asks it anything.
	_pick_area.monitoring = false
	_pick_area.monitorable = false
	_pick_area.collision_mask = 0
	_pick_area.collision_layer = PICK_LAYER
	_pick_area.add_child(shape)
	add_child(_pick_area)


## A card going back to the pool must not take a half-finished fade with it.
##
## `CardPool.acquire()` resets the transform, the face and the id, which covers everything an
## animation can leave behind **except** opacity - and the pool has no business knowing that a
## card can be faded in the first place. Hooking the same signal the collider already follows
## keeps that knowledge here, where it belongs.
func _on_visibility_changed() -> void:
	_refresh_pickable()
	if not visible:
		set_opacity(1.0)
		clear_stats()
		clear_indicator()


## Layer `PICK_LAYER` while the card is on the board, layer 0 - which no query can match - while
## it is parked. Driven by `visibility_changed`, so the pool never has to know this exists.
func _refresh_pickable() -> void:
	if _pick_area == null:
		return
	var on_board: bool = visible and (not is_inside_tree() or is_visible_in_tree())
	_pick_area.collision_layer = PICK_LAYER if on_board else 0


## Unshaded on purpose. The board has one directional light, and a card face is already a
## finished, evenly lit image: shading it again only drags the printed artwork towards whatever
## the table lighting happens to be.
##
## `TEXTURE_FILTER_LINEAR` rather than the mipmapped default because `CardArt` does not generate
## mipmaps - see its memory note for why, and for the one-line change if the aliasing on a
## steeply angled card turns out to read badly.
func _make_material(colour: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_BACK
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return material
