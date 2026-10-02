extends SceneTree

## Phase 1 smoke test: drive a real ocgcore duel through the native API and print the event
## stream. Run with:
##   godot --headless --path game --script res://scenes/duel_smoke.gd
##
## There is no cards.cdb and no Lua scripts yet (docs/DATA.md), so every card comes back as
## zeroed data with no effects. That is fine and is exactly the point: this exercises the
## DuelThread, the message pump and MsgParser, not the card pool.

const DECK_SIZE := 40
const MAX_EVENTS := 80


func _init() -> void:
	var core: Object = ClassDB.instantiate("KaibaCore")
	if core == null:
		push_error("KaibaCore is not registered; the GDExtension did not load.")
		quit(1)
		return

	var deck: PackedInt32Array = PackedInt32Array()
	for i in DECK_SIZE:
		# Blue-Eyes White Dragon, repeated. Without a database the code is just a number.
		deck.append(89631139)

	var result: Dictionary = core.start_duel({
		"start_lp": 8000,
		"start_hand": 5,
		"draw_count": 1,
		"deck_p0": deck,
		"deck_p1": deck,
		# No script collection is installed for this test, so skip the library preload that a
		# real duel requires. Everything below still exercises DuelThread and MsgParser; only
		# card effects are absent, and this deck has none to begin with.
		"init_scripts": PackedStringArray(),
	})

	if not result["ok"]:
		push_error("start_duel failed: %s" % result["error"])
		quit(1)
		return

	print("[smoke] duel started, seed = %s" % str(result["seed"]))

	var seen: Dictionary = {}
	var count := 0
	var idle := 0
	var log_count := 0

	while count < MAX_EVENTS and idle < 400:
		var event: Variant = core.poll_event()
		if event == null:
			idle += 1
			OS.delay_msec(5)
			continue
		idle = 0
		var t: int = event["t"]
		# 1002/1003 are our own CORE_ERROR / CORE_LOG lifecycle events. Without card scripts
		# every card logs a missing initial_effect, which would drown the duel messages.
		if t == 1002 or t == 1003:
			log_count += 1
			continue
		count += 1
		seen[t] = int(seen.get(t, 0)) + 1
		print("[smoke] %3d  t=%-5d %s" % [count, t, _brief(event)])

		# The duel blocks on MSG_SELECT_*. Stop at the first one: answering it properly is
		# the ResponseBuilder's job (Phase 2), not this smoke test's.
		if t >= 10 and t <= 26:
			print("[smoke] reached a blocking selection (t=%d); stopping here." % t)
			break

	print("[smoke] suppressed core log lines: %d" % log_count)
	print("[smoke] event types seen: %s" % str(seen))
	core.end_duel()
	print("[smoke] duel ended cleanly")
	quit(0)


func _brief(event: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for key in event.keys():
		if key == "t":
			continue
		var value: Variant = event[key]
		if value is Array:
			parts.append("%s=[%d]" % [key, (value as Array).size()])
		else:
			parts.append("%s=%s" % [key, str(value)])
	return ", ".join(parts)
