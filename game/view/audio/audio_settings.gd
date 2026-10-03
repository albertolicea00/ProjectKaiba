class_name AudioSettings
extends RefCounted

## Master / effects / music volumes, as Godot audio buses, persisted to `user://`.
##
## Layer: L4 (AGENTS.md section 4). Nothing here names L1 or L2 (V1), and no audio code of any
## kind belongs under `game/core/` (V2) - an `AudioStreamPlayer` is a scene node.
##
## -------------------------------------------------------------------------------------------
## Why buses and not per-player volume
## -------------------------------------------------------------------------------------------
## A pool of effect players plus two music players is eleven `volume_db` fields that would all
## have to be rewritten whenever a slider moves, and the music crossfade already owns the music
## players' `volume_db` for its envelope. Two numbers cannot live in one field. A bus is the one
## place where "all effects, quieter" is expressible without the mixer and the crossfade fighting
## over the same property: each player keeps its own envelope, the bus scales the result.
##
## -------------------------------------------------------------------------------------------
## The buses are created at runtime, deliberately
## -------------------------------------------------------------------------------------------
## The alternative is a `default_bus_layout.tres` committed next to `project.godot`. That file is
## editor-authored binary-ish state that nothing else in this repo owns, and a missing or stale
## copy fails as "my volume slider does nothing" rather than as an error. `ensure_buses()` is
## idempotent, costs a name lookup when the buses already exist, and makes the routing readable
## in source. It is safe to call from several places.
##
## -------------------------------------------------------------------------------------------
## Linear in, decibels out
## -------------------------------------------------------------------------------------------
## Stored and exposed as 0.0..1.0 linear, because that is what a slider is and what a settings
## file should hold. Converted with `linear_to_db()` at the bus. Exactly 0.0 mutes the bus rather
## than setting -inf dB: both silence it, but a muted bus is the state the engine reports back,
## so "is the music off?" has an answer that does not depend on float comparison.

const BUS_MASTER: StringName = &"Master"
const BUS_EFFECTS: StringName = &"Effects"
const BUS_MUSIC: StringName = &"Music"

## Where the three numbers live between runs. `user://` is per-platform and always writable;
## on Android it is app-private storage, which is the only place a phone will let us write.
const SETTINGS_PATH: String = "user://audio.cfg"
const SETTINGS_SECTION: String = "audio"

## Loud enough to be heard over a phone speaker, quiet enough that the first launch is not a
## shock. Music sits well under the effects because it plays continuously and they do not.
const DEFAULT_MASTER: float = 0.9
const DEFAULT_EFFECTS: float = 0.8
const DEFAULT_MUSIC: float = 0.5

var _master: float = DEFAULT_MASTER
var _effects: float = DEFAULT_EFFECTS
var _music: float = DEFAULT_MUSIC

## True once `load()` has read a file, so `save()` from a fresh object cannot overwrite a real
## settings file with defaults it never looked at.
var _loaded: bool = false


# ----------------------------------------------------------------------------------------------
# Buses
# ----------------------------------------------------------------------------------------------

## Creates `Effects` and `Music` under `Master` if they are not already there, and returns true
## either way. Idempotent; call it before the first player is given a bus name.
static func ensure_buses() -> bool:
	for bus: StringName in [BUS_EFFECTS, BUS_MUSIC]:
		if AudioServer.get_bus_index(bus) != -1:
			continue
		var index: int = AudioServer.get_bus_count()
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, bus)
		AudioServer.set_bus_send(index, BUS_MASTER)
	return true


static func bus_index(bus: StringName) -> int:
	return AudioServer.get_bus_index(bus)


# ----------------------------------------------------------------------------------------------
# Volumes
# ----------------------------------------------------------------------------------------------

func master() -> float:
	return _master


func effects() -> float:
	return _effects


func music() -> float:
	return _music


func set_master(value: float) -> void:
	_master = clampf(value, 0.0, 1.0)
	_apply_one(BUS_MASTER, _master)


func set_effects(value: float) -> void:
	_effects = clampf(value, 0.0, 1.0)
	_apply_one(BUS_EFFECTS, _effects)


func set_music(value: float) -> void:
	_music = clampf(value, 0.0, 1.0)
	_apply_one(BUS_MUSIC, _music)


## Pushes all three onto the buses. Creates the buses first, so a caller never has to remember
## the order.
func apply() -> void:
	ensure_buses()
	_apply_one(BUS_MASTER, _master)
	_apply_one(BUS_EFFECTS, _effects)
	_apply_one(BUS_MUSIC, _music)


# ----------------------------------------------------------------------------------------------
# Persistence
# ----------------------------------------------------------------------------------------------

## Reads `user://audio.cfg`. A missing file is the normal first-run state and leaves the
## defaults standing; it is not an error and nothing is written in response.
func load_settings() -> bool:
	_loaded = true
	var config: ConfigFile = ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return false
	_master = clampf(float(config.get_value(SETTINGS_SECTION, "master", DEFAULT_MASTER)), 0.0, 1.0)
	_effects = clampf(float(config.get_value(SETTINGS_SECTION, "effects", DEFAULT_EFFECTS)), 0.0, 1.0)
	_music = clampf(float(config.get_value(SETTINGS_SECTION, "music", DEFAULT_MUSIC)), 0.0, 1.0)
	return true


## Writes the three numbers. Refuses to run before `load_settings()` has been called at least
## once, so a half-built object cannot flatten a real settings file.
func save_settings() -> bool:
	if not _loaded:
		return false
	var config: ConfigFile = ConfigFile.new()
	# Preserve anything else the file holds; a future settings screen may add keys.
	config.load(SETTINGS_PATH)
	config.set_value(SETTINGS_SECTION, "master", _master)
	config.set_value(SETTINGS_SECTION, "effects", _effects)
	config.set_value(SETTINGS_SECTION, "music", _music)
	return config.save(SETTINGS_PATH) == OK


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

func _apply_one(bus: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus)
	if index == -1:
		return
	var silent: bool = linear <= 0.0
	AudioServer.set_bus_mute(index, silent)
	AudioServer.set_bus_volume_db(index, -80.0 if silent else linear_to_db(linear))
