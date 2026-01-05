#include "../../include/utils/hex_utils.hpp"
#include <cstring>
#include <algorithm>
#include <stdexcept>
#include <cmath>

namespace bloxminer {
namespace utils {

static const char HEX_CHARS[] = "0123456789abcdef";

static uint8_t char_to_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

std::vector<uint8_t> hex_to_bytes(const std::string& hex) {
    std::vector<uint8_t> bytes;
    bytes.reserve(hex.length() / 2);
    
    for (size_t i = 0; i + 1 < hex.length(); i += 2) {
        uint8_t byte = (char_to_nibble(hex[i]) << 4) | char_to_nibble(hex[i + 1]);
        bytes.push_back(byte);
    }
    
    return bytes;
}

size_t hex_to_bytes(const std::string& hex, uint8_t* out, size_t out_len) {
    size_t bytes_written = 0;
    
    for (size_t i = 0; i + 1 < hex.length() && bytes_written < out_len; i += 2) {
        out[bytes_written++] = (char_to_nibble(hex[i]) << 4) | char_to_nibble(hex[i + 1]);
    }
    
    return bytes_written;
}

std::string bytes_to_hex(const uint8_t* bytes, size_t len) {
    std::string hex;
    hex.reserve(len * 2);
    
    for (size_t i = 0; i < len; i++) {
        hex += HEX_CHARS[bytes[i] >> 4];
        hex += HEX_CHARS[bytes[i] & 0x0F];
    }
    
    return hex;
}

std::string bytes_to_hex(const std::vector<uint8_t>& bytes) {
    return bytes_to_hex(bytes.data(), bytes.size());
}

void reverse_bytes(uint8_t* data, size_t len) {
    for (size_t i = 0; i < len / 2; i++) {
        std::swap(data[i], data[len - 1 - i]);
    }
}

void swap_endian_32(uint8_t* data, size_t len) {
    for (size_t i = 0; i + 3 < len; i += 4) {
        std::swap(data[i], data[i + 3]);
        std::swap(data[i + 1], data[i + 2]);
    }
}

int compare_hash(const uint8_t* hash1, const uint8_t* hash2) {
    // Compare in big-endian order (from most significant byte)
    for (int i = 31; i >= 0; i--) {
        if (hash1[i] < hash2[i]) return -1;
        if (hash1[i] > hash2[i]) return 1;
    }
    return 0;
}

bool meets_target(const uint8_t* hash, const uint8_t* target) {
    // Hash must be <= target (comparing as 256-bit big-endian numbers)
    // hash[0] is the most significant byte
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return true;
        if (hash[i] > target[i]) return false;
    }
    return true;  // Equal is valid
}

void difficulty_to_target(double difficulty, uint8_t* target) {
    // Initialize target to zeros
    memset(target, 0, 32);
    
    if (difficulty <= 0) {
        memset(target, 0xFF, 32);
        return;
    }
    
    // Standard pool difficulty 1 base target
    // This is: 0x00000000FFFF0000000000000000000000000000000000000000000000000000
    // which is 2^224 * 0xFFFF = the standard Bitcoin/VerusHash pool diff 1 target
    //
    // Target = base / difficulty
    // For diff 1: target[0..3] = 0, target[4..5] = 0xFFFF, rest = 0
    
    // Calculate as: base_target / difficulty
    // base_target = 0xFFFF * 2^208 (in 256-bit space, bytes 4-5 are FFFF)
    
    // For simplicity, we use: target = (0xFFFF << 208) / difficulty
    // We compute this in floating point then convert
    
    // 2^208 represented as double
    double base = 0xFFFF;
    for (int i = 0; i < 26; i++) {  // 26*8 = 208 bits
        base *= 256.0;
    }
    
    double target_val = base / difficulty;
    
    // Convert to 32-byte big-endian target
    // Start from least significant byte (index 31) and work up
    for (int i = 31; i >= 0; i--) {
        target[i] = static_cast<uint8_t>(fmod(target_val, 256.0));
        target_val = floor(target_val / 256.0);
        if (target_val < 1.0) break;
    }
}

void nbits_to_target(uint32_t nbits, uint8_t* target) {
    memset(target, 0, 32);
    
    uint32_t exponent = (nbits >> 24) & 0xFF;
    uint32_t mantissa = nbits & 0x007FFFFF;
    
    if (nbits & 0x00800000) {
        // Negative, which is invalid for targets
        return;
    }
    
    if (exponent <= 3) {
        mantissa >>= 8 * (3 - exponent);
        target[0] = mantissa & 0xFF;
        target[1] = (mantissa >> 8) & 0xFF;
        target[2] = (mantissa >> 16) & 0xFF;
    } else {
        size_t offset = exponent - 3;
        if (offset < 32) {
            target[offset] = mantissa & 0xFF;
            if (offset + 1 < 32) target[offset + 1] = (mantissa >> 8) & 0xFF;
            if (offset + 2 < 32) target[offset + 2] = (mantissa >> 16) & 0xFF;
        }
    }
}

}  // namespace utils
}  // namespace bloxminer
