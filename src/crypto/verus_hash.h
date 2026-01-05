/*
 * VerusHash v2.x - CPU-optimized Proof of Work Hash for BloxMiner
 * 
 * Based on the official VerusCoin implementation.
 * Ported by Bokiko, 2026.
 */

#ifndef BLOXMINER_VERUS_HASH_H
#define BLOXMINER_VERUS_HASH_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "haraka.h"
#include "verus_clhash.h"

// Hash output size
#define VERUSHASH_SIZE 32

/**
 * Initialize VerusHash subsystem
 * Must be called once before any hashing
 */
void verus_hash_init(void);

/**
 * VerusHash v2.0 (original VerusHash 2.0)
 */
void verus_hash_v2(void *result, const void *data, size_t len);

/**
 * VerusHash v2.1
 */
void verus_hash_v2_1(void *result, const void *data, size_t len);

/**
 * VerusHash v2.2 (current mainnet)
 */
void verus_hash_v2_2(void *result, const void *data, size_t len);

/**
 * Default VerusHash (v2.2 for current mainnet)
 */
#define verus_hash verus_hash_v2_2

/**
 * Check if CPU supports VerusHash requirements
 */
int verus_hash_supported(void);

#ifdef __cplusplus
}

#include <cstring>
#include <algorithm>

// C++ class for mining operations
namespace verus {

class Hasher {
public:
    Hasher(int solutionVersion = SOLUTION_VERUSHHASH_V2_2);
    ~Hasher();

    // Initialize with block header
    void init(const uint8_t* header, size_t len);

    // Compute hash with given nonce
    void hash(uint32_t nonce, uint8_t* output);
    
    // Hash raw data (no nonce injection)
    void hash_raw(const uint8_t* data, size_t len, uint8_t* output);

    // Batch hash for better throughput  
    void hash_batch(const uint32_t* nonces, uint8_t* outputs, size_t count);

    // Check CPU support
    static bool supported() { return verus_hash_supported() != 0; }

    // Get key mask
    uint64_t getKeyMask() const { return m_keyMask; }

private:
    // Buffer management
    alignas(32) uint8_t m_buf1[64] = {0};
    alignas(32) uint8_t m_buf2[64] = {0};
    uint8_t* m_curBuf;
    uint8_t* m_result;
    size_t m_curPos;
    
    // Header storage for mining
    alignas(32) uint8_t m_header[256];
    size_t m_headerLen;
    
    // Key management
    uint64_t m_keySize;
    uint64_t m_keyMask;
    int m_solutionVersion;

    // Internal methods
    void reset();
    void write(const uint8_t* data, size_t len);
    void finalize2b(uint8_t* hash);
    u128* genNewCLKey(uint8_t* seedBytes32);
    uint64_t intermediateTo128Offset(uint64_t intermediate);
};

} // namespace verus

#endif // __cplusplus

#endif // BLOXMINER_VERUS_HASH_H
