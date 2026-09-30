#!/usr/bin/env bash
# Build the BloxMiner-X config.json from the flight sheet. jq builds all JSON, so every value is escaped -
# nothing from the flight sheet or Extra config is ever interpolated into a shell command.
#   CUSTOM_URL         pool: stratum+tcp://host:port, stratum+ssl://host:port or host:port (first line is used)
#   CUSTOM_TEMPLATE    wallet(.worker) template, e.g. %WAL%.%WORKER_NAME% -> pools[0].user
#   CUSTOM_PASS        pool password (NOT a thread count - this differs from the Verus BloxMiner) -> pools[0].pass
#   CUSTOM_ALGO        RandomX variant: rx/0, rx/wow, rx/arq, rx/graft, rx/sfx or rx/yada; empty = rx/0
#   CUSTOM_USER_CONFIG optional JSON members, merged into defaults (print-time, colors) before the fixed/
#                      protected settings, e.g. "print-time": 30
#                      "tls": true            - force TLS on the pool connection (stratum+ssl:// already does)
#                      "1gb-pages": true      - opt-in only, top-level OR nested "randomx": {"1gb-pages": true} -
#                                               both forms go through the same >= 3 GiB-free-per-NUMA-node check
#                                               below; dropped with a message otherwise
#                      "cpu": {...}           - merged into the cpu object; "enabled" and "huge-pages" are
#                                               always forced by BloxMiner-X regardless of what Extra config sets
# Threads are XMRig's own cache-aware autoconfig; Extra config can steer them via "cpu": {"max-threads-hint": N}
# or "cpu": {"rx": [...]} (XMRig's own keys, passed through as-is).
. "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}/h-manifest.conf"   # BLOX_DIR: tests only
SYSROOT=${BLOX_SYSFS_ROOT:-}                                       # /sys path prefix; tests only

# top-level Extra config keys BloxMiner-X always sets itself (0% fee, local read-only API, our own log file);
# "cpu.enabled"/"cpu.huge-pages" are protected the same way but live one level down and are handled separately.
PROTECTED='["donate-level","donate-over-proxy","http","api","autosave","log-file","background","syslog","opencl","cuda"]'
ALGOS='["rx/0","rx/wow","rx/arq","rx/graft","rx/sfx","rx/yada"]'

fail() { echo "$1"; message error "$1" 2>/dev/null; exit 1; }

url=$(head -n1 <<< "$CUSTOM_URL" | tr -d '[:space:]')
[[ -n $url ]] || fail "BloxMiner-X: the pool URL in the flight sheet is empty"
[[ $url == stratum+* ]] || url="stratum+tcp://$url"   # XMRig parses stratum+tcp:// / stratum+ssl:// itself

algo=${CUSTOM_ALGO:-rx/0}
if ! jq -ne --argjson a "$ALGOS" --arg algo "$algo" '$a | index($algo) != null' > /dev/null; then
	fail "BloxMiner-X: Algorithm must be one of $(jq -rc . <<< "$ALGOS") (got $algo)"
fi

extra='{}'
if [[ -n $CUSTOM_USER_CONFIG ]]; then
	extra=$(jq -ce 'if type == "object" then . else error end' <<< "{$CUSTOM_USER_CONFIG}" 2>/dev/null) ||
		fail "BloxMiner-X: Extra config must be JSON members, e.g. \"print-time\": 30"
fi

# "tls": boolean only, forces TLS on the pool connection (stratum+ssl:// already sets it without this)
tls_json=null
if jq -e 'has("tls")' <<< "$extra" > /dev/null; then
	t=$(jq -r '.tls | if type == "boolean" then tostring else "(\(type))" end' <<< "$extra")
	[[ $t == true || $t == false ]] || fail "BloxMiner-X: Extra config \"tls\" must be true or false (got $t)"
	tls_json=$t
fi

# "1gb-pages": opt-in only, and only when every NUMA node reports >= 3 GiB free right now (XMRig reserves the
# pages itself at startup via sysfs; a failed reservation silently falls back to 2 MB pages). Both the
# top-level key and the nested "randomx": {"1gb-pages": ...} form are read here and go through this ONE gate;
# the nested form is then stripped out of $xrx below so it can never re-enter the config unchecked.
onegb_req=false
check_onegb_bool() {   # $1 = the "1gb-pages" value found (top-level or nested), fails on anything but a boolean
	local v; v=$(jq -r 'if type == "boolean" then tostring else "(\(type))" end' <<< "$1")
	[[ $v == true || $v == false ]] || fail "BloxMiner-X: Extra config \"1gb-pages\" must be true or false (got $v)"
	[[ $v == true ]]
}
if jq -e 'has("1gb-pages")' <<< "$extra" > /dev/null; then
	check_onegb_bool "$(jq -c '."1gb-pages"' <<< "$extra")" && onegb_req=true
fi
if jq -e '(.randomx // {}) | has("1gb-pages")' <<< "$extra" > /dev/null; then
	check_onegb_bool "$(jq -c '.randomx."1gb-pages"' <<< "$extra")" && onegb_req=true
fi
onegb=false
if [[ $onegb_req == true ]]; then
	nodes=("$SYSROOT"/sys/devices/system/node/node[0-9]*/meminfo)
	if [[ ! -e ${nodes[0]} ]]; then
		echo "BloxMiner-X: Extra config \"1gb-pages\" ignored: no NUMA memory information to verify 3 GiB/node"
	else
		short=""
		for f in "${nodes[@]}"; do
			kb=$(sed -n 's/.*MemFree:[[:space:]]*\([0-9]\+\) kB/\1/p' "$f")
			[[ $kb =~ ^[0-9]+$ ]] && (( kb >= 3 * 1024 * 1024 )) || short+="${short:+, }$(basename "$(dirname "$f")")"
		done
		if [[ -n $short ]]; then
			echo "BloxMiner-X: Extra config \"1gb-pages\" ignored: < 3 GiB free on $short"
		else
			onegb=true
		fi
	fi
fi

# cpu.enabled and cpu.huge-pages are protected (BloxMiner-X always enables the CPU backend with huge pages);
# everything else under "cpu" passes through
xcpu=$(jq -c '.cpu // {}' <<< "$extra")
cpu_ignored=$(jq -r '[if has("enabled") then "cpu.enabled" else empty end,
                      if has("huge-pages") then "cpu.huge-pages" else empty end] | join(", ")' <<< "$xcpu")
[[ -n $cpu_ignored ]] && echo "BloxMiner-X: Extra config keys ignored (set by BloxMiner-X): $cpu_ignored"
xcpu=$(jq -c 'del(.enabled, ."huge-pages")' <<< "$xcpu")

ignored=$(jq -r --argjson p "$PROTECTED" '[keys[] | select(. as $k | $p | index($k))] | join(", ")' <<< "$extra")
[[ -n $ignored ]] && echo "BloxMiner-X: Extra config keys ignored (set by BloxMiner-X): $ignored"
# $rest: permitted Extra config, applied as an override of the defaults below but never of the protected/fixed
# block that follows it (cpu/randomx/pools and the PROTECTED list are always forced, applied last)
rest=$(jq -c --argjson p "$PROTECTED" 'with_entries(select(.key as $k | $p | index($k) | not)) | del(.cpu, .tls, ."1gb-pages", .randomx)' <<< "$extra")
xrx=$(jq -c '(.randomx // {}) | del(."1gb-pages")' <<< "$extra")

# write next to the target, validate, then rename: a failure never leaves an empty or partial config
tmp="$CUSTOM_CONFIG_FILENAME.tmp.$$"
if jq -n --arg url "$url" --arg user "$CUSTOM_TEMPLATE" --arg pass "${CUSTOM_PASS:-x}" --arg algo "$algo" \
	--argjson tls "$tls_json" --argjson rest "$rest" --argjson xcpu "$xcpu" --argjson xrx "$xrx" \
	--argjson onegb "$onegb" --arg log "$CUSTOM_LOG_BASENAME.log" \
	'{colors: true, "print-time": 60}
	 + $rest
	 + {cpu: ($xcpu + {enabled: true, "huge-pages": true}),
	    randomx: ($xrx + (if $onegb then {"1gb-pages": true} else {} end)),
	    "donate-level": 0, "donate-over-proxy": 0, "autosave": false, "background": false, "syslog": false,
	    "log-file": $log,
	    http: {enabled: true, host: "127.0.0.1", port: 4069, restricted: true, "access-token": null},
	    opencl: {enabled: false}, cuda: {enabled: false},
	    pools: [{url: $url, user: $user, pass: $pass, algo: $algo}
	            + (if $tls == null then {} else {tls: $tls} end)]}' > "$tmp" &&
   jq -e --argjson a "$ALGOS" '(.pools | length > 0) and (.pools[0].url | length > 0) and
                               (.pools[0].algo as $g | $a | index($g) != null)' "$tmp" > /dev/null &&
   mv -f "$tmp" "$CUSTOM_CONFIG_FILENAME"; then
	:
else
	rm -f "$tmp"
	fail "BloxMiner-X: could not write $CUSTOM_CONFIG_FILENAME"
fi
