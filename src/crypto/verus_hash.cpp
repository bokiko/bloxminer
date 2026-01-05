/*
 * VerusHash v2.x Implementation for BloxMiner
 * 
 * Based on the official VerusCoin implementation.
 * Ported by Bokiko, 2026.
 */

#include "verus_hash.h"
#include <cstring>
#include <algorithm>

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

// VerusHash v2.0 - Haraka512 chain hash
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
    m_solutionVersion(solutionVersion) 
{
    verus_hash_init();
    
    // Calculate key size (aligned to 32 bytes)
    m_keySize = (VERUSKEYSIZE >> 5) << 5;
    m_keyMask = verus_keymask(m_keySize);
    
    // Initialize thread-local key if needed
    if (!verusclhasher_key) {
        verusclhasher_key = alloc_aligned_buffer(m_keySize << 1);
        if (verusclhasher_key) {
            verusclhasher_descr_ptr = (verusclhash_descr*)alloc_aligned_buffer(sizeof(verusclhash_descr));
            if (verusclhasher_descr_ptr) {
                verusclhasher_descr_ptr->keySizeInBytes = m_keySize;
                memset(verusclhasher_descr_ptr->seed, 0, 32);
            }
        }
    }
    
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

u128* Hasher::genNewCLKey(uint8_t* seedBytes32) {
    uint8_t* key = (uint8_t*)verusclhasher_key;
    verusclhash_descr* pdesc = verusclhasher_descr_ptr;
    
    if (!key || !pdesc) return nullptr;
    
    uint32_t size = pdesc->keySizeInBytes;
    uint64_t refreshsize = m_keyMask + 1;
    
    // Check if we need to regenerate key
    if (memcmp(pdesc->seed, seedBytes32, 32) != 0) {
        // Generate new key by chain hashing with Haraka256
        int n256blks = size >> 5;
        uint8_t* pkey = key;
        uint8_t* psrc = seedBytes32;
        
        for (int i = 0; i < n256blks; i++) {
            haraka256(pkey, psrc);
            psrc = pkey;
            pkey += 32;
        }
        
        // Store seed and copy for refresh
        memcpy(pdesc->seed, seedBytes32, 32);
        memcpy(key + size, key, refreshsize);
    } else {
        // Refresh key from backup
        memcpy(key, key + size, refreshsize);
    }
    
    // Clear remaining area
    memset(key + size + refreshsize, 0, size - refreshsize);
    
    return (u128*)key;
}

uint64_t Hasher::intermediateTo128Offset(uint64_t intermediate) {
    // The mask is where we wrap
    uint64_t mask = m_keyMask >> 4;
    return intermediate & mask;
}

void Hasher::finalize2b(uint8_t* hash) {
    // Fill extra space with beginning of buffer
    const __m128i shuf1 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0);
    const __m128i fill1 = _mm_shuffle_epi8(_mm_load_si128((u128*)m_curBuf), shuf1);
    _mm_store_si128((u128*)(m_curBuf + 32 + 16), fill1);
    m_curBuf[32 + 15] = m_curBuf[0];
    
    // Generate key from current buffer
    u128* key = genNewCLKey(m_curBuf);
    if (!key) {
        // Fallback: just do haraka512
        haraka512(hash, m_curBuf);
        return;
    }
    
    // Get scratch pointer area
    uint64_t keyrefreshsize = m_keyMask + 1;
    __m128i** pMoveScratch = (__m128i**)((uint8_t*)key + verusclhasher_descr_ptr->keySizeInBytes + keyrefreshsize);
    
    // Run VerusCLHash on the buffer
    __m128i acc;
    if (m_solutionVersion >= SOLUTION_VERUSHHASH_V2_2) {
        acc = __verusclmulwithoutreduction64alignedrepeat_sv2_2(key, (const __m128i*)m_curBuf, m_keyMask, pMoveScratch);
    } else if (m_solutionVersion >= SOLUTION_VERUSHHASH_V2_1) {
        acc = __verusclmulwithoutreduction64alignedrepeat_sv2_1(key, (const __m128i*)m_curBuf, m_keyMask, pMoveScratch);
    } else {
        acc = __verusclmulwithoutreduction64alignedrepeat(key, (const __m128i*)m_curBuf, m_keyMask, pMoveScratch);
    }
    
    // Apply lazy length hash and reduction
    const __m128i lengthvector = _mm_set_epi64x(1024, 64);
    const __m128i clprod1 = _mm_clmulepi64_si128(lengthvector, lengthvector, 0x10);
    acc = _mm_xor_si128(acc, clprod1);
    
    // Reduction
    const __m128i C = _mm_cvtsi64_si128((1U<<4)+(1U<<3)+(1U<<1)+(1U<<0));
    __m128i Q2 = _mm_clmulepi64_si128(acc, C, 0x01);
    __m128i Q3 = _mm_shuffle_epi8(_mm_setr_epi8(0, 27, 54, 45, 108, 119, 90, 65, 
                                                (char)216, (char)195, (char)238, (char)245, 
                                                (char)180, (char)175, (char)130, (char)153),
                                  _mm_srli_si128(Q2, 8));
    __m128i Q4 = _mm_xor_si128(Q2, acc);
    acc = _mm_xor_si128(Q3, Q4);
    uint64_t intermediate = _mm_cvtsi128_si64(acc);
    
    // Fill buffer with intermediate result
    const __m128i shuf2 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0);
    __m128i fill2 = _mm_shuffle_epi8(_mm_loadl_epi64((u128*)&intermediate), shuf2);
    _mm_store_si128((u128*)(m_curBuf + 32 + 16), fill2);
    m_curBuf[32 + 15] = *((unsigned char*)&intermediate);
    
    // Final Haraka512 with keyed round constants
    haraka512_keyed(hash, m_curBuf, key + intermediateTo128Offset(intermediate));
}

void Hasher::hash(uint32_t nonce, uint8_t* output) {
    reset();
    
    // Copy header and write nonce
    alignas(32) uint8_t work[256];
    memcpy(work, m_header, m_headerLen);
    
    // Nonce position depends on header size
    // For 80-byte headers (stratum), nonce is at offset 76
    // For 140-byte headers (native), nonce position varies
    size_t noncePos = 76;  // Standard stratum position
    if (m_headerLen >= 80) {
        memcpy(work + noncePos, &nonce, 4);
    }
    
    // Write header data
    write(work, m_headerLen > 0 ? m_headerLen : 80);
    
    // Finalize with CLHash
    finalize2b(output);
}

void Hasher::hash_raw(const uint8_t* data, size_t len, uint8_t* output) {
    reset();
    write(data, len);
    finalize2b(output);
}

void Hasher::hash_batch(const uint32_t* nonces, uint8_t* outputs, size_t count) {
    for (size_t i = 0; i < count; i++) {
        hash(nonces[i], outputs + i * 32);
    }
}

} // namespace verus
