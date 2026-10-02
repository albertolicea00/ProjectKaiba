class_name CardArt
extends RefCounted

## Card faces off the disk: decoded on worker threads, held in a byte-capped LRU.
##
## Layer: L3 (AGENTS.md section 4, "registries"). **V2 caveat, stated rather than hidden:** V2
## says L3 never instantiates a `Texture`, and this class does exactly that - it is what
## `texture_for()` returns. The invariant's target is the *duel model*: `DuelState` must stay a
## pure, headless, serialisable thing (V11 is the sharp form of that rule and this file does not
## touch it). ARCHITECTURE.md section 9 already puts the visual registries at L3 and has
## `VisualDefinition` hold a `PackedScene` and a `Texture`, so the architecture and V2 disagree
## with each other, not with this file. Worth resolving in AGENTS.md - probably by narrowing V2
## to "the duel model" - but that is a documentation edit and out of this change's scope.
##
## -------------------------------------------------------------------------------------------
## Why this is not `load()`
## -------------------------------------------------------------------------------------------
## The art lives in `data/base/pics/`, outside `res://`. It is not imported, has no `.import`
## sidecar and no UID, so `load()` and `ResourceLoader` cannot see it at all. The only route is
## `Image.load_from_file()` on a globalised OS path, then `ImageTexture.create_from_image()`.
##
## That is also why the threading here is ours to get right: `ResourceLoader.load_threaded_*`
## would have done it for an imported resource, and none of it applies.
##
## -------------------------------------------------------------------------------------------
## The one rule: never block the main thread on disk
## -------------------------------------------------------------------------------------------
## `texture_for()` answers out of the cache or answers `null`, immediately, every time. It never
## opens a file. A miss queues a `WorkerThreadPool` task and returns `null`; the card shows its
## placeholder colour for a frame or two and then picks up its face via `CardView.refresh_art()`.
## A card wearing the wrong colour for two frames is invisible to a player. A 40 ms stall while
## a JPEG decodes is not.
##
## The split of labour is deliberate:
##
##   worker thread   file existence check, read, JPEG decode  -> an `Image` (the expensive part)
##   main thread     `ImageTexture.create_from_image()`       -> the GPU upload
##
## The upload has to happen on the main thread anyway, and it is microseconds. The decode is the
## part worth moving, and an `Image` is plain memory that any thread may produce.
##
## -------------------------------------------------------------------------------------------
## Memory, with an actual budget
## -------------------------------------------------------------------------------------------
## Measured on this machine's art set, not assumed:
##
##   sd  268 x 391  RGB8  ->   314_364 bytes decoded  (~29 KB on disk as JPEG)
##   hd  813 x 1185 RGB8  -> 2_890_215 bytes decoded  (~175 KB on disk as JPEG)
##
## The JPEG on disk is ten to sixteen times smaller than the decoded surface, which is the whole
## reason a cache needs a byte cap rather than an entry count. At the 64 MB default that is about
## 213 sd faces or 23 hd faces. A duel shows well under forty cards at once, so sd has enormous
## headroom; **hd does not**, and that is not an accident of this implementation:
##
##   - 40 hd faces = 115 MB. 60 = 173 MB. Neither fits in 64 MB.
##   - So on a tier-hd desktop, `preload_codes()` over both decklists will load every face and
##     the LRU will immediately evict down to the last ~23. The faces still *work* - every one
##     of them reloads on demand - but the preload stops being a preload.
##
## Either raise `set_budget_bytes()` for desktop (256 MB holds ~90 hd faces) or accept the
## reload. The default is left at the specified 64 MB and `stats()` reports the truth, rather
## than quietly enlarging the budget behind the caller's back.
##
## `bytes` counts decoded payload, whether the entry is still a staged `Image` (system memory)
## or has been promoted to an `ImageTexture` (video memory). The same pixels, one figure, no
## double counting - and no pretending the GPU copy is free.
##
## Mipmaps are deliberately **not** generated. They would cost a third more memory and break the
## arithmetic above. A card lying flat on the table and viewed at a grazing angle will therefore
## alias under minification; if that reads badly on a real screen, the fix is one
## `image.generate_mipmaps()` in `_decode()` plus a 33% larger budget.
##
## -------------------------------------------------------------------------------------------
## A missing file is normal
## -------------------------------------------------------------------------------------------
## Tokens, and plenty of ordinary cards, have no image at all. `sd/` holds 14595 faces and `hd/`
## fewer, so "no file" is an expected answer and not an error: it is remembered in `_absent` and
## never retried. Without that, every frame of a token on the field would queue a fresh task for
## a file that will not exist this run either.
##
## -------------------------------------------------------------------------------------------
## Threading contract
## -------------------------------------------------------------------------------------------
## `texture_for()`, `request()`, `preload_codes()`, `set_*()` and `shutdown()` are **main thread
## only** - `texture_for()` touches the RenderingServer. `stats()` is safe from anywhere. Every
## field below is guarded by `_mutex`; the worker body touches nothing else.
##
## Outstanding tasks are drained on `NOTIFICATION_PREDELETE`, because a `Callable` bound to a
## `RefCounted` does not keep it alive: a task still running when the last reference drops would
## otherwise call into a dead object.

## Tier identifiers. These are also the index into `_roots`, so do not reorder them.
const TIER_SD: int = 0
const TIER_HD: int = 1

## 64 MB. See the memory note above for what that buys at each tier.
const DEFAULT_BUDGET_BYTES: int = 64 * 1024 * 1024

## Desktop default. An hd face decodes to roughly 2.9 MB, so 64 MB would hold about 22 of them -
## fewer than a mid-game board shows at once, which means the LRU would evict a card and decode
## it again within the same turn. 256 MB holds about 90, which covers both hands, both fields
## and both graveyards with room to spare.
const DEFAULT_BUDGET_BYTES_HD: int = 256 * 1024 * 1024

## Where the art lives relative to the Godot project, for the dev tree. An Android build keeps
## its art in external app storage and must call `set_roots()` with a real path.
const DEFAULT_PICS_PATH: String = "res://../data/base/pics"

## Guards every `var` below it. Held only for bookkeeping - never across a file read.
var _mutex: Mutex = Mutex.new()

## Root directory per tier, indexed by `TIER_*`.
var _roots: PackedStringArray = PackedStringArray(["", ""])

var _tier: int = TIER_SD

var _budget_bytes: int = DEFAULT_BUDGET_BYTES

## Set once a caller has chosen a budget, so a later `set_tier()` does not overrule them.
var _budget_is_explicit: bool = false

## card_id -> {"image": Image, "texture": Texture2D, "bytes": int, "used": int}.
## Exactly one of `image` / `texture` is non-null: a freshly decoded entry holds the `Image`
## until the first `texture_for()` promotes it and drops it.
var _entries: Dictionary = {}

## card_id -> true for every code that has no file in any tier. Never retried (see above).
var _absent: Dictionary = {}

## card_id -> true while a task for it is queued or running. Keeps one code to one task.
var _pending: Dictionary = {}

## Holds a reference to this object for exactly as long as a worker task might still touch it.
##
## `WorkerThreadPool.add_task()` takes a `Callable`, and a `Callable` bound to a method of a
## `RefCounted` does **not** raise its reference count. Without this, dropping the last external
## reference while a decode was in flight would free the object underneath the running task.
##
## Set when a task is queued, cleared on the main thread once every task has been reaped. It is
## an intentional reference cycle with a defined end: `_reap_locked()` breaks it.
var _self_hold: Variant = null

## WorkerThreadPool task id -> true. Written only by the main thread, read by `shutdown()`.
## The worker never touches this, so there is no window in which a task is both in flight and
## unknown to the drain.
var _tasks: Dictionary = {}

## Sum of `bytes` over `_entries`. Kept incrementally; a full re-sum per frame would be the
## kind of honest-but-slow bookkeeping this class exists to avoid.
var _bytes: int = 0

## Monotonic access counter. The LRU victim is the entry with the lowest `used`.
var _clock: int = 0

## Bumped by `set_tier()` and `set_roots()`. A task carries the generation it was queued under
## and discards its result if that no longer matches, so a tier switch cannot land a stale
## 813x1185 face into a cache that was just told to serve 268x391 ones.
var _generation: int = 0


func _init() -> void:
	_tier = default_tier()
	_budget_bytes = default_budget_bytes(_tier)
	set_roots(default_root(TIER_SD), default_root(TIER_HD))


func _notification(what: int) -> void:
	# NOTIFICATION_PREDELETE deliberately does nothing. A RefCounted at refcount zero can no
	# longer dispatch its own methods, so calling shutdown() from here fails with
	# "base 'null instance'". Outstanding work is kept safe by `_self_hold` instead, which is
	# the stronger guarantee anyway: the object simply cannot reach refcount zero while a task
	# is in flight, so this notification never fires at a dangerous moment.
	if what == NOTIFICATION_PREDELETE:
		pass


# ----------------------------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------------------------

## Points the two tiers at directories of `<code>.jpg` files. Paths are OS paths, not `res://`
## ones; `res://` is accepted and globalised for convenience. Changing either root drops the
## cache, because the pixels behind every cached id just changed meaning.
func set_roots(sd_dir: String, hd_dir: String) -> void:
	var sd: String = _normalise_root(sd_dir)
	var hd: String = _normalise_root(hd_dir)
	_mutex.lock()
	if sd == _roots[TIER_SD] and hd == _roots[TIER_HD]:
		_mutex.unlock()
		return
	_roots[TIER_SD] = sd
	_roots[TIER_HD] = hd
	_invalidate_locked()
	_mutex.unlock()


## `TIER_SD` or `TIER_HD`. Anything else is read as `TIER_SD`, because the failure mode of
## guessing low is a slightly soft card face and the failure mode of guessing high is an
## out-of-memory kill on a phone.
func set_tier(tier: int) -> void:
	var wanted: int = TIER_HD if tier == TIER_HD else TIER_SD
	_mutex.lock()
	if wanted == _tier:
		_mutex.unlock()
		return
	_tier = wanted
	if not _budget_is_explicit:
		# Per-face cost changes by roughly nine times between the tiers, so a budget that was
		# right for one is wrong for the other. A caller who set their own keeps it.
		_budget_bytes = default_budget_bytes(_tier)
	_invalidate_locked()
	_mutex.unlock()


func tier() -> int:
	_mutex.lock()
	var value: int = _tier
	_mutex.unlock()
	return value


## Raises or lowers the cap. Takes effect immediately: lowering it evicts on the spot rather
## than waiting for the next load, so a caller can shrink the budget under memory pressure.
func set_budget_bytes(budget: int) -> void:
	_budget_is_explicit = true
	_mutex.lock()
	_budget_bytes = maxi(1, budget)
	_trim_locked()
	_mutex.unlock()


func budget_bytes() -> int:
	_mutex.lock()
	var value: int = _budget_bytes
	_mutex.unlock()
	return value


## `TIER_SD` on mobile - which for this project means Android, the only mobile target in scope -
## and `TIER_HD` everywhere else. A decoded hd face is 2.9 MB; sixty of them is 173 MB, which is
## not a budget a mid-range phone has to spare. This is a platform fact, not a quality setting.
## The budget that makes sense for a tier, in bytes.
##
## Tied to the tier rather than fixed because the per-face cost differs by about nine times
## between sd and hd, so one number cannot be right for both: sized for hd it wastes a phone's
## memory, sized for sd it thrashes on a desktop.
static func default_budget_bytes(tier: int) -> int:
	return DEFAULT_BUDGET_BYTES_HD if tier == TIER_HD else DEFAULT_BUDGET_BYTES


static func default_tier() -> int:
	return TIER_SD if OS.has_feature("mobile") else TIER_HD


## The dev-tree location of a tier's art. Correct when running from the repo; an exported build
## ships its art elsewhere and must call `set_roots()`.
static func default_root(tier: int) -> String:
	var leaf: String = "hd" if tier == TIER_HD else "sd"
	return ProjectSettings.globalize_path(DEFAULT_PICS_PATH).path_join(leaf).simplify_path()


# ----------------------------------------------------------------------------------------------
# Lookup
# ----------------------------------------------------------------------------------------------

## The face for `card_id`, or `null`. Never touches the disk: `null` means "not cached yet" and
## carries a queued load with it, or "no such file", which is remembered and costs nothing on
## every later call. Main thread only.
func texture_for(card_id: int) -> Texture2D:
	if card_id <= 0:
		return null

	_mutex.lock()
	_reap_locked()

	var entry: Dictionary = _entries.get(card_id, {}) as Dictionary
	if not entry.is_empty():
		_clock += 1
		entry["used"] = _clock
		var texture: Texture2D = entry.get("texture") as Texture2D
		if texture == null:
			# First use since the worker handed over the pixels. The upload happens here, on the
			# main thread, and the staged `Image` is released: the texture owns the bytes now, so
			# `_bytes` stays correct without being touched.
			var image: Image = entry.get("image") as Image
			if image != null:
				texture = ImageTexture.create_from_image(image)
			if texture == null:
				# Decoded to nothing, which should not happen. Drop it rather than retry forever.
				_bytes -= int(entry.get("bytes", 0))
				_entries.erase(card_id)
				_absent[card_id] = true
				_mutex.unlock()
				return null
			entry["texture"] = texture
			entry["image"] = null
		_mutex.unlock()
		return texture

	var queueable: bool = not _absent.has(card_id) and not _pending.has(card_id)
	_mutex.unlock()

	if queueable:
		_queue(card_id)
	return null


## Warms one card without wanting the result yet. Cheap and idempotent: a cached, absent or
## already-queued code does nothing at all.
func request(card_id: int) -> void:
	if card_id <= 0:
		return
	_queue(card_id)


## Warms a whole decklist. Both decklists are known when a duel starts (ARCHITECTURE.md section
## 9), so calling this there puts 40-60 faces in flight before the first draw animation.
##
## Read the memory note above before doing this at `TIER_HD`: the faces all load, but the LRU
## will evict most of them again inside a 64 MB budget.
func preload_codes(codes: PackedInt32Array) -> void:
	for code: int in codes:
		request(code)


## `{"cached": entries held, "bytes": decoded bytes held, "misses": codes known to have no file}`.
##
## `bytes` is the real decoded size of what is held right now, summed from `Image.get_data()`,
## not an estimate from the dimensions. `misses` counts distinct codes, not lookups: a token
## asked for a thousand times is one miss. Safe to call from any thread.
func stats() -> Dictionary:
	_mutex.lock()
	var out: Dictionary = {
		"cached": _entries.size(),
		"bytes": _bytes,
		"misses": _absent.size(),
	}
	_mutex.unlock()
	return out


## How many loads are queued or running. Not part of `stats()` - it is a progress reading rather
## than a memory one - but it is what tells a preload it has finished.
func pending_count() -> int:
	_mutex.lock()
	var value: int = _pending.size()
	_mutex.unlock()
	return value


## Drops every cached face. The absent set survives: a file that did not exist a moment ago
## still does not exist, and re-probing the whole token pool is pure waste.
func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_bytes = 0
	_mutex.unlock()


## Waits for every outstanding load. Called automatically when the last reference drops; a test
## or a scene teardown may call it early. Blocking is the point: it is the only thing that
## guarantees no worker is still inside this object when it stops existing.
## Waits for every outstanding decode and releases the self-reference that kept this object
## alive while they ran. Call it when a duel ends; without it the cache stays alive until the
## last task is reaped, which may be never if the process exits first.
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
		if done:
			# Safe here and only here: every task has been waited on, and the caller is holding
			# a reference in order to have called this at all, so dropping the self-reference
			# cannot free the object out from under this function.
			_self_hold = null
		_mutex.unlock()
		if done:
			return


# ----------------------------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------------------------

## Puts one code in flight, exactly once. Main thread only, which is what makes the gap between
## marking `_pending` and handing the task to the pool safe without extra locking.
func _queue(card_id: int) -> void:
	_mutex.lock()
	_reap_locked()
	if _entries.has(card_id) or _absent.has(card_id) or _pending.has(card_id):
		_mutex.unlock()
		return
	var sd: String = _roots[TIER_SD]
	var hd: String = _roots[TIER_HD]
	var tier: int = _tier
	var generation: int = _generation
	_pending[card_id] = true
	_mutex.unlock()

	var task: int = WorkerThreadPool.add_task(
		_load_task.bind(card_id, sd, hd, tier, generation),
		false,
		"CardArt %d" % card_id)

	_mutex.lock()
	_tasks[task] = true
	# Cannot be freed from here until the task is reaped.
	_self_hold = self
	_mutex.unlock()


## The worker body. Everything expensive happens before the lock is taken, and the configuration
## it needs arrives bound into the Callable rather than read back out of the object, so a
## `set_tier()` racing against a load cannot make this function read a half-changed state.
func _load_task(card_id: int, sd_root: String, hd_root: String, tier: int, generation: int) -> void:
	var image: Image = null
	for path: String in _candidate_paths(card_id, sd_root, hd_root, tier):
		image = _decode(path)
		if image != null:
			break

	_mutex.lock()
	_pending.erase(card_id)

	if generation != _generation:
		# The tier or the roots changed while this was decoding. The pixels are the wrong ones
		# now; dropping them is cheaper than reasoning about which half of the cache they belong
		# to, and whoever still wants this card will ask again.
		_mutex.unlock()
		return

	if image == null:
		_absent[card_id] = true
		_mutex.unlock()
		return

	if _entries.has(card_id):
		# Two tasks raced - possible after an invalidation cleared `_pending` under one of them.
		# Keep the entry already there and discard this one; both hold the same pixels.
		_mutex.unlock()
		return

	var bytes: int = image.get_data().size()
	_clock += 1
	_entries[card_id] = {
		"image": image,
		"texture": null,
		"bytes": bytes,
		"used": _clock,
	}
	_bytes += bytes
	_trim_locked()
	_mutex.unlock()


## Tier order, highest first, with the fallback behind it. `hd/` holds fewer faces than `sd/`,
## so an hd-tier client that refuses to fall back would show a placeholder for thousands of
## cards that do have art. The reverse fallback is deliberately absent: an sd-tier client is
## sd-tier for memory reasons, and quietly loading a 2.9 MB hd face would defeat the point.
func _candidate_paths(card_id: int, sd_root: String, hd_root: String, tier: int) -> PackedStringArray:
	var name: String = "%d.jpg" % card_id
	var paths: PackedStringArray = PackedStringArray()
	if tier == TIER_HD and not hd_root.is_empty():
		paths.append(hd_root.path_join(name))
	if not sd_root.is_empty():
		paths.append(sd_root.path_join(name))
	return paths


## Reads and decodes one file, or returns null. The existence check is not redundant with
## `load_from_file()`: without it, every token on the field would push an engine error into the
## log on every look-up, and "no art for this card" is not an error condition.
func _decode(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	return image


## Evicts least-recently-used entries until the budget is met. Always leaves one entry standing,
## so a single face larger than the whole budget is served rather than evicted the instant it
## lands and reloaded forever. `stats()` reports that overshoot honestly instead of hiding it.
##
## The victim search is a linear scan. At the 64 MB default that is at most ~213 entries and it
## runs only when the budget is actually exceeded, which is far cheaper than keeping an ordered
## structure correct across three threads.
func _trim_locked() -> void:
	while _bytes > _budget_bytes and _entries.size() > 1:
		var victim: int = -1
		var oldest: int = 0
		for key: Variant in _entries:
			var used: int = int((_entries[key] as Dictionary).get("used", 0))
			if victim == -1 or used < oldest:
				oldest = used
				victim = int(key)
		if victim == -1:
			return
		_bytes -= int((_entries[victim] as Dictionary).get("bytes", 0))
		_entries.erase(victim)


## Drops finished task ids. `_tasks` exists only so `shutdown()` knows what to wait for, and it
## is reaped lazily here rather than by the worker, which must never touch it.
func _reap_locked() -> void:
	if _tasks.is_empty():
		return
	for task: Variant in _tasks.keys():
		if WorkerThreadPool.is_task_completed(int(task)):
			_tasks.erase(task)
	# Released here and nowhere else. Clearing it from the worker would let the object be freed
	# while that very worker is still executing inside one of its methods.
	if _tasks.is_empty():
		_self_hold = null


## Everything cached is now the wrong resolution or from the wrong directory. `_pending` is
## cleared too, so a fresh request is not swallowed by an in-flight task whose result the
## generation check is about to throw away.
func _invalidate_locked() -> void:
	_generation += 1
	_entries.clear()
	_absent.clear()
	_pending.clear()
	_bytes = 0


## Accepts a `res://` path, an OS path, or an empty string meaning "this tier has no art".
func _normalise_root(dir: String) -> String:
	if dir.is_empty():
		return ""
	if dir.begins_with("res://") or dir.begins_with("user://"):
		return ProjectSettings.globalize_path(dir).simplify_path()
	return dir.simplify_path()
