extends RefCounted

## Art resolution for every full-screen menu: which background cut to hang behind it, how to
## build the stone slab a row is drawn on, which face to letter it in, and the dark panel that
## keeps dense content legible on top of all that.
##
## Everything here is `static`. This script owns no state, enters no scene tree and is never
## instantiated - a screen preloads it and assigns what it returns. Keeping the decisions out of
## the scene is what lets `ui_test.gd` ask each of them directly, with no window, no screen and
## no rendered frame.
##
## It lives in `game/ui/` and not in `game/ui/main_menu/` because three screens wear this dress -
## the menu, the deck picker and the controls table - and a file three siblings share is not one
## sibling's property. The one device question in it, the screen's orientation, is asked here and
## nowhere else; see `background_for_orientation()` and the grep in `ui_test.gd` that holds it.
##
## Layer: L5 shell, same as the screens. It knows about files and about one device property. It
## knows nothing about a duel, a scene or the core.


# ----------------------------------------------------------------------------------------------
# The background
# ----------------------------------------------------------------------------------------------

## The same temple, cut twice. Neither is ever stretched to the other's aspect - the whole point
## of having both is that `KEEP_ASPECT_COVERED` then has very little left to crop.
const BACKGROUND_PORTRAIT := preload("res://ui/art/menu/background-menu-v.jpeg")
const BACKGROUND_LANDSCAPE := preload("res://ui/art/menu/background-menu-h.jpeg")


## Picks **which of the two background files to load**, from the device's physical screen
## orientation and from nothing else.
##
## This deliberately does not ask the viewport how big it is. ARCHITECTURE.md section 10 rule 4
## forbids a widget sizing itself from the screen, and `ui_test.gd` greps this directory for
## exactly that, because in VR this layer becomes a world-space quad whose pixel size is an
## arbitrary texture resolution - a layout that branched on it would stop meaning anything
## there. Choosing an *asset* from a device fact is a different act. It selects a file; it
## never selects a size, a position or a number of columns. The layout below is identical
## whichever texture comes back, so on a headset the branch is harmless: the display server
## reports a landscape screen, the landscape cut is loaded, and nothing else changes.
##
## The orientation arrives as an argument rather than being read in here, so the decision can
## be exercised for every orientation without a screen attached.
static func background_for_orientation(orientation: int) -> Texture2D:
	var portrait: bool = (
		orientation == DisplayServer.SCREEN_PORTRAIT
		or orientation == DisplayServer.SCREEN_REVERSE_PORTRAIT
		or orientation == DisplayServer.SCREEN_SENSOR_PORTRAIT
	)
	return BACKGROUND_PORTRAIT if portrait else BACKGROUND_LANDSCAPE


## The device fact itself, in one place, so there is exactly one call site to find if the
## question ever needs asking differently.
static func current_background() -> Texture2D:
	return background_for_orientation(DisplayServer.screen_get_orientation())


# ----------------------------------------------------------------------------------------------
# The slab
# ----------------------------------------------------------------------------------------------

const SLAB_RESTING := preload("res://ui/art/menu/frame-menu.png")
const SLAB_PRESSED := preload("res://ui/art/menu/frame-menu-active.png")

## Nine-patch margins, in source pixels, measured off the two bitmaps rather than guessed.
## Order is left, top, right, bottom.
##
## `frame-menu.png` is 1223x555. Its carved edge is an outer stone rim roughly 55 px deep, then
## a dark groove whose inner lip sits at x=67 / y=64 / x=1153 / y=479 on the four sides. The
## groove's corners are a rounded rectangle of radius ~45 px, so the curve is not finished
## until about 105 px in from each edge - traced by walking the groove row by row, its left lip
## is still moving at y=90 and settled by y=100. The margins are the furthest of those plus a
## few pixels of slack, so a whole corner always lands inside a corner patch and is never
## touched by the stretch.
##
## `frame-menu-active.png` is 1220x560 - a slightly different crop of the same slab - and its
## gold band sits at x=49..62 / y=54.. / x=1160..1165 / ..y=500, with its arc settled by y=110.
## Hence the marginally larger numbers. They are measured per file for that reason; do not
## share one set between the two.
const SLAB_RESTING_MARGINS: Array[int] = [112, 108, 115, 120]
const SLAB_PRESSED_MARGINS: Array[int] = [115, 112, 115, 118]

## How far the slab bitmap is resampled down before it becomes a nine-patch.
##
## A nine-patch margin is a count of *source* pixels that is also drawn at that many *screen*
## pixels - the border slices are never scaled. The carved border here is ~110 px deep on each
## side, so 108+120 = 228 px of vertical border would have to fit inside a menu row that is
## about 130 px tall. It does not, and the slices would overlap into nonsense.
##
## Resampling the whole bitmap once, at load, and scaling the margins by the same factor fixes
## that properly: the border is still sampled from the border and still drawn 1:1 against its
## own texels, so it stays sharp, and only the flat middle of the stone takes the stretch. At
## 0.26 the resting slab becomes 318x144 with a 29/28/30/31 border, which leaves daylight
## inside `MainMenu.SLAB_MIN_HEIGHT`; `slab_border_height()` is the number that has to stay
## under it, and `ui_test.gd` holds that.
const SLAB_SCALE := 0.26

## Padding between the carved edge and the word on the slab, in drawn pixels.
const SLAB_CONTENT_MARGIN_X := 24.0
const SLAB_CONTENT_MARGIN_Y := 8.0


## Builds one state of the slab as a `StyleBoxTexture`, resampled and with its nine-patch
## margins scaled to match. See `SLAB_SCALE` for why the resample is not optional.
static func slab_box(texture: Texture2D, margins: Array[int], scale: float = SLAB_SCALE) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.content_margin_left = SLAB_CONTENT_MARGIN_X
	box.content_margin_right = SLAB_CONTENT_MARGIN_X
	box.content_margin_top = SLAB_CONTENT_MARGIN_Y
	box.content_margin_bottom = SLAB_CONTENT_MARGIN_Y

	var image: Image = texture.get_image()
	if image == null:
		box.texture = texture
		return box

	image = image.duplicate() as Image
	# An imported texture can arrive VRAM-compressed depending on the renderer; `resize()` only
	# works on an uncompressed image.
	if image.is_compressed():
		if image.decompress() != OK:
			box.texture = texture
			return box

	var width: int = maxi(1, roundi(float(image.get_width()) * scale))
	var height: int = maxi(1, roundi(float(image.get_height()) * scale))
	image.resize(width, height, Image.INTERPOLATE_LANCZOS)

	box.texture = ImageTexture.create_from_image(image)
	box.texture_margin_left = float(roundi(float(margins[0]) * scale))
	box.texture_margin_top = float(roundi(float(margins[1]) * scale))
	box.texture_margin_right = float(roundi(float(margins[2]) * scale))
	box.texture_margin_bottom = float(roundi(float(margins[3]) * scale))
	return box


## The two states a menu row has: resting stone, and the same stone with its groove lit.
static func resting_slab() -> StyleBoxTexture:
	return slab_box(SLAB_RESTING, SLAB_RESTING_MARGINS)


static func pressed_slab() -> StyleBoxTexture:
	return slab_box(SLAB_PRESSED, SLAB_PRESSED_MARGINS)


## The drawn depth of the carved border, top plus bottom, for whichever of the two states needs
## the most of it. A menu row shorter than this has no middle left for the nine-patch to
## stretch and its border slices start overlapping each other - so this is the hard floor under
## `MainMenu.SLAB_MIN_HEIGHT`, not a style preference.
static func slab_border_height(scale: float = SLAB_SCALE) -> int:
	var resting: int = roundi(float(SLAB_RESTING_MARGINS[1]) * scale) + roundi(float(SLAB_RESTING_MARGINS[3]) * scale)
	var pressed: int = roundi(float(SLAB_PRESSED_MARGINS[1]) * scale) + roundi(float(SLAB_PRESSED_MARGINS[3]) * scale)
	return maxi(resting, pressed)


# ----------------------------------------------------------------------------------------------
# The font
# ----------------------------------------------------------------------------------------------

## Papyrus - the face the menu art was drawn around - as macOS ships it.
const PAPYRUS_SYSTEM_PATH := "/System/Library/Fonts/Supplemental/Papyrus.ttc"


## Resolves the face the menu letters its words in, returning `null` for "whatever the theme
## already has".
##
## Papyrus is a **licensed Apple system font**. It is read from the operating system when the
## machine running the game happens to have it, and it is never copied into this repository and
## never added to an export preset: putting that file inside an APK would be redistributing a
## font we do not hold the rights to. The project is already careful about this elsewhere - see
## `data/base/sounds/CREDITS.md`.
##
## So it is a nicety on a development Mac and nothing more. Every caller must cope with `null`,
## and the menu is completely usable when it gets one - same words, same slabs, same tap
## targets, only the engine's default face instead of the carved one.
##
## If Papyrus is wanted on Android, somebody has to licence a face they may redistribute and
## add it deliberately. That is the maintainer's call; it is not something to quietly paper
## over with a lookalike bundled here.
##
## The path is an argument so a test can prove the fallback by passing one that does not exist.
static func menu_font(path: String = PAPYRUS_SYSTEM_PATH) -> Font:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	# `load_dynamic_font()` reports OK for anything it can read, so the result has to be
	# checked rather than trusted: a `FontFile` wrapped around something that is not a font
	# renders as blank glyphs, which is strictly worse than the engine default.
	var face := FontFile.new()
	if face.load_dynamic_font(path) != OK or face.get_face_count() < 1:
		return null
	# Papyrus ships as a `.ttc` collection of two faces, and the one Godot selects by default is
	# Condensed, not the one the art was drawn with. Pick by style name rather than by index:
	# the order inside an Apple system collection is not ours to depend on.
	var chosen: int = 0
	for index: int in range(face.get_face_count()):
		face.set_face_index(0, index)
		if face.get_font_style_name() == "Regular":
			chosen = index
			break
	face.set_face_index(0, chosen)
	return face


# ----------------------------------------------------------------------------------------------
# Dressing a screen
# ----------------------------------------------------------------------------------------------

## Every slab is at least this tall. Well above the 48 px a thumb needs, and above the carved
## border the slab's nine-patch draws at `SLAB_SCALE` - that second floor is the one that is easy
## to forget: below the border's own depth the patch slices would overlap each other instead of
## framing anything. `slab_border_height()` is what it is checked against, and `ui_test.gd`
## checks it. It lives here rather than on any one screen so that a screen cannot quietly adopt a
## shorter floor than the art allows.
const SLAB_MIN_HEIGHT := 88

## The colour and size a word carved on a slab is lettered at.
const WORD_COLOR := Color(0.956863, 0.901961, 0.776471)
const WORD_SIZE := 30

## Laid over the background, under everything else. The temple is a photograph and text sitting
## straight on it is a coin toss; this is what makes the contrast a constant instead.
const SCRIM_COLOR := Color(0.0235294, 0.0196078, 0.0117647, 0.34902)


## Puts one word on one button and gives that button the slab's two carved states.
##
## `hover` gets the lit slab as well as `pressed`, which on a phone is simply never reached. The
## point is the reverse: nothing is said by hover that is not also said by a press, so a device
## with no pointer loses no information.
##
## `face` may be `null` - see `menu_font()`. The floor on the height is raised, never lowered, so
## a screen that wants a taller target keeps it.
static func dress_slab(
		button: Button,
		word: String,
		resting: StyleBox,
		pressed: StyleBox,
		face: Font = null,
		size: int = WORD_SIZE) -> void:
	if button == null:
		return
	button.text = word
	button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, float(SLAB_MIN_HEIGHT))
	# Across: explicit. Down: `Button` has no vertical text alignment because it always centres
	# its text in whatever the stylebox leaves it, so the symmetric content margins in
	# `slab_box()` are what actually keeps the word in the middle of the stone.
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.icon = null

	button.add_theme_stylebox_override("normal", resting)
	button.add_theme_stylebox_override("disabled", resting)
	button.add_theme_stylebox_override("hover", pressed)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", pressed)

	for slot: String in ["font_color", "font_hover_color", "font_pressed_color",
			"font_focus_color", "font_disabled_color"]:
		button.add_theme_color_override(slot, WORD_COLOR)
	button.add_theme_font_size_override("font_size", size)
	letter(button, face)


## Applies a resolved face to one widget, if there is one to apply. A null face is the documented
## fallback, not a failure - see `menu_font()`.
static func letter(widget: Control, face: Font) -> void:
	if widget == null or face == null:
		return
	widget.add_theme_font_override("font", face)


# ----------------------------------------------------------------------------------------------
# The panel dense content sits on
# ----------------------------------------------------------------------------------------------

## Deck counts, file paths and a two-column table of gestures are small text in quantity, and
## small text over a photograph of carved stone is unreadable at arm's length no matter how good
## the photograph is. The answer is not to drop the art on those screens - then they stop looking
## like the same game - but to put an opaque-enough slab of dark under the words.
##
## Opaque *enough*: at this alpha the temple is still visibly behind the panel, so the screen
## still reads as the menu's sibling, while the text is being contrasted against a near-black
## that does not move. The border is the same sandstone the slabs are lit with, so the panel
## looks placed rather than pasted.
const PANEL_FILL := Color(0.0470588, 0.0431373, 0.0352941, 0.898039)
const PANEL_BORDER := Color(0.521569, 0.431373, 0.254902, 0.705882)
const PANEL_RADIUS := 10
const PANEL_PADDING := 16.0


static func content_panel(padding: float = PANEL_PADDING) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = PANEL_FILL
	box.border_color = PANEL_BORDER
	box.set_border_width_all(1)
	box.set_corner_radius_all(PANEL_RADIUS)
	box.content_margin_left = padding
	box.content_margin_right = padding
	box.content_margin_top = padding
	box.content_margin_bottom = padding
	return box
