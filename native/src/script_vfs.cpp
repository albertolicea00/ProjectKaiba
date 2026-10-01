#include "script_vfs.h"

#include <fstream>

#include <ocgapi.h>

namespace kaiba {
namespace {

/// Accepted on every platform: Windows CRT functions take '/' too, and a cdb-era script
/// path may use either separator depending on who produced it.
const char PATH_SEPARATORS[] = "/\\";

std::string join_path(const std::string& dir, const std::string& file) {
	if (dir.empty()) {
		return file;
	}
	const char last = dir[dir.size() - 1];
	if (last == '/' || last == '\\') {
		return dir + file;
	}
	return dir + "/" + file;
}

} // namespace

std::string ScriptVFS::base_name(const std::string& name) {
	const size_t cut = name.find_last_of(PATH_SEPARATORS);
	if (cut == std::string::npos) {
		return name;
	}
	return name.substr(cut + 1);
}

void ScriptVFS::add_root(const std::string& dir) {
	if (dir.empty()) {
		return;
	}
	std::lock_guard<std::mutex> lock(m_mutex);
	m_roots.push_back(dir);
	// A root added after a lookup can shadow or supply a name already decided on, so every
	// previous answer - including the cached misses - is now suspect.
	m_cache.clear();
}

void ScriptVFS::clear_roots() {
	std::lock_guard<std::mutex> lock(m_mutex);
	m_roots.clear();
	m_cache.clear();
}

void ScriptVFS::clear_cache() {
	std::lock_guard<std::mutex> lock(m_mutex);
	m_cache.clear();
}

size_t ScriptVFS::root_count() const {
	std::lock_guard<std::mutex> lock(m_mutex);
	return m_roots.size();
}

size_t ScriptVFS::cache_size() const {
	std::lock_guard<std::mutex> lock(m_mutex);
	return m_cache.size();
}

bool ScriptVFS::read_file(const std::string& path, std::vector<char>& out) {
	out.clear();

	std::ifstream file(path.c_str(), std::ios::binary | std::ios::ate);
	if (!file) {
		return false;
	}

	const std::streamoff size = file.tellg();
	if (size < 0) {
		return false;
	}
	file.seekg(0, std::ios::beg);
	if (!file) {
		return false;
	}

	out.resize(static_cast<size_t>(size));
	if (!out.empty() && !file.read(out.data(), static_cast<std::streamsize>(size))) {
		out.clear();
		return false;
	}

	// Lua 5.4 skips a BOM in luaL_loadfile but not in luaL_loadbuffer, which is the path
	// OCG_LoadScript takes. Leaving one in place turns the script into a syntax error.
	// EDOPro strips it in Game::ReadScript for the same reason.
	if (out.size() >= 3 && static_cast<unsigned char>(out[0]) == 0xEF
			&& static_cast<unsigned char>(out[1]) == 0xBB
			&& static_cast<unsigned char>(out[2]) == 0xBF) {
		out.erase(out.begin(), out.begin() + 3);
	}

	return true;
}

const std::vector<char>* ScriptVFS::find(const std::string& name) {
	if (name.empty()) {
		return nullptr;
	}
	const std::string key = base_name(name);
	if (key.empty()) {
		// The name was nothing but a directory path.
		return nullptr;
	}

	std::lock_guard<std::mutex> lock(m_mutex);

	const auto cached = m_cache.find(key);
	if (cached != m_cache.end()) {
		return cached->second.found ? &cached->second.data : nullptr;
	}

	CacheEntry entry;
	for (const std::string& root : m_roots) {
		if (read_file(join_path(root, key), entry.data)) {
			entry.found = true;
			break;
		}
	}

	// Misses are cached too. ocgcore retries a failed card script on every summon attempt,
	// and a missing script is a stat() syscall per retry otherwise.
	CacheEntry& stored = m_cache.emplace(key, std::move(entry)).first->second;
	return stored.found ? &stored.data : nullptr;
}

int ScriptVFS::load(OCG_Duel duel, const char* name) {
	if (duel == nullptr || name == nullptr || name[0] == '\0') {
		return 0;
	}

	// Resolved and released before OCG_LoadScript runs: the chunk executes Lua, which can
	// ask for another script, which re-enters this function. Holding the cache mutex across
	// the call would deadlock on the second request.
	const std::vector<char>* buffer = find(name);
	if (buffer == nullptr || buffer->empty()) {
		return 0;
	}

	// `name` is passed through unmodified so that Lua error messages quote the name ocgcore
	// asked for, not our normalised key.
	return OCG_LoadScript(duel, buffer->data(), static_cast<uint32_t>(buffer->size()), name);
}

int ScriptVFS::script_reader(void* payload, OCG_Duel duel, const char* name) {
	ScriptVFS* vfs = static_cast<ScriptVFS*>(payload);
	if (vfs == nullptr) {
		return 0;
	}
	return vfs->load(duel, name);
}

} // namespace kaiba
