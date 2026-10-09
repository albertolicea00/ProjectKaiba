class_name DuelHud
extends CanvasLayer

## What a duel in progress looks like to the person playing it, on a phone held upright: both
## life point totals, the turn number and whose turn it is, the current phase, how many cards
## are left in each pile, whatever the duel is asking for right now, and - while a battle is
## resolving - the numbers the battle is being decided by.
##
## Layer: L5 shell (AGENTS.md section 4). It reads `DuelState` and nothing else - no core, no
## transport, no rules (V1, V3) - and it never writes to the model.
##
## Three calls drive it, and nothing else does:
##
##     hud.bind(state)                              # once, when the duel starts
##     hud.refresh()                                # whenever the model may have moved
##     hud.set_prompt(selection.pending_prompt())   # whenever the pending selection changed
##
## `set_combat()` is a fourth, optional one: a scene that knows an attack is resolving can hand
## over the two cards involved, and passing `null` puts the readout away again.
##
## ------------------------------------------------------------------------------------------
## The portrait layout
## ------------------------------------------------------------------------------------------
## The screen is tall and narrow, so the furniture is pushed to the four corners and the middle
## third is left to the board:
##
##     top-left      opponent's avatar, with their life points on a slanted plate beside it
##     top-centre    the turn line, the phase chip, and whose turn it is
##     top-right     the menu button
##     board edges   a count badge for each seat's deck, extra deck and graveyard
##     centre        the phase banner (on a change) and the battle readout (during one)
##     bottom-right  your avatar, with your life plate above it
##     bottom        `HandZone`, which is deliberately empty
##
## `HandZone` holds nothing and draws nothing. It is the strip the 3D hand is fanned across,
## reserved here so that it is one named rect a test can check nothing else has wandered into.
## Covering the hand is the failure mode a portrait HUD falls into, and a widget that has to
## grow can then be seen to collide with it instead of quietly sitting on top of it.
##
## ------------------------------------------------------------------------------------------
## Why nothing in this file measures the screen - ARCHITECTURE.md section 10, rule 4
## ------------------------------------------------------------------------------------------
## No widget may ask the viewport or the window how large it is in order to decide anything:
## not a layout, not a font size, not an "is this a phone" branch. Everything in the scene is
## anchors, containers and size flags, and the project's `canvas_items` stretch mode does the
## scaling. Portrait makes this tempting - "if it is narrow, stack the top row" - and the answer
## is still no: the stack is unconditional and the anchors hold it together.
##
## The reason is VR, and honouring it costs nothing today. In Phase 7 this whole CanvasLayer is
## re-instantiated inside a `SubViewport` painted on a quad floating above the table. That
## viewport's pixel size is an arbitrary texture resolution picked for legibility at arm's
## length; it has no relation to any screen and no aspect ratio worth branching on. Code that
## sized itself from those numbers would be silently wrong there and would have to be rewritten
## - which is the rewrite rule 4 exists to prevent.
##
## So if this HUD ever looks wrong at some resolution, the fix is an anchor, a size flag or a
## container. Never a measurement. Please do not "fix" it by reading the screen dimensions.
##
## ------------------------------------------------------------------------------------------
## The slanted life plates, with no texture to slant
## ------------------------------------------------------------------------------------------
## `StyleBoxFlat.skew` leans the drawn box without touching its children, so the plate is a
## parallelogram and the number inside it stays upright and legible. The coloured edge bar is
## the same box's border: one side is given a width and the other three are left at zero, so
## only that edge is drawn. The two seats use the same two tricks with the sign of the skew and
## the side of the bar flipped, which is what makes them read as mirrored rather than as two
## different widgets. No image file is involved, which matters because this repo ships none.
##
## ------------------------------------------------------------------------------------------
## Rolling life points
## ------------------------------------------------------------------------------------------
## `DuelState` holds the current total and only that. What was on screen a moment ago is this
## HUD's business, so the previous value lives here and the label travels to the new one rather
## than snapping - a 2000 point hit should be visible as an event, not as a different number.

## Seconds a life point change takes to finish rolling. Long enough to read as a change, short
## enough that the HUD is never meaningfully behind the model.
const ROLL_SECONDS: float = 0.45

## Floor on the roll speed, in life points per second, so that a 100 point cost still ticks
## instead of resolving within a frame.
const MIN_ROLL_SPEED: float = 400.0

## How long the centre banner holds a phase change, and how much of that is spent fading out.
## It is an announcement, not a readout: the phase chip at the top is the thing that stays.
const BANNER_SECONDS: float = 1.5
const BANNER_FADE_SECONDS: float = 0.6

## Stand-in for a field there is no model to fill in yet.
const EMPTY: String = "-"

## Opacity of the seat that is not taking its turn.
const DIM_INACTIVE: float = 0.5

## `DuelEnums.PHASE` is a bit flag, never an ordinal, so this is a lookup and not an index.
## Phases the player never sees separately (the battle sub-steps) are still named, because a
## HUD that goes blank mid-battle reads as a bug.
const PHASE_NAMES: Dictionary = {
	DuelEnums.PHASE.DRAW: "Draw phase",
	DuelEnums.PHASE.STANDBY: "Standby phase",
	DuelEnums.PHASE.MAIN1: "Main phase 1",
	DuelEnums.PHASE.BATTLE_START: "Battle phase",
	DuelEnums.PHASE.BATTLE_STEP: "Battle step",
	DuelEnums.PHASE.DAMAGE: "Damage step",
	DuelEnums.PHASE.DAMAGE_CAL: "Damage calculation",
	DuelEnums.PHASE.BATTLE: "Battle phase",
	DuelEnums.PHASE.MAIN2: "Main phase 2",
	DuelEnums.PHASE.END: "End phase",
}

@onready var _top_panel: Control = $Root/TopSeat
@onready var _top_seat: Label = $Root/TopSeat/Life/Box/Seat
@onready var _top_life: Label = $Root/TopSeat/Life/Box/Life
@onready var _top_tag: Label = $Root/TopSeat/Avatar/Tag
@onready var _bottom_panel: Control = $Root/BottomSeat
@onready var _bottom_seat: Label = $Root/BottomSeat/Life/Box/Seat
@onready var _bottom_life: Label = $Root/BottomSeat/Life/Box/Life
@onready var _bottom_tag: Label = $Root/BottomSeat/Avatar/Tag

@onready var _turn_label: Label = $Root/TurnStack/Count
@onready var _phase_label: Label = $Root/TurnStack/ChipRow/PhaseChip/Phase
@onready var _owner_label: Label = $Root/TurnStack/Owner
@onready var _menu_button: Button = $Root/Menu

@onready var _top_deck: Label = $Root/TopPiles/Deck/Count
@onready var _top_extra: Label = $Root/TopPiles/Extra/Count
@onready var _top_grave: Label = $Root/TopPiles/Grave/Count
@onready var _bottom_deck: Label = $Root/BottomPiles/Deck/Count
@onready var _bottom_extra: Label = $Root/BottomPiles/Extra/Count
@onready var _bottom_grave: Label = $Root/BottomPiles/Grave/Count

@onready var _banner_panel: PanelContainer = $Root/PhaseBanner
@onready var _banner_label: Label = $Root/PhaseBanner/Text

@onready var _combat_panel: PanelContainer = $Root/Combat
@onready var _combat_attacker: Label = $Root/Combat/Box/Attacker
@onready var _combat_defender: Label = $Root/Combat/Box/Defender

@onready var _prompt_panel: PanelContainer = $Root/Prompt
@onready var _prompt_label: Label = $Root/Prompt/Body/Text
@onready var _prompt_confirm: Button = $Root/Prompt/Body/Actions/Confirm
@onready var _prompt_cancel: Button = $Root/Prompt/Body/Actions/Cancel

## Which seat belongs to the person holding the device. `DuelState` does not know and should not
## - it is a board model, not a client - so it is configuration here. A hot seat duel leaves it
## at P0 and reads "You" for the bottom half of the board, which is where P0 sits.
var local_player: int = DuelEnums.PLAYER.P0:
	set(value):
		local_player = clampi(value, 0, DuelEnums.PLAYER_COUNT - 1)
		refresh()

var _state: DuelState = null
var _prompt: String = ""

## Raised when the player answers the pending prompt from the HUD rather than from a gesture.
##
## These exist because `CONFIRM` had **no touch binding at all**: `TouchSource` never called it
## and nothing on screen did either, so on a phone there was no way to say yes to
## `MSG_SELECT_YESNO`, no way to accept an optional effect, and no way to submit a multi-card
## selection. The duel simply parked.
##
## Buttons rather than a new gesture on purpose. A yes/no question deserves a visible yes and a
## visible no - hiding the only affirmative answer behind an undocumented flick would be a worse
## version of the same bug.
signal confirmed
signal cancelled

## Raised by the top-right button. Nothing in the duel scenes listens yet; the button is here
## because a phone has no Escape key and a duel with no way out of it is a worse omission than
## an unhandled signal.
signal menu_pressed

## Raised when the player clicks a phase button (BP, M2, EP). The command string matches what
## SelectionController expects: "to_bp", "to_m2", "to_ep".
signal phase_pressed(cmd: String)

## Life points as drawn, as the model has them, and how fast the first is chasing the second.
var _shown: Array[float] = [0.0, 0.0]
var _target: Array[int] = [0, 0]
var _speed: Array[float] = [0.0, 0.0]

## A fresh binding snaps instead of rolling: nobody wants to watch 8000 points count up from
## zero because the HUD was attached a frame late.
var _snap: bool = true

var _lp_bars: Array[ColorRect] = []
const LP_BAR_HEIGHT: float = 4.0
const LP_BAR_COLOUR_HIGH: Color = Color(0.2, 0.85, 0.3)
const LP_BAR_COLOUR_LOW: Color = Color(0.95, 0.2, 0.2)
const LP_BAR_MAX: int = 8000

## The phase the banner last announced, and how long the announcement has left to live. The
## phase is tracked rather than compared against the chip's text because two phase bits share
## the name "Battle phase" and a banner must not fire for a change the player cannot see.
var _announced_phase: int = 0
var _banner_time: float = 0.0


func _ready() -> void:
	set_process(false)
	_build_dynamic_badges()
	_build_lp_bars()
	refresh()
	_prompt_confirm.pressed.connect(func() -> void: confirmed.emit())
	_prompt_cancel.pressed.connect(func() -> void: cancelled.emit())
	_menu_button.pressed.connect(func() -> void: menu_pressed.emit())
	_build_phase_buttons()
	_paint_prompt()


# ----------------------------------------------------------------------------------------------
# The whole public surface
# ----------------------------------------------------------------------------------------------

## Points the HUD at a duel. Passing `null` is legal and blanks it; that is what a HUD built
## before its duel exists should show.
func bind(state: DuelState) -> void:
	_state = state
	_snap = true
	# The phase the duel is already in is not a change, so binding mid-duel must not raise a
	# banner for it. Armed from here on.
	_announced_phase = state.phase if state != null else 0
	_banner_time = 0.0
	refresh()


## Re-reads the model. Cheap enough to call every frame and idempotent, so a caller that cannot
## tell whether anything changed should just call it.
func refresh() -> void:
	if not is_node_ready():
		return
	_refresh_life()
	_refresh_turn()
	_refresh_phase()
	_refresh_piles()


## The pending prompt, verbatim from `SelectionController.pending_prompt()`. An empty string
## means nothing is being asked, and the prompt gets out of the way rather than showing a stale
## question.
func set_prompt(text: String) -> void:
	_prompt = text
	if not is_node_ready():
		return
	_paint_prompt()


## The two cards a battle is being decided between. `defender` may be `null`, which is a direct
## attack; `attacker` may be `null`, which puts the readout away.
##
## The readout is centred rather than pinned over the attacking monster. Pinning it there would
## mean projecting a world position into screen space inside a widget, which is the measurement
## ARCHITECTURE.md section 10 rule 4 forbids and which has no meaning at all once this layer is
## a quad in VR. See the report in `_combat_line()` for what the model would have to expose for
## a better answer.
func set_combat(attacker: DuelCard, defender: DuelCard) -> void:
	if not is_node_ready():
		return
	if attacker == null:
		_combat_panel.visible = false
		_combat_attacker.text = ""
		_combat_defender.text = ""
		return
	_combat_panel.visible = true
	_combat_attacker.text = _combat_line(attacker)
	_combat_defender.text = "DIRECT ATTACK" if defender == null else "vs  %s" % _combat_line(defender)


const LP_POPUP_SECONDS: float = 1.2
const LP_POPUP_DRIFT: float = 60.0


func show_lp_change(player: int, amount: int) -> void:
	if not is_node_ready() or amount == 0:
		return
	var anchor: Control = _bottom_panel if player == local_player else _top_panel
	if anchor == null:
		return
	var popup: Label = Label.new()
	popup.text = "%+d" % amount
	popup.add_theme_font_size_override("font_size", 28)
	popup.add_theme_color_override("font_color",
		Color(0.3, 1.0, 0.3) if amount > 0 else Color(1.0, 0.3, 0.3))
	popup.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	popup.add_theme_constant_override("outline_size", 4)
	popup.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	popup.position = Vector2(anchor.size.x * 0.5 - 40, anchor.size.y * 0.5)
	anchor.add_child(popup)
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(popup, "position:y", popup.position.y - LP_POPUP_DRIFT, LP_POPUP_SECONDS)
	tween.tween_property(popup, "modulate:a", 0.0, LP_POPUP_SECONDS).set_delay(0.3)
	tween.chain().tween_callback(popup.queue_free)


## Finishes any running animation immediately: the life point roll lands on the model's total
## and the phase banner stops announcing. For a scene change, and for tests that would otherwise
## have to wait one out to read a number.
func settle() -> void:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		_shown[player] = float(_target[player])
	_banner_time = 0.0
	_paint_life()
	_paint_banner()
	set_process(false)


# ----------------------------------------------------------------------------------------------
# Readouts a test asks for rather than reaching into the node tree
#
# The previous version of the suite indexed `Root/Column/BottomRow/Prompt/Text` directly and
# broke the moment the panel grew a button row - a failure about the test's reach, not about the
# behaviour it was checking. Everything a case needs to assert on has an accessor here.
# ----------------------------------------------------------------------------------------------

func prompt_text() -> String:
	return _prompt_label.text if _prompt_label != null else ""


func prompt_is_visible() -> bool:
	return _prompt_panel != null and _prompt_panel.visible


func phase_banner_text() -> String:
	return _banner_label.text if _banner_label != null else ""


func phase_banner_is_visible() -> bool:
	return _banner_panel != null and _banner_panel.visible


func combat_is_visible() -> bool:
	return _combat_panel != null and _combat_panel.visible


func combat_text() -> String:
	if _combat_attacker == null or _combat_defender == null:
		return ""
	return "%s %s" % [_combat_attacker.text, _combat_defender.text]


## Count badge text for one seat's pile. `location` is a `DuelEnums.LOCATION`; anything this
## HUD draws no badge for returns an empty string rather than guessing.
func pile_text(player: int, location: int) -> String:
	var label: Label = _pile_label(player, location)
	return label.text if label != null else ""


# ----------------------------------------------------------------------------------------------
# Life points
# ----------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_advance_roll(delta)
	_advance_banner(delta)
	if not _is_animating():
		set_process(false)


## Separated from `_process` so the roll can be stepped deterministically from a test.
func _advance_roll(delta: float) -> void:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		_shown[player] = move_toward(_shown[player], float(_target[player]), _speed[player] * delta)
	_paint_life()


func _is_rolling() -> bool:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		if absf(_shown[player] - float(_target[player])) >= 0.5:
			return true
	return false


func _is_animating() -> bool:
	return _is_rolling() or _banner_time > 0.0


func _refresh_life() -> void:
	_top_seat.text = _seat_name(_opponent())
	_bottom_seat.text = _seat_name(local_player)
	_top_tag.text = _seat_tag(_opponent())
	_bottom_tag.text = _seat_tag(local_player)

	if _state == null:
		_top_life.text = EMPTY
		_bottom_life.text = EMPTY
		return

	for player: int in range(DuelEnums.PLAYER_COUNT):
		var value: int = _state.life_points[player]
		if _snap:
			_shown[player] = float(value)
			_speed[player] = 0.0
		elif value != _target[player]:
			_speed[player] = maxf(MIN_ROLL_SPEED, absf(float(value) - _shown[player]) / ROLL_SECONDS)
		_target[player] = value

	_snap = false
	_paint_life()
	set_process(_is_animating())


func _paint_life() -> void:
	if _state == null:
		return
	_top_life.text = str(roundi(_shown[_opponent()]))
	_bottom_life.text = str(roundi(_shown[local_player]))
	_paint_lp_bars()


func _build_lp_bars() -> void:
	_lp_bars.resize(DuelEnums.PLAYER_COUNT)
	for player: int in range(DuelEnums.PLAYER_COUNT):
		var life_label: Label = _bottom_life if player == local_player else _top_life
		var box: Control = life_label.get_parent() as Control
		if box == null:
			continue
		var bar: ColorRect = ColorRect.new()
		bar.color = LP_BAR_COLOUR_HIGH
		bar.custom_minimum_size = Vector2(0, LP_BAR_HEIGHT)
		bar.size_flags_horizontal = Control.SIZE_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_END
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(bar)
		_lp_bars[player] = bar


func _paint_lp_bars() -> void:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		if player >= _lp_bars.size() or _lp_bars[player] == null:
			continue
		var bar: ColorRect = _lp_bars[player]
		var ratio: float = clampf(_shown[player] / float(LP_BAR_MAX), 0.0, 1.0)
		var parent: Control = bar.get_parent() as Control
		if parent != null:
			bar.size.x = parent.size.x * ratio
		bar.color = LP_BAR_COLOUR_HIGH.lerp(LP_BAR_COLOUR_LOW, 1.0 - ratio)


# ----------------------------------------------------------------------------------------------
# Turn and phase
# ----------------------------------------------------------------------------------------------

func _refresh_turn() -> void:
	if _state == null:
		_turn_label.text = EMPTY
		_owner_label.text = ""
		_top_panel.modulate.a = 1.0
		_bottom_panel.modulate.a = 1.0
		return

	if _state.is_finished:
		_turn_label.text = _result_text()
		_owner_label.text = ""
	elif _state.turn_count <= 0:
		# START has arrived but NEW_TURN has not: there is a first player, not yet a turn 1.
		_turn_label.text = "Duel start"
		_owner_label.text = ""
	else:
		_turn_label.text = "Turn %d - %s" % [_state.turn_count, _turn_owner_text()]
		_owner_label.text = _turn_owner_text()

	var active: bool = not _state.is_finished
	_top_panel.modulate.a = 1.0 if (active and _state.turn_player == _opponent()) else DIM_INACTIVE
	_bottom_panel.modulate.a = 1.0 if (active and _state.turn_player == local_player) else DIM_INACTIVE


func _refresh_phase() -> void:
	if _state == null or _state.phase == 0:
		_phase_label.text = EMPTY
		return
	_phase_label.text = _phase_text(_state.phase)

	if _state.phase != _announced_phase:
		_announced_phase = _state.phase
		_banner_time = BANNER_SECONDS
		_banner_label.text = _phase_label.text.to_upper()
		set_process(true)
	_paint_banner()


## Name of a phase bit. Falls back to the enum name rather than going blank: an unmapped phase
## is a HUD gap, and a raw `PHASE(512)` on screen says so out loud instead of hiding it (same
## spirit as V13).
func _phase_text(phase: int) -> String:
	if PHASE_NAMES.has(phase):
		return str(PHASE_NAMES[phase])
	return DuelEnums.phase_name(phase)


func _advance_banner(delta: float) -> void:
	if _banner_time <= 0.0:
		return
	_banner_time = maxf(0.0, _banner_time - delta)
	_paint_banner()


func _paint_banner() -> void:
	_banner_panel.visible = _banner_time > 0.0
	if not _banner_panel.visible:
		return
	_banner_panel.modulate.a = minf(1.0, _banner_time / BANNER_FADE_SECONDS)


func _turn_owner_text() -> String:
	return "your turn" if _state.turn_player == local_player else "opponent's turn"


func _result_text() -> String:
	if _state.winner == DuelEnums.PLAYER.NONE:
		return "Duel over - draw"
	return "Duel over - you win" if _state.winner == local_player else "Duel over - you lose"


func show_result(winner: int) -> void:
	if not is_node_ready():
		return
	var won: bool = winner == local_player
	var text: String = "YOU WIN" if won else ("YOU LOSE" if winner != DuelEnums.PLAYER.NONE else "DRAW")
	var colour: Color = Color(1.0, 0.85, 0.2) if won else Color(0.9, 0.3, 0.3)
	if winner == DuelEnums.PLAYER.NONE:
		colour = Color(0.7, 0.7, 0.8)

	var root: Control = get_node_or_null("Root") as Control
	if root == null:
		return
	var label: Label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.add_theme_font_size_override("font_size", 72)
	label.add_theme_color_override("font_color", colour)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 8)
	label.modulate.a = 0.0
	root.add_child(label)
	var tween: Tween = create_tween()
	tween.tween_property(label, "modulate:a", 1.0, 0.5)


# ----------------------------------------------------------------------------------------------
# Pile badges
#
# Counts, never contents. The deck is hidden information and `DuelState` holds face-down
# placeholders for it (see its header); the size of that array is the one thing about it that is
# public, which is exactly what a badge shows.
# ----------------------------------------------------------------------------------------------

## The three piles a badge is drawn for, and the prefix each one wears. The graveyard is the
## only one of the three whose count changes for a reason the player did not choose, which is
## why it is on the board edge next to the deck rather than tucked away with the avatars.
const PILE_BADGES: Array[Dictionary] = [
	{"loc": DuelEnums.LOCATION.DECK, "prefix": "DECK"},
	{"loc": DuelEnums.LOCATION.EXTRA, "prefix": "EX"},
	{"loc": DuelEnums.LOCATION.GRAVE, "prefix": "GY"},
	{"loc": DuelEnums.LOCATION.REMOVED, "prefix": "BAN"},
	{"loc": DuelEnums.LOCATION.HAND, "prefix": "HAND"},
]

var _dynamic_labels: Dictionary = {}


func _refresh_piles() -> void:
	for player: int in range(DuelEnums.PLAYER_COUNT):
		for badge: Dictionary in PILE_BADGES:
			var location: int = int(badge["loc"])
			var label: Label = _pile_label(player, location)
			if label == null:
				continue
			var prefix: String = str(badge["prefix"])
			if _state == null:
				label.text = "%s %s" % [prefix, EMPTY]
			else:
				label.text = "%s %d" % [prefix, _state.pile_for(player, location).size()]


## The badge belonging to a seat and a pile. The local seat's badges live on the near edge of
## the board and the opponent's on the far edge, so this is the same mirroring the avatars and
## the life plates use and it follows `local_player` for the same reason.
func _pile_label(player: int, location: int) -> Label:
	var row: String = "BottomPiles" if player == local_player else "TopPiles"
	var slot: String = ""
	match location:
		DuelEnums.LOCATION.DECK:
			slot = "Deck"
		DuelEnums.LOCATION.EXTRA:
			slot = "Extra"
		DuelEnums.LOCATION.GRAVE:
			slot = "Grave"
		_:
			var key: String = "%s_%d" % [row, location]
			return _dynamic_labels.get(key, null) as Label
	return get_node_or_null("Root/%s/%s/Count" % [row, slot]) as Label


func _build_dynamic_badges() -> void:
	for row_name: String in ["TopPiles", "BottomPiles"]:
		var container: HBoxContainer = get_node_or_null("Root/%s" % row_name) as HBoxContainer
		if container == null:
			continue
		for badge: Dictionary in [
			{"loc": DuelEnums.LOCATION.REMOVED, "prefix": "BAN"},
			{"loc": DuelEnums.LOCATION.HAND, "prefix": "HAND"},
		]:
			var location: int = int(badge["loc"])
			var panel: PanelContainer = PanelContainer.new()
			panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var style: StyleBoxFlat = StyleBoxFlat.new()
			style.content_margin_left = 10.0
			style.content_margin_top = 3.0
			style.content_margin_right = 10.0
			style.content_margin_bottom = 3.0
			style.bg_color = Color(0.035, 0.047, 0.067, 0.82)
			style.set_border_width_all(1)
			style.border_color = Color(0.353, 0.847, 1.0, 0.55)
			style.set_corner_radius_all(6)
			panel.add_theme_stylebox_override("panel", style)
			var label: Label = Label.new()
			label.name = "Count"
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			label.add_theme_color_override("font_color", Color(0.784, 0.859, 0.922))
			label.add_theme_font_size_override("font_size", 15)
			label.text = "%s %s" % [str(badge["prefix"]), EMPTY]
			panel.add_child(label)
			container.add_child(panel)
			_dynamic_labels["%s_%d" % [row_name, location]] = label


# ----------------------------------------------------------------------------------------------
# Battle readout
# ----------------------------------------------------------------------------------------------

## One card's side of the battle. `DuelCard` carries `attack` and `defense` as the engine last
## reported them, and `is_defense()` says which of the two the battle will actually use - so the
## number that decides the outcome is the one shown large, and the other is not shown at all.
##
## What is missing is a name: `DuelCard` holds `code`, and turning a passcode into a printed
## name needs `CardRegistry`, which this HUD is not given. The readout is therefore numbers
## only. Handing the HUD a registry, or putting the resolved name on `DuelCard`, is what would
## fix it - see the report.
func _combat_line(card: DuelCard) -> String:
	if card.is_defense():
		return "DEF %d" % card.defense
	return "ATK %d" % card.attack


# ----------------------------------------------------------------------------------------------
# Prompt
# ----------------------------------------------------------------------------------------------

func _paint_prompt() -> void:
	_prompt_label.text = _prompt
	_prompt_panel.visible = not _prompt.is_empty()


# ----------------------------------------------------------------------------------------------
# Phase buttons (EDOPro-style)
# ----------------------------------------------------------------------------------------------

const PHASE_BUTTON_LABELS: Dictionary = {
	"to_bp": "BP",
	"to_m2": "M2",
	"to_ep": "EP",
}

const PHASE_BUTTON_MIN: Vector2 = Vector2(64, 44)

var _phase_box: VBoxContainer = null
var _phase_buttons: Dictionary = {}


func _build_phase_buttons() -> void:
	_phase_box = VBoxContainer.new()
	_phase_box.name = "PhaseButtons"
	_phase_box.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_phase_box.offset_left = -82.0
	_phase_box.offset_right = -18.0
	_phase_box.offset_top = -80.0
	_phase_box.offset_bottom = 80.0
	_phase_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_phase_box.add_theme_constant_override("separation", 6)
	_phase_box.visible = false
	get_node("Root").add_child(_phase_box)

	for cmd: String in ["to_bp", "to_m2", "to_ep"]:
		var btn: Button = Button.new()
		btn.name = cmd
		btn.text = str(PHASE_BUTTON_LABELS.get(cmd, cmd))
		btn.custom_minimum_size = PHASE_BUTTON_MIN
		btn.add_theme_font_size_override("font_size", 18)
		btn.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))

		var pnormal: StyleBoxFlat = StyleBoxFlat.new()
		pnormal.bg_color = Color(0.08, 0.10, 0.18, 0.92)
		pnormal.border_color = Color(0.30, 0.55, 0.85, 0.5)
		pnormal.set_border_width_all(1)
		pnormal.set_corner_radius_all(6)
		pnormal.set_content_margin_all(6)
		btn.add_theme_stylebox_override("normal", pnormal)

		var phover: StyleBoxFlat = pnormal.duplicate() as StyleBoxFlat
		phover.bg_color = Color(0.14, 0.22, 0.38)
		phover.border_color = Color(0.40, 0.70, 1.0, 0.8)
		btn.add_theme_stylebox_override("hover", phover)

		var ppressed: StyleBoxFlat = pnormal.duplicate() as StyleBoxFlat
		ppressed.bg_color = Color(0.10, 0.16, 0.30)
		btn.add_theme_stylebox_override("pressed", ppressed)

		btn.pressed.connect(_on_phase_button.bind(cmd))
		_phase_box.add_child(btn)
		_phase_buttons[cmd] = btn


func _on_phase_button(cmd: String) -> void:
	phase_pressed.emit(cmd)


## Shows the phase buttons that match the available commands in the current selection.
## Pass an empty array to hide them.
func set_phase_commands(commands: Array[String]) -> void:
	if _phase_box == null:
		return
	if commands.is_empty():
		_phase_box.visible = false
		return
	for cmd: String in _phase_buttons:
		(_phase_buttons[cmd] as Button).visible = commands.has(cmd)
	_phase_box.visible = true


# ----------------------------------------------------------------------------------------------
# Seats
# ----------------------------------------------------------------------------------------------

func _opponent() -> int:
	return 1 - local_player


func _seat_name(player: int) -> String:
	return "You" if player == local_player else "Opponent"


## What goes in the avatar frame until there is art to put there. The repo ships no images on
## purpose, so the frame is a drawn box with the seat's number in it rather than a path to a
## file that does not exist - a placeholder that is honestly a placeholder.
func _seat_tag(player: int) -> String:
	return "P%d" % (player + 1)
