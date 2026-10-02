#ifndef KAIBA_MSG_PARSER_H
#define KAIBA_MSG_PARSER_H

// Turns one ocgcore message (Level 0, raw bytes) into one DuelEvent (Level 1, typed
// Dictionary). See docs/ARCHITECTURE.md section 7.
//
// This is the single place in the project that knows ocgcore's message layout. Nothing above
// L1 may read a raw packet, and nothing here may touch the scene tree or the duel state: the
// parser is a pure function of its input plus a warn-once bookkeeping bitmap.
//
// The authority for every layout implemented here is vendor/ocgcore itself - the
// `pduel->new_message(MSG_*)` call sites in field.cpp, operations.cpp, processor.cpp,
// playerop.cpp, libduel.cpp. EDOPro's gframe/duelclient.cpp was used as a cross-check of the
// reading side only; it is documentation, not portable code (AGENTS.md section 9).

#include <array>
#include <cstdint>

#include <godot_cpp/variant/dictionary.hpp>

#include "core_utils.h"
#include "duel_event.h"

namespace kaiba {

/// Stateless decoder, except for the warn-once table behind invariant V13.
///
/// One instance per duel. Not thread-safe: it belongs to the DuelThread that owns the
/// OCG_Duel handle (V8), same as every other L1 object.
class MsgParser {
public:
	/// Decodes one packet. Never throws, never asserts, never aborts the duel.
	///
	/// An opcode this batch does not implement comes back as
	/// `{"t": EV::UNHANDLED, "opcode": int, "size": int}` and logs one warning the first
	/// time that opcode is seen (V13). A payload that ends mid-field comes back as
	/// `{"t": EV::MALFORMED, ...}` with the same shape, and warns every time, because a
	/// truncated message means the stream is already damaged.
	godot::Dictionary parse(const core_utils::Packet &packet);

	/// Forgets which opcodes have already been warned about. Call when starting a new duel
	/// so the log reports the gap once per duel rather than once per process.
	void reset_warnings();

private:
	/// One flag per opcode byte. Keeps the log readable: an unimplemented message that fires
	/// on every chain link would otherwise drown everything else.
	std::array<bool, 256> warned_{};
};

} // namespace kaiba

#endif // KAIBA_MSG_PARSER_H
