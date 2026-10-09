#ifndef KAIBA_DUEL_EVENT_H
#define KAIBA_DUEL_EVENT_H

// Level 1 of the event model (docs/ARCHITECTURE.md section 7): the typed, lossless,
// replayable form of one ocgcore MSG_* message.
//
// A DuelEvent is a godot::Dictionary, not a struct. That is deliberate: invariant V14 says
// only Dictionary / PackedByteArray cross the C++/GDScript boundary, so a struct would only
// buy a second conversion layer. Every event carries the integer key "t" holding an EV value.
//
// OWNERSHIP: this file belongs to the MsgParser work. Other modules include it; they do not
// edit it.
//
// Field naming convention, fixed by the EV::MOVE example in ARCHITECTURE.md section 7:
//
//   "t"                 int, an EV value
//   "card"              int, a card code. 0 means "face-down / not revealed to this player".
//   "from" / "to"       Dictionary, a loc_info (see loc_dict below)
//   "at"                Dictionary, a loc_info, for messages that carry exactly one
//   "reason"            int, a REASON_* bitmask
//   "player"            int, 0 or 1, in ABSOLUTE core coordinates (see the note below)
//   "loc"               int, a raw LOCATION_* byte. Note the asymmetry: inside a loc_info
//                       dict "loc" is the raw byte too, so a Dictionary-valued "loc" would
//                       contradict the spec's own example. Single locations use "at".
//
// PLAYER COORDINATES: every player id here is the one ocgcore emitted. EDOPro rewrites them
// through LocalPlayer() while parsing so that the viewer is always player 0; we deliberately
// do not. L1 is shared by host, client and replay, and a replay that baked in one viewer's
// perspective could not be watched from the other side (V9). Flipping perspective is a
// presentation concern and belongs in L3/L4.

#include <cstdint>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "core_utils.h"

namespace kaiba {

/// Identity of a Level 1 event.
///
/// The numeric values are the ocgcore MSG_* opcodes. Two reasons:
///   - replays store Level 1 events (V9), so these numbers are a serialisation format and
///     must stay stable; mirroring the engine's own long-stable constants is the cheapest
///     way to get that.
///   - an UNHANDLED event reports a raw "opcode", which is then directly comparable.
/// msg_parser.cpp static_asserts every value below against vendor/ocgcore, so a core bump
/// that renumbered anything breaks the build instead of corrupting replays.
///
/// Values at or above 1000 are reserved for events Project Kaiba synthesises itself and that
/// no opcode corresponds to. The parser-level outcomes live at 1100+ rather than at 0 and 1:
/// MSG_RETRY really is opcode 1, so putting MALFORMED there made two different things share
/// a tag. DuelThread's LifecycleEvent occupies 1000-1003.
enum class EV : int32_t {
	/// ocgcore rejected the last response and re-parked on the same selection.
	///
	/// This one matters more than its size suggests: ocgcore does NOT re-emit the original
	/// MSG_SELECT_*, so a client that waits for a fresh request after a bad answer waits
	/// forever. Treat it as "resend an answer to the selection you are already holding".
	RETRY = 1,

	HINT = 2,
	START = 4,
	WIN = 5,
	UPDATE_DATA = 6,
	UPDATE_CARD = 7,

	SELECT_BATTLECMD = 10,
	SELECT_IDLECMD = 11,
	SELECT_EFFECTYN = 12,
	SELECT_YESNO = 13,
	SELECT_OPTION = 14,
	SELECT_CARD = 15,
	SELECT_CHAIN = 16,
	SELECT_PLACE = 18,
	SELECT_POSITION = 19,
	SELECT_TRIBUTE = 20,
	SELECT_COUNTER = 22,
	SELECT_SUM = 23,
	SORT_CARD = 25,
	SELECT_UNSELECT_CARD = 26,
	SORT_CHAIN = 21,

	CONFIRM_CARDS = 31,
	SHUFFLE_DECK = 32,
	SHUFFLE_HAND = 33,
	SHUFFLE_SET_CARD = 36,
	SHUFFLE_EXTRA = 39,
	NEW_TURN = 40,
	NEW_PHASE = 41,

	MOVE = 50,
	POS_CHANGE = 53,
	SET = 54,

	SUMMONING = 60,
	SUMMONED = 61,
	SPSUMMONING = 62,
	SPSUMMONED = 63,
	FLIPSUMMONING = 64,
	FLIPSUMMONED = 65,

	CHAINING = 70,
	CHAINED = 71,
	CHAIN_SOLVING = 72,
	CHAIN_SOLVED = 73,
	CHAIN_END = 74,
	CHAIN_NEGATED = 75,
	CHAIN_DISABLED = 76,

	CONFIRM_DECKTOP = 30,
	SWAP = 55,
	RANDOM_SELECTED = 81,
	BECOME_TARGET = 83,
	EQUIP = 93,
	CARD_TARGET = 96,
	CANCEL_TARGET = 97,
	PAY_LPCOST = 100,
	ADD_COUNTER = 101,
	REMOVE_COUNTER = 102,
	DAMAGE_STEP_START = 113,
	DAMAGE_STEP_END = 114,
	MISSED_EFFECT = 120,
	TOSS_COIN = 130,
	TOSS_DICE = 131,
	CARD_HINT = 160,
	PLAYER_HINT = 165,
	ANNOUNCE_RACE = 140,
	ANNOUNCE_ATTRIB = 141,
	ANNOUNCE_CARD = 142,
	ANNOUNCE_NUMBER = 143,
	REMOVE_CARDS = 190,

	DRAW = 90,
	DAMAGE = 91,
	RECOVER = 92,
	LPUPDATE = 94,

	ATTACK = 110,
	BATTLE = 111,
	ATTACK_DISABLED = 112,

	// --- synthesised by us; no opcode corresponds -------------------------------------
	/// Opcode recognised by ocgcore but not decoded by this batch. Carries "opcode" and
	/// "size". Invariant V13: a warning, never a crash and never an aborted duel.
	UNHANDLED = 1100,
	/// The payload ended mid-field. Carries "opcode" and "size". Also V13: corrupt or
	/// truncated bytes must not take the duel down.
	MALFORMED = 1101,
};

/// Starts a new event Dictionary with its type tag already set.
inline godot::Dictionary make_event(EV type) {
	godot::Dictionary event;
	event["t"] = static_cast<int32_t>(type);
	return event;
}

/// The one and only encoding of a loc_info. Every "from", "to" and "at" goes through here.
///
/// LOCATION_OVERLAY (0x80) in "loc" means the card is an xyz material: "seq" is then the
/// sequence of the monster it sits under and "pos" is its index in that stack. ocgcore
/// packs it that way in card::get_info_location(); unpacking it is L3's job.
inline godot::Dictionary loc_dict(const core_utils::loc_info &info) {
	godot::Dictionary location;
	location["con"] = static_cast<int32_t>(info.controler);
	location["loc"] = static_cast<int32_t>(info.location);
	location["seq"] = static_cast<int32_t>(info.sequence);
	location["pos"] = static_cast<int32_t>(info.position);
	return location;
}

/// Builds a loc_info from the loose fields that some messages carry instead of a packed one.
///
/// Several opcodes (MSG_SELECT_IDLECMD, MSG_SELECT_TRIBUTE, MSG_CONFIRM_CARDS, ...) send a
/// controller / location / sequence triple with no position byte. Routing them through this
/// keeps every card reference in the event stream one single shape; "pos" is 0 there because
/// the engine never sent one, not because the card is in position 0.
inline core_utils::loc_info make_loc(uint8_t controler, uint8_t location, uint32_t sequence, uint32_t position = 0) {
	core_utils::loc_info info;
	info.controler = controler;
	info.location = location;
	info.sequence = sequence;
	info.position = position;
	return info;
}

} // namespace kaiba

#endif // KAIBA_DUEL_EVENT_H
