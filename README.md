# BloxMiner

**High-Performance VerusHash CPU Miner**

> **BETA SOFTWARE** - This miner is currently in beta testing. Use at your own risk.

BloxMiner is a CPU miner for [Verus Coin (VRSC)](https://verus.io) implementing the VerusHash v2.2 algorithm. It's designed for maximum performance on modern x86-64 CPUs with AES-NI, AVX2, and PCLMULQDQ support.

## Features

- **VerusHash v2.2** - Current Verus mainnet algorithm
- **Multi-threaded** - Automatic thread detection, configurable thread count
- **Stratum v1** - Compatible with standard mining pools
- **Optimized** - AES-NI, AVX2, PCLMULQDQ hardware acceleration
- **Lightweight** - Minimal dependencies, fast startup

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
# Mine to LuckPool with 8 threads
./bloxminer -o na.luckpool.net:3956 -u RYourWalletAddress -w rig1 -t 8

# Mine to Verus.io pool
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress -w miner1
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
│   ├── main.cpp           # Entry point
│   ├── miner.cpp          # Mining engine
│   ├── crypto/
│   │   ├── haraka.c/h     # Haraka256/512 (AES-NI)
│   │   ├── verus_clhash.c/h   # VerusCLHash (PCLMULQDQ)
│   │   └── verus_hash.cpp/h   # VerusHash v2.2
│   ├── stratum/
│   │   └── stratum_client.cpp/hpp
│   └── utils/
│       ├── hex_utils.cpp/hpp
│       └── logger.cpp/hpp
├── include/               # Header files
├── tests/                 # Test programs
├── CMakeLists.txt
└── README.md
```

## Algorithm

VerusHash v2.2 combines:
1. **Haraka512** - Short-input hash using AES-NI
2. **VerusCLHash** - ASIC-resistant mixing using PCLMULQDQ
3. **Dynamic key generation** - Per-hash key mutation

This design is optimized for CPUs and resistant to GPU/ASIC mining.

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [VerusCoin Team](https://verus.io) - Original VerusHash implementation
- [Daniel Lemire](https://github.com/lemire/clhash) - CLHash algorithm
- [kste](https://github.com/kste/haraka) - Haraka hash function

## Disclaimer

**BETA SOFTWARE**: This miner is under active development. While we strive for correctness, there may be bugs that affect mining efficiency or share acceptance. Always verify your mining results and use at your own risk.

---

Made with determination by [@bokiko](https://github.com/bokiko)
