# BloxMiner

**High-Performance VerusHash v2.2 CPU Miner**

BloxMiner is a CPU miner for [Verus Coin (VRSC)](https://verus.io) implementing the VerusHash v2.2 algorithm. It's designed for maximum performance on modern x86-64 CPUs with AES-NI, AVX2, and PCLMULQDQ support.

## Features

- **VerusHash v2.2** - Current Verus mainnet algorithm
- **Multi-threaded** - Automatic thread detection, configurable thread count
- **Stratum v1** - Compatible with standard mining pools
- **Optimized** - AES-NI, AVX2, PCLMULQDQ hardware acceleration
- **Lightweight** - Minimal dependencies, fast startup
- **Pool Verified** - Tested and working with pool.verus.io

## Requirements

### Hardware
- x86-64 CPU with:
  - AES-NI (Advanced Encryption Standard New Instructions)
  - AVX2 (Advanced Vector Extensions 2)
  - PCLMULQDQ (Carry-less Multiplication)
- Most Intel (Haswell+) and AMD (Zen+) processors support these

### Software
- Linux (Ubuntu 20.04+ recommended)
- GCC 9+ or Clang 10+
- CMake 3.16+
- OpenSSL development libraries

## Building

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt update
sudo apt install build-essential cmake libssl-dev

# Clone repository
git clone https://github.com/bokiko/bloxminer.git
cd bloxminer

# Build
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

## Usage

```bash
./bloxminer -o <pool:port> -u <wallet_address> [options]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-o, --pool` | Pool address (host:port) | Required |
| `-u, --user` | Wallet address | Required |
| `-w, --worker` | Worker name | hostname |
| `-p, --pass` | Pool password | x |
| `-t, --threads` | Number of mining threads | Auto-detect |

### Examples

```bash
# Mine to Verus.io pool with 4 threads
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress -w miner1 -t 4

# Mine to LuckPool with 8 threads
./bloxminer -o na.luckpool.net:3956 -u RYourWalletAddress -w rig1 -t 8

# Mine with all available threads
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress
```

## Performance

Approximate hashrates (per thread):

| CPU | H/s per thread |
|-----|----------------|
| AMD Ryzen 9 5950X | ~1.8 MH/s |
| AMD Ryzen 7 5800X | ~1.7 MH/s |
| Intel Core i9-12900K | ~1.5 MH/s |
| AMD Ryzen AI 9 HX 370 | ~1.6 MH/s |

*Performance varies based on CPU model, cooling, and system configuration.*

## Project Structure

```
bloxminer/
├── src/
│   ├── main.cpp              # Entry point
│   ├── miner.cpp             # Mining engine
│   ├── crypto/
│   │   ├── haraka.c/h        # Haraka256/512 (AES-NI optimized)
│   │   ├── verus_clhash.h    # VerusCLHash header
│   │   ├── verus_clhash_v2.c # VerusCLHash v2.2 (PCLMULQDQ)
│   │   └── verus_hash.cpp/h  # VerusHash v2.2 wrapper
│   ├── stratum/
│   │   └── stratum_client.cpp/hpp  # Pool communication
│   └── utils/
│       ├── hex_utils.cpp/hpp # Hex encoding utilities
│       └── logger.cpp/hpp    # Logging system
├── include/                  # Header files
├── tests/                    # Test programs
│   ├── test_clhash_compare.cpp  # CLHash verification test
│   ├── test_verushash.cpp       # VerusHash test vectors
│   └── test_target.cpp          # Target/difficulty tests
├── CMakeLists.txt
├── CONTINUATION.md           # Development notes
└── README.md
```

## Algorithm

VerusHash v2.2 combines:

1. **Haraka512** - Short-input hash using AES-NI round instructions
2. **VerusCLHash** - ASIC-resistant mixing using carry-less multiplication (PCLMULQDQ)
3. **Dynamic key generation** - Per-hash key mutation via Haraka256 chain

This design is optimized for CPUs and resistant to GPU/ASIC mining. The algorithm processes a 1487-byte block header + solution through multiple stages:

```
Block Data (1487 bytes)
    ↓
Haraka512 Chain (hash_half)
    ↓
Intermediate State (64 bytes)
    ↓
Key Generation (8832 bytes via Haraka256)
    ↓
CLHash v2.2 (32 iterations with AES mixing)
    ↓
Final Haraka512 (keyed)
    ↓
Hash Result (32 bytes)
```

## Testing

```bash
# Build and run tests
cd build

# Run CLHash comparison test (validates against reference implementation)
../tests/test_clhash_compare

# Run VerusHash test
./test_verushash  # if built with tests enabled
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [VerusCoin Team](https://verus.io) - Original VerusHash implementation
- [ccminer-verus](https://github.com/monkins1010/ccminer) - Reference CPU implementation
- [Daniel Lemire](https://github.com/lemire/clhash) - CLHash algorithm
- [kste](https://github.com/kste/haraka) - Haraka hash function

## Changelog

### v1.0.0 (January 7, 2026)
- Initial working release
- VerusHash v2.2 implementation verified against pool
- Fixed CLHash variable shadowing bug (cases 0x10, 0x14, 0x18)
- All shares accepted by pool.verus.io

### v0.1.0-beta (January 6, 2026)
- Initial beta release
- Basic stratum support
- Haraka/CLHash primitives implemented

---

Made with determination by [@bokiko](https://github.com/bokiko)
