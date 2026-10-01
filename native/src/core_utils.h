#ifndef KAIBA_CORE_UTILS_H
#define KAIBA_CORE_UTILS_H

// Port of EDOPro's gframe/core_utils.h: the message / query byte-parsing layer.
//
// This decodes the binary stream produced by ocgcore (OCG_DuelGetMessage, OCG_DuelQuery*).
// Field order, field widths and the compat/legacy branches are part of that wire format, not
// style choices. Do not change the byte layout casually - "tidying" any of it silently breaks
// duels. The authority is vendor/ocgcore (card.cpp::get_infos, ocgapi.cpp).
//
// Differences from the original, all mechanical:
//   - namespace CoreUtils -> kaiba::core_utils
//   - no Irrlicht, no ygo::ClientCard; Query's members are public instead of friend-gated
//   - ParseMessages calls the real OCG_DuelGetMessage from <ocgapi.h> (see core_utils.cpp)
//   - the HINT_SKILL* defines are dropped: only duelclient.cpp referenced them, and
//     duelclient.cpp is not portable (AGENTS.md section 9)

#include <cstdint>
#include <cstring>
#include <vector>

#include "buffer_io.h"

namespace kaiba {
namespace core_utils {

/// One ocgcore message: a leading opcode byte plus its raw payload.
///
/// Level 0 in the event model (docs/ARCHITECTURE.md section 7). Stays opaque bytes all the
/// way to the transport; only MsgParser interprets it.
class Packet {
public:
	Packet() {}
	Packet(const uint8_t* buf, std::size_t len) {
		uint8_t msg = BufferIO::Read<uint8_t>(buf);
		Set(msg, buf, len);
	}
	Packet(int msg, const uint8_t* buf, std::size_t len) {
		Set(msg, buf, len);
	}
	void Set(int msg, const uint8_t* buf, std::size_t len) {
		message = static_cast<uint8_t>(msg);
		buffer.resize(len);
		if(len)
			std::memcpy(buffer.data(), buf, len);
	}
	uint8_t* data() { return buffer.data(); }
	const uint8_t* data() const { return buffer.data(); }
	uint8_t message{};
	std::vector<uint8_t> buffer;
	/// Size on the wire: payload plus the opcode byte.
	auto size() const { return buffer.size() + sizeof(uint8_t); }
	auto buff_size() const { return buffer.size(); }
};

/// Splits one OCG_DuelGetMessage buffer into its individual messages.
///
/// Layout: repeated [uint32 size][uint8 opcode][payload of size-1 bytes].
class PacketStream {
	std::vector<Packet> packets;
public:
	PacketStream() {}
	PacketStream(uint8_t* buf, uint32_t len);
	auto begin() { return packets.begin(); }
	auto begin() const { return packets.begin(); }
	auto end() { return packets.end(); }
	auto end() const { return packets.end(); }
};

/// Where a card is. Mirrors ocgcore's loc_info.
struct loc_info {
	uint8_t controler = 0;
	uint8_t location = 0;
	uint32_t sequence = 0;
	uint32_t position = 0;
};

/// Reads a loc_info and advances the cursor.
/// `compat` selects the legacy layout, where sequence and position are one byte each
/// instead of four.
loc_info ReadLocInfo(const uint8_t*& p, bool compat);
loc_info ReadLocInfo(uint8_t*& p, bool compat);

/// One card's query result: a flag-tagged, length-prefixed TLV block.
///
/// All members are public. The original gated them behind `friend class ygo::ClientCard`;
/// we have no ClientCard, and MsgParser plus HostService both need to read them.
/// GenerateBuffer is what implements invariant V7 (hidden-information filtering).
class Query {
public:
	Query() = delete;
	Query(const uint8_t* buff, bool compat = false, uint32_t len = 0, bool legacy_race_size = false) {
		if(compat)
			ParseCompat(buff, len);
		else
			Parse(buff, legacy_race_size);
	}

	/// Tag type that selects the cursor-advancing constructor used by QueryStream.
	struct Token {};
	Query(Token, const uint8_t*& buff, bool legacy_race_size) { Parse(buff, legacy_race_size); }

	/// Re-serialises this query.
	/// `is_for_public_buffer` strips every field an opponent must not learn.
	/// `check_hidden` additionally strips them when the card is flagged QUERY_IS_HIDDEN.
	void GenerateBuffer(std::vector<uint8_t>& buffer, bool is_for_public_buffer, bool check_hidden) const;

	void Parse(const uint8_t*& buff, bool legacy_race_size);
	void ParseCompat(const uint8_t* buff, uint32_t len);
	bool IsPublicQuery(uint32_t to_check_flag) const;
	std::size_t GetFlagSize(uint32_t to_check_flag) const;
	std::size_t GetSize() const;

	/// Set when the engine reported an empty field slot (a bare uint16 0).
	bool onfield_skipped = false;
	uint32_t flag = 0;
	uint32_t code = 0;
	uint32_t position = 0;
	uint32_t alias = 0;
	uint32_t type = 0;
	uint32_t level = 0;
	uint32_t rank = 0;
	uint32_t link = 0;
	uint32_t attribute = 0;
	uint64_t race = 0;
	int32_t attack = 0;
	int32_t defense = 0;
	int32_t base_attack = 0;
	int32_t base_defense = 0;
	uint32_t reason = 0;
	uint8_t owner = 0;
	uint32_t status = 0;
	uint8_t is_public = 0;
	uint32_t lscale = 0;
	uint32_t rscale = 0;
	uint32_t link_marker = 0;
	loc_info reason_card;
	loc_info equip_card;
	uint8_t is_hidden = 0;
	uint32_t cover = 0;
	std::vector<loc_info> target_cards;
	std::vector<uint32_t> overlay_cards;
	std::vector<uint32_t> counters;
};

/// A whole location's worth of queries, as produced by OCG_DuelQueryLocation.
///
/// Layout: [uint32 total size][Query]... where an empty slot is a bare uint16 0.
class QueryStream {
public:
	QueryStream() = delete;
	QueryStream(const uint8_t* buff, bool compat = false, uint32_t len = 0, bool legacy_race_size = false) {
		if(compat)
			ParseCompat(buff, len);
		else
			Parse(buff, legacy_race_size);
	}
	/// Re-serialises every query, keeping private fields. For the owning player.
	void GenerateBuffer(std::vector<uint8_t>& buffer, bool check_hidden) const;
	/// Re-serialises every query with private fields stripped. For everyone else (V7).
	void GeneratePublicBuffer(std::vector<uint8_t>& buffer) const;
	const std::vector<Query>& GetQueries() const { return queries; }
private:
	std::vector<Query> queries;
	void Parse(const uint8_t* buff, bool legacy_race_size);
	void ParseCompat(const uint8_t* buff, uint32_t len);
	std::size_t GetSize() const;
};

/// Kept as the original declared it, so this header pulls in no ocgcore headers.
/// Identical to the typedef in vendor/ocgcore/ocgapi_types.h; if upstream ever stops making
/// OCG_Duel a void*, core_utils.cpp fails to compile rather than failing silently.
using OCG_Duel = void*;

/// Drains the engine's pending message buffer. Must run on the duel's own thread (V8).
PacketStream ParseMessages(OCG_Duel duel);

} // namespace core_utils
} // namespace kaiba

#endif // KAIBA_CORE_UTILS_H
