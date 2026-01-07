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
    # Get last STATS line from log
    # Format: [STATS] hr=24.15 unit=MH temp=56 ac=100 rj=0 thr=756.0K,759.8K,...
    STATS_LINE=$(tail -200 "$LOG_FILE" | grep '\[STATS\]' | tail -1)

    if [[ -n "$STATS_LINE" ]]; then
        # Parse hashrate value and unit
        HR_VALUE=$(echo "$STATS_LINE" | grep -oP 'hr=\K[0-9.]+')
        HR_UNIT=$(echo "$STATS_LINE" | grep -oP 'unit=\K[A-Z]+')

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
