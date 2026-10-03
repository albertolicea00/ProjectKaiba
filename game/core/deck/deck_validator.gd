class_name DeckValidator
extends RefCounted

## Checks a `DeckModel` and reports **everything** that is wrong with it.
##
## Layer: **L3**. Pure function of (deck, card data, limits). No scene tree, no core, no files.
##
## -------------------------------------------------------------------------------------------
## Every problem, not the first one
## -------------------------------------------------------------------------------------------
## EDOPro's `DeckManager::CheckDeck` returns a single `DeckError` and stops. That is fine for a
## yes/no gate before a duel and useless for an editor: a player who is six cards short *and*
## holding four Pot of Greed should see both, not be told about one, fix it, and be told about
## the other. `validate()` therefore collects and keeps going.
##
## -------------------------------------------------------------------------------------------
## Structured results, never strings
## -------------------------------------------------------------------------------------------
## Each issue is a `Dictionary` with an `ISSUE` code and the numbers behind it. The UI formats
## them; this file never writes a sentence. Two reasons that matter beyond tidiness: the same
## issue list has to survive being sent to a LAN client that will phrase it in its own language,
## and a test asserting on `ISSUE.TOO_MANY_COPIES` keeps passing when the wording changes.
##
## -------------------------------------------------------------------------------------------
## Sizes are a parameter, because the host owns them
## -------------------------------------------------------------------------------------------
## The 40-60 / 0-15 / 0-15 limits are **not** in the engine. They arrive per host, in the
## `DeckSizes` struct of `edopro/gframe/network.h`, as part of the room settings - a LAN host
## may legitimately run a 60-card minimum or a sideless format. `DEFAULT_LIMITS` below is the
## standard format and nothing more; `validate()` takes a `limits` Dictionary and `HostService`
## will pass the host's. A Dictionary rather than a class because this is exactly the shape
## that has to cross the wire later (V14).
##
## -------------------------------------------------------------------------------------------
## Copies are counted by alias
## -------------------------------------------------------------------------------------------
## Several cards exist under more than one passcode - an alternate artwork, or a reprint with a
## different number. The cdb's `alias` column points such a row at the original. Counting by raw
## passcode would let three "Harpie Lady" (76812113) and one "Cyber Harpie Lady" (80316585) sit
## in the same deck as four copies of one card. Every count below is therefore keyed on
## `identity()`, which resolves the alias.

## What can be wrong with a deck. Values are explicit so an issue list stays readable in a log
## and so renumbering cannot happen by accident when a member is inserted.
enum ISSUE {
	## A list has too few or too many cards. `list` names which, `count` and `limit` the numbers.
	MAIN_TOO_SMALL = 0,
	MAIN_TOO_LARGE = 1,
	EXTRA_TOO_SMALL = 2,
	EXTRA_TOO_LARGE = 3,
	SIDE_TOO_SMALL = 4,
	SIDE_TOO_LARGE = 5,
	## More than `limits.copies` of one card, counted across main + extra + side, by alias.
	TOO_MANY_COPIES = 6,
	## An extra-deck monster in the main deck, or a main-deck card in the extra deck. The side
	## deck is never wrong: it legally holds both kinds.
	WRONG_LIST = 7,
	## A Token. Tokens are made by effects and may not be in any deck.
	TOKEN_NOT_ALLOWED = 8,
	## No row in the card database for this passcode. Usually a deck built against a newer cdb.
	UNKNOWN_CODE = 9,
}

## The standard format. Override per host; see the header.
const DEFAULT_LIMITS: Dictionary = {
	"main_min": 40,
	"main_max": 60,
	"extra_min": 0,
	"extra_max": 15,
	"side_min": 0,
	"side_max": 15,
	"copies": 3,
}

## Size issues per list, indexed by `DeckModel.LIST`. Saves a three-way branch that could
## disagree with itself about which list it is reporting.
const _TOO_SMALL: Array[ISSUE] = [ISSUE.MAIN_TOO_SMALL, ISSUE.EXTRA_TOO_SMALL, ISSUE.SIDE_TOO_SMALL]
const _TOO_LARGE: Array[ISSUE] = [ISSUE.MAIN_TOO_LARGE, ISSUE.EXTRA_TOO_LARGE, ISSUE.SIDE_TOO_LARGE]
const _MIN_KEY: Array[String] = ["main_min", "extra_min", "side_min"]
const _MAX_KEY: Array[String] = ["main_max", "extra_max", "side_max"]


## A mutable copy, so a caller can adjust one field without editing the constant.
static func default_limits() -> Dictionary:
	return DEFAULT_LIMITS.duplicate()


## Host-supplied sizes merged over the defaults, so a host that only sets `main_min` does not
## have to restate the other six. Unknown keys are kept - they cost nothing and a future field
## should not be silently dropped on the way through.
static func limits_from(overrides: Dictionary) -> Dictionary:
	var limits: Dictionary = DEFAULT_LIMITS.duplicate()
	for key: Variant in overrides:
		limits[key] = overrides[key]
	return limits


## The passcode a card counts as for the copy limit: its alias when it has one, itself when it
## does not. `info` is a `KaibaCore.get_card_info()` Dictionary, or `{}` for an unknown card -
## in which case the code counts as itself, which is the only honest answer available.
static func identity(code: int, info: Dictionary) -> int:
	var alias: int = int(info.get("alias", 0))
	return alias if alias != 0 else code


# ----------------------------------------------------------------------------------------------
# The check
# ----------------------------------------------------------------------------------------------

## `info_for` is `func(code: int) -> Dictionary`, shaped like `KaibaCore.get_card_info()` and
## answering `{}` for a passcode the database does not have. A Callable rather than a prebuilt
## Dictionary of 14 595 cards: the validator needs at most sixty rows and should not force the
## caller to materialise the whole database to get them.
##
## Returns:
##
##     {
##       "ok":     bool,                 # issues.is_empty()
##       "issues": Array[Dictionary],    # see below; empty when ok
##       "counts": {"main": int, "extra": int, "side": int},
##       "limits": Dictionary,           # the limits actually applied, echoed back
##     }
##
## An issue is:
##
##     {
##       "issue": ISSUE,
##       "list":  DeckModel.LIST or -1,  # -1 when the issue is not about one list
##       "code":  int,                   # 0 when the issue is not about one card
##       "name":  String,                # "" when unknown; a convenience, never the payload
##       "count": int,                   # what was found
##       "limit": int,                   # what was allowed
##     }
##
## `WRONG_LIST` carries one extra key, `"belongs"`: the `DeckModel.LIST` the card should be in.
## No other issue has anywhere to put a second list.
##
## Issue order is deterministic: size issues first in main / extra / side order, then per-card
## issues in deck order, then copy-limit issues in first-appearance order. Tests and the UI both
## depend on it being stable.
static func validate(deck: DeckModel, info_for: Callable, limits: Dictionary = DEFAULT_LIMITS) -> Dictionary:
	var issues: Array[Dictionary] = []
	var counts: Dictionary = {}

	# --- sizes -------------------------------------------------------------------------------
	for which: int in [DeckModel.LIST.MAIN, DeckModel.LIST.EXTRA, DeckModel.LIST.SIDE]:
		var found: int = deck.size(which as DeckModel.LIST)
		counts[DeckModel.LIST_NAMES[which]] = found

		var low: int = int(limits.get(_MIN_KEY[which], DEFAULT_LIMITS[_MIN_KEY[which]]))
		var high: int = int(limits.get(_MAX_KEY[which], DEFAULT_LIMITS[_MAX_KEY[which]]))

		if found < low:
			issues.append(_issue(_TOO_SMALL[which], which, 0, "", found, low))
		elif found > high:
			issues.append(_issue(_TOO_LARGE[which], which, 0, "", found, high))

	# --- per card ----------------------------------------------------------------------------
	# One pass over the whole deck doing three things at once, so `info_for` is called once per
	# entry rather than three times. `copies` is keyed by alias identity and remembers the first
	# passcode and name it saw, which is what the copy-limit report names.
	var copies: Dictionary = {}
	var order: Array[int] = []

	for which: int in [DeckModel.LIST.MAIN, DeckModel.LIST.EXTRA, DeckModel.LIST.SIDE]:
		for code: int in deck.cards(which as DeckModel.LIST):
			var info: Dictionary = info_for.call(code)
			if typeof(info) != TYPE_DICTIONARY:
				info = {}
			var name: String = str(info.get("name", ""))

			if info.is_empty():
				issues.append(_issue(ISSUE.UNKNOWN_CODE, which, code, "", 1, 0))
			else:
				var type: int = int(info.get("type", 0))
				if DeckModel.is_token_type(type):
					issues.append(_issue(ISSUE.TOKEN_NOT_ALLOWED, which, code, name, 1, 0))
				elif which != DeckModel.LIST.SIDE:
					# The side deck holds both kinds, so it is never the wrong list.
					var belongs: DeckModel.LIST = DeckModel.list_for_type(type)
					if belongs != which:
						var wrong: Dictionary = _issue(ISSUE.WRONG_LIST, which, code, name, 1, 0)
						# The only issue that needs a second list in it: `list` is where the
						# card is, `belongs` is where it should go. The UI offers a one-tap move.
						wrong["belongs"] = int(belongs)
						issues.append(wrong)

			var key: int = identity(code, info)
			if not copies.has(key):
				copies[key] = {"count": 0, "code": code, "name": name}
				order.append(key)
			var slot: Dictionary = copies[key]
			slot["count"] = int(slot["count"]) + 1
			# An alias entry often has no text row of its own; keep the first name that exists.
			if str(slot["name"]).is_empty() and not name.is_empty():
				slot["name"] = name

	# --- copies ------------------------------------------------------------------------------
	var allowed: int = int(limits.get("copies", DEFAULT_LIMITS["copies"]))
	for key: int in order:
		var slot: Dictionary = copies[key]
		var found: int = int(slot["count"])
		if found > allowed:
			# `code` is the alias identity - the card the copies all *are* - rather than
			# whichever printing happened to be listed first.
			issues.append(_issue(ISSUE.TOO_MANY_COPIES, -1, key, str(slot["name"]), found, allowed))

	return {
		"ok": issues.is_empty(),
		"issues": issues,
		"counts": counts,
		"limits": limits.duplicate(),
	}


## True when `deck` is legal under `limits`. The cheap gate, for callers that do not want the
## report - a duel start, for instance.
static func is_legal(deck: DeckModel, info_for: Callable, limits: Dictionary = DEFAULT_LIMITS) -> bool:
	return bool(validate(deck, info_for, limits)["ok"])


## Issues of one kind, for a caller that cares about exactly one rule.
static func issues_of(result: Dictionary, issue: ISSUE) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Dictionary in result.get("issues", []):
		if int(entry["issue"]) == int(issue):
			out.append(entry)
	return out


static func _issue(issue: ISSUE, which: int, code: int, name: String, count: int, limit: int) -> Dictionary:
	return {
		"issue": issue,
		"list": which,
		"code": code,
		"name": name,
		"count": count,
		"limit": limit,
	}
