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
    # Strip ANSI codes and non-printable chars (box drawing, etc.)
    CLEAN_LOG=$(tail -200 "$LOG_FILE" | LC_ALL=C sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -cd '[:print:]\n')

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

    # Get temp: "Temp: 54°C" or "Temp: 54C"
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

    # Parse per-thread hashrates - threads split across multiple lines
    # Search entire log for each thread pattern
    hs_values=()
    for i in $(seq 0 $((THREADS-1))); do
        idx=$(printf "%02d" $i)
        # Search entire clean log for this thread's value
        hr=$(echo "$CLEAN_LOG" | grep -oP "\[$idx\][^0-9]*\K[0-9.]+" | tail -1)
        suffix=$(echo "$CLEAN_LOG" | grep -oP "\[$idx\][^0-9]*[0-9.]+\K[KMG]" | tail -1)

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
