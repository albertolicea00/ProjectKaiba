class_name SoundBank
extends Node

## Audio streams off the disk: read and decoded on worker threads, held in a byte-capped LRU.
##
## Layer: L4 (AGENTS.md section 4). Nothing here names `KaibaCore`, `MsgParser` or anything under
## `native/` (V1), and it is a scene node, which is exactly why no part of it may move under
## `game/core/` (V2).
##
## -------------------------------------------------------------------------------------------
## Why this is not `load()`
## -------------------------------------------------------------------------------------------
## The sounds live in `data/base/sounds/`, outside `res://`. They are not imported, have no
## `.import` sidecar and no UID, so `load()` and `ResourceLoader` cannot see them at all - the
## same situation `CardArt` is in with the card faces, and the same answer: read the file into a
## `PackedByteArray` and build the stream from the bytes with `AudioStreamWAV.load_from_buffer()`
## or `AudioStreamMP3.load_from_buffer()` (Godot 4.4+). Both are plain data resources, unlike an
## `ImageTexture`, so the whole build can happen on the worker and the main thread only ever
## receives a finished stream.
##
## -------------------------------------------------------------------------------------------
## The one rule: never block the main thread on disk
## -------------------------------------------------------------------------------------------
## `effect()` answers out of the cache or answers `null`, immediately, every time. It never opens
## a file and never even stats one - the existence probe lives on the worker too, because a stat
## is still a syscall and a cold SD card on a phone can make it an expensive one. A miss queues a
## `WorkerThreadPool` task and returns `null`; the sound is simply not heard that once.
##
## That would make the first summon of every duel silent, which is why `prewarm()` exists: the
## twenty generic effects are 6.9 MB in total and the whole set is queued when a duel scene comes
## up, long before the first intent arrives. On-demand loading is what keeps the 46 MB sound set
## off a phone's heap; prewarming twenty small files is not the same thing as loading all of it.
##
## -------------------------------------------------------------------------------------------
## Per-card overrides
## -------------------------------------------------------------------------------------------
## `sound/activate/`, `sound/attack/` and `sound/summon/` are EDOPro's per-passcode override
## directories: dropping `activate/89631139.wav` in gives Blue-Eyes its own activation sound. They
## ship empty and this project invents no files for them, but the lookup is here so that dropping
## one in works with no code change. The override is tried first and the generic effect is the
## fallback, which is the only ordering that lets a pack add a sound without removing one.
##
## -------------------------------------------------------------------------------------------
## Two caches, on purpose
## -------------------------------------------------------------------------------------------
## `_paths` maps a lookup key (`"summon#89631139"`) to the file that answered it, and `_streams`
## maps a file to its decoded stream. Without the split, every card that has no override would
## store its own copy of the generic `summon.wav` under its own key and the budget would be spent
## on duplicates. With it, a thousand distinct keys share one stream.
##
## -------------------------------------------------------------------------------------------
## A missing file is normal
## -------------------------------------------------------------------------------------------
## Almost every per-card lookup misses, because the override directories are empty. A miss is
## remembered in `_absent` and never probed again: `probe_count()` is the evidence, and it is what
## the test asserts on. `data/` is gitignored (AGENTS.md section 9), so a checkout with no sounds
## at all is a normal state in which every lookup misses once and the duel runs silently.
##
## -------------------------------------------------------------------------------------------
## Threading contract
## -------------------------------------------------------------------------------------------
## `effect()`, `request()`, `prewarm()`, `music()`, `set_root()` and `shutdown()` are main thread
## only. `stats()` is safe from anywhere. Every field below is guarded by `_mutex`. Outstanding
## tasks are drained by `shutdown()` and by `_exit_tree()`, because a `Callable` bound to a Node
## does not keep that node alive through `queue_free()`.

## Where the sounds live relative to the Godot project, for the dev tree. An Android build keeps
## its data in external app storage and must call `set_root()` with a real path.
const DEFAULT_SOUNDS_PATH: String = "res://../data/base/sounds"

## Music lives one directory per context under here, each holding exactly one track.
const BGM_LEAF: String = "BGM"

## The twenty effects EDOPro ships, by file stem. This is the whole generic set; `prewarm()`
## queues it and the test uses it to check that every name a mapping can ask for exists.
const EFFECT_NAMES: Array[String] = [
	"activate", "addcounter", "attack", "chatmessage", "coinflip", "damage", "destroyed",
	"diceroll", "draw", "equip", "flip", "gainlp", "nextturn", "phase", "playerenter",
	"removecounter", "set", "shuffle", "specialsummon", "summon",
]

## Effect names that also have a per-passcode override directory in the EDOPro layout. Probing a
## directory that does not exist is harmless but pointless, so the probe is restricted to these.
const OVERRIDABLE: Array[String] = ["activate", "attack", "summon"]

## Extensions tried, in order, for both effects and music. `.wav` first because every generic
## effect is one; `.ogg` is accepted so a pack can ship the cheaper format.
const EXTENSIONS: Array[String] = [".wav", ".mp3", ".ogg"]

## 16 MB. The twenty generic effects are 6.9 MB decoded-in-place, so the cap exists for the part
## that is genuinely unbounded: per-card overrides, of which a large pack could ship hundreds.
## The music stream is held separately and is NOT counted here - see `_music_stream`.
const DEFAULT_BUDGET_BYTES: int = 16 * 1024 * 1024

## Guards every `var` below it. Held only for bookkeeping - never across a file read.
var _mutex: Mutex = Mutex.new()

var _root: String = ""

var _budget_bytes: int = DEFAULT_BUDGET_BYTES

## Lookup key -> absolute path that answered it. `"summon#0"` for the generic effect,
## `"summon#89631139"` for one card's override attempt.
var _paths: Dictionary = {}

## Absolute path -> {"stream": AudioStream, "bytes": int, "used": int}.
var _streams: Dictionary = {}

## Lookup key -> true for every key with no file anywhere. Never retried.
var _absent: Dictionary = {}

## Lookup key -> true while a task for it is queued or running. Keeps one key to one task.
var _pending: Dictionary = {}

## WorkerThreadPool task id -> true. Written only by the main thread.
var _tasks: Dictionary = {}

## Sum of `bytes` over `_streams`, kept incrementally.
var _bytes: int = 0

## Monotonic access counter. The LRU victim is the entry with the lowest `used`.
var _clock: int = 0

## Bumped by `set_root()`. A task carries the generation it was queued under and discards its
## result if that no longer matches.
var _generation: int = 0

## How many times a worker has gone to the filesystem on behalf of a lookup. One per queued task,
## not one per candidate path: it answers "did we ask the disk about this key again?", which is
## the only thing a remembered miss is supposed to prevent.
var _probes: int = 0

## The one resident music track. Held outside `_streams` and outside `_bytes`: it is 1.7 to
## 11 MB on its own, so an LRU that could evict it would evict everything else first and then
## evict the thing that is actually playing. Exactly one is held at a time, by construction.
var _music_stream: AudioStream = null
var _music_context: String = ""
var _music_pending: String = ""


func _init() -> void:
	set_root(default_root())


func _exit_tree() -> void:
	shutdown()


# ----------------------------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------------------------

## The dev-tree location of the sound set. Correct when running from the repo; an exported build
## ships its data elsewhere and must call `set_root()`.
static func default_root() -> String:
	return ProjectSettings.globalize_path(DEFAULT_SOUNDS_PATH).simplify_path()


## Points the bank at a directory laid out like EDOPro's `sound/`. Accepts a `res://` path or an
## OS path. Changing it drops everything cached, because the bytes behind every key just changed
## meaning.
func set_root(dir: String) -> void:
	var normalised: String = _normalise(dir)
	_mutex.lock()
	if normalised == _root:
		_mutex.unlock()
		return
	_root = normalised
	_generation += 1
	_paths.clear()
	_streams.clear()
	_absent.clear()
	_pending.clear()
	_bytes = 0
	_music_stream = null
	_music_context = ""
	_music_pending = ""
	_mutex.unlock()


func root() -> String:
	_mutex.lock()
	var value: String = _root
	_mutex.unlock()
	return value


func set_budget_bytes(budget: int) -> void:
	_mutex.lock()
	_budget_bytes = maxi(1, budget)
	_trim_locked()
	_mutex.unlock()


# ----------------------------------------------------------------------------------------------
# Effects
# ----------------------------------------------------------------------------------------------

## The stream for `name`, preferring `name/<card_id>.<ext>` when `card_id` is non-zero, or `null`.
##
## Never touches the disk: `null` means "not loaded yet", and carries a queued load with it, or
## "no such file", which is remembered and costs nothing on every later call. Main thread only.
func effect(name: String, card_id: int = 0) -> AudioStream:
	if name.is_empty():
		return null
	var key: String = _key(name, card_id)

	_mutex.lock()
	_reap_locked()
	var path: String = str(_paths.get(key, ""))
	if not path.is_empty():
		var entry: Dictionary = _streams.get(path, {}) as Dictionary
		if not entry.is_empty():
			_clock += 1
			entry["used"] = _clock
			var stream: AudioStream = entry.get("stream") as AudioStream
			_mutex.unlock()
			return stream
		# The path is known but its stream was evicted. Fall through and queue it again.
	var queueable: bool = not _absent.has(key) and not _pending.has(key)
	_mutex.unlock()

	if queueable:
		_queue_effect(name, card_id, key)
	return null


## Warms one effect without wanting the result yet. Cheap and idempotent.
func request(name: String, card_id: int = 0) -> void:
	if name.is_empty():
		return
	var key: String = _key(name, card_id)
	_mutex.lock()
	var queueable: bool = (
		not _absent.has(key)
		and not _pending.has(key)
		and not _streams.has(str(_paths.get(key, "")))
	)
	_mutex.unlock()
	if queueable:
		_queue_effect(name, card_id, key)


## Queues the whole generic effect set. Call it when a duel scene comes up: twenty files, 6.9 MB,
## all in flight before the first intent is translated, so the opening draw is not silent.
func prewarm() -> void:
	for name: String in EFFECT_NAMES:
		request(name, 0)


## True when `name` has a stream ready right now. Used by the test; a caller that wants the sound
## should just call `effect()` and accept `null`.
func is_loaded(name: String, card_id: int = 0) -> bool:
	var key: String = _key(name, card_id)
	_mutex.lock()
	var ready: bool = _streams.has(str(_paths.get(key, "")))
	_mutex.unlock()
	return ready


## True when `name` has been looked for and is known not to exist. A remembered miss.
func is_absent(name: String, card_id: int = 0) -> bool:
	var key: String = _key(name, card_id)
	_mutex.lock()
	var absent: bool = _absent.has(key)
	_mutex.unlock()
	return absent


## The file a loaded key resolved to, or `""`. The only way to tell an override from a fallback
## without reading the bytes back.
func resolved_path(name: String, card_id: int = 0) -> String:
	var key: String = _key(name, card_id)
	_mutex.lock()
	var path: String = str(_paths.get(key, ""))
	_mutex.unlock()
	return path


# ----------------------------------------------------------------------------------------------
# Music
# ----------------------------------------------------------------------------------------------

## The track for a BGM context (`"menu"`, `"duel"`, `"win"`, `"lose"`, ...), or `null` while it
## loads or if the context has no directory. One track is resident at a time: asking for a new
## context drops the previous one as soon as the new one arrives.
func music(context: String) -> AudioStream:
	if context.is_empty():
		return null
	_mutex.lock()
	_reap_locked()
	if context == _music_context and _music_stream != null:
		var stream: AudioStream = _music_stream
		_mutex.unlock()
		return stream
	var key: String = _music_key(context)
	var queueable: bool = (
		not _absent.has(key) and not _pending.has(key) and _music_pending != context
	)
	if queueable:
		_music_pending = context
	_mutex.unlock()

	if queueable:
		_queue_music(context, key)
	return null


## True when the context has been looked for and has no track.
func music_is_absent(context: String) -> bool:
	_mutex.lock()
	var absent: bool = _absent.has(_music_key(context))
	_mutex.unlock()
	return absent


# ----------------------------------------------------------------------------------------------
# Diagnostics
# ----------------------------------------------------------------------------------------------

## `{"cached", "bytes", "misses", "probes", "pending", "music"}`. Safe from any thread.
##
## `probes` counts trips to the filesystem, not lookups: an absent override asked for a thousand
## times is one probe, and that is the claim the remembered-miss machinery makes.
func stats() -> Dictionary:
	_mutex.lock()
	var out: Dictionary = {
		"cached": _streams.size(),
		"bytes": _bytes,
		"misses": _absent.size(),
		"probes": _probes,
		"pending": _pending.size(),
		"music": _music_context,
	}
	_mutex.unlock()
	return out


func probe_count() -> int:
	_mutex.lock()
	var value: int = _probes
	_mutex.unlock()
	return value


func pending_count() -> int:
	_mutex.lock()
	var value: int = _pending.size()
	_mutex.unlock()
	return value


## Waits for every outstanding load. Blocking is the point: it is the only thing that guarantees
## no worker is still inside this node when the scene tears it down.
func shutdown() -> void:
	while true:
		_mutex.lock()
		var ids: Array = _tasks.keys()
		_mutex.unlock()
		if ids.is_empty():
			return
		for task: Variant in ids:
			WorkerThreadPool.wait_for_task_completion(int(task))
		_mutex.lock()
		for task: Variant in ids:
			_tasks.erase(task)
		var done: bool = _tasks.is_empty()
		_mutex.unlock()
		if done:
			return


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

static func _key(name: String, card_id: int) -> String:
	return "%s#%d" % [name, maxi(card_id, 0)]


static func _music_key(context: String) -> String:
	return "bgm/%s" % context


## Puts one effect key in flight, exactly once. Main thread only, which is what makes the gap
## between marking `_pending` and handing the task to the pool safe without extra locking.
func _queue_effect(name: String, card_id: int, key: String) -> void:
	_mutex.lock()
	if _absent.has(key) or _pending.has(key):
		_mutex.unlock()
		return
	var root: String = _root
	var generation: int = _generation
	_pending[key] = true
	_probes += 1
	_mutex.unlock()

	_spawn(_effect_task.bind(name, card_id, key, root, generation), "SoundBank %s" % key)


func _queue_music(context: String, key: String) -> void:
	_mutex.lock()
	if _absent.has(key) or _pending.has(key):
		_mutex.unlock()
		return
	var root: String = _root
	var generation: int = _generation
	_pending[key] = true
	_probes += 1
	_mutex.unlock()

	_spawn(_music_task.bind(context, key, root, generation), "SoundBank %s" % key)


func _spawn(task: Callable, description: String) -> void:
	var id: int = WorkerThreadPool.add_task(task, false, description)
	_mutex.lock()
	_tasks[id] = true
	_mutex.unlock()


## The worker body for an effect. Everything expensive happens before the lock is taken, and the
## configuration it needs arrives bound into the Callable rather than read back out of the node,
## so a `set_root()` racing against a load cannot make this read a half-changed state.
func _effect_task(
	name: String, card_id: int, key: String, root: String, generation: int
) -> void:
	var path: String = ""
	var stream: AudioStream = null
	for candidate: String in _candidates(name, card_id, root):
		stream = _decode(candidate)
		if stream != null:
			path = candidate
			break

	_mutex.lock()
	_pending.erase(key)

	if generation != _generation:
		# The root changed while this was loading. These bytes are the wrong ones now; whoever
		# still wants this sound will ask again.
		_mutex.unlock()
		return

	if stream == null:
		_absent[key] = true
		_mutex.unlock()
		return

	_paths[key] = path
	if not _streams.has(path):
		_clock += 1
		var bytes: int = _stream_bytes(stream)
		_streams[path] = {"stream": stream, "bytes": bytes, "used": _clock}
		_bytes += bytes
		_trim_locked()
	_mutex.unlock()


## The worker body for a music context. The directory is scanned rather than named, because each
## BGM folder holds one track whose filename is the artist's and must not be edited - the
## attribution in `CREDITS.md` is keyed to it.
func _music_task(context: String, key: String, root: String, generation: int) -> void:
	var path: String = _find_music(root, context)
	var stream: AudioStream = _decode(path) if not path.is_empty() else null

	_mutex.lock()
	_pending.erase(key)
	if _music_pending == context:
		_music_pending = ""

	if generation != _generation:
		_mutex.unlock()
		return

	if stream == null:
		_absent[key] = true
		_mutex.unlock()
		return

	# Replacing the previous track here is what keeps exactly one resident. The player that is
	# fading the old one out still holds its own reference, so this does not cut it short.
	_music_stream = stream
	_music_context = context
	_mutex.unlock()


## Candidate files for one lookup, best first: the per-card override, then the generic effect.
func _candidates(name: String, card_id: int, root: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if root.is_empty():
		return out
	if card_id > 0 and OVERRIDABLE.has(name):
		for extension: String in EXTENSIONS:
			out.append(root.path_join(name).path_join("%d%s" % [card_id, extension]))
	for extension: String in EXTENSIONS:
		out.append(root.path_join(name + extension))
	return out


## The single file in `BGM/<context>/`, whatever it is called. Returns `""` when the directory
## is missing or holds nothing playable.
func _find_music(root: String, context: String) -> String:
	if root.is_empty():
		return ""
	var dir_path: String = root.path_join(BGM_LEAF).path_join(context)
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return ""
	var best: String = ""
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			var extension: String = ".%s" % entry.get_extension().to_lower()
			if EXTENSIONS.has(extension):
				var candidate: String = dir_path.path_join(entry)
				# Deterministic when a context somehow holds two files: lowest name wins, so two
				# runs on the same install never pick different tracks.
				if best.is_empty() or candidate < best:
					best = candidate
		entry = dir.get_next()
	dir.list_dir_end()
	return best


## Reads one file and builds a stream from its bytes, or returns null. The existence check is not
## redundant with the read: without it every absent per-card override would push an engine error
## into the log, and "this card has no custom sound" is not an error condition.
func _decode(path: String) -> AudioStream:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	match path.get_extension().to_lower():
		"wav":
			return AudioStreamWAV.load_from_buffer(_trim_wav(bytes))
		"mp3":
			return AudioStreamMP3.load_from_buffer(bytes)
		"ogg":
			return AudioStreamOggVorbis.load_from_buffer(bytes)
		_:
			return null


## Cuts a RIFF file off at the end of its `data` chunk and rewrites the size field to match.
##
## This is not tidying. `activate.wav` in the EDOPro set carries a 603-byte `bext` (broadcast
## extension) chunk after the audio, and 603 is odd while the file has no pad byte after it - so
## the RIFF spec says the next chunk starts one byte past the end of the file. Godot's parser
## follows the spec, seeks there, and emits ten `Condition "p_position > length" is true` errors
## per load before giving up. The stream it returns is correct either way; the errors are not,
## because they appear in the log of every duel and look like a real failure.
##
## Metadata after the audio is of no use to a player, so the honest fix is to hand the parser
## exactly the part it is going to read. Anything it cannot parse - not a RIFF, a chunk running
## past the end, no `data` chunk at all - is passed through untouched, so a format this does not
## understand is still the engine's problem to report rather than silently mangled here.
static func _trim_wav(bytes: PackedByteArray) -> PackedByteArray:
	const RIFF: int = 0x46464952
	const DATA: int = 0x61746164
	if bytes.size() < 44 or bytes.decode_u32(0) != RIFF:
		return bytes
	var cursor: int = 12
	while cursor + 8 <= bytes.size():
		var id: int = bytes.decode_u32(cursor)
		var size: int = bytes.decode_u32(cursor + 4)
		var end: int = cursor + 8 + size
		if size <= 0 or end > bytes.size():
			return bytes
		if id == DATA:
			if end == bytes.size():
				return bytes
			var out: PackedByteArray = bytes.slice(0, end)
			out.encode_u32(4, end - 8)
			return out
		# Odd-sized chunks are padded to an even boundary.
		cursor = end + (size & 1)
	return bytes


## What a stream costs in memory. `AudioStreamWAV` holds its PCM verbatim, so `data.size()` is
## the honest figure; the compressed formats hold the encoded bytes and decode a frame at a time,
## which is why an mp3 that plays for two and a half minutes costs six megabytes and not three
## hundred. There is no common accessor, hence the type switch.
static func _stream_bytes(stream: AudioStream) -> int:
	if stream is AudioStreamWAV:
		return (stream as AudioStreamWAV).data.size()
	if stream is AudioStreamMP3:
		return (stream as AudioStreamMP3).data.size()
	if stream is AudioStreamOggVorbis:
		# No byte accessor on the packet sequence. Estimate from duration at a typical 128 kbit/s
		# rather than report zero, which would make the budget meaningless for ogg packs.
		return int(stream.get_length() * 16000.0)
	return 0


## Evicts least-recently-used streams until the budget is met. Always leaves one standing, so a
## single sound larger than the whole budget is served rather than evicted the instant it lands.
##
## Evicting only drops this node's reference: an `AudioStreamPlayer` that is mid-playback holds
## its own, so nothing is ever cut off by the budget.
func _trim_locked() -> void:
	while _bytes > _budget_bytes and _streams.size() > 1:
		var victim: String = ""
		var oldest: int = 0
		for path: Variant in _streams:
			var used: int = int((_streams[path] as Dictionary).get("used", 0))
			if victim.is_empty() or used < oldest:
				oldest = used
				victim = str(path)
		if victim.is_empty():
			return
		_bytes -= int((_streams[victim] as Dictionary).get("bytes", 0))
		_streams.erase(victim)


## Drops finished task ids. `_tasks` exists only so `shutdown()` knows what to wait for, and it
## is reaped lazily here rather than by the worker, which must never touch it.
func _reap_locked() -> void:
	if _tasks.is_empty():
		return
	for task: Variant in _tasks.keys():
		if WorkerThreadPool.is_task_completed(int(task)):
			_tasks.erase(task)


## Accepts a `res://` path, an OS path, or an empty string meaning "no sounds installed".
static func _normalise(dir: String) -> String:
	if dir.is_empty():
		return ""
	if dir.begins_with("res://") or dir.begins_with("user://"):
		return ProjectSettings.globalize_path(dir).simplify_path()
	return dir.simplify_path()
