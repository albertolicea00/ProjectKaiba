#include "card_db.h"

#include <cstring>

#include <ocgapi_constants.h>
#include <sqlite3.h>

namespace kaiba {
namespace {

/// Taken verbatim from EDOPro's `gframe/data_manager.cpp` (`SELECT_STMT`). The column order
/// below is load-bearing: the indices in `Column` index into this statement, not into the
/// physical table. Do not reorder without updating `Column`.
constexpr const char* SELECT_STMT =
		"SELECT datas.id,datas.ot,datas.alias,datas.setcode,datas.type,datas.atk,datas.def,"
		"datas.level,datas.race,datas.attribute,datas.category,"
		"texts.name,texts.desc,texts.str1,texts.str2,texts.str3,texts.str4,texts.str5,"
		"texts.str6,texts.str7,texts.str8,texts.str9,texts.str10,texts.str11,texts.str12,"
		"texts.str13,texts.str14,texts.str15,texts.str16 "
		"FROM datas,texts WHERE texts.id = datas.id ORDER BY texts.id;";

enum Column {
	COL_ID = 0,
	COL_OT = 1,
	COL_ALIAS = 2,
	COL_SETCODE = 3,
	COL_TYPE = 4,
	COL_ATK = 5,
	COL_DEF = 6,
	COL_LEVEL = 7,
	COL_RACE = 8,
	COL_ATTRIBUTE = 9,
	COL_CATEGORY = 10,
	COL_NAME = 11,
	COL_DESC = 12,
	/// `texts.str1` lives here; `strN` is at `COL_STR1 + (N - 1)`.
	COL_STR1 = 13,
};

/// `datas.setcode` packs four 16-bit archetype ids into one 64-bit column.
constexpr int SETCODES_PER_ROW = 4;

/// Shared terminator handed to ocgcore for cards that have no setcodes and for unknown
/// codes. Static storage duration, never written to, so it is safe to share across duels.
const uint16_t g_empty_setcodes[1] = { 0 };

std::string column_text(sqlite3_stmt* stmt, int index) {
	// sqlite3_column_text must be called before sqlite3_column_bytes: the first call can
	// convert the stored value and change the byte count the second one reports.
	const unsigned char* text = sqlite3_column_text(stmt, index);
	if (text == nullptr) {
		// SQL NULL, or an out-of-memory conversion failure. Both become an empty string.
		return std::string();
	}
	const int bytes = sqlite3_column_bytes(stmt, index);
	if (bytes <= 0) {
		return std::string();
	}
	return std::string(reinterpret_cast<const char*>(text), static_cast<size_t>(bytes));
}

std::string sqlite_error(sqlite3* db, const char* context) {
	std::string message = context;
	const char* detail = (db != nullptr) ? sqlite3_errmsg(db) : nullptr;
	if (detail != nullptr && detail[0] != '\0') {
		message += ": ";
		message += detail;
	}
	return message;
}

} // namespace

void CardDB::fill_unknown(uint32_t code, OCG_CardData* data) {
	if (data == nullptr) {
		return;
	}
	std::memset(data, 0, sizeof(OCG_CardData));
	data->code = code;
	// const_cast is forced by the C API: OCG_CardData::setcodes is a non-const uint16_t*.
	// ocgcore only ever reads through it (vendor/ocgcore/duel.cpp, card_data's constructor).
	data->setcodes = const_cast<uint16_t*>(g_empty_setcodes);
}

void CardDB::clear() {
	m_cards.clear();
	m_texts.clear();
	m_loaded = false;
}

size_t CardDB::setcode_count() const {
	size_t total = 0;
	for (const auto& pair : m_cards) {
		// Every list carries a terminator, so "has setcodes" means "longer than one".
		if (pair.second.setcodes.size() > 1) {
			++total;
		}
	}
	return total;
}

const OCG_CardData* CardDB::find(uint32_t code) const {
	const auto found = m_cards.find(code);
	return (found == m_cards.end()) ? nullptr : &found->second.data;
}

const CardText* CardDB::find_text(uint32_t code) const {
	const auto found = m_texts.find(code);
	return (found == m_texts.end()) ? nullptr : &found->second;
}

bool CardDB::fill(uint32_t code, OCG_CardData* data) const {
	if (data == nullptr) {
		return false;
	}
	const OCG_CardData* entry = find(code);
	if (entry == nullptr) {
		fill_unknown(code, data);
		return false;
	}
	*data = *entry;
	return true;
}

void CardDB::card_reader(void* payload, uint32_t code, OCG_CardData* data) {
	if (data == nullptr) {
		return;
	}
	const CardDB* db = static_cast<const CardDB*>(payload);
	if (db == nullptr) {
		// Misconfigured OCG_DuelOptions::payload1. Degrade to "every card is unknown"
		// rather than dereferencing null in the middle of a duel.
		fill_unknown(code, data);
		return;
	}
	db->fill(code, data);
}

void CardDB::card_reader_done(void* /*payload*/, OCG_CardData* /*data*/) {
	// Nothing to release. See the declaration in card_db.h for why.
}

bool CardDB::open(const std::string& cdb_path, std::string* out_error) {
	clear();

	sqlite3* db = nullptr;
	// SQLITE_OPEN_READONLY also means SQLite will not create the file if it is missing,
	// which turns a wrong path into an error instead of an empty database.
	if (sqlite3_open_v2(cdb_path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
		if (out_error != nullptr) {
			*out_error = sqlite_error(db, "cannot open card database '" + cdb_path + "'");
		}
		// sqlite3_open_v2 hands back a handle even on failure, purely to carry the message.
		sqlite3_close(db);
		return false;
	}

	sqlite3_stmt* stmt = nullptr;
	if (sqlite3_prepare_v2(db, SELECT_STMT, -1, &stmt, nullptr) != SQLITE_OK) {
		if (out_error != nullptr) {
			*out_error = sqlite_error(db,
					"'" + cdb_path + "' does not have the expected datas/texts schema");
		}
		sqlite3_finalize(stmt);
		sqlite3_close(db);
		return false;
	}

	// A full cdb holds roughly 15k-25k cards. Reserving up front avoids a dozen rehashes
	// during the load; it is not required for correctness, since rehashing an unordered_map
	// does not move the elements the setcodes pointers refer to.
	m_cards.reserve(25000);
	m_texts.reserve(25000);

	bool failed = false;
	for (;;) {
		const int step = sqlite3_step(stmt);
		if (step == SQLITE_DONE) {
			break;
		}
		if (step == SQLITE_WARNING || step == SQLITE_NOTICE) {
			// Advisory codes. EDOPro skips them; so do we.
			continue;
		}
		if (step != SQLITE_ROW) {
			if (out_error != nullptr) {
				*out_error = sqlite_error(db, "failed while reading '" + cdb_path + "'");
			}
			failed = true;
			break;
		}

		const uint32_t code = static_cast<uint32_t>(sqlite3_column_int64(stmt, COL_ID));

		// A duplicate datas.id overwrites the earlier row, matching EDOPro. Taking the
		// reference first and filling in place keeps Entry::setcodes at a stable address.
		Entry& entry = m_cards[code];
		OCG_CardData& data = entry.data;
		std::memset(&data, 0, sizeof(OCG_CardData));
		data.code = code;
		data.alias = static_cast<uint32_t>(sqlite3_column_int64(stmt, COL_ALIAS));

		// datas.setcode packs up to four archetype ids, low 16 bits first. Zeroes are holes,
		// not list ends: {0x1234, 0, 0x5678, 0} must yield {0x1234, 0x5678}.
		const uint64_t packed_setcodes =
				static_cast<uint64_t>(sqlite3_column_int64(stmt, COL_SETCODE));
		entry.setcodes.clear();
		entry.setcodes.reserve(SETCODES_PER_ROW + 1);
		for (int i = 0; i < SETCODES_PER_ROW; ++i) {
			const uint16_t setcode =
					static_cast<uint16_t>((packed_setcodes >> (i * 16)) & 0xffffu);
			if (setcode != 0) {
				entry.setcodes.push_back(setcode);
			}
		}
		entry.setcodes.push_back(0);
		// Wired up only after the last push_back: an earlier reallocation would strand it.
		data.setcodes = entry.setcodes.data();

		data.type = static_cast<uint32_t>(sqlite3_column_int64(stmt, COL_TYPE));
		data.attack = sqlite3_column_int(stmt, COL_ATK);
		data.defense = sqlite3_column_int(stmt, COL_DEF);

		// datas.def is overloaded: on a Link monster it holds the link marker bitmask and
		// the card has no defence at all. Reading it as defence would give every Link
		// monster a nonsensical DEF and no arrows - silently, with no error anywhere.
		if ((data.type & TYPE_LINK) != 0) {
			data.link_marker = static_cast<uint32_t>(data.defense);
			data.defense = 0;
		} else {
			data.link_marker = 0;
		}

		// datas.level packs three fields: level in the low byte, right scale in byte 2 and
		// left scale in byte 3. Treat the column as a bit pattern rather than a number -
		// shifting a negative int right is implementation-defined before C++20, and some
		// rows are negative (see below).
		const int32_t raw_level = sqlite3_column_int(stmt, COL_LEVEL);
		const uint32_t level_bits = static_cast<uint32_t>(raw_level);
		if (raw_level < 0) {
			// A negative row marks a card whose level is "?". EDOPro negates the low byte,
			// not the original value, so a raw -4 becomes level -252, not -4. That looks
			// like a bug but it is the encoding ocgcore is fed in production, and changing
			// it here would desynchronise us from the rules engine.
			data.level = static_cast<uint32_t>(-static_cast<int32_t>(level_bits & 0xffu));
		} else {
			data.level = level_bits & 0xffu;
		}
		data.lscale = (level_bits >> 24) & 0xffu;
		data.rscale = (level_bits >> 16) & 0xffu;

		// race is 64-bit in OCG core v11; reading it as 32-bit truncates the newer types.
		data.race = static_cast<uint64_t>(sqlite3_column_int64(stmt, COL_RACE));
		data.attribute = static_cast<uint32_t>(sqlite3_column_int64(stmt, COL_ATTRIBUTE));

		CardText& text = m_texts[code];
		text.code = code;
		text.ot = static_cast<uint32_t>(sqlite3_column_int64(stmt, COL_OT));
		text.category = static_cast<uint32_t>(sqlite3_column_int64(stmt, COL_CATEGORY));
		text.name = column_text(stmt, COL_NAME);
		text.desc = column_text(stmt, COL_DESC);
		for (size_t i = 0; i < CardText::STRING_COUNT; ++i) {
			text.strings[i] = column_text(stmt, COL_STR1 + static_cast<int>(i));
		}
	}

	sqlite3_finalize(stmt);
	// Finalised first on purpose: sqlite3_close returns SQLITE_BUSY while any statement is
	// still live, which would leak the handle for the rest of the process.
	sqlite3_close(db);

	if (failed) {
		clear();
		return false;
	}

	m_loaded = true;
	return true;
}

} // namespace kaiba
