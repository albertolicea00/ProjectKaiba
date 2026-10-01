#ifndef KAIBA_CORE_H
#define KAIBA_CORE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

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
};

} // namespace kaiba

#endif // KAIBA_CORE_H
