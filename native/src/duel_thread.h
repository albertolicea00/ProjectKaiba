#ifndef KAIBA_DUEL_THREAD_H
#define KAIBA_DUEL_THREAD_H

#include "msg_parser.h"
#include "spsc_queue.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <ocgapi_types.h>

namespace kaiba {

class CardDB;
class ScriptVFS;

/// Events the duel worker synthesises itself, which correspond to no ocgcore opcode.
///
/// duel_event.h reserves "t" values at or above 1000 for exactly this. 1000-1099 is the
/// DuelThread lifecycle band; a parser-side synthetic event must pick a different one.
/// They share the integer "t" key with every parsed event, and additionally carry
/// `"src": "core"` so an adapter can filter them without knowing the EV table.
enum class LifecycleEvent : int32_t {
	/// The duel exists, both decks are loaded and OCG_StartDuel has been called.
	DUEL_STARTED = 1000,
	/// OCG_DuelProcess returned OCG_DUEL_STATUS_END. The worker is about to exit.
	DUEL_ENDED = 1001,
	/// Setup or teardown failed. Carries "stage" and "detail".
	CORE_ERROR = 1002,
	/// Passthrough of ocgcore's logHandler. Carries "level" (an OCG_LogTypes value) and
	/// "message". An OCG_LOG_TYPE_ERROR here means a broken card script.
	CORE_LOG = 1003,
};

/// Everything OCG_CreateDuel needs, plus the two decklists used to populate the duel.
///
/// Copied into the worker thread when start() is called, so the caller may let it go out
/// of scope immediately. The two pointers are NOT owned: CardDB and ScriptVFS outlive the
/// duel (KaibaCore owns them) and are shared by every duel in the process.
struct DuelConfig {
	/// OCG_CreateDuel rejects an all-zero seed with OCG_DUEL_CREATION_NULL_RNG_SEED.
	/// Replay determinism depends on this value; see ARCHITECTURE.md section 7.
	uint64_t seed[4] = { 0, 0, 0, 0 };

	/// DUEL_* flags from ocgapi_constants.h. Zero means "no optional rule", which is a
	/// legal but very old rule set; callers normally want DUEL_MODE_MR5.
	uint64_t flags = 0;

	/// index 0 is team1 / player 0, index 1 is team2 / player 1.
	OCG_Player team[2] = { { 8000u, 5u, 1u }, { 8000u, 5u, 1u } };

	/// Card codes, in deck order. index 0 is player 0's list, index 1 is player 1's.
	std::vector<uint32_t> main_deck[2];
	std::vector<uint32_t> extra_deck[2];

	CardDB *card_db = nullptr; // non-owning, must be non-null
	ScriptVFS *script_vfs = nullptr; // non-owning, must be non-null

	/// Library scripts loaded into the duel's Lua state before any card is created.
	///
	/// ocgcore only ever asks the scriptReader for `c<code>.lua` (interpreter.cpp:287); the
	/// shared library is the host's job to push in. These two pull in the rest themselves
	/// through `Duel.LoadScript`, which routes back through our own scriptReader, so the
	/// chain resolves from here. Mirrors EDOPro's `Game::SetupDuel` (game.cpp:3932).
	std::vector<std::string> init_scripts = { "constant.lua", "utility.lua" };
};

/// One OCG_Duel, one std::thread, for the whole life of that duel.
///
/// Invariants this class exists to enforce:
///
///   V4  No OCG_* call ever happens on Godot's main thread. OCG_DuelProcess runs the whole
///       rules engine synchronously and can take hundreds of milliseconds to resolve a long
///       chain. On the main thread that is a visible freeze.
///   V8  The OCG_Duel handle is created, used and destroyed on this object's worker thread
///       and is never exposed. ocgcore has no internal locking; a second thread touching the
///       handle is undefined behaviour, not a race you can win.
///   V14 Only godot::Dictionary and godot::PackedByteArray cross the boundary.
///
/// ## Thread topology
///
/// ```
///   main thread                         worker thread
///   -----------                         -------------
///   start(config) --- init handshake --> OCG_CreateDuel
///                                        OCG_DuelNewCard x N
///                                        OCG_StartDuel
///              <------- ready/failed ---
///   poll_event()  <== SpscQueue =======  OCG_DuelProcess / OCG_DuelGetMessage
///                                        MsgParser::parse -> Dictionary
///   send_response() == mutex + cv =====> OCG_DuelSetResponse
///   stop()         == mutex + cv =====>  wake, break, OCG_DestroyDuel, exit
/// ```
///
/// The event path is lock-free so the render thread never blocks. The mutex and condition
/// variable exist only for the response handoff and for shutdown, which are rare and
/// already blocking by nature.
///
/// ## Emitted events
///
/// Most Dictionaries in the queue come straight from MsgParser and carry its schema. This
/// class injects a few of its own, all of them tagged with `"src": "core"` so an adapter
/// can tell them apart from parsed MSG_* events without knowing MsgParser's schema:
///
///   {"src": "core", "t": "duel_start"}
///   {"src": "core", "t": "duel_end"}
///   {"src": "core", "t": "error", "stage": String, "detail": String}
///   {"src": "core", "t": "log",   "level": int, "message": String}
class DuelThread {
public:
	/// Events buffered between two poll_event() drains. A long chain resolves into a few
	/// hundred messages, so this holds several frames' worth of the worst realistic burst.
	/// The producer blocks (see emit()) rather than dropping if it ever fills: losing one
	/// duel message would desynchronise DuelState from the core permanently.
	static constexpr std::size_t EVENT_QUEUE_CAPACITY = 1024;

	DuelThread() = default;
	~DuelThread();

	DuelThread(const DuelThread &) = delete;
	DuelThread &operator=(const DuelThread &) = delete;

	/// Spawns the worker, then blocks until it has created and populated the duel.
	///
	/// The wait is deliberate: it is the only way start_duel() can report a real
	/// error instead of a promise. It costs one deck's worth of card lookups and Lua
	/// script compiles (roughly 110 cards for a standard 1v1), which belongs in a loading
	/// screen, not in a frame. No OCG_* call runs on the caller's thread, so V4 holds.
	///
	/// On failure the worker has already exited and been joined; the object is reusable.
	/// `error` may be null.
	bool start(const DuelConfig &config, std::string *error);

	/// Requests shutdown and joins the worker. Safe to call when no duel is running, and
	/// safe to call twice.
	///
	/// A worker parked waiting for a response wakes on the same condition variable that
	/// send_response() uses, so there is no window in which shutdown has to wait for a
	/// player to act. The one unavoidable delay is a call already inside OCG_DuelProcess:
	/// ocgcore offers no way to abort a process step, so stop() waits for it to return.
	/// That is bounded by the longest chain resolution, not by user input.
	void stop();

	/// True between a successful start() and the worker leaving its loop, whether it left
	/// because the duel ended or because stop() was called.
	bool is_running() const;

	/// Consumer side of the event queue. Call from the main thread. Returns false when
	/// there is nothing queued. Events stay drainable after the duel ends.
	bool poll_event(godot::Dictionary &out);

	/// Producer side of the response handoff. Call from the main thread.
	///
	/// Overwrites any response that has not been consumed yet: ocgcore asks for exactly one
	/// response at a time, so a second call before the worker wakes is a bug in the caller
	/// and the last answer is the one that counts.
	void send_response(const godot::PackedByteArray &response);

private:
	enum class InitState : int {
		PENDING,
		READY,
		FAILED
	};

	// --- worker thread only ----------------------------------------------------------
	void run();
	bool create_duel(std::string *error);
	bool load_init_scripts(std::string *error);
	bool populate_decks(std::string *error);
	void process_loop();
	bool dispatch_messages(uint8_t *buffer, uint32_t length);
	bool wait_for_response(std::vector<uint8_t> &out);
	bool emit(const godot::Dictionary &event);
	void emit_lifecycle(LifecycleEvent type);
	void emit_error(const char *stage, const std::string &detail);
	static void log_handler(void *payload, const char *message, int type);

	bool stop_requested() const;

	/// Owned by the worker thread for its whole lifetime. Never read from anywhere else.
	OCG_Duel duel_ = nullptr;

	/// Last OCG_LOG_TYPE_ERROR text seen by log_handler. Worker thread only.
	std::string last_core_error_;

	// --- shared ----------------------------------------------------------------------
	DuelConfig config_;
	std::thread worker_;
	/// Owned by the worker thread, like the OCG_Duel handle itself (V8).
	MsgParser parser_;
	SpscQueue<godot::Dictionary, EVENT_QUEUE_CAPACITY> events_;
	std::atomic<bool> duel_live_{ false };

	mutable std::mutex mutex_;
	std::condition_variable cv_;
	std::vector<uint8_t> response_;
	bool has_response_ = false;
	bool stop_requested_ = false;
	InitState init_state_ = InitState::PENDING;
	std::string init_error_;
};

} // namespace kaiba

#endif // KAIBA_DUEL_THREAD_H
