#ifndef KAIBA_SCRIPT_VFS_H
#define KAIBA_SCRIPT_VFS_H

#include <cstddef>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <ocgapi_types.h>

namespace kaiba {

/// Resolves ocgcore's script requests against an ordered list of directories.
///
/// ocgcore asks for a script by bare file name - `"c12345678.lua"` from
/// `interpreter::load_card_script`, plus whatever we load ourselves at duel setup
/// (`"constant.lua"`, `"utility.lua"`). It has no concept of directories, so the search
/// order is entirely ours: roots are tried in insertion order and the first hit wins. That
/// is what lets a mounted pack shadow a base script (docs/DATA.md, "Layout").
///
/// Contents are cached after the first successful read, including misses, because the same
/// handful of procedure scripts is requested over and over within a duel and across duels.
///
/// Thread safety: `script_reader` is called from a duel thread (invariant V8), and several
/// duels may share one instance, so the cache is mutex-guarded. `add_root`, `clear_roots`
/// and `clear_cache` are not safe to call while a duel exists - they invalidate buffers the
/// duel threads may still be reading.
class ScriptVFS {
public:
	ScriptVFS() = default;
	ScriptVFS(const ScriptVFS&) = delete;
	ScriptVFS& operator=(const ScriptVFS&) = delete;
	ScriptVFS(ScriptVFS&&) = delete;
	ScriptVFS& operator=(ScriptVFS&&) = delete;

	/// Appends a search root. Later roots are only consulted when the earlier ones miss.
	/// An empty string is ignored. Drops the cache, since a new root can change what an
	/// already-resolved name points at.
	void add_root(const std::string& dir);

	void clear_roots();

	/// Forgets every cached file and every cached miss.
	void clear_cache();

	size_t root_count() const;

	/// Number of distinct names resolved so far, hits and misses together.
	size_t cache_size() const;

	/// Reads `name`, through the cache. Returns null when no root holds it.
	///
	/// The returned buffer is owned by this object and stays valid until `clear_cache()`,
	/// `clear_roots()`, `add_root()` or destruction. It is the file's bytes with a leading
	/// UTF-8 BOM removed; Lua's `luaL_loadbuffer` does not skip one and would report a
	/// syntax error on the first character.
	const std::vector<char>* find(const std::string& name);

	/// Reads `name` and hands it to `OCG_LoadScript`. Returns 1 on success, 0 on failure or
	/// when the file is not found.
	int load(OCG_Duel duel, const char* name);

	/// `OCG_DuelOptions::scriptReader`. `payload` is a `ScriptVFS*`.
	/// Returns 0 rather than crashing when `payload` or `name` is null.
	static int script_reader(void* payload, OCG_Duel duel, const char* name);

	/// Strips any leading directory from `name`, EDOPro style, and returns the bare file
	/// name used as the lookup key. `"./script/c1.lua"` and `"script\\c1.lua"` both become
	/// `"c1.lua"`. Exposed so tests can assert the normalisation directly.
	static std::string base_name(const std::string& name);

private:
	struct CacheEntry {
		bool found = false;
		std::vector<char> data;
	};

	/// Reads one file into `out`. Returns false if it cannot be opened or read whole.
	static bool read_file(const std::string& path, std::vector<char>& out);

	mutable std::mutex m_mutex;
	std::vector<std::string> m_roots;
	/// Keyed by the normalised bare file name. Node-based, so a pointer handed to a duel
	/// thread survives the rehash caused by another thread caching a different script.
	std::unordered_map<std::string, CacheEntry> m_cache;
};

} // namespace kaiba

#endif // KAIBA_SCRIPT_VFS_H
