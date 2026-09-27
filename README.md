<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img src="assets/logo-light.svg" alt="BloxMiner" width="420">
</picture>

**VerusHash v2.2 CPU miner for Verus (VRSC) — 0 % dev fee, runs on any x86-64 Linux, HiveOS-ready**

<p>
  <a href="https://github.com/bokiko/bloxminer"><img src="https://img.shields.io/badge/GitHub-bloxminer-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://verus.io"><img src="https://img.shields.io/badge/Verus-VRSC-3165D4?style=for-the-badge" alt="Verus"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Version-2.1.0-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Based_on-ccminer-00599C?style=flat-square" alt="ccminer">
  <img src="https://img.shields.io/badge/Algorithm-VerusHash_v2.2-blue?style=flat-square" alt="VerusHash">
  <img src="https://img.shields.io/badge/Platform-Linux_x86--64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/HiveOS-Ready-green?style=flat-square" alt="HiveOS">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/Dev_fee-0%25-brightgreen?style=flat-square" alt="0% dev fee">
</p>

</div>

---

## Index

- [What it mines](#what-it-mines)
- [Installation](#installation)
  - [HiveOS Flight Sheet (Recommended)](#hiveos-flight-sheet-recommended)
  - [HiveOS Terminal Install](#hiveos-terminal-install)
  - [Updating](#updating)
- [Usage](#usage)
- [The miner screen](#the-miner-screen)
- [Configuration](#configuration)
- [CPU support](#cpu-support)
- [HiveOS stats](#hiveos-stats)
- [API](#api)
- [Performance](#performance)
- [Troubleshooting](#troubleshooting)
- [Requirements](#requirements)
- [Building](#building)
- [Algorithm](#algorithm)
- [License](#license)

---

## What it mines

BloxMiner mines **VerusHash v2.2 only** — the proof-of-work of [Verus (VRSC)](https://verus.io).

| | |
|---|---|
| **VRSC** | Supported and tested on Verus stratum pools |
| **Fees** | **None.** No dev fee and no donation mining: every share goes to your wallet on the pool you configure. Open source (GPL-3.0); the full change to ccminer is [`build/bloxminer.patch`](build/bloxminer.patch) |
| **Verus PBaaS chains** | The Verus merged-mining header handling is included (from monkins1010's ccminer). Whether a pool offers merged mining or a PBaaS chain, and which rewards you get, depends on the pool. Not tested by us |
| **Other coins / algorithms** | Not supported. Any `algo` other than `verus` is refused at start with a message |

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
     https://github.com/bokiko/bloxminer/releases/download/2.1.0/bloxminer-2.1.0.tar.gz
     ```
   - Hash algorithm: `verushash`
   - Wallet and worker template: `%WAL%.%WORKER_NAME%`
   - Pool URL: your pool, e.g. `stratum+tcp://veruscoin.cedric-crispin.com:4024`
   - Pass: number of threads, `1`–`128` (e.g. `32`), or empty for all CPUs

3. **Apply Flight Sheet** to your rig

#### Flight Sheet Fields

| Field | Value | Notes |
|-------|-------|-------|
| Miner | `custom` | Required |
| Miner name | `bloxminer` | Must match exactly |
| Installation URL | `https://github.com/bokiko/bloxminer/releases/download/2.1.0/bloxminer-2.1.0.tar.gz` | HiveOS installs it once and reuses it |
| Hash algorithm | `verushash` | |
| Wallet template | `%WAL%.%WORKER_NAME%` | Your wallet.worker |
| Pool URL | `stratum+tcp://host:port` | Your pool (`host:port` also works) |
| Pass | `32` | Thread count `1`–`128` (optional). Empty = every CPU HiveOS gives the miner. Any text that is not a number is sent to the pool as the password |
| Extra config arguments | *(empty)* | Optional JSON members, see [Configuration](#configuration) |

A pool that needs a **numeric** password: leave Pass empty and put `"pass": "1234"` in Extra config.

### HiveOS Terminal Install

```bash
/hive/miners/custom/custom-get https://github.com/bokiko/bloxminer/releases/download/2.1.0/bloxminer-2.1.0.tar.gz
```

Then set the flight sheet as above. On a fresh HiveOS image, HiveOS installs its custom-miner support automatically
the first time a flight sheet uses a Custom miner.

### Updating

Change the version in the Installation URL (e.g. `2.0.0` → `2.1.0`) and apply the flight sheet.
HiveOS downloads the new package and restarts the miner. Your flight sheet fields stay the same.

---

## Usage

HiveOS runs BloxMiner for you. Useful commands on the rig:

```bash
miner                 # open the miner screen (Ctrl+A, D to leave)
miner restart         # restart
tail -f /var/log/miner/bloxminer/bloxminer.log     # plain-text log (rotates to .log.1 at 10 MB)
/hive/miners/custom/bloxminer/bloxminer --sensors  # CPU topology, temperature sources and power
```

Outside HiveOS, on any Linux x86-64 box that meets the [requirements](#requirements):

```bash
./bloxminer -o stratum+tcp://veruscoin.cedric-crispin.com:4024 -u RYourWalletAddress.rig1 -p x -t 32
./bloxminer --help
```

BloxMiner options (in addition to the usual ccminer pool options):

| Option | Meaning |
|--------|---------|
| `-t, --threads=N` | Mining threads, `1`–`140` |
| `--no-dashboard` | Plain scrolling output instead of the sticky header on a terminal |
| `--stats-interval=N` | A stats table every N seconds when there is no sticky header, and in the log file (default `60`, `0` = off) |
| `--log-file=FILE` | Also write a plain-text log without colours (rotates to `FILE.1` at 10 MB) |
| `--thread-log` | Print every thread's batch rate (the classic ccminer `CPU T5: Verus Hashing …` lines) |
| `--ccd-temp-map=auto\|1\|0` | Per-CCD temperatures on AMD: `auto` (validated CPUs), `1` (force the L3→CCD heuristic), `0` (package temperature) |
| `--sensors` | Show CPU topology, temperature sources and power, then exit |

---

## The miner screen

**On HiveOS** the `miner` screen shows plain scrolling lines (shares, pool messages, errors) and a per-core stats
table every 60 s, so the HiveOS web **Miner log** stays readable:

```
== BloxMiner 2.1.0 | 49.80 MH/s | A 32 R 0 | 136 W | 64 C | 365 kH/W | up 0h01m ==
 C00 3.11M   63C  C01 3.09M   63C  C02 3.12M   63C  C03 3.05M   63C  C04 3.12M   63C  C05 3.10M   63C
 C06 3.15M   63C  C07 3.11M   63C  C08 3.11M   63C  C09 3.11M   63C  C10 3.14M   63C  C11 3.10M   63C
 C12 3.11M   63C  C13 3.11M   63C  C14 3.13M   63C  C15 3.11M   63C
```
(Ryzen 9 5950X on HiveOS, from the log file.)

For a **live stats header** in the HiveOS miner screen add `"dashboard": true` to Extra config. HiveOS's web
*Miner log* is a tail of the raw screen recording, so with the header on it fills with screen redraws; the clean
log is always `/var/log/miner/bloxminer/bloxminer.log`. On any other terminal the header is on by default.
Captured from a Ryzen 9 5900X (80 columns) a few seconds after start:

```
+------------------------------------------------------------------------------+
| BloxMiner 2.1.0  Ryzen 9 5900X  12C/24T                            up 0h00m  |
| Hashrate 32.83 MH/s   A 8  R 0   Diff 1.28e+07                               |
| Power 89 W   Temp 45C   Eff 368 kH/W   Pool veruscoin.cedric-crispin.com:4024 |
+------------------------------------------------------------------------------+
| C00 2.75M  45C C01 2.74M  45C C02 2.75M  45C C03 2.75M  45C C04 2.73M  45C   |
| C05 2.69M  45C C06 2.74M  43C C07 2.75M  43C C08 2.74M  43C C09 2.71M  43C   |
| C10 2.76M  43C C11 2.72M  43C                                                |
+------------------------------------------------------------------------------+
[2026-09-27 10:20:55] accepted: 8/8 (diff 14861478.698), 12.24 MH/s yes!
```

- One cell per **physical core** (`C00`…): the hashrate of its SMT threads together, and its temperature.
  `...` = the core has not finished its first batch yet (normal for the first minute).
- Hashrate is the sum of threads that worked recently — the same total HiveOS shows.
- Power is the CPU package power (RAPL); `Eff` = kH/s per watt. `Power n/a` when the kernel does not expose it.
- A small window, `--no-dashboard` (the HiveOS default) or output that is not a terminal gives plain scrolling
  output with a stats table every 60 s instead. The log file never contains colour codes.
- `STALLED` in the header means no thread has finished work recently; the miner then reports 0 H/s (see
  [HiveOS stats](#hiveos-stats)).

---

## Configuration

The flight sheet is turned into `/hive/miners/custom/bloxminer/config.json` every time the miner starts:

```json
{
  "pools": [ { "name": "pool1", "url": "stratum+tcp://host:port", "timeout": 150 } ],
  "user": "RYourWalletAddress.rig1",
  "pass": "x",
  "retry-pause": 5,
  "ccd-temp-map": "auto",
  "threads": 32,
  "algo": "verus",
  "api-bind": "127.0.0.1:4068",
  "api-allow": "127.0.0.1",
  "log-file": "/var/log/miner/bloxminer/bloxminer.log"
}
```

**Extra config arguments** are JSON members merged into this file (keys are the long option names), e.g.
`"threads": 12`, `"pass": "1234"`, `"ccd-temp-map": "1"`, `"dashboard": true`, `"stats-interval": 30`.
`"dashboard"` (`true`/`false`, default `false`) turns the sticky stats header on in the HiveOS miner screen (see
[The miner screen](#the-miner-screen)). `algo`, `api-bind`, `api-allow`, `log-file` and `no-dashboard` are always
set by BloxMiner (HiveOS stats need the local API; only VerusHash is supported); if you put them in Extra config
they are ignored with a message.

Running by hand with both `-c config.json` and command-line options: the config file is applied **after** the
command line, so its values win (upstream ccminer behaviour).

`/hive/miners/custom/bloxminer/h-manifest.conf` sets the default `CCD_TEMP_MAP` (`auto`); Extra config
`"ccd-temp-map"` overrides it.

---

## CPU support

BloxMiner runs on any x86-64-v3 CPU with AES-NI and PCLMUL (AMD Zen or newer, Intel Haswell or newer).
Run `bloxminer --sensors` to see exactly what it detects on your machine.

| Feature | Where it works |
|---------|----------------|
| **Hashrate per physical core** | Every CPU where each thread is bound to its own CPU and the topology is in sysfs (normal Linux). Otherwise one row per thread, or a single total |
| **Temperature per core row** | **AMD:** per-CCD temperature (AMD has no per-core sensor) on validated CPUs, package temperature (Tctl) on the rest. **Intel:** real per-core temperature (coretemp; checked on a Core i9-10900KF). Multi-socket: package temperature per socket |
| **CPU power** | Wherever the kernel exposes RAPL package energy (AMD Zen and Intel on current kernels); needs root, which HiveOS miners have. Multi-socket: sum of all packages, shown only when every package is readable |

Per-CCD temperatures are switched on automatically only for CPU families where the mapping was confirmed by a
controlled load test (load pinned to one CCD at a time, only that CCD's sensor rises):

| CPU family | Per-CCD temps (`auto`) | Checked on |
|------------|------------------------|------------|
| Ryzen 5000 (Zen 3, 1–2 CCD) | yes | Ryzen 9 5950X and 5900X (per-CCD load tests). 1-CCD parts have a single CCD sensor |
| *other families* (Zen 2, Zen 4, …) | package temperature — `ccd-temp-map=1` forces a heuristic | not yet validated; profiles are added only after a load test |

---

## HiveOS stats

What HiveOS receives every agent tick (read from the miner's local API by `h-stats.sh`):

| Field | Content |
|-------|---------|
| `hs` | One value per physical core (kH/s), or per thread, or one total |
| `temp` | Per row: CCD / core temperature, else package temperature |
| `ar` | Accepted, rejected |
| `uptime`, `ver`, `algo` | Miner uptime (s), `2.1.0`, `verushash` |
| `cpu_power` | CPU package power in W (omitted when unavailable, never sent as 0). The HiveOS web (0.6-231, Sept 2026) does not show it in the CONSUMPTION tile; it is in the miner screen, log, API and `--sensors` |

The total is the sum of **fresh** rows: a thread counts only while it keeps finishing work. When every thread is
overdue (for example the pool connection is lost) the miner reports **0**, never its last rate — about 10 minutes
after the last work (a thread is overdue after 2 × its longest batch + 30 s, at least 5 and at most 10 min; the stats
reach HiveOS up to ~30 s later). A connection that goes silent without being closed (a network black hole) is not
detected by ccminer: the threads keep hashing the last job, so the rate stays and only the accepted count stops
rising; mining resumes by itself when the network returns (unchanged from ccminer and BloxMiner 2.0.0). The
benchmark numbers below use the miner's averaged summary rate instead.

---

## API

ccminer-compatible text API, `127.0.0.1:4068` by default (HiveOS keeps it local):

```bash
echo -n summary | nc 127.0.0.1 4068
echo -n cores   | nc 127.0.0.1 4068
echo -n threads | nc 127.0.0.1 4068
```

`summary` — the ccminer fields (abridged here), then `LASTWORK`, `STALL`, `FRESHKHS` and, new in 2.1.0,
`POWER` (W), `TEMP` (package °C), `CORES` (physical-core rows) and `ENGINE`. An empty value means unavailable:

```
NAME=bloxminer;VER=2.1.0;ALGO=verus;KHS=32693.12;ACC=11;REJ=0;UPTIME=90;LASTWORK=6;STALL=0;FRESHKHS=32500.77;POWER=89;TEMP=45;CORES=12;ENGINE=ccminer-3.8.3|
```

`cores` — a header, then one row per physical core (or per thread when binding/topology did not resolve):

```
GEN=45;AGE=1.8;ROWS=12;THREADS=24/24;PERCORE=1;STALL=0|ROW=0;PKG=0;CORE=0;CPUS=0,12;KHS=2727.13;TEMP=45;SRC=ccd|...
```

| Field | Meaning |
|-------|---------|
| `GEN` / `AGE` | Sample number / seconds since the sample (taken every 2 s) |
| `THREADS` | Threads represented / threads configured |
| `KHS` | Sum of the row's fresh thread rates (kH/s) |
| `TEMP` / `SRC` | Temperature and its source: `ccd`, `core`, `pkg`, `none` |

`threads` — one entry per mining thread (unchanged from 2.0.0):

```
CPU=0;KHS=1363.02;AFF=0;AGE=8;DUR=36;STATE=hashing|CPU=1;KHS=1372.25;AFF=1;AGE=8;DUR=18;STATE=hashing|...
```

| Field | Meaning |
|-------|---------|
| `KHS` | Rate of the thread's latest batch that ran long enough to measure (0 when overdue) |
| `AFF` | CPU the thread is bound to (`-1` = unbound) |
| `AGE` | Seconds since the thread last finished or was interrupted by a new pool job |
| `DUR` | Length of that measured batch (s) |
| `STATE` | A freshness flag: `hashing` = finished work recently; `waiting` = overdue (2 × the thread's longest batch + 30 s, at least 5 and at most 10 min) |

---

## Performance

2 × AMD Ryzen 9 5950X (32 threads), HiveOS on Ubuntu 22.04, same pool, balanced ABBA runs (2 × 10 min per miner
per rig) against Oink70's ccminer 3.8.3a (the fastest CPU build we measured):

| Rig | Oink70 3.8.3a | **BloxMiner 2.0.0** |
|-----|---------------|---------------|
| cask10 | 49.71 MH/s | **49.94 MH/s** |
| cask18 | 49.35 MH/s | **49.56 MH/s** |

BloxMiner **+0.4 %** versus Oink — equal within measurement noise — while adding per-core stats.

**2.1.0** (same rigs and method, the release package with the HiveOS default config, 2 × ABBA = 16 slots of 10 min):

| Rig | Oink70 3.8.3a | **BloxMiner 2.1.0** | Difference |
|-----|---------------|---------------------|-----------|
| cask10 | 50.31 MH/s | **50.24 MH/s** | −0.14 % |
| cask18 | 49.81 MH/s | **49.62 MH/s** | −0.39 % |

Overall **−0.27 %**, within the run-to-run noise (about ±1 % between 10-minute slots). The hashing code of 2.1.0 is
instruction-identical to
2.0.0 ([`tools/hashing-identity.sh`](tools/hashing-identity.sh)); 2.1.0 adds a stats thread (sensors every 2 s).
Full method, diagnosis and all runs: [BENCHMARKS.md](BENCHMARKS.md).

---

## Troubleshooting

| You see | Meaning / fix |
|---------|---------------|
| HiveOS message *"BloxMiner needs an x86-64-v3 CPU …"* | The CPU lacks AVX2/BMI2/FMA or AES-NI. BloxMiner cannot run on it |
| *"Pass is a thread count and must be 1-128"* | Pass is a number outside 1–128. Use a valid count, or put a numeric pool password in Extra config |
| *"BloxMiner mines VerusHash only"* | An `algo` other than `verus` was given (command line or config) |
| One row instead of one per core | The miner API did not answer completely in time, or threads could not be bound; `echo -n cores \| nc 127.0.0.1 4068` shows why |
| `...` in a core cell | That core has not finished its first batch yet (first minute after start) |
| Hashrate 0 and `STALLED` | No thread finished work for several minutes — usually the pool connection; check the log |
| `Power n/a` | No readable RAPL package counter (not root, or kernel/CPU without it). `bloxminer --sensors` says which |

---

## Requirements

| Category | Requirement |
|----------|-------------|
| **OS** | Any x86-64 Linux with glibc ≥ 2.34 and OpenSSL 3 (e.g. Ubuntu 22.04+, Debian 12+), including HiveOS on Ubuntu 22.04+. Older HiveOS 18.04 images: update with `hive-replace --stable` |
| **CPU** | x86-64-v3 (AVX2, BMI2, FMA) with AES-NI and PCLMULQDQ — AMD Ryzen / EPYC, Intel Haswell or newer |
| **Tuned for** | AMD Zen 3 (`-mtune=znver3`); runs on every CPU above |

---

## Building

On Ubuntu 22.04 x86-64:

```bash
build/build.sh                      # clang 14, -march=x86-64-v3 -mtune=znver3 -O3 → out/bloxminer-O3 (+ .provenance)
build/package.sh out/bloxminer-O3   # → bloxminer-2.1.0.tar.gz + SHA256SUMS
```

Source: [monkins1010/ccminer](https://github.com/monkins1010/ccminer) `Verus2.2` @ `e28e183` + [`build/bloxminer.patch`](build/bloxminer.patch).
The patch adds the BloxMiner screen, log file, sensors and power, the `cores` API, stall detection and fixes for
pool-input and option parsing; the hashing code (`verus/`) is unchanged.

`build.sh` records the upstream commit, patch hash, flags and the exact version of every build package in
`<binary>.provenance`; the package's `SOURCE.md` is generated from it. With those package versions the build is
reproducible bit for bit (two independent builds give the published sha256); newer compiler packages give a
working but different binary.

Tests (also run by CI): `tests/hive/test_hive_scripts.sh`, and against a built binary
`tests/engine/cli_test.sh`, `tests/engine/stratum_fuzz.py` and the fake-sysfs sensor tests `tests/engine/test_sys.cpp`
(`tests/engine/prepare_source.sh` creates the patched source).

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
The release package also contains `libomp.so.5` (LLVM, Apache-2.0 with LLVM exception; `LICENSE.libomp`,
`LICENSE.Apache-2.0`). The logo's wordmark is drawn from the Inter typeface (SIL Open Font License 1.1).
BloxMiner 1.x (the earlier from-scratch C++ miner, MIT) remains in this repository's history.

---

## Acknowledgments

- [VerusCoin Team](https://verus.io) - VerusHash
- [monkins1010/ccminer](https://github.com/monkins1010/ccminer) - Verus ccminer (Christian Buchner, Christian H., tpruvot and contributors)
- [Oink70/ccminer-verus](https://github.com/Oink70/ccminer-verus) - CPU builds and reference speed
- [Daniel Lemire](https://github.com/lemire/clhash) - CLHash algorithm
- [LLVM Project](https://llvm.org) - clang and libomp (Apache-2.0 with LLVM exception)
- [Inter](https://rsms.me/inter/) - typeface of the logo wordmark

---

<p align="center">
  <a href="https://github.com/bokiko/bloxminer">GitHub</a> •
  <a href="https://verus.io">Verus.io</a>
</p>

<p align="center">
  Made by <a href="https://github.com/bokiko">@bokiko</a>
</p>
