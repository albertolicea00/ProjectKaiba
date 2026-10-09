#include "msg_parser.h"

#include <cstring>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <ocgapi_constants.h>

using godot::Array;
using godot::Dictionary;
using godot::String;

namespace kaiba {

// The EV enum doubles as a replay serialisation format (V9), so every value that mirrors an
// opcode must keep mirroring it. If a core bump renumbers anything, fail the build here
// rather than silently corrupting the replay library.
static_assert(static_cast<int32_t>(EV::RETRY) == MSG_RETRY, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::HINT) == MSG_HINT, "EV/MSG drift");
// The two synthesised outcomes must stay clear of every real opcode.
static_assert(static_cast<int32_t>(EV::UNHANDLED) > 255, "UNHANDLED collides with an opcode");
static_assert(static_cast<int32_t>(EV::MALFORMED) > 255, "MALFORMED collides with an opcode");
static_assert(static_cast<int32_t>(EV::WIN) == MSG_WIN, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::UPDATE_DATA) == MSG_UPDATE_DATA, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::UPDATE_CARD) == MSG_UPDATE_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_BATTLECMD) == MSG_SELECT_BATTLECMD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_IDLECMD) == MSG_SELECT_IDLECMD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_EFFECTYN) == MSG_SELECT_EFFECTYN, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_YESNO) == MSG_SELECT_YESNO, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_OPTION) == MSG_SELECT_OPTION, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_CARD) == MSG_SELECT_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_CHAIN) == MSG_SELECT_CHAIN, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_PLACE) == MSG_SELECT_PLACE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_POSITION) == MSG_SELECT_POSITION, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_TRIBUTE) == MSG_SELECT_TRIBUTE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_SUM) == MSG_SELECT_SUM, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_DISFIELD) == MSG_SELECT_DISFIELD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SORT_CARD) == MSG_SORT_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CONFIRM_CARDS) == MSG_CONFIRM_CARDS, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SHUFFLE_DECK) == MSG_SHUFFLE_DECK, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SHUFFLE_HAND) == MSG_SHUFFLE_HAND, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SHUFFLE_SET_CARD) == MSG_SHUFFLE_SET_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SHUFFLE_EXTRA) == MSG_SHUFFLE_EXTRA, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::NEW_TURN) == MSG_NEW_TURN, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::NEW_PHASE) == MSG_NEW_PHASE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::MOVE) == MSG_MOVE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::POS_CHANGE) == MSG_POS_CHANGE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SET) == MSG_SET, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SUMMONING) == MSG_SUMMONING, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SUMMONED) == MSG_SUMMONED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SPSUMMONING) == MSG_SPSUMMONING, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SPSUMMONED) == MSG_SPSUMMONED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::FLIPSUMMONING) == MSG_FLIPSUMMONING, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::FLIPSUMMONED) == MSG_FLIPSUMMONED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAINING) == MSG_CHAINING, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAINED) == MSG_CHAINED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAIN_SOLVING) == MSG_CHAIN_SOLVING, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAIN_SOLVED) == MSG_CHAIN_SOLVED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAIN_END) == MSG_CHAIN_END, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::DRAW) == MSG_DRAW, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::DAMAGE) == MSG_DAMAGE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::RECOVER) == MSG_RECOVER, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::LPUPDATE) == MSG_LPUPDATE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ATTACK) == MSG_ATTACK, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::BATTLE) == MSG_BATTLE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ATTACK_DISABLED) == MSG_ATTACK_DISABLED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::START) == MSG_START, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAIN_NEGATED) == MSG_CHAIN_NEGATED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CHAIN_DISABLED) == MSG_CHAIN_DISABLED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CONFIRM_DECKTOP) == MSG_CONFIRM_DECKTOP, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SWAP) == MSG_SWAP, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::RANDOM_SELECTED) == MSG_RANDOM_SELECTED, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::BECOME_TARGET) == MSG_BECOME_TARGET, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::EQUIP) == MSG_EQUIP, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CARD_TARGET) == MSG_CARD_TARGET, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CANCEL_TARGET) == MSG_CANCEL_TARGET, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::PAY_LPCOST) == MSG_PAY_LPCOST, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ADD_COUNTER) == MSG_ADD_COUNTER, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::REMOVE_COUNTER) == MSG_REMOVE_COUNTER, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::DAMAGE_STEP_START) == MSG_DAMAGE_STEP_START, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::DAMAGE_STEP_END) == MSG_DAMAGE_STEP_END, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::MISSED_EFFECT) == MSG_MISSED_EFFECT, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SORT_CHAIN) == MSG_SORT_CHAIN, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_COUNTER) == MSG_SELECT_COUNTER, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SORT_CARD) == MSG_SORT_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::SELECT_UNSELECT_CARD) == MSG_SELECT_UNSELECT_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ANNOUNCE_RACE) == MSG_ANNOUNCE_RACE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ANNOUNCE_ATTRIB) == MSG_ANNOUNCE_ATTRIB, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ANNOUNCE_CARD) == MSG_ANNOUNCE_CARD, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::ANNOUNCE_NUMBER) == MSG_ANNOUNCE_NUMBER, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::TOSS_COIN) == MSG_TOSS_COIN, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::TOSS_DICE) == MSG_TOSS_DICE, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::CARD_HINT) == MSG_CARD_HINT, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::PLAYER_HINT) == MSG_PLAYER_HINT, "EV/MSG drift");
static_assert(static_cast<int32_t>(EV::REMOVE_CARDS) == MSG_REMOVE_CARDS, "EV/MSG drift");

namespace {

/// Bounds-checked read cursor over one message payload.
///
/// Every read goes through here. An attempt to read past the end flips `overrun_` and
/// returns a zeroed value instead of reading out of bounds, so a truncated or corrupt
/// message degrades into EV::MALFORMED rather than a crash (invariant V13).
class Cursor {
public:
	Cursor(const uint8_t* data, std::size_t size)
		: p_(data), end_(data + size) {}

	bool ok() const { return !overrun_; }

	std::size_t remaining() const {
		return overrun_ ? 0u : static_cast<std::size_t>(end_ - p_);
	}

	template<typename T>
	T read() {
		if (remaining() < sizeof(T)) {
			overrun_ = true;
			return T{};
		}
		T value{};
		std::memcpy(&value, p_, sizeof(T));
		p_ += sizeof(T);
		return value;
	}

	/// Reads a packed loc_info: controller, location, sequence, position.
	/// This is what ocgcore's card::get_info_location() produces.
	core_utils::loc_info read_loc() {
		core_utils::loc_info info;
		info.controler = read<uint8_t>();
		info.location = read<uint8_t>();
		info.sequence = read<uint32_t>();
		info.position = read<uint32_t>();
		return info;
	}

	/// Reads a loose controller / location / sequence triple with a 32-bit sequence.
	/// Several messages send this instead of a packed loc_info; there is no position byte,
	/// so "pos" ends up 0 because none was sent, not because the card is in position 0.
	core_utils::loc_info read_loc_triple32() {
		const uint8_t controler = read<uint8_t>();
		const uint8_t location = read<uint8_t>();
		const uint32_t sequence = read<uint32_t>();
		return make_loc(controler, location, sequence);
	}

	/// Same, but with an 8-bit sequence.
	///
	/// This asymmetry is not a mistake in this file. ocgcore writes the sequence as uint8_t
	/// for repositionable_cards and attackable_cards (playerop.cpp) and as uint32_t
	/// everywhere else in the very same message. Reading the wrong width desynchronises the
	/// rest of the payload.
	core_utils::loc_info read_loc_triple8() {
		const uint8_t controler = read<uint8_t>();
		const uint8_t location = read<uint8_t>();
		const uint8_t sequence = read<uint8_t>();
		return make_loc(controler, location, sequence);
	}

private:
	const uint8_t* p_;
	const uint8_t* end_;
	bool overrun_ = false;
};

/// {"card": code, "at": loc} - the shape every card reference in a list takes.
Dictionary card_ref(uint32_t code, const core_utils::loc_info& at) {
	Dictionary entry;
	entry["card"] = static_cast<int32_t>(code);
	entry["at"] = loc_dict(at);
	return entry;
}

/// A list of {code, loose triple with a 32-bit sequence}.
Array read_card_list32(Cursor& cursor) {
	Array list;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		list.push_back(card_ref(code, cursor.read_loc_triple32()));
	}
	return list;
}

/// A list of activatable effects: code, triple, description, client mode.
Array read_activatable_list(Cursor& cursor) {
	Array list;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		Dictionary entry = card_ref(code, cursor.read_loc_triple32());
		entry["desc"] = static_cast<int64_t>(cursor.read<uint64_t>());
		entry["mode"] = static_cast<int32_t>(cursor.read<uint8_t>());
		list.push_back(entry);
	}
	return list;
}

// ---------------------------------------------------------------------------------------
// One function per opcode. Layouts are taken from the write sites in vendor/ocgcore, not
// from EDOPro's reader: the engine is the authority (AGENTS.md section 9).
// ---------------------------------------------------------------------------------------

Dictionary parse_hint(Cursor& cursor) {
	Dictionary event = make_event(EV::HINT);
	event["hint_type"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["data"] = static_cast<int64_t>(cursor.read<uint64_t>());
	return event;
}

Dictionary parse_win(Cursor& cursor) {
	Dictionary event = make_event(EV::WIN);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["reason"] = static_cast<int32_t>(cursor.read<uint8_t>());
	return event;
}

Dictionary parse_new_turn(Cursor& cursor) {
	Dictionary event = make_event(EV::NEW_TURN);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	return event;
}

Dictionary parse_new_phase(Cursor& cursor) {
	Dictionary event = make_event(EV::NEW_PHASE);
	event["phase"] = static_cast<int32_t>(cursor.read<uint16_t>());
	return event;
}

Dictionary parse_draw(Cursor& cursor) {
	Dictionary event = make_event(EV::DRAW);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());

	Array cards;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		Dictionary drawn;
		// 0 means the card was not revealed to this viewer; the host blanks it (V7).
		drawn["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
		drawn["pos"] = static_cast<int32_t>(cursor.read<uint32_t>());
		cards.push_back(drawn);
	}
	event["cards"] = cards;
	event["count"] = static_cast<int32_t>(count);
	return event;
}

Dictionary parse_move(Cursor& cursor) {
	Dictionary event = make_event(EV::MOVE);
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["from"] = loc_dict(cursor.read_loc());
	event["to"] = loc_dict(cursor.read_loc());
	event["reason"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

Dictionary parse_pos_change(Cursor& cursor) {
	Dictionary event = make_event(EV::POS_CHANGE);
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	// Not a loc_info: ocgcore writes the sequence as a single byte here
	// (operations.cpp MSG_POS_CHANGE), then the previous and current positions.
	const uint8_t controler = cursor.read<uint8_t>();
	const uint8_t location = cursor.read<uint8_t>();
	const uint8_t sequence = cursor.read<uint8_t>();
	const uint8_t previous_position = cursor.read<uint8_t>();
	const uint8_t current_position = cursor.read<uint8_t>();
	event["at"] = loc_dict(make_loc(controler, location, sequence, current_position));
	event["prev_pos"] = static_cast<int32_t>(previous_position);
	event["pos"] = static_cast<int32_t>(current_position);
	return event;
}

/// MSG_SET, MSG_SUMMONING, MSG_FLIPSUMMONING: code plus one packed loc_info.
Dictionary parse_card_at(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["at"] = loc_dict(cursor.read_loc());
	return event;
}

Dictionary parse_spsummoning(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	// 0 here means the summoning card is not revealed to this viewer.
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["at"] = loc_dict(cursor.read_loc());
	return event;
}

/// MSG_SUMMONED, MSG_SPSUMMONED, MSG_FLIPSUMMONED, MSG_CHAIN_END, MSG_ATTACK_DISABLED.
/// ocgcore emits these with no payload at all; they are pure sequencing markers.
Dictionary parse_empty(EV type) {
	return make_event(type);
}

Dictionary parse_damage(Cursor& cursor) {
	Dictionary event = make_event(EV::DAMAGE);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["amount"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

Dictionary parse_recover(Cursor& cursor) {
	Dictionary event = make_event(EV::RECOVER);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["amount"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

Dictionary parse_lpupdate(Cursor& cursor) {
	Dictionary event = make_event(EV::LPUPDATE);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["lp"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

Dictionary parse_attack(Cursor& cursor) {
	Dictionary event = make_event(EV::ATTACK);
	event["from"] = loc_dict(cursor.read_loc());
	// A zeroed loc_info means a direct attack: there is no defender.
	const core_utils::loc_info target = cursor.read_loc();
	const bool is_direct = (target.controler == 0 && target.location == 0
			&& target.sequence == 0 && target.position == 0);
	event["direct"] = is_direct;
	if (!is_direct) {
		event["to"] = loc_dict(target);
	}
	return event;
}

Dictionary parse_battle(Cursor& cursor) {
	Dictionary event = make_event(EV::BATTLE);
	event["from"] = loc_dict(cursor.read_loc());
	event["from_atk"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["from_def"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["from_destroyed"] = cursor.read<uint8_t>() != 0;
	const core_utils::loc_info target = cursor.read_loc();
	const bool is_direct = (target.controler == 0 && target.location == 0
			&& target.sequence == 0 && target.position == 0);
	event["direct"] = is_direct;
	if (!is_direct) {
		event["to"] = loc_dict(target);
		event["to_atk"] = static_cast<int32_t>(cursor.read<uint32_t>());
		event["to_def"] = static_cast<int32_t>(cursor.read<uint32_t>());
		event["to_destroyed"] = cursor.read<uint8_t>() != 0;
	}
	return event;
}

Dictionary parse_chaining(Cursor& cursor) {
	Dictionary event = make_event(EV::CHAINING);
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["at"] = loc_dict(cursor.read_loc());
	event["trigger"] = loc_dict(cursor.read_loc_triple32());
	event["desc"] = static_cast<int64_t>(cursor.read<uint64_t>());
	event["chain_size"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

/// MSG_CHAINED, MSG_CHAIN_SOLVING, MSG_CHAIN_SOLVED: just the chain link index.
Dictionary parse_chain_index(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["chain_index"] = static_cast<int32_t>(cursor.read<uint8_t>());
	return event;
}

Dictionary parse_shuffle_deck(Cursor& cursor) {
	Dictionary event = make_event(EV::SHUFFLE_DECK);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	return event;
}

/// MSG_SHUFFLE_HAND and MSG_SHUFFLE_EXTRA share one layout (field.cpp:970): the owner, a
/// count, then the new ordering as bare card codes. Codes are 0 for a hidden hand.
Dictionary parse_shuffle_codes(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	Array codes;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		codes.push_back(static_cast<int32_t>(cursor.read<uint32_t>()));
	}
	event["codes"] = codes;
	return event;
}

Dictionary parse_confirm_cards(Cursor& cursor) {
	Dictionary event = make_event(EV::CONFIRM_CARDS);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["cards"] = read_card_list32(cursor);
	return event;
}

Dictionary parse_select_idlecmd(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_IDLECMD);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["summon"] = read_card_list32(cursor);
	event["spsummon"] = read_card_list32(cursor);

	// Repositionable cards carry an 8-bit sequence while every other list in this same
	// message carries a 32-bit one (playerop.cpp). Not a typo.
	Array repos;
	const uint32_t repos_count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < repos_count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		repos.push_back(card_ref(code, cursor.read_loc_triple8()));
	}
	event["repos"] = repos;

	event["mset"] = read_card_list32(cursor);
	event["sset"] = read_card_list32(cursor);
	event["activate"] = read_activatable_list(cursor);
	event["to_bp"] = cursor.read<uint8_t>() != 0;
	event["to_ep"] = cursor.read<uint8_t>() != 0;
	// Trailing "can shuffle hand" byte. Read only if the payload actually carries it so a
	// core that stops sending it degrades to false instead of EV::MALFORMED.
	event["can_shuffle"] = (cursor.remaining() >= sizeof(uint8_t)) && (cursor.read<uint8_t>() != 0);
	return event;
}

Dictionary parse_select_battlecmd(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_BATTLECMD);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["activate"] = read_activatable_list(cursor);

	// Attackable cards also use the 8-bit sequence, plus a direct-attack flag.
	Array attack;
	const uint32_t attack_count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < attack_count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		Dictionary entry = card_ref(code, cursor.read_loc_triple8());
		entry["direct"] = cursor.read<uint8_t>() != 0;
		attack.push_back(entry);
	}
	event["attack"] = attack;

	event["to_m2"] = cursor.read<uint8_t>() != 0;
	event["to_ep"] = cursor.read<uint8_t>() != 0;
	return event;
}

Dictionary parse_select_effectyn(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_EFFECTYN);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["at"] = loc_dict(cursor.read_loc());
	event["desc"] = static_cast<int64_t>(cursor.read<uint64_t>());
	return event;
}

Dictionary parse_select_yesno(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_YESNO);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["desc"] = static_cast<int64_t>(cursor.read<uint64_t>());
	return event;
}

Dictionary parse_select_option(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_OPTION);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	Array options;
	// Note the width: the option count is a single byte here, not a uint32.
	const uint8_t count = cursor.read<uint8_t>();
	for (uint8_t i = 0; i < count && cursor.ok(); ++i) {
		options.push_back(static_cast<int64_t>(cursor.read<uint64_t>()));
	}
	event["options"] = options;
	return event;
}

/// MSG_SELECT_CARD and MSG_SELECT_TRIBUTE share the same five-field prefix but NOT the same
/// card entry, which is the kind of difference that costs an afternoon.
///
///   SELECT_CARD    code + packed loc_info          (playerop.cpp:314)
///   SELECT_TRIBUTE code + loose triple + release   (playerop.cpp:673)
///
/// The tribute entry has no position field and its sequence is 32-bit, so reading it as a
/// packed loc_info overruns by four bytes per card and the message decodes as MALFORMED.
Dictionary parse_select_card(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["cancelable"] = cursor.read<uint8_t>() != 0;
	event["min"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["max"] = static_cast<int32_t>(cursor.read<uint32_t>());

	const bool is_tribute = (type == EV::SELECT_TRIBUTE);

	Array cards;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		Dictionary entry = card_ref(code, is_tribute ? cursor.read_loc_triple32() : cursor.read_loc());
		if (is_tribute) {
			// How many tributes this card is worth. A card that counts double still occupies
			// one index in the answer, so L3 must not sum indices to reach the required count.
			entry["release_param"] = static_cast<int32_t>(cursor.read<uint8_t>());
		}
		cards.push_back(entry);
	}
	event["cards"] = cards;
	return event;
}

/// MSG_SELECT_SUM: pick cards whose summed parameter reaches `acc` (playerop.cpp:796).
///
/// Two lists arrive. `must` is forced in by the engine and is NOT addressable by the answer;
/// indices in the response address `cards` alone. Concatenating the two for display and then
/// answering with those indices is an off-by-N that the engine reports only as MSG_RETRY.
///
/// Reached in practice through ritual summons: proc_ritual.lua is the only place in the whole
/// ProjectIgnis collection that calls Group.SelectWithSumEqual.
Dictionary parse_select_sum(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_SUM);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	// ocgcore writes 0 when a max was given and 1 when it was not; with 1 the engine accepts
	// any number of cards as long as the sum lands exactly on `acc`.
	event["exact_count"] = cursor.read<uint8_t>() == 0;
	event["acc"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["min"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["max"] = static_cast<int32_t>(cursor.read<uint32_t>());

	// Both lists use a packed loc_info here, unlike SELECT_TRIBUTE just above.
	for (const char* key : { "must", "cards" }) {
		Array list;
		const uint32_t count = cursor.read<uint32_t>();
		for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
			const uint32_t code = cursor.read<uint32_t>();
			Dictionary entry = card_ref(code, cursor.read_loc());
			entry["sum_param"] = static_cast<int32_t>(cursor.read<uint32_t>());
			list.push_back(entry);
		}
		event[key] = list;
	}
	return event;
}

Dictionary parse_select_chain(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_CHAIN);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["spe_count"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["forced"] = cursor.read<uint8_t>() != 0;
	event["hint_timing"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["other_hint_timing"] = static_cast<int32_t>(cursor.read<uint32_t>());

	Array chains;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		Dictionary entry = card_ref(code, cursor.read_loc());
		entry["desc"] = static_cast<int64_t>(cursor.read<uint64_t>());
		entry["mode"] = static_cast<int32_t>(cursor.read<uint8_t>());
		chains.push_back(entry);
	}
	event["chains"] = chains;
	return event;
}

Dictionary parse_select_place(Cursor& cursor, EV ev = EV::SELECT_PLACE) {
	Dictionary event = make_event(ev);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["count"] = static_cast<int32_t>(cursor.read<uint8_t>());
	// Bitmask of zones that are NOT selectable. L3 inverts it against the field layout.
	event["flag"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

Dictionary parse_select_position(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_POSITION);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["positions"] = static_cast<int32_t>(cursor.read<uint8_t>());
	return event;
}

Dictionary parse_shuffle_set_card(Cursor& cursor) {
	Dictionary event = make_event(EV::SHUFFLE_SET_CARD);
	event["loc"] = static_cast<int32_t>(cursor.read<uint8_t>());

	const uint8_t count = cursor.read<uint8_t>();
	Array from;
	for (uint8_t i = 0; i < count && cursor.ok(); ++i) {
		from.push_back(loc_dict(cursor.read_loc()));
	}
	Array to;
	for (uint8_t i = 0; i < count && cursor.ok(); ++i) {
		to.push_back(loc_dict(cursor.read_loc()));
	}
	event["from"] = from;
	event["to"] = to;
	return event;
}


// ---------------------------------------------------------------------------------------
// Batch 2. Same rule as batch 1: every layout below is read off a write site in
// vendor/ocgcore. Opcodes whose layout could not be pinned down with certainty are left out
// entirely and fall through to EV::UNHANDLED rather than being guessed at.
// ---------------------------------------------------------------------------------------

/// A bare list of loc_info, length-prefixed with a uint32.
Array read_loc_list32(Cursor& cursor) {
	Array list;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		list.push_back(loc_dict(cursor.read_loc()));
	}
	return list;
}

/// MSG_BECOME_TARGET, MSG_RANDOM_SELECTED (minus its leading player), MSG_REMOVE_CARDS.
Dictionary parse_loc_list(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["cards"] = read_loc_list32(cursor);
	return event;
}

Dictionary parse_random_selected(Cursor& cursor) {
	Dictionary event = make_event(EV::RANDOM_SELECTED);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["cards"] = read_loc_list32(cursor);
	return event;
}

/// MSG_EQUIP, MSG_CARD_TARGET, MSG_CANCEL_TARGET: two packed loc_infos, source then target.
Dictionary parse_loc_pair(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["from"] = loc_dict(cursor.read_loc());
	event["to"] = loc_dict(cursor.read_loc());
	return event;
}

Dictionary parse_swap(Cursor& cursor) {
	Dictionary event = make_event(EV::SWAP);
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["from"] = loc_dict(cursor.read_loc());
	event["card2"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["to"] = loc_dict(cursor.read_loc());
	return event;
}

Dictionary parse_pay_lpcost(Cursor& cursor) {
	Dictionary event = make_event(EV::PAY_LPCOST);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["amount"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

/// MSG_ADD_COUNTER and MSG_REMOVE_COUNTER. Note the widths: the counter type and the count
/// are uint16, and the sequence is a single byte rather than part of a loc_info.
Dictionary parse_counter(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["counter_type"] = static_cast<int32_t>(cursor.read<uint16_t>());
	const uint8_t controler = cursor.read<uint8_t>();
	const uint8_t location = cursor.read<uint8_t>();
	const uint8_t sequence = cursor.read<uint8_t>();
	event["at"] = loc_dict(make_loc(controler, location, sequence));
	event["count"] = static_cast<int32_t>(cursor.read<uint16_t>());
	return event;
}

Dictionary parse_missed_effect(Cursor& cursor) {
	Dictionary event = make_event(EV::MISSED_EFFECT);
	event["at"] = loc_dict(cursor.read_loc());
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

/// MSG_TOSS_COIN and MSG_TOSS_DICE: owner, count, then one byte per result.
Dictionary parse_toss(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	Array results;
	const uint8_t count = cursor.read<uint8_t>();
	for (uint8_t i = 0; i < count && cursor.ok(); ++i) {
		results.push_back(static_cast<int32_t>(cursor.read<uint8_t>()));
	}
	event["results"] = results;
	return event;
}

Dictionary parse_card_hint(Cursor& cursor) {
	Dictionary event = make_event(EV::CARD_HINT);
	event["at"] = loc_dict(cursor.read_loc());
	event["hint_type"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["data"] = static_cast<int64_t>(cursor.read<uint64_t>());
	return event;
}

Dictionary parse_player_hint(Cursor& cursor) {
	Dictionary event = make_event(EV::PLAYER_HINT);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["hint_type"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["data"] = static_cast<int64_t>(cursor.read<uint64_t>());
	return event;
}

/// MSG_FIELD_DISABLED: u32 bitmask of disabled zones.
Dictionary parse_field_disabled(Cursor& cursor) {
	Dictionary event = make_event(EV::FIELD_DISABLED);
	event["flag"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

/// MSG_DECK_TOP: u8 player, u32 index from top, u32 code, u32 position.
Dictionary parse_deck_top(Cursor& cursor) {
	Dictionary event = make_event(EV::DECK_TOP);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["index"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["position"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

/// MSG_CONFIRM_EXTRATOP: u8 player, u32 count, then per card: u32 code, u8 con, u8 loc, u32 seq.
Dictionary parse_confirm_extratop(Cursor& cursor) {
	Dictionary event = make_event(EV::CONFIRM_EXTRATOP);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	Array cards;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		Dictionary card;
		card["code"] = static_cast<int32_t>(cursor.read<uint32_t>());
		card["con"] = static_cast<int32_t>(cursor.read<uint8_t>());
		card["loc"] = static_cast<int32_t>(cursor.read<uint8_t>());
		card["seq"] = static_cast<int32_t>(cursor.read<uint32_t>());
		cards.push_back(card);
	}
	event["cards"] = cards;
	return event;
}

/// MSG_SWAP_GRAVE_DECK: u8 player, then a bitfield marking extra-deck monsters.
/// Complex enough that we just emit the player — the state rebuild happens via full refresh.
Dictionary parse_swap_grave_deck(Cursor& cursor) {
	Dictionary event = make_event(EV::SWAP_GRAVE_DECK);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	// Skip remaining bitfield — consume it so the cursor stays ok().
	while (cursor.remaining() > 0 && cursor.ok()) cursor.read<uint8_t>();
	return event;
}

/// MSG_ROCK_PAPER_SCISSORS: u8 player — requests RPS input.
Dictionary parse_rps(Cursor& cursor) {
	Dictionary event = make_event(EV::ROCK_PAPER_SCISSORS);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	return event;
}

/// MSG_HAND_RES: u8 packed (hand0 in bits 0-1, hand1 in bits 2-3).
Dictionary parse_hand_res(Cursor& cursor) {
	Dictionary event = make_event(EV::HAND_RES);
	uint8_t packed = cursor.read<uint8_t>();
	event["hand0"] = static_cast<int32_t>(packed & 0x03);
	event["hand1"] = static_cast<int32_t>((packed >> 2) & 0x03);
	return event;
}

Dictionary parse_confirm_decktop(Cursor& cursor) {
	Dictionary event = make_event(EV::CONFIRM_DECKTOP);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["cards"] = read_card_list32(cursor);
	return event;
}

/// MSG_SORT_CARD and MSG_SORT_CHAIN. Per-card layout:
///   u32 code, u8 controller, u32 location, u32 sequence.
/// Note: location is u32 here, not u8 like loc_info.
Dictionary parse_sort(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	Array cards;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		Dictionary entry;
		entry["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
		const uint8_t controler = cursor.read<uint8_t>();
		const uint32_t location = cursor.read<uint32_t>();
		const uint32_t sequence = cursor.read<uint32_t>();
		entry["at"] = loc_dict(make_loc(controler, static_cast<uint8_t>(location), sequence));
		cards.push_back(entry);
	}
	event["cards"] = cards;
	return event;
}

/// MSG_SELECT_COUNTER. Per-card: u32 code, u8 controller, u8 location, u8 sequence, u16 count.
Dictionary parse_select_counter(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_COUNTER);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["counter_type"] = static_cast<int32_t>(cursor.read<uint16_t>());
	event["count"] = static_cast<int32_t>(cursor.read<uint16_t>());
	Array cards;
	const uint32_t count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < count && cursor.ok(); ++i) {
		Dictionary entry;
		entry["card"] = static_cast<int32_t>(cursor.read<uint32_t>());
		const uint8_t controler = cursor.read<uint8_t>();
		const uint8_t location = cursor.read<uint8_t>();
		const uint8_t sequence = cursor.read<uint8_t>();
		entry["at"] = loc_dict(make_loc(controler, location, sequence));
		entry["counter_count"] = static_cast<int32_t>(cursor.read<uint16_t>());
		cards.push_back(entry);
	}
	event["cards"] = cards;
	return event;
}

/// MSG_SELECT_UNSELECT_CARD. Two card lists: selectable and unselectable.
/// Per-card: u32 code, then a loc_info (u8 ctrl, u8 loc, u32 seq, u32 pos).
Dictionary parse_select_unselect_card(Cursor& cursor) {
	Dictionary event = make_event(EV::SELECT_UNSELECT_CARD);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["finishable"] = cursor.read<uint8_t>() != 0;
	event["cancelable"] = cursor.read<uint8_t>() != 0;
	event["min"] = static_cast<int32_t>(cursor.read<uint32_t>());
	event["max"] = static_cast<int32_t>(cursor.read<uint32_t>());

	Array select_cards;
	const uint32_t sel_count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < sel_count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		select_cards.push_back(card_ref(code, cursor.read_loc()));
	}
	event["select_cards"] = select_cards;

	Array unselect_cards;
	const uint32_t unsel_count = cursor.read<uint32_t>();
	for (uint32_t i = 0; i < unsel_count && cursor.ok(); ++i) {
		const uint32_t code = cursor.read<uint32_t>();
		unselect_cards.push_back(card_ref(code, cursor.read_loc()));
	}
	event["unselect_cards"] = unselect_cards;
	return event;
}

/// MSG_ANNOUNCE_RACE: player, count, available (u64 bitmask).
Dictionary parse_announce_race(Cursor& cursor) {
	Dictionary event = make_event(EV::ANNOUNCE_RACE);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["count"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["available"] = static_cast<int64_t>(cursor.read<uint64_t>());
	return event;
}

/// MSG_ANNOUNCE_ATTRIB: player, count, available (u32 bitmask).
Dictionary parse_announce_attrib(Cursor& cursor) {
	Dictionary event = make_event(EV::ANNOUNCE_ATTRIB);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["count"] = static_cast<int32_t>(cursor.read<uint8_t>());
	event["available"] = static_cast<int32_t>(cursor.read<uint32_t>());
	return event;
}

/// MSG_ANNOUNCE_CARD and MSG_ANNOUNCE_NUMBER: player, count, then u64 options.
Dictionary parse_announce_options(Cursor& cursor, EV type) {
	Dictionary event = make_event(type);
	event["player"] = static_cast<int32_t>(cursor.read<uint8_t>());
	Array options;
	const uint8_t count = cursor.read<uint8_t>();
	for (uint8_t i = 0; i < count && cursor.ok(); ++i) {
		options.push_back(static_cast<int64_t>(cursor.read<uint64_t>()));
	}
	event["options"] = options;
	return event;
}

} // namespace

godot::Dictionary MsgParser::parse(const core_utils::Packet& packet) {
	Cursor cursor(packet.data(), packet.buff_size());
	const uint8_t opcode = packet.message;

	Dictionary event;
	switch (opcode) {
		// Carries no payload. Surfaced explicitly because ocgcore does not re-send the
		// selection it rejected; L3 must answer the request it is already holding.
		case MSG_RETRY:             event = parse_empty(EV::RETRY); break;
		case MSG_HINT:              event = parse_hint(cursor); break;
		case MSG_WIN:               event = parse_win(cursor); break;
		case MSG_NEW_TURN:          event = parse_new_turn(cursor); break;
		case MSG_NEW_PHASE:         event = parse_new_phase(cursor); break;
		case MSG_DRAW:              event = parse_draw(cursor); break;
		case MSG_MOVE:              event = parse_move(cursor); break;
		case MSG_POS_CHANGE:        event = parse_pos_change(cursor); break;

		case MSG_SET:               event = parse_card_at(cursor, EV::SET); break;
		case MSG_SUMMONING:         event = parse_card_at(cursor, EV::SUMMONING); break;
		case MSG_FLIPSUMMONING:     event = parse_card_at(cursor, EV::FLIPSUMMONING); break;
		case MSG_SPSUMMONING:       event = parse_spsummoning(cursor, EV::SPSUMMONING); break;

		// Payload-free sequencing markers.
		case MSG_SUMMONED:          event = parse_empty(EV::SUMMONED); break;
		case MSG_SPSUMMONED:        event = parse_empty(EV::SPSUMMONED); break;
		case MSG_FLIPSUMMONED:      event = parse_empty(EV::FLIPSUMMONED); break;
		case MSG_CHAIN_END:         event = parse_empty(EV::CHAIN_END); break;
		case MSG_ATTACK_DISABLED:   event = parse_empty(EV::ATTACK_DISABLED); break;

		case MSG_DAMAGE:            event = parse_damage(cursor); break;
		case MSG_RECOVER:           event = parse_recover(cursor); break;
		case MSG_LPUPDATE:          event = parse_lpupdate(cursor); break;

		case MSG_ATTACK:            event = parse_attack(cursor); break;
		case MSG_BATTLE:            event = parse_battle(cursor); break;

		case MSG_CHAINING:          event = parse_chaining(cursor); break;
		case MSG_CHAINED:           event = parse_chain_index(cursor, EV::CHAINED); break;
		case MSG_CHAIN_SOLVING:     event = parse_chain_index(cursor, EV::CHAIN_SOLVING); break;
		case MSG_CHAIN_SOLVED:      event = parse_chain_index(cursor, EV::CHAIN_SOLVED); break;

		case MSG_SHUFFLE_DECK:      event = parse_shuffle_deck(cursor); break;
		case MSG_SHUFFLE_HAND:      event = parse_shuffle_codes(cursor, EV::SHUFFLE_HAND); break;
		case MSG_SHUFFLE_EXTRA:     event = parse_shuffle_codes(cursor, EV::SHUFFLE_EXTRA); break;
		case MSG_SHUFFLE_SET_CARD:  event = parse_shuffle_set_card(cursor); break;
		case MSG_CONFIRM_CARDS:     event = parse_confirm_cards(cursor); break;

		case MSG_SELECT_IDLECMD:    event = parse_select_idlecmd(cursor); break;
		case MSG_SELECT_BATTLECMD:  event = parse_select_battlecmd(cursor); break;
		case MSG_SELECT_EFFECTYN:   event = parse_select_effectyn(cursor); break;
		case MSG_SELECT_YESNO:      event = parse_select_yesno(cursor); break;
		case MSG_SELECT_OPTION:     event = parse_select_option(cursor); break;
		case MSG_SELECT_CARD:       event = parse_select_card(cursor, EV::SELECT_CARD); break;
		case MSG_SELECT_TRIBUTE:    event = parse_select_card(cursor, EV::SELECT_TRIBUTE); break;
		case MSG_SELECT_SUM:        event = parse_select_sum(cursor); break;
		case MSG_SELECT_CHAIN:      event = parse_select_chain(cursor); break;
		case MSG_SELECT_PLACE:      event = parse_select_place(cursor); break;
		case MSG_SELECT_DISFIELD:   event = parse_select_place(cursor, EV::SELECT_DISFIELD); break;
		case MSG_SELECT_POSITION:   event = parse_select_position(cursor); break;

		// --- batch 2 -------------------------------------------------------------------
		case MSG_CHAIN_NEGATED:     event = parse_chain_index(cursor, EV::CHAIN_NEGATED); break;
		case MSG_CHAIN_DISABLED:    event = parse_chain_index(cursor, EV::CHAIN_DISABLED); break;
		case MSG_CONFIRM_DECKTOP:   event = parse_confirm_decktop(cursor); break;
		case MSG_SWAP:              event = parse_swap(cursor); break;
		case MSG_RANDOM_SELECTED:   event = parse_random_selected(cursor); break;
		case MSG_BECOME_TARGET:     event = parse_loc_list(cursor, EV::BECOME_TARGET); break;
		case MSG_REMOVE_CARDS:      event = parse_loc_list(cursor, EV::REMOVE_CARDS); break;
		case MSG_EQUIP:             event = parse_loc_pair(cursor, EV::EQUIP); break;
		case MSG_CARD_TARGET:       event = parse_loc_pair(cursor, EV::CARD_TARGET); break;
		case MSG_CANCEL_TARGET:     event = parse_loc_pair(cursor, EV::CANCEL_TARGET); break;
		case MSG_PAY_LPCOST:        event = parse_pay_lpcost(cursor); break;
		case MSG_ADD_COUNTER:       event = parse_counter(cursor, EV::ADD_COUNTER); break;
		case MSG_REMOVE_COUNTER:    event = parse_counter(cursor, EV::REMOVE_COUNTER); break;
		case MSG_MISSED_EFFECT:     event = parse_missed_effect(cursor); break;
		case MSG_TOSS_COIN:         event = parse_toss(cursor, EV::TOSS_COIN); break;
		case MSG_TOSS_DICE:         event = parse_toss(cursor, EV::TOSS_DICE); break;
		case MSG_CARD_HINT:         event = parse_card_hint(cursor); break;
		case MSG_PLAYER_HINT:       event = parse_player_hint(cursor); break;
		case MSG_DAMAGE_STEP_START: event = parse_empty(EV::DAMAGE_STEP_START); break;
		case MSG_DAMAGE_STEP_END:   event = parse_empty(EV::DAMAGE_STEP_END); break;

		case MSG_SORT_CARD:            event = parse_sort(cursor, EV::SORT_CARD); break;
		case MSG_SORT_CHAIN:           event = parse_sort(cursor, EV::SORT_CHAIN); break;
		case MSG_SELECT_COUNTER:       event = parse_select_counter(cursor); break;
		case MSG_SELECT_UNSELECT_CARD: event = parse_select_unselect_card(cursor); break;
		case MSG_ANNOUNCE_RACE:        event = parse_announce_race(cursor); break;
		case MSG_ANNOUNCE_ATTRIB:      event = parse_announce_attrib(cursor); break;
		case MSG_ANNOUNCE_CARD:        event = parse_announce_options(cursor, EV::ANNOUNCE_CARD); break;
		case MSG_ANNOUNCE_NUMBER:      event = parse_announce_options(cursor, EV::ANNOUNCE_NUMBER); break;

		case MSG_CARD_SELECTED:     event = parse_loc_list(cursor, EV::CARD_SELECTED); break;
		case MSG_BE_CHAIN_TARGET:   event = parse_loc_list(cursor, EV::BE_CHAIN_TARGET); break;
		case MSG_UNEQUIP:           event = parse_loc_pair(cursor, EV::UNEQUIP); break;
		case MSG_FIELD_DISABLED:    event = parse_field_disabled(cursor); break;
		case MSG_DECK_TOP:          event = parse_deck_top(cursor); break;
		case MSG_CONFIRM_EXTRATOP:  event = parse_confirm_extratop(cursor); break;
		case MSG_SWAP_GRAVE_DECK:   event = parse_swap_grave_deck(cursor); break;
		case MSG_REVERSE_DECK:      event = parse_empty(EV::REVERSE_DECK); break;
		case MSG_MATCH_KILL:        event = parse_empty(EV::MATCH_KILL); break;
		case MSG_ROCK_PAPER_SCISSORS: event = parse_rps(cursor); break;
		case MSG_HAND_RES:          event = parse_hand_res(cursor); break;
		// MSG_TAG_SWAP and MSG_RELOAD_FIELD: multiplayer-only, not used in solo mode.

		default:
			// Invariant V13: an opcode this batch does not cover is reported, not fatal.
			if (!warned_[opcode]) {
				warned_[opcode] = true;
				godot::UtilityFunctions::push_warning(
						String("[kaiba] MsgParser: opcode ") + String::num_int64(opcode)
						+ " is not implemented yet; the duel continues without it.");
			}
			event = make_event(EV::UNHANDLED);
			event["opcode"] = static_cast<int32_t>(opcode);
			event["size"] = static_cast<int32_t>(packet.buff_size());
			return event;
	}

	if (!cursor.ok()) {
		// The payload ended mid-field. Warn every time: a truncated message means the stream
		// is already damaged, so this is not noise worth suppressing.
		godot::UtilityFunctions::push_warning(
				String("[kaiba] MsgParser: opcode ") + String::num_int64(opcode)
				+ " payload was truncated (" + String::num_int64(static_cast<int64_t>(packet.buff_size()))
				+ " bytes); emitting MALFORMED.");
		Dictionary malformed = make_event(EV::MALFORMED);
		malformed["opcode"] = static_cast<int32_t>(opcode);
		malformed["size"] = static_cast<int32_t>(packet.buff_size());
		return malformed;
	}

	return event;
}

void MsgParser::reset_warnings() {
	warned_.fill(false);
}

} // namespace kaiba
