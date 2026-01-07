/*
 * VerusHash v2.x Implementation for BloxMiner
 * 
 * Based on the official VerusCoin implementation and ccminer-verus.
 * Copyright (c) 2018 Michael Toutonghi
 * Ported by Bokiko, 2026.
 */

#include "verus_hash.h"
#include <cstring>
#include <algorithm>
#include <cstdio>

// Global initialization flag
static int g_verus_initialized = 0;

void verus_hash_init(void) {
    if (g_verus_initialized) return;
    load_constants();
    g_verus_initialized = 1;
}

int verus_hash_supported(void) {
    return IsCPUVerusOptimized();
}

// VerusHash v2.0 - Haraka512 chain hash (non-CLHash version)
void verus_hash_v2(void *result, const void *data, size_t len) {
    verus_hash_init();
    
    alignas(32) unsigned char buf[128];
    unsigned char *bufPtr = buf;
    int nextOffset = 64;
    size_t pos = 0;
    unsigned char *bufPtr2 = bufPtr + nextOffset;
    unsigned char *ptr = (unsigned char *)data;

    // Initial zero state
    memset(bufPtr, 0, 32);

    // Digest 32 bytes at a time
    for (; pos < len; pos += 32) {
        if (len - pos >= 32) {
            memcpy(bufPtr + 32, ptr + pos, 32);
        } else {
            size_t remaining = len - pos;
            memcpy(bufPtr + 32, ptr + pos, remaining);
            memset(bufPtr + 32 + remaining, 0, 32 - remaining);
        }
        haraka512(bufPtr2, bufPtr);
        bufPtr2 = bufPtr;
        bufPtr += nextOffset;
        nextOffset *= -1;
    }
    memcpy(result, bufPtr, 32);
}

// VerusHash v2.1 - with CLHash
void verus_hash_v2_1(void *result, const void *data, size_t len) {
    verus::Hasher hasher(SOLUTION_VERUSHHASH_V2_1);
    hasher.hash_raw((const uint8_t*)data, len, (uint8_t*)result);
}

// VerusHash v2.2 - current mainnet
void verus_hash_v2_2(void *result, const void *data, size_t len) {
    verus::Hasher hasher(SOLUTION_VERUSHHASH_V2_2);
    hasher.hash_raw((const uint8_t*)data, len, (uint8_t*)result);
}

// C++ implementation
namespace verus {

Hasher::Hasher(int solutionVersion) : 
    m_curBuf(m_buf1), 
    m_result(m_buf2),
    m_curPos(0),
    m_headerLen(0),
    m_solutionVersion(solutionVersion),
    m_cachedKey(nullptr),
    m_cachedKeySize(0),
    m_keyPrepared(false),
    m_pristineKey(nullptr)
{
    verus_hash_init();
    
    // Calculate key size (aligned to 32 bytes)
    m_keySize = (VERUSKEYSIZE >> 5) << 5;
    m_keyMask = verus_keymask(m_keySize);
    
    // Initialize thread-local key if needed
    if (!verusclhasher_key) {
        // Allocate key buffer: key + refresh area + scratch space
        size_t totalSize = m_keySize * 2 + sizeof(__m128i*) * 2;
        verusclhasher_key = alloc_aligned_buffer(totalSize);
        if (verusclhasher_key) {
            verusclhasher_descr_ptr = (verusclhash_descr*)alloc_aligned_buffer(sizeof(verusclhash_descr));
            if (verusclhasher_descr_ptr) {
                verusclhasher_descr_ptr->keySizeInBytes = m_keySize;
                memset(verusclhasher_descr_ptr->seed, 0, 32);
            }
        }
    }
    
    // Allocate pristine key backup buffer
    m_pristineKey = (u128*)alloc_aligned_buffer(VERUSKEYSIZE);
    
    // Initialize FixKey state (kept for compatibility)
    memset(m_fixRand, 0, sizeof(m_fixRand));
    memset(m_fixRandEx, 0, sizeof(m_fixRandEx));
    memset(m_pRand, 0, sizeof(m_pRand));
    memset(m_pRandEx, 0, sizeof(m_pRandEx));
    
    reset();
}

Hasher::~Hasher() {
    // Thread-local resources are cleaned up when thread exits
}

void Hasher::reset() {
    m_curBuf = m_buf1;
    m_result = m_buf2;
    m_curPos = 0;
    memset(m_buf1, 0, sizeof(m_buf1));
}

void Hasher::init(const uint8_t* header, size_t len) {
    m_headerLen = std::min(len, sizeof(m_header));
    memcpy(m_header, header, m_headerLen);
}

void Hasher::write(const uint8_t* data, size_t len) {
    size_t pos = 0;
    
    while (pos < len) {
        size_t room = 32 - m_curPos;
        
        if (len - pos >= room) {
            memcpy(m_curBuf + 32 + m_curPos, data + pos, room);
            haraka512(m_result, m_curBuf);
            
            // Swap buffers
            uint8_t* tmp = m_curBuf;
            m_curBuf = m_result;
            m_result = tmp;
            
            pos += room;
            m_curPos = 0;
        } else {
            memcpy(m_curBuf + 32 + m_curPos, data + pos, len - pos);
            m_curPos += len - pos;
            pos = len;
        }
    }
}

void Hasher::genNewCLKey(const uint8_t* seedBytes32) {
    // Generate CLHash key by chain hashing with Haraka256 from the seed
    // This exactly matches ccminer's GenNewCLKey
    
    uint8_t* key = (uint8_t*)verusclhasher_key;
    if (!key) return;
    
    int n256blks = VERUSKEYSIZE >> 5;  // 8832 >> 5 = 276
    int nbytesExtra = VERUSKEYSIZE & 0x1f;  // 8832 & 31 = 0
    
    uint8_t* pkey = key;
    const uint8_t* psrc = seedBytes32;
    
    for (int i = 0; i < n256blks; i++) {
        haraka256(pkey, psrc);
        psrc = pkey;
        pkey += 32;
    }
    
    if (nbytesExtra) {
        uint8_t buf[32];
        haraka256(buf, psrc);
        memcpy(pkey, buf, nbytesExtra);
    }
    
    m_cachedKey = (u128*)key;
    m_cachedKeySize = VERUSKEYSIZE;
}

void Hasher::fixKey() {
    // Restore modified key entries - matches ccminer's FixKey
    if (!m_cachedKey) return;
    
    for (int i = 31; i >= 0; i--) {
        m_cachedKey[m_fixRandEx[i]] = m_pRandEx[i];
        m_cachedKey[m_fixRand[i]] = m_pRand[i];
    }
}

uint64_t Hasher::intermediateTo128Offset(uint64_t intermediate) {
    // The mask determines where we wrap in the key
    return intermediate & (m_keyMask >> 4);
}

void Hasher::fillExtra(const u128* data) {
    const uint8_t* src = (const uint8_t*)data;
    int pos = m_curPos;
    int left = 32 - pos;
    
    do {
        int len = left > 16 ? 16 : left;
        memcpy(m_curBuf + 32 + pos, src, len);
        pos += len;
        left -= len;
    } while (left > 0);
}

void Hasher::fillExtra64(uint64_t data) {
    const uint8_t* src = (const uint8_t*)&data;
    int pos = m_curPos;
    int left = 32 - pos;
    
    do {
        int len = left > 8 ? 8 : left;
        memcpy(m_curBuf + 32 + pos, src, len);
        pos += len;
        left -= len;
    } while (left > 0);
}

void Hasher::finalize2b(uint8_t* hash) {
    fillExtra((u128*)m_curBuf);
    
    genNewCLKey(m_curBuf);
    if (!m_cachedKey) {
        haraka512(hash, m_curBuf);
        return;
    }
    
    uint64_t keyrefreshsize = m_keyMask + 1;
    __m128i** pMoveScratch = (__m128i**)((uint8_t*)m_cachedKey + verusclhasher_descr_ptr->keySizeInBytes + keyrefreshsize);
    
    __m128i acc;
    if (m_solutionVersion >= SOLUTION_VERUSHHASH_V2_2) {
        acc = __verusclmulwithoutreduction64alignedrepeat_sv2_2(m_cachedKey, (const __m128i*)m_curBuf, m_keyMask, pMoveScratch);
    } else if (m_solutionVersion >= SOLUTION_VERUSHHASH_V2_1) {
        acc = __verusclmulwithoutreduction64alignedrepeat_sv2_1(m_cachedKey, (const __m128i*)m_curBuf, m_keyMask, pMoveScratch);
    } else {
        acc = __verusclmulwithoutreduction64alignedrepeat(m_cachedKey, (const __m128i*)m_curBuf, m_keyMask, pMoveScratch);
    }
    
    const __m128i lengthvector = _mm_set_epi64x(1024, 64);
    const __m128i clprod1 = _mm_clmulepi64_si128(lengthvector, lengthvector, 0x10);
    acc = _mm_xor_si128(acc, clprod1);
    
    const __m128i C = _mm_cvtsi64_si128((1U<<4)+(1U<<3)+(1U<<1)+(1U<<0));
    __m128i Q2 = _mm_clmulepi64_si128(acc, C, 0x01);
    __m128i Q3 = _mm_shuffle_epi8(_mm_setr_epi8(0, 27, 54, 45, 108, 119, 90, 65, 
                                                (char)216, (char)195, (char)238, (char)245, 
                                                (char)180, (char)175, (char)130, (char)153),
                                  _mm_srli_si128(Q2, 8));
    __m128i Q4 = _mm_xor_si128(Q2, acc);
    acc = _mm_xor_si128(Q3, Q4);
    uint64_t intermediate = _mm_cvtsi128_si64(acc);
    
    fillExtra64(intermediate);
    haraka512_keyed(hash, m_curBuf, m_cachedKey + intermediateTo128Offset(intermediate));
}

void Hasher::hash(uint32_t nonce, uint8_t* output) {
    reset();
    
    alignas(32) uint8_t work[256];
    memcpy(work, m_header, m_headerLen);
    
    size_t noncePos = 76;
    memcpy(work + noncePos, &nonce, 4);
    
    write(work, m_headerLen > 0 ? m_headerLen : 80);
    finalize2b(output);
}

void Hasher::hash_raw(const uint8_t* data, size_t len, uint8_t* output) {
    reset();
    write(data, len);
    finalize2b(output);
}

void Hasher::hash_half(const uint8_t* data, size_t len, uint8_t* intermediate64) {
    // Compute intermediate state from full block data
    // This exactly matches ccminer's VerusHashHalf
    
    alignas(32) uint8_t buf1[64] = {0};
    alignas(32) uint8_t buf2[64];
    uint8_t* curBuf = buf1;
    uint8_t* result = buf2;
    size_t curPos = 0;
    
    // Digest up to 32 bytes at a time with Haraka512
    for (size_t pos = 0; pos < len; ) {
        size_t room = 32 - curPos;
        
        if (len - pos >= room) {
            memcpy(curBuf + 32 + curPos, data + pos, room);
            haraka512(result, curBuf);
            
            // Swap buffers
            uint8_t* tmp = curBuf;
            curBuf = result;
            result = tmp;
            
            pos += room;
            curPos = 0;
        } else {
            memcpy(curBuf + 32 + curPos, data + pos, len - pos);
            curPos += len - pos;
            pos = len;
        }
    }
    
    // FillExtra - exactly as in ccminer:
    // memcpy(curBuf + 47, curBuf, 16);
    // memcpy(curBuf + 63, curBuf, 1);
    memcpy(curBuf + 47, curBuf, 16);
    memcpy(curBuf + 63, curBuf, 1);
    
    // Return the 64-byte intermediate state
    memcpy(intermediate64, curBuf, 64);
}

void Hasher::prepare_key(const uint8_t* intermediate64) {
    // Generate CLHash key from intermediate state
    // This must be called once per job after hash_half
    genNewCLKey(intermediate64);
    m_keyPrepared = (m_cachedKey != nullptr);
    
    // Save pristine copy of key for restoration before each hash
    // This is more reliable than the FixKey mechanism
    if (m_keyPrepared && m_pristineKey && m_cachedKey) {
        memcpy(m_pristineKey, m_cachedKey, VERUSKEYSIZE);
    }
}

void Hasher::hash_with_nonce(const uint8_t* intermediate64, const uint8_t* nonceSpace15, uint8_t* output) {
    // Compute final hash from intermediate state + 15-byte nonceSpace
    // This matches ccminer's Verus2hash exactly
    
    // Ensure key is prepared
    if (!m_keyPrepared || !m_cachedKey || !m_pristineKey) {
        prepare_key(intermediate64);
        if (!m_cachedKey || !m_pristineKey) {
            memset(output, 0, 32);
            return;
        }
    }
    
    // Restore key from pristine backup before each hash
    // CLHash modifies the key, so we need to restore it each time
    // This is faster than FixKey and more reliable
    memcpy(m_cachedKey, m_pristineKey, VERUSKEYSIZE);
    
    // Work on a copy of the intermediate
    alignas(32) uint8_t curBuf[64];
    memcpy(curBuf, intermediate64, 64);
    
    // FillExtra - shuffle and fill BEFORE copying nonce
    // This matches ccminer's Verus2hash order exactly:
    // static const __m128i shuf1 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0);
    // fill1 = shuffle(curBuf[0..15], shuf1)
    // _mm_store_si128(&curBuf[48], fill1)
    // curBuf[47] = curBuf[0]
    // memcpy(curBuf + 32, nonce, 15)
    
    __m128i src = _mm_load_si128((const __m128i*)curBuf);
    const __m128i shuf1 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0);
    __m128i fill1 = _mm_shuffle_epi8(src, shuf1);
    uint8_t ch = curBuf[0];
    _mm_store_si128((__m128i*)(curBuf + 48), fill1);
    curBuf[47] = ch;
    
    // Copy the 15-byte nonceSpace to positions 32-46
    memcpy(curBuf + 32, nonceSpace15, 15);
    
    // Run CLHash v2.2
    // ccminer passes 511 directly (keyMask already divided by 16)
    uint64_t clhash_result = verusclhashv2_2_full(
        m_cachedKey, curBuf, 511,
        m_fixRand, m_fixRandEx, m_pRand, m_pRandEx);
    
    // FillExtra with CLHash result
    // ccminer: static const __m128i shuf2 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0);
    //          fill2 = _mm_shuffle_epi8(_mm_loadl_epi64(&intermediate), shuf2);
    //          _mm_store_si128(&curBuf[48], fill2);
    //          curBuf[47] = intermediate[0];
    const __m128i shuf2 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0);
    __m128i intVec = _mm_loadl_epi64((const __m128i*)&clhash_result);
    __m128i fill2 = _mm_shuffle_epi8(intVec, shuf2);
    _mm_store_si128((__m128i*)(curBuf + 48), fill2);
    curBuf[47] = ((const uint8_t*)&clhash_result)[0];
    
    // Mask for key offset (happens AFTER fill in ccminer)
    // ccminer: intermediate &= 511;
    uint64_t keyOffset = clhash_result & 511;
    
    // Final keyed Haraka512
    haraka512_keyed(output, curBuf, m_cachedKey + keyOffset);
    
    // Key restoration happens at the start of next hash_with_nonce call
}

void Hasher::hash_batch(const uint32_t* nonces, uint8_t* outputs, size_t count) {
    for (size_t i = 0; i < count; i++) {
        hash(nonces[i], outputs + i * 32);
    }
}

} // namespace verus
