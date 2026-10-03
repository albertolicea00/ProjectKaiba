class_name SceneRouter
extends Node
##
## Layer: **L5**, not L3. This file instantiates scenes and adds children for a living, which is
## exactly what invariant V2 forbids L3 from doing. It lived under `game/core/` briefly and that
## was wrong: `core/` is the pure model, `platform/` is the shell that puts a model on a screen.
## A router is shell.

## Owns which scene is on screen and swaps them (ARCHITECTURE.md section 4). One entry point:
##
##     router.go("menu")
##     router.go("solo")
##     router.go("solo_test")
##
## `menu`, `solo`, `solo_test`, `controls` and `decks` are the destinations that exist. `host`, `join` and `replays` are
## named in the menu because they are named in the roadmap, and choosing one lands back on the
## menu carrying the line of `PENDING` that says why. An unknown name does the same thing with a
## different line - a typo should put the player somewhere, not nowhere.
##
## Layer: L5 shell. The router knows scene paths and destination names; it never reads the duel,
## the core or the model. Scenes talk back to it through one signal, `chose(destination)`,
## looked up by name so the router does not have to depend on the menu's type.
##
## NOTE ON ITS HOME: `game/core/` is documented as L3, "zero scene dependencies" (V2), and this
## file does instantiate scenes. It sits here because the task that created it placed it here
## and because ARCHITECTURE.md section 4 draws it directly under `Main.tscn`. If V2 is ever read
## strictly over the whole of `core/` rather than over `core/duel/` and `core/registry/`, this
## file belongs in `game/scenes/` or `game/platform/` and nothing but its path has to change.

## Emitted after the swap, with the destination that is now current.
signal changed(destination: String)

const MENU: String = "menu"
const SOLO: String = "solo"
## The hot-seat test bench. A separate destination from `solo` rather than a flag on it: they
## are the same duel wired to two different shells, and the one thing this one adds - a camera
## and a HUD that change seats with the turn - is exactly what a real solo duel against an AI
## must never do.
const SOLO_TEST: String = "solo_test"
const DECKS: String = "decks"
## Every gesture the game listens for, on both devices. A destination rather than an overlay
## because it has to be reachable before a duel exists - a player who cannot work out how to
## play a card is not already in a duel.
const CONTROLS: String = "controls"

const MENU_SCENE: String = "res://ui/main_menu/main_menu.tscn"
const SOLO_SCENE: String = "res://scenes/duel_touch.tscn"
const SOLO_TEST_SCENE: String = "res://scenes/solo_test.tscn"
## Decks are chosen, not edited. See `DeckLibrary` for why: a `.ydk` built in any other
## client works here untouched, and owning a deck format would cut this one off from all
## of them.
const DECKS_SCENE: String = "res://ui/deck_picker/deck_picker.tscn"
const CONTROLS_SCENE: String = "res://ui/controls/controls_screen.tscn"

## The signal a hosted scene uses to ask for a different destination.
const CHOSE_SIGNAL: String = "chose"

## The method a hosted scene exposes if it can show the player a line of text.
const MESSAGE_METHOD: String = "show_message"

## Destinations that exist in the roadmap and not in the build. Each one routes back to the menu
## with its explanation; that is the entire implementation until the phase named here lands.
## Phases are ARCHITECTURE.md section 12.
const PENDING: Dictionary = {
	"host": "Host Duel needs the LAN transport and the lobby - Phase 3. Nothing behind it yet.",
	"join": "Join Duel needs LAN discovery and the lobby - Phase 3. Nothing behind it yet.",
	"replays": "Replay recording and playback arrive in Phase 3. Nothing is recorded yet.",
}

## destination -> scene, as a `res://` path or an already-loaded `PackedScene`. Both are accepted
## so that a test can route somewhere cheap instead of booting a real duel on a real core.
var routes: Dictionary = {
	MENU: MENU_SCENE,
	SOLO: SOLO_SCENE,
	SOLO_TEST: SOLO_TEST_SCENE,
	DECKS: DECKS_SCENE,
	CONTROLS: CONTROLS_SCENE,
}

var _current: String = ""
var _scene: Node = null


# ----------------------------------------------------------------------------------------------
# The whole public surface
# ----------------------------------------------------------------------------------------------

## Shows `destination`, or the menu plus an explanation when it cannot.
func go(destination: String) -> void:
	var wanted: String = destination.strip_edges().to_lower()
	var message: String = ""

	if PENDING.has(wanted):
		message = str(PENDING[wanted])
		wanted = MENU
	elif not routes.has(wanted):
		message = "There is no destination called '%s'." % destination
		wanted = MENU

	# Re-choosing what is already on screen keeps the scene and just updates the message. It
	# matters: tapping "Decks" three times should not restart the menu three times.
	if wanted != _current or not _is_live():
		_swap(wanted)

	if not message.is_empty():
		announce(message)


## The destination currently on screen, or "" before the first `go()`.
func current() -> String:
	return _current


func current_scene() -> Node:
	return _scene


## Always logged, shown as well when the current scene can show text. The log line is what makes
## a headless run of the router auditable.
func announce(message: String) -> void:
	print("[router] %s" % message)
	if _is_live() and _scene.has_method(MESSAGE_METHOD):
		_scene.call(MESSAGE_METHOD, message)


# ----------------------------------------------------------------------------------------------
# Swapping
# ----------------------------------------------------------------------------------------------

func _swap(destination: String) -> void:
	var next: Node = _instantiate(destination)
	if next == null:
		# There is nowhere to fall back to that would not recurse, so keep what is on screen and
		# be loud about it. A blank window with no error in the log is the worst outcome here.
		push_error("SceneRouter: '%s' could not be instantiated (route: %s)" % [
			destination, str(routes.get(destination, "<none>"))])
		return

	if _is_live():
		remove_child(_scene)
		_scene.queue_free()

	_scene = next
	_current = destination
	add_child(_scene)

	if _scene.has_signal(CHOSE_SIGNAL):
		_scene.connect(CHOSE_SIGNAL, _on_chose)

	changed.emit(destination)


func _instantiate(destination: String) -> Node:
	var route: Variant = routes.get(destination)

	if route is PackedScene:
		return (route as PackedScene).instantiate()

	var path: String = str(route) if route != null else ""
	if path.is_empty() or not ResourceLoader.exists(path):
		return null

	var packed: PackedScene = load(path) as PackedScene
	return packed.instantiate() if packed != null else null


func _is_live() -> bool:
	return _scene != null and is_instance_valid(_scene)


func _on_chose(destination: String) -> void:
	go(destination)
