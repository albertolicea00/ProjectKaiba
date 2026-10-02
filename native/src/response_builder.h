#ifndef KAIBA_RESPONSE_BUILDER_H
#define KAIBA_RESPONSE_BUILDER_H

// The answering half of MsgParser: turns one player intent into the byte buffer that
// OCG_DuelSetResponse expects for the MSG_SELECT_* currently blocking the duel.
//
// This is the second (and last) place in the project that knows ocgcore's wire format.
// MsgParser decodes requests; this encodes answers. They are NOT mirror images of each
// other - the response layout of a message has nothing to do with its request layout, and
// the integer widths differ per message exactly like they do on the request side
// (AGENTS.md section 8b trap 2).
//
// The authority for every layout implemented here is vendor/ocgcore itself: the `else`
// branch of each `field::process(Processors::Select*&)` in playerop.cpp, which is the code
// that reads `returns` back. `::parse_response_cards` in the same file defines the shared
// encoding used by every card-list answer. EDOPro's client was not consulted; it is
// documentation, not an authority (AGENTS.md section 9).
//
// An invalid-but-well-formed answer is not fatal: ocgcore emits MSG_RETRY and parks on the
// same selection again (processor_visit.cpp increments the step but `needs_answer` stays
// true), so the duel re-asks rather than desynchronising. This class still validates
// everything it can see, because a MSG_RETRY loop is silent and a returned error is not.
//
// What it cannot validate is anything that depends on the pending request: whether an index
// is inside the list the engine offered, whether a zone is actually free, whether a
// selection was cancelable. `build` is a pure function of (event_type, intent) by design -
// it holds no duel state (V8: the duel lives on its own thread). Range checks against the
// request belong to L3, which has the parsed event in hand.
//
// ---------------------------------------------------------------------------------------
// Intent schema, one entry per supported event_type
// ---------------------------------------------------------------------------------------
//
// Key names match MsgParser's event keys wherever the two talk about the same thing, so an
// adapter can read a request and write an answer in one vocabulary.
//
//   EV::SELECT_IDLECMD   {"cmd": "summon"|"spsummon"|"repos"|"mset"|"sset"|"activate"
//                                |"to_bp"|"to_ep"|"shuffle"  (or the int 0..8),
//                         "index": int}          index into the matching request list;
//                                                omitted or 0 for to_bp / to_ep / shuffle
//
//   EV::SELECT_BATTLECMD {"cmd": "activate"|"attack"|"to_m2"|"to_ep"  (or the int 0..3),
//                         "index": int}
//
//   EV::SELECT_EFFECTYN  {"yes": bool}
//   EV::SELECT_YESNO     {"yes": bool}
//   EV::SELECT_OPTION    {"index": int}          index into the request's "options"
//
//   EV::SELECT_CARD      {"indices": [int, ...]} indices into the request's "cards";
//   EV::SELECT_TRIBUTE                           a scalar "index" is accepted for the
//   EV::SELECT_SUM                               one-card case
//                        {"cancel": true}        instead of "indices", when the request
//                                                said cancelable (SELECT_SUM never is)
//
//         For SELECT_SUM the indices address the *selectable* list only. MSG_SELECT_SUM
//         carries two lists, must-select first and selectable second; ocgcore prepends the
//         must-select cards itself and never looks for them in the answer.
//
//   EV::SELECT_CHAIN     {"index": int}          index into "chains"; -1 declines
//                        {"cancel": true}        same as index -1
//
//   EV::SELECT_PLACE     {"places": [{"con": int, "loc": int, "seq": int}, ...],
//                         "count": int}          "count" is an optional cross-check against
//                                                the request; a single-zone answer may drop
//                                                "places" and carry con/loc/seq directly
//
//   EV::SELECT_POSITION  {"position": int}       exactly one POS_* bit
//
//   EV::SORT_CARD        {"order": [int, ...]}   order[i] = rank card i must end up at
//                        {"cancel": true}        let the engine keep its own order
//
// Aliases: "command"/"action" for "cmd", "idx" for "index", "pos" for "position",
// "answer"/"value" for "yes", "selected" for "indices", "player"/"controller" for "con",
// "location" for "loc", "sequence" for "seq". Any integer-valued key also accepts a bool.
//
// MSG_SELECT_DISFIELD and MSG_SORT_CHAIN are accepted too. They are not extra features:
// ocgcore answers them through the very same Processors::SelectPlace and
// Processors::SortCard handlers, with byte-identical response formats, and only picks a
// different opcode for the request.

#include <cstdint>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace kaiba {

/// Stateless encoder. No instance, no duel handle, no ownership (V8, V14).
class ResponseBuilder {
public:
	/// Encodes one answer to a pending MSG_SELECT_* into the byte buffer
	/// OCG_DuelSetResponse wants.
	///
	/// `event_type` is an EV value, which is also the ocgcore MSG_* opcode (duel_event.h).
	/// Returns false and fills `error` if the intent does not match the pending message, in
	/// which case `out` is left exactly as it was: a rejected intent never produces bytes.
	/// `error` may be null.
	static bool build(int32_t event_type, const godot::Dictionary &intent,
			godot::PackedByteArray &out, godot::String *error);
};

} // namespace kaiba

#endif // KAIBA_RESPONSE_BUILDER_H
