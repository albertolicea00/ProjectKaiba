extends SceneTree

## Self-checking tests for `CardArt` and for the face it puts on a `CardView`.
##
##   godot --headless --path game --script res://core/registry/card_art_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, so it can be wired into a
## Makefile target as a gate.
##
## -------------------------------------------------------------------------------------------
## Run against the real files, or not at all
## -------------------------------------------------------------------------------------------
## Every case here reads `data/base/pics/`. There are no fixtures and no fake JPEGs on purpose:
## the things worth testing in a loader are "does this decode", "is a missing file survivable"
## and "does the byte budget hold against real decoded sizes", and a synthetic 4x4 image proves
## none of them. The texture sizes asserted below - 268x391 and 813x1185 - are what makes a case
## able to say *which tier* answered, which is the only honest test of the hd->sd fallback.
##
## `data/` is gitignored (AGENTS.md section 9), so a checkout without art is a normal state, not
## a failure: the suite prints SKIP and exits 0 rather than reporting red for data it was never
## supposed to have.
##
## Codes are discovered from the directory rather than hardcoded, except for 89631139, which is
## Blue-Eyes White Dragon and is present in both tiers. `hd/` is the smaller set and is still
## being filled in, so a hardcoded "this one is sd-only" would rot the first time someone
## finishes a download.

## Present in both tiers. The one fixed point the suite is allowed.
const KNOWN_CODE: int = 89631139

## Above every passcode on disk (the largest is nine digits, 501000007), so no file can exist.
const ABSENT_CODE: int = 999999999

## Decoded sizes, which is how a case tells the tiers apart.
const SD_SIZE: Vector2i = Vector2i(268, 391)
const HD_SIZE: Vector2i = Vector2i(813, 1185)

## How long a case will wait for a worker thread before calling it a failure. Generous: these
## are 29 KB to 175 KB JPEG decodes, so this is a hang detector, not a timing assertion.
const WAIT_MS: int = 5000

var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0

var _sd_root: String = ""
var _hd_root: String = ""
var _empty_root: String = ""


func _init() -> void:
	print("== CardArt tests ==")

	_sd_root = CardArt.default_root(CardArt.TIER_SD)
	_hd_root = CardArt.default_root(CardArt.TIER_HD)
	_empty_root = _sd_root.get_base_dir().path_join("ld")

	if not _art_is_present():
		print("SKIP  no artwork under %s - see data/base/pics/README.md" % _sd_root.get_base_dir())
		print("== 0 cases, 0 failed ==")
		quit(0)
		return

	_case_known_card_loads()
	_case_lookup_never_blocks()
	_case_missing_file_is_not_an_error()
	_case_hd_falls_back_to_sd()
	_case_hd_serves_hd_when_it_has_the_file()
	_case_lru_evicts_over_budget()
	_case_preload_warms_a_decklist()
	_case_tier_switch_invalidates()
	_case_card_view_wears_the_face()
	_case_face_down_never_shows_a_face()

	print("== %d cases, %d failed ==" % [_cases_run, _cases_failed])
	quit(1 if _cases_failed > 0 else 0)


# ----------------------------------------------------------------------------------------------
# Loading
# ----------------------------------------------------------------------------------------------

func _case_known_card_loads() -> void:
	_begin("a known card decodes off the disk at the requested tier")
	var art: CardArt = _fresh(CardArt.TIER_SD)

	var texture: Texture2D = _await_texture(art, KNOWN_CODE)
	_check("89631139 produced a texture", texture != null, "got null after %d ms" % WAIT_MS)
	if texture != null:
		_equal("texture is the sd face", texture.get_size(), Vector2(SD_SIZE))

	var stats: Dictionary = art.stats()
	_equal("one entry cached", stats["cached"], 1)
	_equal("no misses", stats["misses"], 0)
	_check("bytes is the real decoded size",
		int(stats["bytes"]) == SD_SIZE.x * SD_SIZE.y * 3,
		"expected %d, got %d" % [SD_SIZE.x * SD_SIZE.y * 3, int(stats["bytes"])])

	# Measured, so the report carries a figure rather than an assumption.
	print("        sd decoded size: %d bytes (%.1f KB)" % [
		int(stats["bytes"]), float(stats["bytes"]) / 1024.0])

	art.shutdown()
	_end()


func _case_lookup_never_blocks() -> void:
	_begin("the first look-up answers null immediately and queues the load")
	var art: CardArt = _fresh(CardArt.TIER_SD)

	var started: int = Time.get_ticks_usec()
	var first: Texture2D = art.texture_for(KNOWN_CODE)
	var elapsed_us: int = Time.get_ticks_usec() - started

	_equal("cold look-up is null", first == null, true)
	# A JPEG decode is tens of milliseconds. Anything under a millisecond cannot have touched
	# the disk, which is the whole claim being tested.
	_check("cold look-up did not touch the disk", elapsed_us < 1000,
		"took %d us, which is long enough to have decoded something" % elapsed_us)
	_check("the load was queued", art.pending_count() == 1 or art.stats()["cached"] == 1,
		"nothing pending and nothing cached")

	var later: Texture2D = _await_texture(art, KNOWN_CODE)
	_check("the queued load lands", later != null, "still null after %d ms" % WAIT_MS)

	var again: Texture2D = art.texture_for(KNOWN_CODE)
	_check("a cached look-up returns the same texture", again == later, "got a different texture")

	print("        cold look-up: %d us" % elapsed_us)
	art.shutdown()
	_end()


func _case_missing_file_is_not_an_error() -> void:
	_begin("a code with no file returns null, is remembered, and is never retried")
	var art: CardArt = _fresh(CardArt.TIER_SD)

	_equal("first look-up is null", art.texture_for(ABSENT_CODE) == null, true)
	art.shutdown()

	_equal("still null once the task has run", art.texture_for(ABSENT_CODE) == null, true)

	var stats: Dictionary = art.stats()
	_equal("nothing was cached", stats["cached"], 0)
	_equal("the miss is remembered", stats["misses"], 1)
	_equal("no bytes held", stats["bytes"], 0)

	# The point of remembering: a token asked for on every frame must not queue a task on
	# every frame.
	for _i: int in range(50):
		art.texture_for(ABSENT_CODE)
	_equal("no task was queued for a known miss", art.pending_count(), 0)
	_equal("still exactly one miss", art.stats()["misses"], 1)

	art.shutdown()
	_end()


# ----------------------------------------------------------------------------------------------
# Tiers
# ----------------------------------------------------------------------------------------------

func _case_hd_falls_back_to_sd() -> void:
	_begin("tier hd falls back to the sd file when hd has none")
	var art: CardArt = CardArt.new()
	# An hd root that exists and is empty. `ld/` is one of the tier folders the art set ships
	# with and nothing has ever been put in it, which is exactly the shape of the real problem:
	# hd holds fewer faces than sd, so the fallback has to fire for thousands of cards.
	art.set_roots(_sd_root, _empty_root)
	art.set_tier(CardArt.TIER_HD)

	var texture: Texture2D = _await_texture(art, KNOWN_CODE)
	_check("a face was still produced", texture != null, "got null after %d ms" % WAIT_MS)
	if texture != null:
		_equal("and it is the sd one", texture.get_size(), Vector2(SD_SIZE))
	_equal("so it is not a miss", art.stats()["misses"], 0)
	art.shutdown()

	# The same thing against the real hd directory, using a code that genuinely has no hd file.
	# `hd/` is still being filled in, so this is discovered rather than hardcoded.
	var sd_only: int = _find_sd_only_code()
	if sd_only == 0:
		print("        (no sd-only code found on disk; hd must now be a superset of sd)")
	else:
		var real: CardArt = _fresh(CardArt.TIER_HD)
		var fallback: Texture2D = _await_texture(real, sd_only)
		_check("a real sd-only code (%d) still gets a face" % sd_only, fallback != null,
			"got null after %d ms" % WAIT_MS)
		if fallback != null:
			_equal("served from sd", fallback.get_size(), Vector2(SD_SIZE))
		real.shutdown()

	_end()


func _case_hd_serves_hd_when_it_has_the_file() -> void:
	_begin("tier hd serves the hd file when there is one")
	var art: CardArt = _fresh(CardArt.TIER_HD)

	var texture: Texture2D = _await_texture(art, KNOWN_CODE)
	_check("89631139 produced a texture", texture != null, "got null after %d ms" % WAIT_MS)
	if texture != null:
		_equal("texture is the hd face", texture.get_size(), Vector2(HD_SIZE))

	var bytes: int = int(art.stats()["bytes"])
	_equal("bytes is the real decoded size", bytes, HD_SIZE.x * HD_SIZE.y * 3)
	print("        hd decoded size: %d bytes (%.2f MB)" % [bytes, float(bytes) / 1048576.0])

	art.shutdown()
	_end()


func _case_tier_switch_invalidates() -> void:
	_begin("switching tier drops the cache instead of serving the wrong resolution")
	var art: CardArt = _fresh(CardArt.TIER_SD)
	var sd_texture: Texture2D = _await_texture(art, KNOWN_CODE)
	_equal("sd face cached", sd_texture != null and sd_texture.get_size() == Vector2(SD_SIZE), true)

	art.set_tier(CardArt.TIER_HD)
	_equal("the cache was dropped", art.stats()["cached"], 0)
	_equal("and so were the bytes", art.stats()["bytes"], 0)

	var hd_texture: Texture2D = _await_texture(art, KNOWN_CODE)
	_equal("the hd face replaces it",
		hd_texture != null and hd_texture.get_size() == Vector2(HD_SIZE), true)

	art.shutdown()
	_end()


# ----------------------------------------------------------------------------------------------
# Budget
# ----------------------------------------------------------------------------------------------

func _case_lru_evicts_over_budget() -> void:
	_begin("the LRU evicts the least recently used face once the budget is exceeded")
	var codes: PackedInt32Array = _sample_codes(6)
	if codes.size() < 6:
		_check("needed six codes on disk", false, "found %d" % codes.size())
		_end()
		return

	var face_bytes: int = SD_SIZE.x * SD_SIZE.y * 3
	var budget: int = face_bytes * 3

	var art: CardArt = _fresh(CardArt.TIER_SD)
	art.set_budget_bytes(budget)
	print("        budget %d bytes = %d sd faces of %d bytes" % [budget, 3, face_bytes])

	# Loaded one at a time so the access order is unambiguous: codes[0] is the oldest.
	for code: int in codes:
		var texture: Texture2D = _await_texture(art, code)
		_check("code %d loaded" % code, texture != null, "got null after %d ms" % WAIT_MS)

	var stats: Dictionary = art.stats()
	print("        stats() after six loads into a three-face budget: %s" % str(stats))

	_check("the cache did not keep all six", int(stats["cached"]) < 6,
		"cached %d of 6" % int(stats["cached"]))
	_equal("it kept exactly what fits", stats["cached"], 3)
	_check("and stayed inside the budget", int(stats["bytes"]) <= budget,
		"holding %d bytes against a %d byte budget" % [int(stats["bytes"]), budget])
	_equal("bytes is consistent with the entry count",
		int(stats["bytes"]), int(stats["cached"]) * face_bytes)
	_equal("eviction is not a miss", stats["misses"], 0)

	# Least *recently used*, not first loaded: touching an old entry has to save it.
	var survivor: Texture2D = art.texture_for(codes[5])
	_check("the newest face survived", survivor != null, "codes[5] was evicted")
	var evicted: Texture2D = art.texture_for(codes[0])
	_equal("the oldest face was the one dropped", evicted == null, true)

	art.shutdown()
	_end()


func _case_preload_warms_a_decklist() -> void:
	_begin("preload_codes warms a decklist's worth of faces off the main thread")
	var codes: PackedInt32Array = _sample_codes(40)
	if codes.size() < 40:
		_check("needed forty codes on disk", false, "found %d" % codes.size())
		_end()
		return

	var art: CardArt = _fresh(CardArt.TIER_SD)

	var started: int = Time.get_ticks_usec()
	art.preload_codes(codes)
	var elapsed_us: int = Time.get_ticks_usec() - started

	# Forty JPEG decodes is well over a frame. The call that starts them must not be.
	_check("preloading forty faces did not block the caller", elapsed_us < 16000,
		"took %d us, which is more than a 60 fps frame" % elapsed_us)

	art.shutdown()

	var hits: int = 0
	for code: int in codes:
		if art.texture_for(code) != null:
			hits += 1
	_equal("all forty landed", hits, 40)

	var stats: Dictionary = art.stats()
	_equal("and all forty are cached", stats["cached"], 40)
	_check("forty sd faces fit the 64 MB default",
		int(stats["bytes"]) < CardArt.DEFAULT_BUDGET_BYTES,
		"forty faces is %d bytes" % int(stats["bytes"]))

	print("        preload_codes(40) returned in %d us; cache holds %.1f MB" % [
		elapsed_us, float(stats["bytes"]) / 1048576.0])

	art.shutdown()
	_end()


# ----------------------------------------------------------------------------------------------
# CardView
# ----------------------------------------------------------------------------------------------

func _case_card_view_wears_the_face() -> void:
	_begin("a face-up CardView takes the texture and drops the placeholder tint")
	var art: CardArt = _fresh(CardArt.TIER_SD)
	var texture: Texture2D = _await_texture(art, KNOWN_CODE)
	_check("the face is cached before the view asks", texture != null, "load did not land")

	var view: CardView = CardView.new()
	CardView.art_source = art
	view.set_card_id(KNOWN_CODE)
	view.set_orientation(true, false)

	var material: StandardMaterial3D = _front_material(view)
	_check("the front material carries the face", material.albedo_texture == texture,
		"albedo_texture is %s" % str(material.albedo_texture))
	_equal("and the tint is white so it does not stain the art",
		material.albedo_color, Color.WHITE)

	# A card with no art on disk keeps working, wearing its placeholder colour.
	view.set_card_id(ABSENT_CODE)
	art.shutdown()
	view.refresh_art(art)
	var plain: StandardMaterial3D = _front_material(view)
	_equal("a card with no file keeps the placeholder", plain.albedo_texture == null, true)
	_check("and a non-white tint", plain.albedo_color != Color.WHITE,
		"placeholder colour was white")

	CardView.art_source = null
	view.free()
	art.shutdown()
	_end()


func _case_face_down_never_shows_a_face() -> void:
	_begin("a face-down card, or one with card_id 0, never carries a texture")
	var art: CardArt = _fresh(CardArt.TIER_SD)
	_check("the face is cached", _await_texture(art, KNOWN_CODE) != null, "load did not land")

	var view: CardView = CardView.new()
	CardView.art_source = art
	view.set_card_id(KNOWN_CODE)
	view.set_orientation(true, false)
	_check("face-up carries it", _front_material(view).albedo_texture != null, "no texture")

	view.set_orientation(false, false)
	_equal("turning it face-down strips it",
		_front_material(view).albedo_texture == null, true)

	view.set_orientation(false, true)
	_equal("face-down defense too", _front_material(view).albedo_texture == null, true)

	view.set_orientation(true, true)
	_check("face-up defense gets it back", _front_material(view).albedo_texture != null,
		"no texture")

	# The other half of the rule: the viewer was never told what this card is.
	view.set_card_id(0)
	_equal("card_id 0 carries nothing even face-up",
		_front_material(view).albedo_texture == null, true)

	# And setting an id while face-down must not sneak one back on.
	view.set_orientation(false, false)
	view.set_card_id(KNOWN_CODE)
	_equal("set_card_id on a face-down card stays blank",
		_front_material(view).albedo_texture == null, true)

	CardView.art_source = null
	view.free()
	art.shutdown()
	_end()


# ----------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------

func _fresh(tier: int) -> CardArt:
	var art: CardArt = CardArt.new()
	art.set_roots(_sd_root, _hd_root)
	art.set_tier(tier)
	return art


## Polls `texture_for()` the way a `_process` would, rather than blocking on the pool. That is
## the path the game actually takes, so it is the path worth testing.
func _await_texture(art: CardArt, card_id: int) -> Texture2D:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var texture: Texture2D = art.texture_for(card_id)
		if texture != null:
			return texture
		if art.pending_count() == 0 and art.stats()["misses"] > 0:
			return null
		OS.delay_msec(2)
	return null


func _front_material(view: CardView) -> StandardMaterial3D:
	var front: MeshInstance3D = view.get_node_or_null("Front") as MeshInstance3D
	if front == null:
		return StandardMaterial3D.new()
	return front.material_override as StandardMaterial3D


func _art_is_present() -> bool:
	return FileAccess.file_exists(_sd_root.path_join("%d.jpg" % KNOWN_CODE))


## The first `count` passcodes with an sd file, in directory order. Discovered rather than
## hardcoded so the suite does not depend on which art someone happens to have downloaded.
func _sample_codes(count: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var dir: DirAccess = DirAccess.open(_sd_root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "" and out.size() < count:
		if entry.ends_with(".jpg"):
			var code: int = int(entry.get_basename())
			if code > 0:
				out.append(code)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## A passcode with an sd file and no hd file, or 0 if there is none. `hd/` holds fewer faces
## than `sd/`, so this normally finds one immediately.
func _find_sd_only_code() -> int:
	var dir: DirAccess = DirAccess.open(_sd_root)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.ends_with(".jpg") and not FileAccess.file_exists(_hd_root.path_join(entry)):
			var code: int = int(entry.get_basename())
			if code > 0:
				dir.list_dir_end()
				return code
		entry = dir.get_next()
	dir.list_dir_end()
	return 0


# ----------------------------------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------------------------------

func _begin(name: String) -> void:
	_case_name = name
	_case_failures = PackedStringArray()


func _check(label: String, passed: bool, detail: String) -> void:
	if passed:
		return
	_case_failures.append("%s (%s)" % [label, detail])


func _equal(label: String, actual: Variant, expected: Variant) -> void:
	_check(label, _same(actual, expected), "expected %s, got %s" % [str(expected), str(actual)])


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
