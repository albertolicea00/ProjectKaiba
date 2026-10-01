#ifndef KAIBA_CORE_SELFTEST_H
#define KAIBA_CORE_SELFTEST_H

#include <string>

namespace kaiba {

/// Outcome of the Phase 0 toolchain probe.
struct SelftestResult {
	bool ok = false;
	int core_major = 0;
	int core_minor = 0;
	int expected_major = 0;
	int expected_minor = 0;
	/// Last stage reached: "version", "create_duel", "load_script" or "done".
	std::string stage;
	/// Human-readable explanation. Empty when ok is true.
	std::string detail;
};

/// Creates a throwaway duel, runs a trivial Lua chunk inside it and tears it down.
///
/// This proves four things that a plain OCG_GetVersion() call does not:
///   - ocgcore is linked and its symbols resolve
///   - Lua was compiled as C++ (ocgcore refuses to start otherwise)
///   - the Lua state initialises and executes bytecode
///   - C++ exceptions survive the ocgcore boundary
///
/// Allocates and frees exactly one duel. Safe to call from any thread.
SelftestResult run_core_selftest();

} // namespace kaiba

#endif // KAIBA_CORE_SELFTEST_H
