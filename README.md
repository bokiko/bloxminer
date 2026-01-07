<div align="center">

# BloxMiner

**High-Performance VerusHash v2.2 CPU Miner for Verus Coin**

<p>
  <a href="https://github.com/bokiko/bloxminer"><img src="https://img.shields.io/badge/GitHub-bloxminer-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://verus.io"><img src="https://img.shields.io/badge/Verus-VRSC-3165D4?style=for-the-badge" alt="Verus"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Language-C++-00599C?style=flat-square&logo=cplusplus" alt="C++">
  <img src="https://img.shields.io/badge/Algorithm-VerusHash_v2.2-blue?style=flat-square" alt="VerusHash">
  <img src="https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

</div>

---

## HiveOS Installation

### Installation URL (for Flight Sheet)
```
https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh
```

### Manual Terminal Install
```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh | bash
```

After installation, the miner is located at `/hive/miners/bloxminer/bloxminer`

### Run Manually
```bash
/hive/miners/bloxminer/bloxminer -o pool.verus.io:9999 -u YOUR_WALLET -w worker1 -t $(nproc)
```

---

## Overview

BloxMiner is a CPU miner for [Verus Coin (VRSC)](https://verus.io) implementing the VerusHash v2.2 algorithm. Designed for maximum performance on modern x86-64 CPUs with AES-NI, AVX2, and PCLMULQDQ hardware acceleration.

---

## Stats

| Metric | Value |
|--------|-------|
| **Share Acceptance** | 100% verified |
| **Pool Tested** | pool.verus.io |
| **Algorithm** | VerusHash v2.2 |
| **Platforms** | Ubuntu, Debian, HiveOS |

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
- HiveOS ready

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
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
make -C build -j$(nproc)

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

## Performance

| CPU | H/s per Thread |
|-----|----------------|
| AMD Ryzen 9 5950X | ~1.8 MH/s |
| AMD Ryzen 7 5800X | ~1.7 MH/s |
| AMD Ryzen AI 9 HX 370 | ~1.6 MH/s |
| Intel Core i9-12900K | ~1.5 MH/s |

*Performance varies based on CPU model, cooling, and system configuration.*

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
| **Language** | C++ |
| **Build** | CMake |
| **Crypto** | OpenSSL, AES-NI intrinsics |
| **Protocol** | Stratum v1 |

---

## Project Structure

```
bloxminer/
├── src/
│   ├── main.cpp              # Entry point
│   ├── miner.cpp             # Mining engine
│   ├── crypto/               # Haraka, CLHash, VerusHash
│   ├── stratum/              # Pool communication
│   └── utils/                # Hex, logging utilities
├── include/                  # Header files
├── tests/                    # Test programs
├── CMakeLists.txt
└── README.md
```

---

## Algorithm

VerusHash v2.2 combines multiple cryptographic primitives for ASIC resistance:

```
Block Data (1487 bytes)
    |
Haraka512 Chain (AES-NI)
    |
Key Generation (8832 bytes via Haraka256)
    |
CLHash v2.2 (32 iterations + AES mixing)
    |
Final Haraka512 (keyed)
    |
Hash Result (32 bytes)
```

---

## Roadmap

- [x] VerusHash v2.2 implementation
- [x] Stratum v1 support
- [x] Pool verification (100% acceptance)
- [ ] ARM64 support
- [ ] Solo mining mode
- [ ] Benchmark mode

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
  Made by <a href="https://x.com/bokiko">@bokiko</a>
</p>
