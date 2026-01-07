/*
 * CLHash Comparison Test
 * 
 * Compares our verusclhashv2_2_full() with ccminer's verusclhashv2_2()
 * on identical inputs to find where they diverge.
 */

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <x86intrin.h>

// Include our implementation
#include "../src/crypto/verus_clhash.h"
#include "../src/crypto/haraka.h"

// Forward declare ccminer's implementation (we'll include the source directly)
extern "C" {
    // From ccminer - we need to rename to avoid conflicts
    uint64_t ccminer_verusclhashv2_2(void *random, const unsigned char buf[64], uint64_t keyMask,
        uint32_t *fixrand, uint32_t *fixrandex, u128 *g_prand, u128 *g_prandex);
}

void print_hex(const char* label, const uint8_t* data, size_t len) {
    printf("%s: ", label);
    for (size_t i = 0; i < len; i++) {
        printf("%02x", data[i]);
    }
    printf("\n");
}

void print_key_segment(const char* label, const u128* key, int start, int count) {
    printf("%s [%d..%d]:\n", label, start, start + count - 1);
    for (int i = 0; i < count; i++) {
        printf("  [%3d]: ", start + i);
        const uint8_t* p = (const uint8_t*)&key[start + i];
        for (int j = 0; j < 16; j++) {
            printf("%02x", p[j]);
        }
        printf("\n");
    }
}

int main() {
    printf("=== CLHash Comparison Test ===\n\n");
    
    // Initialize Haraka constants
    load_constants();
    
    // Create aligned buffers
    alignas(32) uint8_t curBuf[64];
    alignas(32) uint8_t key1[VERUSKEYSIZE];  // Our key
    alignas(32) uint8_t key2[VERUSKEYSIZE];  // CCMiner's key (copy)
    
    // FixKey arrays
    uint32_t fixrand1[32], fixrandex1[32];
    uint32_t fixrand2[32], fixrandex2[32];
    u128 prand1[32], prandex1[32];
    u128 prand2[32], prandex2[32];
    
    // Initialize with a deterministic pattern for reproducibility
    // This simulates what hash_half would produce
    printf("Generating test inputs...\n");
    
    // Generate a deterministic intermediate state (like hash_half output)
    alignas(32) uint8_t seed[32];
    for (int i = 0; i < 32; i++) {
        seed[i] = (uint8_t)(i * 17 + 42);  // Arbitrary pattern
    }
    
    // Generate curBuf - first 32 bytes from "intermediate"
    memcpy(curBuf, seed, 32);
    
    // FillExtra - like hash_half does:
    // memcpy(curBuf + 47, curBuf, 16);
    // memcpy(curBuf + 63, curBuf, 1);
    memcpy(curBuf + 47, curBuf, 16);
    memcpy(curBuf + 63, curBuf, 1);
    
    // Add nonceSpace bytes (positions 32-46)
    for (int i = 0; i < 15; i++) {
        curBuf[32 + i] = (uint8_t)(i + 0x10);
    }
    
    // Now apply Verus2hash-style FillExtra (shuffle pattern)
    // This overwrites positions 47-63
    __m128i src = _mm_load_si128((const __m128i*)curBuf);
    const __m128i shuf1 = _mm_setr_epi8(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0);
    __m128i fill1 = _mm_shuffle_epi8(src, shuf1);
    uint8_t ch = curBuf[0];
    _mm_store_si128((__m128i*)(curBuf + 48), fill1);
    curBuf[47] = ch;
    
    print_hex("curBuf (64 bytes)", curBuf, 64);
    printf("\n");
    
    // Generate key using haraka256 chain (like genNewCLKey)
    printf("Generating CLHash key (8832 bytes via Haraka256 chain)...\n");
    {
        int n256blks = VERUSKEYSIZE >> 5;  // 276 iterations
        uint8_t* pkey = key1;
        const uint8_t* psrc = curBuf;  // Use first 32 bytes as seed
        
        for (int i = 0; i < n256blks; i++) {
            haraka256(pkey, psrc);
            psrc = pkey;
            pkey += 32;
        }
    }
    
    // Copy key for ccminer (so both start with identical keys)
    memcpy(key2, key1, VERUSKEYSIZE);
    
    // Verify keys are identical
    if (memcmp(key1, key2, VERUSKEYSIZE) == 0) {
        printf("Keys are identical: OK\n");
    } else {
        printf("ERROR: Keys differ!\n");
        return 1;
    }
    
    // Show key[513] - the initial accumulator value
    printf("\nKey[513] (initial acc):\n");
    print_hex("  key1[513]", (uint8_t*)&((u128*)key1)[513], 16);
    print_hex("  key2[513]", (uint8_t*)&((u128*)key2)[513], 16);
    
    printf("\n=== Running CLHash implementations ===\n\n");
    
    // Run our implementation
    printf("Running our verusclhashv2_2_full...\n");
    uint64_t result1 = verusclhashv2_2_full(
        key1, curBuf, 511,
        fixrand1, fixrandex1, prand1, prandex1);
    
    printf("Our result: 0x%016lx\n\n", result1);
    
    // Run ccminer's implementation
    printf("Running ccminer's verusclhashv2_2...\n");
    uint64_t result2 = ccminer_verusclhashv2_2(
        key2, curBuf, 511,
        fixrand2, fixrandex2, prand2, prandex2);
    
    printf("CCMiner result: 0x%016lx\n\n", result2);
    
    // Compare
    printf("=== Comparison ===\n");
    if (result1 == result2) {
        printf("PASS: Results match!\n");
    } else {
        printf("FAIL: Results differ!\n");
        printf("  Our result:     0x%016lx\n", result1);
        printf("  CCMiner result: 0x%016lx\n", result2);
        printf("  XOR difference: 0x%016lx\n", result1 ^ result2);
        
        // Compare FixKey arrays to see where divergence started
        printf("\nComparing FixKey arrays...\n");
        for (int i = 0; i < 32; i++) {
            if (fixrand1[i] != fixrand2[i] || fixrandex1[i] != fixrandex2[i]) {
                printf("Divergence at iteration %d:\n", i);
                printf("  fixrand:   ours=%u, theirs=%u\n", fixrand1[i], fixrand2[i]);
                printf("  fixrandex: ours=%u, theirs=%u\n", fixrandex1[i], fixrandex2[i]);
                break;
            }
            if (memcmp(&prand1[i], &prand2[i], 16) != 0 || 
                memcmp(&prandex1[i], &prandex2[i], 16) != 0) {
                printf("Divergence in saved values at iteration %d:\n", i);
                print_hex("  prand ours", (uint8_t*)&prand1[i], 16);
                print_hex("  prand theirs", (uint8_t*)&prand2[i], 16);
                break;
            }
        }
    }
    
    printf("\n=== Test Complete ===\n");
    return (result1 == result2) ? 0 : 1;
}
