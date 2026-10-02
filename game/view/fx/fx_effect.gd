class_name FxEffect
extends Node3D

## Base class for every procedural effect in `game/view/fx/`.
##
## Layer: L4 (AGENTS.md section 4). **V1: nothing here names `KaibaCore`, `MsgParser` or anything
## under `native/`.** **V6: everything is world-space metres.** An effect is told where to be and
## how long to live; it reads nothing and decides nothing.
##
## -------------------------------------------------------------------------------------------
## The one contract that matters
## -------------------------------------------------------------------------------------------
## `AnimationDirector.skip_all()` must be able to collapse any animation to its end state with
## no tween, because that is both the zero-duration path and the skip path. The end state of an
## effect is *gone*, so every effect must be killable at any instant and leave nothing running.
##
##   `play(duration)`   starts it. A duration of zero finishes it on the spot, without a frame.
##   `stop()`           ends it now: kills the tween, silences whatever it owns, emits
##                      `finished`. Idempotent, and safe to call before `play()`.
##
## `finished` is what `FxLayer` listens to in order to take the node out of the tree and free
## it. An effect never frees itself - a node that deletes itself out from under the object that
## is iterating a list of effects is the kind of bug that only reproduces on a slow phone.
##
## -------------------------------------------------------------------------------------------
## Subclassing
## -------------------------------------------------------------------------------------------
## Override `_prepare()` to build the nodes (called once, from `_init`), `_advance(t)` to pose
## the effect at `t` in [0, 1], and `_silence()` to stop anything that keeps running on its own -
## a particle system, in practice. `_advance()` is never called after `_silence()`.

## Emitted exactly once, whether the effect played out or was cut short.
signal finished

var _tween: Tween = null
var _done: bool = false


func _init() -> void:
	_prepare()


## Starts the effect. `seconds` is the whole life of the effect, not a hint: the caller has
## already scaled it by `AnimationDirector.duration_scale`.
func play(seconds: float) -> void:
	if _done:
		return
	if seconds <= 0.0:
		# Zero duration is a real path, not a degenerate one: an intent with no time budget and
		# a skipped queue both arrive here, and both mean "be finished already".
		stop()
		return
	_advance(0.0)
	_tween = create_tween()
	_tween.tween_method(_advance, 0.0, 1.0, seconds)
	_tween.finished.connect(stop)


## Ends the effect now. Safe at any point, including from inside a tween callback and including
## twice.
func stop() -> void:
	if _done:
		return
	_done = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_silence()
	finished.emit()


func is_finished() -> bool:
	return _done


# ----------------------------------------------------------------------------------------------
# Subclass hooks
# ----------------------------------------------------------------------------------------------

## Builds whatever this effect owns. Called from `_init`, so there is no tree and no parent yet.
func _prepare() -> void:
	pass


## Poses the effect at `t` in [0, 1].
func _advance(_t: float) -> void:
	pass


## Stops anything that would keep going without being driven. Called exactly once.
func _silence() -> void:
	visible = false


# ----------------------------------------------------------------------------------------------
# Shared material
# ----------------------------------------------------------------------------------------------

## The one material shape every glow in this directory uses.
##
## Additive and unshaded: the board has a single directional light and a glow is emissive by
## definition, so shading it would only drag it towards the felt colour. Depth writing is off
## (implied by `TRANSPARENCY_ALPHA`) because these overlap each other and the cards they sit
## under, and `CULL_DISABLED` because a flat quad on a table is legitimately seen from below
## when the camera drops towards table level.
static func glow_material(colour: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	# Drawn after the cards, which are opaque, so an effect on the table never has to fight a
	# quad it is supposed to be lighting up.
	material.render_priority = 1
	return material
