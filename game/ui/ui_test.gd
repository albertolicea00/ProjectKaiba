extends SceneTree

## Self-checking tests for the duel HUD, the main menu and the scene router.
##
##   godot --headless --path game --script res://ui/ui_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, so it can be wired into
## a Makefile target as a gate. Same shape as `core/duel/duel_state_test.gd`, no framework.
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

var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0

var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true

	print("== DuelHud / MainMenu / SceneRouter tests ==")

	_case_hud_reads_the_model()
	_case_hud_rolls_life_points()
	_case_hud_knows_which_seat_is_yours()
	_case_hud_shows_the_pending_prompt()
	_case_hud_without_a_model()

	_case_router_reaches_the_menu()
	_case_router_reaches_solo()
	_case_router_sends_unbuilt_destinations_home()
	_case_menu_offers_every_destination()

	_case_no_widget_measures_the_screen()

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
