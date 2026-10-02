// Standalone test for the two ocgcore data callbacks.
//
// There is no cards.cdb on a fresh clone (docs/DATA.md: nothing under data/ is versioned),
// so this builds its own: a temporary SQLite file with the documented datas/texts schema and
// a handful of synthetic rows chosen to exercise every packed column - a Link monster, a
// Pendulum monster, a four-setcode row, a "?"-level row and a row full of SQL NULLs.
//
// It then writes a throwaway script tree and drives ScriptVFS through a real OCG_Duel, so
// the script path is checked end to end rather than mocked.
//
//   scons platform=macos target=template_debug arch=arm64 datatest=yes
//   ./build/macos.template_debug.arm64/kaiba_data_test
//
// Everything it creates lives under a temp directory and is deleted on the way out.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#include <ocgapi.h>
#include <ocgapi_constants.h>
#include <ocgapi_types.h>
#include <sqlite3.h>

#include "card_db.h"
#include "script_vfs.h"

namespace {

int g_checks = 0;
int g_failures = 0;

void check(bool condition, const char* what) {
	++g_checks;
	if (condition) {
		return;
	}
	++g_failures;
	std::printf("  FAIL  %s\n", what);
}

template <typename T>
void check_eq(T actual, T expected, const char* what) {
	++g_checks;
	if (actual == expected) {
		return;
	}
	++g_failures;
	std::printf("  FAIL  %s: got %lld, expected %lld\n", what,
			static_cast<long long>(actual), static_cast<long long>(expected));
}

void check_str(const std::string& actual, const std::string& expected, const char* what) {
	++g_checks;
	if (actual == expected) {
		return;
	}
	++g_failures;
	std::printf("  FAIL  %s: got '%s', expected '%s'\n", what, actual.c_str(), expected.c_str());
}

// ---------------------------------------------------------------------------------------
// Synthetic card codes and their packed values
// ---------------------------------------------------------------------------------------

// Plain Effect Monster, four setcodes, one of which is a zero hole in the middle.
const uint32_t CODE_NORMAL = 10000001u;
// setcode slots, low 16 bits first: 0x1234, hole, 0x00AB, 0x5678.
const int64_t SETCODE_NORMAL = static_cast<int64_t>(0x5678'00AB'0000'1234ull);
// level 4, no scales.
const int32_t LEVEL_NORMAL = 4;

// Pendulum Monster: level 7, left scale 8, right scale 3.
const uint32_t CODE_PENDULUM = 10000002u;
const int32_t LEVEL_PENDULUM = static_cast<int32_t>((8u << 24) | (3u << 16) | 7u);

// Link Monster: datas.def carries the marker bitmask, not a defence value.
const uint32_t CODE_LINK = 10000003u;
// Bottom-left, bottom, bottom-right.
const int32_t LINK_MARKERS = LINK_MARKER_BOTTOM_LEFT | LINK_MARKER_BOTTOM | LINK_MARKER_BOTTOM_RIGHT;

// "?" level: datas.level is negative.
const uint32_t CODE_QUESTION = 10000004u;
const int32_t LEVEL_QUESTION = -4;

// Every text column is SQL NULL.
const uint32_t CODE_NULLS = 10000005u;

// ---------------------------------------------------------------------------------------
// Temp directory plumbing
// ---------------------------------------------------------------------------------------

std::string g_temp_dir;

bool run_sql(sqlite3* db, const char* sql) {
	char* error = nullptr;
	if (sqlite3_exec(db, sql, nullptr, nullptr, &error) == SQLITE_OK) {
		return true;
	}
	std::printf("  SQL error: %s\n", error != nullptr ? error : "(none)");
	sqlite3_free(error);
	return false;
}

bool write_file(const std::string& path, const std::string& contents) {
	std::FILE* file = std::fopen(path.c_str(), "wb");
	if (file == nullptr) {
		return false;
	}
	const size_t written = contents.empty()
			? 0
			: std::fwrite(contents.data(), 1, contents.size(), file);
	std::fclose(file);
	return written == contents.size();
}

/// Builds the cdb this test reads back. Mirrors the column names in docs/DATA.md; the
/// physical types are SQLite's usual INTEGER/TEXT, which is what BabelCDB ships.
bool create_test_cdb(const std::string& path) {
	sqlite3* db = nullptr;
	if (sqlite3_open_v2(path.c_str(), &db,
				SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr) != SQLITE_OK) {
		std::printf("  cannot create %s\n", path.c_str());
		sqlite3_close(db);
		return false;
	}

	bool ok = run_sql(db,
			"CREATE TABLE datas ("
			"id INTEGER PRIMARY KEY, ot INTEGER, alias INTEGER, setcode INTEGER,"
			"type INTEGER, atk INTEGER, def INTEGER, level INTEGER, race INTEGER,"
			"attribute INTEGER, category INTEGER);"
			"CREATE TABLE texts ("
			"id INTEGER PRIMARY KEY, name TEXT, desc TEXT,"
			"str1 TEXT, str2 TEXT, str3 TEXT, str4 TEXT, str5 TEXT, str6 TEXT, str7 TEXT,"
			"str8 TEXT, str9 TEXT, str10 TEXT, str11 TEXT, str12 TEXT, str13 TEXT,"
			"str14 TEXT, str15 TEXT, str16 TEXT);");

	sqlite3_stmt* datas = nullptr;
	sqlite3_stmt* texts = nullptr;
	if (ok) {
		ok = sqlite3_prepare_v2(db,
					   "INSERT INTO datas VALUES (?,?,?,?,?,?,?,?,?,?,?);", -1, &datas, nullptr)
				== SQLITE_OK;
	}
	if (ok) {
		ok = sqlite3_prepare_v2(db,
					   "INSERT INTO texts (id,name,desc,str1,str16) VALUES (?,?,?,?,?);",
					   -1, &texts, nullptr)
				== SQLITE_OK;
	}

	struct Row {
		uint32_t id;
		int64_t ot;
		int64_t alias;
		int64_t setcode;
		int64_t type;
		int32_t atk;
		int32_t def;
		int32_t level;
		int64_t race;
		int64_t attribute;
		int64_t category;
		const char* name;
		const char* desc;
		const char* str1;
		const char* str16;
	};

	// race is deliberately a value that does not fit in 32 bits on one row: OCG core v11
	// widened it to uint64_t and a 32-bit read would truncate it silently.
	const Row rows[] = {
		{ CODE_NORMAL, 3, 0, SETCODE_NORMAL, TYPE_MONSTER | TYPE_EFFECT, 1800, 1500,
				LEVEL_NORMAL, RACE_WARRIOR, ATTRIBUTE_EARTH, 0x10,
				"Kaiba Test Warrior", "Does nothing at all.", "Effect one", "Effect sixteen" },
		{ CODE_PENDULUM, 1, 0, 0x00000000'0000'9999ll,
				TYPE_MONSTER | TYPE_EFFECT | TYPE_PENDULUM, 2500, 2000,
				LEVEL_PENDULUM, RACE_SPELLCASTER, ATTRIBUTE_DARK, 0,
				"Kaiba Test Pendulum", "Scale 8 / 3.", "", "" },
		{ CODE_LINK, 1, 0, 0, TYPE_MONSTER | TYPE_EFFECT | TYPE_LINK, 2300, LINK_MARKERS,
				3, static_cast<int64_t>(RACE_CYBERSE), ATTRIBUTE_LIGHT, 0,
				"Kaiba Test Link", "Three arrows.", "", "" },
		{ CODE_QUESTION, 1, CODE_NORMAL, 0, TYPE_MONSTER, 0, 0, LEVEL_QUESTION,
				static_cast<int64_t>(1ull << 40), ATTRIBUTE_WIND, 0,
				"Kaiba Test Question", "Level ?.", "", "" },
		{ CODE_NULLS, 0, 0, 0, TYPE_SPELL, 0, 0, 0, 0, 0, 0, nullptr, nullptr, nullptr, nullptr },
	};

	for (const Row& row : rows) {
		if (!ok) {
			break;
		}
		sqlite3_reset(datas);
		sqlite3_bind_int64(datas, 1, row.id);
		sqlite3_bind_int64(datas, 2, row.ot);
		sqlite3_bind_int64(datas, 3, row.alias);
		sqlite3_bind_int64(datas, 4, row.setcode);
		sqlite3_bind_int64(datas, 5, row.type);
		sqlite3_bind_int(datas, 6, row.atk);
		sqlite3_bind_int(datas, 7, row.def);
		sqlite3_bind_int(datas, 8, row.level);
		sqlite3_bind_int64(datas, 9, row.race);
		sqlite3_bind_int64(datas, 10, row.attribute);
		sqlite3_bind_int64(datas, 11, row.category);
		ok = sqlite3_step(datas) == SQLITE_DONE;

		if (!ok) {
			break;
		}
		sqlite3_reset(texts);
		sqlite3_bind_int64(texts, 1, row.id);
		// A null pointer binds as SQL NULL, which is the case CardDB must survive.
		if (row.name != nullptr) {
			sqlite3_bind_text(texts, 2, row.name, -1, SQLITE_TRANSIENT);
			sqlite3_bind_text(texts, 3, row.desc, -1, SQLITE_TRANSIENT);
			sqlite3_bind_text(texts, 4, row.str1, -1, SQLITE_TRANSIENT);
			sqlite3_bind_text(texts, 5, row.str16, -1, SQLITE_TRANSIENT);
		}
		ok = sqlite3_step(texts) == SQLITE_DONE;
	}

	sqlite3_finalize(datas);
	sqlite3_finalize(texts);
	sqlite3_close(db);

	if (!ok) {
		std::printf("  failed to populate the synthetic cdb\n");
	}
	return ok;
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

void test_card_db(const std::string& cdb_path) {
	std::printf("CardDB\n");

	kaiba::CardDB db;
	std::string error;
	if (!db.open(cdb_path, &error)) {
		std::printf("  FAIL  open: %s\n", error.c_str());
		++g_failures;
		++g_checks;
		return;
	}
	check_eq<size_t>(db.card_count(), 5, "card_count");
	check(db.is_loaded(), "is_loaded");

	// --- packed setcode column ---------------------------------------------------------
	const OCG_CardData* normal = db.find(CODE_NORMAL);
	check(normal != nullptr, "normal monster is present");
	if (normal != nullptr) {
		check_eq<uint32_t>(normal->code, CODE_NORMAL, "normal.code");
		check_eq<int32_t>(normal->attack, 1800, "normal.attack");
		check_eq<int32_t>(normal->defense, 1500, "normal.defense");
		check_eq<uint32_t>(normal->link_marker, 0, "normal.link_marker");
		check_eq<uint32_t>(normal->level, 4, "normal.level");
		check_eq<uint32_t>(normal->lscale, 0, "normal.lscale");
		check_eq<uint32_t>(normal->rscale, 0, "normal.rscale");
		check_eq<uint64_t>(normal->race, RACE_WARRIOR, "normal.race");
		check_eq<uint32_t>(normal->attribute, ATTRIBUTE_EARTH, "normal.attribute");
		check(normal->setcodes != nullptr, "normal.setcodes is not null");
		if (normal->setcodes != nullptr) {
			// The zero in slot 1 is a hole, not a terminator: it must be dropped, and the
			// two setcodes after it must survive.
			check_eq<uint16_t>(normal->setcodes[0], 0x1234, "normal.setcodes[0]");
			check_eq<uint16_t>(normal->setcodes[1], 0x00AB, "normal.setcodes[1]");
			check_eq<uint16_t>(normal->setcodes[2], 0x5678, "normal.setcodes[2]");
			check_eq<uint16_t>(normal->setcodes[3], 0, "normal.setcodes is zero-terminated");
		}
	}

	// --- packed level column -----------------------------------------------------------
	const OCG_CardData* pendulum = db.find(CODE_PENDULUM);
	check(pendulum != nullptr, "pendulum is present");
	if (pendulum != nullptr) {
		check_eq<uint32_t>(pendulum->level, 7, "pendulum.level");
		check_eq<uint32_t>(pendulum->lscale, 8, "pendulum.lscale");
		check_eq<uint32_t>(pendulum->rscale, 3, "pendulum.rscale");
		check_eq<int32_t>(pendulum->defense, 2000, "pendulum.defense");
		check_eq<uint32_t>(pendulum->link_marker, 0, "pendulum.link_marker");
		check(pendulum->setcodes != nullptr && pendulum->setcodes[0] == 0x9999
						&& pendulum->setcodes[1] == 0,
				"pendulum has exactly one setcode");
	}

	// --- overloaded def column ---------------------------------------------------------
	const OCG_CardData* link = db.find(CODE_LINK);
	check(link != nullptr, "link monster is present");
	if (link != nullptr) {
		check_eq<uint32_t>(link->link_marker, static_cast<uint32_t>(LINK_MARKERS),
				"link.link_marker comes from datas.def");
		check_eq<int32_t>(link->defense, 0, "link.defense is zeroed");
		check_eq<int32_t>(link->attack, 2300, "link.attack");
		check_eq<uint32_t>(link->level, 3, "link.level holds the link rating");
		check(link->setcodes != nullptr && link->setcodes[0] == 0,
				"link has an empty but valid setcode list");
	}

	// --- negative level ----------------------------------------------------------------
	const OCG_CardData* question = db.find(CODE_QUESTION);
	check(question != nullptr, "'?' level card is present");
	if (question != nullptr) {
		// EDOPro negates the low byte, not the stored value: -4 becomes -252. Faithfully
		// odd; see the comment in card_db.cpp.
		const uint32_t expected = static_cast<uint32_t>(-static_cast<int32_t>(
				static_cast<uint32_t>(LEVEL_QUESTION) & 0xffu));
		check_eq<uint32_t>(question->level, expected, "question.level is the negated low byte");
		check_eq<uint32_t>(question->alias, CODE_NORMAL, "question.alias");
		// 1 << 40 does not survive a 32-bit read.
		check_eq<uint64_t>(question->race, 1ull << 40, "question.race keeps all 64 bits");
	}

	// --- client-side-only columns ------------------------------------------------------
	const kaiba::CardText* text = db.find_text(CODE_NORMAL);
	check(text != nullptr, "normal monster has text");
	if (text != nullptr) {
		check_str(text->name, "Kaiba Test Warrior", "text.name");
		check_str(text->desc, "Does nothing at all.", "text.desc");
		check_str(text->strings[0], "Effect one", "text.str1");
		check_str(text->strings[15], "Effect sixteen", "text.str16");
		check_eq<uint32_t>(text->ot, 3, "text.ot");
		check_eq<uint32_t>(text->category, 0x10, "text.category");
	}

	const kaiba::CardText* nulls = db.find_text(CODE_NULLS);
	check(nulls != nullptr, "all-NULL row has a text entry");
	if (nulls != nullptr) {
		check(nulls->name.empty() && nulls->desc.empty() && nulls->strings[0].empty(),
				"SQL NULL text becomes an empty string, not a crash");
	}

	// --- callbacks ---------------------------------------------------------------------
	OCG_CardData data;
	std::memset(&data, 0xAA, sizeof(data));
	kaiba::CardDB::card_reader(&db, CODE_LINK, &data);
	check_eq<uint32_t>(data.code, CODE_LINK, "card_reader fills a known code");
	check_eq<uint32_t>(data.link_marker, static_cast<uint32_t>(LINK_MARKERS),
			"card_reader keeps the link markers");
	kaiba::CardDB::card_reader_done(&db, &data);

	std::memset(&data, 0xAA, sizeof(data));
	kaiba::CardDB::card_reader(&db, 99999999u, &data);
	check_eq<uint32_t>(data.code, 99999999u, "unknown code is echoed back");
	check_eq<uint32_t>(data.type, 0, "unknown code is otherwise zeroed");
	check_eq<int32_t>(data.attack, 0, "unknown code has no attack");
	check(data.setcodes != nullptr, "unknown code still gets a setcodes pointer");
	if (data.setcodes != nullptr) {
		check_eq<uint16_t>(data.setcodes[0], 0, "unknown code's setcodes is terminated");
	}

	std::memset(&data, 0xAA, sizeof(data));
	kaiba::CardDB::card_reader(nullptr, CODE_LINK, &data);
	check(data.setcodes != nullptr && data.setcodes[0] == 0 && data.type == 0,
			"null payload degrades to an unknown card");
	// Must not dereference null.
	kaiba::CardDB::card_reader(&db, CODE_LINK, nullptr);
	kaiba::CardDB::card_reader_done(nullptr, nullptr);
	check(true, "null OCG_CardData is survivable");

	// --- failure paths -----------------------------------------------------------------
	kaiba::CardDB missing;
	error.clear();
	check(!missing.open(g_temp_dir + "/does_not_exist.cdb", &error), "missing file fails");
	check(!error.empty(), "missing file reports why");
	check_eq<size_t>(missing.card_count(), 0, "failed open leaves the db empty");

	const std::string junk_path = g_temp_dir + "/not_a.cdb";
	write_file(junk_path, "this is not a database");
	kaiba::CardDB junk;
	error.clear();
	check(!junk.open(junk_path, &error), "non-sqlite file fails");
	check(!junk.is_loaded(), "non-sqlite file leaves is_loaded false");

	std::printf("  %zu cards loaded, %zu with setcodes\n", db.card_count(), db.setcode_count());
}

void test_script_vfs(const std::string& base_root, const std::string& pack_root) {
	std::printf("ScriptVFS\n");

	// --- name normalisation ------------------------------------------------------------
	check_str(kaiba::ScriptVFS::base_name("c12345678.lua"), "c12345678.lua", "bare name");
	check_str(kaiba::ScriptVFS::base_name("./script/c1.lua"), "c1.lua", "unix path stripped");
	check_str(kaiba::ScriptVFS::base_name("script\\c1.lua"), "c1.lua", "windows path stripped");
	check_str(kaiba::ScriptVFS::base_name("/a/b/constant.lua"), "constant.lua", "absolute path");

	kaiba::ScriptVFS vfs;
	check_eq<size_t>(vfs.root_count(), 0, "starts with no roots");
	check(vfs.find("c10000001.lua") == nullptr, "no roots means no hits");

	// Mounted pack first, base second: the pack must shadow the base.
	vfs.add_root(pack_root);
	vfs.add_root(base_root);
	check_eq<size_t>(vfs.root_count(), 2, "two roots");

	const std::vector<char>* shadowed = vfs.find("utility.lua");
	check(shadowed != nullptr, "utility.lua resolves");
	if (shadowed != nullptr) {
		check_str(std::string(shadowed->begin(), shadowed->end()),
				"-- from the pack\n", "the first root wins");
	}

	const std::vector<char>* base_only = vfs.find("constant.lua");
	check(base_only != nullptr, "constant.lua falls through to the second root");
	if (base_only != nullptr) {
		// The file on disk starts with a UTF-8 BOM; it must not reach Lua.
		check(base_only->size() >= 2 && (*base_only)[0] == '-' && (*base_only)[1] == '-',
				"UTF-8 BOM is stripped");
	}

	check(vfs.find("./script/c10000001.lua") != nullptr, "leading path is stripped on lookup");
	check(vfs.find("nope.lua") == nullptr, "a missing script returns null");

	// --- caching -----------------------------------------------------------------------
	const size_t cached = vfs.cache_size();
	check(cached >= 4, "hits and misses are both cached");
	const std::string disposable = base_root + "/c10000001.lua";
	check_eq<int>(std::remove(disposable.c_str()), 0, "delete the file behind the cache");
	check(vfs.find("c10000001.lua") != nullptr, "a cached script survives its file");
	check_eq<size_t>(vfs.cache_size(), cached, "a cache hit adds no entry");

	// --- the real callback, against a real duel ----------------------------------------
	kaiba::CardDB empty_db;
	OCG_DuelOptions options;
	std::memset(&options, 0, sizeof(options));
	options.seed[0] = 0x4b414942ull;
	options.seed[1] = 0x44415441ull;
	options.seed[2] = 0x54455354ull;
	options.seed[3] = 0x31323334ull;
	options.team1 = OCG_Player{ 8000u, 5u, 1u };
	options.team2 = OCG_Player{ 8000u, 5u, 1u };
	options.cardReader = &kaiba::CardDB::card_reader;
	options.payload1 = &empty_db;
	options.scriptReader = &kaiba::ScriptVFS::script_reader;
	options.payload2 = &vfs;
	options.cardReaderDone = &kaiba::CardDB::card_reader_done;
	options.payload4 = &empty_db;
	options.enableUnsafeLibraries = 0;

	OCG_Duel duel = nullptr;
	const int status = OCG_CreateDuel(&duel, &options);
	check_eq<int>(status, static_cast<int>(OCG_DUEL_CREATION_SUCCESS), "OCG_CreateDuel");
	if (duel != nullptr) {
		check_eq<int>(kaiba::ScriptVFS::script_reader(&vfs, duel, "constant.lua"), 1,
				"script_reader loads a valid chunk");
		check_eq<int>(kaiba::ScriptVFS::script_reader(&vfs, duel, "./script/constant.lua"), 1,
				"script_reader accepts a prefixed name");
		check_eq<int>(kaiba::ScriptVFS::script_reader(&vfs, duel, "nope.lua"), 0,
				"script_reader reports a missing script");
		check_eq<int>(kaiba::ScriptVFS::script_reader(&vfs, duel, "broken.lua"), 0,
				"script_reader reports a Lua syntax error");
		check_eq<int>(kaiba::ScriptVFS::script_reader(nullptr, duel, "constant.lua"), 0,
				"null payload returns 0");
		check_eq<int>(kaiba::ScriptVFS::script_reader(&vfs, duel, nullptr), 0,
				"null name returns 0");
		OCG_DestroyDuel(duel);
	}
}

} // namespace

int main() {
	char temp_template[] = "/tmp/kaiba_data_test_XXXXXX";
	const char* made = mkdtemp(temp_template);
	if (made == nullptr) {
		std::printf("cannot create a temp directory\n");
		return 1;
	}
	g_temp_dir = made;

	const std::string cdb_path = g_temp_dir + "/cards.cdb";
	const std::string base_root = g_temp_dir + "/base_script";
	const std::string pack_root = g_temp_dir + "/pack_script";
	mkdir(base_root.c_str(), 0755);
	mkdir(pack_root.c_str(), 0755);

	std::printf("temp dir        : %s\n", g_temp_dir.c_str());
	std::printf("sqlite version  : %s\n", sqlite3_libversion());
	int core_major = 0;
	int core_minor = 0;
	OCG_GetVersion(&core_major, &core_minor);
	std::printf("ocgcore version : %d.%d\n\n", core_major, core_minor);

	bool ready = create_test_cdb(cdb_path);
	// "\xEF\xBB\xBF" is a UTF-8 BOM: luaL_loadbuffer would choke on it.
	ready = ready && write_file(base_root + "/constant.lua", "\xEF\xBB\xBF-- base constant\n");
	ready = ready && write_file(base_root + "/utility.lua", "-- from the base\n");
	ready = ready && write_file(pack_root + "/utility.lua", "-- from the pack\n");
	ready = ready && write_file(base_root + "/c10000001.lua", "-- card script\n");
	ready = ready && write_file(base_root + "/broken.lua", "this is not ( valid lua\n");

	if (!ready) {
		std::printf("FAIL: could not lay out the fixtures\n");
		return 1;
	}

	test_card_db(cdb_path);
	std::printf("\n");
	test_script_vfs(base_root, pack_root);

	// Best-effort cleanup. The fixture list is closed, so no directory walk is needed.
	const char* const leftovers[] = {
		"/cards.cdb", "/not_a.cdb",
		"/base_script/constant.lua", "/base_script/utility.lua",
		"/base_script/c10000001.lua", "/base_script/broken.lua",
		"/pack_script/utility.lua",
	};
	for (const char* leftover : leftovers) {
		std::remove((g_temp_dir + leftover).c_str());
	}
	rmdir(base_root.c_str());
	rmdir(pack_root.c_str());
	rmdir(g_temp_dir.c_str());

	std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
	std::printf("result          : %s\n", g_failures == 0 ? "PASS" : "FAIL");
	return g_failures == 0 ? 0 : 1;
}
