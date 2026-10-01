#include "kaiba_core.h"

#include "core_selftest.h"

#include <godot_cpp/core/class_db.hpp>

#include <ocgapi.h>

using godot::ClassDB;
using godot::D_METHOD;
using godot::Dictionary;
using godot::String;

namespace kaiba {

void KaibaCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_core_version"), &KaibaCore::get_core_version);
	ClassDB::bind_method(D_METHOD("get_build_info"), &KaibaCore::get_build_info);
	ClassDB::bind_method(D_METHOD("run_selftest"), &KaibaCore::run_selftest);
}

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

} // namespace kaiba
