extends SceneTree

## Self-checking tests for the duel HUD, the card preview, the main menu, the scene router, the
## board's zone markers and the card back.
##
##   godot --headless --path game --script res://ui/ui_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, so it can be wired into
## a Makefile target as a gate. Same shape as `core/duel/duel_state_test.gd`, no framework.
##
## ------------------------------------------------------------------------------------------
## Why the board and the art cache are tested from the UI suite
## ------------------------------------------------------------------------------------------
## `BoardView`'s zone markers and `CardArt.back_texture()` are not UI, and in a tidier world
## their checks would live beside `core/duel/duel_state_test.gd` and
## `core/registry/card_art_test.gd`. They are here because this is the suite that exists and
## adding a Makefile target was outside the change that wrote them. Both are headless-safe
## measurements of real state, which is the only property that actually matters for where they
## run. Move them when a `make test-ui` target appears.
##
## ------------------------------------------------------------------------------------------
## Cases that need `data/`
## ------------------------------------------------------------------------------------------
## `data/` is gitignored (AGENTS.md section 9), so a checkout with no artwork is a normal state.
## The card-back case prints SKIP and is not counted rather than reporting red for files it was
## never supposed to have - the same contract `core/registry/card_art_test.gd` uses.
##
## ------------------------------------------------------------------------------------------
## Why the work happens in `_process` and not in `_init`
## ------------------------------------------------------------------------------------------
## A node only becomes ready once the scene tree's own root is inside the tree, and that has not
## happened yet while `_init` or `_initialize` run: `root.add_child(n)` there leaves `n` with
## `is_inside_tree() == false` and `_ready()` never called. A HUD whose `@onready` references
## are still null would measure nothing, so the first `_process` is the earliest honest moment.
##
## ------------------------------------------------------------------------------------------
## What is deliberately not tested here
## ------------------------------------------------------------------------------------------
## The router's "solo" route is checked as a route - the path it names, that the file exists,
## that `go()` swaps to it - but the real `duel_touch.tscn` is never instantiated. It would
## create a `KaibaCore`, start a duel thread and need `data/base/cards.cdb`, none of which has
## anything to do with routing. `make touch` covers that scene.

const HudScript := preload("res://ui/hud/duel_hud.gd")
const HudScene := preload("res://ui/hud/duel_hud.tscn")
const MenuScript := preload("res://ui/main_menu/main_menu.gd")
const MenuScene := preload("res://ui/main_menu/main_menu.tscn")
const RouterScript := preload("res://platform/scene_router.gd")
const PreviewScene := preload("res://ui/preview/card_preview.tscn")

const HUD_TOP_LIFE := "Root/Column/TopRow/TopSeat/Box/Life"
const HUD_TOP_SEAT := "Root/Column/TopRow/TopSeat/Box/Seat"
const HUD_BOTTOM_LIFE := "Root/Column/BottomRow/BottomSeat/Box/Life"
const HUD_BOTTOM_SEAT := "Root/Column/BottomRow/BottomSeat/Box/Seat"
const HUD_TURN := "Root/Column/TopRow/Turn/Box/Count"
const HUD_PHASE := "Root/Column/TopRow/Turn/Box/Phase"
const HUD_PROMPT := "Root/Column/BottomRow/Prompt/Text"
const HUD_PROMPT_PANEL := "Root/Column/BottomRow/Prompt"

const MENU_BUTTONS := "Frame/Center/Column/Buttons"
const MENU_STATUS := "Frame/Center/Column/Status"

const UI_ROOT := "res://ui"

## Blue-Eyes White Dragon, as `KaibaCore.get_card_info()` returns it. Hand-built rather than
## looked up: V1 forbids anything under `game/ui/` from naming the core, and this file is under
## `game/ui/`. The values are the ones `make duel-real` prints for that passcode - LIGHT Dragon,
## level 8, 3000 / 2500 - so the fixture is a transcript, not an invention. Every key the C++
## `get_card_info()` can write is present, including the ones the preview deliberately ignores,
## so the preview is proved to tolerate the whole shape rather than a convenient subset.
static func blue_eyes() -> Dictionary:
	return {
		"code": 89631139,
		"name": "Blue-Eyes White Dragon",
		"desc": "This legendary dragon is a powerful engine of destruction.",
		"strings": PackedStringArray(["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""]),
		"type": DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.NORMAL,
		"level": 8,
		"attribute": DuelEnums.ATTRIBUTE.LIGHT,
		"race": DuelEnums.RACE.DRAGON,
		"attack": 3000,
		"defense": 2500,
		"lscale": 0,
		"rscale": 0,
		"link_marker": 0,
		"alias": 0,
		"ot": 3,
		"category": 0,
		"setcodes": PackedInt32Array(),
	}

## A Link monster, which is the shape the preview is most able to get wrong: the cdb's `def`
## column carries the marker bitmask instead of a defence, and `level` carries the link rating.
## Markers are TOP | LEFT | RIGHT - 0200 | 0010 | 0040 octal in `ocgapi_constants.h`, so 168.
static func link_monster() -> Dictionary:
	return {
		"code": 1861629,
		"name": "Test Link Dragon",
		"desc": "2+ monsters",
		"strings": PackedStringArray(),
		"type": DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.LINK,
		"level": 3,
		"attribute": DuelEnums.ATTRIBUTE.DARK,
		"race": DuelEnums.RACE.CYBERSE,
		"attack": 2300,
		"defense": 0,
		"lscale": 0,
		"rscale": 0,
		"link_marker": 128 | 8 | 32,
		"alias": 0,
		"ot": 3,
		"category": 0,
		"setcodes": PackedInt32Array(),
	}

## Pot of Greed. A spell, so every monster-only line has to disappear rather than read zero.
static func pot_of_greed() -> Dictionary:
	return {
		"code": 55144522,
		"name": "Pot of Greed",
		"desc": "Draw 2 cards.",
		"strings": PackedStringArray(),
		"type": DuelEnums.TYPE.SPELL,
		"level": 0,
		"attribute": 0,
		"race": 0,
		"attack": 0,
		"defense": 0,
		"lscale": 0,
		"rscale": 0,
		"link_marker": 0,
		"alias": 0,
		"ot": 3,
		"category": 0,
		"setcodes": PackedInt32Array(),
	}

## Decoded size of `data/base/pics/cover/classic/hd.jpg`, measured rather than assumed. RGB8, no mipmaps.
const BACK_SIZE := Vector2i(930, 1350)

var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0

var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true

	print("== DuelHud / CardPreview / MainMenu / SceneRouter / BoardView / CardArt tests ==")

	_case_hud_reads_the_model()
	_case_hud_rolls_life_points()
	_case_hud_knows_which_seat_is_yours()
	_case_hud_shows_the_pending_prompt()
	_case_hud_without_a_model()

	_case_preview_fills_itself_from_card_info()
	_case_preview_hides_what_a_spell_has_no_room_for()
	_case_preview_link_monster_has_markers_and_no_defence()
	_case_preview_without_card_data()

	_case_router_reaches_the_menu()
	_case_router_reaches_solo()
	_case_router_sends_unbuilt_destinations_home()
	_case_menu_offers_every_destination()

	_case_zone_markers_sit_on_their_anchors()
	_case_zone_markers_light_up()
	_case_card_back_is_outside_the_budget()

	_case_no_widget_measures_the_screen()
	_case_no_ui_file_names_the_core()

	print("== %d cases, %d failed ==" % [_cases_run, _cases_failed])
	quit(1 if _cases_failed > 0 else 0)
	return true


# ----------------------------------------------------------------------------------------------
# DuelHud
# ----------------------------------------------------------------------------------------------

func _case_hud_reads_the_model() -> void:
	_begin("hud reads life points, turn and phase out of DuelState")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_equal("your life points", _text(hud, HUD_BOTTOM_LIFE), "8000")
	_equal("opponent life points", _text(hud, HUD_TOP_LIFE), "7000")
	_equal("turn", _text(hud, HUD_TURN), "Turn 1 - your turn")
	_equal("phase", _text(hud, HUD_PHASE), "Main phase 1")

	# Every one of those came from the model, so moving the model moves the HUD.
	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.BATTLE})
	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P1})
	hud.refresh()

	_equal("phase after NEW_PHASE", _text(hud, HUD_PHASE), "Battle phase")
	_equal("turn after NEW_TURN", _text(hud, HUD_TURN), "Turn 2 - opponent's turn")

	_discard(hud)
	_end()


func _case_hud_rolls_life_points() -> void:
	_begin("hud rolls life points to the new total instead of snapping")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	state.apply({"t": DuelEnums.EV.DAMAGE, "player": DuelEnums.PLAYER.P0, "amount": 1500})
	hud.refresh()
	_equal("still on the old total the instant the model changed", _text(hud, HUD_BOTTOM_LIFE), "8000")

	hud._advance_roll(0.1)
	var midway: int = int(_text(hud, HUD_BOTTOM_LIFE))
	_check("rolling", midway > 6500 and midway < 8000, "midway value was %d" % midway)

	hud.settle()
	_equal("arrives at the model's total", _text(hud, HUD_BOTTOM_LIFE), "6500")
	_equal("the other seat never moved", _text(hud, HUD_TOP_LIFE), "7000")

	# A fresh binding snaps: nobody should watch 8000 count up because the HUD attached late.
	var fresh: HudScript = _hud()
	fresh.bind(state)
	_equal("a fresh bind snaps", _text(fresh, HUD_BOTTOM_LIFE), "6500")

	_discard(hud)
	_discard(fresh)
	_end()


func _case_hud_knows_which_seat_is_yours() -> void:
	_begin("hud labels the seats from local_player, which DuelState does not hold")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_equal("bottom seat", _text(hud, HUD_BOTTOM_SEAT), "You")
	_equal("top seat", _text(hud, HUD_TOP_SEAT), "Opponent")

	hud.local_player = DuelEnums.PLAYER.P1
	hud.settle()
	_equal("bottom life follows the seat", _text(hud, HUD_BOTTOM_LIFE), "7000")
	_equal("top life follows the seat", _text(hud, HUD_TOP_LIFE), "8000")
	_equal("turn is read from the new seat", _text(hud, HUD_TURN), "Turn 1 - opponent's turn")

	_discard(hud)
	_end()


func _case_hud_shows_the_pending_prompt() -> void:
	_begin("hud shows what SelectionController is asking for")
	var state: DuelState = _duel_in_progress()
	var hud: HudScript = _hud()
	hud.bind(state)

	_check("no prompt, no panel", not _node(hud, HUD_PROMPT_PANEL).visible, "panel was visible")

	var selection: SelectionController = SelectionController.new(state)
	selection.set_pending({"t": DuelEnums.EV.SELECT_IDLECMD})
	var prompt: String = selection.pending_prompt()
	hud.set_prompt(prompt)

	_check("prompt is not empty", not prompt.is_empty(), "pending_prompt() returned nothing")
	_equal("prompt reaches the label verbatim", _text(hud, HUD_PROMPT), prompt)
	_check("panel appears", _node(hud, HUD_PROMPT_PANEL).visible, "panel stayed hidden")

	selection.clear()
	hud.set_prompt(selection.pending_prompt())
	_equal("cleared prompt clears the label", _text(hud, HUD_PROMPT), "")
	_check("panel hides again", not _node(hud, HUD_PROMPT_PANEL).visible, "panel stayed visible")

	_discard(hud)
	_end()


func _case_hud_without_a_model() -> void:
	_begin("hud with no duel bound shows placeholders rather than crashing")
	var hud: HudScript = _hud()
	hud.refresh()

	_equal("life", _text(hud, HUD_BOTTOM_LIFE), HudScript.EMPTY)
	_equal("turn", _text(hud, HUD_TURN), HudScript.EMPTY)
	_equal("phase", _text(hud, HUD_PHASE), HudScript.EMPTY)

	hud.bind(null)
	_equal("binding null is legal", _text(hud, HUD_TOP_LIFE), HudScript.EMPTY)

	_discard(hud)
	_end()


# ----------------------------------------------------------------------------------------------
# CardPreview
# ----------------------------------------------------------------------------------------------

func _case_preview_fills_itself_from_card_info() -> void:
	_begin("preview fills every label from a get_card_info-shaped Dictionary")
	var preview: CardPreview = _preview()

	_check("starts hidden", not preview.is_showing(), "it was already showing")

	preview.show_card(blue_eyes(), null)
	_check("showing", preview.is_showing(), "show_card did not open it")
	_equal("the code it believes it is showing", preview.shown_code(), 89631139)

	_equal("name", _text(preview, CardPreview.PATH_NAME), "Blue-Eyes White Dragon")
	_equal("type decoded from the TYPE bits", _text(preview, CardPreview.PATH_TYPE),
		"Monster / Normal")
	_equal("attribute and race decoded", _text(preview, CardPreview.PATH_TRAITS),
		"LIGHT%sDragon" % CardPreview.PART_SEPARATOR)
	_equal("level, attack and defence", _text(preview, CardPreview.PATH_STATS),
		"Level 8%sATK 3000%sDEF 2500" % [CardPreview.PART_SEPARATOR, CardPreview.PART_SEPARATOR])
	_equal("effect text verbatim", _text(preview, CardPreview.PATH_DESC), str(blue_eyes()["desc"]))

	# Not a Link and not a Pendulum, so those two lines are absent rather than blank.
	_check("no marker line", not _node(preview, CardPreview.PATH_MARKERS).visible,
		"a non-Link card offered link markers")
	_check("no scale line", not _node(preview, CardPreview.PATH_SCALES).visible,
		"a non-Pendulum card offered scales")

	# A null face is a normal argument: the art may not have decoded yet, or there may be none.
	_check("says there is no artwork", _node(preview, CardPreview.PATH_NO_ART).visible,
		"a null face left the art area silently empty")

	# A real texture takes the place of that message, which is what a hover actually passes in.
	var texture: Texture2D = PlaceholderTexture2D.new()
	preview.show_card(blue_eyes(), texture)
	var face: TextureRect = preview.get_node(CardPreview.PATH_FACE) as TextureRect
	_check("the face it was handed", face.texture == texture, "got %s" % str(face.texture))
	_check("and the no-artwork message is gone", not _node(preview, CardPreview.PATH_NO_ART).visible,
		"it stayed visible under a real texture")

	preview.hide_card()
	_check("hide_card closes it", not preview.is_showing(), "still showing")
	_check("and lets go of the face", face.texture == null,
		"a hidden preview was still holding a texture")

	_discard(preview)
	_end()


func _case_preview_hides_what_a_spell_has_no_room_for() -> void:
	_begin("a spell shows no attribute, no level and no stats rather than zeroes")
	var preview: CardPreview = _preview()
	preview.show_card(pot_of_greed(), null)

	_equal("name", _text(preview, CardPreview.PATH_NAME), "Pot of Greed")
	# The cdb stores a Normal Spell as bare TYPE_SPELL with no second bit, so "Normal" has to be
	# inferred from the absence of every subtype flag.
	_equal("type", _text(preview, CardPreview.PATH_TYPE), "Spell / Normal")
	_equal("effect text", _text(preview, CardPreview.PATH_DESC), "Draw 2 cards.")

	for path: String in [CardPreview.PATH_TRAITS, CardPreview.PATH_STATS,
			CardPreview.PATH_MARKERS, CardPreview.PATH_SCALES]:
		_check("%s is hidden" % path.get_file(), not _node(preview, path).visible,
			"it read '%s'" % _text(preview, path))

	_discard(preview)
	_end()


## The one shape most likely to be rendered wrong. `card_db.cpp` moves the cdb's `def` column
## into `link_marker` for a Link monster and zeroes `defense`, so a preview that printed a
## defence would print "DEF 0" - a plausible lie, which is worse than an obvious one.
func _case_preview_link_monster_has_markers_and_no_defence() -> void:
	_begin("a Link monster shows its markers, its rating, and no defence at all")
	var preview: CardPreview = _preview()
	preview.show_card(link_monster(), null)

	var stats: String = _text(preview, CardPreview.PATH_STATS)
	_equal("rating and attack", stats,
		"LINK-3%sATK 2300" % CardPreview.PART_SEPARATOR)
	_check("no defence anywhere in the stat line", not stats.contains("DEF"),
		"it read '%s'" % stats)
	_check("and no level either - a Link monster has none", not stats.contains("Level"),
		"it read '%s'" % stats)

	_check("the marker line is visible", _node(preview, CardPreview.PATH_MARKERS).visible,
		"a Link monster showed no markers")
	_equal("markers decoded in reading order", _text(preview, CardPreview.PATH_MARKERS),
		"Markers: Top, Left, Right")

	# Straight off the bitmask, so the decode is checked without the panel in the way. 0200,
	# 0010 and 0040 octal from ocgapi_constants.h.
	_equal("link_marker_names decodes the raw mask",
		CardPreview.link_marker_names(128 | 8 | 32), PackedStringArray(["Top", "Left", "Right"]))
	_equal("the corners too",
		CardPreview.link_marker_names(64 | 256 | 1 | 4),
		PackedStringArray(["Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right"]))

	_equal("type line names Link", _text(preview, CardPreview.PATH_TYPE),
		"Monster / Link / Effect")

	# An Xyz carries a Rank in the same column a Level lives in, and ocgcore writes an unknown
	# ATK or DEF as a negative number rather than as a sentinel worth printing.
	var xyz: Dictionary = blue_eyes()
	xyz["type"] = DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.XYZ
	xyz["level"] = 4
	xyz["attack"] = -2
	xyz["defense"] = -2
	preview.show_card(xyz, null)
	_equal("an Xyz has a Rank, and '?' is a value", _text(preview, CardPreview.PATH_STATS),
		"Rank 4%sATK ?%sDEF ?" % [CardPreview.PART_SEPARATOR, CardPreview.PART_SEPARATOR])

	# Pendulum scales live in their own line because they are not stats.
	var pendulum: Dictionary = blue_eyes()
	pendulum["type"] = DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.EFFECT | DuelEnums.TYPE.PENDULUM
	pendulum["lscale"] = 4
	pendulum["rscale"] = 8
	preview.show_card(pendulum, null)
	_check("a Pendulum shows its scales", _node(preview, CardPreview.PATH_SCALES).visible,
		"the scale line stayed hidden")
	_equal("scales", _text(preview, CardPreview.PATH_SCALES), "Pendulum Scale 4 / 8")

	_discard(preview)
	_end()


func _case_preview_without_card_data() -> void:
	_begin("an empty Dictionary says so instead of showing a panel full of blanks")
	var preview: CardPreview = _preview()

	# `get_card_info()` answers {} for a passcode the database does not have: a token, a card
	# from a set we do not ship, or a code that arrived over the network.
	preview.show_card({}, null)

	_check("it still opens", preview.is_showing(), "an unknown card closed the panel")
	_equal("the name says what happened", _text(preview, CardPreview.PATH_NAME),
		CardPreview.UNKNOWN_NAME)
	_check("the name is not blank", not _text(preview, CardPreview.PATH_NAME).strip_edges().is_empty(),
		"the name label was empty")
	_equal("the type line is a placeholder, not an empty string",
		_text(preview, CardPreview.PATH_TYPE), CardPreview.EMPTY)
	_equal("and the text area explains itself", _text(preview, CardPreview.PATH_DESC),
		CardPreview.UNKNOWN_DESC)
	_equal("no code is claimed", preview.shown_code(), 0)

	for path: String in [CardPreview.PATH_TRAITS, CardPreview.PATH_STATS,
			CardPreview.PATH_MARKERS, CardPreview.PATH_SCALES]:
		_check("%s stays out of the way" % path.get_file(), not _node(preview, path).visible,
			"it read '%s'" % _text(preview, path))

	# Half a row is also a real answer: `get_card_info()` fills the numeric half from
	# OCG_CardData and the text half from the cdb's text table, and returns whichever it found.
	preview.show_card({"code": 42, "type": DuelEnums.TYPE.TRAP | DuelEnums.TYPE.CONTINUOUS}, null)
	_equal("a row with data but no text still gets a title",
		_text(preview, CardPreview.PATH_NAME), "Card 42")
	_equal("and its type is still decoded", _text(preview, CardPreview.PATH_TYPE),
		"Trap / Continuous")

	preview.hide_card()
	_check("hidden", not preview.is_showing(), "still showing")

	_discard(preview)
	_end()


# ----------------------------------------------------------------------------------------------
# SceneRouter
# ----------------------------------------------------------------------------------------------

func _case_router_reaches_the_menu() -> void:
	_begin("router reaches the menu")
	var router: RouterScript = _router()
	router.go(RouterScript.MENU)

	_equal("current", router.current(), "menu")
	_check("a scene is mounted", router.current_scene() != null, "nothing was instantiated")
	_check("it is the menu", router.current_scene() is MenuScript,
		"got %s" % str(router.current_scene()))
	_check("mounted under the router", router.current_scene().get_parent() == router, "wrong parent")

	_discard(router)
	_end()


func _case_router_reaches_solo() -> void:
	_begin("router reaches solo")
	var router: RouterScript = _router()

	_equal("solo routes at duel_touch", RouterScript.SOLO_SCENE, "res://scenes/duel_touch.tscn")
	_check("that scene exists", ResourceLoader.exists(RouterScript.SOLO_SCENE),
		"%s is missing" % RouterScript.SOLO_SCENE)
	_equal("and the route table points there", str(router.routes[RouterScript.SOLO]),
		RouterScript.SOLO_SCENE)

	# Swapped for a stub so this test does not boot a core, a duel thread and a card database.
	router.routes[RouterScript.SOLO] = _stub_scene("SoloStub")
	router.go(RouterScript.MENU)
	router.go(RouterScript.SOLO)

	_equal("current", router.current(), "solo")
	_equal("the menu was replaced", str(router.current_scene().name), "SoloStub")
	_equal("only one scene is mounted", router.get_child_count(), 1)

	_discard(router)
	_end()


func _case_router_sends_unbuilt_destinations_home() -> void:
	_begin("router sends unbuilt destinations back to the menu with a reason")
	var router: RouterScript = _router()

	for destination: String in RouterScript.PENDING:
		router.go(destination)
		_equal("%s lands on the menu" % destination, router.current(), "menu")
		_equal("%s explains itself" % destination, _text(router.current_scene(), MENU_STATUS),
			str(RouterScript.PENDING[destination]))

	var before: Node = router.current_scene()
	router.go("decks")
	_check("re-choosing does not rebuild the menu", router.current_scene() == before,
		"the menu was replaced")

	router.go("there is no such place")
	_equal("an unknown name still lands somewhere", router.current(), "menu")
	_check("and says so", _text(router.current_scene(), MENU_STATUS).contains("no destination"),
		"status read '%s'" % _text(router.current_scene(), MENU_STATUS))

	_discard(router)
	_end()


# ----------------------------------------------------------------------------------------------
# MainMenu
# ----------------------------------------------------------------------------------------------

func _case_menu_offers_every_destination() -> void:
	_begin("menu offers the five destinations and says which are not built")
	var menu: MenuScript = MenuScene.instantiate() as MenuScript
	root.add_child(menu)

	var chosen: Array[String] = []
	menu.chose.connect(func(destination: String) -> void: chosen.append(destination))

	var buttons: Node = menu.get_node(MENU_BUTTONS)
	_equal("five entries", MenuScript.ENTRIES.size(), 5)
	_equal("five buttons", buttons.get_child_count(), 5)

	for entry: Dictionary in MenuScript.ENTRIES:
		var button: Button = buttons.get_node_or_null(str(entry["node"])) as Button
		_check("%s has a button" % str(entry["id"]), button != null, "no node named %s" % str(entry["node"]))
		if button == null:
			continue
		_check("%s is pressable" % str(entry["id"]), not button.disabled, "it was disabled")
		_check("%s names itself" % str(entry["id"]), button.text.begins_with(str(entry["label"])),
			"button read '%s'" % button.text)
		if not str(entry["note"]).is_empty():
			_check("%s admits it is not built" % str(entry["id"]), button.text.contains(str(entry["note"])),
				"button read '%s'" % button.text)
		button.pressed.emit()

	_equal("every press was reported", chosen, ["solo", "host", "join", "decks", "replays"])

	menu.show_message("anything at all")
	_equal("messages reach the screen", _text(menu, MENU_STATUS), "anything at all")

	_discard(menu)
	_end()


# ----------------------------------------------------------------------------------------------
# BoardView zone markers
# ----------------------------------------------------------------------------------------------

## The whole point of building the markers off the anchors rather than off the layout arithmetic
## a second time. A marker that has drifted is worse than no marker: it tells a player a card
## goes somewhere it does not.
func _case_zone_markers_sit_on_their_anchors() -> void:
	_begin("every zone marker sits within a millimetre of the anchor it represents")
	var board: BoardView = _board()

	var names: PackedStringArray = board.zone_marker_names()
	# 17 playable zones per seat: 5 monster, 2 extra monster, 5 spell & trap, field, graveyard,
	# banished, deck, extra deck. Counted from DuelEnums rather than typed as "34".
	var per_player: int = (
		DuelEnums.MAIN_MONSTER_ZONES + DuelEnums.EXTRA_MONSTER_ZONES
		+ DuelEnums.SPELL_TRAP_ZONES + 5)
	_equal("one marker per playable zone per seat", names.size(),
		per_player * DuelEnums.PLAYER_COUNT)

	var worst: float = 0.0
	var worst_name: String = ""
	var strays: PackedStringArray = PackedStringArray()
	for anchor: String in names:
		if not board.anchor_names().has(anchor):
			strays.append(anchor)
			continue
		var drift: float = board.zone_marker_transform(anchor).origin.distance_to(
			board.anchor_position(anchor))
		if drift > worst:
			worst = drift
			worst_name = anchor
	_check("every marker names a real anchor", strays.is_empty(),
		"strays: %s" % ", ".join(strays))
	_check("worst drift is under a millimetre", worst < 0.001,
		"%s is %.4f m from its anchor" % [worst_name, worst])
	print("        worst marker drift: %s %.4f mm" % [worst_name, worst * 1000.0])

	# The only offset there is meant to be, and it has to clear the table without reaching the
	# cards. Either way round it z-fights something.
	var lift: float = board.zone_marker_transform("MZ_P0_0").origin.y
	_check("markers float above the table top", lift > 0.0, "lift was %.5f m" % lift)
	_check("and stay under the cards", lift < BoardView.CARD_LIFT,
		"lift %.5f m vs card lift %.5f m" % [lift, BoardView.CARD_LIFT])

	# Role is carried by the shape, not only by the colour: three distinct meshes.
	_equal("monster zone role", board.zone_marker_role("MZ_P0_2"), BoardView.ZoneRole.MONSTER)
	_equal("extra monster zone role", board.zone_marker_role("EMZ_P1_0"), BoardView.ZoneRole.MONSTER)
	_equal("spell & trap role", board.zone_marker_role("ST_P0_4"), BoardView.ZoneRole.SPELL_TRAP)
	_equal("field zone role", board.zone_marker_role("FZ_P1"), BoardView.ZoneRole.SPELL_TRAP)
	for pile: String in ["GY_P0", "BANISH_P0", "DECK_P1", "EXTRA_P1"]:
		_equal("%s role" % pile, board.zone_marker_role(pile), BoardView.ZoneRole.PILE)
	_equal("an anchor with no marker reports no role", board.zone_marker_role("HAND_P0"), -1)

	var monster: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P0_0") as MeshInstance3D
	var spell: MeshInstance3D = board.get_node("ZoneMarkers/ST_P0_0") as MeshInstance3D
	var pile_marker: MeshInstance3D = board.get_node("ZoneMarkers/GY_P0") as MeshInstance3D
	_check("monster and spell & trap are different geometry", monster.mesh != spell.mesh,
		"both roles share one mesh, so only the colour tells them apart")
	_check("and so is a pile", pile_marker.mesh != monster.mesh and pile_marker.mesh != spell.mesh,
		"a pile shares a mesh with a zone")

	# Shared, not per-instance: the marker set must cost a fixed number of resources.
	var other_monster: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P1_3") as MeshInstance3D
	_check("meshes are shared between markers of a role", other_monster.mesh == monster.mesh,
		"every marker allocated its own mesh")
	_check("so are materials", other_monster.material_override == monster.material_override,
		"every marker allocated its own material")

	# Hands, players and NOWHERE are not places a card is "placed", so they have no outline.
	for anchor: String in ["HAND_P0", "HAND_P1", "PLAYER_P0", BoardView.ANCHOR_NOWHERE]:
		_check("%s has no marker" % anchor, not names.has(anchor), "it got one")

	# A marker must never be able to answer a pick ray - that is CardView's job alone.
	var colliders: PackedStringArray = PackedStringArray()
	for anchor: String in names:
		var marker: Node = board.get_node("ZoneMarkers/%s" % anchor)
		if marker.get_child_count() > 0:
			colliders.append(anchor)
	_check("no marker carries a collider", colliders.is_empty(),
		"these have children: %s" % ", ".join(colliders))

	# The markers live beside the anchors, never inside them: `anchor_names()` is the vocabulary
	# L3 and L4 share and a marker appearing in it would be a new, meaningless anchor.
	_equal("the anchor list is untouched", board.anchor_names().size(),
		board.get_node("ZoneAnchors").get_child_count())

	_discard(board)
	_end()


func _case_zone_markers_light_up() -> void:
	_begin("a legal target lights up, and one call sets the whole state")
	var board: BoardView = _board()

	board.highlight_zones(PackedStringArray(["MZ_P0_1", "MZ_P0_3"]))
	_equal("the zones asked for", board.highlighted_zones(),
		PackedStringArray(["MZ_P0_1", "MZ_P0_3"]))

	var lit: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P0_1") as MeshInstance3D
	var dark: MeshInstance3D = board.get_node("ZoneMarkers/MZ_P0_0") as MeshInstance3D
	_equal("a lit zone wears the highlight colour",
		(lit.material_override as StandardMaterial3D).albedo_color, BoardView.COLOUR_HIGHLIGHT)
	_equal("an unlit one keeps its role colour",
		(dark.material_override as StandardMaterial3D).albedo_color, BoardView.COLOUR_MONSTER)

	# One call is the whole state, so a caller never has to remember what it lit last time.
	board.highlight_zones(PackedStringArray(["ST_P1_0"]))
	_equal("the previous set is gone", board.highlighted_zones(), PackedStringArray(["ST_P1_0"]))
	_equal("and the zone it left went back to its role colour",
		(lit.material_override as StandardMaterial3D).albedo_color, BoardView.COLOUR_MONSTER)

	# The same anchor grammar as everything else, aliases included.
	board.highlight_zones(PackedStringArray(["PZ_P0_0", "PZ_P0_1"]))
	_equal("a pendulum zone lights the spell & trap zone it actually is",
		board.highlighted_zones(),
		PackedStringArray(["ST_P0_0", "ST_P0_%d" % (DuelEnums.SPELL_TRAP_ZONES - 1)]))

	# V13's spirit: an anchor with no marker warns and is skipped, never crashes.
	print("        the next warning is this check doing its job")
	board.highlight_zones(PackedStringArray(["MZ_P1_2", "HAND_P0", "NOT_AN_ANCHOR"]))
	_equal("the unknown names are dropped and the real one survives",
		board.highlighted_zones(), PackedStringArray(["MZ_P1_2"]))

	board.clear_highlights()
	_equal("clear_highlights turns everything off", board.highlighted_zones().size(), 0)

	_discard(board)
	_end()


# ----------------------------------------------------------------------------------------------
# CardArt - the card back
# ----------------------------------------------------------------------------------------------

## `back_texture()` is the one thing in `CardArt` that is not a face, and the one thing that must
## never be evicted: every face-down card, both decks, both extra decks and the opponent's hand
## wear it, so losing it under memory pressure would blank most of the board at exactly the
## moment memory was tight - and then reload it on the next frame.
func _case_card_back_is_outside_the_budget() -> void:
	var art: CardArt = CardArt.new()
	if not FileAccess.file_exists(art.back_path()):
		print("SKIP  the card back loads and survives an LRU sweep (no %s)" % art.back_path())
		return

	_begin("the card back loads and survives an LRU sweep")

	var back: Texture2D = art.back_texture()
	_check("it loaded", back != null, "back_texture() returned null")
	if back != null:
		_equal("it is the real file, at its real size", back.get_size(), Vector2(BACK_SIZE))
	_equal("its decoded cost is reported", art.back_bytes(), BACK_SIZE.x * BACK_SIZE.y * 3)
	_check("and is not counted against the face budget", int(art.stats()["bytes"]) == 0,
		"stats() reported %d bytes with only the back loaded" % int(art.stats()["bytes"]))
	_equal("nor as a cache entry", art.stats()["cached"], 0)
	_check("a second call is the same texture, not a second decode",
		art.back_texture() == back, "it reloaded")
	print("        card back: %s, %d bytes decoded, outside the %d byte budget" % [
		art.back_path().get_file(), art.back_bytes(), art.budget_bytes()])

	# Now actually run the LRU over the top of it: a budget of one face, then six faces loaded.
	var codes: PackedInt32Array = _sample_codes(CardArt.default_root(CardArt.TIER_SD), 6)
	if codes.size() < 6:
		_check("needed six faces on disk to force an eviction", false,
			"found %d" % codes.size())
		art.shutdown()
		_end()
		return

	art.set_tier(CardArt.TIER_SD)
	art.set_budget_bytes(268 * 391 * 3)
	for code: int in codes:
		art.request(code)
	art.shutdown()
	for code: int in codes:
		art.texture_for(code)

	var stats: Dictionary = art.stats()
	_check("the sweep really did evict", int(stats["cached"]) < codes.size(),
		"all %d faces survived a one-face budget" % int(stats["cached"]))
	_check("the back is still the same object", art.back_texture() == back,
		"the LRU took the card back")
	_equal("and still not in the cache's accounting", stats["cached"], 1)

	# Neither of the two other things that drop faces may touch it.
	art.clear()
	_check("clear() leaves it", art.back_texture() == back, "clear() dropped the card back")
	art.set_tier(CardArt.TIER_HD)
	_check("and so does a tier switch - there is only one file, shared by both tiers",
		art.back_texture() == back, "set_tier() dropped the card back")

	art.shutdown()
	_end()


# ----------------------------------------------------------------------------------------------
# ARCHITECTURE.md section 10 rule 4
# ----------------------------------------------------------------------------------------------

## No widget may size itself from the screen. In VR this whole layer becomes a SubViewport on a
## quad whose pixel size is an arbitrary texture resolution, and any such branch would be wrong
## there (see the header of `ui/hud/duel_hud.gd`).
func _case_no_widget_measures_the_screen() -> void:
	_begin("no file under game/ui/ measures the screen")

	# Spelled in halves so that this file is not itself a hit for the thing it forbids.
	var needles: Array[String] = [
		"get_viewport()" + ".size",
		"get_window()" + ".size",
		"DisplayServer." + "window_get_size",
	]

	var files: PackedStringArray = _ui_files(UI_ROOT)
	_check("there are files to scan", files.size() > 0, "found none under %s" % UI_ROOT)

	for path: String in files:
		var text: String = FileAccess.get_file_as_string(path)
		_check("%s was readable" % path, not text.is_empty(), "read nothing")
		for needle: String in needles:
			_check("%s is clean" % path, not text.contains(needle), "it contains '%s'" % needle)

	_end()


## V1: L4 and L5 never import anything from L1. The card preview is the file this is actually
## about - it renders card data and the shortest route to card data is the core - but the rule
## is the directory's, so the whole directory is scanned.
##
## A widget that reached the core directly would work today and would be unusable the first time
## a card is previewed from a replay, from a deck list or from across the network, none of which
## have a live core to ask.
func _case_no_ui_file_names_the_core() -> void:
	_begin("no file under game/ui/ names the core")

	# Spelled in halves so that this file is not itself a hit for the thing it forbids.
	# `ClassDB.instantiate` is here because it is the actual back door: the core is registered
	# by the GDExtension and `ClassDB.instantiate("<the core>")` reaches it without the name
	# ever appearing as an identifier.
	var needles: Array[String] = [
		"Kaiba" + "Core",
		"ClassDB." + "instantiate",
		"OCG" + "_",
	]

	var files: PackedStringArray = _ui_files(UI_ROOT)
	_check("there are files to scan", files.size() > 0, "found none under %s" % UI_ROOT)

	for path: String in files:
		# Comment lines are stripped first. The invariant is about what the code *does*, and
		# several files under here explain the rule by quoting the forbidden name - which is
		# the opposite of breaking it. `ui/hud/duel_hud.gd` has said so since it was written.
		var text: String = _without_comments(FileAccess.get_file_as_string(path))
		_check("%s was readable" % path, not text.strip_edges().is_empty(), "read nothing")
		for needle: String in needles:
			_check("%s is clean" % path, not text.contains(needle), "it contains '%s'" % needle)

	_end()


## Drops whole-line GDScript comments. Deliberately crude: it does not try to understand strings
## or trailing comments, because the needles it exists to serve never appear in either.
func _without_comments(text: String) -> String:
	var kept: PackedStringArray = PackedStringArray()
	for line: String in text.split("\n"):
		if not line.strip_edges().begins_with("#"):
			kept.append(line)
	return "\n".join(kept)


## Every script and scene under a directory, recursively. Source-tree only: an exported build
## ships `.gdc` and this test never runs from one.
func _ui_files(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for file: String in DirAccess.get_files_at(dir):
		if file.ends_with(".gd") or file.ends_with(".tscn"):
			out.append(dir.path_join(file))
	for sub: String in DirAccess.get_directories_at(dir):
		out.append_array(_ui_files(dir.path_join(sub)))
	return out


# ----------------------------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------------------------

## A duel one turn in, built by hand from the event shapes `native/src/msg_parser.cpp` emits.
## P0 is on 8000, P1 has taken 1000, it is P0's first main phase.
func _duel_in_progress() -> DuelState:
	var state: DuelState = DuelState.new()
	state.apply({
		"t": DuelEnums.EV.START,
		"lp": [8000, 8000],
		"deck": [40, 40],
		"extra": [0, 0],
		"first": DuelEnums.PLAYER.P0,
	})
	state.apply({"t": DuelEnums.EV.NEW_TURN, "player": DuelEnums.PLAYER.P0})
	state.apply({"t": DuelEnums.EV.NEW_PHASE, "phase": DuelEnums.PHASE.MAIN1})
	state.apply({"t": DuelEnums.EV.DAMAGE, "player": DuelEnums.PLAYER.P1, "amount": 1000})
	return state


func _hud() -> HudScript:
	var hud: HudScript = HudScene.instantiate() as HudScript
	root.add_child(hud)
	return hud


func _router() -> RouterScript:
	var router: RouterScript = RouterScript.new()
	root.add_child(router)
	return router


func _preview() -> CardPreview:
	var preview: CardPreview = PreviewScene.instantiate() as CardPreview
	root.add_child(preview)
	return preview


## A board with no duel behind it. `BoardView` builds its table, its anchors and its markers on
## first touch, so nothing else is needed to measure the geometry.
func _board() -> BoardView:
	var board: BoardView = BoardView.new()
	root.add_child(board)
	return board


## The first `count` passcodes with a file under `dir`, in directory order. Discovered rather
## than hardcoded so the suite does not depend on which art someone happens to have downloaded.
func _sample_codes(dir: String, count: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var handle: DirAccess = DirAccess.open(dir)
	if handle == null:
		return out
	handle.list_dir_begin()
	var entry: String = handle.get_next()
	while entry != "" and out.size() < count:
		if entry.ends_with(".jpg"):
			var code: int = int(entry.get_basename())
			if code > 0:
				out.append(code)
		entry = handle.get_next()
	handle.list_dir_end()
	return out


func _stub_scene(node_name: String) -> PackedScene:
	var node: Node = Node.new()
	node.name = node_name
	var packed: PackedScene = PackedScene.new()
	packed.pack(node)
	node.free()
	return packed


func _node(owner: Node, path: String) -> Control:
	return owner.get_node_or_null(path) as Control


func _text(owner: Node, path: String) -> String:
	var label: Label = owner.get_node_or_null(path) as Label
	return label.text if label != null else "<no node at %s>" % path


func _discard(node: Node) -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()


# ----------------------------------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------------------------------

func _begin(case_name: String) -> void:
	_case_name = case_name
	_case_failures = PackedStringArray()


func _check(label: String, passed: bool, detail: String) -> void:
	if passed:
		return
	_case_failures.append("%s (%s)" % [label, detail])


func _equal(label: String, actual: Variant, expected: Variant) -> void:
	_check(label, _same(actual, expected), "expected %s, got %s" % [str(expected), str(actual)])


## Godot's `==` on Array and Dictionary is identity, not content, so compare the serialised
## form instead. Scalars fall through to a plain comparison.
func _same(actual: Variant, expected: Variant) -> bool:
	if actual is Array or actual is Dictionary or expected is Array or expected is Dictionary:
		return JSON.stringify(actual) == JSON.stringify(expected)
	return actual == expected


func _end() -> void:
	_cases_run += 1
	if _case_failures.is_empty():
		print("PASS  %s" % _case_name)
		return
	_cases_failed += 1
	print("FAIL  %s" % _case_name)
	for failure: String in _case_failures:
		print("        %s" % failure)
