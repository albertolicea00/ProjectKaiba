#ifndef KAIBA_CARD_DB_H
#define KAIBA_CARD_DB_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include <ocgapi_types.h>

namespace kaiba {

/// The columns of `cards.cdb` that the rules engine never sees.
///
/// `OCG_CardData` has no room for them, and ocgcore has no use for them: they exist for the
/// deck validator, the deck editor filters and `CardRegistry` (L3). Kept in a separate map so
/// the hot path - `card_reader` - touches only the `OCG_CardData` map.
///
/// Text is stored as UTF-8 exactly as the cdb holds it. EDOPro converts to `std::wstring`
/// here; we do not, because everything above this layer is Godot `String`, which is UTF-8.
struct CardText {
	/// Number of `texts.strN` columns in the schema. Fixed by the cdb format, not a guess.
	static constexpr size_t STRING_COUNT = 16;

	uint32_t code = 0;
	/// `datas.ot` - OCG/TCG/anime availability flags. Consumed by `deck_validator.gd`.
	uint32_t ot = 0;
	/// `datas.category` - effect category bitmask. Consumed by the deck editor filters.
	uint32_t category = 0;
	std::string name;
	std::string desc;
	/// `texts.str1 .. texts.str16` - the per-effect labels shown when a card offers a choice.
	/// Absent entries are empty strings, never null.
	std::string strings[STRING_COUNT];
};

/// In-memory mirror of `cards.cdb`, and the source of ocgcore's `cardReader` callback.
///
/// `cardReader` is called thousands of times per duel (docs/ARCHITECTURE.md section 6), so
/// `open()` reads every row once and closes the SQLite handle before returning. After that
/// there is zero SQLite access: no statement handles survive, no file stays open, and the
/// hot path is a single `unordered_map` lookup plus a struct copy.
///
/// Lifetime contract: an instance must outlive every `OCG_Duel` it was handed to, because
/// `OCG_CardData::setcodes` points into memory this object owns. `open()` and `clear()` are
/// the only mutators and must not run while a duel exists. Lookups are const and therefore
/// safe to call concurrently from several duel threads.
///
/// Copying is deleted: the stored `OCG_CardData::setcodes` pointers alias this object's own
/// storage, so a copy would hand ocgcore pointers into the original.
class CardDB {
public:
	CardDB() = default;
	CardDB(const CardDB&) = delete;
	CardDB& operator=(const CardDB&) = delete;
	CardDB(CardDB&&) = delete;
	CardDB& operator=(CardDB&&) = delete;

	/// Opens `cdb_path` read-only, loads every row into memory and closes the handle.
	///
	/// Returns false and writes a human-readable reason to `out_error` (when not null) if the
	/// file is missing, is not a cdb, or does not carry the expected `datas`/`texts` schema.
	/// A failed call leaves the object empty, never half-loaded.
	bool open(const std::string& cdb_path, std::string* out_error);

	/// Drops every loaded row. Invalidates all pointers previously returned by this object
	/// and every `OCG_CardData::setcodes` handed out so far.
	void clear();

	bool is_loaded() const { return m_loaded; }

	/// Distinct card codes held. Duplicate `datas.id` rows collapse to one entry.
	size_t card_count() const { return m_cards.size(); }

	/// Rows that carry at least one non-zero setcode. Diagnostic only.
	size_t setcode_count() const;

	/// Rules-engine view of one card, or null when the code is unknown.
	/// The pointer stays valid until `clear()` or destruction.
	const OCG_CardData* find(uint32_t code) const;

	/// Client-side-only columns for one card, or null when the code is unknown.
	const CardText* find_text(uint32_t code) const;

	/// Copies the card into `data`. Returns false for an unknown code, in which case `data`
	/// is zero-filled except for `code` and a valid empty `setcodes` list.
	bool fill(uint32_t code, OCG_CardData* data) const;

	/// `OCG_DuelOptions::cardReader`. `payload` is a `CardDB*`.
	///
	/// Never throws, never crashes, never leaves `setcodes` dangling. A null payload or an
	/// unknown code both produce the same zeroed-but-valid record as `fill_unknown`.
	static void card_reader(void* payload, uint32_t code, OCG_CardData* data);

	/// `OCG_DuelOptions::cardReaderDone`. `payload` is a `CardDB*`.
	///
	/// Deliberately a no-op. docs/DATA.md suggests a per-duel arena released here, but that
	/// is only needed when `setcodes` is allocated per call. Ours is not: every list is owned
	/// by the `CardDB` entry and lives as long as the database. ocgcore copies the list into
	/// a `std::set` inside `card_data`'s constructor before this callback runs
	/// (vendor/ocgcore/duel.cpp, `read_card`), so there is nothing left to release.
	static void card_reader_done(void* payload, OCG_CardData* data);

	/// Fills `data` with a zeroed record for `code`, with `setcodes` pointing at a shared,
	/// statically allocated, zero-terminated empty list. Never leaves `setcodes` null:
	/// ocgcore tolerates null, but a null here is one refactor away from a crash.
	static void fill_unknown(uint32_t code, OCG_CardData* data);

private:
	/// One row. `data.setcodes` points at `setcodes.data()`, which is why `Entry` must never
	/// be copied or moved after `open()` has wired the pointer up.
	struct Entry {
		OCG_CardData data{};
		/// Zero-terminated. Always holds at least the terminator.
		std::vector<uint16_t> setcodes;
	};

	bool m_loaded = false;
	/// Node-based on purpose: `unordered_map` keeps element addresses stable across rehash,
	/// so `Entry::setcodes.data()` stays valid while the rest of the cdb loads.
	std::unordered_map<uint32_t, Entry> m_cards;
	std::unordered_map<uint32_t, CardText> m_texts;
};

} // namespace kaiba

#endif // KAIBA_CARD_DB_H
