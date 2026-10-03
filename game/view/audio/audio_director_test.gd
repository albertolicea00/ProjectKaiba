extends SceneTree

## Self-checking tests for the audio layer.
##
##   godot --headless --path game --script res://view/audio/audio_director_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, so it can be wired into a
## Makefile target as a gate.
##
## -------------------------------------------------------------------------------------------
## Headless has no audio device, so nothing here listens
## -------------------------------------------------------------------------------------------
## Every case asserts on state: which effect name a kind maps to, which file a lookup resolved
## to, how many times the bank went to the disk, how many players exist. `is_playing()` is never
## consulted, because under the dummy audio driver its answer is evidence about the driver and
## not about this code.
##
## -------------------------------------------------------------------------------------------
## Fixtures, and where they are allowed
## -------------------------------------------------------------------------------------------
## The override and remembered-miss cases build a tiny sound tree under `user://`, because they
## need a per-card override file and the real `data/base/sounds/activate|attack|summon/`
## directories ship EMPTY on purpose - EDOPro ships no per-card sounds and this project invents
## none. Writing a fake `89631139.wav` into the real tree would be inventing one.
##
## The install cases do read the real tree, and SKIP rather than fail when it is absent: `data/`
## is gitignored (AGENTS.md section 9), so a checkout with no sounds is a normal state.

## Blue-Eyes White Dragon. Any passcode would do; a real one makes the fixture readable.
const OVERRIDE_CODE: int = 89631139

## No effect is called this, so it can only ever miss.
const ABSENT_NAME: String = "no_such_effect_zzz"

const FIXTURE_DIR: String = "user://audio_test_sounds"

## How long a case will wait for a worker thread before calling it a failure. Generous: these are
## sub-megabyte reads, so this is a hang detector, not a timing assertion.
const WAIT_MS: int = 5000

var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0


func _init() -> void:
	print("== AudioDirector / SoundBank tests ==")

	_case_every_kind_is_decided()
	_case_conditional_kinds()
	_case_effect_names_exist()
	_case_override_beats_generic()
	_case_missing_is_remembered()
	_case_pool_recycles()
	_case_buses_and_volumes()
	_case_credits_present()
	_case_real_install()

	print("-- %d case(s), %d failed" % [_cases_run, _cases_failed])
	quit(1 if _cases_failed > 0 else 0)


# ----------------------------------------------------------------------------------------------
# Mapping
# ----------------------------------------------------------------------------------------------

## The one that matters. Every `EventTranslator.KIND_*` must appear in `EFFECT_FOR_KIND`, whether
## its answer is a sound or `SILENT`. A kind added upstream and never considered here would be
## silent in a played duel and invisible in every other test, which is exactly the failure this
## case exists to make loud.
func _case_every_kind_is_decided() -> void:
	_begin("every intent kind is either mapped or deliberately silent")

	var kinds: PackedStringArray = _all_kinds()
	_check("the translator exposes its kinds", kinds.size() >= 25,
		"found %d KIND_* constants" % kinds.size())

	var silent: PackedStringArray = PackedStringArray()
	for kind: String in kinds:
		_check("%s is decided" % kind, AudioDirector.knows_kind(kind),
			"no entry in EFFECT_FOR_KIND")
		if AudioDirector.effect_for({"kind": kind}) == AudioDirector.SILENT:
			silent.append(kind)

	# Every entry in the table must be a real kind, too: a typo'd key would read as coverage.
	for key: Variant in AudioDirector.EFFECT_FOR_KIND:
		_check("table key %s is a real kind" % str(key), kinds.has(str(key)),
			"EFFECT_FOR_KIND holds a kind the translator never emits")

	# Not an assertion about which kinds are silent - that is a design decision documented at
	# each entry - but a report, so a reviewer sees the list without reading the table.
	print("        deliberately silent: %s" % ", ".join(silent))

	# An unknown kind must not be mistaken for a decided one.
	_check("an unknown kind is not claimed", not AudioDirector.knows_kind("NOT_A_KIND"),
		"knows_kind() answered yes for a kind that does not exist")
	_end()


## The three kinds whose answer depends on a field of the intent rather than on its kind alone.
func _case_conditional_kinds() -> void:
	_begin("summon kind, life point mode and battle outcome pick the effect")

	_equal("normal summon", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_SUMMON_ANNOUNCE,
		"summon_kind": EventTranslator.SUMMON_NORMAL,
	}), "summon")
	_equal("special summon", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_SUMMON_ANNOUNCE,
		"summon_kind": EventTranslator.SUMMON_SPECIAL,
	}), "specialsummon")
	_equal("flip summon", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_SUMMON_ANNOUNCE,
		"summon_kind": EventTranslator.SUMMON_FLIP,
	}), "flip")

	_equal("damage", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_LP_CHANGE, "mode": EventTranslator.LP_DAMAGE,
	}), "damage")
	_equal("recovery", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_LP_CHANGE, "mode": EventTranslator.LP_RECOVER,
	}), "gainlp")
	_equal("an absolute LP resync is silent", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_LP_CHANGE, "mode": EventTranslator.LP_SET,
	}), AudioDirector.SILENT)

	_equal("a battle that destroys the attacker", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_BATTLE, "from_destroyed": true,
	}), "destroyed")
	_equal("a battle that destroys the defender", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_BATTLE, "to_destroyed": true,
	}), "destroyed")
	_equal("a battle with no casualty is silent", AudioDirector.effect_for({
		"kind": EventTranslator.KIND_BATTLE, "from_destroyed": false, "to_destroyed": false,
	}), AudioDirector.SILENT)
	_end()


## Every name the mapping can produce has to be a file the sound set actually ships, or the
## mapping is pointing at nothing.
func _case_effect_names_exist() -> void:
	_begin("every mapped effect names a file in the sound set")
	for kind: String in _all_kinds():
		for intent: Dictionary in _variants(kind):
			var name: String = AudioDirector.effect_for(intent)
			if name == AudioDirector.SILENT:
				continue
			_check("%s -> %s" % [kind, name], SoundBank.EFFECT_NAMES.has(name),
				"not one of the twenty effects EDOPro ships")
	_end()


# ----------------------------------------------------------------------------------------------
# The bank
# ----------------------------------------------------------------------------------------------

## A per-card file must win over the generic one, and a card with no file must fall back to it
## rather than go silent.
func _case_override_beats_generic() -> void:
	_begin("a per-card override wins over the generic effect")

	var root: String = _build_fixture()
	if root.is_empty():
		_check("fixture", false, "could not write the fixture tree under user://")
		_end()
		return

	var bank: SoundBank = SoundBank.new()
	bank.set_root(root)

	bank.request("summon", OVERRIDE_CODE)
	bank.request("summon", 0)
	bank.request("attack", OVERRIDE_CODE)
	_drain(bank)

	var override_path: String = bank.resolved_path("summon", OVERRIDE_CODE)
	var generic_path: String = bank.resolved_path("summon", 0)
	_check("the override resolved", override_path.ends_with("summon/%d.wav" % OVERRIDE_CODE),
		"got '%s'" % override_path)
	_check("the generic resolved", generic_path.ends_with("summon.wav")
		and not generic_path.ends_with("%d.wav" % OVERRIDE_CODE), "got '%s'" % generic_path)
	_check("they are different files", override_path != generic_path, override_path)

	# `attack` has a generic file and no override for this card: the fallback must answer rather
	# than the lookup failing.
	var fallback: String = bank.resolved_path("attack", OVERRIDE_CODE)
	_check("a card with no override falls back", fallback.ends_with("attack.wav"),
		"got '%s'" % fallback)

	bank.shutdown()
	bank.free()
	_end()


## A file that is not there is an answer, not an error, and the answer is remembered. Measured in
## trips to the filesystem, which is the only thing a remembered miss is supposed to save.
func _case_missing_is_remembered() -> void:
	_begin("a missing file is a remembered miss, not a repeated disk hit")

	var root: String = _build_fixture()
	var bank: SoundBank = SoundBank.new()
	bank.set_root(root)

	_equal("nothing probed yet", bank.probe_count(), 0)

	_check("a cold lookup answers null", bank.effect(ABSENT_NAME) == null, "got a stream")
	_drain(bank)
	var after_first: int = bank.probe_count()
	_equal("one probe for one miss", after_first, 1)
	_check("the miss is remembered", bank.is_absent(ABSENT_NAME), "is_absent() said no")

	for _i: int in range(50):
		_check("every later lookup still answers null", bank.effect(ABSENT_NAME) == null,
			"got a stream")
	_drain(bank)
	_equal("no further probes", bank.probe_count(), after_first)
	_equal("one miss recorded, not fifty", int(bank.stats().get("misses", -1)), 1)

	# A hit is remembered the same way: a second lookup must not go back to the disk either.
	bank.effect("summon", 0)
	_drain(bank)
	var after_hit: int = bank.probe_count()
	_check("the hit loaded", bank.is_loaded("summon", 0), "stream never arrived")
	for _i: int in range(50):
		bank.effect("summon", 0)
	_equal("a cached hit costs no probes", bank.probe_count(), after_hit)

	bank.shutdown()
	bank.free()
	_end()


# ----------------------------------------------------------------------------------------------
# The director
# ----------------------------------------------------------------------------------------------

## The pool is fixed. Asking for more players than exist steals the oldest; it never allocates.
func _case_pool_recycles() -> void:
	_begin("the player pool recycles instead of growing")

	var director: AudioDirector = AudioDirector.new()
	# `_ready()` never fires for a node that was never inside a running tree, and this script is
	# a `SceneTree` with no running tree of its own.
	director.initialise()

	var before: Dictionary = director.pool_stats()
	_equal("the pool is built once", int(before.get("size", -1)), AudioDirector.POOL_SIZE)
	_equal("nothing stolen yet", int(before.get("steals", -1)), 0)

	# Claim more players than exist, holding every one busy well past the end of the case so the
	# pool is genuinely exhausted rather than quietly recycling a finished player.
	var now: float = float(Time.get_ticks_msec())
	var overflow: int = 3
	var seen: Dictionary = {}
	for index: int in range(AudioDirector.POOL_SIZE + overflow):
		var claimed: int = director._claim(now)
		_check("claim %d is in range" % index,
			claimed >= 0 and claimed < AudioDirector.POOL_SIZE, "got %d" % claimed)
		seen[claimed] = true
		director._busy_until[claimed] = now + 60000.0

	var after: Dictionary = director.pool_stats()
	_equal("the pool did not grow", int(after.get("size", -1)), AudioDirector.POOL_SIZE)
	_equal("every player was used", seen.size(), AudioDirector.POOL_SIZE)
	_equal("the overflow stole, it did not allocate", int(after.get("steals", -1)), overflow)
	_equal("the node holds exactly the pool, the music pair and the bank",
		director.get_child_count(), AudioDirector.POOL_SIZE + 3)

	# Silence must stay silent: a SILENT mapping never reaches the pool at all.
	var plays_before: int = int(director.pool_stats().get("plays", -1))
	director._on_intent_started({"kind": EventTranslator.KIND_SUMMON_COMPLETE})
	director._on_intent_started({"kind": EventTranslator.KIND_BANISH})
	_equal("a silent kind plays nothing",
		int(director.pool_stats().get("plays", -1)), plays_before)

	# And an unknown kind is logged once, not swallowed and not fatal (V13's spirit).
	director._on_intent_started({"kind": "SOMETHING_NEW"})
	director._on_intent_started({"kind": "SOMETHING_NEW"})
	_equal("an unknown kind is noticed once", director.unknown_kinds().size(), 1)

	if director.bank() != null:
		director.bank().shutdown()
	director.free()
	_end()


## The volume model is three buses, not eleven `volume_db` fields.
func _case_buses_and_volumes() -> void:
	_begin("master / effects / music are separate buses and persist")

	AudioSettings.ensure_buses()
	for bus: StringName in [
		AudioSettings.BUS_MASTER, AudioSettings.BUS_EFFECTS, AudioSettings.BUS_MUSIC
	]:
		_check("bus %s exists" % bus, AudioServer.get_bus_index(bus) != -1, "not found")

	var effects_index: int = AudioServer.get_bus_index(AudioSettings.BUS_EFFECTS)
	var music_index: int = AudioServer.get_bus_index(AudioSettings.BUS_MUSIC)
	_equal("effects routes to master",
		AudioServer.get_bus_send(effects_index), AudioSettings.BUS_MASTER)
	_equal("music routes to master",
		AudioServer.get_bus_send(music_index), AudioSettings.BUS_MASTER)

	var settings: AudioSettings = AudioSettings.new()
	settings.load_settings()
	settings.set_effects(0.5)
	settings.set_music(0.25)
	settings.apply()
	_check("effects took the volume",
		is_equal_approx(AudioServer.get_bus_volume_db(effects_index), linear_to_db(0.5)),
		"%.3f dB" % AudioServer.get_bus_volume_db(effects_index))
	_check("the two buses are independent",
		not is_equal_approx(
			AudioServer.get_bus_volume_db(effects_index),
			AudioServer.get_bus_volume_db(music_index)),
		"both buses ended up at the same level")

	settings.set_music(0.0)
	_check("zero mutes rather than approximating silence",
		AudioServer.is_bus_mute(music_index), "the music bus is not muted at 0.0")

	_check("settings are written", settings.save_settings(), "save_settings() refused")
	var reloaded: AudioSettings = AudioSettings.new()
	reloaded.load_settings()
	_check("and read back", is_equal_approx(reloaded.effects(), 0.5),
		"got %.3f" % reloaded.effects())

	# Leave the defaults behind rather than a test's volumes.
	settings.set_master(AudioSettings.DEFAULT_MASTER)
	settings.set_effects(AudioSettings.DEFAULT_EFFECTS)
	settings.set_music(AudioSettings.DEFAULT_MUSIC)
	settings.save_settings()
	_end()


# ----------------------------------------------------------------------------------------------
# The install
# ----------------------------------------------------------------------------------------------

## The attribution is a licence condition, not documentation: several effects are CC-BY 3.0 and
## the music is by named artists. If it stops travelling with the sounds, the install is not
## legal to pass on. `.gitignore` keeps this one file tracked on purpose.
func _case_credits_present() -> void:
	_begin("CREDITS.md travels with the sounds")

	var path: String = SoundBank.default_root().path_join("CREDITS.md")
	var exists: bool = FileAccess.file_exists(path)
	_check("CREDITS.md is in data/base/sounds/", exists, "not at %s" % path)
	if not exists:
		_end()
		return

	var text: String = FileAccess.get_file_as_string(path)
	_check("it has content", text.length() > 500, "only %d bytes" % text.length())
	_check("the CC-BY attribution survived", text.contains("Creative Commons Attribution"),
		"no CC-BY clause found")
	for artist: String in ["Ketsa", "Chad Crouch", "Steve Combs"]:
		_check("the music credit for %s survived" % artist, text.contains(artist), "missing")
	_end()


## The real tree, when there is one. SKIP, not FAIL, on a checkout without `data/`.
func _case_real_install() -> void:
	_begin("the installed sound set has everything the mapping asks for")

	var root: String = SoundBank.default_root()
	if not DirAccess.dir_exists_absolute(root) or not FileAccess.file_exists(
		root.path_join("summon.wav")
	):
		print("SKIP  no sounds under %s - install them from the EDOPro sound set" % root)
		_case_name = ""
		return

	for name: String in SoundBank.EFFECT_NAMES:
		_check("%s.wav is installed" % name,
			FileAccess.file_exists(root.path_join("%s.wav" % name)), "missing")

	for leaf: String in SoundBank.OVERRIDABLE:
		_check("the %s/ override directory exists" % leaf,
			DirAccess.dir_exists_absolute(root.path_join(leaf)), "missing")

	var bank: SoundBank = SoundBank.new()
	for context: String in [
		AudioDirector.MUSIC_MENU, AudioDirector.MUSIC_DUEL,
		AudioDirector.MUSIC_WIN, AudioDirector.MUSIC_LOSE,
		AudioDirector.MUSIC_ADVANTAGE, AudioDirector.MUSIC_DISADVANTAGE,
		AudioDirector.MUSIC_DECK,
	]:
		bank.music(context)
		_drain(bank)
		_check("BGM/%s has a track" % context, not bank.music_is_absent(context),
			"no playable file in BGM/%s/" % context)

	# One track resident at a time, whatever was asked for along the way.
	_check("exactly one music context is held",
		str(bank.stats().get("music", "")) == AudioDirector.MUSIC_DECK,
		"held '%s'" % str(bank.stats().get("music", "")))

	# A real stream really builds from bytes outside res://.
	bank.request("summon", 0)
	_drain(bank)
	var stream: AudioStream = bank.effect("summon", 0)
	_check("summon.wav decoded from bytes", stream is AudioStreamWAV, "got %s" % str(stream))
	if stream != null:
		_check("and has a sensible duration",
			stream.get_length() > 0.05 and stream.get_length() < 30.0,
			"%.3f s" % stream.get_length())

	bank.shutdown()
	bank.free()
	_end()


# ----------------------------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------------------------

## A minimal sound tree under `user://`: `summon.wav`, `attack.wav` and one per-card override.
## Returns the absolute root, or `""` if it could not be written.
func _build_fixture() -> String:
	var root: String = ProjectSettings.globalize_path(FIXTURE_DIR).simplify_path()
	if DirAccess.make_dir_recursive_absolute(root.path_join("summon")) != OK:
		return ""

	# Rewritten every run rather than reused: a fixture left over from an older revision of this
	# file would quietly test the old shape.
	for path: String in [
		root.path_join("summon.wav"),
		root.path_join("attack.wav"),
		root.path_join("summon").path_join("%d.wav" % OVERRIDE_CODE),
	]:
		if _tone().save_to_wav(path) != OK:
			return ""
	return root


## A fraction of a second of 8-bit noise. Nothing here listens to it; it exists so that
## `load_from_buffer()` has real RIFF bytes to parse.
func _tone() -> AudioStreamWAV:
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = 22050
	var data: PackedByteArray = PackedByteArray()
	# Even, deliberately: Godot's own `save_to_wav()` does not pad an odd-sized `data` chunk, and
	# its reader then seeks one byte past the end looking for the next chunk and logs an error.
	# An even payload sidesteps a quirk that has nothing to do with what this case is testing.
	data.resize(2204)
	for index: int in range(data.size()):
		data[index] = 128 + int(64.0 * sin(float(index) * 0.1))
	wav.data = data
	return wav


## Waits for a bank's worker threads. These are sub-megabyte reads, so a timeout is a hang.
func _drain(bank: SoundBank) -> void:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while bank.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		OS.delay_msec(5)
	if bank.pending_count() > 0:
		_check("worker drain", false, "%d load(s) still pending after %d ms"
			% [bank.pending_count(), WAIT_MS])


## Every `KIND_*` constant the translator declares, read off the script rather than listed here,
## so a kind added upstream shows up in this suite without anyone remembering to add it.
func _all_kinds() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var constants: Dictionary = (EventTranslator as GDScript).get_script_constant_map()
	for key: Variant in constants:
		var name: String = str(key)
		if name.begins_with("KIND_") and constants[key] is String:
			out.append(str(constants[key]))
	out.sort()
	return out


## Every shape of one kind the mapping can answer differently, so the name check covers the
## conditional branches and not just the table default.
func _variants(kind: String) -> Array[Dictionary]:
	match kind:
		EventTranslator.KIND_SUMMON_ANNOUNCE:
			return [
				{"kind": kind, "summon_kind": EventTranslator.SUMMON_NORMAL},
				{"kind": kind, "summon_kind": EventTranslator.SUMMON_SPECIAL},
				{"kind": kind, "summon_kind": EventTranslator.SUMMON_FLIP},
			]
		EventTranslator.KIND_LP_CHANGE:
			return [
				{"kind": kind, "mode": EventTranslator.LP_DAMAGE},
				{"kind": kind, "mode": EventTranslator.LP_RECOVER},
				{"kind": kind, "mode": EventTranslator.LP_SET},
			]
		EventTranslator.KIND_BATTLE:
			return [
				{"kind": kind, "from_destroyed": true},
				{"kind": kind, "to_destroyed": true},
				{"kind": kind},
			]
	return [{"kind": kind}]


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
	if _case_name.is_empty():
		return
	_cases_run += 1
	if _case_failures.is_empty():
		print("PASS  %s" % _case_name)
		_case_name = ""
		return
	_cases_failed += 1
	print("FAIL  %s" % _case_name)
	for failure: String in _case_failures:
		print("        %s" % failure)
	_case_name = ""
