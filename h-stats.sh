#!/usr/bin/env bash

LOG_FILE="/var/log/miner/custom/custom.log"

khs=0
ac=0
rj=0
cpu_temp=0

if [[ -f "$LOG_FILE" ]]; then
    # Strip ANSI color codes and cursor control sequences, get last 100 lines
    CLEAN_LOG=$(tail -100 "$LOG_FILE" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')

    # Parse box format: |  Hashrate: 27.18 MH/s  Temp: 54°C     |
    HASH_LINE=$(echo "$CLEAN_LOG" | grep '|.*Hashrate:' | tail -1)
    if [[ "$HASH_LINE" =~ Hashrate:[[:space:]]*([0-9.]+)[[:space:]]*(MH|KH|GH|TH)/s ]]; then
        VALUE="${BASH_REMATCH[1]}"
        UNIT="${BASH_REMATCH[2]}"
        case "$UNIT" in
            TH) khs=$(echo "$VALUE * 1000000000" | bc 2>/dev/null || echo "0") ;;
            GH) khs=$(echo "$VALUE * 1000000" | bc 2>/dev/null || echo "0") ;;
            MH) khs=$(echo "$VALUE * 1000" | bc 2>/dev/null || echo "0") ;;
            KH) khs="$VALUE" ;;
        esac
    fi

    # Get temp from same line
    if [[ "$HASH_LINE" =~ Temp:[[:space:]]*([0-9]+) ]]; then
        cpu_temp="${BASH_REMATCH[1]}"
    fi

    # Parse box format: |  Accepted: 17          Rejected: 0       |
    SHARE_LINE=$(echo "$CLEAN_LOG" | grep '|.*Accepted:' | tail -1)
    if [[ "$SHARE_LINE" =~ Accepted:[[:space:]]*([0-9]+) ]]; then
        ac="${BASH_REMATCH[1]}"
    fi
    if [[ "$SHARE_LINE" =~ Rejected:[[:space:]]*([0-9]+) ]]; then
        rj="${BASH_REMATCH[1]}"
    fi
fi

# Fallback CPU temp from system
if [[ "$cpu_temp" == "0" ]] && [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    cpu_temp=$(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
fi

# Ensure khs is a valid number
khs=$(echo "$khs" | grep -oE '^[0-9.]+' || echo "0")
[[ -z "$khs" ]] && khs=0

cat << STATS
{"hs":[$khs],"temp":[$cpu_temp],"fan":[],"khs":$khs,"ac":$ac,"rj":$rj,"ver":"1.0","algo":"verushash"}
STATS
