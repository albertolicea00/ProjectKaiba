#include "duel_thread.h"

#include "card_db.h"
#include "core_utils.h"
#include "script_vfs.h"

#include <chrono>
#include <utility>

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <ocgapi.h>
#include <ocgapi_constants.h>

using godot::Dictionary;
using godot::PackedByteArray;
using godot::String;

namespace kaiba {

namespace {

/// How long the producer backs off when the event queue is full.
///
/// Dropping an event is not an option: DuelState is built by replaying the stream in order,
/// so a hole in it desynchronises the board permanently. Blocking the worker is the lesser
/// evil - it only stalls the duel, and only while the main thread is far behind.
constexpr auto QUEUE_BACKOFF = std::chrono::milliseconds(1);

} // namespace

DuelThread::~DuelThread() {
	stop();
}

bool DuelThread::start(const DuelConfig &config, std::string *error) {
	if (worker_.joinable()) {
		if (error != nullptr) {
			*error = "a duel is already running on this DuelThread";
		}
		return false;
	}
	if (config.card_db == nullptr || config.script_vfs == nullptr) {
		if (error != nullptr) {
			*error = "DuelConfig needs both a CardDB and a ScriptVFS";
		}
		return false;
	}
	if (config.seed[0] == 0 && config.seed[1] == 0 && config.seed[2] == 0 && config.seed[3] == 0) {
		if (error != nullptr) {
			*error = "DuelConfig seed is all zeroes; OCG_CreateDuel rejects that";
		}
		return false;
	}

	config_ = config;
	parser_.reset_warnings();
	events_.reset();

	{
		std::lock_guard<std::mutex> lock(mutex_);
		stop_requested_ = false;
		has_response_ = false;
		response_.clear();
		init_state_ = InitState::PENDING;
		init_error_.clear();
	}

	worker_ = std::thread(&DuelThread::run, this);

	// Block only until the worker reports whether creation succeeded. That is bounded work
	// (OCG_CreateDuel plus OCG_DuelNewCard per card) and the caller needs a real answer.
	std::unique_lock<std::mutex> lock(mutex_);
	cv_.wait(lock, [this] { return init_state_ != InitState::PENDING; });

	if (init_state_ == InitState::FAILED) {
		const std::string detail = init_error_;
		lock.unlock();
		stop();
		if (error != nullptr) {
			*error = detail;
		}
		return false;
	}
	return true;
}

void DuelThread::stop() {
	{
		std::lock_guard<std::mutex> lock(mutex_);
		stop_requested_ = true;
	}
	// Wakes a worker parked in wait_for_response. Without this the thread would sit on the
	// condition variable forever and the join below would hang on shutdown.
	cv_.notify_all();

	if (worker_.joinable()) {
		worker_.join();
	}
}

bool DuelThread::is_running() const {
	return duel_live_.load(std::memory_order_acquire);
}

bool DuelThread::poll_event(Dictionary &out) {
	return events_.pop(out);
}

void DuelThread::send_response(const PackedByteArray &response) {
	std::vector<uint8_t> bytes(static_cast<std::size_t>(response.size()));
	for (int64_t i = 0; i < response.size(); ++i) {
		bytes[static_cast<std::size_t>(i)] = response[i];
	}
	{
		std::lock_guard<std::mutex> lock(mutex_);
		response_ = std::move(bytes);
		has_response_ = true;
	}
	cv_.notify_all();
}

bool DuelThread::stop_requested() const {
	std::lock_guard<std::mutex> lock(mutex_);
	return stop_requested_;
}

void DuelThread::run() {
	std::string error;
	const bool created = create_duel(&error) && load_init_scripts(&error) && populate_decks(&error);

	{
		std::lock_guard<std::mutex> lock(mutex_);
		init_state_ = created ? InitState::READY : InitState::FAILED;
		init_error_ = created ? std::string() : error;
	}
	cv_.notify_all();

	if (!created) {
		emit_error("start", error);
		if (duel_ != nullptr) {
			OCG_DestroyDuel(duel_);
			duel_ = nullptr;
		}
		return;
	}

	OCG_StartDuel(duel_);
	duel_live_.store(true, std::memory_order_release);
	emit_lifecycle(LifecycleEvent::DUEL_STARTED);

	process_loop();

	duel_live_.store(false, std::memory_order_release);
	emit_lifecycle(LifecycleEvent::DUEL_ENDED);

	// The handle is created, used and destroyed entirely on this thread (invariant V8).
	OCG_DestroyDuel(duel_);
	duel_ = nullptr;
}

bool DuelThread::create_duel(std::string *error) {
	OCG_DuelOptions options{};
	for (int i = 0; i < 4; ++i) {
		options.seed[i] = config_.seed[i];
	}
	options.flags = config_.flags;
	options.team1 = config_.team[0];
	options.team2 = config_.team[1];
	options.cardReader = &CardDB::card_reader;
	options.payload1 = config_.card_db;
	options.scriptReader = &ScriptVFS::script_reader;
	options.payload2 = config_.script_vfs;
	options.logHandler = &DuelThread::log_handler;
	options.payload3 = this;
	options.cardReaderDone = &CardDB::card_reader_done;
	options.payload4 = config_.card_db;
	options.enableUnsafeLibraries = 0;

	const int status = OCG_CreateDuel(&duel_, &options);
	if (status == OCG_DUEL_CREATION_SUCCESS && duel_ != nullptr) {
		return true;
	}

	if (error != nullptr) {
		switch (status) {
			case OCG_DUEL_CREATION_NULL_RNG_SEED:
				*error = "OCG_CreateDuel rejected an all-zero RNG seed";
				break;
			case OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API:
				*error = "Lua was not compiled as C++, so ocgcore cannot unwind through it "
						 "(AGENTS.md section 8.1)";
				break;
			case OCG_DUEL_CREATION_NULL_DATA_READER:
				*error = "card reader was null";
				break;
			case OCG_DUEL_CREATION_NULL_SCRIPT_READER:
				*error = "script reader was null";
				break;
			case OCG_DUEL_CREATION_NOT_CREATED:
				*error = "ocgcore could not allocate the duel";
				break;
			default:
				*error = "OCG_CreateDuel failed with status " + std::to_string(status);
				break;
		}
		if (!last_core_error_.empty()) {
			*error += ": " + last_core_error_;
		}
	}
	duel_ = nullptr;
	return false;
}

bool DuelThread::load_init_scripts(std::string *error) {
	for (const std::string &name : config_.init_scripts) {
		if (config_.script_vfs->load(duel_, name.c_str()) != 1) {
			if (error != nullptr) {
				*error = "could not load the library script '" + name + "'";
				if (!last_core_error_.empty()) {
					*error += ": " + last_core_error_;
				}
				*error += ". Card effects need the ProjectIgnis script collection; see docs/DATA.md";
			}
			return false;
		}
	}
	return true;
}

bool DuelThread::populate_decks(std::string *error) {
	if (config_.main_deck[0].empty() || config_.main_deck[1].empty()) {
		if (error != nullptr) {
			*error = "both teams need a non-empty main deck";
		}
		return false;
	}

	for (uint8_t team = 0; team < 2; ++team) {
		// ocgcore appends to the zone, so sequence 0 for every card preserves list order.
		for (const uint32_t code : config_.main_deck[team]) {
			OCG_NewCardInfo info{};
			info.team = team;
			info.duelist = 0;
			info.code = code;
			info.con = team;
			info.loc = LOCATION_DECK;
			info.seq = 0;
			info.pos = POS_FACEDOWN_DEFENSE;
			OCG_DuelNewCard(duel_, &info);
		}
		for (const uint32_t code : config_.extra_deck[team]) {
			OCG_NewCardInfo info{};
			info.team = team;
			info.duelist = 0;
			info.code = code;
			info.con = team;
			info.loc = LOCATION_EXTRA;
			info.seq = 0;
			info.pos = POS_FACEDOWN_DEFENSE;
			OCG_DuelNewCard(duel_, &info);
		}
	}
	return true;
}

void DuelThread::process_loop() {
	while (!stop_requested()) {
		const int status = OCG_DuelProcess(duel_);

		// Drain messages before acting on the status. A duel that is AWAITING is waiting on
		// a MSG_SELECT_* that is sitting in this very buffer, so the UI has to see it first.
		uint32_t length = 0;
		void *buffer = OCG_DuelGetMessage(duel_, &length);
		if (buffer != nullptr && length > 0) {
			if (!dispatch_messages(static_cast<uint8_t *>(buffer), length)) {
				return; // stop requested mid-drain
			}
		}

		if (status == OCG_DUEL_STATUS_END) {
			return;
		}
		if (status == OCG_DUEL_STATUS_AWAITING) {
			std::vector<uint8_t> response;
			if (!wait_for_response(response)) {
				return; // stop requested while parked
			}
			OCG_DuelSetResponse(duel_, response.data(), static_cast<uint32_t>(response.size()));
		}
	}
}

bool DuelThread::dispatch_messages(uint8_t *buffer, uint32_t length) {
	core_utils::PacketStream stream(buffer, length);
	for (const auto &packet : stream) {
		if (!emit(parser_.parse(packet))) {
			return false;
		}
	}
	return true;
}

bool DuelThread::wait_for_response(std::vector<uint8_t> &out) {
	std::unique_lock<std::mutex> lock(mutex_);
	cv_.wait(lock, [this] { return has_response_ || stop_requested_; });
	if (stop_requested_) {
		return false;
	}
	out = std::move(response_);
	response_.clear();
	has_response_ = false;
	return true;
}

bool DuelThread::emit(const Dictionary &event) {
	while (!events_.push(event)) {
		if (stop_requested()) {
			return false;
		}
		// Queue full: the main thread has not drained in a while. Back off rather than drop
		// the event; see QUEUE_BACKOFF above for why dropping is not acceptable.
		std::this_thread::sleep_for(QUEUE_BACKOFF);
	}
	return true;
}

void DuelThread::emit_lifecycle(LifecycleEvent type) {
	Dictionary event;
	event["t"] = static_cast<int32_t>(type);
	emit(event);
}

void DuelThread::emit_error(const char *stage, const std::string &detail) {
	Dictionary event;
	event["t"] = static_cast<int32_t>(LifecycleEvent::CORE_ERROR);
	event["stage"] = String::utf8(stage);
	event["detail"] = String::utf8(detail.c_str());
	emit(event);
}

void DuelThread::log_handler(void *payload, const char *message, int type) {
	auto *self = static_cast<DuelThread *>(payload);
	if (self == nullptr || message == nullptr) {
		return;
	}

	// Called from inside ocgcore, so always on the worker thread: this is the queue's single
	// producer, same as the message path.
	if (type == OCG_LOG_TYPE_ERROR) {
		self->last_core_error_ = message;
	}

	Dictionary event;
	event["t"] = static_cast<int32_t>(
			type == OCG_LOG_TYPE_ERROR ? LifecycleEvent::CORE_ERROR : LifecycleEvent::CORE_LOG);
	event["stage"] = String("core");
	event["detail"] = String::utf8(message);
	event["log_type"] = type;
	self->emit(event);
}

} // namespace kaiba
