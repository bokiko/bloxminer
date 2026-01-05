/*
 * VerusCLHash - Carry-less multiplication hash for VerusHash v2
 * 
 * Based on CLHash by Daniel Lemire, modified for VerusCoin.
 * Ported to BloxMiner by Bokiko, 2026.
 *
 * Copyright (c) 2018 Michael Toutonghi
 * Distributed under the Apache 2.0 software license.
 */

#ifndef BLOXMINER_VERUS_CLHASH_H
#define BLOXMINER_VERUS_CLHASH_H

#include <stdint.h>
#include <stddef.h>
#include <cpuid.h>
#include <x86intrin.h>

#include "haraka.h"

#ifdef __cplusplus
extern "C" {
#endif

// VerusHash key constants - must match official implementation
#define VERUSKEYSIZE        (1024 * 8 + (40 * 16))  // 8832 bytes
#define VERUS_KEY_SIZE      VERUSKEYSIZE
#define VERUS_KEY_SIZE128   (VERUSKEYSIZE / 16)     // 552

// Solution versions
#define SOLUTION_VERUSHHASH_V2      1
#define SOLUTION_VERUSHHASH_V2_1    3
#define SOLUTION_VERUSHHASH_V2_2    4

// Key descriptor structure
typedef struct {
    uint8_t seed[32] __attribute__((aligned(32)));
    uint32_t keySizeInBytes;
} verusclhash_descr;

// Thread-local storage wrapper
typedef struct {
    void *ptr;
} thread_specific_ptr;

// Thread-local key storage
extern __thread void *verusclhasher_key;
extern __thread verusclhash_descr *verusclhasher_descr_ptr;

// CPU feature detection
extern int __cpuverusoptimized;

static inline int IsCPUVerusOptimized(void) {
    if (__cpuverusoptimized & 0x80) {
        unsigned int eax, ebx, ecx, edx;
        if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) {
            __cpuverusoptimized = 0;
        } else {
            __cpuverusoptimized = ((ecx & (bit_AVX | bit_AES | bit_PCLMUL)) == (bit_AVX | bit_AES | bit_PCLMUL));
        }
    }
    return __cpuverusoptimized;
}

// Allocate aligned buffer
void *alloc_aligned_buffer(uint64_t bufSize);

// Free thread-local resources
void verus_clhash_cleanup(void);

// Key mask calculation - returns power of 2 minus 1
static inline uint64_t verus_keymask(uint64_t keysize) {
    int i = 0;
    while (keysize >>= 1) {
        i++;
    }
    return i ? (((uint64_t)1) << i) - 1 : 0;
}

// Main VerusCLHash functions - returns 64-bit intermediate hash
// All versions take: random key buffer, 64-byte input buffer, key mask, scratch pointer array
uint64_t verusclhash(void *random, const unsigned char buf[64], uint64_t keyMask, __m128i **pMoveScratch);
uint64_t verusclhash_sv2_1(void *random, const unsigned char buf[64], uint64_t keyMask, __m128i **pMoveScratch);
uint64_t verusclhash_sv2_2(void *random, const unsigned char buf[64], uint64_t keyMask, __m128i **pMoveScratch);

// Internal CLHash functions
__m128i __verusclmulwithoutreduction64alignedrepeat(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch);
__m128i __verusclmulwithoutreduction64alignedrepeat_sv2_1(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch);
__m128i __verusclmulwithoutreduction64alignedrepeat_sv2_2(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch);

#ifdef __cplusplus
}
#endif

#endif // BLOXMINER_VERUS_CLHASH_H
