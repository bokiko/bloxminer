# BloxMiner Continuation Ledger

**Last Updated:** January 7, 2026  
**Status:** WORKING - SHARES ACCEPTED

---

## QUICK START

```bash
# Build
cd /home/bokiko/projects/bloxminer/build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)

# Run miner (shares will be ACCEPTED now!)
./bloxminer -o pool.verus.io:9999 -u RCt6Afs3tia1AHhbpDFnDBjLXBeSqM78ic -w test -t 2
```

---

## PROJECT SUMMARY

**What:** BloxMiner - VerusHash v2.2 CPU miner for Verus Coin (VRSC)  
**Where:** `/home/bokiko/projects/bloxminer/`  
**Language:** C++17 with AES-NI, AVX, PCLMUL intrinsics  
**Performance:** ~1.8 MH/s per thread on modern CPU

---

## BUG FIXED (January 7, 2026)

### The Problem
Shares were being rejected with "low difficulty" errors. The pool computed a hash ~100x worse than what we computed locally.

### Root Cause
In `src/crypto/verus_clhash_v2.c`, the AES2 macro uses a variable named `rc` for round constants. In ccminer's CLHash implementation, this is intentionally shadowed with a local variable:

```cpp
const __m128i *rc = prand;  // Shadows global rc with key data
```

Our code incorrectly named this `rc_ptr`:
```cpp
const __m128i *rc_ptr = prand;  // WRONG - doesn't shadow global rc
```

This meant the AES2 macro was using Haraka's global round constants instead of the key data, causing incorrect hash computation.

### The Fix
Changed variable names from `rc_ptr` to `rc` in three switch cases:
- **Case 0x10** (line 205): `const __m128i *rc_ptr = prand;` -> `const __m128i *rc = prand;`
- **Case 0x14** (line 237): `__m128i *rc_ptr = prand;` -> `__m128i *rc = prand;`  
- **Case 0x18** (line 273): `__m128i *rc_ptr = prand;` -> `__m128i *rc = prand;`

### Result
- All shares now accepted by pool.verus.io
- No more "low difficulty" rejections
- Hash rate: ~1.8 MH/s per thread

---

## KEY FILES

| File | Purpose |
|------|---------|
| `src/crypto/verus_clhash_v2.c` | CLHash v2.2 implementation (FIXED) |
| `src/crypto/verus_hash.cpp` | hash_half, hash_with_nonce, key generation |
| `src/crypto/haraka.c` | Haraka512, Haraka256 primitives |
| `src/miner.cpp` | Mining loop, job handling |
| `src/stratum/stratum_client.cpp` | Pool communication, share submission |

---

## TESTS

```bash
# CLHash comparison test (validates our CLHash matches ccminer)
cd /home/bokiko/projects/bloxminer
./tests/test_clhash_compare

# VerusHash test
./tests/test_verushash
```

---

## BUILD COMMANDS

```bash
# Full rebuild
cd /home/bokiko/projects/bloxminer/build
rm -rf * && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)

# Quick rebuild
cd /home/bokiko/projects/bloxminer/build
make -j$(nproc)

# Run miner
./bloxminer -o pool.verus.io:9999 -u RCt6Afs3tia1AHhbpDFnDBjLXBeSqM78ic -w test -t 2
```

---

## SESSION HISTORY

### Session 1 (Jan 6, 2026)
- Built complete miner from scratch
- Verified all Haraka primitives against test vectors
- Verified submission format matches ccminer
- Identified CLHash as primary suspect
- Created handoff document

### Session 2 (Jan 7, 2026)
- Created CLHash comparison test (`tests/test_clhash_compare.cpp`)
- Found divergence at iteration 1 in case 0x10 (AES case)
- Identified root cause: `rc_ptr` vs `rc` variable naming
- Fixed variable names in cases 0x10, 0x14, 0x18
- Verified CLHash outputs now match ccminer exactly
- Confirmed shares accepted by pool.verus.io
- **BUG FIXED!**

---

## FUTURE IMPROVEMENTS

1. Add more threads support testing
2. Benchmark against other miners
3. Add pool failover support
4. Add hashrate reporting to pool
5. Consider AVX2/AVX512 optimizations
