extends SceneTree

## Self-checking tests for the deck layer: `DeckModel`, `YdkIo`, `DeckValidator`.
##
##   godot --headless --path game --script res://core/deck/deck_test.gd
##
## Prints PASS or FAIL per case and exits non-zero if anything failed, same shape as
## `core/duel/duel_state_test.gd` and `ui/ui_test.gd`. No framework.
##
## -------------------------------------------------------------------------------------------
## Why this one talks to the real card database
## -------------------------------------------------------------------------------------------
## Routing a card to the main or the extra deck is a function of its `type` bitmask, and a test
## that supplies the bitmask itself proves only that the arithmetic in `DeckModel` matches the
## arithmetic in the test. The interesting failure is the other one: that a real Synchro in a
## real `cards.cdb` does not carry the bit we think it does, or that `TYPE_LINK` is set on
## something that is not a monster. So the fixtures below are **looked up**, by passcode, in
## `data/base/cards.cdb`.
##
## This file is under `game/core/`, not `game/ui/`, so naming the native core here is allowed -
## V1 constrains L4 and L5. Nothing in `core/deck/` itself touches it; only this test does, and
## only to fetch the fixtures.
##
## `data/` is gitignored (AGENTS.md section 9). With no database present, the cases that need
## one print SKIP and are not counted, exactly as `core/registry/card_art_test.gd` does. The
## pure cases - the parser, the serialiser, the copy rule - run either way.

const CORE_CLASS: String = "KaibaCore"
const CDB_PATH: String = "res://../data/base/cards.cdb"

## Looked up in `cards.cdb` at run time; the passcodes are real and the types they are asserted
## to carry are the database's, not ours. Chosen by scanning the shipped cdb for the first
## non-alias card of each kind, so each is an ordinary example rather than a special case.
const FUSION: int = 45349196       # Archfiend Black Skull Dragon
const SYNCHRO: int = 60992105      # Blackfeather Darkrage Dragon
const XYZ: int = 98986900          # Thelematech Clatis
const LINK: int = 7594154          # Zenna's Deceiving Doll Maidens
const RITUAL: int = 60258960       # Legendary Flame Lord - a Ritual *monster*
const TOKEN: int = 15394084        # Nordic Beast Token
const VANILLA: int = 89631139      # Blue-Eyes White Dragon
const SPELL: int = 55144522        # Pot of Greed

## An alias pair: 73134082 is a second printing of 73134081, both called "Final Flame", and the
## cdb points the former at the latter. Four copies spread across the two passcodes are four
## copies of one card and the copy rule has to see that.
const ALIAS_PRINT: int = 73134082
const ALIAS_ORIGINAL: int = 73134081

var _core: Object = null
var _case_name: String = ""
var _case_failures: PackedStringArray = []
var _cases_run: int = 0
var _cases_failed: int = 0
var _cases_skipped: int = 0


func _init() -> void:
	print("== DeckModel / YdkIo / DeckValidator tests ==")
	_open_core()

	_case_ydk_parses_edopro_output()
	_case_ydk_tolerates_a_hostile_file()
	_case_ydk_round_trips_byte_for_byte()
	_case_ydk_names_are_made_safe()

	_case_routing_by_type_bits()
	_case_model_counts_and_removal()

	_case_validator_reports_everything_at_once()
	_case_validator_copy_rule_spans_the_lists()
	_case_validator_limits_are_a_parameter()

	_case_real_cards_route_to_the_right_list()
	_case_real_alias_does_not_dodge_the_copy_limit()
	_case_real_token_and_unknown_code()
	_case_real_deck_round_trips()

	print("== %d cases, %d failed, %d skipped ==" % [_cases_run, _cases_failed, _cases_skipped])
	quit(1 if _cases_failed > 0 else 0)


# ----------------------------------------------------------------------------------------------
# YdkIo - the format
# ----------------------------------------------------------------------------------------------

## The exact bytes `DeckManager::SaveDeck` writes, parsed back.
func _case_ydk_parses_edopro_output() -> void:
	_begin("a .ydk written by EDOPro parses into three lists")

	var text: String = "#created by Seto\n#main\n89631139\n89631139\n55144522\n#extra\n45349196\n!side\n55144522\n"
	var deck: DeckModel = YdkIo.parse(text)

	_equal("main", deck.cards(DeckModel.LIST.MAIN), PackedInt32Array([89631139, 89631139, 55144522]))
	_equal("extra", deck.cards(DeckModel.LIST.EXTRA), PackedInt32Array([45349196]))
	_equal("side", deck.cards(DeckModel.LIST.SIDE), PackedInt32Array([55144522]))
	_equal("total", deck.total(), 5)

	# CRLF, which is what a file edited on Windows looks like.
	var crlf: DeckModel = YdkIo.parse(text.replace("\n", "\r\n"))
	_check("a CRLF file parses identically", crlf.equals(deck), "it did not")

	_end()


## Every branch of the parser that is easy to get wrong, in one file: a `!side` marker, stray
## `#` comments in all three sections, a `#main` that must NOT be treated as a mode switch,
## blank lines, and two unparseable lines that have to be skipped rather than fail the file.
func _case_ydk_tolerates_a_hostile_file() -> void:
	_begin("stray comments, !side and junk lines parse the way EDOPro parses them")

	var text: String = "".join(PackedStringArray([
		"#created by somebody\n",
		"# a bare comment\n",
		"#main\n",            # not a mode switch: main is simply where the parser starts
		"\n",
		"89631139\n",
		"# Blue-Eyes White Dragon\n",   # EDOPro's addCardNamesToDeckList mode writes these
		"89631139\n",
		"#extra\n",
		"45349196\n",
		"#notextra\n",        # a comment, not a switch - the following code stays in extra
		"60992105\n",
		"!side\n",            # it is the leading '!' that matters
		"55144522\n",
		"not a number\n",     # no digit at all: skipped
		"oops 42\n",          # has a digit but does not start with one: skipped, as stoul throws
		"  777  \n",          # leading whitespace and trailing junk: parses as 777
		"#Extra\n",           # wrong case, so a comment - the next code is still side
		"11111\n",
	]))

	var deck: DeckModel = YdkIo.parse(text)

	_equal("main took only the two before #extra",
		deck.cards(DeckModel.LIST.MAIN), PackedInt32Array([89631139, 89631139]))
	_equal("extra kept both codes across the stray comment",
		deck.cards(DeckModel.LIST.EXTRA), PackedInt32Array([45349196, 60992105]))
	_equal("side took everything after the ! marker, junk dropped",
		deck.cards(DeckModel.LIST.SIDE), PackedInt32Array([55144522, 777, 11111]))

	# '!' is the switch, not the word after it.
	var bang: DeckModel = YdkIo.parse("1\n!whatever\n2\n")
	_equal("any ! line switches to side", bang.cards(DeckModel.LIST.SIDE), PackedInt32Array([2]))

	# A file that is not a deck at all is an empty deck, not a crash and not a null.
	var garbage: DeckModel = YdkIo.parse("<html><body>404</body></html>")
	_check("a non-deck file yields an empty deck", garbage != null, "it returned null")

	_end()


func _case_ydk_round_trips_byte_for_byte() -> void:
	_begin("serialise -> parse -> serialise is byte-identical")

	var original: String = "#created by Seto\n#main\n89631139\n89631139\n55144522\n#extra\n45349196\n!side\n55144522\n"
	var once: String = YdkIo.serialise(YdkIo.parse(original), "Seto")
	_equal("a file EDOPro wrote comes back unchanged", once, original)

	var twice: String = YdkIo.serialise(YdkIo.parse(once), "Seto")
	_equal("and again", twice, once)

	# Only the author line may differ, and it is the first line.
	var other_author: String = YdkIo.serialise(YdkIo.parse(original), "Somebody Else")
	_equal("everything after the author line is identical",
		other_author.split("\n", true, 1)[1], original.split("\n", true, 1)[1])
	_check("the author line carries the name", other_author.begins_with("#created by Somebody Else\n"),
		"it read '%s'" % other_author.split("\n")[0])

	# An empty deck still has all three markers: EDOPro writes them unconditionally and a file
	# missing #extra would load its extra deck into main.
	_equal("an empty deck is still a well-formed file",
		YdkIo.serialise(DeckModel.new(), "x"), "#created by x\n#main\n#extra\n!side\n")

	# A newline in the author name would otherwise forge a section marker, and `#created by`
	# only comments out the first line of one.
	var hostile: String = YdkIo.serialise(DeckModel.new(), "x\n!side\n89631139")
	_equal("the author line is still one line", hostile.split("\n")[0],
		"#created by x !side 89631139")
	_check("and the forged code never reaches a list",
		YdkIo.parse(hostile).is_empty(), "it parsed as %s" % str(YdkIo.parse(hostile)))

	_end()


func _case_ydk_names_are_made_safe() -> void:
	_begin("a deck name becomes a filename without escaping the deck folder")

	_equal("path separators go", YdkIo.sanitise_name("../../etc/passwd"), ".._.._etc_passwd")
	_equal("windows-illegal characters go", YdkIo.sanitise_name("a:b*c?d"), "a_b_c_d")
	_equal("a name that sanitises away still names something", YdkIo.sanitise_name("   "), "deck")
	_check("the path stays under the deck folder",
		YdkIo.path_for("../escape").begins_with(YdkIo.deck_dir() + "/"),
		"it read '%s'" % YdkIo.path_for("../escape"))
	_check("decks live in user://", YdkIo.deck_dir().begins_with("user://"),
		"they live in %s" % YdkIo.deck_dir())

	_end()


# ----------------------------------------------------------------------------------------------
# DeckModel
# ----------------------------------------------------------------------------------------------

## The bitmask arithmetic on its own, including the two terms that look redundant and are not.
func _case_routing_by_type_bits() -> void:
	_begin("extra-deck routing, including the Link and Ritual qualifiers")

	var monster: int = DuelEnums.TYPE.MONSTER
	for bit: int in [DuelEnums.TYPE.FUSION, DuelEnums.TYPE.SYNCHRO, DuelEnums.TYPE.XYZ]:
		_check("0x%x routes to extra" % bit, DeckModel.is_extra_deck_type(monster | bit), "it did not")
		# The three non-Link branches do not test for the monster bit upstream either.
		_check("0x%x routes to extra even without the monster bit" % bit,
			DeckModel.is_extra_deck_type(bit), "it did not")

	_check("a Link monster routes to extra",
		DeckModel.is_extra_deck_type(monster | DuelEnums.TYPE.LINK), "it did not")
	_check("a Link SPELL does not - this is why the monster term is there",
		not DeckModel.is_extra_deck_type(DuelEnums.TYPE.SPELL | DuelEnums.TYPE.LINK), "it did")

	# Rituals are main-deck cards under modern rules; see the header of deck_model.gd.
	_check("a Ritual monster routes to main",
		not DeckModel.is_extra_deck_type(monster | DuelEnums.TYPE.RITUAL), "it routed to extra")
	_check("and is recognised as one",
		DeckModel.is_ritual_monster_type(monster | DuelEnums.TYPE.RITUAL), "it was not")
	_check("a Ritual SPELL is not a ritual monster",
		not DeckModel.is_ritual_monster_type(DuelEnums.TYPE.SPELL | DuelEnums.TYPE.RITUAL), "it was")

	_check("a plain monster routes to main", not DeckModel.is_extra_deck_type(monster), "it did not")
	_check("a token is recognised", DeckModel.is_token_type(monster | DuelEnums.TYPE.TOKEN), "it was not")

	_equal("list_for_type agrees", DeckModel.list_for_type(monster | DuelEnums.TYPE.XYZ),
		DeckModel.LIST.EXTRA)
	_equal("and for a main-deck card", DeckModel.list_for_type(DuelEnums.TYPE.TRAP),
		DeckModel.LIST.MAIN)

	_end()


func _case_model_counts_and_removal() -> void:
	_begin("counts span the lists and removal takes the last copy")

	var deck: DeckModel = DeckModel.new()
	deck.append(DeckModel.LIST.MAIN, 1)
	deck.append(DeckModel.LIST.MAIN, 2)
	deck.append(DeckModel.LIST.MAIN, 1)
	deck.append(DeckModel.LIST.SIDE, 1)

	_equal("main holds three", deck.size(DeckModel.LIST.MAIN), 3)
	_equal("two copies in main", deck.count_in(DeckModel.LIST.MAIN, 1), 2)
	_equal("three across the deck", deck.count(1), 3)
	_equal("grouped for the UI", deck.counts_by_code(DeckModel.LIST.MAIN), {1: 2, 2: 1})

	_check("removing one succeeds", deck.remove_one(DeckModel.LIST.MAIN, 1), "it did not")
	_equal("the LAST copy went, so the rest kept their places",
		deck.cards(DeckModel.LIST.MAIN), PackedInt32Array([1, 2]))
	_check("removing a card that is not there fails",
		not deck.remove_one(DeckModel.LIST.EXTRA, 1), "it reported success")

	var copy: DeckModel = deck.copy()
	_check("a copy is equal", copy.equals(deck), "it was not")
	copy.append(DeckModel.LIST.MAIN, 9)
	_check("and independent", not copy.equals(deck), "mutating the copy moved the original")

	_equal("all_codes is main then extra then side",
		deck.all_codes(), PackedInt32Array([1, 2, 1]))

	_end()


# ----------------------------------------------------------------------------------------------
# DeckValidator
# ----------------------------------------------------------------------------------------------

## A deck with four separate problems reports four, not the first.
func _case_validator_reports_everything_at_once() -> void:
	_begin("the validator reports every problem at once")

	var fusion_type: int = DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.FUSION
	var cards: Dictionary = {
		1: {"code": 1, "name": "Beater", "type": DuelEnums.TYPE.MONSTER, "alias": 0},
		2: {"code": 2, "name": "Big Fusion", "type": fusion_type, "alias": 0},
		3: {"code": 3, "name": "A Token", "type": DuelEnums.TYPE.MONSTER | DuelEnums.TYPE.TOKEN, "alias": 0},
	}
	var lookup: Callable = func(code: int) -> Dictionary: return cards.get(code, {})

	var deck: DeckModel = DeckModel.new()
	for i: int in 4:
		deck.append(DeckModel.LIST.MAIN, 1)   # four copies: one over
	deck.append(DeckModel.LIST.MAIN, 2)       # a Fusion in the main deck: wrong list
	deck.append(DeckModel.LIST.MAIN, 3)       # a Token: not allowed anywhere
	deck.append(DeckModel.LIST.MAIN, 999)     # not in the database

	var result: Dictionary = DeckValidator.validate(deck, lookup)

	_check("not ok", not bool(result["ok"]), "it said ok")
	_equal("counts are reported", result["counts"], {"main": 7, "extra": 0, "side": 0})

	# Five distinct problems, and the short deck is one of them.
	_equal("main is too small", DeckValidator.issues_of(result, DeckValidator.ISSUE.MAIN_TOO_SMALL).size(), 1)
	_equal("one wrong-list card", DeckValidator.issues_of(result, DeckValidator.ISSUE.WRONG_LIST).size(), 1)
	_equal("one token", DeckValidator.issues_of(result, DeckValidator.ISSUE.TOKEN_NOT_ALLOWED).size(), 1)
	_equal("one unknown code", DeckValidator.issues_of(result, DeckValidator.ISSUE.UNKNOWN_CODE).size(), 1)
	_equal("one copy violation", DeckValidator.issues_of(result, DeckValidator.ISSUE.TOO_MANY_COPIES).size(), 1)

	var size_issue: Dictionary = DeckValidator.issues_of(result, DeckValidator.ISSUE.MAIN_TOO_SMALL)[0]
	_equal("the size issue carries the numbers", [size_issue["count"], size_issue["limit"]], [7, 40])

	var wrong: Dictionary = DeckValidator.issues_of(result, DeckValidator.ISSUE.WRONG_LIST)[0]
	_equal("the wrong-list issue says where it is", wrong["list"], DeckModel.LIST.MAIN)
	_equal("and where it belongs", wrong["belongs"], DeckModel.LIST.EXTRA)
	_equal("and which card", wrong["code"], 2)

	# Nothing in the validator may produce prose. The UI does that.
	for issue: Dictionary in result["issues"]:
		_check("the issue is structured", issue.has("issue") and typeof(issue["issue"]) == TYPE_INT,
			"got %s" % str(issue))

	# The side deck is never the wrong list: it legally holds both kinds.
	var sided: DeckModel = DeckModel.new()
	sided.append(DeckModel.LIST.SIDE, 2)
	var side_result: Dictionary = DeckValidator.validate(sided, lookup)
	_equal("a Fusion in the side deck is not a wrong-list issue",
		DeckValidator.issues_of(side_result, DeckValidator.ISSUE.WRONG_LIST).size(), 0)

	_end()


## The headline rule: four copies spread across main and side is still four copies.
func _case_validator_copy_rule_spans_the_lists() -> void:
	_begin("three in main plus one in side is four copies, and is caught")

	var cards: Dictionary = {7: {"code": 7, "name": "Pot of Greed", "type": DuelEnums.TYPE.SPELL, "alias": 0}}
	var lookup: Callable = func(code: int) -> Dictionary: return cards.get(code, {})

	var deck: DeckModel = DeckModel.new()
	for i: int in 3:
		deck.append(DeckModel.LIST.MAIN, 7)
	deck.append(DeckModel.LIST.SIDE, 7)

	var found: Array[Dictionary] = DeckValidator.issues_of(
		DeckValidator.validate(deck, lookup), DeckValidator.ISSUE.TOO_MANY_COPIES)
	_equal("one copy violation", found.size(), 1)
	if found.size() == 1:
		_equal("counted across the lists", found[0]["count"], 4)
		_equal("against the limit", found[0]["limit"], 3)
		_equal("naming the card", found[0]["name"], "Pot of Greed")

	# Exactly three is legal.
	var legal: DeckModel = DeckModel.new()
	for i: int in 3:
		legal.append(DeckModel.LIST.MAIN, 7)
	_equal("three is fine", DeckValidator.issues_of(
		DeckValidator.validate(legal, lookup), DeckValidator.ISSUE.TOO_MANY_COPIES).size(), 0)

	_end()


## Deck sizes are not the engine's. They arrive per host in `DeckSizes` (`gframe/network.h`).
func _case_validator_limits_are_a_parameter() -> void:
	_begin("deck sizes are a parameter a host can override")

	_equal("the default is the standard format",
		[DeckValidator.DEFAULT_LIMITS["main_min"], DeckValidator.DEFAULT_LIMITS["main_max"]], [40, 60])
	_equal("extra and side default to 0-15",
		[DeckValidator.DEFAULT_LIMITS["extra_max"], DeckValidator.DEFAULT_LIMITS["side_max"]], [15, 15])
	_equal("and three copies", DeckValidator.DEFAULT_LIMITS["copies"], 3)

	var lookup: Callable = func(code: int) -> Dictionary:
		return {"code": code, "name": "x", "type": DuelEnums.TYPE.SPELL, "alias": 0}

	var deck: DeckModel = DeckModel.new()
	for i: int in 20:
		deck.append(DeckModel.LIST.MAIN, i + 1)

	_check("twenty cards is illegal by default",
		not DeckValidator.is_legal(deck, lookup), "it was legal")

	var host_limits: Dictionary = DeckValidator.limits_from({"main_min": 20, "main_max": 20})
	_check("and legal under a host that said 20",
		DeckValidator.is_legal(deck, lookup, host_limits), "it was still illegal")
	_equal("an override keeps the fields it did not set", host_limits["side_max"], 15)
	_equal("the result echoes the limits it applied",
		DeckValidator.validate(deck, lookup, host_limits)["limits"]["main_min"], 20)
	_equal("overriding does not edit the default",
		DeckValidator.DEFAULT_LIMITS["main_min"], 40)

	var strict: Dictionary = DeckValidator.limits_from({"main_min": 20, "main_max": 20, "copies": 1})
	var doubled: DeckModel = deck.copy()
	doubled.remove_one(DeckModel.LIST.MAIN, 20)
	doubled.append(DeckModel.LIST.MAIN, 1)
	_equal("a one-copy format catches the pair",
		DeckValidator.issues_of(DeckValidator.validate(doubled, lookup, strict),
			DeckValidator.ISSUE.TOO_MANY_COPIES).size(), 1)

	_end()


# ----------------------------------------------------------------------------------------------
# Against the real cards.cdb
# ----------------------------------------------------------------------------------------------

## The case the whole file exists for: real cards, real type bits, real routing.
func _case_real_cards_route_to_the_right_list() -> void:
	if not _begin_real("a real Fusion, Synchro, Xyz and Link go to extra; a real Ritual goes to main"):
		return

	for pair: Array in [[FUSION, "Fusion"], [SYNCHRO, "Synchro"], [XYZ, "Xyz"], [LINK, "Link"]]:
		var code: int = int(pair[0])
		var info: Dictionary = _core.get_card_info(code)
		_check("%d is in the database" % code, not info.is_empty(), "get_card_info returned {}")
		if info.is_empty():
			continue
		var type: int = int(info["type"])
		_check("%s '%s' is a monster" % [str(pair[1]), str(info["name"])],
			(type & DuelEnums.TYPE.MONSTER) != 0, "type 0x%x" % type)
		_equal("%s '%s' routes to extra" % [str(pair[1]), str(info["name"])],
			DeckModel.list_for_type(type), DeckModel.LIST.EXTRA)

	var ritual: Dictionary = _core.get_card_info(RITUAL)
	_check("the ritual fixture is in the database", not ritual.is_empty(), "{}")
	if not ritual.is_empty():
		var type: int = int(ritual["type"])
		_check("'%s' really is a Ritual monster" % str(ritual["name"]),
			DeckModel.is_ritual_monster_type(type), "type 0x%x" % type)
		_equal("and routes to MAIN under modern rules",
			DeckModel.list_for_type(type), DeckModel.LIST.MAIN)

	var vanilla: Dictionary = _core.get_card_info(VANILLA)
	_equal("Blue-Eyes routes to main", DeckModel.list_for_type(int(vanilla.get("type", 0))),
		DeckModel.LIST.MAIN)
	var spell: Dictionary = _core.get_card_info(SPELL)
	_equal("Pot of Greed routes to main", DeckModel.list_for_type(int(spell.get("type", 0))),
		DeckModel.LIST.MAIN)

	# And the whole way through the model, not just the classifier.
	var deck: DeckModel = DeckModel.new()
	for code: int in [FUSION, SYNCHRO, XYZ, LINK, RITUAL, VANILLA, SPELL]:
		deck.add(code, int(_core.get_card_info(code).get("type", 0)))
	_equal("add() put four cards in extra", deck.size(DeckModel.LIST.EXTRA), 4)
	_equal("and three in main", deck.size(DeckModel.LIST.MAIN), 3)
	_check("the ritual is one of the three", deck.count_in(DeckModel.LIST.MAIN, RITUAL) == 1,
		"it is not in main")

	# And then back through the validator, which must find nothing wrong with the lists.
	var result: Dictionary = DeckValidator.validate(deck, _info_for)
	_equal("no card is in the wrong list",
		DeckValidator.issues_of(result, DeckValidator.ISSUE.WRONG_LIST).size(), 0)

	_end()


## Alternate printings must not be a way round the copy limit.
func _case_real_alias_does_not_dodge_the_copy_limit() -> void:
	if not _begin_real("an alias does not dodge the three-copy limit"):
		return

	var printing: Dictionary = _core.get_card_info(ALIAS_PRINT)
	var original: Dictionary = _core.get_card_info(ALIAS_ORIGINAL)
	_check("both printings are in the database",
		not printing.is_empty() and not original.is_empty(), "one was missing")
	if printing.is_empty() or original.is_empty():
		_end()
		return

	_equal("the second printing aliases the first", int(printing["alias"]), ALIAS_ORIGINAL)
	_equal("and the first aliases nothing", int(original.get("alias", 0)), 0)
	_equal("they are the same card", str(printing["name"]), str(original["name"]))
	_equal("identity() resolves the alias",
		DeckValidator.identity(ALIAS_PRINT, printing), ALIAS_ORIGINAL)
	_equal("and leaves the original alone",
		DeckValidator.identity(ALIAS_ORIGINAL, original), ALIAS_ORIGINAL)

	# Three of one printing in main plus one of the other in the side deck. Counting by raw
	# passcode this is 3 + 1 of two different cards and perfectly legal. It is not.
	var deck: DeckModel = DeckModel.new()
	for i: int in 3:
		deck.append(DeckModel.LIST.MAIN, ALIAS_ORIGINAL)
	deck.append(DeckModel.LIST.SIDE, ALIAS_PRINT)

	var found: Array[Dictionary] = DeckValidator.issues_of(
		DeckValidator.validate(deck, _info_for), DeckValidator.ISSUE.TOO_MANY_COPIES)
	_equal("the alias is caught", found.size(), 1)
	if found.size() == 1:
		_equal("as four copies", found[0]["count"], 4)
		_equal("reported against the original passcode", found[0]["code"], ALIAS_ORIGINAL)

	# Two of each is still four.
	var mixed: DeckModel = DeckModel.new()
	for i: int in 2:
		mixed.append(DeckModel.LIST.MAIN, ALIAS_ORIGINAL)
		mixed.append(DeckModel.LIST.MAIN, ALIAS_PRINT)
	_equal("two of each printing is four copies", DeckValidator.issues_of(
		DeckValidator.validate(mixed, _info_for), DeckValidator.ISSUE.TOO_MANY_COPIES)[0]["count"], 4)

	# But three in total, however they are spelled, is legal.
	var legal: DeckModel = DeckModel.new()
	legal.append(DeckModel.LIST.MAIN, ALIAS_ORIGINAL)
	legal.append(DeckModel.LIST.MAIN, ALIAS_PRINT)
	legal.append(DeckModel.LIST.SIDE, ALIAS_PRINT)
	_equal("three across both printings is legal", DeckValidator.issues_of(
		DeckValidator.validate(legal, _info_for), DeckValidator.ISSUE.TOO_MANY_COPIES).size(), 0)

	_end()


func _case_real_token_and_unknown_code() -> void:
	if not _begin_real("a real Token is rejected, and an unknown passcode is reported not guessed"):
		return

	var token: Dictionary = _core.get_card_info(TOKEN)
	_check("the token fixture is in the database", not token.is_empty(), "{}")
	if not token.is_empty():
		_check("'%s' really carries TYPE_TOKEN" % str(token["name"]),
			DeckModel.is_token_type(int(token["type"])), "type 0x%x" % int(token["type"]))

	var deck: DeckModel = DeckModel.new()
	deck.append(DeckModel.LIST.MAIN, TOKEN)
	deck.append(DeckModel.LIST.MAIN, 999999999)

	var result: Dictionary = DeckValidator.validate(deck, _info_for)
	_equal("the token is reported",
		DeckValidator.issues_of(result, DeckValidator.ISSUE.TOKEN_NOT_ALLOWED).size(), 1)
	_equal("the unknown passcode is reported",
		DeckValidator.issues_of(result, DeckValidator.ISSUE.UNKNOWN_CODE).size(), 1)
	# An unknown card is not also accused of being in the wrong list: we do not know what it is.
	_equal("and is not also called wrong-list",
		DeckValidator.issues_of(result, DeckValidator.ISSUE.WRONG_LIST).size(), 0)

	_end()


## A deck built out of real cards, written as this code writes it, read back identically.
func _case_real_deck_round_trips() -> void:
	if not _begin_real("a .ydk this code wrote parses back to the same deck"):
		return

	var deck: DeckModel = DeckModel.new()
	for i: int in 40:
		deck.append(DeckModel.LIST.MAIN, VANILLA if i % 2 == 0 else SPELL)
	for code: int in [FUSION, SYNCHRO, XYZ, LINK]:
		deck.append(DeckModel.LIST.EXTRA, code)
	deck.append(DeckModel.LIST.SIDE, RITUAL)

	var text: String = YdkIo.serialise(deck, "Project Kaiba")
	var parsed: DeckModel = YdkIo.parse(text)
	_check("the deck survives the round trip", parsed.equals(deck), "it did not")
	_equal("and re-serialises to the same bytes", YdkIo.serialise(parsed, "Project Kaiba"), text)

	# Through a real file in user://, which is where decks actually live.
	var path: String = YdkIo.path_for("deck_test_scratch")
	var saved: Error = YdkIo.save_to(deck, path, "Project Kaiba")
	_equal("it saves", saved, OK)
	if saved == OK:
		var loaded: DeckModel = YdkIo.parse_file(path)
		_check("and loads back equal", loaded != null and loaded.equals(deck), "it did not")
		_check("the folder lists it", YdkIo.list_decks().has("deck_test_scratch"),
			"list_decks() returned %s" % str(YdkIo.list_decks()))
		DirAccess.remove_absolute(path)

	_check("a file that is not there loads as null", YdkIo.parse_file(
		YdkIo.path_for("no_such_deck_at_all")) == null, "it returned a deck")

	_end()


# ----------------------------------------------------------------------------------------------
# Fixtures and harness
# ----------------------------------------------------------------------------------------------

func _open_core() -> void:
	if not ClassDB.class_exists(CORE_CLASS):
		print("NOTE  the GDExtension is not loaded; the cases that need cards.cdb will SKIP")
		return
	if not FileAccess.file_exists(CDB_PATH):
		print("NOTE  %s is missing; the cases that need it will SKIP (docs/DATA.md)" % CDB_PATH)
		return
	var core: Object = ClassDB.instantiate(CORE_CLASS)
	var loaded: Dictionary = core.load_card_database(CDB_PATH)
	if not bool(loaded.get("ok", false)):
		print("NOTE  %s did not load: %s" % [CDB_PATH, str(loaded.get("error", ""))])
		return
	_core = core
	print("        cards.cdb: %d rows" % int(loaded.get("count", 0)))


func _info_for(code: int) -> Dictionary:
	return _core.get_card_info(code) if _core != null else {}


## Starts a case that needs the real database, or prints SKIP and answers false.
func _begin_real(case_name: String) -> bool:
	if _core == null:
		print("SKIP  %s (no cards.cdb)" % case_name)
		_cases_skipped += 1
		return false
	_begin(case_name)
	return true


func _begin(case_name: String) -> void:
	_case_name = case_name
	_case_failures = PackedStringArray()


func _check(label: String, passed: bool, detail: String) -> void:
	if passed:
		return
	_case_failures.append("%s (%s)" % [label, detail])


func _equal(label: String, actual: Variant, expected: Variant) -> void:
	_check(label, _same(actual, expected), "expected %s, got %s" % [str(expected), str(actual)])


## Godot's `==` on Array and Dictionary is identity, not content, so compare the serialised
## form instead. Scalars fall through to a plain comparison.
func _same(actual: Variant, expected: Variant) -> bool:
	if actual is Array or actual is Dictionary or expected is Array or expected is Dictionary:
		return JSON.stringify(actual) == JSON.stringify(expected)
	if actual is PackedInt32Array or expected is PackedInt32Array:
		return str(actual) == str(expected)
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
