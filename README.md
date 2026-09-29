<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img src="assets/logo-light.svg" alt="BloxMiner" width="420">
</picture>

**CPU miner for Verus (VRSC, VerusHash v2.2) and Monero-family RandomX coins — one download, 0 % dev fee, runs
on any x86-64 Linux, HiveOS-ready**

<p>
  <a href="https://github.com/bokiko/bloxminer"><img src="https://img.shields.io/badge/GitHub-bloxminer-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://verus.io"><img src="https://img.shields.io/badge/Verus-VRSC-3165D4?style=for-the-badge" alt="Verus"></a>
  <a href="https://www.getmonero.org"><img src="https://img.shields.io/badge/RandomX-XMR_and_friends-FF6600?style=for-the-badge" alt="RandomX"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Version-3.0.0-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Based_on-ccminer_%2B_XMRig-00599C?style=flat-square" alt="ccminer + XMRig">
  <img src="https://img.shields.io/badge/Algorithms-VerusHash_v2.2_%2B_RandomX-blue?style=flat-square" alt="VerusHash + RandomX">
  <img src="https://img.shields.io/badge/Platform-Linux_x86--64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/HiveOS-Ready-green?style=flat-square" alt="HiveOS">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/Dev_fee-0%25-brightgreen?style=flat-square" alt="0% dev fee">
</p>

</div>

---

## Index

- [What it mines](#what-it-mines)
- [Two engines, one download](#two-engines-one-download)
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
- [Huge pages](#huge-pages)
- [Performance](#performance)
- [Troubleshooting](#troubleshooting)
- [Requirements](#requirements)
- [Building](#building)
- [Algorithm](#algorithm)
- [License](#license)

---

## What it mines

BloxMiner mines **VerusHash v2.2** — the proof-of-work of [Verus (VRSC)](https://verus.io) — **and RandomX** —
the proof-of-work of [Monero (XMR)](https://www.getmonero.org) and the RandomX-family coins XMRig itself
supports (Wownero, ArQmA, Graft, Safex, YadaCoin). One download; the flight sheet's algorithm picks which one
runs — see [Two engines, one download](#two-engines-one-download).

| | |
|---|---|
| **VRSC / XMR and RandomX-family coins** | Supported and tested on Verus and Monero-family stratum pools |
| **Fees** | **None, on either engine.** No dev fee and no donation mining: every share goes to your wallet on the pool you configure. Open source (GPL-3.0); the full changes are [`build/bloxminer.patch`](build/bloxminer.patch) (ccminer/Verus) and [`build/donate0.patch`](build/donate0.patch) (XMRig/RandomX, one line: the built-in donation level set to 0) |
| **Verus PBaaS chains** | The Verus merged-mining header handling is included (from monkins1010's ccminer). Whether a pool offers merged mining or a PBaaS chain, and which rewards you get, depends on the pool. Not tested by us |
| **Other coins / algorithms** | Not supported. A flight-sheet algorithm that is neither a VerusHash nor a RandomX-family value is refused at start with a message — see the table below |

---

## Two engines, one download

BloxMiner 3.0.0 ships **both** mining engines in a single package (still installed as the Custom miner
`bloxminer`, so a 2.1.0 rig upgrades in place by only changing the Installation URL's version — see
[Updating](#updating)). Which engine actually runs is decided every time the miner (re)starts, from the flight
sheet's **Hash algorithm** field — never both at once, and switching is just editing the flight sheet and
restarting the miner:

| Hash algorithm (flight sheet) | Engine | Notes |
|---|---|---|
| *(empty)* | Verus (VerusHash v2.2) | Backward compatible: a 2.1.0 flight sheet never had this field |
| `verus`, `verushash` | Verus (VerusHash v2.2) | |
| `randomx`, `rx/0` | RandomX | XMR and RandomX-family coins that use the plain `rx/0` variant |
| `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada` | RandomX | The other RandomX-family variants XMRig supports |
| anything else | *(refused)* | HiveOS shows an error message; the miner does not start (no restart loop) |

The two engines' own mining code is otherwise **unchanged** from their previous internal builds — BloxMiner
2.1.0's ccminer engine, and the RandomX engine, which is **XMRig 6.26.0 with the donation level set to 0**
(plus, as of 3.0.0, a display-only BloxMiner label — see below). BloxMiner 3.0.0 rebuilds both, each with one
small, precisely scoped, proven change: the Verus engine's own `configure.ac` release number (`AC_INIT`) moves
2.1.0 → 3.0.0 — that one line is the *entire* source diff versus the 2.1.0 patch — and every hashing function
in the resulting binary is proven instruction-identical to the 2.1.0 binary (`tools/hashing-identity.sh`,
15/15); the RandomX engine gets one extra *display-only* patch, `build/branding.patch`, on top of
`build/donate0.patch` — it adds two cosmetic log lines (a startup summary line and a periodic hashrate prefix)
touching two source files (plus one new header) and nothing else; XMRig's own `APP_VERSION`/user-agent/API
version stay exactly `6.26.0` for pool/API compatibility. Identity proof for the RandomX engine: rebuilding the
pre-branding (`donate0.patch`-only) source tree with the exact same recipe/toolchain used for the shipped
binary reproduces this engine's own previous internal build (never separately published) **bit-for-bit**
(sha256 `721aa3fc9a7a…`); comparing that reproduction against the shipped, branded binary (`44cff475d581…`)
object file by object file shows 208 of 210 `.o` files byte-identical — the only two that differ are the two
touched source files' own objects, and `xmrig --bench=1M` produces the identical result hash on both binaries.
See [Building](#building) and `docs/3.0.0-engine-identity.md` for the full proof output including exact
binaries compared. Only the parts that genuinely have to be shared (the package directory, the log file base,
the engine picker itself) are new. That means:

- **Pass means something different per engine** (unchanged from each engine's own 1.x/2.x behaviour): on the
  Verus engine, Pass is a **thread count** (`1`–`128`, or empty for every CPU); on the RandomX engine, Pass is
  the **pool password** sent as-is (numeric or not) — RandomX's own thread count comes from XMRig's cache-aware
  autoconfig, steerable via Extra config (see [Configuration](#configuration)).
- **"Pass" in the miner screen/API means something different per engine too**: the Verus engine's `A`/`R`
  counts and per-core table are its own (see [The miner screen](#the-miner-screen)); the RandomX engine reports
  XMRig's own accepted/rejected counts and per-core rows, the same way it always has.
- **Each engine keeps its own Extra config options** — the Verus ones (`threads`, `ccd-temp-map`, `dashboard`,
  …, see [Configuration](#configuration)) only apply when Hash algorithm selects the Verus engine; the RandomX
  ones (`tls`, `1gb-pages`, `cpu`, …) only apply when it selects the RandomX engine. Setting a Verus-only key
  while mining RandomX (or vice versa) has no effect.
- **The API port differs**: `127.0.0.1:4068` (Verus engine) or `127.0.0.1:4069` (RandomX engine) — see
  [API](#api). `WEB_PORT` in the HiveOS manifest is fixed at `4068`, so the HiveOS web UI's port link only ever
  points at the Verus engine's API; it is simply dead while the RandomX engine is active (the miner screen and
  HiveOS farm stats are unaffected either way — neither depends on `WEB_PORT`).
- **Switching engines is clean**: the previous engine is never left running (HiveOS stops it before the new one
  starts), and its config.json is fully rewritten for the new engine. If the RandomX engine had reserved huge
  pages, switching to the Verus engine releases that reservation *only* when it was confirmed ("finalized") in
  the same boot and `vm.nr_hugepages` still matches what BloxMiner left it at — otherwise it is left untouched
  and logged, never guessed at. See [Huge pages](#huge-pages) for the exact conditions.

---

## Installation

### HiveOS Flight Sheet (Recommended)

1. **Create New Flight Sheet**
   - Coin: `VRSC` (Verus) or `XMR` (Monero)/your RandomX-family coin
   - Wallet: Select your wallet
   - Pool: `Configure in miner`

2. **Add Miner**
   - Miner: `Custom`
   - Miner name: `bloxminer`
   - Installation URL:
     ```
     https://github.com/bokiko/bloxminer/releases/download/3.0.0/bloxminer-3.0.0.tar.gz
     ```
   - Hash algorithm: `verushash` (Verus) or `randomx` / `rx/0` / `rx/wow` / `rx/arq` / `rx/graft` / `rx/sfx` / `rx/yada` (RandomX) — see [Two engines, one download](#two-engines-one-download)
   - Wallet and worker template: `%WAL%.%WORKER_NAME%`
   - Pool URL: your pool, e.g. `stratum+tcp://veruscoin.cedric-crispin.com:4024` (Verus) or `stratum+tcp://pool.example.com:PORT` / `stratum+ssl://...` (RandomX)
   - Pass: **Verus** — number of threads, `1`–`128` (e.g. `32`), or empty for all CPUs. **RandomX** — the pool password (or empty)

3. **Apply Flight Sheet** to your rig

#### Flight Sheet Fields

| Field | Value | Notes |
|-------|-------|-------|
| Miner | `custom` | Required |
| Miner name | `bloxminer` | Must match exactly |
| Installation URL | `https://github.com/bokiko/bloxminer/releases/download/3.0.0/bloxminer-3.0.0.tar.gz` | HiveOS installs it once and reuses it, for either engine |
| Hash algorithm | `verushash` or `randomx`/`rx/wow`/… | Picks the engine — see [Two engines, one download](#two-engines-one-download) |
| Wallet template | `%WAL%.%WORKER_NAME%` | Your wallet.worker |
| Pool URL | `stratum+tcp://host:port` (or `stratum+ssl://` for RandomX) | Your pool (`host:port` also works) |
| Pass | Verus: `32` (thread count `1`–`128`, optional, empty = every CPU). RandomX: the pool password, or empty | Meaning depends on the engine — see [Two engines, one download](#two-engines-one-download) |
| Extra config arguments | *(empty)* | Optional JSON members, engine-specific — see [Configuration](#configuration) |

A **Verus** pool that needs a **numeric** password: leave Pass empty and put `"pass": "1234"` in Extra config.

### HiveOS Terminal Install

```bash
/hive/miners/custom/custom-get https://github.com/bokiko/bloxminer/releases/download/3.0.0/bloxminer-3.0.0.tar.gz
```

Then set the flight sheet as above. On a fresh HiveOS image, HiveOS installs its custom-miner support automatically
the first time a flight sheet uses a Custom miner.

### Updating

**From 2.1.0**: change only the version in the Installation URL (`2.1.0` → `3.0.0`) and apply the flight sheet.
Everything else keeps working as before — an empty Hash algorithm still means the Verus engine, so a 2.1.0
Verus rig upgrades in place with no other field changes. HiveOS downloads the new package and restarts the
miner.

**Switching an existing rig between engines** (e.g. Verus → RandomX on the same rig): change Hash algorithm,
Pool URL and Wallet as usual, but also **review Pass and Extra config** — both mean something different per
engine (see [Two engines, one download](#two-engines-one-download)), so carrying either over unchanged is
usually wrong, not just unnecessary:
- **Pass**: a thread count `1`–`128` on the Verus engine; the pool password on the RandomX engine.
- **Extra config**: engine-specific keys (e.g. `ccd-temp-map` vs `1gb-pages`) are simply ignored on the wrong
  engine, but the other engine's own selector marker (a top-level `randomx` key, or `algo`) is rejected
  outright if it ends up in Extra config — the miner refuses to start rather than produce an ambiguous config.

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
== BloxMiner 3.0.0 | 49.80 MH/s | A 32 R 0 | 136 W | 64 C | 365 kH/W | up 0h01m ==
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
| BloxMiner 3.0.0  Ryzen 9 5900X  12C/24T                            up 0h00m  |
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

**RandomX engine** — the screen is XMRig 6.26.0's own, with two added BloxMiner lines: a startup summary line
and a literal prefix on the existing periodic speed line. Captured output (colours on, as HiveOS gets by
default; ANSI stripped here for readability):

```
 * BLOXMINER    3.0.0 (XMRig 6.26.0 engine)
...
BloxMiner 3.0.0  miner    speed 10s/60s/15m 8869.8 n/a n/a H/s max 9061.2 H/s
```

Everything else — the rest of the startup banner, share lines, per-thread output — is XMRig's own, unmodified.
HiveOS reports the version as `3.0.0 (xmrig 6.26.0)` (the Verus engine reports `3.0.0 (verus)`) — see
[HiveOS stats](#hiveos-stats).

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

Each flight sheet configures **exactly one pool, with no failover list** — if that pool goes down, the miner
idles and retries against it rather than falling over to another one; point Pool URL at a different pool and
re-apply the flight sheet if you need to change it.

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

**RandomX engine** (Hash algorithm `randomx`/`rx/0`/`rx/wow`/…): the same flight sheet fields produce XMRig's
own config.json instead (`threads` above does not apply — see [Two engines, one download](#two-engines-one-download)):

```json
{
  "cpu": { "enabled": true, "huge-pages": true },
  "randomx": {},
  "donate-level": 0, "donate-over-proxy": 0,
  "http": { "enabled": true, "host": "127.0.0.1", "port": 4069, "restricted": true },
  "pools": [ { "url": "stratum+tcp://host:port", "user": "XYourWalletAddress.rig1", "pass": "x", "algo": "rx/0" } ]
}
```

RandomX Extra config keys (JSON members, merged in): `"tls": true` (force TLS even without `stratum+ssl://`),
`"1gb-pages": true` (only applied when every NUMA node reports ≥ 3 GiB free right now, else dropped with a
message), `"cpu": {...}` (merged into the `cpu` object — e.g. `"cpu": {"max-threads-hint": 50}`; `enabled` and
`huge-pages` are always forced on and cannot be overridden), and any of XMRig's own top-level options that are
not already set by BloxMiner (`donate-level`, `http`, `log-file`, … are always fixed). `algo`, `api`/`http` and
`log-file` are always set by BloxMiner; if you put them in Extra config they are ignored with a message.

---

## CPU support

CPU requirements are per engine (each keeps its own gated check, unchanged): the **Verus engine** needs
x86-64-v3 with AES-NI and PCLMUL (AMD Zen or newer, Intel Haswell or newer); the **RandomX engine** needs only
AES-NI (RandomX itself requires AES acceleration) on any x86-64 CPU — see
[Two engines, one download](#two-engines-one-download). The table below describes the Verus engine's own
per-core stats; the RandomX engine's stats and topology detection are XMRig's own (unchanged since this
engine's first internal build). Run `bloxminer --sensors` to see exactly what the Verus engine detects on your
machine.

**Validated on real HiveOS rigs** (beyond the CI/toolchain checks above): **Ryzen 9 5950X** — both engines
(RandomX: MSR `ryzen_19h` preset, dataset huge pages 100 %, live pool mining, engine switching, kill/restart,
HiveOS agent restart; Verus: live pool mining, per-CCD temperature mapping — see the table below). **Ryzen 9
5900X** — Verus engine, per-CCD temperature mapping.

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

What HiveOS receives every agent tick, read from whichever engine is currently active (`h-stats.sh` is a thin
dispatcher: it never mixes data from the two engines — see [Two engines, one download](#two-engines-one-download)):

| Field | Content |
|-------|---------|
| `hs` | One value per physical core (kH/s), or per thread, or one total |
| `temp` | Per row: CCD / core temperature, else package temperature |
| `ar` | Accepted, rejected |
| `uptime` | Miner uptime (s) |
| `ver` | `3.0.0 (verus)` on the Verus engine (or `3.0.0 (verus, engine <n>)` if a future package ever ships a differently versioned engine build), `3.0.0 (xmrig 6.26.0)` on the RandomX engine |
| `algo` | `verushash` (Verus engine) or the active RandomX variant, e.g. `rx/0`, `rx/wow` (RandomX engine) |
| `cpu_power` | CPU package power in W (omitted when unavailable, never sent as 0). The HiveOS web (0.6-231, Sept 2026) does not show it in the CONSUMPTION tile; it is in the miner screen, log, API and `--sensors` |

The total is the sum of **fresh** rows: a thread counts only while it keeps finishing work. When every thread is
overdue (for example the pool connection is lost) the miner reports **0**, never its last rate — about 10 minutes
after the last work (a thread is overdue after 2 × its longest batch + 30 s, at least 5 and at most 10 min; the stats
reach HiveOS up to ~30 s later). A connection that goes silent without being closed (a network black hole) is not
detected by ccminer: the threads keep hashing the last job, so the rate stays and only the accepted count stops
rising; mining resumes by itself when the network returns (unchanged from ccminer and BloxMiner 2.0.0). The
benchmark numbers below use the miner's averaged summary rate instead.

**Both engines' collectors, under CPU load:** `h-stats.sh` runs in a killable child bound by ONE absolute
deadline (a single `DEADLINE_US`, computed once at the true poll entry — the top-level dispatcher, before even
manifest parsing or engine selection — and threaded through launch, collection, enrichment and cleanup — never
a fresh relative timer re-armed partway through), targeting 3.0 s for the whole poll even when the miner
saturates every CPU in a small cpuset; at the most extreme contention (1-2 CPUs pinned against many more
competing threads) scheduling/signal-delivery delay alone can still push a poll past that target — it is a
target enforced by one shared deadline, not a hard ceiling — but it never produces a false zero even then (see
`tests/hive/test_verus_under_load.sh`). There is no cache of the hashrate: every poll splits into a mandatory
Phase A — one cheap, bounded API call that alone yields the rate, accepted/rejected and stall/freshness state,
validated fresh on THIS poll — written immediately, before anything else is attempted, so a kill later in the
same poll can never lose it; and an optional Phase B (per-core rows, sensors, topology verification) that runs
with whatever budget remains and may only ever *replace Phase A's WHOLE result* (both the total and its own
stats together, never a mix of the two) with its own when Phase B's own data is complete (every row present,
none missing/null) and consistent with Phase A (within a 10% tolerance of Phase A's own value when Phase A has
a confident positive rate — never a null-as-zero or a near-zero reply quietly outvoting a positive, fresher
rate) — otherwise Phase A's total AND its own stats stand, untouched. If the fresh-rate call itself cannot
complete under starvation, the poll reports 0, honestly, inside the same budget — never a stale positive left
over from an earlier poll or a different
instance. RandomX's ownership check (the API port belongs to *this* `xmrig`, confirmed via `/proc`) also gates a
small, cosmetic per-instance cache of the last real *temperature* only, bound by pid+start-time+age (never the
hashrate). See `tests/hive/test_rx_stats_cache.sh`, `tests/hive/test_rx_under_load.sh` and
`tests/hive/test_verus_under_load.sh`. The Verus engine's field parser also uses plain shell parameter expansion
instead of forking `tr`/`grep`/`cut` for every field of every `cores` row — on a many-core rig that per-field
forking was, on its own, measured to be slow enough under a saturated small cpuset to matter.

---

## API

**Verus engine** — ccminer-compatible text API, `127.0.0.1:4068` by default (HiveOS keeps it local). **RandomX
engine** — XMRig's own JSON HTTP API, `127.0.0.1:4069`, restricted/local, e.g. `curl http://127.0.0.1:4069/2/summary`
(see the [XMRig API docs](https://xmrig.com/docs/miner/api)). Only the Verus engine's text API is documented
below (unchanged from 2.1.0); `WEB_PORT` (the HiveOS web UI port link) is fixed at `4068` either way — see
[Two engines, one download](#two-engines-one-download).

```bash
echo -n summary | nc 127.0.0.1 4068
echo -n cores   | nc 127.0.0.1 4068
echo -n threads | nc 127.0.0.1 4068
```

`summary` — the ccminer fields (abridged here), then `LASTWORK`, `STALL`, `FRESHKHS` and, new in 2.1.0,
`POWER` (W), `TEMP` (package °C), `CORES` (physical-core rows) and `ENGINE`. An empty value means unavailable:

```
NAME=bloxminer;VER=3.0.0;ALGO=verus;KHS=32693.12;ACC=11;REJ=0;UPTIME=90;LASTWORK=6;STALL=0;FRESHKHS=32500.77;POWER=89;TEMP=45;CORES=12;ENGINE=ccminer-3.8.3|
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

## Huge pages

The RandomX engine reserves ~1200 × 2 MB huge pages on start: Hive's own `hugepages -rx` helper sets an
initial `vm.nr_hugepages`, then XMRig itself may raise that value further on its own (it maps one extra huge
page for its JIT compiler that Hive's helper does not account for). BloxMiner does not trust Hive's number for
this — it measures what XMRig actually mapped, read from the running process's own memory map
(`/proc/<pid>/smaps_rollup`), and that measured value is what gets recorded and (conditionally) restored below.

**Exclusive-ownership policy.** From the moment the dispatcher runs `hugepages -rx` for a fresh RandomX start
until this package positively confirms ("finalizes") what XMRig itself raised `vm.nr_hugepages` to — bounded by
`HUGEPAGES_STARTUP_WINDOW_S` in `bloxminer/h-common.sh`, 300 s by default (comfortably above the ~2 s a real
dataset takes to become ready on a modern CPU — finalization happens within seconds in practice) — BloxMiner
assumes it is the **only** thing writing `vm.nr_hugepages` on the rig, since HiveOS runs exactly one miner at a
time. Anything else that also writes `vm.nr_hugepages` during that same window (a custom script, another miner
test, manual `sysctl`) is unsupported and can make BloxMiner adopt a value it did not itself set; don't do
that. If the reservation is never confirmed within the window, BloxMiner gives up on ever finalizing that
session's record — it is logged once, and no restore will happen on the next Verus switch (the "unsupported"
outcome above is scoped to that startup window alone, never open-ended).

**Restore conditions, on switching to the Verus engine.** The reservation is only ever restored automatically
when **both** are true: the RandomX engine's reservation was finalized (confirmed, as above) in the *same
boot*, and `vm.nr_hugepages` still equals exactly the value BloxMiner left it at (nothing else changed it in
the meantime). If either condition fails — no finalized record, a different boot, or the live value has moved
— BloxMiner leaves `vm.nr_hugepages` untouched and logs why, rather than guessing. **1 GB pages are never
auto-restored**, under any condition (this covers 2 MB huge pages only); if you turn on `1gb-pages` in Extra
config, plan to manage that reservation yourself.

A finalized record is only ever trusted within the SAME boot it was written in (`boot_id` from
`/proc/sys/kernel/random/boot_id`, checked both when finalizing and again before every restore) - it lives on
tmpfs anyway, so a reboot normally clears it outright, but this is a second, explicit guard in case that ever
is not true (an unusual `$STATEDIR` override, for example).

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

**3.0.0** — both engines are rebuilt only to show the release number; neither engine's hashing code changed
(see [Two engines, one download](#two-engines-one-download) and `docs/3.0.0-engine-identity.md`).

*Verus engine*: instruction-identical to 2.1.0 (15/15 functions, `tools/hashing-identity.sh`). Live sanity
check on cask18 (Ryzen 9 5950X), old (2.1.0) / new (3.0.0) / new / old, 10-minute slots:

| Slot | 1 (old) | 2 (new) | 3 (new) | 4 (old) |
|---|---|---|---|---|
| kH/s | 49 877 | 49 916 | 50 167 | 50 047 |

Mean: old 49 962 kH/s, new 50 041.5 kH/s — **+0.16 %**, within the slot-to-slot noise (about ±1 %).

*RandomX engine* — the shipped 3.0.0 binary reproduces the exact XMRig binary already benchmarked at the X6
gate (bit-for-bit against the pre-branding rebuild, 208 of 210 compiled objects identical; see
`docs/3.0.0-engine-identity.md`), plus the display-only branding patch, so that benchmark carries over without
a re-run. Both 5950X rigs, BloxMiner (bx) vs HiveOS's stock XMRig 6.26.0, same pool, alternated slots:

| Rig | bx | stock XMRig 6.26.0 |
|---|---|---|
| cask10 | 15 898.50 / 15 868.85 H/s | 15 906.74 / 15 879.36 H/s |
| cask18 | 15 855.62 / 15 869.82 H/s | 15 823.32 / 15 816.05 H/s |

Mean: bx 15 873.20 H/s vs stock 15 856.37 H/s — **+0.11 %** overall (cask10 −0.06 %, cask18 +0.27 %), within
the slot-to-slot noise.

*RandomX live sanity on the 3.0.0 package* (same cask18 ABBA method, to confirm the shipped package itself,
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

Full method, diagnosis and all runs: [BENCHMARKS.md](BENCHMARKS.md).

---

## Troubleshooting

| You see | Meaning / fix |
|---------|---------------|
| HiveOS message *"BloxMiner needs an x86-64-v3 CPU …"* | Verus engine: the CPU lacks AVX2/BMI2/FMA or AES-NI. Switch to the RandomX engine (needs only AES-NI) if your coin choice allows it, otherwise this CPU cannot mine Verus with BloxMiner |
| HiveOS message *"BloxMiner needs an x86-64 CPU with AES-NI …"* | RandomX engine: the CPU lacks AES-NI, which RandomX itself requires |
| *"Pass is a thread count and must be 1-128"* | Verus engine: Pass is a number outside 1–128. Use a valid count, or put a numeric pool password in Extra config |
| *"Algorithm must be empty (Verus/VerusHash) …"* | The flight sheet's Hash algorithm is neither empty/Verus nor a RandomX-family value — see [Two engines, one download](#two-engines-one-download) |
| One row instead of one per core | The miner API did not answer completely in time, or threads could not be bound; `echo -n cores \| nc 127.0.0.1 4068` shows why |
| `...` in a core cell | That core has not finished its first batch yet (first minute after start) |
| Hashrate 0 and `STALLED` | No thread finished work for several minutes — usually the pool connection; check the log |
| `Power n/a` | No readable RAPL package counter (not root, or kernel/CPU without it). `bloxminer --sensors` says which |
| HiveOS web UI's port link is dead in RandomX mode | Expected: `WEB_PORT` is fixed at `4068`, the Verus engine's API port. The RandomX engine's own API is `4069` — see [API](#api). The miner screen and HiveOS farm stats work either way |
| Miner idling / not switching pools on its own | Expected: each flight sheet has exactly one pool, with no failover list. If that pool is down the miner idles and retries against it; point Pool URL at a different pool and re-apply if you need one |
| Huge pages not released after switching RandomX → Verus | Expected in some cases: restore only happens when the RandomX engine's reservation was finalized in the same boot and `vm.nr_hugepages` still matches what BloxMiner left it at; otherwise it is left untouched and logged, and 1 GB pages are never auto-restored — see [Huge pages](#huge-pages) |
| MSR tuning still applied after `kill -9` | Expected: XMRig's own MSR register tweak (RandomX engine) persists until the next reboot even after a hard kill; restarting the miner does not undo it (same as stock XMRig) |
| Reboot / HiveOS online-boot path | Not re-tested for 3.0.0 (owner check pending) |

---

## Requirements

| Category | Requirement |
|----------|-------------|
| **OS** | Any x86-64 Linux with glibc ≥ 2.34 and OpenSSL 3 (e.g. Ubuntu 22.04+, Debian 12+), including HiveOS on Ubuntu 22.04+. Older HiveOS 18.04 images: update with `hive-replace --stable` |
| **CPU** | x86-64-v3 (AVX2, BMI2, FMA) with AES-NI and PCLMULQDQ — AMD Ryzen / EPYC, Intel Haswell or newer |
| **Tuned for** | AMD Zen 3 (`-mtune=znver3`); runs on every CPU above |

---

## Building

BloxMiner 3.0.0 rebuilds both engines from source, each with a change proven not to touch mining code (see
above). `build/build.sh` and `build/build-rx.sh` each clone their pinned upstream, apply their patch(es), build,
and write their own binary + provenance; `build/package.sh` then verifies every sha256 (and, for the version
strings, the declared version itself) against that build's own recorded provenance and assembles the combined
package deterministically — two independent runs (including a fresh network re-clone of both upstream engines
for the source bundle below) give byte-identical output:

```bash
build/build.sh      # Verus engine: clang 14, -march=x86-64-v3 -mtune=znver3 -O3 -> out/bloxminer-O3 (+ .provenance, + libomp.so.5)
build/build-rx.sh   # RandomX engine: gcc 11, cmake Release, static libuv/hwloc/OpenSSL -> out/xmrig, out/bloxsense (+ build.provenance)
build/package.sh out out
# -> bloxminer-3.0.0.tar.gz + bloxminer-3.0.0-src.tar.gz + SHA256SUMS
```

(`build/build.sh` and `build/build-rx.sh` write to `./out` by default; pass each its own outdir if you keep them
separate, and give `package.sh` the two matching outdirs.) Both must run on Ubuntu 22.04 x86-64: `build.sh` in a
container/chroot with `libssl-dev` pinned to OpenSSL 3 (refuses to run on a HiveOS rig, which pins 1.1.1),
`build-rx.sh` as root.

Source: **Verus engine** — [monkins1010/ccminer](https://github.com/monkins1010/ccminer) `Verus2.2` @ `e28e183`
+ [`build/bloxminer.patch`](build/bloxminer.patch) (adds the BloxMiner screen, log file, sensors and power, the
`cores` API, stall detection, fixes for pool-input and option parsing, and — for 3.0.0 — the `AC_INIT` release
number 2.1.0 → 3.0.0; the hashing code (`verus/`) is unchanged, proven with `tools/hashing-identity.sh`).
**RandomX engine** — [xmrig/xmrig](https://github.com/xmrig/xmrig) `v6.26.0` +
[`build/donate0.patch`](build/donate0.patch) (one line: the built-in donation level, 1 % → 0 %) +
[`build/branding.patch`](build/branding.patch) (display-only: a `BLOX_DISPLAY_VERSION` constant used by exactly
two cosmetic log lines — the startup summary and the periodic hashrate prefix; never touches `APP_VERSION`, the
user-agent, or the API version) plus `bloxsense`, BloxMiner's own CPU/sensor helper (shared, unchanged source
compiled identically for both engines' packaging).

`build.sh`/`build-rx.sh` record the upstream commit, patch hash, flags and the exact version of every build
package/static dependency in `<binary>.provenance`/`build.provenance`; each release's `SOURCE.md` is generated
from it, and `build/package.sh` re-verifies all of it (and re-clones + re-patches both upstream trees for the
GPL source bundle) before it will assemble a 3.0.0 package — see [SOURCE.md](bloxminer/SOURCE.md) in the
package and `bloxminer-3.0.0-src.tar.gz`.

Tests (also run by CI): `tests/hive/test_dispatcher.sh` (engine selection, the state file, hugepage hygiene on
switch), `tests/hive/test_config_diff.sh` (this package's generated configs are byte-equal to each engine's
previous gated build, for the same inputs), `tests/hive/test_verus_hive_scripts.sh` and
`tests/hive/test_rx_hive_scripts.sh` (each engine's own gated suite, adapted to the shared package layout),
`tests/hive/test_rx_under_load.sh` (RandomX engine under full CPU load, including the real `xmrig`+`bloxsense`),
`tests/build/test_package_provenance.sh` (every sha256 `package.sh` checks really is checked) and
`tests/bloxsense/run_tests.sh`. Against a built Verus engine binary: `tests/engine/cli_test.sh`,
`tests/engine/stratum_fuzz.py` and the fake-sysfs sensor tests `tests/engine/test_sys.cpp`
(`tests/engine/prepare_source.sh` creates the patched source).

---

## Algorithm

**VerusHash v2.2** (Verus engine) combines multiple cryptographic primitives for ASIC resistance:

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

**RandomX** (RandomX engine) is Monero's proof-of-work: a randomised sequence of general-purpose CPU
instructions and virtual-machine programs per hash, specifically designed to run efficiently only on general
CPUs (favouring a large cache/random memory access over GPU/ASIC/FPGA throughput). BloxMiner's RandomX engine is
XMRig, upstream and unmodified except the donation patch above — see the
[RandomX design document](https://github.com/tevador/RandomX/blob/master/doc/design.md) for the algorithm itself.

---

## License

GPL-3.0 — see [LICENSE](LICENSE). The Verus engine is built from ccminer; the RandomX engine is built from
XMRig — both GPL-licensed. The release package also contains `libomp.so.5` (LLVM, Apache-2.0 with LLVM
exception; `LICENSE.libomp`, `LICENSE.Apache-2.0`, Verus engine only) and, statically linked into the RandomX
engine, libuv (MIT), hwloc (BSD-3-Clause) and OpenSSL 3 (Apache-2.0) — see `LICENSES/`. The logo's wordmark is
drawn from the Inter typeface (SIL Open Font License 1.1). BloxMiner 1.x (the earlier from-scratch C++ miner,
MIT) remains in this repository's history.

---

## Acknowledgments

- [VerusCoin Team](https://verus.io) - VerusHash
- [monkins1010/ccminer](https://github.com/monkins1010/ccminer) - Verus ccminer (Christian Buchner, Christian H., tpruvot and contributors)
- [Oink70/ccminer-verus](https://github.com/Oink70/ccminer-verus) - CPU builds and reference speed
- [Monero Project](https://www.getmonero.org) / [tevador](https://github.com/tevador/RandomX) - RandomX
- [XMRig](https://github.com/xmrig/xmrig) - RandomX engine (xmrig.com, XMRig contributors)
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
