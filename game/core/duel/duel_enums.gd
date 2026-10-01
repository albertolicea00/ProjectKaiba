class_name DuelEnums

## Mirror of the C++ constants. Drift between this file and the native side is a bug.
##
## Authority, in order:
##   1. `native/vendor/ocgcore/ocgapi_constants.h` for LOCATION, POSITION, TYPE, ATTRIBUTE,
##      RACE, PHASE, REASON, PLAYER. Every value here was copied from that header verbatim.
##   2. `native/src/duel_event.h` for EV, once it exists.
##
## EV did not have a native counterpart when this file was written: `native/src/duel_event.h`
## was absent. The members below are the "Minimum set for the MVP" from
## docs/ARCHITECTURE.md section 7, and their values are the ocgcore `MSG_*` opcodes from
## `ocgapi_constants.h` — the same header, so the two sides can be diffed mechanically rather
## than trusted. If `duel_event.h` ever renumbers these, THIS FILE IS WRONG, not that one.
##
## Nothing here may be "tidied". A changed value is a silent wire-format break.
##
## Layer: L3 (see AGENTS.md section 4). No scene-tree types. V2, V11, V14.

# --------------------------------------------------------------------------------------------
# Event types (Level 1 `DuelEvent.t`)
# --------------------------------------------------------------------------------------------

## Values are the ocgcore `MSG_*` opcodes. The MVP subset of docs/ARCHITECTURE.md section 7 is
## marked; the rest are listed so an unhandled opcode can still be named in a warning instead of
## being printed as a bare integer (V13).
enum EV {
	RETRY = 1,
	HINT = 2,
	WAITING = 3,
	START = 4,                  # MVP. Host-generated, not emitted by ocgcore.
	WIN = 5,                    # MVP
	UPDATE_DATA = 6,            # MVP. Host-generated from OCG_DuelQueryLocation.
	UPDATE_CARD = 7,            # MVP. Host-generated from OCG_DuelQuery.
	REQUEST_DECK = 8,
	SELECT_BATTLECMD = 10,      # MVP
	SELECT_IDLECMD = 11,        # MVP
	SELECT_EFFECTYN = 12,       # MVP
	SELECT_YESNO = 13,          # MVP
	SELECT_OPTION = 14,         # MVP
	SELECT_CARD = 15,           # MVP
	SELECT_CHAIN = 16,          # MVP
	SELECT_PLACE = 18,          # MVP
	SELECT_POSITION = 19,       # MVP
	SELECT_TRIBUTE = 20,        # MVP
	SORT_CHAIN = 21,
	SELECT_COUNTER = 22,
	SELECT_SUM = 23,            # MVP
	SELECT_DISFIELD = 24,
	SORT_CARD = 25,             # MVP
	SELECT_UNSELECT_CARD = 26,
	CONFIRM_DECKTOP = 30,
	CONFIRM_CARDS = 31,         # MVP
	SHUFFLE_DECK = 32,          # MVP
	SHUFFLE_HAND = 33,          # MVP
	REFRESH_DECK = 34,
	SWAP_GRAVE_DECK = 35,
	SHUFFLE_SET_CARD = 36,      # MVP
	REVERSE_DECK = 37,
	DECK_TOP = 38,
	SHUFFLE_EXTRA = 39,         # MVP
	NEW_TURN = 40,              # MVP
	NEW_PHASE = 41,             # MVP
	CONFIRM_EXTRATOP = 42,
	MOVE = 50,                  # MVP
	POS_CHANGE = 53,            # MVP
	SET = 54,                   # MVP
	SWAP = 55,
	FIELD_DISABLED = 56,
	SUMMONING = 60,             # MVP
	SUMMONED = 61,              # MVP
	SPSUMMONING = 62,           # MVP
	SPSUMMONED = 63,            # MVP
	FLIPSUMMONING = 64,         # MVP
	FLIPSUMMONED = 65,          # MVP
	CHAINING = 70,              # MVP
	CHAINED = 71,               # MVP
	CHAIN_SOLVING = 72,         # MVP
	CHAIN_SOLVED = 73,          # MVP
	CHAIN_END = 74,             # MVP
	CHAIN_NEGATED = 75,
	CHAIN_DISABLED = 76,
	CARD_SELECTED = 80,
	RANDOM_SELECTED = 81,
	BECOME_TARGET = 83,
	DRAW = 90,                  # MVP
	DAMAGE = 91,                # MVP
	RECOVER = 92,               # MVP
	EQUIP = 93,
	LPUPDATE = 94,              # MVP
	UNEQUIP = 95,
	CARD_TARGET = 96,
	CANCEL_TARGET = 97,
	PAY_LPCOST = 100,
	ADD_COUNTER = 101,
	REMOVE_COUNTER = 102,
	ATTACK = 110,               # MVP
	BATTLE = 111,               # MVP
	ATTACK_DISABLED = 112,      # MVP
	DAMAGE_STEP_START = 113,
	DAMAGE_STEP_END = 114,
	MISSED_EFFECT = 120,
	BE_CHAIN_TARGET = 121,
	CREATE_RELATION = 122,
	RELEASE_RELATION = 123,
	TOSS_COIN = 130,
	TOSS_DICE = 131,
	ROCK_PAPER_SCISSORS = 132,
	HAND_RES = 133,
	ANNOUNCE_RACE = 140,
	ANNOUNCE_ATTRIB = 141,
	ANNOUNCE_CARD = 142,
	ANNOUNCE_NUMBER = 143,
	CARD_HINT = 160,
	TAG_SWAP = 161,
	RELOAD_FIELD = 162,
	AI_NAME = 163,
	SHOW_HINT = 164,
	PLAYER_HINT = 165,
	MATCH_KILL = 170,
	CUSTOM_MSG = 180,
	REMOVE_CARDS = 190,
}

# --------------------------------------------------------------------------------------------
# ocgcore constants — ocgapi_constants.h
# --------------------------------------------------------------------------------------------

## `LOCATION_*`. Bit flags: a query may carry `MZONE | OVERLAY` to mean "xyz material on a
## monster zone", which is why these are powers of two and must be tested with `&`.
enum LOCATION {
	DECK = 0x01,
	HAND = 0x02,
	MZONE = 0x04,
	SZONE = 0x08,
	GRAVE = 0x10,
	REMOVED = 0x20,
	EXTRA = 0x40,
	OVERLAY = 0x80,
	ONFIELD = 0x0C,   # MZONE | SZONE
}

## `POS_*`. ARCHITECTURE.md section 7 abbreviates these as `FACEUP_ATK`; the header spells them
## out, and the header wins.
enum POSITION {
	FACEUP_ATTACK = 0x1,
	FACEDOWN_ATTACK = 0x2,
	FACEUP_DEFENSE = 0x4,
	FACEDOWN_DEFENSE = 0x8,
	FACEUP = 0x5,     # FACEUP_ATTACK | FACEUP_DEFENSE
	FACEDOWN = 0xA,   # FACEDOWN_ATTACK | FACEDOWN_DEFENSE
	ATTACK = 0x3,     # FACEUP_ATTACK | FACEDOWN_ATTACK
	DEFENSE = 0xC,    # FACEUP_DEFENSE | FACEDOWN_DEFENSE
}

## `TYPE_*`.
enum TYPE {
	MONSTER = 0x1,
	SPELL = 0x2,
	TRAP = 0x4,
	NORMAL = 0x10,
	EFFECT = 0x20,
	FUSION = 0x40,
	RITUAL = 0x80,
	TRAPMONSTER = 0x100,
	SPIRIT = 0x200,
	UNION = 0x400,
	GEMINI = 0x800,
	TUNER = 0x1000,
	SYNCHRO = 0x2000,
	TOKEN = 0x4000,
	MAXIMUM = 0x8000,
	QUICKPLAY = 0x10000,
	CONTINUOUS = 0x20000,
	EQUIP = 0x40000,
	FIELD = 0x80000,
	COUNTER = 0x100000,
	FLIP = 0x200000,
	TOON = 0x400000,
	XYZ = 0x800000,
	PENDULUM = 0x1000000,
	SPSUMMON = 0x2000000,
	LINK = 0x4000000,
}

## `ATTRIBUTE_*`.
enum ATTRIBUTE {
	EARTH = 0x01,
	WATER = 0x02,
	FIRE = 0x04,
	WIND = 0x08,
	LIGHT = 0x10,
	DARK = 0x20,
	DIVINE = 0x40,
}

## `ATTRIBUTE_ALL`. Kept out of the enum so reverse name lookup stays unambiguous.
const ATTRIBUTE_ALL: int = 0x7F

## `RACE_*`. 64-bit since ocgcore v11 (`RACE_YOKAI` sits in the high word); GDScript `int` is
## int64, so these survive the boundary intact. V14.
enum RACE {
	WARRIOR = 0x1,
	SPELLCASTER = 0x2,
	FAIRY = 0x4,
	FIEND = 0x8,
	ZOMBIE = 0x10,
	MACHINE = 0x20,
	AQUA = 0x40,
	PYRO = 0x80,
	ROCK = 0x100,
	WINGEDBEAST = 0x200,
	PLANT = 0x400,
	INSECT = 0x800,
	THUNDER = 0x1000,
	DRAGON = 0x2000,
	BEAST = 0x4000,
	BEASTWARRIOR = 0x8000,
	DINOSAUR = 0x10000,
	FISH = 0x20000,
	SEASERPENT = 0x40000,
	REPTILE = 0x80000,
	PSYCHIC = 0x100000,
	DIVINE = 0x200000,
	CREATORGOD = 0x400000,
	WYRM = 0x800000,
	CYBERSE = 0x1000000,
	ILLUSION = 0x2000000,
	CYBORG = 0x4000000,
	MAGICALKNIGHT = 0x8000000,
	HIGHDRAGON = 0x10000000,
	OMEGAPSYCHIC = 0x20000000,
	CELESTIALWARRIOR = 0x40000000,
	GALAXY = 0x80000000,
	YOKAI = 0x4000000000000000,
}

## `RACE_MAX` / `RACE_ALL`. Outside the enum: both alias values already present in it.
const RACE_MAX: int = 0x80000000
const RACE_ALL: int = 0x40000000FFFFFFFF

## `PHASE_*`. Bit flags, not an ordinal sequence — do not compare with `<`.
enum PHASE {
	DRAW = 0x01,
	STANDBY = 0x02,
	MAIN1 = 0x04,
	BATTLE_START = 0x08,
	BATTLE_STEP = 0x10,
	DAMAGE = 0x20,
	DAMAGE_CAL = 0x40,
	BATTLE = 0x80,
	MAIN2 = 0x100,
	END = 0x200,
}

## `REASON_*`. Why a card moved. Carried on `MOVE` as a bitmask: a tribute summon material
## arrives as `RELEASE | SUMMON`.
enum REASON {
	DESTROY = 0x1,
	RELEASE = 0x2,
	TEMPORARY = 0x4,
	MATERIAL = 0x8,
	SUMMON = 0x10,
	BATTLE = 0x20,
	EFFECT = 0x40,
	COST = 0x80,
	ADJUST = 0x100,
	LOST_TARGET = 0x200,
	RULE = 0x400,
	SPSUMMON = 0x800,
	DISSUMMON = 0x1000,
	FLIP = 0x2000,
	DISCARD = 0x4000,
	RDAMAGE = 0x8000,
	RRECOVER = 0x10000,
	RETURN = 0x20000,
	FUSION = 0x40000,
	SYNCHRO = 0x80000,
	RITUAL = 0x100000,
	XYZ = 0x200000,
	REPLACE = 0x1000000,
	DRAW = 0x2000000,
	REDIRECT = 0x4000000,
	LINK = 0x10000000,
}

## `PLAYER_*`. `WIN` reports `NONE` for a draw, so a winner is not always 0 or 1.
enum PLAYER {
	P0 = 0,
	P1 = 1,
	NONE = 2,
	ALL = 3,
}

# --------------------------------------------------------------------------------------------
# Zone geometry — native/vendor/ocgcore/field.h, `player_info`
# --------------------------------------------------------------------------------------------
#
# `list_mzone.resize(7)`  -> 0..4 main monster zones, 5..6 extra monster zones.
# `list_szone.resize(8)`  -> 0..4 spell & trap zones, 5 field zone, 6..7 pendulum zones.
#
# The pendulum zones only live at szone 6/7 under `DUEL_SEPARATE_PZONE` (MR3). Under MR4/MR5
# `field::get_pzone_index` returns `seq * 4`, so pendulum cards occupy spell/trap zones 0 and 4
# and need no separate storage. DuelState models MR4/MR5 and treats szone 6/7 as out of model.

const MAIN_MONSTER_ZONES: int = 5
const EXTRA_MONSTER_ZONES: int = 2
const SPELL_TRAP_ZONES: int = 5
const MZONE_SLOTS: int = 7
const SZONE_SLOTS: int = 8
const FIELD_ZONE_SEQUENCE: int = 5
const PENDULUM_LEFT_SEQUENCE: int = 6
const PENDULUM_RIGHT_SEQUENCE: int = 7
const PLAYER_COUNT: int = 2

# --------------------------------------------------------------------------------------------
# Naming helpers. Diagnostics only — never let these feed back into state.
# --------------------------------------------------------------------------------------------

## Name of an event type, or `EV(<n>)` when the opcode is not one we know. Used by the
## unhandled-opcode warning required by V13.
static func ev_name(value: int) -> String:
	return _name_of(EV, value, "EV")


## Name of a location. Reports the `OVERLAY` bit separately because it is a modifier on another
## location rather than a location of its own.
static func location_name(value: int) -> String:
	if (value & LOCATION.OVERLAY) != 0 and value != LOCATION.OVERLAY:
		return "%s|OVERLAY" % location_name(value & ~LOCATION.OVERLAY)
	return _name_of(LOCATION, value, "LOC")


static func position_name(value: int) -> String:
	return _name_of(POSITION, value, "POS")


static func phase_name(value: int) -> String:
	return _name_of(PHASE, value, "PHASE")


## Decomposes a bitmask into the `|`-joined names of its set bits. For REASON and TYPE, which
## are almost always combinations.
static func flags_to_string(dict: Dictionary, value: int, prefix: String) -> String:
	if value == 0:
		return "NONE"
	var parts: PackedStringArray = []
	var covered: int = 0
	for key: String in dict:
		var bit: int = dict[key]
		if bit != 0 and (value & bit) == bit and (bit & (bit - 1)) == 0:
			parts.append(key)
			covered |= bit
	var rest: int = value & ~covered
	if rest != 0:
		parts.append("%s(0x%X)" % [prefix, rest])
	return "|".join(parts)


static func reason_to_string(value: int) -> String:
	return flags_to_string(REASON, value, "REASON")


static func type_to_string(value: int) -> String:
	return flags_to_string(TYPE, value, "TYPE")


static func _name_of(dict: Dictionary, value: int, prefix: String) -> String:
	for key: String in dict:
		if dict[key] == value:
			return key
	return "%s(%d)" % [prefix, value]
