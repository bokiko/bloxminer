#!/usr/bin/env bash
# BloxMiner HiveOS Custom Miner Installation Script

set -e

MINER_NAME="bloxminer"
INSTALL_DIR="/hive/miners/custom/$MINER_NAME"

echo "=========================================="
echo "Installing BloxMiner for HiveOS..."
echo "=========================================="

# Install build dependencies
apt-get update -qq
apt-get install -y -qq build-essential cmake libssl-dev git

# Clean previous installation
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Clone and build
cd /tmp
rm -rf bloxminer
git clone https://github.com/bokiko/bloxminer.git
cd bloxminer
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Install binary
cp bloxminer "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bloxminer"

# Create h-manifest.conf
cat > "$INSTALL_DIR/h-manifest.conf" << 'EOF'
CUSTOM_NAME=bloxminer
CUSTOM_LOG_BASENAME=/var/log/miner/custom/custom
CUSTOM_CONFIG_FILENAME=/hive/miners/custom/bloxminer/config.txt
EOF

# Create h-config.sh - parses Flight Sheet config
cat > "$INSTALL_DIR/h-config.sh" << 'EOFCONFIG'
#!/usr/bin/env bash

# Source configs
[[ -f /hive-config/wallet.conf ]] && source /hive-config/wallet.conf
[[ -f /hive-config/rig.conf ]] && source /hive-config/rig.conf

# Parse pool URL (remove stratum+tcp:// prefix if present)
POOL="${CUSTOM_URL:-pool.verus.io:9999}"
POOL="${POOL#stratum+tcp://}"
POOL="${POOL#stratum://}"

# Parse wallet.worker from CUSTOM_TEMPLATE
if [[ -n "$CUSTOM_TEMPLATE" ]]; then
    WALLET="${CUSTOM_TEMPLATE%%.*}"
    WORKER="${CUSTOM_TEMPLATE#*.}"
    [[ "$WORKER" == "$WALLET" ]] && WORKER=""
fi

# Fallbacks
[[ -z "$WALLET" ]] && echo "ERROR: Wallet address required in CUSTOM_TEMPLATE" && exit 1
[[ -z "$WORKER" ]] && WORKER="${WORKER_NAME:-miner}"

# Threads from CUSTOM_PASS (default: all cores)
THREADS="${CUSTOM_PASS:-$(nproc)}"

# Write config
echo "-o $POOL -u $WALLET -w $WORKER -t $THREADS" > /hive/miners/custom/bloxminer/config.txt
EOFCONFIG
chmod +x "$INSTALL_DIR/h-config.sh"

# Create h-run.sh - runs the miner
cat > "$INSTALL_DIR/h-run.sh" << 'EOF'
#!/usr/bin/env bash
cd /hive/miners/custom/bloxminer

# Generate config from flight sheet
./h-config.sh

# Read config
CONFIG=$(cat config.txt 2>/dev/null)

# Run miner
exec ./bloxminer $CONFIG
EOF
chmod +x "$INSTALL_DIR/h-run.sh"

# Create h-stats.sh - provides stats to HiveOS
cat > "$INSTALL_DIR/h-stats.sh" << 'EOF'
#!/usr/bin/env bash

# Read from miner log
LOG_FILE="/var/log/miner/custom/custom.log"

# Initialize stats
khs=0
ac=0
rj=0

# Parse log for hashrate
if [[ -f "$LOG_FILE" ]]; then
    # Get total hashrate - look for "[HASH] X.XX MH/s"
    HASHRATE=$(tail -200 "$LOG_FILE" | grep -oP '\[HASH\]\s*[\d.]+\s*[MKG]?H/s' | tail -1)
    if [[ -n "$HASHRATE" ]]; then
        if [[ "$HASHRATE" =~ ([0-9.]+).*MH ]]; then
            khs=$(echo "${BASH_REMATCH[1]} * 1000" | bc 2>/dev/null || echo "0")
        elif [[ "$HASHRATE" =~ ([0-9.]+).*KH ]]; then
            khs="${BASH_REMATCH[1]}"
        elif [[ "$HASHRATE" =~ ([0-9.]+).*GH ]]; then
            khs=$(echo "${BASH_REMATCH[1]} * 1000000" | bc 2>/dev/null || echo "0")
        fi
    fi

    # Count accepted/rejected shares
    ac=$(tail -500 "$LOG_FILE" | grep -c "Share accepted" 2>/dev/null || echo "0")
    rj=$(tail -500 "$LOG_FILE" | grep -c "Share rejected\|rejected" 2>/dev/null || echo "0")
fi

# Get CPU temp
cpu_temp=0
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    cpu_temp=$(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
fi

# Output JSON stats
cat << STATS
{"hs":[],"temp":[$cpu_temp],"fan":[],"khs":$khs,"ac":$ac,"rj":$rj,"ver":"1.0","algo":"verushash"}
STATS
EOF
chmod +x "$INSTALL_DIR/h-stats.sh"

# Cleanup
rm -rf /tmp/bloxminer

echo ""
echo "=========================================="
echo "BloxMiner installed successfully!"
echo "=========================================="
echo ""
echo "Location: $INSTALL_DIR"
echo ""
echo "Flight Sheet Setup:"
echo "  - Miner: custom"
echo "  - Installation URL: (leave empty after install)"
echo "  - Miner name: bloxminer"
echo "  - Pool URL: pool.verus.io:9999"
echo "  - Wallet: YOUR_VRSC_ADDRESS.WORKER_NAME"
echo "  - Pass: number of threads (e.g., 16)"
echo ""
