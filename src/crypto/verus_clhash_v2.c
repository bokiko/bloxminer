/*
 * VerusCLHash v2.2 Implementation for BloxMiner
 * 
 * This is a complete rewrite matching ccminer's implementation exactly.
 * Includes proper FixKey mechanism for key restoration.
 *
 * Based on the official VerusCoin implementation by Michael Toutonghi.
 * Original CLHash by Daniel Lemire.
 * 
 * Copyright (c) 2018 Michael Toutonghi
 * Licensed under Apache 2.0
 */

#include "verus_clhash.h"
#include <string.h>
#include <stdlib.h>

// Thread-local key storage
__thread void *verusclhasher_key_v2 = NULL;
__thread verusclhash_descr *verusclhasher_descr_ptr_v2 = NULL;

// Lazy length hash - multiply length and key
static inline __attribute__((always_inline)) __m128i lazyLengthHash_v2(uint64_t keylength, uint64_t length) {
    const __m128i lengthvector = _mm_set_epi64x(keylength, length);
    const __m128i clprod1 = _mm_clmulepi64_si128(lengthvector, lengthvector, 0x10);
    return clprod1;
}

// Modulo reduction to 64-bit value
static inline __attribute__((always_inline)) uint64_t precompReduction64_v2(__m128i A) {
    const __m128i C = _mm_cvtsi64_si128((1U << 4) + (1U << 3) + (1U << 1) + (1U << 0));
    __m128i Q2 = _mm_clmulepi64_si128(A, C, 0x01);
    __m128i Q3 = _mm_shuffle_epi8(_mm_setr_epi8(0, 27, 54, 45, 108, 119, 90, 65,
                                                (char)216, (char)195, (char)238, (char)245,
                                                (char)180, (char)175, (char)130, (char)153),
                                  _mm_srli_si128(Q2, 8));
    __m128i Q4 = _mm_xor_si128(Q2, A);
    __m128i final = _mm_xor_si128(Q3, Q4);
    return _mm_cvtsi128_si64(final);
}

// FixKey - restore modified key entries
// This MUST be called after each CLHash to restore the key for the next hash
void verus_fixkey(uint32_t *fixrand, uint32_t *fixrandex, u128 *keyback,
                  u128 *g_prand, u128 *g_prandex) {
    for (int i = 31; i >= 0; i--) {
        keyback[fixrandex[i]] = g_prandex[i];
        keyback[fixrand[i]] = g_prand[i];
    }
}

// CLHash v2.2 internal implementation - MATCHES CCMINER EXACTLY
// Note: keyMask should be 511 (already divided by 16)
__m128i __verusclmulwithoutreduction64alignedrepeat_v2_2_full(
    __m128i *randomsource,
    const __m128i buf[4],
    uint64_t keyMask,
    uint32_t *fixrand,
    uint32_t *fixrandex,
    u128 *g_prand,
    u128 *g_prandex)
{
    const __m128i pbuf_copy[4] = {
        _mm_xor_si128(buf[0], buf[2]),
        _mm_xor_si128(buf[1], buf[3]),
        buf[2],
        buf[3]
    };
    const __m128i *pbuf;

    // The random buffer must have at least 32 16-byte dwords after the keymask
    // Take the value from the last element inside keyMask + 2
    __m128i acc = _mm_load_si128(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++) {
        const uint64_t selector = _mm_cvtsi128_si64(acc);

        uint32_t prand_idx = (selector >> 5) & keyMask;
        uint32_t prandex_idx = (selector >> 32) & keyMask;

        // Get two random locations in the key, which will be mutated
        __m128i *prand = randomsource + prand_idx;
        __m128i *prandex = randomsource + prandex_idx;

        // Select random start and order of pbuf processing
        pbuf = pbuf_copy + (selector & 3);

        // Save original values BEFORE modification for FixKey
        _mm_store_si128(&g_prand[i], prand[0]);
        _mm_store_si128(&g_prandex[i], prandex[0]);
        fixrand[i] = prand_idx;
        fixrandex[i] = prandex_idx;

        switch (selector & 0x1c) {
            case 0: {
                const __m128i temp1 = _mm_load_si128(prandex);
                const __m128i temp2 = pbuf[(selector & 1) ? -1 : 1];
                const __m128i add1 = _mm_xor_si128(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                const __m128i temp12 = _mm_load_si128(prand);
                _mm_store_si128(prand, tempa2);

                const __m128i temp22 = _mm_load_si128(pbuf);
                const __m128i add12 = _mm_xor_si128(temp12, temp22);
                const __m128i clprod12 = _mm_clmulepi64_si128(add12, add12, 0x10);
                acc = _mm_xor_si128(clprod12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prandex, tempb2);
                break;
            }
            case 4: {
                const __m128i temp1 = _mm_load_si128(prand);
                const __m128i temp2 = _mm_load_si128(pbuf);
                const __m128i add1 = _mm_xor_si128(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);
                const __m128i clprod2 = _mm_clmulepi64_si128(temp2, temp2, 0x10);
                acc = _mm_xor_si128(clprod2, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                const __m128i temp12 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa2);

                const __m128i temp22 = pbuf[(selector & 1) ? -1 : 1];
                const __m128i add12 = _mm_xor_si128(temp12, temp22);
                acc = _mm_xor_si128(add12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                _mm_store_si128(prand, _mm_xor_si128(tempb1, temp12));
                break;
            }
            case 8: {
                const __m128i temp1 = _mm_load_si128(prandex);
                const __m128i temp2 = _mm_load_si128(pbuf);
                const __m128i add1 = _mm_xor_si128(temp1, temp2);
                acc = _mm_xor_si128(add1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                const __m128i temp12 = _mm_load_si128(prand);
                _mm_store_si128(prand, tempa2);

                const __m128i temp22 = pbuf[(selector & 1) ? -1 : 1];
                const __m128i add12 = _mm_xor_si128(temp12, temp22);
                const __m128i clprod12 = _mm_clmulepi64_si128(add12, add12, 0x10);
                acc = _mm_xor_si128(clprod12, acc);
                const __m128i clprod22 = _mm_clmulepi64_si128(temp22, temp22, 0x10);
                acc = _mm_xor_si128(clprod22, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prandex, tempb2);
                break;
            }
            case 0xc: {
                const __m128i temp1 = _mm_load_si128(prand);
                const __m128i temp2 = pbuf[(selector & 1) ? -1 : 1];
                const __m128i add1 = _mm_xor_si128(temp1, temp2);

                // Cannot be zero here
                const int32_t divisor = (uint32_t)selector;

                acc = _mm_xor_si128(add1, acc);

                const int64_t dividend = _mm_cvtsi128_si64(acc);
                const __m128i modulo = _mm_cvtsi32_si128(dividend % divisor);
                acc = _mm_xor_si128(modulo, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                if (dividend & 1) {
                    const __m128i temp12 = _mm_load_si128(prandex);
                    _mm_store_si128(prandex, tempa2);

                    const __m128i temp22 = _mm_load_si128(pbuf);
                    const __m128i add12 = _mm_xor_si128(temp12, temp22);
                    const __m128i clprod12 = _mm_clmulepi64_si128(add12, add12, 0x10);
                    acc = _mm_xor_si128(clprod12, acc);
                    const __m128i clprod22 = _mm_clmulepi64_si128(temp22, temp22, 0x10);
                    acc = _mm_xor_si128(clprod22, acc);

                    const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                    const __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                    _mm_store_si128(prand, tempb2);
                } else {
                    _mm_store_si128(prand, _mm_load_si128(prandex));
                    _mm_store_si128(prandex, tempa2);
                    acc = _mm_xor_si128(_mm_load_si128(pbuf), acc);
                }
                break;
            }
            case 0x10: {
                // A few AES operations
                // CRITICAL: The variable MUST be named 'rc' to shadow the global rc
                // so that AES2 macro uses key bytes instead of Haraka round constants
                const __m128i *rc = prand;
                __m128i tmp;

                __m128i temp1 = pbuf[(selector & 1) ? -1 : 1];
                __m128i temp2 = _mm_load_si128(pbuf);

                AES2(temp1, temp2, 0);
                MIX2(temp1, temp2);

                AES2(temp1, temp2, 4);
                MIX2(temp1, temp2);

                AES2(temp1, temp2, 8);
                MIX2(temp1, temp2);

                acc = _mm_xor_si128(temp2, _mm_xor_si128(temp1, acc));

                const __m128i tempa1 = _mm_load_si128(prand);
                const __m128i tempa2 = _mm_mulhrs_epi16(acc, tempa1);

                _mm_store_si128(prand, _mm_load_si128(prandex));
                _mm_store_si128(prandex, _mm_xor_si128(tempa1, tempa2));
                break;
            }
            case 0x14: {
                // The monkins loop
                // CRITICAL: Variable MUST be named 'rc' to shadow global rc
                // so that AES2 macro uses key bytes from the moving pointer
                const __m128i *buftmp = &pbuf[(selector & 1) ? -1 : 1];
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc = prand;
                uint64_t aesroundoffset = 0;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        const __m128i add1 = _mm_xor_si128(rc[0], temp2); rc++;
                        const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                        acc = _mm_xor_si128(clprod1, acc);
                    } else {
                        onekey = _mm_load_si128(rc++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? buftmp : pbuf);
                        AES2(onekey, temp2, aesroundoffset);
                        aesroundoffset += 4;
                        MIX2(onekey, temp2);
                        acc = _mm_xor_si128(onekey, acc);
                        acc = _mm_xor_si128(temp2, acc);
                    }
                } while (rounds--);

                const __m128i tempa1 = _mm_load_si128(prand);
                const __m128i tempa2 = _mm_mulhrs_epi16(acc, tempa1);
                const __m128i tempa3 = _mm_xor_si128(tempa1, tempa2);

                const __m128i tempa4 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa3);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x18: {
                // CRITICAL: Variable MUST be named 'rc' to shadow global rc
                const __m128i *buftmp = &pbuf[(selector & 1) ? -1 : 1];
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc = prand;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        onekey = _mm_xor_si128(rc[0], temp2); rc++;
                        const int32_t divisor = (uint32_t)selector;
                        const int64_t dividend = _mm_cvtsi128_si64(onekey);
                        const __m128i modulo = _mm_cvtsi32_si128(dividend % divisor);
                        acc = _mm_xor_si128(modulo, acc);
                    } else {
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? buftmp : pbuf);
                        const __m128i add1 = _mm_xor_si128(rc[0], temp2); rc++;
                        onekey = _mm_clmulepi64_si128(add1, add1, 0x10);
                        const __m128i clprod2 = _mm_mulhrs_epi16(acc, onekey);
                        acc = _mm_xor_si128(clprod2, acc);
                    }
                } while (rounds--);

                const __m128i tempa3 = _mm_load_si128(prandex);

                _mm_store_si128(prandex, onekey);
                _mm_store_si128(prand, _mm_xor_si128(tempa3, acc));
                break;
            }
            case 0x1c: {
                const __m128i temp1 = _mm_load_si128(pbuf);
                const __m128i temp2 = _mm_load_si128(prandex);
                const __m128i add1 = _mm_xor_si128(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16(acc, temp2);
                const __m128i tempa2 = _mm_xor_si128(tempa1, temp2);

                const __m128i tempa3 = _mm_load_si128(prand);
                _mm_store_si128(prand, tempa2);

                acc = _mm_xor_si128(tempa3, acc);
                const __m128i temp4 = pbuf[(selector & 1) ? -1 : 1];
                acc = _mm_xor_si128(temp4, acc);
                const __m128i tempb1 = _mm_mulhrs_epi16(acc, tempa3);
                *prandex = _mm_xor_si128(tempb1, tempa3);
                break;
            }
        }
    }
    return acc;
}

// Full verusclhash v2.2 with FixKey support
uint64_t verusclhashv2_2_full(
    void *random,
    const unsigned char buf[64],
    uint64_t keyMask,
    uint32_t *fixrand,
    uint32_t *fixrandex,
    u128 *g_prand,
    u128 *g_prandex)
{
    // Note: ccminer passes 511 directly (keyMask already divided by 16)
    __m128i acc = __verusclmulwithoutreduction64alignedrepeat_v2_2_full(
        (__m128i *)random, (const __m128i *)buf, 511,
        fixrand, fixrandex, g_prand, g_prandex);
    acc = _mm_xor_si128(acc, lazyLengthHash_v2(1024, 64));
    return precompReduction64_v2(acc);
}
