#include "core_selftest.h"

#include <cstring>

#include <ocgapi.h>
#include <ocgapi_types.h>

namespace kaiba {
namespace {

/// Zero-terminated empty setcode list. The selftest never creates cards, but handing
/// ocgcore a null setcodes pointer would be a trap if that ever changes.
uint16_t g_no_setcodes[1] = { 0 };

void stub_card_reader(void* /*payload*/, uint32_t code, OCG_CardData* data) {
	if (data == nullptr) {
		return;
	}
	std::memset(data, 0, sizeof(OCG_CardData));
	data->code = code;
	data->setcodes = g_no_setcodes;
}

void stub_card_reader_done(void* /*payload*/, OCG_CardData* /*data*/) {}

int stub_script_reader(void* /*payload*/, OCG_Duel /*duel*/, const char* /*name*/) {
	// No card scripts are mounted during the selftest.
	return 0;
}

void capture_log(void* payload, const char* message, int type) {
	if (payload == nullptr || message == nullptr || type != OCG_LOG_TYPE_ERROR) {
		return;
	}
	*static_cast<std::string*>(payload) = message;
}

const char* describe_creation_status(int status) {
	switch (status) {
		case OCG_DUEL_CREATION_SUCCESS:
			return "success";
		case OCG_DUEL_CREATION_NO_OUTPUT:
			return "no output pointer was given";
		case OCG_DUEL_CREATION_NOT_CREATED:
			return "allocation failed";
		case OCG_DUEL_CREATION_NULL_DATA_READER:
			return "card reader was null";
		case OCG_DUEL_CREATION_NULL_SCRIPT_READER:
			return "script reader was null";
		case OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API:
			return "Lua was not compiled as C++, so ocgcore cannot unwind through it "
				   "(see AGENTS.md section 8.1)";
		case OCG_DUEL_CREATION_NULL_RNG_SEED:
			return "RNG seed was all zeroes";
		default:
			return "unknown creation status";
	}
}

} // namespace

SelftestResult run_core_selftest() {
	SelftestResult result;
	result.expected_major = OCG_VERSION_MAJOR;
	result.expected_minor = OCG_VERSION_MINOR;
	result.stage = "version";

	OCG_GetVersion(&result.core_major, &result.core_minor);
	if (result.core_major != OCG_VERSION_MAJOR || result.core_minor != OCG_VERSION_MINOR) {
		result.detail = "The linked ocgcore reports a different version than the headers "
						"this binary was compiled against.";
		return result;
	}

	std::string core_error;

	OCG_DuelOptions options;
	std::memset(&options, 0, sizeof(options));
	// Any non-zero seed will do here; OCG_CreateDuel rejects an all-zero one.
	options.seed[0] = 0x4b414942ull;
	options.seed[1] = 0x41434f52ull;
	options.seed[2] = 0x53454c46ull;
	options.seed[3] = 0x54455354ull;
	options.flags = 0;
	options.team1 = OCG_Player{ 8000u, 5u, 1u };
	options.team2 = OCG_Player{ 8000u, 5u, 1u };
	options.cardReader = &stub_card_reader;
	options.scriptReader = &stub_script_reader;
	options.logHandler = &capture_log;
	options.payload3 = &core_error;
	options.cardReaderDone = &stub_card_reader_done;
	options.enableUnsafeLibraries = 0;

	result.stage = "create_duel";
	OCG_Duel duel = nullptr;
	const int status = OCG_CreateDuel(&duel, &options);
	if (status != OCG_DUEL_CREATION_SUCCESS || duel == nullptr) {
		result.detail = describe_creation_status(status);
		if (!core_error.empty()) {
			result.detail += ": " + core_error;
		}
		return result;
	}

	result.stage = "load_script";
	// Exercises luaL_loadbuffer and lua_pcall inside the duel's own Lua state.
	static const char probe[] = "local a = 1 + 1 if a ~= 2 then error('arithmetic is broken') end";
	const int loaded = OCG_LoadScript(
			duel, probe, static_cast<uint32_t>(sizeof(probe) - 1), "kaiba_selftest.lua");
	OCG_DestroyDuel(duel);

	if (loaded != 1) {
		result.detail = core_error.empty()
				? "OCG_LoadScript failed without reporting an error"
				: core_error;
		return result;
	}

	result.stage = "done";
	result.ok = true;
	return result;
}

} // namespace kaiba
