#!/usr/bin/env bash
# Build the BloxMiner config.json from the flight sheet. jq builds all JSON, so every value is escaped.
#   CUSTOM_URL         pool: stratum+tcp://host:port or host:port (first line is used)
#   CUSTOM_TEMPLATE    wallet.worker (%WAL%.%WORKER_NAME%)
#   CUSTOM_PASS        1-128 = thread count (pool password "x"); any other text = pool password; empty = all CPUs
#   CUSTOM_USER_CONFIG optional JSON members, e.g. "threads": 12  or  "pass": "1234" (a numeric pool password)
#                      "dashboard": true = sticky stats header in the Hive miner screen (off by default: HiveOS
#                      "Miner log" shows the raw screen recording, which the header's redraws make unreadable)
. "${BLOX_DIR:-/hive/miners/custom/bloxminer}/h-manifest.conf"   # BLOX_DIR: tests only
MAX_THREADS=128
# keys BloxMiner sets itself: HiveOS stats need the local API, and only VerusHash is supported
PROTECTED='["algo","api-bind","api-allow","api-remote","log-file","background","no-dashboard"]'   # header: "dashboard"

fail() { echo "$1"; message error "$1" 2>/dev/null; exit 1; }
# a thread count is 1-3 decimal digits in 1..MAX_THREADS; leading zeros are decimal, never octal
threads_ok() { [[ $1 =~ ^[0-9]{1,3}$ ]] && (( 10#$1 >= 1 && 10#$1 <= MAX_THREADS )); }

url=$(head -n1 <<< "$CUSTOM_URL" | tr -d '[:space:]')
[[ -n $url ]] || fail "BloxMiner: the pool URL in the flight sheet is empty"
[[ $url == stratum+* ]] || url="stratum+tcp://$url"

threads=$(nproc)                       # CPUs this process may use (respects cpusets), not every CPU in the box
(( threads > MAX_THREADS )) && threads=$MAX_THREADS
pass=${CUSTOM_PASS:-x}
if [[ $CUSTOM_PASS =~ ^[0-9]+$ ]]; then
	threads_ok "$CUSTOM_PASS" || fail "BloxMiner: Pass is a thread count and must be 1-$MAX_THREADS (got $CUSTOM_PASS). For a numeric pool password use Extra config: \"pass\": \"$CUSTOM_PASS\""
	threads=$((10#$CUSTOM_PASS)); pass=x
fi

extra='{}'
if [[ -n $CUSTOM_USER_CONFIG ]]; then
	extra=$(jq -ce 'if type == "object" then . else error end' <<< "{$CUSTOM_USER_CONFIG}" 2>/dev/null) ||
		fail "BloxMiner: Extra config must be JSON members, e.g. \"threads\": 12"
fi
if jq -e 'has("threads")' <<< "$extra" > /dev/null; then        # present: must be a valid count (false/null too)
	t=$(jq -r '.threads | if type == "number" or type == "string" then tostring else "(\(type))" end' <<< "$extra")
	threads_ok "$t" || fail "BloxMiner: Extra config \"threads\" must be 1-$MAX_THREADS (got $t)"
	threads=$((10#$t))
fi
dash=false                                                     # "dashboard": JSON true/false only
if jq -e 'has("dashboard")' <<< "$extra" > /dev/null; then
	d=$(jq -r '.dashboard | if type == "boolean" then tostring else "\(tojson)" end' <<< "$extra")
	[[ $d == true || $d == false ]] || fail "BloxMiner: Extra config \"dashboard\" must be true or false (got $d)"
	dash=$d
fi
[[ $dash == true ]] && echo "BloxMiner: dashboard on - the HiveOS \"Miner log\" view shows raw screen redraws; the clean log is $CUSTOM_LOG_BASENAME.log"
ignored=$(jq -r --argjson p "$PROTECTED" '[keys[] | select(. as $k | $p | index($k))] | join(", ")' <<< "$extra")
[[ -n $ignored ]] && echo "BloxMiner: Extra config keys ignored (set by BloxMiner): $ignored"
extra=$(jq -c --argjson p "$PROTECTED" 'with_entries(select(.key as $k | $p | index($k) | not)) | del(.threads, .dashboard)' <<< "$extra")

ccd=${CCD_TEMP_MAP:-auto}
[[ $ccd == auto || $ccd == 0 || $ccd == 1 ]] || fail "BloxMiner: CCD_TEMP_MAP in h-manifest.conf must be auto, 0 or 1 (got $ccd)"
if jq -e 'has("ccd-temp-map")' <<< "$extra" > /dev/null; then
	c=$(jq -r '."ccd-temp-map" | if type == "number" or type == "string" then tostring else "(\(type))" end' <<< "$extra")
	[[ $c == auto || $c == 0 || $c == 1 ]] || fail "BloxMiner: Extra config \"ccd-temp-map\" must be \"auto\", \"0\" or \"1\" (got $c)"
	extra=$(jq -c --arg c "$c" '."ccd-temp-map" = $c' <<< "$extra")
fi

# write next to the target, validate, then rename: a failure never leaves an empty or partial config
tmp="$CUSTOM_CONFIG_FILENAME.tmp.$$"
if jq -n --arg url "$url" --arg user "$CUSTOM_TEMPLATE" --arg pass "$pass" --argjson threads "$threads" \
	--argjson extra "$extra" --arg log "$CUSTOM_LOG_BASENAME.log" --arg ccd "$ccd" --argjson dash "$dash" \
	'{pools: [{name: "pool1", url: $url, timeout: 150}], user: $user, pass: $pass, "retry-pause": 5, "ccd-temp-map": $ccd}
	 + $extra
	 + {threads: $threads, algo: "verus", "api-bind": "127.0.0.1:4068", "api-allow": "127.0.0.1", "log-file": $log}
	 + (if $dash then {} else {"no-dashboard": true} end)' > "$tmp" &&
   jq -e '.threads >= 1' "$tmp" > /dev/null &&
   mv -f "$tmp" "$CUSTOM_CONFIG_FILENAME"; then
	:
else
	rm -f "$tmp"
	fail "BloxMiner: could not write $CUSTOM_CONFIG_FILENAME"
fi
