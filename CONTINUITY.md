# BloxMiner Continuity Ledger

## Project Overview
**BloxMiner** is a VerusHash v2.2 CPU miner for Verus Coin (VRSC) written in C++.
- **Location:** `/home/bokiko/projects/bloxminer/`
- **GitHub:** `git@github.com:bokiko/bloxminer.git`
- **Status:** FULLY WORKING - Shares accepted by pools

---

## What Was Accomplished

### 1. Fixed Critical CLHash Bug
**Problem:** Shares were rejected by pools with "low difficulty" errors. Pool computed hash ~100x worse than our local computation.

**Root Cause:** In `src/crypto/verus_clhash_v2.c`, the AES2 macro uses a variable named `rc` for round constants. The code incorrectly named the local variable `rc_ptr` instead of `rc`, so the AES2 macro used global Haraka round constants instead of key data.

**Fix:** Changed variable names from `rc_ptr` to `rc` in three switch cases:
- Case 0x10 (line ~205)
- Case 0x14 (line ~237)
- Case 0x18 (line ~273)

**File:** `src/crypto/verus_clhash_v2.c`

### 2. Verified Miner Works
- **12-minute test with 4 threads:**
  - 53 shares submitted
  - 52 accepted (98.1%)
  - 0 rejected
  - Hash rate: ~6.7 MH/s (~1.68 MH/s per thread)
  - 100% pool acceptance rate

### 3. Created CLHash Comparison Test
- **File:** `tests/test_clhash_compare.cpp`
- **Purpose:** Compares our CLHash output with ccminer's reference implementation
- **Reference:** `tests/ccminer_clhash.cpp` (extracted from ccminer)

### 4. Updated README for HiveOS Miners
- Simplified README with HiveOS one-command install at the top
- Fixed binary path issues
- Added background mining and troubleshooting sections

### 5. Added HiveOS Installation Script
- Created `h-install.sh` for HiveOS Flight Sheet integration
- Installation URL for HiveOS custom miner setup
- Installs to `/hive/miners/bloxminer/`

---

## Key Files

| File | Purpose |
|------|---------|
| `src/crypto/verus_clhash_v2.c` | CLHash v2.2 implementation (FIXED) |
| `src/crypto/verus_hash.cpp` | VerusHash wrapper, hash_half, hash_with_nonce |
| `src/crypto/haraka.c` | Haraka512/256 AES-NI implementation |
| `src/miner.cpp` | Mining loop, job handling |
| `src/stratum/stratum_client.cpp` | Pool communication |
| `tests/test_clhash_compare.cpp` | CLHash verification test |
| `CMakeLists.txt` | Build configuration |
| `README.md` | User documentation |
| `h-install.sh` | HiveOS installation script |

---

## Build & Run Commands

```bash
# Build
cd /home/bokiko/projects/bloxminer
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Run
./bloxminer -o pool.verus.io:9999 -u RCt6Afs3tia1AHhbpDFnDBjLXBeSqM78ic -w test -t 4

# Run CLHash test
cd /home/bokiko/projects/bloxminer
./tests/test_clhash_compare
```

---

## HiveOS Installation

### Installation URL (for Flight Sheet custom miner)
```
https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh
```

### Manual Terminal Install
```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh | bash
```

After installation, the miner is at `/hive/miners/bloxminer/bloxminer`

---

## Git History

```
6641424 feat: Add HiveOS installation script and URL
4c2f184 docs: Enhance README with badges and better formatting
b2e5d49 docs: Add continuity ledger for project state tracking
f3b74f9 docs: Completely rewrite README for miners
f53d5c3 fix: CLHash variable shadowing bug - shares now accepted
89479f9 Initial commit: BloxMiner v0.1.0-beta
```

---

## Reference Implementation Location
- **ccminer-verus:** `/tmp/ccminer-verus/`
- **Key reference files:**
  - `/tmp/ccminer-verus/verus/verus_clhash.cpp` - Reference CLHash
  - `/tmp/ccminer-verus/verus/verusscan.cpp` - Verus2hash function
  - `/tmp/ccminer-verus/verus/haraka.h` - AES2/MIX2 macros

---

## What Could Be Done Next

1. **Performance optimization** - AVX2/AVX512 implementations
2. **Add more pools** - Test with luckpool, other Verus pools
3. **Add statistics** - Better hashrate reporting, share statistics
4. **Add config file support** - JSON config for easier setup
5. **Add API** - HTTP API for monitoring
6. **Package for distribution** - Create releases, binaries

---

## Important Technical Notes

### The CLHash Bug (For Reference)
The AES2 macro in `haraka.h` references `rc[rci]`:
```c
#define AES2(s0, s1, rci) \
  s0 = _mm_aesenc_si128(s0, rc[rci]); \
  ...
```

In normal Haraka, `rc` is the global round constants array. But in CLHash cases 0x10, 0x14, 0x18, ccminer **shadows** this with a local variable:
```c
const __m128i *rc = prand;  // Shadows global rc with key data
```

Our code incorrectly used `rc_ptr` which didn't shadow the global, causing wrong hash computation.

### VerusHash v2.2 Flow
```
Block Data (1487 bytes)
    |
Haraka512 Chain (hash_half)
    |
Intermediate State (64 bytes)
    |
Key Generation (8832 bytes via Haraka256)
    |
CLHash v2.2 (32 iterations with AES mixing)
    |
Final Haraka512 (keyed)
    |
Hash Result (32 bytes)
```

---

*Last Updated: 2026-01-07*
