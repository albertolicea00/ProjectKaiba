#include "kaiba_core.h"

#include "core_selftest.h"

#include <random>
#include <string>

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <ocgapi.h>

using godot::ClassDB;
using godot::D_METHOD;
using godot::Dictionary;
using godot::PackedByteArray;
using godot::PackedInt32Array;
using godot::PackedInt64Array;
using godot::ProjectSettings;
using godot::String;
using godot::Variant;

namespace kaiba {

void KaibaCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_core_version"), &KaibaCore::get_core_version);
	ClassDB::bind_method(D_METHOD("get_build_info"), &KaibaCore::get_build_info);
	ClassDB::bind_method(D_METHOD("run_selftest"), &KaibaCore::run_selftest);

	ClassDB::bind_method(D_METHOD("load_card_database", "path"), &KaibaCore::load_card_database);
	ClassDB::bind_method(D_METHOD("add_script_root", "path"), &KaibaCore::add_script_root);
	ClassDB::bind_method(D_METHOD("start_duel", "config"), &KaibaCore::start_duel);
	ClassDB::bind_method(D_METHOD("poll_event"), &KaibaCore::poll_event);
	ClassDB::bind_method(D_METHOD("send_response", "response"), &KaibaCore::send_response);
	ClassDB::bind_method(D_METHOD("end_duel"), &KaibaCore::end_duel);
	ClassDB::bind_method(D_METHOD("is_duel_running"), &KaibaCore::is_duel_running);
}

namespace {

/// Turns a Godot path into something the C++ standard library can open.
/// res:// and user:// mean nothing outside the engine.
std::string to_native_path(const String &path) {
	return std::string(ProjectSettings::get_singleton()->globalize_path(path).utf8().get_data());
}

/// Reads a PackedInt32Array of card codes out of a config Dictionary.
std::vector<uint32_t> read_decklist(const Dictionary &config, const char *key) {
	std::vector<uint32_t> codes;
	if (!config.has(key)) {
		return codes;
	}
	const PackedInt32Array source = config[key];
	codes.reserve(static_cast<std::size_t>(source.size()));
	for (int64_t i = 0; i < source.size(); ++i) {
		codes.push_back(static_cast<uint32_t>(source[i]));
	}
	return codes;
}

} // namespace

Dictionary KaibaCore::get_core_version() const {
	int major = 0;
	int minor = 0;
	OCG_GetVersion(&major, &minor);

	Dictionary version;
	version["major"] = major;
	version["minor"] = minor;
	return version;
}

Dictionary KaibaCore::get_build_info() const {
	Dictionary info;

#if defined(__ANDROID__)
	info["platform"] = "android";
#elif defined(__APPLE__)
	info["platform"] = "macos";
#elif defined(_WIN32)
	info["platform"] = "windows";
#elif defined(__linux__)
	info["platform"] = "linux";
#else
	info["platform"] = "unknown";
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
	info["arch"] = "arm64";
#elif defined(__arm__) || defined(_M_ARM)
	info["arch"] = "arm32";
#elif defined(__x86_64__) || defined(_M_X64)
	info["arch"] = "x86_64";
#else
	info["arch"] = "unknown";
#endif

#if defined(__clang__)
	info["compiler"] = String("clang ") + String::utf8(__clang_version__);
#elif defined(__GNUC__)
	info["compiler"] = String("gcc ") + String::utf8(__VERSION__);
#else
	info["compiler"] = "unknown";
#endif

	// If this is false the build is broken: ocgcore raises Lua errors as C++ exceptions.
	// See AGENTS.md section 8.1.
#if defined(__cpp_exceptions)
	info["exceptions"] = true;
#else
	info["exceptions"] = false;
#endif

	info["build_date"] = String::utf8(__DATE__) + " " + String::utf8(__TIME__);
	return info;
}

Dictionary KaibaCore::run_selftest() const {
	const SelftestResult result = run_core_selftest();

	Dictionary out;
	out["ok"] = result.ok;
	out["stage"] = String::utf8(result.stage.c_str());
	out["detail"] = String::utf8(result.detail.c_str());
	out["core_version"] = String::num_int64(result.core_major) + "." + String::num_int64(result.core_minor);
	out["expected_version"] = String::num_int64(result.expected_major) + "." + String::num_int64(result.expected_minor);
	return out;
}

Dictionary KaibaCore::load_card_database(const String &path) {
	Dictionary result;
	std::string error;
	const bool ok = card_db_.open(to_native_path(path), &error);

	result["ok"] = ok;
	result["count"] = static_cast<int64_t>(card_db_.card_count());
	result["error"] = ok ? String() : String::utf8(error.c_str());
	return result;
}

void KaibaCore::add_script_root(const String &path) {
	script_vfs_.add_root(to_native_path(path));
}

Dictionary KaibaCore::start_duel(const Dictionary &config) {
	Dictionary result;

	if (duel_thread_ && duel_thread_->is_running()) {
		result["ok"] = false;
		result["error"] = "a duel is already running; call end_duel() first";
		return result;
	}

	DuelConfig duel_config;

	if (config.has("seed")) {
		const PackedInt64Array seed = config["seed"];
		for (int i = 0; i < 4 && i < seed.size(); ++i) {
			duel_config.seed[i] = static_cast<uint64_t>(seed[i]);
		}
	} else {
		// A reproducible duel needs a recorded seed, so generate one here and hand it back:
		// the replay writer stores exactly these four words (ARCHITECTURE.md section 7).
		std::random_device device;
		std::uniform_int_distribution<uint64_t> distribution;
		std::mt19937_64 engine(device());
		for (int i = 0; i < 4; ++i) {
			duel_config.seed[i] = distribution(engine);
		}
		// Guard against the astronomically unlikely all-zero draw, which ocgcore rejects.
		duel_config.seed[0] |= 1ull;
	}

	duel_config.flags = config.has("flags") ? static_cast<uint64_t>(static_cast<int64_t>(config["flags"])) : 0ull;

	const uint32_t start_lp = config.has("start_lp") ? static_cast<uint32_t>(static_cast<int64_t>(config["start_lp"])) : 8000u;
	const uint32_t start_hand = config.has("start_hand") ? static_cast<uint32_t>(static_cast<int64_t>(config["start_hand"])) : 5u;
	const uint32_t draw_count = config.has("draw_count") ? static_cast<uint32_t>(static_cast<int64_t>(config["draw_count"])) : 1u;
	for (int team = 0; team < 2; ++team) {
		duel_config.team[team] = OCG_Player{ start_lp, start_hand, draw_count };
	}

	duel_config.main_deck[0] = read_decklist(config, "deck_p0");
	duel_config.extra_deck[0] = read_decklist(config, "extra_p0");
	duel_config.main_deck[1] = read_decklist(config, "deck_p1");
	duel_config.extra_deck[1] = read_decklist(config, "extra_p1");

	duel_config.card_db = &card_db_;
	duel_config.script_vfs = &script_vfs_;

	duel_thread_ = std::make_unique<DuelThread>();
	std::string error;
	if (!duel_thread_->start(duel_config, &error)) {
		duel_thread_.reset();
		result["ok"] = false;
		result["error"] = String::utf8(error.c_str());
		return result;
	}

	PackedInt64Array used_seed;
	for (int i = 0; i < 4; ++i) {
		used_seed.push_back(static_cast<int64_t>(duel_config.seed[i]));
	}
	result["ok"] = true;
	result["error"] = String();
	result["seed"] = used_seed;
	return result;
}

Variant KaibaCore::poll_event() {
	if (!duel_thread_) {
		return Variant();
	}
	Dictionary event;
	if (!duel_thread_->poll_event(event)) {
		return Variant();
	}
	return event;
}

void KaibaCore::send_response(const PackedByteArray &response) {
	if (duel_thread_) {
		duel_thread_->send_response(response);
	}
}

void KaibaCore::end_duel() {
	if (duel_thread_) {
		duel_thread_->stop();
		duel_thread_.reset();
	}
}

bool KaibaCore::is_duel_running() const {
	return duel_thread_ && duel_thread_->is_running();
}

} // namespace kaiba
