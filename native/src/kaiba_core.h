#ifndef KAIBA_CORE_H
#define KAIBA_CORE_H

#include <memory>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "card_db.h"
#include "duel_thread.h"
#include "response_builder.h"
#include "script_vfs.h"

namespace kaiba {

/// L1 facade over ocgcore.
///
/// Phase 0 exposes version reporting and the toolchain selftest only. Duel creation, the
/// worker thread and MSG_* parsing arrive in Phase 1. See docs/ARCHITECTURE.md section 6.
///
/// Invariant V4: once this class owns an OCG_Duel, every OCG_* call must happen on that
/// duel's own thread. Nothing here may block the main thread.
class KaibaCore : public godot::RefCounted {
	GDCLASS(KaibaCore, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	/// Version of the linked ocgcore as {"major": int, "minor": int}.
	godot::Dictionary get_core_version() const;

	/// Build identity of this binary: platform, arch, compiler and feature flags.
	/// Useful when debugging the ABI matrix across Android architectures.
	godot::Dictionary get_build_info() const;

	/// Runs the Phase 0 toolchain probe. See core_selftest.h for what it proves.
	/// Returns {"ok", "stage", "detail", "core_version", "expected_version"}.
	godot::Dictionary run_selftest() const;

	// --- Phase 1: card data, scripts and the duel lifecycle -----------------------------

	/// Loads a cards.cdb entirely into memory. Accepts res:// and user:// paths.
	/// Returns {"ok": bool, "count": int, "error": String}.
	godot::Dictionary load_card_database(const godot::String &path);

	/// Everything the UI needs to show one card, or an empty Dictionary for an unknown code.
	///
	/// Keys: "code", "name", "desc", "strings" (16 per-effect labels), "type", "level",
	/// "attribute", "race", "attack", "defense", "lscale", "rscale", "link_marker", "alias",
	/// "ot", "category", "setcodes".
	///
	/// Reads the in-memory database, so it is a hash lookup and safe to call from a tooltip.
	/// `load_card_database()` must have succeeded first.
	godot::Dictionary get_card_info(int code) const;

	/// Appends a directory to the Lua script search path, searched in insertion order.
	void add_script_root(const godot::String &path);

	/// Starts a duel on its own thread (invariants V4 and V8).
	///
	/// Config keys: "seed" (PackedInt64Array of 4; generated when absent), "flags",
	/// "start_lp", "start_hand", "draw_count", "deck_p0", "extra_p0", "deck_p1", "extra_p1"
	/// (PackedInt32Array of card codes). Returns {"ok": bool, "error": String}.
	godot::Dictionary start_duel(const godot::Dictionary &config);

	/// Drains one event from the duel thread, or null when the queue is empty.
	/// Returning a Variant rather than taking an out-parameter keeps the GDScript call site
	/// honest: `while true: var ev = core.poll_event(); if ev == null: break`.
	godot::Variant poll_event();

	/// Hands a response back to the blocked duel thread.
	void send_response(const godot::PackedByteArray &response);

	/// Encodes one player intent for the pending MSG_SELECT_* and hands it to the duel
	/// thread. `event_type` is the "t" of the selection event that is blocking the duel.
	///
	/// Returns {"ok": bool, "error": String}. On failure nothing is sent: a malformed
	/// intent leaves the duel parked on the same selection, which is recoverable, whereas
	/// half a response is not. See response_builder.h for the intent schema.
	godot::Dictionary respond(int event_type, const godot::Dictionary &intent);

	/// Stops the duel thread and joins it. Safe to call when no duel is running.
	void end_duel();

	bool is_duel_running() const;

private:
	CardDB card_db_;
	ScriptVFS script_vfs_;
	std::unique_ptr<DuelThread> duel_thread_;
};

} // namespace kaiba

#endif // KAIBA_CORE_H
