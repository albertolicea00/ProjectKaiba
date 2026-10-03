class_name AudioDirector
extends Node

## Sound for a duel, driven by the same intent stream the animation is driven by.
##
## Layer: L4 (AGENTS.md section 4). Nothing here names `KaibaCore`, `MsgParser` or anything under
## `native/` (V1). It is a scene node and owns `AudioStreamPlayer`s, which is precisely why none
## of it may live under `game/core/` (V2).
##
## -------------------------------------------------------------------------------------------
## One stream of intents, not two
## -------------------------------------------------------------------------------------------
## `bind()` connects to `AnimationDirector.intent_started`. That is the whole input. There is
## deliberately no second path from the duel to the audio layer - no `DuelState` subscription, no
## tap on the event poll in the scene, nothing that could deliver a sound the animation does not
## also show. A second path would be a second clock, and two clocks drift: the summon sound would
## land before the card left the hand, or after it had already settled, depending on how far the
## director had been allowed to lag. Listening to the director means the sound fires when the
## animation for that intent begins, by construction, with no synchronisation code at all.
##
## It also means `AnimationDirector` needs no changes to gain audio, and would need none to lose
## it again. The coupling is one signal, one way.
##
## -------------------------------------------------------------------------------------------
## Every kind is accounted for
## -------------------------------------------------------------------------------------------
## `EFFECT_FOR_KIND` holds an entry for every `EventTranslator.KIND_*`, and an entry may be
## `SILENT`. A kind with no entry at all is a bug and `audio_director_test.gd` fails on it: the
## failure mode this prevents is a new intent kind being added upstream and simply never making a
## sound, which is invisible in a headless test and nearly invisible in a played duel.
##
## Three kinds need more than a table lookup and get it in `effect_for()`:
##   SUMMON_ANNOUNCE  the subkind decides - normal, special or flip summon.
##   LP_CHANGE        damage and recovery are opposite beats; an absolute resync is neither.
##   BATTLE           only a clash that destroys something gets the destruction sound; a battle
##                    that resolves without a casualty was already announced by ATTACK.
##
## -------------------------------------------------------------------------------------------
## A pool, and what happens when it runs out
## -------------------------------------------------------------------------------------------
## Several effects legitimately overlap: a battle destroys two monsters and deals damage inside
## one beat. `POOL_SIZE` players are created once, in `_ready()`, and never added to. When all of
## them are busy the OLDEST is stolen - the sound that has been playing longest is cut, and the
## new one is heard. The alternative, dropping the new sound, silences the event that is
## happening now in favour of one the player has already heard most of, which is exactly
## backwards. The pool never grows, because an unbounded pool on a phone is a slow leak that only
## shows up during the noisiest moment of a duel.
##
## -------------------------------------------------------------------------------------------
## Volume
## -------------------------------------------------------------------------------------------
## Three buses - Master, Effects, Music - owned by `AudioSettings` and persisted to `user://`.
## Players are assigned to a bus and their own `volume_db` is left alone, except on the two music
## players, where it is the crossfade envelope and nothing else. See `audio_settings.gd`.

## No sound for this intent, said explicitly. Distinct from "no entry", which is a bug.
const SILENT: String = ""

## Music contexts, matching the directory names under `data/base/sounds/BGM/`.
const MUSIC_MENU: String = "menu"
const MUSIC_DUEL: String = "duel"
const MUSIC_WIN: String = "win"
const MUSIC_LOSE: String = "lose"

## Wired, and deliberately unused. `advantage`, `disadvantage` and `deck` are real directories
## with real tracks, but nothing in this project computes who is ahead or opens a deck editor's
## own screen yet. Inventing a life-point heuristic here - "below 2000 is disadvantage" - would
## be a rule invented in the view layer to drive a mood, and it would be wrong the first time
## someone played a burn deck. They stay reachable through `set_music_context()` for whoever adds
## the state that actually means them.
const MUSIC_ADVANTAGE: String = "advantage"
const MUSIC_DISADVANTAGE: String = "disadvantage"
const MUSIC_DECK: String = "deck"

## Enough for a battle that destroys both monsters, deals damage and changes phase inside one
## beat, with headroom. Small enough that eight decoded buffers are never the reason a phone is
## short of memory.
const POOL_SIZE: int = 8

## Two effects with the same name starting inside this window are one sound. A five-card draw
## emits five non-blocking DRAW intents that the director starts in the same frame; without this
## they phase against each other and the result is a flange, not a draw. Per name, so a draw and
## a phase change in the same frame are both heard.
const RETRIGGER_GUARD_MS: int = 60

## Seconds for a music change. Long enough to read as a transition rather than a cut, short
## enough that a win jingle is not still arriving when the screen has moved on.
const CROSSFADE_SECONDS: float = 1.5

## Treated as silence for the crossfade envelope. Godot's own floor is -80 dB.
const MIN_DB: float = -80.0

## Intent kind -> effect name, or `SILENT`. Every `EventTranslator.KIND_*` appears exactly once.
## The three kinds whose answer depends on a field are listed here with their most common answer
## and overridden in `effect_for()`; the table is still the place to look for coverage.
const EFFECT_FOR_KIND: Dictionary = {
	# ---- movement ---------------------------------------------------------------------------
	# The unclassified residue of `move_kind()`: a card went somewhere none of the named kinds
	# describe. Sounding it would mean guessing, and guessing wrong on every odd move.
	# Three sounds that shipped with the set but had nothing to attach to until the translator
	# learned to emit these kinds. MsgParser had been decoding MSG_EQUIP, MSG_TOSS_COIN and
	# MSG_TOSS_DICE since batch 2; the events simply stopped at L3. EDOPro sounds all three.
	EventTranslator.KIND_EQUIP: "equip",
	EventTranslator.KIND_COIN_TOSS: "coinflip",
	EventTranslator.KIND_DICE_ROLL: "diceroll",

	EventTranslator.KIND_MOVE: SILENT,
	EventTranslator.KIND_SUMMON: "summon",
	EventTranslator.KIND_SPECIAL_SUMMON: "specialsummon",
	EventTranslator.KIND_SET: "set",
	# A tributed monster leaves the field as a cost. Nothing in the set is a tribute sound;
	# `destroyed` is what a monster leaving the field sounds like, and the summon it paid for
	# follows immediately, which reads as cause and effect.
	EventTranslator.KIND_TRIBUTE: "destroyed",
	# Nothing here is a card-to-graveyard sound. Borrowing `destroyed` would make a hand discard
	# sound like a destruction, which it is not - a discarded card was never destroyed and cards
	# that care about the difference are common.
	EventTranslator.KIND_DISCARD: SILENT,
	EventTranslator.KIND_DESTROY: "destroyed",
	# Material being gathered for a fusion, synchro, xyz, link or ritual summon. The summon it
	# feeds sounds a fraction of a second later; sounding each of three materials first turns one
	# beat into four.
	EventTranslator.KIND_MATERIAL: SILENT,
	# An xyz material going onto, or coming off, a host monster. `addcounter` / `removecounter`
	# are short pings, which is what stacking and spending an overlay unit should sound like.
	EventTranslator.KIND_ATTACH: "addcounter",
	EventTranslator.KIND_DETACH: "removecounter",
	# A card entering the model from nowhere - a token, mostly. The special summon that puts it
	# there carries the beat; this is the bookkeeping half of the same moment.
	EventTranslator.KIND_CREATE: SILENT,
	# The mirror image: a card leaving the model entirely. Bookkeeping.
	EventTranslator.KIND_REMOVE: SILENT,
	# Reached by anything sent to the graveyard for a reason none of DESTROY / DISCARD / TRIBUTE /
	# MATERIAL claimed. Those four already sounded for every common route to the graveyard, so a
	# sound here would mostly double them.
	EventTranslator.KIND_TO_GRAVE: SILENT,
	# Banishing is a strong beat and the sound set has nothing for it. Reusing `destroyed` would
	# actively mislead: banished cards are not in the graveyard and half the game cares.
	EventTranslator.KIND_BANISH: SILENT,
	# A card sliding into a hand, which is what `draw.wav` is - a sliding envelope. The same
	# motion, so the same sound.
	EventTranslator.KIND_TO_HAND: "draw",
	EventTranslator.KIND_TO_DECK: "shuffle",
	# The extra deck is not shuffled and is not a pile you riffle, so `shuffle` would be a lie
	# about a zone the player can see.
	EventTranslator.KIND_TO_EXTRA: SILENT,
	# A card arriving in a zone without a summon or a set to explain it. The explaining kind -
	# SUMMON, SPECIAL_SUMMON, SET - sounds for every normal arrival.
	EventTranslator.KIND_PLACE_MONSTER: SILENT,
	EventTranslator.KIND_PLACE_SPELL: SILENT,
	# ---- summoning --------------------------------------------------------------------------
	# Overridden by `summon_kind` in `effect_for()`; "summon" is the NORMAL case.
	EventTranslator.KIND_SUMMON_ANNOUNCE: "summon",
	# A payload-free sequencing marker (AGENTS.md section 8b.4). The announce already sounded.
	EventTranslator.KIND_SUMMON_COMPLETE: SILENT,
	# ---- cards and positions ----------------------------------------------------------------
	EventTranslator.KIND_DRAW: "draw",
	# A monster turning between attack and defence. `set.wav` is the sound of a card being put
	# down on the field, which is the closest the set has to a card physically turning in place.
	EventTranslator.KIND_POS_CHANGE: "set",
	EventTranslator.KIND_FLIP: "flip",
	# ---- battle -----------------------------------------------------------------------------
	EventTranslator.KIND_ATTACK: "attack",
	# A negated attack. The set has no negation sound and borrowing one would announce something
	# that did not happen.
	EventTranslator.KIND_ATTACK_CANCEL: SILENT,
	# Overridden in `effect_for()`: only a clash with a casualty sounds. See the header.
	EventTranslator.KIND_BATTLE: "destroyed",
	# Overridden by `mode` in `effect_for()`; "damage" is the DAMAGE case.
	EventTranslator.KIND_LP_CHANGE: "damage",
	# ---- flow -------------------------------------------------------------------------------
	EventTranslator.KIND_TURN_START: "nextturn",
	EventTranslator.KIND_PHASE_CHANGE: "phase",
}

## Set false to keep everything wired but silent, without unbinding anything.
@export var enabled: bool = true

var _bank: SoundBank = null
var _settings: AudioSettings = null
var _director: AnimationDirector = null

## `POOL_SIZE` players, created once in `_ready()` and never added to.
var _pool: Array[AudioStreamPlayer] = []

## Milliseconds at which each pooled player is expected to be free again. Kept here rather than
## read back from `is_playing()` because a headless run has no audio device and the engine's
## answer there is not evidence about the pool's logic. The `finished` signal clears it early
## when there is a device; the timestamp is what makes the behaviour testable without one.
var _busy_until: PackedFloat64Array = PackedFloat64Array()

## Effect name -> the millisecond it last started. See `RETRIGGER_GUARD_MS`.
var _last_started: Dictionary = {}

## How many times the pool has had to cut a playing sound short. A steadily rising number means
## `POOL_SIZE` is too small for the way the duel actually sounds.
var _steals: int = 0

var _plays: int = 0
var _suppressed: int = 0

## Kinds seen with no entry in `EFFECT_FOR_KIND`, warned about once each. V13's spirit: an
## unknown kind logs and continues, it never stops the duel.
var _unknown_kinds: Dictionary = {}

# --- music ------------------------------------------------------------------------------------
var _music_players: Array[AudioStreamPlayer] = []
var _active_music: int = 0
var _wanted_context: String = ""
var _playing_context: String = ""

## 0.0..1.0 through the crossfade, or -1.0 when no crossfade is running.
var _fade: float = -1.0


## True when this process has no speakers to send anything to: a headless run uses Godot's Dummy
## audio driver, which never mixes.
##
## Everything above the device still happens - the mapping is evaluated, the bank loads, the pool
## is claimed and stolen from, `pool_stats()` counts - so a headless duel is still evidence about
## this code. Only the final `play()` is skipped, for a reason that is not an optimisation: the
## Dummy driver takes an `AudioStreamPlayback` from every `play()` and only releases it on its
## next mix step, which never comes, so the process exits holding a dozen of them and reports
## `ObjectDB instances leaked at exit`. That warning is Godot's, not ours, and it would appear in
## the log of every headless duel run from here on.
var _no_output: bool = false

## Set by `initialise()`, so a test that builds this node outside a running tree and a scene that
## lets `_ready()` do it cannot both build the pool.
var _initialised: bool = false


func _ready() -> void:
	initialise()


## Builds the settings, the bank and both pools. `_ready()` calls it; a test that constructs this
## node before the scene tree is running calls it directly, because `_ready()` never fires for a
## node that was never inside a tree. Idempotent.
func initialise() -> void:
	if _initialised:
		return
	_initialised = true
	_no_output = DisplayServer.get_name() == "headless"

	_settings = AudioSettings.new()
	_settings.load_settings()
	_settings.apply()

	if _bank == null:
		_bank = SoundBank.new()
		_bank.name = "SoundBank"
		add_child(_bank)
	# Twenty files, 6.9 MB, all queued on worker threads before the first intent arrives. Without
	# this the first occurrence of every effect in a duel is silent, because a cache miss
	# deliberately does not block (see `sound_bank.gd`).
	_bank.prewarm()

	for index: int in range(POOL_SIZE):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "Effect%d" % index
		player.bus = AudioSettings.BUS_EFFECTS
		add_child(player)
		_pool.append(player)
		_busy_until.append(0.0)
		player.finished.connect(_on_effect_finished.bind(index))

	for index: int in range(2):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "Music%d" % index
		player.bus = AudioSettings.BUS_MUSIC
		player.volume_db = MIN_DB
		add_child(player)
		_music_players.append(player)

	set_process(true)


## Released by hand, in this order, because neither half cleans itself up.
##
## `AudioServer` keeps an `AudioStreamPlayback` alive for every player that was still playing
## when it was freed, and at process exit those show up as leaked instances - thirteen of them,
## measured, after one headless duel. Stopping each player and dropping its stream hands them
## back before the node goes away. The bank is drained second so no worker is still inside it.
func _exit_tree() -> void:
	for player: AudioStreamPlayer in _pool:
		player.stop()
		player.stream = null
	for player: AudioStreamPlayer in _music_players:
		player.stop()
		player.stream = null
	_fade = -1.0
	if _bank != null:
		_bank.shutdown()


# ----------------------------------------------------------------------------------------------
# Wiring
# ----------------------------------------------------------------------------------------------

## The only input. Connects to `intent_started` and nothing else; see the header for why there is
## no second path. Safe to call twice and safe to call with the same director twice.
func bind(director: AnimationDirector) -> void:
	if director == _director:
		return
	if _director != null and _director.intent_started.is_connected(_on_intent_started):
		_director.intent_started.disconnect(_on_intent_started)
	_director = director
	if _director != null and not _director.intent_started.is_connected(_on_intent_started):
		_director.intent_started.connect(_on_intent_started)


func bank() -> SoundBank:
	return _bank


func settings() -> AudioSettings:
	return _settings


# ----------------------------------------------------------------------------------------------
# Mapping
# ----------------------------------------------------------------------------------------------

## The effect name for one intent, or `SILENT`. Pure: no node, no disk, no audio device, which is
## what lets the test assert the whole mapping without one.
static func effect_for(intent: Dictionary) -> String:
	var kind: String = str(intent.get("kind", ""))
	if not EFFECT_FOR_KIND.has(kind):
		return SILENT

	match kind:
		EventTranslator.KIND_SUMMON_ANNOUNCE:
			match str(intent.get("summon_kind", EventTranslator.SUMMON_NORMAL)):
				EventTranslator.SUMMON_SPECIAL:
					return "specialsummon"
				EventTranslator.SUMMON_FLIP:
					return "flip"
				_:
					return "summon"
		EventTranslator.KIND_LP_CHANGE:
			match str(intent.get("mode", EventTranslator.LP_DAMAGE)):
				EventTranslator.LP_RECOVER:
					return "gainlp"
				EventTranslator.LP_SET:
					# An absolute total, not a change. `LPUPDATE` is how the engine resynchronises
					# the readout - it fires with no damage and no recovery behind it, so a sound
					# here would announce an event that did not happen.
					return SILENT
				_:
					return "damage"
		EventTranslator.KIND_BATTLE:
			var destroyed: bool = (
				bool(intent.get("from_destroyed", false))
				or bool(intent.get("to_destroyed", false))
			)
			# A clash with no casualty was already announced by the ATTACK intent a moment
			# earlier; sounding the destruction effect anyway would report a death that did not
			# occur.
			return "destroyed" if destroyed else SILENT

	return str(EFFECT_FOR_KIND[kind])


## True when `kind` is in the table at all, whatever its answer. The distinction the test cares
## about: `SILENT` is a decision, a missing key is an oversight.
static func knows_kind(kind: String) -> bool:
	return EFFECT_FOR_KIND.has(kind)


# ----------------------------------------------------------------------------------------------
# Effects
# ----------------------------------------------------------------------------------------------

func _on_intent_started(intent: Dictionary) -> void:
	var kind: String = str(intent.get("kind", ""))
	if not EFFECT_FOR_KIND.has(kind):
		_warn_unknown(kind)
		return
	var name: String = effect_for(intent)
	if name == SILENT:
		return
	# `card_id` is 0 for a face-down or unrevealed card, which is exactly the case where a
	# per-card sound must not be used: it would tell the opponent what the card is.
	play_effect(name, int(intent.get("card_id", 0)))


## Plays one effect by name, preferring a per-card override. Safe to call with a sound that has
## not loaded yet - the bank answers `null` and nothing happens, which is the same contract the
## card art has.
func play_effect(name: String, card_id: int = 0) -> bool:
	if not enabled or _bank == null or name.is_empty():
		return false

	var now: float = float(Time.get_ticks_msec())
	var last: float = float(_last_started.get(name, -1e12))
	if now - last < float(RETRIGGER_GUARD_MS):
		_suppressed += 1
		return false

	var stream: AudioStream = _bank.effect(name, card_id)
	if stream == null and card_id > 0:
		# The override is still loading or absent. The generic effect is the point of the
		# fallback, so take it rather than drop the beat.
		stream = _bank.effect(name, 0)
	if stream == null:
		return false

	var index: int = _claim(now)
	var player: AudioStreamPlayer = _pool[index]
	player.stream = stream
	if not _no_output:
		player.play()
	_busy_until[index] = now + maxf(stream.get_length(), 0.05) * 1000.0
	_last_started[name] = now
	_plays += 1
	return true


## The pooled player to use next: the first one free, or the one that has been playing longest.
##
## Stealing rather than growing is the whole point - see the header. `now` is passed in so the
## caller and the pool agree on one timestamp for one play.
func _claim(now: float) -> int:
	var oldest: int = 0
	for index: int in range(_pool.size()):
		if _busy_until[index] <= now:
			return index
		if _busy_until[index] < _busy_until[oldest]:
			oldest = index
	_steals += 1
	_pool[oldest].stop()
	return oldest


func _on_effect_finished(index: int) -> void:
	if index >= 0 and index < _busy_until.size():
		_busy_until[index] = 0.0


## `{"size", "busy", "steals", "plays", "suppressed"}`. `size` is the claim the test makes: the
## pool is `POOL_SIZE` before the first sound and `POOL_SIZE` after the hundredth.
func pool_stats() -> Dictionary:
	var now: float = float(Time.get_ticks_msec())
	var busy: int = 0
	for index: int in range(_busy_until.size()):
		if _busy_until[index] > now:
			busy += 1
	return {
		"size": _pool.size(),
		"busy": busy,
		"steals": _steals,
		"plays": _plays,
		"suppressed": _suppressed,
		"audible": not _no_output,
	}


# ----------------------------------------------------------------------------------------------
# Music
# ----------------------------------------------------------------------------------------------

## Asks for a context by name. The track loads on a worker thread, so nothing happens this frame;
## `_process()` starts the crossfade once the bytes have arrived. Asking for the context that is
## already playing does nothing.
func set_music_context(context: String) -> void:
	if context == _wanted_context:
		return
	_wanted_context = context
	if context.is_empty():
		_begin_crossfade(null)


func music_context() -> String:
	return _playing_context


func stop_music() -> void:
	set_music_context("")


func _process(delta: float) -> void:
	_advance_crossfade(delta)

	if not enabled or _bank == null:
		return
	if _wanted_context.is_empty() or _wanted_context == _playing_context:
		return
	if _bank.music_is_absent(_wanted_context):
		# Remembered, not retried: the directory has no track and will not grow one this run.
		_playing_context = _wanted_context
		return
	var stream: AudioStream = _bank.music(_wanted_context)
	if stream == null:
		return
	_begin_crossfade(stream)
	_playing_context = _wanted_context


## Starts the incoming player silent and lets `_advance_crossfade()` raise it. A null stream
## means "fade out to nothing", which is how `stop_music()` is expressed.
func _begin_crossfade(stream: AudioStream) -> void:
	if _music_players.size() < 2:
		return
	var incoming: int = 1 - _active_music
	var player: AudioStreamPlayer = _music_players[incoming]
	player.stop()
	player.stream = stream
	player.volume_db = MIN_DB
	if stream != null and not _no_output:
		player.play()
	_active_music = incoming
	_fade = 0.0


## The envelope. This is the one place a player's own `volume_db` is written, and it is not a
## volume setting: the Music bus scales whatever comes out of here, so a player moving a slider
## mid-crossfade gets both behaviours and neither fights the other.
func _advance_crossfade(delta: float) -> void:
	if _fade < 0.0 or _music_players.size() < 2:
		return
	_fade = minf(_fade + delta / maxf(CROSSFADE_SECONDS, 0.001), 1.0)

	var incoming: AudioStreamPlayer = _music_players[_active_music]
	var outgoing: AudioStreamPlayer = _music_players[1 - _active_music]
	incoming.volume_db = _envelope(_fade)
	outgoing.volume_db = _envelope(1.0 - _fade)

	if _fade < 1.0:
		return
	_fade = -1.0
	outgoing.stop()
	# Dropping the reference here is what keeps exactly one music stream resident. The bank has
	# already replaced its own, so this is the last one.
	outgoing.stream = null


static func _envelope(t: float) -> float:
	if t <= 0.0:
		return MIN_DB
	return maxf(linear_to_db(clampf(t, 0.0, 1.0)), MIN_DB)


# ----------------------------------------------------------------------------------------------
# Diagnostics
# ----------------------------------------------------------------------------------------------

## Once per kind, never per occurrence. A new intent kind upstream should be visible in a log
## without drowning it, and must never stop the duel (V13's spirit).
func _warn_unknown(kind: String) -> void:
	if kind.is_empty() or _unknown_kinds.has(kind):
		return
	_unknown_kinds[kind] = true
	push_warning("[AudioDirector] no audio decision for intent kind '%s'; staying silent" % kind)


func unknown_kinds() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for kind: Variant in _unknown_kinds:
		out.append(str(kind))
	return out
