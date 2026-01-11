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

## Index

- [Installation](#installation)
  - [One-Line Install (Recommended)](#one-line-install-recommended)
  - [Manual Install](#manual-install)
  - [Updating](#updating)
  - [HiveOS](#hiveos)
- [Usage](#usage)
- [Configuration](#configuration)
- [Features](#features)
- [API](#api)
- [Requirements](#requirements)
- [Algorithm](#algorithm)
- [License](#license)

---

## Installation

### One-Line Install (Recommended)

```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/install.sh | bash
```

The installer will:
1. Install build dependencies (cmake, libssl-dev, etc.)
2. Clone and build BloxMiner to `~/bloxminer`
3. Prompt for your wallet, pool, worker name, and thread count
4. Save configuration to `~/bloxminer/bloxminer.json`
5. Create run scripts and offer to start mining

### Manual Install

```bash
# Install dependencies
sudo apt update
sudo apt install build-essential cmake libssl-dev git

# Clone and build
git clone https://github.com/bokiko/bloxminer.git ~/bloxminer
cd ~/bloxminer
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Run (interactive setup on first run if no config exists)
./bloxminer
```

### Updating

Run the installer again - it will detect existing installation and offer to update:

```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/install.sh | bash
# Choose [U] Update when prompted (default)
```

Or update manually:

```bash
cd ~/bloxminer
git pull
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

### HiveOS

#### Quick Install (Terminal)

```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh | bash
```

The installer automatically:
- Installs build dependencies
- Detects Zen 2/Zen 3 CPUs and disables AVX-512 (prevents crashes)
- Sets up RAPL power monitoring with persistent udev rules
- Builds optimized binary for your CPU

#### Flight Sheet Setup

1. **Create New Flight Sheet**
   - Coin: `VRSC` (Verus)
   - Wallet: Select your Verus wallet
   - Pool: Configure your pool (e.g., `pool.verus.io:9999`)

2. **Add Miner**
   - Miner: `Custom`
   - Installation URL:
     ```
     https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh
     ```
   - Hash algorithm: `verushash`
   - Wallet and worker template: `%WAL%.%WORKER_NAME%`
   - Pool URL: `%URL%`
   - Pass: Number of threads (e.g., `32`) or leave empty for auto

3. **Apply Flight Sheet** to your rig

#### Flight Sheet Fields

| Field | Value | Notes |
|-------|-------|-------|
| Miner | `custom` | Required |
| Installation URL | `https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh` | First install only |
| Miner name | `bloxminer` | After install |
| Hash algorithm | `verushash` | |
| Wallet template | `%WAL%.%WORKER_NAME%` | Your wallet.worker |
| Pool URL | `stratum+tcp://pool.verus.io:9999` | Your pool |
| Pass | `32` | Thread count (optional) |

#### HiveOS Features

- **Auto CPU Detection**: Zen 2/Zen 3 (Ryzen 3000/5000) automatically built without AVX-512
- **Power Monitoring**: CPU power via RAPL shown in miner stats
- **Stats Integration**: Hashrate, temperature, accepted/rejected shares reported to HiveOS dashboard
- **Per-Thread Stats**: Individual thread hashrates visible in miner output

#### Updating on HiveOS

Re-run the installer to update:

```bash
curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/h-install.sh | bash
```

Or via Miner actions in HiveOS web interface.

---

## Usage

After installation, run the miner:

```bash
# Using run script (recommended)
cd ~/bloxminer && ./run.sh

# Run in background
cd ~/bloxminer && ./run-background.sh

# View logs (background mode)
tail -f ~/bloxminer/miner.log

# Stop miner
pkill -f bloxminer
```

### Command Line Options

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
| `-t, --threads` | Mining threads (0 = auto) | Auto-detect |
| `-q, --quiet` | Quiet mode (warnings/errors only) | Off |
| `--api-port` | API port (0 to disable) | 4068 |
| `--api-bind` | API bind address | 127.0.0.1 |

### Examples

```bash
# Use saved config (recommended)
./bloxminer

# Override thread count
./bloxminer -t 8

# Full command line (no config needed)
./bloxminer -o pool.verus.io:9999 -u RYourWalletAddress -w rig1 -t 4

# Multiple failover pools
./bloxminer -o pool.verus.io:9999 -o na.luckpool.net:3956 -u RYourWalletAddress
```

### Install as System Service

```bash
sudo cp ~/bloxminer/bloxminer.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable bloxminer
sudo systemctl start bloxminer
```

---

## Configuration

BloxMiner saves settings to `bloxminer.json` so you don't need to enter them every time.

### First Run (Interactive Setup)

If no config file exists and no wallet is provided via CLI, the miner prompts for configuration:

```
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

### Edit Configuration

```bash
nano ~/bloxminer/bloxminer.json
```

---

## Features

| Category | Features |
|----------|----------|
| **Performance** | VerusHash v2.2, AES-NI acceleration, AVX2 optimizations, PCLMULQDQ |
| **Reliability** | Failover pools, exponential backoff, auto pool switching, primary retry |
| **Monitoring** | htop-style display, per-thread hashrates, CPU temp, power consumption |
| **Compatibility** | Multi-threaded auto-detect, Stratum v1, all major pools, HiveOS |

### Live Stats Display

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
    "threads": [755.2, 758.1],
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
