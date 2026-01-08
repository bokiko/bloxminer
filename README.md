<div align="center">

# BloxMiner

**High-Performance VerusHash v2.2 CPU Miner for Verus Coin**

<p>
  <a href="https://github.com/bokiko/bloxminer"><img src="https://img.shields.io/badge/GitHub-bloxminer-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://verus.io"><img src="https://img.shields.io/badge/Verus-VRSC-3165D4?style=for-the-badge" alt="Verus"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Version-1.0.1-blue?style=flat-square" alt="Version">
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
|  BloxMiner v1.0.1 - VerusHash CPU Miner                    |
+------------------------------------------------------------+
|  Hashrate: 24.15 MH/s     Temp: 55C                        |
|  Accepted: 367            Rejected: 0                      |
|  Uptime: 3h 24m           Power: 110.6W                    |
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
<td colspan="2">

### Monitoring
- Real-time sticky stats display
- CPU temperature monitoring
- Power consumption (RAPL)
- Per-thread hashrate breakdown
- JSON API on port 4068

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

# Run
./bloxminer -o pool.verus.io:9999 -u YOUR_WALLET -w miner1 -t 4
```

---

## Usage

```bash
./bloxminer -o <pool:port> -u <wallet_address> [options]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-o, --pool` | Pool address (host:port) | Required |
| `-u, --user` | Wallet address | Required |
| `-w, --worker` | Worker name | hostname |
| `-p, --pass` | Pool password | x |
| `-t, --threads` | Mining threads | Auto-detect |
| `--api-port` | API port | 4068 |

### Examples

```bash
# Verus.io pool with 4 threads
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress -w miner1 -t 4

# LuckPool with 8 threads
./bloxminer -o na.luckpool.net:3956 -u RYourWalletAddress -w rig1 -t 8

# All available threads
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress
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
  "version": "1.0.1",
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
