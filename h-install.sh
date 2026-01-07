#!/usr/bin/env bash
# BloxMiner HiveOS Custom Miner Installation Script

set -e

MINER_NAME="BloxMiner"
INSTALL_DIR="/hive/miners/custom/$MINER_NAME"

echo "=========================================="
echo "Installing BloxMiner for HiveOS..."
echo "=========================================="

# Install build dependencies
apt-get update -qq
apt-get install -y -qq build-essential cmake libssl-dev git

# Clean previous installation
rm -rf "$INSTALL_DIR"
rm -rf "/hive/miners/custom/bloxminer"  # Remove old lowercase version
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
CUSTOM_NAME=BloxMiner
CUSTOM_LOG_BASENAME=/var/log/miner/custom/custom
CUSTOM_CONFIG_FILENAME=/hive/miners/custom/BloxMiner/config.txt
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
echo "-o $POOL -u $WALLET -w $WORKER -t $THREADS" > /hive/miners/custom/BloxMiner/config.txt
EOFCONFIG
chmod +x "$INSTALL_DIR/h-config.sh"

# Create h-run.sh - runs the miner
cat > "$INSTALL_DIR/h-run.sh" << 'EOF'
#!/usr/bin/env bash
cd /hive/miners/custom/BloxMiner

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

LOG_FILE="/var/log/miner/custom/custom.log"

khs=0
ac=0
rj=0
cpu_temp=0

if [[ -f "$LOG_FILE" ]]; then
    # Strip ANSI color codes and get last 100 lines
    CLEAN_LOG=$(tail -100 "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g')

    # Get hashrate from [HASH] line
    HASH_LINE=$(echo "$CLEAN_LOG" | grep '\[HASH\]' | tail -1)
    if [[ "$HASH_LINE" =~ ([0-9.]+)[[:space:]]*(MH|KH|GH)/s ]]; then
        VALUE="${BASH_REMATCH[1]}"
        UNIT="${BASH_REMATCH[2]}"
        case "$UNIT" in
            MH) khs=$(echo "$VALUE * 1000" | bc 2>/dev/null || echo "0") ;;
            KH) khs="$VALUE" ;;
            GH) khs=$(echo "$VALUE * 1000000" | bc 2>/dev/null || echo "0") ;;
        esac
    fi

    # Get accepted/rejected from [SHARE] line
    SHARE_LINE=$(echo "$CLEAN_LOG" | grep '\[SHARE\]' | tail -1)
    if [[ "$SHARE_LINE" =~ Accepted:[[:space:]]*([0-9]+) ]]; then
        ac="${BASH_REMATCH[1]}"
    fi
    if [[ "$SHARE_LINE" =~ Rejected:[[:space:]]*([0-9]+) ]]; then
        rj="${BASH_REMATCH[1]}"
    fi

    # Get temp from [HASH] line
    if [[ "$HASH_LINE" =~ Temp:[[:space:]]*([0-9]+) ]]; then
        cpu_temp="${BASH_REMATCH[1]}"
    fi
fi

# Fallback CPU temp from system
if [[ "$cpu_temp" == "0" ]] && [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    cpu_temp=$(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
fi

cat << STATS
{"hs":[$khs],"temp":[$cpu_temp],"fan":[],"khs":$khs,"ac":$ac,"rj":$rj,"ver":"1.0","algo":"verushash"}
STATS
EOF
chmod +x "$INSTALL_DIR/h-stats.sh"

# Set directory permissions so HiveOS can write config
chmod 777 "$INSTALL_DIR"
touch "$INSTALL_DIR/config.txt"
chmod 666 "$INSTALL_DIR/config.txt"

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
echo "  - Miner name: BloxMiner"
echo "  - Pool URL: pool.verus.io:9999"
echo "  - Wallet: YOUR_VRSC_ADDRESS.WORKER_NAME"
echo "  - Pass: number of threads (e.g., 16)"
echo ""
