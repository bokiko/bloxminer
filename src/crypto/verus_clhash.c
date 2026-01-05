/*
 * VerusCLHash Implementation for BloxMiner
 * 
 * Based on the official VerusCoin implementation by Michael Toutonghi.
 * Original CLHash by Daniel Lemire.
 * 
 * Copyright (c) 2018 Michael Toutonghi
 * Ported to BloxMiner by Bokiko, 2026.
 * 
 * Licensed under Apache 2.0
 */

#include "verus_clhash.h"
#include <string.h>
#include <stdlib.h>

// Global CPU optimization flag
int __cpuverusoptimized = 0x80;

// Thread-local key storage
__thread void *verusclhasher_key = NULL;
__thread verusclhash_descr *verusclhasher_descr_ptr = NULL;

// Allocate aligned buffer
void *alloc_aligned_buffer(uint64_t bufSize) {
    void *answer = NULL;
    if (posix_memalign(&answer, sizeof(__m128i) * 2, bufSize)) {
        return NULL;
    }
    return answer;
}

// Cleanup thread-local resources
void verus_clhash_cleanup(void) {
    if (verusclhasher_key) {
        free(verusclhasher_key);
        verusclhasher_key = NULL;
    }
    if (verusclhasher_descr_ptr) {
        free(verusclhasher_descr_ptr);
        verusclhasher_descr_ptr = NULL;
    }
}

// Lazy length hash - multiply length and key
static inline __attribute__((always_inline)) __m128i lazyLengthHash(uint64_t keylength, uint64_t length) {
    const __m128i lengthvector = _mm_set_epi64x(keylength, length);
    const __m128i clprod1 = _mm_clmulepi64_si128(lengthvector, lengthvector, 0x10);
    return clprod1;
}

// Modulo reduction to 64-bit value
static inline __attribute__((always_inline)) __m128i precompReduction64_si128(__m128i A) {
    const __m128i C = _mm_cvtsi64_si128((1U<<4)+(1U<<3)+(1U<<1)+(1U<<0));
    __m128i Q2 = _mm_clmulepi64_si128(A, C, 0x01);
    __m128i Q3 = _mm_shuffle_epi8(_mm_setr_epi8(0, 27, 54, 45, 108, 119, 90, 65, 
                                                (char)216, (char)195, (char)238, (char)245, 
                                                (char)180, (char)175, (char)130, (char)153),
                                  _mm_srli_si128(Q2, 8));
    __m128i Q4 = _mm_xor_si128(Q2, A);
    const __m128i final = _mm_xor_si128(Q3, Q4);
    return final;
}

static inline __attribute__((always_inline)) uint64_t precompReduction64(__m128i A) {
    return _mm_cvtsi128_si64(precompReduction64_si128(A));
}

// VerusCLHash v2.0 internal implementation
__m128i __verusclmulwithoutreduction64alignedrepeat(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch) {
    const __m128i *pbuf;

    // Divide key mask by 16 from bytes to __m128i
    keyMask >>= 4;

    // Initial accumulator from key
    __m128i acc = _mm_load_si128(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++) {
        const uint64_t selector = _mm_cvtsi128_si64(acc);

        // Get two random locations in the key
        __m128i *prand = randomsource + ((selector >> 5) & keyMask);
        __m128i *prandex = randomsource + ((selector >> 32) & keyMask);

        *(pMoveScratch++) = prand;
        *(pMoveScratch++) = prandex;

        // Select random start and order of pbuf processing
        pbuf = buf + (selector & 3);

        switch (selector & 0x1c) {
            case 0: {
                const __m128i temp1 = _mm_load_si128(prandex);
                const __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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

                const __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add12 = _mm_xor_si128(temp12, temp22);
                acc = _mm_xor_si128(add12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prand, tempb2);
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

                const __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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
                const __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add1 = _mm_xor_si128(temp1, temp2);

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
                    const __m128i tempb3 = _mm_load_si128(prandex);
                    _mm_store_si128(prandex, tempa2);
                    _mm_store_si128(prand, tempb3);
                }
                break;
            }
            case 0x10: {
                // A few AES operations
                const __m128i *rc_ptr = prand;
                __m128i tmp;

                __m128i temp1 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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
                const __m128i tempa3 = _mm_xor_si128(tempa1, tempa2);

                const __m128i tempa4 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa3);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x14: {
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc_ptr = prand;
                uint64_t aesroundoffset = 0;
                __m128i onekey;

                do {
                    if (selector & (0x10000000 << rounds)) {
                        onekey = _mm_load_si128(rc_ptr++);
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        const __m128i add1 = _mm_xor_si128(onekey, temp2);
                        const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                        acc = _mm_xor_si128(clprod1, acc);
                    } else {
                        onekey = _mm_load_si128(rc_ptr++);
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
                const __m128i temp1 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i temp2 = _mm_load_si128(prand);
                const __m128i add1 = _mm_xor_si128(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16(acc, temp2);
                const __m128i tempa2 = _mm_xor_si128(tempa1, temp2);

                const __m128i tempb3 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa2);
                _mm_store_si128(prand, tempb3);
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

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, tempa3);
                const __m128i tempb2 = _mm_xor_si128(tempb1, tempa3);
                _mm_store_si128(prandex, tempb2);
                break;
            }
        }
    }
    return acc;
}

// VerusCLHash v2.1 internal implementation
__m128i __verusclmulwithoutreduction64alignedrepeat_sv2_1(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch) {
    const __m128i pbuf_copy[4] = {_mm_xor_si128(buf[0], buf[2]), _mm_xor_si128(buf[1], buf[3]), buf[2], buf[3]};
    const __m128i *pbuf;

    keyMask >>= 4;
    __m128i acc = _mm_load_si128(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++) {
        const uint64_t selector = _mm_cvtsi128_si64(acc);

        __m128i *prand = randomsource + ((selector >> 5) & keyMask);
        __m128i *prandex = randomsource + ((selector >> 32) & keyMask);

        *(pMoveScratch++) = prand;
        *(pMoveScratch++) = prandex;

        pbuf = pbuf_copy + (selector & 3);

        switch (selector & 0x1c) {
            case 0: {
                const __m128i temp1 = _mm_load_si128(prandex);
                const __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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

                const __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add12 = _mm_xor_si128(temp12, temp22);
                acc = _mm_xor_si128(add12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prand, tempb2);
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

                const __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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
                const __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add1 = _mm_xor_si128(temp1, temp2);

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
                    const __m128i tempb3 = _mm_load_si128(prandex);
                    _mm_store_si128(prandex, tempa2);
                    _mm_store_si128(prand, tempb3);
                }
                break;
            }
            case 0x10: {
                const __m128i *rc_ptr = prand;
                __m128i tmp;

                __m128i temp1 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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
                const __m128i tempa3 = _mm_xor_si128(tempa1, tempa2);

                const __m128i tempa4 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa3);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x14: {
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc_ptr = prand;
                uint64_t aesroundoffset = 0;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = _mm_load_si128(rc_ptr++);
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        const __m128i add1 = _mm_xor_si128(onekey, temp2);
                        const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                        acc = _mm_xor_si128(clprod1, acc);
                    } else {
                        onekey = _mm_load_si128(rc_ptr++);
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
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc_ptr = prand;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = _mm_load_si128(rc_ptr++);
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        const __m128i add1 = _mm_xor_si128(onekey, temp2);
                        const int32_t divisor = (uint32_t)selector;
                        const int64_t dividend = _mm_cvtsi128_si64(add1);
                        const __m128i modulo = _mm_cvtsi32_si128(dividend % divisor);
                        acc = _mm_xor_si128(modulo, acc);
                    } else {
                        onekey = _mm_load_si128(rc_ptr++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? buftmp : pbuf);
                        const __m128i add1 = _mm_xor_si128(onekey, temp2);
                        const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                        const __m128i clprod2 = _mm_mulhrs_epi16(acc, clprod1);
                        acc = _mm_xor_si128(clprod2, acc);
                    }
                } while (rounds--);

                const __m128i tempa3 = _mm_load_si128(prandex);
                const __m128i tempa4 = _mm_xor_si128(tempa3, acc);
                _mm_store_si128(prandex, tempa4);
                _mm_store_si128(prand, onekey);
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

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, tempa3);
                const __m128i tempb2 = _mm_xor_si128(tempb1, tempa3);
                _mm_store_si128(prandex, tempb2);
                break;
            }
        }
    }
    return acc;
}

// VerusCLHash v2.2 internal implementation
__m128i __verusclmulwithoutreduction64alignedrepeat_sv2_2(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch) {
    const __m128i pbuf_copy[4] = {_mm_xor_si128(buf[0], buf[2]), _mm_xor_si128(buf[1], buf[3]), buf[2], buf[3]};
    const __m128i *pbuf;

    keyMask >>= 4;
    __m128i acc = _mm_load_si128(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++) {
        const uint64_t selector = _mm_cvtsi128_si64(acc);

        __m128i *prand = randomsource + ((selector >> 5) & keyMask);
        __m128i *prandex = randomsource + ((selector >> 32) & keyMask);

        *(pMoveScratch++) = prand;
        *(pMoveScratch++) = prandex;

        pbuf = pbuf_copy + (selector & 3);

        switch (selector & 0x1c) {
            case 0: {
                const __m128i temp1 = _mm_load_si128(prandex);
                const __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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

                const __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add12 = _mm_xor_si128(temp12, temp22);
                acc = _mm_xor_si128(add12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prand, tempb2);
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

                const __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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
                const __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add1 = _mm_xor_si128(temp1, temp2);

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
                    const __m128i tempb3 = _mm_load_si128(prandex);
                    _mm_store_si128(prandex, tempa2);
                    _mm_store_si128(prand, tempb3);
                    const __m128i tempb4 = _mm_load_si128(pbuf);
                    acc = _mm_xor_si128(tempb4, acc);
                }
                break;
            }
            case 0x10: {
                const __m128i *rc_ptr = prand;
                __m128i tmp;

                __m128i temp1 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
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
                const __m128i tempa3 = _mm_xor_si128(tempa1, tempa2);

                const __m128i tempa4 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa3);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x14: {
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc_ptr = prand;
                uint64_t aesroundoffset = 0;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = _mm_load_si128(rc_ptr++);
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        const __m128i add1 = _mm_xor_si128(onekey, temp2);
                        const __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                        acc = _mm_xor_si128(clprod1, acc);
                    } else {
                        onekey = _mm_load_si128(rc_ptr++);
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
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rc_ptr = prand;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = _mm_load_si128(rc_ptr++);
                        const __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        onekey = _mm_xor_si128(onekey, temp2);
                        const int32_t divisor = (uint32_t)selector;
                        const int64_t dividend = _mm_cvtsi128_si64(onekey);
                        const __m128i modulo = _mm_cvtsi32_si128(dividend % divisor);
                        acc = _mm_xor_si128(modulo, acc);
                    } else {
                        onekey = _mm_load_si128(rc_ptr++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? buftmp : pbuf);
                        const __m128i add1 = _mm_xor_si128(onekey, temp2);
                        onekey = _mm_clmulepi64_si128(add1, add1, 0x10);
                        const __m128i clprod2 = _mm_mulhrs_epi16(acc, onekey);
                        acc = _mm_xor_si128(clprod2, acc);
                    }
                } while (rounds--);

                const __m128i tempa3 = _mm_load_si128(prandex);
                const __m128i tempa4 = _mm_xor_si128(tempa3, acc);

                _mm_store_si128(prandex, onekey);
                _mm_store_si128(prand, tempa4);
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
                const __m128i temp4 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                acc = _mm_xor_si128(temp4, acc);
                const __m128i tempb1 = _mm_mulhrs_epi16(acc, tempa3);
                const __m128i tempb2 = _mm_xor_si128(tempb1, tempa3);
                _mm_store_si128(prandex, tempb2);
                break;
            }
        }
    }
    return acc;
}

// Public API - VerusCLHash v2.0
uint64_t verusclhash(void *random, const unsigned char buf[64], uint64_t keyMask, __m128i **pMoveScratch) {
    __m128i acc = __verusclmulwithoutreduction64alignedrepeat((__m128i *)random, (const __m128i *)buf, keyMask, pMoveScratch);
    acc = _mm_xor_si128(acc, lazyLengthHash(1024, 64));
    return precompReduction64(acc);
}

// Public API - VerusCLHash v2.1
uint64_t verusclhash_sv2_1(void *random, const unsigned char buf[64], uint64_t keyMask, __m128i **pMoveScratch) {
    __m128i acc = __verusclmulwithoutreduction64alignedrepeat_sv2_1((__m128i *)random, (const __m128i *)buf, keyMask, pMoveScratch);
    acc = _mm_xor_si128(acc, lazyLengthHash(1024, 64));
    return precompReduction64(acc);
}

// Public API - VerusCLHash v2.2
uint64_t verusclhash_sv2_2(void *random, const unsigned char buf[64], uint64_t keyMask, __m128i **pMoveScratch) {
    __m128i acc = __verusclmulwithoutreduction64alignedrepeat_sv2_2((__m128i *)random, (const __m128i *)buf, keyMask, pMoveScratch);
    acc = _mm_xor_si128(acc, lazyLengthHash(1024, 64));
    return precompReduction64(acc);
}
