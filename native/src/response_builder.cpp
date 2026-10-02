#include "response_builder.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <ocgapi_constants.h>

#include "buffer_io.h"
#include "duel_event.h"

using godot::Array;
using godot::Dictionary;
using godot::PackedByteArray;
using godot::PackedInt32Array;
using godot::PackedInt64Array;
using godot::String;
using godot::Variant;

namespace kaiba {

// Same discipline as msg_parser.cpp: EV values double as a replay serialisation format, so a
// core bump that renumbered an opcode must break the build rather than quietly make this
// file answer the wrong question.
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
static_assert(static_cast<int32_t>(EV::SORT_CARD) == MSG_SORT_CARD, "EV/MSG drift");

namespace {

using Bytes = std::vector<uint8_t>;
using core_utils::BufferIO;

// ---------------------------------------------------------------------------------------
// Byte writers
// ---------------------------------------------------------------------------------------
//
// Everything goes through BufferIO::insert_value, i.e. a plain memcpy of the host
// representation. That is not laziness: ocgcore reads the response back with
// ProgressiveBuffer::at<T>(), which is itself a memcpy out of the same buffer. Matching it
// byte for byte is the definition of correct here, and it stays correct on any endianness.

void put_i32(Bytes &bytes, int32_t value) {
	BufferIO::insert_value<int32_t>(bytes, value);
}

void put_u32(Bytes &bytes, uint32_t value) {
	BufferIO::insert_value<uint32_t>(bytes, value);
}

void put_u8(Bytes &bytes, uint8_t value) {
	BufferIO::insert_value<uint8_t>(bytes, value);
}

// ---------------------------------------------------------------------------------------
// Intent reading
// ---------------------------------------------------------------------------------------

void set_error(String *error, const String &text) {
	if (error != nullptr) {
		*error = text;
	}
}

/// Starts an error message already prefixed with the message being answered.
String prefix(const String &what) {
	String message = what;
	message += ": ";
	return message;
}

/// Returns the first alias actually present in the intent, or null.
const char *find_key(const Dictionary &intent, std::initializer_list<const char *> keys) {
	for (const char *key : keys) {
		if (intent.has(key)) {
			return key;
		}
	}
	return nullptr;
}

/// Accepts INT, BOOL and whole-valued FLOAT. GDScript hands integers over as any of the
/// three depending on how the caller built the Dictionary; 1.5 is still rejected.
bool variant_to_int(const Variant &value, int64_t &out) {
	switch (value.get_type()) {
		case Variant::INT:
		case Variant::BOOL:
			out = static_cast<int64_t>(value);
			return true;
		case Variant::FLOAT: {
			const double raw = static_cast<double>(value);
			out = static_cast<int64_t>(raw);
			return static_cast<double>(out) == raw;
		}
		default:
			return false;
	}
}

bool read_int(const Dictionary &intent, std::initializer_list<const char *> keys,
		const String &what, int64_t &out, String *error) {
	const char *key = find_key(intent, keys);
	if (key == nullptr) {
		String message = prefix(what);
		message += "intent is missing the required key \"";
		message += *keys.begin();
		message += "\"";
		set_error(error, message);
		return false;
	}
	if (!variant_to_int(intent[key], out)) {
		String message = prefix(what);
		message += "\"";
		message += key;
		message += "\" must be an integer";
		set_error(error, message);
		return false;
	}
	return true;
}

/// Same, but a missing key is not an error.
bool read_optional_int(const Dictionary &intent, std::initializer_list<const char *> keys,
		const String &what, int64_t fallback, int64_t &out, String *error) {
	if (find_key(intent, keys) == nullptr) {
		out = fallback;
		return true;
	}
	return read_int(intent, keys, what, out, error);
}

/// True when the intent asks to decline the selection rather than answer it.
bool wants_cancel(const Dictionary &intent) {
	const char *key = find_key(intent, { "cancel", "canceled" });
	int64_t raw = 0;
	return key != nullptr && variant_to_int(intent[key], raw) && raw != 0;
}

/// Reads an integer list from an Array or from any of the packed integer array types.
bool read_int_list(const Dictionary &intent, std::initializer_list<const char *> keys,
		const String &what, std::vector<int64_t> &out, String *error) {
	const char *key = find_key(intent, keys);
	if (key == nullptr) {
		String message = prefix(what);
		message += "intent is missing the required key \"";
		message += *keys.begin();
		message += "\"";
		set_error(error, message);
		return false;
	}

	const Variant value = intent[key];

	switch (value.get_type()) {
		case Variant::ARRAY: {
			const Array list = value;
			for (int64_t i = 0; i < list.size(); ++i) {
				int64_t item = 0;
				if (!variant_to_int(list[i], item)) {
					String message = prefix(what);
					message += "\"";
					message += key;
					message += "\" entry ";
					message += String::num_int64(i);
					message += " is not an integer";
					set_error(error, message);
					return false;
				}
				out.push_back(item);
			}
			return true;
		}
		case Variant::PACKED_INT32_ARRAY: {
			const PackedInt32Array list = value;
			for (int64_t i = 0; i < list.size(); ++i) {
				out.push_back(static_cast<int64_t>(list[i]));
			}
			return true;
		}
		case Variant::PACKED_INT64_ARRAY: {
			const PackedInt64Array list = value;
			for (int64_t i = 0; i < list.size(); ++i) {
				out.push_back(list[i]);
			}
			return true;
		}
		case Variant::PACKED_BYTE_ARRAY: {
			const PackedByteArray list = value;
			for (int64_t i = 0; i < list.size(); ++i) {
				out.push_back(static_cast<int64_t>(list[i]));
			}
			return true;
		}
		default: {
			String message = prefix(what);
			message += "\"";
			message += key;
			message += "\" must be an array of integers";
			set_error(error, message);
			return false;
		}
	}
}

// ---------------------------------------------------------------------------------------
// MSG_SELECT_IDLECMD / MSG_SELECT_BATTLECMD
// ---------------------------------------------------------------------------------------
//
// Both answer with a single int32 that packs two values:
//
//     uint32_t t = returns.at<int32_t>(0) & 0xffff;   // which list the player acted on
//     uint32_t s = returns.at<int32_t>(0) >> 16;      // index inside that list
//
// so the response is `(index << 16) | command`, four bytes and nothing else. The unpack
// above is verbatim from the `else` branch of both handlers in playerop.cpp, and
// processor.cpp repeats it when it consumes the answer
// (`core.summonable_cards[returns.at<int32_t>(0) >> 16]` and friends).
//
// The shift runs on a *signed* int32 there, so an index of 0x8000 or more sign-extends and
// comes back as a huge uint32 that fails the engine's own bounds check. INDEX_MAX caps it.

constexpr int64_t INDEX_MAX = 0x7fff;

struct Command {
	const char *name;
	int32_t code;
	/// False for the "change phase" style commands, which carry no list index.
	bool takes_index;
};

/// t values 0..8, from the bounds check in field::process(Processors::SelectIdleCmd&).
/// The names match the list keys MsgParser puts in the request event.
constexpr Command IDLE_COMMANDS[] = {
	{ "summon", 0, true },
	{ "spsummon", 1, true },
	{ "repos", 2, true },
	{ "mset", 3, true },
	{ "sset", 4, true },
	{ "activate", 5, true },
	{ "to_bp", 6, false },
	{ "to_ep", 7, false },
	{ "shuffle", 8, false },
};

/// t values 0..3, from field::process(Processors::SelectBattleCmd&).
constexpr Command BATTLE_COMMANDS[] = {
	{ "activate", 0, true },
	{ "attack", 1, true },
	{ "to_m2", 2, false },
	{ "to_ep", 3, false },
};

String command_list(const Command *table, std::size_t count) {
	String names;
	for (std::size_t i = 0; i < count; ++i) {
		if (i != 0) {
			names += ", ";
		}
		names += table[i].name;
	}
	return names;
}

bool encode_packed_command(const Dictionary &intent, const Command *table, std::size_t count,
		const String &what, Bytes &bytes, String *error) {
	const char *key = find_key(intent, { "cmd", "command", "action" });
	if (key == nullptr) {
		String message = prefix(what);
		message += "intent is missing the required key \"cmd\" (one of ";
		message += command_list(table, count);
		message += ")";
		set_error(error, message);
		return false;
	}

	const Variant raw = intent[key];
	const Command *chosen = nullptr;

	if (raw.get_type() == Variant::STRING || raw.get_type() == Variant::STRING_NAME) {
		const String name = raw;
		for (std::size_t i = 0; i < count && chosen == nullptr; ++i) {
			if (name == String(table[i].name)) {
				chosen = &table[i];
			}
		}
		if (chosen == nullptr) {
			String message = prefix(what);
			message += "unknown command \"";
			message += name;
			message += "\"; expected one of ";
			message += command_list(table, count);
			set_error(error, message);
			return false;
		}
	} else {
		int64_t code = 0;
		if (!variant_to_int(raw, code)) {
			String message = prefix(what);
			message += "\"";
			message += key;
			message += "\" must be a command name or its integer code";
			set_error(error, message);
			return false;
		}
		for (std::size_t i = 0; i < count && chosen == nullptr; ++i) {
			if (static_cast<int64_t>(table[i].code) == code) {
				chosen = &table[i];
			}
		}
		if (chosen == nullptr) {
			String message = prefix(what);
			message += "command code ";
			message += String::num_int64(code);
			message += " is out of range; expected 0..";
			message += String::num_int64(static_cast<int64_t>(count) - 1);
			set_error(error, message);
			return false;
		}
	}

	int64_t index = 0;
	if (!read_optional_int(intent, { "index", "idx" }, what, 0, index, error)) {
		return false;
	}

	if (!chosen->takes_index) {
		if (index != 0) {
			String message = prefix(what);
			message += "command \"";
			message += chosen->name;
			message += "\" takes no index, but \"index\" was ";
			message += String::num_int64(index);
			set_error(error, message);
			return false;
		}
	} else if (index < 0 || index > INDEX_MAX) {
		String message = prefix(what);
		message += "\"index\" must be between 0 and ";
		message += String::num_int64(INDEX_MAX);
		message += ", got ";
		message += String::num_int64(index);
		set_error(error, message);
		return false;
	}

	put_i32(bytes, static_cast<int32_t>((index << 16) | static_cast<int64_t>(chosen->code)));
	return true;
}

// ---------------------------------------------------------------------------------------
// Yes/no, option, chain, position
// ---------------------------------------------------------------------------------------

/// MSG_SELECT_EFFECTYN and MSG_SELECT_YESNO both reject anything that is not literally 0 or
/// 1 (playerop.cpp). 1 is yes: processor.cpp turns the answer into a chain index with
/// `returns.set<int32_t>(0, returns.at<int32_t>(0) - 1)`, so 1 selects chain 0 and 0 declines.
bool encode_yes_no(const Dictionary &intent, const String &what, Bytes &bytes, String *error) {
	int64_t raw = 0;
	if (!read_int(intent, { "yes", "answer", "value" }, what, raw, error)) {
		return false;
	}
	put_i32(bytes, raw != 0 ? 1 : 0);
	return true;
}

/// MSG_SELECT_OPTION answers with the zero-based index into the option list, as an int32.
bool encode_option(const Dictionary &intent, const String &what, Bytes &bytes, String *error) {
	int64_t index = 0;
	if (!read_int(intent, { "index", "option", "idx" }, what, index, error)) {
		return false;
	}
	if (index < 0) {
		String message = prefix(what);
		message += "\"index\" must not be negative, got ";
		message += String::num_int64(index);
		set_error(error, message);
		return false;
	}
	put_i32(bytes, static_cast<int32_t>(index));
	return true;
}

/// MSG_SELECT_CHAIN answers with the index into the offered chain list, as an int32.
/// -1 declines, and the engine accepts that only when the request was not `forced`.
bool encode_chain(const Dictionary &intent, const String &what, Bytes &bytes, String *error) {
	if (wants_cancel(intent)) {
		put_i32(bytes, -1);
		return true;
	}
	int64_t index = 0;
	if (!read_int(intent, { "index", "chain", "idx" }, what, index, error)) {
		return false;
	}
	if (index < -1 || index > INT32_MAX) {
		String message = prefix(what);
		message += "\"index\" must be -1 (decline) or a chain index, got ";
		message += String::num_int64(index);
		set_error(error, message);
		return false;
	}
	put_i32(bytes, static_cast<int32_t>(index));
	return true;
}

/// MSG_SELECT_POSITION answers with one POS_* bit as an int32. The engine rejects any value
/// that is not exactly one of 0x1 / 0x2 / 0x4 / 0x8, and also rejects a position the request
/// did not offer - the latter needs the request, so it is not checkable here.
bool encode_position(const Dictionary &intent, const String &what, Bytes &bytes, String *error) {
	int64_t position = 0;
	if (!read_int(intent, { "position", "pos" }, what, position, error)) {
		return false;
	}
	if (position != POS_FACEUP_ATTACK && position != POS_FACEDOWN_ATTACK
			&& position != POS_FACEUP_DEFENSE && position != POS_FACEDOWN_DEFENSE) {
		String message = prefix(what);
		message += "\"position\" must be exactly one POS_* bit (1, 2, 4 or 8), got ";
		message += String::num_int64(position);
		set_error(error, message);
		return false;
	}
	put_i32(bytes, static_cast<int32_t>(position));
	return true;
}

// ---------------------------------------------------------------------------------------
// The shared card-list answer
// ---------------------------------------------------------------------------------------
//
// ::parse_response_cards in playerop.cpp defines one encoding, used by MSG_SELECT_CARD,
// MSG_SELECT_TRIBUTE and MSG_SELECT_SUM alike:
//
//     int32  type      -1 cancel | 0 uint32 indices | 1 uint16 indices | 2 uint8 indices
//                      | 3 bitset over the offered list, starting at bit 32
//     uint32 count     types 0-2 only
//     index[count]     always starting at byte 8, 4 / 2 / 1 bytes wide by type
//
// The three index widths land on the same byte offset because ProgressiveBuffer::at<T>(pos)
// indexes in units of T: at<uint32_t>(2), at<uint16_t>(4) and at<uint8_t>(8) are all byte 8.
//
// We always emit type 0. It is the only variant with no ceiling on the index value, its
// count is explicit, and ProgressiveBuffer::at silently returns 0 past the end of the
// buffer - so a format whose length is implied (type 3) can be misread, while this cannot.

bool encode_card_list(const Dictionary &intent, const String &what, bool allow_cancel,
		Bytes &bytes, String *error) {
	if (wants_cancel(intent)) {
		if (!allow_cancel) {
			String message = prefix(what);
			message += "this selection can never be cancelled";
			set_error(error, message);
			return false;
		}
		put_i32(bytes, -1);
		return true;
	}

	std::vector<int64_t> indices;
	// Answering with exactly one card is the common case, so a scalar "index" is accepted
	// as shorthand for a one-element "indices".
	if (find_key(intent, { "indices", "selected" }) == nullptr
			&& find_key(intent, { "index", "idx" }) != nullptr) {
		int64_t single = 0;
		if (!read_int(intent, { "index", "idx" }, what, single, error)) {
			return false;
		}
		indices.push_back(single);
	} else if (!read_int_list(intent, { "indices", "selected" }, what, indices, error)) {
		return false;
	}

	for (std::size_t i = 0; i < indices.size(); ++i) {
		if (indices[i] < 0 || indices[i] > static_cast<int64_t>(UINT32_MAX)) {
			String message = prefix(what);
			message += "index ";
			message += String::num_int64(indices[i]);
			message += " is not a valid position in the offered list";
			set_error(error, message);
			return false;
		}
	}

	put_i32(bytes, 0);
	put_u32(bytes, static_cast<uint32_t>(indices.size()));
	for (std::size_t i = 0; i < indices.size(); ++i) {
		put_u32(bytes, static_cast<uint32_t>(indices[i]));
	}
	return true;
}

// ---------------------------------------------------------------------------------------
// MSG_SELECT_PLACE
// ---------------------------------------------------------------------------------------
//
// The answer is `count` three-byte triples, read back as
//
//     uint8 player; uint8 location; uint8 sequence;
//
// with the cursor advancing by 3 per zone (playerop.cpp, Processors::SelectPlace). `count`
// is the value the request carried. The engine reads exactly that many triples and
// ProgressiveBuffer::at returns 0 past the end of the buffer, so a short answer decodes as
// location 0, fails the engine's LOCATION_MZONE / LOCATION_SZONE check and loops silently on
// MSG_RETRY. That is why "count" is accepted here as an optional cross-check.
//
// The engine also rejects a zone that is set in the request's `flag` bitmask (flag marks the
// zones that are NOT available). That needs the request, so it is L3's check, not ours.

bool encode_one_place(const Dictionary &place, const String &what, int64_t ordinal,
		Bytes &bytes, String *error) {
	String where = what;
	where += " place ";
	where += String::num_int64(ordinal);

	int64_t controller = 0;
	int64_t location = 0;
	int64_t sequence = 0;
	if (!read_int(place, { "con", "player", "controller" }, where, controller, error)
			|| !read_int(place, { "loc", "location" }, where, location, error)
			|| !read_int(place, { "seq", "sequence" }, where, sequence, error)) {
		return false;
	}

	if (controller != 0 && controller != 1) {
		String message = prefix(where);
		message += "\"con\" must be 0 or 1, got ";
		message += String::num_int64(controller);
		set_error(error, message);
		return false;
	}
	if (location != LOCATION_MZONE && location != LOCATION_SZONE) {
		String message = prefix(where);
		message += "\"loc\" must be LOCATION_MZONE (4) or LOCATION_SZONE (8), got ";
		message += String::num_int64(location);
		set_error(error, message);
		return false;
	}
	// The engine's own bound is `sequence > 7 - ismzone`: 0..6 for monster zones (five main
	// plus two extra-monster zones) and 0..7 for spell/trap zones (five plus two pendulum
	// zones plus the field zone).
	const int64_t max_sequence = (location == LOCATION_MZONE) ? 6 : 7;
	if (sequence < 0 || sequence > max_sequence) {
		String message = prefix(where);
		message += "\"seq\" must be between 0 and ";
		message += String::num_int64(max_sequence);
		message += " for this location, got ";
		message += String::num_int64(sequence);
		set_error(error, message);
		return false;
	}

	put_u8(bytes, static_cast<uint8_t>(controller));
	put_u8(bytes, static_cast<uint8_t>(location));
	put_u8(bytes, static_cast<uint8_t>(sequence));
	return true;
}

bool encode_place(const Dictionary &intent, const String &what, Bytes &bytes, String *error) {
	Array places;
	if (intent.has("places")) {
		const Variant raw = intent["places"];
		if (raw.get_type() != Variant::ARRAY) {
			String message = prefix(what);
			message += "\"places\" must be an array of {con, loc, seq} dictionaries";
			set_error(error, message);
			return false;
		}
		const Array given = raw;
		places = given;
	} else if (find_key(intent, { "loc", "location" }) != nullptr) {
		// Single-zone shorthand: the intent itself is the one place. This is what a normal
		// summon or set answers with, and it is by far the most common case.
		places.push_back(intent);
	} else {
		String message = prefix(what);
		message += "intent is missing the required key \"places\"";
		set_error(error, message);
		return false;
	}

	if (places.is_empty()) {
		String message = prefix(what);
		message += "\"places\" is empty; the engine always asks for at least one zone";
		set_error(error, message);
		return false;
	}

	// Optional: the "count" the request carried. Cross-checking it here turns a silent
	// MSG_RETRY loop into a named error at the call site.
	int64_t expected = 0;
	if (!read_optional_int(intent, { "count" }, what, places.size(), expected, error)) {
		return false;
	}
	if (expected != places.size()) {
		String message = prefix(what);
		message += "the request asked for ";
		message += String::num_int64(expected);
		message += " zone(s) but the intent carries ";
		message += String::num_int64(places.size());
		set_error(error, message);
		return false;
	}

	for (int64_t i = 0; i < places.size(); ++i) {
		const Variant entry = places[i];
		if (entry.get_type() != Variant::DICTIONARY) {
			String message = prefix(what);
			message += "place ";
			message += String::num_int64(i);
			message += " must be a dictionary with \"con\", \"loc\" and \"seq\"";
			set_error(error, message);
			return false;
		}
		const Dictionary place = entry;
		if (!encode_one_place(place, what, i, bytes, error)) {
			return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------------------
// MSG_SORT_CARD
// ---------------------------------------------------------------------------------------
//
// One signed byte per card in the offered list. A leading -1 declines the whole sort and the
// engine keeps its own order (`if(returns.at<int8_t>(0) == -1) return TRUE;`).
//
// The direction of the mapping is the easy thing to get backwards. processor.cpp applies it
// as `tc[returns.at<uint8_t>(i)] = core.select_cards[i]`, so byte i is the *destination rank*
// of offered card i - not "which card goes into slot i".
//
// The engine validates with `returns.at<int8_t>(i)` against `m = select_cards.size()`, so a
// rank is only representable while it fits a non-negative int8_t: a list longer than 128
// cards cannot be sorted through this protocol at all.

constexpr int64_t SORT_MAX_CARDS = 128;

bool encode_sort(const Dictionary &intent, const String &what, Bytes &bytes, String *error) {
	if (wants_cancel(intent)) {
		put_u8(bytes, 0xffu); // int8_t -1
		return true;
	}

	std::vector<int64_t> order;
	if (!read_int_list(intent, { "order", "indices" }, what, order, error)) {
		return false;
	}
	if (order.empty()) {
		String message = prefix(what);
		message += "\"order\" is empty; use {\"cancel\": true} to decline the sort";
		set_error(error, message);
		return false;
	}

	const int64_t size = static_cast<int64_t>(order.size());
	if (size > SORT_MAX_CARDS) {
		String message = prefix(what);
		message += "\"order\" holds ";
		message += String::num_int64(size);
		message += " entries; ocgcore reads each rank as a signed byte and cannot sort more than ";
		message += String::num_int64(SORT_MAX_CARDS);
		set_error(error, message);
		return false;
	}

	std::vector<bool> seen(static_cast<std::size_t>(size), false);
	for (std::size_t i = 0; i < order.size(); ++i) {
		const int64_t rank = order[i];
		if (rank < 0 || rank >= size) {
			String message = prefix(what);
			message += "\"order\" entry ";
			message += String::num_int64(static_cast<int64_t>(i));
			message += " is ";
			message += String::num_int64(rank);
			message += "; ranks must be 0..";
			message += String::num_int64(size - 1);
			set_error(error, message);
			return false;
		}
		if (seen[static_cast<std::size_t>(rank)]) {
			String message = prefix(what);
			message += "\"order\" uses rank ";
			message += String::num_int64(rank);
			message += " twice; it must be a permutation";
			set_error(error, message);
			return false;
		}
		seen[static_cast<std::size_t>(rank)] = true;
	}

	for (std::size_t i = 0; i < order.size(); ++i) {
		put_u8(bytes, static_cast<uint8_t>(order[i]));
	}
	return true;
}

// ---------------------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------------------

/// Name of an event_type for error messages. Covers the selections this file does not
/// implement too, so "not supported yet" can at least say what was asked for.
const char *event_name(int32_t event_type) {
	switch (event_type) {
		case MSG_SELECT_BATTLECMD: return "MSG_SELECT_BATTLECMD";
		case MSG_SELECT_IDLECMD: return "MSG_SELECT_IDLECMD";
		case MSG_SELECT_EFFECTYN: return "MSG_SELECT_EFFECTYN";
		case MSG_SELECT_YESNO: return "MSG_SELECT_YESNO";
		case MSG_SELECT_OPTION: return "MSG_SELECT_OPTION";
		case MSG_SELECT_CARD: return "MSG_SELECT_CARD";
		case MSG_SELECT_CHAIN: return "MSG_SELECT_CHAIN";
		case MSG_SELECT_PLACE: return "MSG_SELECT_PLACE";
		case MSG_SELECT_DISFIELD: return "MSG_SELECT_DISFIELD";
		case MSG_SELECT_POSITION: return "MSG_SELECT_POSITION";
		case MSG_SELECT_TRIBUTE: return "MSG_SELECT_TRIBUTE";
		case MSG_SORT_CHAIN: return "MSG_SORT_CHAIN";
		case MSG_SELECT_COUNTER: return "MSG_SELECT_COUNTER";
		case MSG_SELECT_SUM: return "MSG_SELECT_SUM";
		case MSG_SORT_CARD: return "MSG_SORT_CARD";
		case MSG_SELECT_UNSELECT_CARD: return "MSG_SELECT_UNSELECT_CARD";
		case MSG_ANNOUNCE_RACE: return "MSG_ANNOUNCE_RACE";
		case MSG_ANNOUNCE_ATTRIB: return "MSG_ANNOUNCE_ATTRIB";
		case MSG_ANNOUNCE_CARD: return "MSG_ANNOUNCE_CARD";
		case MSG_ANNOUNCE_NUMBER: return "MSG_ANNOUNCE_NUMBER";
		case MSG_ROCK_PAPER_SCISSORS: return "MSG_ROCK_PAPER_SCISSORS";
		default: return nullptr;
	}
}

bool encode(int32_t event_type, const Dictionary &intent, Bytes &bytes, String *error) {
	switch (event_type) {
		case MSG_SELECT_IDLECMD:
			return encode_packed_command(intent, IDLE_COMMANDS,
					sizeof(IDLE_COMMANDS) / sizeof(IDLE_COMMANDS[0]), "MSG_SELECT_IDLECMD", bytes, error);
		case MSG_SELECT_BATTLECMD:
			return encode_packed_command(intent, BATTLE_COMMANDS,
					sizeof(BATTLE_COMMANDS) / sizeof(BATTLE_COMMANDS[0]), "MSG_SELECT_BATTLECMD", bytes, error);

		case MSG_SELECT_EFFECTYN:
			return encode_yes_no(intent, "MSG_SELECT_EFFECTYN", bytes, error);
		case MSG_SELECT_YESNO:
			return encode_yes_no(intent, "MSG_SELECT_YESNO", bytes, error);
		case MSG_SELECT_OPTION:
			return encode_option(intent, "MSG_SELECT_OPTION", bytes, error);

		case MSG_SELECT_CARD:
			return encode_card_list(intent, "MSG_SELECT_CARD", true, bytes, error);
		case MSG_SELECT_TRIBUTE:
			return encode_card_list(intent, "MSG_SELECT_TRIBUTE", true, bytes, error);
		// field::process(Processors::SelectSum&) calls parse_response_cards(false): a sum
		// selection is never cancelable, whatever the intent says.
		case MSG_SELECT_SUM:
			return encode_card_list(intent, "MSG_SELECT_SUM", false, bytes, error);

		case MSG_SELECT_CHAIN:
			return encode_chain(intent, "MSG_SELECT_CHAIN", bytes, error);

		// MSG_SELECT_DISFIELD is the same Processors::SelectPlace with disable_field set;
		// playerop.cpp only picks a different opcode for the request. Same answer format.
		case MSG_SELECT_PLACE:
			return encode_place(intent, "MSG_SELECT_PLACE", bytes, error);
		case MSG_SELECT_DISFIELD:
			return encode_place(intent, "MSG_SELECT_DISFIELD", bytes, error);

		case MSG_SELECT_POSITION:
			return encode_position(intent, "MSG_SELECT_POSITION", bytes, error);

		// MSG_SORT_CHAIN is Processors::SortCard with is_chain set, read back by
		// Processors::SortChain with the identical `returns.at<int8_t>(i)` loop.
		case MSG_SORT_CARD:
			return encode_sort(intent, "MSG_SORT_CARD", bytes, error);
		case MSG_SORT_CHAIN:
			return encode_sort(intent, "MSG_SORT_CHAIN", bytes, error);

		default: {
			String message = "ResponseBuilder: ";
			const char *name = event_name(event_type);
			if (name != nullptr) {
				message += name;
				message += " (event type ";
				message += String::num_int64(event_type);
				message += ") is a selection, but no response encoder exists for it yet";
			} else {
				message += "event type ";
				message += String::num_int64(event_type);
				message += " is not a selection that takes a response";
			}
			set_error(error, message);
			return false;
		}
	}
}

} // namespace

bool ResponseBuilder::build(int32_t event_type, const Dictionary &intent,
		PackedByteArray &out, String *error) {
	if (error != nullptr) {
		*error = String();
	}

	// Built aside and only handed over once every check has passed, so a rejected intent
	// leaves `out` exactly as the caller left it. Half a response is worse than none: the
	// engine reads the missing bytes back as zeros and acts on them.
	Bytes bytes;
	if (!encode(event_type, intent, bytes, error)) {
		return false;
	}

	out.resize(static_cast<int64_t>(bytes.size()));
	if (!bytes.empty()) {
		std::memcpy(out.ptrw(), bytes.data(), bytes.size());
	}
	return true;
}

} // namespace kaiba
