#pragma once

#include <string>
#include <vector>
#include <cstdint>

namespace bloxminer {
namespace utils {

/**
 * Convert hex string to bytes
 * @param hex Hexadecimal string
 * @return Vector of bytes
 */
std::vector<uint8_t> hex_to_bytes(const std::string& hex);

/**
 * Convert hex string to bytes (in-place)
 * @param hex Hexadecimal string
 * @param out Output buffer
 * @param out_len Output buffer size
 * @return Number of bytes written
 */
size_t hex_to_bytes(const std::string& hex, uint8_t* out, size_t out_len);

/**
 * Convert bytes to hex string
 * @param bytes Byte array
 * @param len Length of byte array
 * @return Hexadecimal string
 */
std::string bytes_to_hex(const uint8_t* bytes, size_t len);

/**
 * Convert bytes to hex string
 * @param bytes Vector of bytes
 * @return Hexadecimal string
 */
std::string bytes_to_hex(const std::vector<uint8_t>& bytes);

/**
 * Reverse byte order (for endianness conversion)
 * @param data Byte array
 * @param len Length
 */
void reverse_bytes(uint8_t* data, size_t len);

/**
 * Swap endianness of 32-bit words in a byte array
 * @param data Byte array (must be multiple of 4 bytes)
 * @param len Length
 */
void swap_endian_32(uint8_t* data, size_t len);

/**
 * Compare two hashes (for target comparison)
 * @param hash1 First hash (32 bytes)
 * @param hash2 Second hash (32 bytes)
 * @return -1 if hash1 < hash2, 0 if equal, 1 if hash1 > hash2
 */
int compare_hash(const uint8_t* hash1, const uint8_t* hash2);

/**
 * Check if hash meets target (hash <= target)
 * @param hash Hash to check (32 bytes)
 * @param target Target (32 bytes)
 * @return true if hash <= target
 */
bool meets_target(const uint8_t* hash, const uint8_t* target);

/**
 * Convert difficulty to target
 * @param difficulty Difficulty value
 * @param target Output target (32 bytes)
 */
void difficulty_to_target(double difficulty, uint8_t* target);

/**
 * Convert nbits (compact target) to full target
 * @param nbits Compact target representation
 * @param target Output target (32 bytes)
 */
void nbits_to_target(uint32_t nbits, uint8_t* target);

}  // namespace utils
}  // namespace bloxminer
