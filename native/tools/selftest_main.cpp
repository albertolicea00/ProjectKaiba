// Standalone headless probe for the ocgcore build.
//
// Links ocgcore and Lua without Godot, so a failure here isolates the problem to the core
// build rather than to the GDExtension binding.
//
//   scons platform=macos target=template_debug arch=arm64 selftest=yes
//   ./build/macos.template_debug.arm64/kaiba_selftest

#include <cstdio>

#include "core_selftest.h"

int main() {
	const kaiba::SelftestResult result = kaiba::run_core_selftest();

	std::printf("ocgcore version : %d.%d (headers expect %d.%d)\n",
			result.core_major, result.core_minor,
			result.expected_major, result.expected_minor);
	std::printf("stage reached   : %s\n", result.stage.c_str());

	if (result.ok) {
		std::printf("result          : PASS\n");
		return 0;
	}

	std::printf("result          : FAIL\n");
	std::printf("detail          : %s\n", result.detail.c_str());
	return 1;
}
