# BloxMiner benchmarks

**Setup:** 2 × AMD Ryzen 9 5950X (32 threads) — `cask10`, `cask18` — HiveOS 0.6-230 on Ubuntu 22.04.5, kernel 6.12,
pool `veruscoin.cedric-crispin.com:4024`, a separate pool worker per run, 2–3 min warm-up discarded, variants rotated
across both rigs. **Metric:** the miner's own summary hashrate, sampled every 30 s (all variants share the same counting code).
Pool-side per-worker estimates swung 23–55 MH/s over 15–20 min windows and cannot resolve 1–2 %, so they are not used for x86.
Accepted-share counts per run (30–130) are likewise too small to resolve 1 %.

## 1. Why a plain rebuild was 2 % slower

| Build | cask10 | cask18 |
|---|---|---|
| Oink70 ccminer 3.8.3a (reference) | 50.22 | 49.79 |
| ccminer e28e183 + patch, clang 14 `-march=x86-64-v3 -O2` | 49.24 | 48.79 |
| same, `-O3` | 48.56 | 48.73 |

| Diagnosis (15 min each) | cask10 | cask18 |
|---|---|---|
| Oink70 3.8.3a | 50.03 | 49.34 |
| e28e183 + patch `-O3` (threads pinned) | 48.75 | 48.41 |
| same binary, pinning off (`HCV_NO_AFFINITY=1`) | 48.11 | 48.16 |
| Oink's own source (1997eda) + patch, same flags | 48.72 | 48.48 |

The source revisions tested did not explain the gap (Oink's own source built the same way was just as slow), and
thread pinning did not recover it (unpinned was slightly slower). Oink's release was built with clang 14 `-march=native`;
adding **`-mtune=znver3`** to the portable `-march=x86-64-v3` recovered comparable measured speed. `-march=znver3` gave a
byte-identical binary.

## 2. BloxMiner flags vs Oink (MH/s, alternated pairs)

| Pair | Build | cask10 BloxMiner / Oink | cask18 BloxMiner / Oink |
|---|---|---|---|
| 2 × 15 min each | first tuned build | 49.99 / 50.11 (−0.2 %) | 49.88 / 49.47 (+0.8 %) |
| 10 min each | + stall bookkeeping | 50.21 / 50.26 (−0.1 %) | 50.62 / 49.39 (+2.5 %) |
| 10 min each | + interrupted-batch stats | — | 49.28 / 49.99 (−1.4 %) |
| 10 min each | + monotonic clock / floor (`fbd6a2bb…`) | — | 50.46 / 50.74 (−0.6 %) |
| 10 min each | **2.0.0 release binary** (`b4812242…`), BloxMiner first | — | 49.28 / 49.96 (−1.4 %) |

All these builds have **instruction-identical hashing code** (all 15 VerusHash / Haraka / CLHash functions compared after
address normalisation); they differ only in stats bookkeeping. Single pairs swing ±1.5–2.5 %, and the build that runs first
tended to measure lower (BloxMiner-first pairs −1.4 / −0.6 / −1.4 %, the Oink-first pair +2.5 %). To remove that order effect
the release binary was measured in a balanced ABBA run on both rigs at the same time (2 min warm-up + 10 min per slot):

| Slot | cask10 | MH/s | cask18 | MH/s |
|---|---|---|---|---|
| 1 | BloxMiner | 49.60 | Oink | 49.25 |
| 2 | Oink | 49.93 | BloxMiner | 49.67 |
| 3 | Oink | 49.49 | BloxMiner | 49.45 |
| 4 | BloxMiner | 50.28 | Oink | 49.45 |
| **Mean** | BloxMiner / Oink | **49.94 / 49.71 (+0.5 %)** | BloxMiner / Oink | **49.56 / 49.35 (+0.4 %)** |

Mean over both rigs: **+0.4 %** — BloxMiner 2.0.0 and Oink 3.8.3a are equal within measurement noise. Rejected
shares during the measured windows: 7 vs 8. Sample SD within a slot 0.1–1.0 %; the two slots of the same miner differed by up to 1.4 %.

Tuned for AMD Zen 3; runs on any x86-64-v3 CPU with AES-NI / PCLMUL. Intel is untested.

## 3. BloxMiner 2.1.0

The 2.1.0 hashing functions are instruction-identical to 2.0.0 (`tools/hashing-identity.sh`, 15/15). 2.1.0 adds a service
thread that samples sensors every 2 s and redraws the screen; its speed was measured again with the balanced ABBA method.

**Method.** The exact release package (`bloxminer-2.1.0.tar.gz`, binary `3fd67be2…`) with the
HiveOS default config (no sticky header, log file on) against Oink70's ccminer 3.8.3a, both in a detached `screen` (a pty,
as under HiveOS), 2 × Ryzen 9 5950X on HiveOS 22.04, same pool, test worker names. Order per rig BloxMiner, Oink, Oink,
BloxMiner; 2 min warm-up + 10 min measured per slot; summary `KHS` every 30 s; two rounds on each rig. Every sample was checked for the
right miner (API `NAME`/`VER`), a finite rate and a place inside its slot's measured window (a first attempt was discarded
because the Oink binary had lost its execute bit and produced no samples).

| Rig, round | BloxMiner slot 1 | Oink slot 2 | Oink slot 3 | BloxMiner slot 4 |
|---|---|---|---|---|
| cask10 r1 | 50407.51 | 50692.62 | 50561.58 | 49913.73 |
| cask10 r2 | 50130.65 | 50029.15 | 49957.42 | 50504.38 |
| cask18 r1 | 49985.54 | 49779.50 | 50216.77 | 49478.04 |
| cask18 r2 | 48956.71 | 49843.35 | 49412.96 | 50046.54 |

(kH/s, 20 samples per slot.) BloxMiner 49 927.89 vs Oink 50 061.67 kH/s: **−0.27 %** (cask10 −0.14 %, cask18 −0.39 %),
within the slot-to-slot noise (about ±1 %).

## 4. BloxMiner 3.0.0

Both engines are rebuilt only to show the release number; neither engine's hashing code changed. **Verus
engine**: instruction-identical to 2.1.0 (`tools/hashing-identity.sh`, 15/15). **RandomX engine**: the shipped
binary reproduces bit-for-bit against a rebuild of the pre-branding source using the same recipe/toolchain, and
an object-by-object diff shows 208 of 210 compiled objects identical — only the two touched (branding-only)
source files' objects differ. Full proof: `docs/3.0.0-engine-identity.md`.

**Verus live sanity** (cask18, Ryzen 9 5950X, old = 2.1.0, new = 3.0.0, old/new/new/old 10-min slots):

| Slot | 1 (old) | 2 (new) | 3 (new) | 4 (old) |
|---|---|---|---|---|
| kH/s | 49 877 | 49 916 | 50 167 | 50 047 |

Mean: old 49 962 kH/s, new 50 041.5 kH/s — **+0.16 %**, within the slot-to-slot noise (about ±1 %).

**RandomX engine — the X6 benchmark carries over unchanged.** 3.0.0's RandomX engine is the exact binary
already benchmarked at the X6 gate (XMRig 6.26.0, donation level 0), plus the display-only branding patch —
proven bit-for-bit / object-identical above, so no re-benchmark was needed. Both 5950X rigs, BloxMiner (bx) vs
HiveOS's stock XMRig 6.26.0, same pool, alternated slots:

| Rig | bx | stock XMRig 6.26.0 |
|---|---|---|
| cask10 | 15 898.50 / 15 868.85 H/s | 15 906.74 / 15 879.36 H/s |
| cask18 | 15 855.62 / 15 869.82 H/s | 15 823.32 / 15 816.05 H/s |

Mean: bx 15 873.20 H/s vs stock 15 856.37 H/s — **+0.11 %** overall (cask10 −0.06 %, cask18 +0.27 %), within
the slot-to-slot noise.

**RandomX live sanity on the shipped 3.0.0 package** (same cask18 ABBA method, to confirm the package itself
beyond the object-identity proof above):

| Slot (10 min, cask18 5950X) | Package | Hive hashrate | Shares (acc/rej) |
|---|---|---|---|
| 1 | previous 3.0.0 candidate (unlabelled engine) | 15.58 kH/s | 51 / 0 |
| 2 | **3.0.0** (labelled engine) | **15.54 kH/s** | 56 / 0 |
| 3 | **3.0.0** (labelled engine) | **15.53 kH/s** | 56 / 0 |
| 4 | previous 3.0.0 candidate (unlabelled engine) | 15.55 kH/s | 54 / 0 |

Averages 15.565 vs 15.535 kH/s (−0.19 %). HiveOS reports this value with two decimals (0.01 kH/s ≈ 0.06 % here), so
the difference is at the resolution limit and within the slot-to-slot noise; zero false-zero readings in all four
slots.

## 5. ARM (not part of this package)

Orange Pi 5 (RK3588), 2 × 1 h each, pool-side: primo-arm-miner 1.1.0 **8.13 / 8.33 MH/s** vs Oink ARM ccminer
7.20 / 7.26 MH/s (+13.8 % from these numbers; an earlier summary said +13.6 %). Pool numbers count only shares sent to
the user's pool, so primo's 2 % fee is already excluded.
