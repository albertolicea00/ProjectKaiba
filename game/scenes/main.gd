extends Node

## Phase 0 bootstrap.
##
## Proves the native toolchain end to end: the GDExtension loads, ocgcore is linked, Lua was
## compiled as C++, and a duel can be created, scripted and destroyed.
##
## Replaced by SceneRouter in Phase 2. See docs/ARCHITECTURE.md section 4.

const CORE_CLASS := "KaibaCore"


func _ready() -> void:
	var core: Object = _instantiate_core()
	if core == null:
		return
	_report_build(core)
	_report_selftest(core)


## Uses ClassDB rather than `KaibaCore.new()` on purpose: a missing GDExtension would make the
## literal class name a parse error, and we would lose the diagnostic below.
func _instantiate_core() -> Object:
	if not ClassDB.class_exists(CORE_CLASS):
		push_error(
			"%s is not registered. The GDExtension did not load. " % CORE_CLASS
			+ "Check that game/bin/ holds a library matching this platform, then run: make host"
		)
		return null
	return ClassDB.instantiate(CORE_CLASS)


func _report_build(core: Object) -> void:
	var info: Dictionary = core.get_build_info()
	print("[kaiba] platform : %s %s" % [info["platform"], info["arch"]])
	print("[kaiba] compiler : %s" % info["compiler"])
	print("[kaiba] built    : %s" % info["build_date"])

	if not info["exceptions"]:
		push_error(
			"Built without C++ exceptions, but ocgcore raises Lua errors through them. "
			+ "Rebuild with disable_exceptions=no. See AGENTS.md section 8.1."
		)


func _report_selftest(core: Object) -> void:
	var result: Dictionary = core.run_selftest()
	print("[kaiba] ocgcore  : %s (headers expect %s)" % [result["core_version"], result["expected_version"]])

	if result["ok"]:
		print("[kaiba] selftest : PASS")
		return

	push_error("[kaiba] selftest FAILED at stage '%s': %s" % [result["stage"], result["detail"]])
