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
cat > "$INSTALL_DIR/h-config.sh" << 'EOF'
#!/usr/bin/env bash

# Get pool and wallet from Flight Sheet
[[ -z $CUSTOM_URL ]] && CUSTOM_URL="pool.verus.io:9999"
[[ -z $CUSTOM_TEMPLATE ]] && echo "ERROR: Wallet address required" && exit 1

POOL="$CUSTOM_URL"
WALLET="$CUSTOM_TEMPLATE"
WORKER="${CUSTOM_USER_CONFIG:-$WORKER_NAME}"
THREADS="${CUSTOM_PASS:-$(nproc)}"

# Build config file
echo "-o $POOL -u $WALLET -w $WORKER -t $THREADS" > /hive/miners/custom/bloxminer/config.txt
EOF
chmod +x "$INSTALL_DIR/h-config.sh"

# Create h-run.sh - runs the miner
cat > "$INSTALL_DIR/h-run.sh" << 'EOF'
#!/usr/bin/env bash
cd /hive/miners/custom/bloxminer

# Read config
CONFIG=$(cat config.txt 2>/dev/null)

# Run miner
./bloxminer $CONFIG
EOF
chmod +x "$INSTALL_DIR/h-run.sh"

# Create h-stats.sh - provides stats to HiveOS
cat > "$INSTALL_DIR/h-stats.sh" << 'EOF'
#!/usr/bin/env bash

# Read from miner log
LOG_FILE="/var/log/miner/custom/custom.log"

# Initialize stats
hs=()        # hashrates per thread
temp=()      # temperatures
fan=()       # fan speeds
khs=0        # total hashrate in kH/s
ac=0         # accepted shares
rj=0         # rejected shares

# Parse log for hashrate (look for "Hash rate:" or similar)
if [[ -f "$LOG_FILE" ]]; then
    # Get total hashrate - look for patterns like "6.7 MH/s" or "Hash rate: X"
    HASHRATE=$(tail -100 "$LOG_FILE" | grep -oP '[\d.]+\s*[MKG]?H/s' | tail -1)
    if [[ -n "$HASHRATE" ]]; then
        # Convert to kH/s
        if [[ "$HASHRATE" =~ ([0-9.]+).*MH ]]; then
            khs=$(echo "${BASH_REMATCH[1]} * 1000" | bc 2>/dev/null || echo "0")
        elif [[ "$HASHRATE" =~ ([0-9.]+).*KH ]]; then
            khs="${BASH_REMATCH[1]}"
        elif [[ "$HASHRATE" =~ ([0-9.]+).*GH ]]; then
            khs=$(echo "${BASH_REMATCH[1]} * 1000000" | bc 2>/dev/null || echo "0")
        elif [[ "$HASHRATE" =~ ([0-9.]+).*H ]]; then
            khs=$(echo "${BASH_REMATCH[1]} / 1000" | bc 2>/dev/null || echo "0")
        fi
    fi
    
    # Get accepted shares
    ac=$(tail -100 "$LOG_FILE" | grep -c "accepted\|Accepted" 2>/dev/null || echo "0")
    
    # Get rejected shares
    rj=$(tail -100 "$LOG_FILE" | grep -c "rejected\|Rejected" 2>/dev/null || echo "0")
fi

# Get CPU temp if available
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    cpu_temp=$((cpu_temp / 1000))
    temp+=($cpu_temp)
fi

# Build JSON stats
stats=$(jq -n \
    --argjson hs "$(printf '%s\n' "${hs[@]}" | jq -s '.')" \
    --argjson temp "$(printf '%s\n' "${temp[@]}" | jq -s '.')" \
    --argjson fan "$(printf '%s\n' "${fan[@]}" | jq -s '.')" \
    --arg khs "$khs" \
    --arg ac "$ac" \
    --arg rj "$rj" \
    --arg ver "1.0" \
    '{hs: $hs, temp: $temp, fan: $fan, khs: ($khs|tonumber), $ac, $rj, ver: $ver, algo: "verushash"}' 2>/dev/null)

# If jq fails, return minimal stats
if [[ -z "$stats" ]]; then
    stats="{\"khs\":$khs,\"ac\":$ac,\"rj\":$rj,\"ver\":\"1.0\",\"algo\":\"verushash\"}"
fi

echo "$stats"
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
echo "  - Installation URL: (leave empty, already installed)"
echo "  - Miner name: bloxminer"
echo "  - Pool URL: pool.verus.io:9999"
echo "  - Wallet: YOUR_VRSC_ADDRESS"
echo "  - Worker: %WORKER_NAME% (or custom name)"
echo "  - Pass: number of threads (e.g., 4)"
echo ""
