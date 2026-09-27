<div align="center">

# BloxMiner

**VerusHash v2.2 CPU miner for Verus (VRSC) — runs on any x86-64 Linux, HiveOS-ready**

<p>
  <a href="https://github.com/bokiko/bloxminer"><img src="https://img.shields.io/badge/GitHub-bloxminer-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://verus.io"><img src="https://img.shields.io/badge/Verus-VRSC-3165D4?style=for-the-badge" alt="Verus"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Version-2.0.0-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Based_on-ccminer-00599C?style=flat-square" alt="ccminer">
  <img src="https://img.shields.io/badge/Algorithm-VerusHash_v2.2-blue?style=flat-square" alt="VerusHash">
  <img src="https://img.shields.io/badge/Platform-Linux_x86--64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/HiveOS-Ready-green?style=flat-square" alt="HiveOS">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License">
</p>

</div>

---

## Index

- [Installation](#installation)
  - [HiveOS Flight Sheet (Recommended)](#hiveos-flight-sheet-recommended)
  - [HiveOS Terminal Install](#hiveos-terminal-install)
  - [Updating](#updating)
- [Usage](#usage)
- [Configuration](#configuration)
- [Features](#features)
- [API](#api)
- [Performance](#performance)
- [Requirements](#requirements)
- [Building](#building)
- [Algorithm](#algorithm)
- [License](#license)

---

## Installation

### HiveOS Flight Sheet (Recommended)

1. **Create New Flight Sheet**
   - Coin: `VRSC` (Verus)
   - Wallet: Select your Verus wallet
   - Pool: `Configure in miner`

2. **Add Miner**
   - Miner: `Custom`
   - Miner name: `bloxminer`
   - Installation URL:
     ```
     https://github.com/bokiko/bloxminer/releases/download/2.0.0/bloxminer-2.0.0.tar.gz
     ```
   - Hash algorithm: `verushash`
   - Wallet and worker template: `%WAL%.%WORKER_NAME%`
   - Pool URL: your pool, e.g. `stratum+tcp://veruscoin.cedric-crispin.com:4024`
   - Pass: number of threads (e.g. `32`) or leave empty for all threads

3. **Apply Flight Sheet** to your rig

#### Flight Sheet Fields

| Field | Value | Notes |
|-------|-------|-------|
| Miner | `custom` | Required |
| Miner name | `bloxminer` | Must match exactly |
| Installation URL | `https://github.com/bokiko/bloxminer/releases/download/2.0.0/bloxminer-2.0.0.tar.gz` | Keep it — HiveOS installs once and reuses it |
| Hash algorithm | `verushash` | |
| Wallet template | `%WAL%.%WORKER_NAME%` | Your wallet.worker |
| Pool URL | `stratum+tcp://host:port` | Your pool |
| Pass | `32` | Thread count (optional). Any non-number is sent to the pool as the password |
| Extra config arguments | *(empty)* | Optional ccminer JSON, e.g. `"threads": 12` |

### HiveOS Terminal Install

```bash
/hive/miners/custom/custom-get https://github.com/bokiko/bloxminer/releases/download/2.0.0/bloxminer-2.0.0.tar.gz
```

Then set the flight sheet as above. On a fresh HiveOS image, HiveOS installs its custom-miner support automatically
the first time a flight sheet uses a Custom miner.

### Updating

Change the version in the Installation URL (e.g. `2.0.0` → a newer release) and apply the flight sheet.
HiveOS downloads the new package and restarts the miner.

---

## Usage

HiveOS runs BloxMiner for you. Useful commands on the rig:

```bash
miner                 # open the miner screen (Ctrl+A, D to leave)
miner restart         # restart
tail -f /var/log/miner/bloxminer/bloxminer.log
```

The binary can also run outside HiveOS with standard ccminer options:

```bash
/hive/miners/custom/bloxminer/ccminer -a verus \
  -o stratum+tcp://veruscoin.cedric-crispin.com:4024 \
  -u RYourWalletAddress.rig1 -p x -t 32
```

---

## Configuration

The flight sheet is turned into `/hive/miners/custom/bloxminer/config.json` every time the miner starts:

```json
{
  "pools": [ { "name": "pool1", "url": "stratum+tcp://host:port", "timeout": 150 } ],
  "user": "RYourWalletAddress.rig1",
  "pass": "x",
  "algo": "verus",
  "threads": 32,
  "api-bind": "127.0.0.1:4068"
}
```

Options in `/hive/miners/custom/bloxminer/h-manifest.conf`:

| Option | Values | Default |
|--------|--------|---------|
| `CCD_TEMP_MAP` | `auto` · `1` (force per-CCD temps) · `0` (package temp on every row) | `auto` |

---

## Features

| Category | Features |
|----------|----------|
| **Performance** | Same speed as the fastest ccminer CPU build we measured (Oink70 3.8.3a), tuned for AMD Zen 3, reproducible build |
| **HiveOS stats** | **Hashrate per physical core** (SMT threads summed), temperature per core row, CPU package power (RAPL), accepted/rejected |
| **Temperatures** | AMD Ryzen 5000: temperature of each core's CCD (AMD has no per-core sensor) · Intel: real per-core temperature · others: package temperature |
| **Reliability** | Stall detection — a stalled miner shows 0 H/s instead of its last rate (within 10 min without work) · CPU check with a clear HiveOS message on unsupported CPUs |
| **Threads** | Each thread pinned to its own CPU (respects the process CPU set), bound CPU reported per thread |

### What HiveOS receives (example, Ryzen 9 5950X)

```
core  0   3.14 MH/s   62°C  (CCD1)
core  1   3.12 MH/s   62°C  (CCD1)
 ...
core  8   3.13 MH/s   63°C  (CCD2)
 ...
core 15   3.15 MH/s   64°C  (CCD2)
                              cpu_power: 136 W
```

CPU power is sent as `cpu_power` in the miner stats; how HiveOS displays it depends on the HiveOS version.

---

## API

ccminer-compatible text API on `127.0.0.1:4068` (local only):

```bash
echo -n summary | nc 127.0.0.1 4068
echo -n threads | nc 127.0.0.1 4068
```

`summary` (BloxMiner adds `LASTWORK`, `STALL` and `FRESHKHS` — the total of threads that worked recently):

```
NAME=ccminer_CPU;VER=3.8.3;ALGO=verus;KHS=49221.86;ACC=15;REJ=0;UPTIME=152;LASTWORK=14;STALL=0;FRESHKHS=49180.32|
```

`threads` — one entry per mining thread:

```
CPU=0;KHS=1567.96;AFF=0;AGE=9;DUR=62;STATE=hashing|CPU=1;KHS=1526.47;AFF=1;AGE=4;DUR=58;STATE=hashing|...
```

| Field | Meaning |
|-------|---------|
| `KHS` | Rate of the thread's last completed batch (0 when overdue) |
| `AFF` | CPU the thread is bound to (`-1` = unbound) |
| `AGE` / `DUR` | Seconds since the last batch finished / how long that batch took |
| `STATE` | `hashing`, or `waiting` when the current batch is overdue: 2 × the thread's longest batch + 30 s, at least 5 min and at most 10 min |

---

## Performance

2 × AMD Ryzen 9 5950X (32 threads), HiveOS on Ubuntu 22.04, same pool, alternated runs against
Oink70's ccminer 3.8.3a (the fastest CPU build we measured):

| Rig | Oink70 3.8.3a | **BloxMiner** |
|-----|---------------|---------------|
| cask10 | 49.71 MH/s | **49.94 MH/s** |
| cask18 | 49.35 MH/s | **49.56 MH/s** |

Balanced ABBA run of the 2.0.0 binary on both rigs (2 × 10 min per miner per rig): BloxMiner **+0.4 %** versus Oink — equal
within measurement noise — while adding per-core stats. Full method, diagnosis and all runs: [BENCHMARKS.md](BENCHMARKS.md).

---

## Requirements

| Category | Requirement |
|----------|-------------|
| **OS** | Any x86-64 Linux with glibc ≥ 2.34 and OpenSSL 3 (e.g. Ubuntu 22.04+, Debian 12+), including HiveOS on Ubuntu 22.04+. Older HiveOS 18.04 images: update with `hive-replace --stable` |
| **CPU** | x86-64-v3 (AVX2, BMI2, FMA) with AES-NI and PCLMULQDQ — AMD Ryzen / EPYC, Intel Haswell or newer |
| **Tested** | AMD Ryzen 9 5950X. Other Zen 3 CPUs share the same core; Intel should work but is untested |

---

## Building

Reproducible on Ubuntu 22.04 x86-64:

```bash
build/build.sh                  # clang 14, -march=x86-64-v3 -mtune=znver3 -O3 → out/ccminer-O3
build/package.sh out/ccminer-O3 # → bloxminer-2.0.0.tar.gz
```

Source: [monkins1010/ccminer](https://github.com/monkins1010/ccminer) `Verus2.2` @ `e28e183` + [`build/bloxminer.patch`](build/bloxminer.patch).
The patch adds the per-thread API, stall detection and the thread-pinning fix. The hashing code is unchanged.
The release binary's sha256 is listed in the release notes.

---

## Algorithm

VerusHash v2.2 combines multiple cryptographic primitives for ASIC resistance:

```
Block Data (1487 bytes)
    |
    v
Haraka512 Chain (AES-NI accelerated)
    |
    v
Key Generation (8832 bytes via Haraka256)
    |
    v
CLHash v2.2 (32 iterations + AES mixing)
    |
    v
Final Haraka512 (keyed)
    |
    v
Hash Result (32 bytes)
```

---

## License

GPL-3.0 — see [LICENSE](LICENSE). BloxMiner 2.x is built from ccminer, which is GPL-licensed.
BloxMiner 1.x (the earlier from-scratch C++ miner, MIT) remains in this repository's history.

---

## Acknowledgments

- [VerusCoin Team](https://verus.io) - VerusHash
- [monkins1010/ccminer](https://github.com/monkins1010/ccminer) - Verus ccminer (Christian Buchner, Christian H., tpruvot and contributors)
- [Oink70/ccminer-verus](https://github.com/Oink70/ccminer-verus) - CPU builds and reference speed
- [Daniel Lemire](https://github.com/lemire/clhash) - CLHash algorithm
- [LLVM Project](https://llvm.org) - clang and libomp (Apache-2.0 with LLVM exception)

---

<p align="center">
  <a href="https://github.com/bokiko/bloxminer">GitHub</a> •
  <a href="https://verus.io">Verus.io</a>
</p>

<p align="center">
  Made by <a href="https://github.com/bokiko">@bokiko</a>
</p>
