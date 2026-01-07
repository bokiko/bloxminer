# BloxMiner

**High-Performance VerusHash v2.2 CPU Miner**

BloxMiner is a CPU miner for [Verus Coin (VRSC)](https://verus.io) implementing VerusHash v2.2 algorithm. Optimized for modern x86-64 CPUs with AES-NI, AVX2, and PCLMULQDQ support.

---

## HiveOS - One Command Install

Copy and paste this into your HiveOS terminal (replace `YOUR_WALLET` with your VRSC address):

```bash
cd ~ && sudo apt update && sudo apt install -y build-essential cmake libssl-dev git && git clone https://github.com/bokiko/bloxminer.git && cd bloxminer && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc) && ./bloxminer -o pool.verus.io:9999 -u YOUR_WALLET -w worker1 -t $(nproc)
```

**Run in background:**
```bash
cd ~/bloxminer/build && nohup ./bloxminer -o pool.verus.io:9999 -u YOUR_WALLET -w worker1 -t $(nproc) > ~/miner.log 2>&1 &
```

**Check miner status:**
```bash
tail -f ~/miner.log
```

**Stop miner:**
```bash
pkill bloxminer
```

---

## Features

- **VerusHash v2.2** - Current Verus mainnet algorithm
- **Multi-threaded** - Uses all CPU cores by default
- **Stratum v1** - Works with all major Verus pools
- **Optimized** - AES-NI, AVX2, PCLMULQDQ hardware acceleration
- **Pool Verified** - Tested with pool.verus.io (100% share acceptance)

---

## Requirements

### Supported Systems
- **HiveOS** (recommended)
- **Ubuntu** 20.04, 22.04
- **Debian** 11+

### Hardware
- x86-64 CPU with AES-NI, AVX2, PCLMULQDQ
- Intel Haswell+ or AMD Zen+ processors

---

## Ubuntu/Debian Installation

```bash
# Install dependencies
sudo apt update && sudo apt install -y build-essential cmake libssl-dev git

# Clone and build
git clone https://github.com/bokiko/bloxminer.git
cd bloxminer && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)

# Run miner
./bloxminer -o pool.verus.io:9999 -u YOUR_WALLET -w worker1 -t 4
```

---

## Usage

```bash
./bloxminer -o <pool:port> -u <wallet> -w <worker> -t <threads>
```

| Option | Description | Default |
|--------|-------------|---------|
| `-o` | Pool address (host:port) | Required |
| `-u` | Wallet address | Required |
| `-w` | Worker name | hostname |
| `-t` | Number of threads | All cores |

### Pool Examples

```bash
# Verus.io pool
./bloxminer -o pool.verus.io:9999 -u RYourWallet -w rig1 -t 4

# LuckPool
./bloxminer -o na.luckpool.net:3956 -u RYourWallet -w rig1 -t 8
```

---

## Performance

| CPU | Per Thread | 4 Threads |
|-----|------------|-----------|
| AMD Ryzen 9 5950X | ~1.8 MH/s | ~7.2 MH/s |
| AMD Ryzen 7 5800X | ~1.7 MH/s | ~6.8 MH/s |
| Intel i9-12900K | ~1.5 MH/s | ~6.0 MH/s |

---

## Troubleshooting

**Check CPU support:**
```bash
lscpu | grep -E "aes|avx2|pclmul"
```

**View logs:**
```bash
tail -f ~/miner.log
```

**Check if running:**
```bash
ps aux | grep bloxminer
```

---

## License

MIT License - see [LICENSE](LICENSE) file.

## Acknowledgments

- [VerusCoin Team](https://verus.io)
- [ccminer-verus](https://github.com/monkins1010/ccminer)

---

Made by [@bokiko](https://github.com/bokiko)
