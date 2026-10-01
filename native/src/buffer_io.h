#ifndef KAIBA_BUFFER_IO_H
#define KAIBA_BUFFER_IO_H

// Port of EDOPro's gframe/bufferio.h, reduced to the raw byte cursor helpers.
//
// This is the only place that turns ocgcore's wire bytes into values and back. Field widths
// and cursor arithmetic mirror the engine's own serialisation (vendor/ocgcore/card.cpp,
// ocgapi.cpp). Do not change the byte layout casually: ocgcore is the authority, and any
// drift here silently desynchronises or corrupts a duel.
//
// Everything from the original that depended on Irrlicht or EDOPro's text layer (the UTF-8 /
// UTF-16 codecs, CopyStr, GetVal, getStruct) is deliberately absent. See the port notes in
// core_utils.h.

#include <cstdint>
#include <cstring>
#include <vector>

namespace kaiba {
namespace core_utils {

namespace detail {

/// Local stand-in for std::is_same_v<std::remove_cv_t<T>, uint8_t>.
///
/// Hand-rolled so this header needs nothing beyond <cstdint>, <cstring> and <vector>.
template<typename T> struct is_byte_cursor { static constexpr bool value = false; };
template<> struct is_byte_cursor<uint8_t> { static constexpr bool value = true; };
template<> struct is_byte_cursor<const uint8_t> { static constexpr bool value = true; };
template<> struct is_byte_cursor<volatile uint8_t> { static constexpr bool value = true; };
template<> struct is_byte_cursor<const volatile uint8_t> { static constexpr bool value = true; };

} // namespace detail

class BufferIO {
public:
	static void insert_data(std::vector<uint8_t>& vec, const void* val, std::size_t len) {
		const auto vec_size = vec.size();
		const auto val_size = len;
		vec.resize(vec_size + val_size);
		std::memcpy(&vec[vec_size], val, val_size);
	}

	template<typename T>
	static void insert_value(std::vector<uint8_t>& vec, T val) {
		insert_data(vec, &val, sizeof(T));
	}

	/// Copies `size` bytes out of the cursor and advances it.
	template<typename input_type>
	static void Read(input_type*& p, void* dest, std::size_t size) {
		static_assert(detail::is_byte_cursor<input_type>::value, "only uint8_t supported as buffer input");
		std::memcpy(dest, p, size);
		p += size;
	}

	/// Reads one T out of the cursor and advances it by sizeof(T).
	template<typename T, typename input_type>
	static T Read(input_type*& p) {
		static_assert(detail::is_byte_cursor<input_type>::value, "only uint8_t supported as buffer input");
		T ret;
		Read(p, &ret, sizeof(T));
		return ret;
	}

	/// Writes one T at the cursor and advances it by sizeof(T).
	template<typename T>
	static void Write(uint8_t*& p, T value) {
		std::memcpy(p, &value, sizeof(T));
		p += sizeof(T);
	}
};

} // namespace core_utils
} // namespace kaiba

#endif // KAIBA_BUFFER_IO_H
