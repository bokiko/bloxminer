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
rm -rf "/hive/miners/custom/BloxMiner"  # Remove old capitalized version
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

# Ensure log directory exists
mkdir -p /var/log/miner/custom

# Run miner with logging (required for h-stats.sh to parse output)
# Use stdbuf to force line buffering so tee writes output immediately
stdbuf -oL ./bloxminer $CONFIG 2>&1 | tee /var/log/miner/custom/custom.log
EOF
chmod +x "$INSTALL_DIR/h-run.sh"

# Create h-stats.sh - provides stats to HiveOS (sourced by agent)
cat > "$INSTALL_DIR/h-stats.sh" << 'EOF'
#!/usr/bin/env bash
# HiveOS stats script - sets $khs and $stats variables (sourced by agent)

CONFIG_FILE="/hive/miners/custom/bloxminer/config.txt"

# Get thread count from config
THREADS=$(grep -oP '\-t\s*\K\d+' "$CONFIG_FILE" 2>/dev/null || nproc)

khs=0
local_ac=0
local_rj=0
cpu_temp=0
hs_array=""

# Read stats from file written by miner (reliable, no screen buffer issues)
STATS_FILE="/tmp/bloxminer_stats.txt"
STATS_LINE=""
if [[ -f "$STATS_FILE" ]]; then
    STATS_LINE=$(cat "$STATS_FILE" 2>/dev/null)
fi

if [[ -n "$STATS_LINE" ]]; then
    # Parse hashrate value and unit (use word boundary to avoid matching 'thr=')
    HR_VALUE=$(echo "$STATS_LINE" | grep -oP '\bhr=\K[0-9.]+')
    HR_UNIT=$(echo "$STATS_LINE" | grep -oP '\bunit=\K[A-Z]+')

    # Convert to KH/s
    if [[ -n "$HR_VALUE" ]]; then
        case "$HR_UNIT" in
            TH) khs=$(echo "$HR_VALUE * 1000000000" | bc 2>/dev/null || echo "0") ;;
            GH) khs=$(echo "$HR_VALUE * 1000000" | bc 2>/dev/null || echo "0") ;;
            MH) khs=$(echo "$HR_VALUE * 1000" | bc 2>/dev/null || echo "0") ;;
            KH) khs="$HR_VALUE" ;;
            H)  khs=$(echo "scale=2; $HR_VALUE / 1000" | bc 2>/dev/null || echo "0") ;;
        esac
    fi

    # Parse temp
    cpu_temp=$(echo "$STATS_LINE" | grep -oP 'temp=\K[0-9]+')
    [[ -z "$cpu_temp" ]] && cpu_temp=0

    # Parse accepted/rejected
    local_ac=$(echo "$STATS_LINE" | grep -oP 'ac=\K[0-9]+')
    [[ -z "$local_ac" ]] && local_ac=0

    local_rj=$(echo "$STATS_LINE" | grep -oP 'rj=\K[0-9]+')
    [[ -z "$local_rj" ]] && local_rj=0

    # Parse per-thread hashrates
    # Format: thr=756.0K,759.8K,757.9K,...
    THR_STRING=$(echo "$STATS_LINE" | grep -oP 'thr=\K[^\s]+')
    if [[ -n "$THR_STRING" ]]; then
        hs_values=()
        IFS=',' read -ra THR_ARRAY <<< "$THR_STRING"
        for thr in "${THR_ARRAY[@]}"; do
            # Parse value and suffix (K, M, G or none)
            hr=$(echo "$thr" | grep -oP '^[0-9.]+')
            suffix=$(echo "$thr" | grep -oP '[KMG]$')
            if [[ -n "$hr" ]]; then
                case "$suffix" in
                    M) val=$(echo "$hr * 1000" | bc 2>/dev/null || echo "0") ;;
                    G) val=$(echo "$hr * 1000000" | bc 2>/dev/null || echo "0") ;;
                    K|*) val="$hr" ;;
                esac
                hs_values+=("$val")
            fi
        done
        hs_array=$(IFS=,; echo "${hs_values[*]}")
    fi
fi

# Fallback: distribute total across threads if per-thread not found
if [[ -z "$hs_array" ]] && [[ "$khs" != "0" && "$khs" != "" ]]; then
    per_thread=$(echo "scale=2; $khs / $THREADS" | bc 2>/dev/null || echo "0")
    hs_values=()
    for i in $(seq 1 $THREADS); do
        hs_values+=("$per_thread")
    done
    hs_array=$(IFS=,; echo "${hs_values[*]}")
fi

# Fallback CPU temp from system
if [[ "$cpu_temp" == "0" || -z "$cpu_temp" ]]; then
    for hwmon in /sys/class/hwmon/hwmon*; do
        name=$(cat "$hwmon/name" 2>/dev/null)
        if [[ "$name" == "k10temp" || "$name" == "coretemp" ]]; then
            temp=$(cat "$hwmon/temp1_input" 2>/dev/null || echo 0)
            cpu_temp=$((temp / 1000))
            break
        fi
    done
    if [[ "$cpu_temp" == "0" && -f /sys/class/thermal/thermal_zone0/temp ]]; then
        cpu_temp=$(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
    fi
fi

# Build temp array (one per thread for HiveOS display)
temp_array=""
if [[ "$cpu_temp" != "0" && "$THREADS" -gt 0 ]]; then
    temps=()
    for i in $(seq 1 $THREADS); do
        temps+=("$cpu_temp")
    done
    temp_array=$(IFS=,; echo "${temps[*]}")
else
    temp_array="$cpu_temp"
fi

# Ensure khs is a valid number
khs=$(echo "$khs" | grep -oE '^[0-9.]+' || echo "0")
[[ -z "$khs" ]] && khs=0

# Set stats variable for HiveOS agent (sourced, not printed)
stats=$(cat <<STATSEOF
{"hs":[$hs_array],"temp":[$temp_array],"fan":[],"khs":$khs,"ac":$local_ac,"rj":$local_rj,"ver":"1.0","algo":"verushash"}
STATSEOF
)

# Also print for direct execution testing
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && echo "$stats"
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
echo "  - Miner name: bloxminer"
echo "  - Pool URL: pool.verus.io:9999"
echo "  - Wallet: YOUR_VRSC_ADDRESS.WORKER_NAME"
echo "  - Pass: number of threads (e.g., 16)"
echo ""
