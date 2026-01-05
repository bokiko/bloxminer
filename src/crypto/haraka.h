/*
The MIT License (MIT)

Copyright (c) 2016 kste
Modified for BloxMiner by Bokiko, 2026

Optimized Implementations for Haraka256 and Haraka512
*/
#ifndef BLOXMINER_HARAKA_H
#define BLOXMINER_HARAKA_H

#include <stdint.h>
#include <immintrin.h>
#include <x86intrin.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
typedef unsigned long long u64;
#else
typedef unsigned long u64;
#endif
typedef __m128i u128;

// Round constants
extern u128 rc[40];
extern u128 rc0[40];

#define LOAD(src) _mm_load_si128((u128 *)(src))
#define STORE(dest,src) _mm_storeu_si128((u128 *)(dest),src)

#define AES2(s0, s1, rci) \
  s0 = _mm_aesenc_si128(s0, rc[rci]); \
  s1 = _mm_aesenc_si128(s1, rc[rci + 1]); \
  s0 = _mm_aesenc_si128(s0, rc[rci + 2]); \
  s1 = _mm_aesenc_si128(s1, rc[rci + 3]);

#define AES4(s0, s1, s2, s3, rci) \
  s0 = _mm_aesenc_si128(s0, rc[rci]); \
  s1 = _mm_aesenc_si128(s1, rc[rci + 1]); \
  s2 = _mm_aesenc_si128(s2, rc[rci + 2]); \
  s3 = _mm_aesenc_si128(s3, rc[rci + 3]); \
  s0 = _mm_aesenc_si128(s0, rc[rci + 4]); \
  s1 = _mm_aesenc_si128(s1, rc[rci + 5]); \
  s2 = _mm_aesenc_si128(s2, rc[rci + 6]); \
  s3 = _mm_aesenc_si128(s3, rc[rci + 7]);

#define AES4_zero(s0, s1, s2, s3, rci) \
  s0 = _mm_aesenc_si128(s0, rc0[rci]); \
  s1 = _mm_aesenc_si128(s1, rc0[rci + 1]); \
  s2 = _mm_aesenc_si128(s2, rc0[rci + 2]); \
  s3 = _mm_aesenc_si128(s3, rc0[rci + 3]); \
  s0 = _mm_aesenc_si128(s0, rc0[rci + 4]); \
  s1 = _mm_aesenc_si128(s1, rc0[rci + 5]); \
  s2 = _mm_aesenc_si128(s2, rc0[rci + 6]); \
  s3 = _mm_aesenc_si128(s3, rc0[rci + 7]);

#define MIX2(s0, s1) \
  tmp = _mm_unpacklo_epi32(s0, s1); \
  s1 = _mm_unpackhi_epi32(s0, s1); \
  s0 = tmp;

#define MIX4(s0, s1, s2, s3) \
  tmp  = _mm_unpacklo_epi32(s0, s1); \
  s0 = _mm_unpackhi_epi32(s0, s1); \
  s1 = _mm_unpacklo_epi32(s2, s3); \
  s2 = _mm_unpackhi_epi32(s2, s3); \
  s3 = _mm_unpacklo_epi32(s0, s2); \
  s0 = _mm_unpackhi_epi32(s0, s2); \
  s2 = _mm_unpackhi_epi32(s1, tmp); \
  s1 = _mm_unpacklo_epi32(s1, tmp);

#define TRUNCSTORE(out, s0, s1, s2, s3) \
  *(u64*)(out) = *(((u64*)&s0 + 1)); \
  *(u64*)(out + 8) = *(((u64*)&s1 + 1)); \
  *(u64*)(out + 16) = *(((u64*)&s2 + 0)); \
  *(u64*)(out + 24) = *(((u64*)&s3 + 0));

// Initialize round constants
void load_constants(void);

// Haraka256: 32 bytes in -> 32 bytes out
void haraka256(unsigned char *out, const unsigned char *in);
void haraka256_keyed(unsigned char *out, const unsigned char *in, const u128 *rc);

// Haraka512: 64 bytes in -> 32 bytes out
void haraka512(unsigned char *out, const unsigned char *in);
void haraka512_zero(unsigned char *out, const unsigned char *in);
void haraka512_keyed(unsigned char *out, const unsigned char *in, const u128 *rc);

#ifdef __cplusplus
}
#endif

#endif // BLOXMINER_HARAKA_H
