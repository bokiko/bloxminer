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

/**
 * Mining-optimized VerusHash v2.2 hasher
 * 
 * Usage for stratum mining (two-stage approach):
 * 
 * 1. When new job arrives:
 *    - Build full block (140-byte header + 1347-byte solution)
 *    - Clear non-canonical fields for merged mining
 *    - Call hash_half() to compute 64-byte intermediate state
 *    - Call prepare_key() to generate CLHash key (done once per job)
 * 
 * 2. For each nonce:
 *    - Update nonceSpace with current mining nonce
 *    - Call hash_with_nonce() to compute final 32-byte hash
 *    - Check if hash meets target
 */
class Hasher {
public:
    Hasher(int solutionVersion = SOLUTION_VERUSHHASH_V2_2);
    ~Hasher();

    // Initialize with block header (legacy interface)
    void init(const uint8_t* header, size_t len);

    // Compute hash with given nonce (legacy interface for 80-byte headers)
    void hash(uint32_t nonce, uint8_t* output);
    
    // Hash raw data directly (full VerusHash, no optimization)
    void hash_raw(const uint8_t* data, size_t len, uint8_t* output);

    // =========================================
    // Two-stage mining hash (optimized path)
    // =========================================
    
    /**
     * Stage 1: Compute intermediate state from full block
     * 
     * @param data Full block data (1487 bytes for Verus)
     * @param len  Length of data
     * @param intermediate64 Output buffer for 64-byte intermediate state
     */
    void hash_half(const uint8_t* data, size_t len, uint8_t* intermediate64);
    
    /**
     * Stage 2: Generate CLHash key from intermediate state
     * Must be called once after hash_half() for each new job
     * 
     * @param intermediate64 The 64-byte intermediate from hash_half()
     */
    void prepare_key(const uint8_t* intermediate64);
    
    /**
     * Stage 3: Compute final hash from intermediate + nonceSpace
     * Called for each nonce iteration. prepare_key() must have been called first.
     * 
     * @param intermediate64 The 64-byte intermediate from hash_half()
     * @param nonceSpace15   15-byte nonce space (pool nonce + mining nonce)
     * @param output         32-byte hash output
     */
    void hash_with_nonce(const uint8_t* intermediate64, const uint8_t* nonceSpace15, uint8_t* output);

    // Batch hash for better throughput  
    void hash_batch(const uint32_t* nonces, uint8_t* outputs, size_t count);

    // Check CPU support
    static bool supported() { return verus_hash_supported() != 0; }

    // Get key mask
    uint64_t getKeyMask() const { return m_keyMask; }
    
    // Check if key is prepared for current job
    bool isKeyPrepared() const { return m_keyPrepared; }

private:
    // Buffer management for chained hashing
    alignas(32) uint8_t m_buf1[64] = {0};
    alignas(32) uint8_t m_buf2[64] = {0};
    uint8_t* m_curBuf;
    uint8_t* m_result;
    size_t m_curPos;
    
    // Header storage for legacy mining interface
    alignas(32) uint8_t m_header[256];
    size_t m_headerLen;
    
    // Key management
    uint64_t m_keySize;
    uint64_t m_keyMask;
    int m_solutionVersion;
    
    // Cached key material for two-stage mining
    // Generated once per job by prepare_key()
    u128* m_cachedKey;
    uint64_t m_cachedKeySize;
    bool m_keyPrepared;
    
    // Pristine key backup - restored before each hash_with_nonce
    // This is more efficient than FixKey which has issues
    u128* m_pristineKey;

    // First hash after prepare_key needs full pristine copy
    // Subsequent hashes can use optimized FixKey restoration
    bool m_firstHashAfterPrepare;
    
    // FixKey state for CLHash (kept for compatibility but not used)
    alignas(32) uint32_t m_fixRand[32];
    alignas(32) uint32_t m_fixRandEx[32];
    alignas(32) u128 m_pRand[32];
    alignas(32) u128 m_pRandEx[32];

    // Internal methods
    void reset();
    void write(const uint8_t* data, size_t len);
    void fillExtra(const u128* data);
    void fillExtra64(uint64_t data);
    void finalize2b(uint8_t* hash);
    void genNewCLKey(const uint8_t* seedBytes32);
    void fixKey();
    uint64_t intermediateTo128Offset(uint64_t intermediate);
};

} // namespace verus

#endif // __cplusplus

#endif // BLOXMINER_VERUS_HASH_H
