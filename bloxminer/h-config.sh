#!/usr/bin/env bash
# Build the ccminer config.json from the flight sheet (JSON built with jq, so values are escaped).
#   CUSTOM_URL         pool (stratum+tcp://host:port or host:port)
#   CUSTOM_TEMPLATE    wallet.worker (%WAL%.%WORKER_NAME%)
#   CUSTOM_PASS        a plain number = thread count (pool password "x"); anything else = pool password; empty = all threads
#   CUSTOM_USER_CONFIG optional JSON object members, e.g. "threads": 12
. /hive/miners/custom/bloxminer/h-manifest.conf
MAX_THREADS=128                      # ccminer's per-thread arrays hold 140 entries
url=$(head -n1 <<< "$CUSTOM_URL"); [[ $url != stratum+* ]] && url="stratum+tcp://$url"
pass=${CUSTOM_PASS:-x}; threads=$(nproc --all)
if [[ $CUSTOM_PASS =~ ^[0-9]+$ ]]; then threads=$CUSTOM_PASS; pass=x; fi
extra='{}'
if [[ -n $CUSTOM_USER_CONFIG ]]; then
  extra=$(jq -ce . <<< "{$CUSTOM_USER_CONFIG}" 2>/dev/null) || { echo "Extra config arguments are not valid JSON members"; exit 1; }
fi
t=$(jq -r '.threads // empty' <<< "$extra"); [[ $t =~ ^[0-9]+$ ]] && threads=$t
(( threads < 1 )) && threads=1; (( threads > MAX_THREADS )) && threads=$MAX_THREADS
jq -n --arg url "$url" --arg user "$CUSTOM_TEMPLATE" --arg pass "$pass" --argjson threads "$threads" --argjson extra "$extra" \
  '{pools: [{name: "pool1", url: $url, timeout: 150}], user: $user, pass: $pass, algo: "verus",
    "retry-pause": 5, "api-bind": "127.0.0.1:4068", "api-allow": "127.0.0.1"} + $extra + {threads: $threads}' \
  > "$CUSTOM_CONFIG_FILENAME" || { echo "could not write $CUSTOM_CONFIG_FILENAME"; exit 1; }
