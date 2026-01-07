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
# Note: Cannot use exec with pipe, so just run with tee
./bloxminer $CONFIG 2>&1 | tee /var/log/miner/custom/custom.log
EOF
chmod +x "$INSTALL_DIR/h-run.sh"

# Create h-stats.sh - provides stats to HiveOS (sourced by agent)
cat > "$INSTALL_DIR/h-stats.sh" << 'EOF'
#!/usr/bin/env bash
# HiveOS stats script - sets $khs and $stats variables (sourced by agent)

LOG_FILE="/var/log/miner/custom/custom.log"
CONFIG_FILE="/hive/miners/custom/bloxminer/config.txt"

# Get thread count from config
THREADS=$(grep -oP '\-t\s*\K\d+' "$CONFIG_FILE" 2>/dev/null || nproc)

khs=0
local_ac=0
local_rj=0
cpu_temp=0
hs_array=""

if [[ -f "$LOG_FILE" ]]; then
    # Strip ANSI codes more aggressively (including UTF-8 box chars and cursor sequences)
    CLEAN_LOG=$(tail -200 "$LOG_FILE" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')

    # Parse hashrate: "Hashrate: 27.18 MH/s"
    if [[ "$CLEAN_LOG" =~ Hashrate:[[:space:]]*([0-9.]+)[[:space:]]*(MH|KH|GH|TH)/s ]]; then
        VALUE="${BASH_REMATCH[1]}"
        UNIT="${BASH_REMATCH[2]}"
        case "$UNIT" in
            TH) khs=$(echo "$VALUE * 1000000000" | bc 2>/dev/null || echo "0") ;;
            GH) khs=$(echo "$VALUE * 1000000" | bc 2>/dev/null || echo "0") ;;
            MH) khs=$(echo "$VALUE * 1000" | bc 2>/dev/null || echo "0") ;;
            KH) khs="$VALUE" ;;
        esac
    fi

    # Get temp: "Temp: 54C" or "Temp: 54°C"
    if [[ "$CLEAN_LOG" =~ Temp:[[:space:]]*([0-9]+) ]]; then
        cpu_temp="${BASH_REMATCH[1]}"
    fi

    # Get shares from header display (checkmark format)
    # Format: "Shares: ✓ 76" or after ANSI strip just numbers
    if [[ "$CLEAN_LOG" =~ Shares:[^0-9]*([0-9]+) ]]; then
        local_ac="${BASH_REMATCH[1]}"
    fi

    # Count rejected from log messages
    local_rj=$(echo "$CLEAN_LOG" | grep -c "Share rejected\|rejected:" 2>/dev/null || echo "0")

    # Parse per-thread hashrates from "Threads:" line
    # Format after ANSI strip: "Threads: [00]740.5K [01]740.1K ..."
    THREAD_LINE=$(echo "$CLEAN_LOG" | grep "Threads:" | tail -1)
    if [[ -n "$THREAD_LINE" ]]; then
        hs_values=()
        for i in $(seq 0 $((THREADS-1))); do
            # Zero-pad the index to match [00], [01], etc.
            idx=$(printf "%02d" $i)
            # Extract value after [NN] - handles K, M, G suffixes
            hr=$(echo "$THREAD_LINE" | grep -oP "\[$idx\][^0-9]*\K[0-9.]+" | head -1)
            suffix=$(echo "$THREAD_LINE" | grep -oP "\[$idx\][^0-9]*[0-9.]+\K[KMG]" | head -1)

            if [[ -n "$hr" ]]; then
                case "$suffix" in
                    M) val=$(echo "$hr * 1000" | bc 2>/dev/null || echo "0") ;;
                    G) val=$(echo "$hr * 1000000" | bc 2>/dev/null || echo "0") ;;
                    K|*) val="$hr" ;;
                esac
            else
                val="0"
            fi
            hs_values+=("$val")
        done
        hs_array=$(IFS=,; echo "${hs_values[*]}")
    fi
fi

# Fallback: distribute total across threads if per-thread not found
if [[ -z "$hs_array" || "$hs_array" == "0" ]] && [[ "$khs" != "0" ]]; then
    per_thread=$(echo "scale=2; $khs / $THREADS" | bc 2>/dev/null || echo "0")
    hs_values=()
    for i in $(seq 1 $THREADS); do
        hs_values+=("$per_thread")
    done
    hs_array=$(IFS=,; echo "${hs_values[*]}")
fi

# Fallback CPU temp from system
if [[ "$cpu_temp" == "0" ]]; then
    # Try hwmon (k10temp, coretemp)
    for hwmon in /sys/class/hwmon/hwmon*; do
        name=$(cat "$hwmon/name" 2>/dev/null)
        if [[ "$name" == "k10temp" || "$name" == "coretemp" ]]; then
            temp=$(cat "$hwmon/temp1_input" 2>/dev/null || echo 0)
            cpu_temp=$((temp / 1000))
            break
        fi
    done
    # Fallback to thermal zone
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
