<div align="center">

# BloxMiner

**High-Performance VerusHash v2.2 CPU Miner for Verus Coin**

<p>
  <a href="https://github.com/bokiko/bloxminer"><img src="https://img.shields.io/badge/GitHub-bloxminer-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://verus.io"><img src="https://img.shields.io/badge/Verus-VRSC-3165D4?style=for-the-badge" alt="Verus"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Version-1.0.3-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Language-C++-00599C?style=flat-square&logo=cplusplus" alt="C++">
  <img src="https://img.shields.io/badge/Algorithm-VerusHash_v2.2-blue?style=flat-square" alt="VerusHash">
  <img src="https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/HiveOS-Ready-green?style=flat-square" alt="HiveOS">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

</div>

---

## Quick Install

### Ubuntu/Debian (Interactive)
```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/install.sh | bash
```
The installer will ask for your wallet, pool, and thread count, then start mining.

### HiveOS (Flight Sheet)
```
Installation URL: https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh
```

### HiveOS (Terminal)
```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh | bash
```

---

## Overview

BloxMiner is a CPU miner for [Verus Coin (VRSC)](https://verus.io) implementing the VerusHash v2.2 algorithm. Designed for maximum performance on modern x86-64 CPUs with AES-NI, AVX2, and PCLMULQDQ hardware acceleration.

---

## Live Stats Display

```
+------------------------------------------------------------+
|  BloxMiner v1.0.3 - VerusHash CPU Miner                    |
+------------------------------------------------------------+
|  Hashrate: 27.67 MH/s     Temp: 54C       Pool: (1/3)      |
|  Accepted: 367            Rejected: 0     Diff: 128        |
|  Uptime: 3h 24m           Power: 110.6W   Eff: 250 KH/W    |
+------------------------------------------------------------+
|  Thread hashrates: 865K 867K 864K 866K 865K 868K ...       |
+------------------------------------------------------------+
```

---

## Features

<table>
<tr>
<td width="50%">

### Performance
- VerusHash v2.2 mainnet algorithm
- AES-NI hardware acceleration
- AVX2 vector optimizations
- PCLMULQDQ carry-less multiplication

</td>
<td width="50%">

### Compatibility
- Multi-threaded (auto-detect cores)
- Stratum v1 protocol
- All major Verus pools
- HiveOS native support

</td>
</tr>
<tr>
<td width="50%">

### Reliability
- Failover pool support (multiple -o)
- Exponential backoff reconnection
- Auto pool switching after 3 failures
- Primary pool retry every 5 minutes

</td>
<td width="50%">

### Monitoring
- Real-time htop-style stats display
- CPU temperature monitoring
- Power consumption (RAPL + AMD hwmon)
- Per-thread hashrate breakdown
- JSON API on port 4068
- Quiet mode for reduced log noise

</td>
</tr>
</table>

---

## Quick Start

### Ubuntu/Debian

```bash
# Install dependencies
sudo apt update
sudo apt install build-essential cmake libssl-dev git

# Clone and build
git clone https://github.com/bokiko/bloxminer.git
cd bloxminer
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Run (interactive setup on first run)
./bloxminer
```

### Updating

```bash
cd bloxminer
git pull
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

---

## Configuration

BloxMiner saves your settings in `bloxminer.json` so you don't need to enter them every time.

### First Run (Interactive Setup)

```
$ ./bloxminer

========================================
   BloxMiner First-Run Setup
========================================

Enter your Verus (VRSC) wallet address:
> RYourWalletAddress

Enter pool address [pool.verus.io:9999]:
>

Enter worker name [hostname]:
> rig1

Enter thread count (1-32) [auto=32]:
>

Save this configuration? [Y/n]: y
Configuration saved to bloxminer.json
```

### Config File Format

```json
{
  "wallet": "RYourWalletAddress",
  "pools": [
    {"host": "pool.verus.io", "port": 9999},
    {"host": "na.luckpool.net", "port": 3956}
  ],
  "worker": "rig1",
  "threads": 0,
  "api": {
    "enabled": true,
    "port": 4068,
    "bind": "127.0.0.1"
  }
}
```

### Config File Locations

1. `./bloxminer.json` (current directory - checked first)
2. `~/.config/bloxminer/config.json` (user global)

### CLI Overrides

Command-line arguments always override config file values:

```bash
./bloxminer -t 8              # Override thread count
./bloxminer -o other:3956     # Override pool
```

---

## Usage

```bash
./bloxminer [options]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-c, --config` | Config file path | bloxminer.json |
| `-o, --pool` | Pool address (host:port). Repeat for failover | From config |
| `-u, --user` | Wallet address | From config |
| `-w, --worker` | Worker name | hostname |
| `-p, --pass` | Pool password | x |
| `-t, --threads` | Mining threads | Auto-detect |
| `-q, --quiet` | Quiet mode (warnings/errors only) | Off |
| `--api-port` | API port (0 to disable) | 4068 |
| `--api-bind` | API bind address | 127.0.0.1 |

### Examples

```bash
# Use config file (recommended)
./bloxminer

# Override specific options
./bloxminer -t 8 -q

# Full command line (no config needed)
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress -w rig1 -t 4

# Failover pools
./bloxminer -o pool.verus.io:9999 -o na.luckpool.net:3956 -u RYourWalletAddress
```

---

## API

BloxMiner exposes a JSON API on port 4068:

```bash
curl http://localhost:4068
```

```json
{
  "miner": "BloxMiner",
  "version": "1.0.3",
  "algorithm": "verushash",
  "uptime": 12345,
  "hashrate": {
    "total": 24150.5,
    "threads": [755.2, 758.1, ...],
    "unit": "KH/s"
  },
  "shares": {
    "accepted": 367,
    "rejected": 0
  },
  "hardware": {
    "threads": 32,
    "temp": 55,
    "power": 110.6,
    "efficiency": 218.4,
    "efficiency_unit": "KH/W"
  }
}
```

---

## Requirements

| Category | Requirement |
|----------|-------------|
| **OS** | Ubuntu 20.04+, Debian 11+, HiveOS |
| **CPU** | x86-64 with AES-NI, AVX2, PCLMULQDQ |
| **Compiler** | GCC 9+ or Clang 10+ |
| **Build** | CMake 3.16+, OpenSSL dev libs |

Most Intel (Haswell+) and AMD (Zen+) processors are supported.

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| **Language** | C++17 |
| **Build** | CMake |
| **Crypto** | OpenSSL, AES-NI intrinsics |
| **Protocol** | Stratum v1 |
| **Monitoring** | RAPL, lm-sensors |

---

## Project Structure

```
bloxminer/
├── src/
│   ├── main.cpp              # Entry point
│   ├── miner.cpp             # Mining engine
│   ├── crypto/               # Haraka, CLHash, VerusHash
│   ├── stratum/              # Pool communication
│   └── utils/                # Hex, logging, display
├── include/                  # Header files
├── tests/                    # Test programs
├── install.sh                # Ubuntu installer
├── h-install.sh              # HiveOS installer
├── h-stats.sh                # HiveOS stats parser
├── CMakeLists.txt
└── README.md
```

---

## Algorithm

VerusHash v2.2 combines multiple cryptographic primitives for ASIC resistance:

```
Block Data (1487 bytes)
    │
    ▼
Haraka512 Chain (AES-NI accelerated)
    │
    ▼
Key Generation (8832 bytes via Haraka256)
    │
    ▼
CLHash v2.2 (32 iterations + AES mixing)
    │
    ▼
Final Haraka512 (keyed)
    │
    ▼
Hash Result (32 bytes)
```

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Acknowledgments

- [VerusCoin Team](https://verus.io) - Original VerusHash implementation
- [ccminer-verus](https://github.com/monkins1010/ccminer) - Reference CPU implementation
- [Daniel Lemire](https://github.com/lemire/clhash) - CLHash algorithm

---

<p align="center">
  <a href="https://github.com/bokiko/bloxminer">GitHub</a> •
  <a href="https://verus.io">Verus.io</a>
</p>

<p align="center">
  Made by <a href="https://github.com/bokiko">@bokiko</a>
</p>
