class_name VirtualCardList
extends ScrollContainer

## A scrollable list of cards that instantiates a screenful of rows, not a list-ful.
##
## Layer: **L4/L5 widget**. It is handed plain Dictionaries and a `CardArt`; it never looks a
## card up and never names the native core (V1).
##
## -------------------------------------------------------------------------------------------
## Why this exists at all
## -------------------------------------------------------------------------------------------
## The card pool is 14 595 entries. A `VBoxContainer` with one `Button` per entry is roughly
## 60 000 `Control` nodes once each row's icon and two labels are counted. On a phone that is
## seconds of stall on open, tens of megabytes of node overhead, and a layout pass over the
## whole list every time the search box changes. `ItemList` would avoid that but cannot hold an
## arbitrary row of child controls, and `Tree` brings a column model nobody here wants.
##
## So: the rows are a **pool**, sized to the viewport and no larger, and they are moved rather
## than created.
##
##   `_body`  a bare `Control` - not a container, so nothing fights the manual positions -
##            whose minimum height is `entries * ROW_HEIGHT`. That one number is what gives the
##            scrollbar its range and makes the scroll feel like a list of 14 595 things.
##   `_rows`  `ceil(viewport / ROW_HEIGHT) + OVERSCAN` buttons, reused. On every scroll each one
##            is re-bound to a different entry and moved to `index * ROW_HEIGHT`.
##
## The pool is grown when the widget gets taller and never shrunk: a row costs a few hundred
## bytes and churning them on every resize is the expensive half of what this class exists to
## avoid.
##
## -------------------------------------------------------------------------------------------
## ARCHITECTURE.md section 10 rule 4
## -------------------------------------------------------------------------------------------
## The pool size comes from **this widget's own height**, handed to it by its parent container -
## never from the screen. That distinction is the whole rule: in VR this becomes a `SubViewport`
## on a quad whose pixel height has nothing to do with any display, and a widget that had sized
## its pool from the window would allocate the wrong number of rows there. `size.y` is correct
## in both worlds; a viewport or window query is correct in neither.
##
## -------------------------------------------------------------------------------------------
## Thumbnails
## -------------------------------------------------------------------------------------------
## `CardArt.texture_for()` never blocks: it answers out of its cache or answers null and queues
## a decode. Only the rows actually on screen ever ask, so scrolling past 14 595 cards requests
## a few dozen faces, not 14 595. A row that got null keeps its placeholder and `_process` tries
## again while the cache still has work outstanding - and stops polling the moment it does not.

## Emitted when a row is tapped. The editor decides what that means; this widget does not know
## whether it is a catalogue or a deck list.
signal activated(code: int)

## Row height in layout units. Everything about the virtualisation is derived from it, so it is
## a constant rather than a measurement: a row whose height depended on its content would make
## the scroll range unknowable without measuring all 14 595 of them.
const ROW_HEIGHT: int = 48

## Rows kept beyond the visible range, one above and one below, so a half-scrolled row is
## already bound instead of popping in.
const OVERSCAN: int = 2

## Hard ceiling on the pool, in case a layout bug hands this widget an absurd height.
const MAX_ROWS: int = 64

const ICON_SIZE: Vector2 = Vector2(30, 42)

const COLOR_TEXT: Color = Color(0.952941, 0.968627, 1.0, 1.0)
const COLOR_DIM: Color = Color(0.588235, 0.65098, 0.729412, 1.0)
const COLOR_ROW: Color = Color(0.113725, 0.133333, 0.168627, 1.0)
const COLOR_ROW_ACTIVE: Color = Color(0.180392, 0.227451, 0.309804, 1.0)
const COLOR_PLACEHOLDER: Color = Color(0.164706, 0.192157, 0.239216, 1.0)

const FONT_SIZE_NAME: int = 18
const FONT_SIZE_NOTE: int = 16

## Faces for the rows on screen. Optional: with no art on disk the rows show a flat placeholder
## and everything else still works.
var art: CardArt = null

## `{"code": int, "name": String, "note": String}`. `note` is the right-hand column - a copy
## count in a deck list, a type line in the catalogue - and may be empty.
var _entries: Array[Dictionary] = []

var _body: Control = null
var _rows: Array[Button] = []

## First entry index currently bound to `_rows[0]`, or -1 when nothing is bound. Used to skip
## the rebind when a scroll of two pixels did not change which entries are on screen.
var _first_bound: int = -1

## True while at least one visible row is still waiting for its face. Gates `_process`.
var _awaiting_art: bool = false

var _empty_label: Label = null
var _empty_text: String = "Nothing here."


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	clip_contents = true

	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_body)

	_empty_label = Label.new()
	_empty_label.name = "Empty"
	_empty_label.add_theme_color_override("font_color", COLOR_DIM)
	_empty_label.add_theme_font_size_override("font_size", FONT_SIZE_NOTE)
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_label.position = Vector2(8, 8)
	_empty_label.text = _empty_text
	_body.add_child(_empty_label)

	get_v_scroll_bar().value_changed.connect(_on_scrolled)
	resized.connect(_relayout)
	set_process(false)
	_relayout()


# ----------------------------------------------------------------------------------------------
# The public surface
# ----------------------------------------------------------------------------------------------

## Replaces the whole list. Cheap: it sets one minimum height and re-binds the rows on screen,
## whether `entries` holds three cards or fifteen thousand.
func set_entries(entries: Array[Dictionary]) -> void:
	_entries = entries
	_first_bound = -1
	# A filter that shortened the list can leave the scroll past the new end; the scrollbar
	# clamps itself once the minimum size is applied, and `_relayout` re-reads it.
	_relayout()


func entry_count() -> int:
	return _entries.size()


## The entry at `index`, or `{}`. Mostly for tests: it is the only way to see what a row is
## bound to without reaching into the pool.
func entry_at(index: int) -> Dictionary:
	return _entries[index] if index >= 0 and index < _entries.size() else {}


## What to show when the list is empty - "no cards match", "the side deck is empty".
func set_empty_text(text: String) -> void:
	_empty_text = text
	if _empty_label != null:
		_empty_label.text = text


## Rows currently instantiated. The whole point of this class is that this stays small; the
## editor's self-check asserts on it.
func pooled_rows() -> int:
	return _rows.size()


## Index of the first entry bound to a row, or -1.
func first_bound() -> int:
	return _first_bound


## Scrolls so that `index` is at the top. Used after adding a card, to show where it went.
##
## The scrollbar's range is pushed out first. `_body`'s minimum height only reaches the bar on
## the engine's next layout pass, and until it does the bar clamps any value past its stale
## maximum back to where it was - so a scroll requested in the same frame as the entries were
## set would silently do nothing. Widening the range here is harmless: the layout pass
## recomputes it from the real content either way.
func scroll_to(index: int) -> void:
	var bar: VScrollBar = get_v_scroll_bar()
	bar.max_value = maxf(bar.max_value, float(_entries.size() * ROW_HEIGHT))
	bar.value = clampf(float(maxi(0, index) * ROW_HEIGHT), 0.0, bar.max_value)
	_relayout()


# ----------------------------------------------------------------------------------------------
# Virtualisation
# ----------------------------------------------------------------------------------------------

func _on_scrolled(_value: float) -> void:
	_relayout()


func _relayout() -> void:
	if _body == null:
		return

	_body.custom_minimum_size.y = float(_entries.size() * ROW_HEIGHT)
	_empty_label.visible = _entries.is_empty()

	# The widget's own height, handed down by its parent container. Never the screen's.
	var visible_rows: int = int(ceil(maxf(size.y, float(ROW_HEIGHT)) / float(ROW_HEIGHT)))
	var wanted: int = clampi(visible_rows + OVERSCAN, 1, MAX_ROWS)
	_grow_pool(wanted)

	# The scrollbar, not `scroll_vertical`: the property is a view onto the same value but is
	# clamped against a range that lags a frame behind `_body`'s minimum size. See `scroll_to`.
	var offset: float = get_v_scroll_bar().value
	var first: int = maxi(0, int(floor(offset / float(ROW_HEIGHT))) - 1)
	_bind_from(first)


## Rows are only ever added. See the header: recycling beats churning.
func _grow_pool(wanted: int) -> void:
	while _rows.size() < wanted:
		var row: Button = _make_row(_rows.size())
		_rows.append(row)
		_body.add_child(row)
		_first_bound = -1


func _bind_from(first: int) -> void:
	var width: float = maxf(_body.size.x, size.x)

	for i: int in _rows.size():
		var row: Button = _rows[i]
		var index: int = first + i

		if index >= _entries.size():
			row.visible = false
			continue

		var entry: Dictionary = _entries[index]
		row.visible = true
		row.position = Vector2(0.0, float(index * ROW_HEIGHT))
		row.size = Vector2(width, float(ROW_HEIGHT))
		row.set_meta("code", int(entry.get("code", 0)))

		var name_label: Label = row.get_node("Row/Name") as Label
		var note_label: Label = row.get_node("Row/Note") as Label
		name_label.text = str(entry.get("name", ""))
		note_label.text = str(entry.get("note", ""))

		_apply_face(row, int(entry.get("code", 0)))

	_first_bound = first
	set_process(_awaiting_art)


## Asks the cache, takes whatever it has, and remembers whether anything is still outstanding.
func _apply_face(row: Button, code: int) -> void:
	var face: TextureRect = row.get_node("Row/Face") as TextureRect
	if art == null or code <= 0:
		face.texture = null
		return

	var texture: Texture2D = art.texture_for(code)
	face.texture = texture
	if texture == null:
		art.request(code)
		_awaiting_art = true


## Runs only while a face is outstanding. `CardArt` has no "a face arrived" signal, so the rows
## on screen are re-asked each frame until none of them is still waiting.
func _process(_delta: float) -> void:
	_awaiting_art = false
	for row: Button in _rows:
		if row.visible:
			_apply_face(row, int(row.get_meta("code", 0)))
	if not _awaiting_art:
		set_process(false)


# ----------------------------------------------------------------------------------------------
# One row
# ----------------------------------------------------------------------------------------------

func _make_row(index: int) -> Button:
	var row: Button = Button.new()
	row.name = "Row%d" % index
	row.focus_mode = Control.FOCUS_NONE
	row.add_theme_stylebox_override("normal", _row_style(COLOR_ROW))
	row.add_theme_stylebox_override("hover", _row_style(COLOR_ROW_ACTIVE))
	row.add_theme_stylebox_override("pressed", _row_style(COLOR_ROW_ACTIVE))
	row.add_theme_stylebox_override("focus", _row_style(COLOR_ROW))
	row.pressed.connect(_on_row_pressed.bind(row))

	var box: HBoxContainer = HBoxContainer.new()
	box.name = "Row"
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 8.0
	box.offset_right = -8.0
	box.offset_top = 3.0
	box.offset_bottom = -3.0
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(box)

	var face: TextureRect = TextureRect.new()
	face.name = "Face"
	face.custom_minimum_size = ICON_SIZE
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_SCALE
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A flat panel behind the face, so a card whose art has not arrived is a card-shaped gap
	# rather than nothing at all.
	var backing: Panel = Panel.new()
	backing.name = "Backing"
	backing.set_anchors_preset(Control.PRESET_FULL_RECT)
	backing.show_behind_parent = true
	backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backing.add_theme_stylebox_override("panel", _row_style(COLOR_PLACEHOLDER))
	face.add_child(backing)
	box.add_child(face)

	var name_label: Label = Label.new()
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_color_override("font_color", COLOR_TEXT)
	name_label.add_theme_font_size_override("font_size", FONT_SIZE_NAME)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var note_label: Label = Label.new()
	note_label.name = "Note"
	note_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	note_label.add_theme_color_override("font_color", COLOR_DIM)
	note_label.add_theme_font_size_override("font_size", FONT_SIZE_NOTE)
	note_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(note_label)

	return row


func _on_row_pressed(row: Button) -> void:
	var code: int = int(row.get_meta("code", 0))
	if code > 0:
		activated.emit(code)


static func _row_style(colour: Color) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = colour
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 0.0
	style.content_margin_right = 0.0
	style.content_margin_top = 0.0
	style.content_margin_bottom = 0.0
	return style
