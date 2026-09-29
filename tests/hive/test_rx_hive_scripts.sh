#!/usr/bin/env bash
# Tests for bloxminer/engines/rx/h-config.sh and h-stats.sh (adapted from BloxMiner-X 1.0.0's gated suite:
# harness paths + the shared top-level manifest/version only - all assertions kept).
# (Linux: needs jq, curl, timeout, python3, bash).
# Usage: tests/hive/test_hive_scripts.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer/engines/rx" && pwd)
MANIFEST_SRC=$(cd "$HERE/../../bloxminer" && pwd)/h-manifest.conf   # shared top-level manifest (3.0.0)
T=$(mktemp -d)
declare -a ALL_API_PIDS=()   # every fake-API pid THIS script ever started (kill -9 -o exactly these, never a
	# pattern-kill: 127.0.0.1:20015 is permanently held by another, lead-owned process on shared build hosts)
cleanup_apis() { local p; for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill -9 "$p" 2>/dev/null; done; wait "${ALL_API_PIDS[@]:-}" 2>/dev/null || true; }
trap 'cleanup_apis; rm -rf "$T"' EXIT INT TERM
pass=0; fail=0; API_PID=
ok()  { pass=$((pass+1)); printf '%-58s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-58s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR=$T/pkg
mkdir -p "$BLOX_DIR"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer-x#" "$MANIFEST_SRC" > "$BLOX_DIR/h-manifest.conf"
mkdir -p "$T/log"   # h-run.sh creates this in production before the miner (and h-stats.sh) ever runs
CONF=$T/config.json
: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"     # placeholder: only its path is ever compared, never run

# ================================================================== h-config.sh
hc() {  # url template pass algo extra -> runs h-config, sets $out $rc
	out=$(BLOX_SYSFS_ROOT=${BLOX_SYSFS_ROOT:-} CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_ALGO=$4 CUSTOM_USER_CONFIG=$5 \
	      bash "$BLOX_DIR/h-config.sh" 2>&1); rc=$?
}
jqc() { jq -r "$1" "$CONF"; }
check_cfg() {   # name, jq expression that must be true
	if [[ $rc == 0 ]] && [[ $(jq -r "$2" "$CONF" 2>/dev/null) == true ]]; then ok "$1"; else bad "$1" "rc=$rc out=$out cfg=$(cat "$CONF" 2>/dev/null)"; fi
}
check_out()  { if grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "out=$out"; fi; }
check_fail() { if [[ $rc != 0 ]] && grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "rc=$rc out=$out"; fi; }

unset BLOX_SYSFS_ROOT
hc "pool.example.com:9999" "W.rig" "" "" ""
check_cfg "host:port gets stratum+tcp://" '.pools[0].url == "stratum+tcp://pool.example.com:9999"'
check_cfg "template -> user, pass defaults to x" '.pools[0].user == "W.rig" and .pools[0].pass == "x"'
check_cfg "algo defaults to rx/0" '.pools[0].algo == "rx/0"'
check_cfg "fixed keys: donate 0, local restricted API, log file, cpu enabled+huge-pages" \
	'."donate-level" == 0 and ."donate-over-proxy" == 0 and .http.enabled == true and .http.host == "127.0.0.1" and
	 .http.port == 4069 and .http.restricted == true and (.http."access-token" == null) and
	 .cpu.enabled == true and .cpu."huge-pages" == true and (."log-file" | endswith("/log/bloxminer-x.log")) and
	 .autosave == false and .background == false and .opencl.enabled == false and .cuda.enabled == false'

hc $'stratum+tcp://a:1\nstratum+tcp://b:2' "W.rig" "" "" ""
check_cfg "only the first URL line" '.pools[0].url == "stratum+tcp://a:1"'
hc "stratum+ssl://pool:1234" "W.rig" "" "" ""
check_cfg "stratum+ssl:// URL passed through as-is (XMRig parses it)" '.pools[0].url == "stratum+ssl://pool:1234"'
hc "" "W.rig" "" "" "";  check_fail "empty URL rejected" "pool URL in the flight sheet is empty"
hc "p:1" "W.rig" "mypass" "" "";  check_cfg "Pass is always the pool password" '.pools[0].pass == "mypass"'
hc "p:1" "W.rig" "" "rx/wow" "";  check_cfg "CUSTOM_ALGO rx/wow accepted" '.pools[0].algo == "rx/wow"'
for a in rx/0 rx/wow rx/arq rx/graft rx/sfx rx/yada; do
	hc "p:1" "W.rig" "" "$a" ""
	check_cfg "algo allow-list: $a" ".pools[0].algo == \"$a\""
done
hc "p:1" "W.rig" "" "cn/r" "";  check_fail "algo not in the RandomX family rejected" "Algorithm must be one of"
hc "p:1" "W.rig" "" "rx" "";    check_fail "algo rx (not rx/0) rejected" "Algorithm must be one of"

# ---- protected keys are dropped with a message; cpu.enabled (nested) too
hc "p:1" "W.rig" "" "" '"donate-level": 5, "donate-over-proxy": 1, "http": {"port": 9}, "api": {}, "autosave": true, "log-file": "/tmp/x", "background": true, "syslog": true, "opencl": {"enabled": true}, "cuda": {"enabled": true}'
check_cfg "protected keys stay fixed" \
	'."donate-level" == 0 and ."donate-over-proxy" == 0 and .http.port == 4069 and .autosave == false and
	 (."log-file" | endswith("bloxminer-x.log")) and .background == false and .syslog == false and
	 .opencl.enabled == false and .cuda.enabled == false'
check_out "protected keys reported ignored" "donate-level"
hc "p:1" "W.rig" "" "" '"cpu": {"enabled": false, "max-threads-hint": 50}'
check_cfg "cpu.enabled forced true, other cpu keys pass through" '.cpu.enabled == true and .cpu."max-threads-hint" == 50'
check_out "cpu.enabled ignored message" "cpu.enabled"
hc "p:1" "W.rig" "" "" '"cpu": {"rx": [0, 1, 2, 3]}'
check_cfg "cpu.rx passes through" '.cpu.rx == [0, 1, 2, 3]'
hc "p:1" "W.rig" "" "" '"pools": [{"url": "stratum+tcp://evil:1", "user": "x", "pass": "x", "algo": "rx/0"}]'
check_cfg "Extra config cannot replace pools[]" '(.pools | length) == 1 and .pools[0].url == "stratum+tcp://p:1"'

# ---- tls
hc "p:1" "W.rig" "" "" '"tls": true';   check_cfg "tls true -> pools[0].tls" '.pools[0].tls == true'
hc "p:1" "W.rig" "" "" '"tls": false';  check_cfg "tls false -> pools[0].tls false" '.pools[0].tls == false'
hc "p:1" "W.rig" "" "" '"tls": "yes"';  check_fail "tls non-boolean rejected" "\"tls\" must be true or false"
hc "p:1" "W.rig" "" "" '';              check_cfg "no tls key -> no pools[0].tls" '(.pools[0] | has("tls")) | not'

# ---- 1gb-pages: opt-in only, gated on >= 3 GiB free per NUMA node
T_SYS="$T/sysfs"
setnode() { mkdir -p "$T_SYS/sys/devices/system/node/node$1"; printf 'Node %s MemFree:      %s kB\n' "$1" "$2" > "$T_SYS/sys/devices/system/node/node$1/meminfo"; }
rm -rf "$T_SYS"; setnode 0 $((4 * 1024 * 1024)); setnode 1 $((5 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": true'
check_cfg "1gb-pages: both nodes >= 3 GiB -> enabled" '.randomx."1gb-pages" == true'
rm -rf "$T_SYS"; setnode 0 $((4 * 1024 * 1024)); setnode 1 $((1 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": true'
check_cfg "1gb-pages: one node short -> dropped" '(.randomx | has("1gb-pages")) | not'
check_out "1gb-pages: dropped message names the node" "1gb-pages\" ignored"
rm -rf "$T_SYS"
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": true'
check_cfg "1gb-pages: no NUMA info -> dropped" '(.randomx | has("1gb-pages")) | not'
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": false'
check_cfg "1gb-pages: false -> not set (no NUMA check needed)" '(.randomx | has("1gb-pages")) | not'
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": "true"'
check_fail "1gb-pages: non-boolean rejected" "\"1gb-pages\" must be true or false"
hc "p:1" "W.rig" "" "" '"randomx": {"rdmsr": false}, "1gb-pages": true'
check_cfg "randomx object merges alongside 1gb-pages handling" '.randomx.rdmsr == false'

# ---- nested "randomx": {"1gb-pages": ...} must go through the SAME NUMA gate as the top-level key (no bypass)
rm -rf "$T_SYS"; setnode 0 $((4 * 1024 * 1024)); setnode 1 $((5 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"randomx": {"1gb-pages": true, "rdmsr": false}'
check_cfg "nested 1gb-pages: enough memory -> enabled, sibling randomx keys kept" '.randomx."1gb-pages" == true and .randomx.rdmsr == false'
rm -rf "$T_SYS"; setnode 0 $((1 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"randomx": {"1gb-pages": true}'
check_cfg "nested 1gb-pages: short on memory -> dropped, cannot bypass the gate" '(.randomx | has("1gb-pages")) | not'
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"randomx": {"1gb-pages": "true"}'
check_fail "nested 1gb-pages: non-boolean rejected" "\"1gb-pages\" must be true or false"

# ---- cpu.huge-pages is forced the same way cpu.enabled is - Extra config cannot turn it off
hc "p:1" "W.rig" "" "" '"cpu": {"huge-pages": false, "max-threads-hint": 8}'
check_cfg "cpu.huge-pages forced true even when Extra sets it false" '.cpu."huge-pages" == true and .cpu."max-threads-hint" == 8'
check_out "cpu.huge-pages ignored message" "cpu.huge-pages"

# ---- print-time (and other non-protected defaults) are overridable by Extra config
hc "p:1" "W.rig" "" "" '"print-time": 30'
check_cfg "Extra config print-time survives" '."print-time" == 30'
hc "p:1" "W.rig" "" "" ''
check_cfg "print-time default is 60" '."print-time" == 60'

# ---- malformed Extra config leaves the old config intact, no temp file left behind
echo '{"old":true}' > "$CONF"
hc "p:1" "W.rig" "" "" 'not json at all'
if [[ $rc != 0 && $(cat "$CONF") == '{"old":true}' ]]; then ok "bad Extra config leaves old config intact"; else bad "bad Extra config leaves old config intact" "rc=$rc $(cat "$CONF")"; fi
if ls "$T"/config.json.tmp.* > /dev/null 2>&1; then bad "no temp file left behind" "$(ls "$T")"; else ok "no temp file left behind"; fi

# ---- injection: quotes and command substitutions in every free-text field must stay literal JSON, never run
MARK="$T/pwned"
evil_user="W.rig\"; touch ${MARK}1; \""
evil_pass="x\$(touch ${MARK}2)x"
evil_extra="\"note\": \"\$(touch ${MARK}3)\`touch ${MARK}4\`\""
hc "p:1" "$evil_user" "$evil_pass" "" "$evil_extra"
expect_note="\$(touch ${MARK}3)\`touch ${MARK}4\`"
if [[ ! -e ${MARK}1 && ! -e ${MARK}2 && ! -e ${MARK}3 && ! -e ${MARK}4 ]] &&
   [[ $(jqc .pools[0].user) == "$evil_user" && $(jqc .pools[0].pass) == "$evil_pass" && $(jqc .note) == "$expect_note" ]]
then
	ok "quotes/command substitutions stay literal JSON, nothing executes"
else
	bad "quotes/command substitutions stay literal JSON, nothing executes" "rc=$rc out=$out cfg=$(cat "$CONF")"
fi
evil_url='stratum+tcp://p:1; touch '"$MARK"'5'
hc "$evil_url" "W.rig" "" "" ""
expect_url=$(tr -d '[:space:]' <<< "$evil_url")   # h-config.sh strips whitespace from the URL by design
if [[ ! -e ${MARK}5 ]] && [[ $(jqc .pools[0].url) == "$expect_url" ]]; then ok "URL with shell metacharacters stays literal"; else bad "URL with shell metacharacters stays literal" "out=$out cfg=$(cat "$CONF")"; fi

# ================================================================== h-stats.sh
jq -n '{pools: [{algo: "rx/0"}]}' > "$CONF"   # h-stats.sh reads algo from the config, independent of the h-config tests above
PROC=$T/proc
export BLOX_PROCFS_ROOT=$PROC
: > "$BLOX_DIR/bloxsense"; chmod +x "$BLOX_DIR/bloxsense"
FAKE_PID=4242

reset_proc() { rm -rf "$PROC"; mkdir -p "$PROC/net"; : > "$PROC/net/tcp"; }
listen() {   # port inode exe-target
	local hex; hex=$(printf '%04X' "$1")
	{
		echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
		printf '   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %s 1 0000000000000000 100 0 0 10 0\n' "$hex" "$2"
	} > "$PROC/net/tcp"
	mkdir -p "$PROC/$FAKE_PID/fd"
	ln -sf "socket:[$2]" "$PROC/$FAKE_PID/fd/23"
	ln -sf "$3" "$PROC/$FAKE_PID/exe"
}
task() { mkdir -p "$PROC/$FAKE_PID/task/$1"; printf 'Cpus_allowed_list:\t%s\n' "$2" > "$PROC/$FAKE_PID/task/$1/status"; }
bloxsense_says() { printf '%s\n' "$1" > "$BLOX_DIR/bloxsense.json"; cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/sh
cat "$BLOX_DIR/bloxsense.json"
EOF
	chmod +x "$BLOX_DIR/bloxsense"
}

fake_topo_json() {   # $1 = number of physical cores (two threads per core, SMT: cpu i and cpu i+ncores share core i)
                      # $2 = power_w (default 95.0), may be fractional
	local n=$1 p=${2:-95.0}
	python3 - "$n" "$p" <<'PY'
import json, sys
n, p = int(sys.argv[1]), float(sys.argv[2])
cpus = []
for c in range(2 * n):
	core = c % n
	cpus.append({"cpu": c, "pkg": 0, "core": core, "temp": 55 + core, "src": "core"})
print(json.dumps({"cpus": cpus, "pkg_temp": 70, "power_w": p, "ccd_reason": "test fixture"}))
PY
}

stats_case() {   # name port summary-json backends-json-or-empty jq-assertion
	kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
	local port=$2
	if [[ -n $3 ]]; then
		jq -n --argjson s "$3" --argjson b "${4:-[]}" '{summary: $s, backends: $b}' > "$T/replies.json"
		: > "$T/api.out"
		python3 "$HERE/fake_xmrig_api.py" "$port" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
		for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
		grep -q ready "$T/api.out" || { bad "$1" "fake API did not start: $(cat "$T/api.out")"; return; }
		# "ready" only confirms bind()+listen() succeeded, not that the server's accept loop is actually
		# spun up yet - a curl that lands in that gap gets "Empty reply from server" (observed, reproducible,
		# purely a fake-server startup race, nothing to do with h-stats.sh). Confirm a REAL round-trip before
		# handing control to h-stats.sh, so every stats_case exercises the fixture, not this race.
		for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:$port/2/summary" && break; sleep 0.05; done
	fi
	export BLOX_API_PORT=$port
	local res t0 t1
	t0=$(date +%s.%N)
	res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	if [[ $(jq -r "$5" <<< "$res" 2>/dev/null) == true ]]; then ok "$1 (${elapsed}s)"; else bad "$1" "elapsed=${elapsed}s $res"; fi
}

BACK_16C32T=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [ (100 + c) * 10.0, None, None]} for c in range(32)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
SUM_OK=$(jq -nc '{uptime: 321, connection: {accepted: 15, rejected: 1}, algo: "rx/0", version: "6.26.0", donate_level: 0}')

reset_proc; listen 20001 1001 "$BLOX_DIR/xmrig"
for c in $(seq 0 31); do task "t$c" "$c"; done
task "tmgmt" "0-31"   # a management thread keeping the full mask must not confuse the multiset check
bloxsense_says "$(fake_topo_json 16)"
stats_case "per-core grouping, 16C/32T, bound and verified" 20001 "$SUM_OK" "$BACK_16C32T" \
	'(.stats.hs | length) == 16 and .stats.uptime == 321 and .stats.ar == [15, 1] and .stats.cpu_power == 95 and
	 .stats.ver == "3.0.0 (xmrig 6.26.0)" and .stats.algo == "rx/0" and
	 (.stats.hs[0] == (((100 + 0) * 10 + (100 + 16) * 10) / 1000)) and (.stats.temp[0] == 55)'

BACK_NULLS=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [None, None, None]} for c in range(4)]
threads[2]["hashrate"][0] = 5000.0
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20002 1002 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "null thread rates -> row marked null (never fabricated 0), Phase A's total stands" 20002 "$SUM_OK" "$BACK_NULLS" \
	'.stats.hs == [null, null, 5, null] and .khs == "0.00"'

SUM_POS=$(jq -nc '{uptime: 321, connection: {accepted: 15, rejected: 1}, algo: "rx/0", version: "6.26.0",
                   donate_level: 0, hashrate: {total: [6000, null, null]}}')   # a real, positive fresh rate
reset_proc; listen 20027 1027 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "positive summary + null detail rows -> Phase A's positive total kept, not a null-as-0 partial sum" \
	20027 "$SUM_POS" "$BACK_NULLS" '.khs == "6.00" and .stats.hs == [null, null, 5, null]'

reset_proc; listen 20028 1028 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "positive summary + all-missing detail (backends empty) -> Phase A's positive total kept" \
	20028 "$SUM_POS" "$(jq -nc '[]')" '.khs == "6.00" and .stats.hs == [6]'

BACK_ZERO=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [0.0, 0.0, 0.0]} for c in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20003 1003 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "all-zero hashrate -> real rows, all 0 (not the single fallback row)" 20003 "$SUM_OK" "$BACK_ZERO" \
	'(.stats.hs | length) == 4 and (.stats.hs | add) == 0 and .khs == "0.00"'

reset_proc   # nothing listening at all
stats_case "API down -> khs 0, hs [0]" 20004 "" "" '.khs == "0" and .stats.hs == [0]'

reset_proc; listen 20005 1005 "/usr/bin/xmrig"   # a foreign miner owns this port; API itself is healthy
bloxsense_says "$(fake_topo_json 4)"
stats_case "foreign listener on our port -> unavailable, never its stats" 20005 "$SUM_OK" "$BACK_NULLS" \
	'.khs == "0" and .stats.hs == [0]'

BACK_UNBOUND=$(python3 - <<'PY'
import json
threads = [{"affinity": -1, "hashrate": [3000.0, None, None]} for _ in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20006 1006 "$BLOX_DIR/xmrig"
bloxsense_says "$(fake_topo_json 4)"
stats_case "affinity == -1 -> per-thread rows, package temp" 20006 "$SUM_OK" "$BACK_UNBOUND" \
	'(.stats.hs | length) == 4 and (.stats.temp | unique) == [70]'

reset_proc; listen 20007 1007 "$BLOX_DIR/xmrig"
task "t0" "0"; task "t1" "1"; task "t2" "2"   # thread for cpu 3 never shows a single-CPU mask: verification fails
bloxsense_says "$(fake_topo_json 4)"
stats_case "affinity not independently confirmed -> per-thread rows, package temp" 20007 "$SUM_OK" "$BACK_NULLS" \
	'(.stats.hs | length) == 4 and (.stats.temp | unique) == [70]'

reset_proc; listen 20008 1008 "$BLOX_DIR/xmrig"
task "t0" "0"; task "t1" "1"; task "t2" "1"; task "t3" "3"   # cpu 1 pinned twice, cpu 2 never -> multiset mismatch
bloxsense_says "$(fake_topo_json 4)"
stats_case "duplicate task pinning -> multiset mismatch -> per-thread rows" 20008 "$SUM_OK" "$BACK_NULLS" \
	'(.stats.temp | unique) == [70]'

reset_proc; listen 20009 1009 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "numeric JSON types throughout (nulls allowed only for rows a fresh rate is genuinely missing for)" 20009 "$SUM_OK" "$BACK_NULLS" \
	'(.stats.ar | map(type) | unique) == ["number"] and (.stats.uptime | type) == "number" and
	 (.stats.hs | map(type) | unique | sort) == ["null", "number"] and (.khs | type) == "string" and (.khs | tonumber | type) == "number"'

reset_proc; listen 20011 1011 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4 95.5)"
stats_case "fractional power_w (95.5) is not dropped" 20011 "$SUM_OK" "$BACK_NULLS" '.stats.cpu_power == 95.5'

BACK_BAD_TYPES=$(python3 - <<'PY'
import json
threads = [{"affinity": str(c), "hashrate": [1000.0, None, None]} for c in range(4)]   # affinity is a STRING
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20012 1012 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "malformed JSON types (affinity as string) -> Phase A total stands, no per-core rows" 20012 "$SUM_OK" "$BACK_BAD_TYPES" \
	'.khs == "0.00" and .stats.hs == [0.00]'

BACK_NO_HASHRATE_ARRAY=$(jq -nc '[{"type": "cpu", "threads": [{"affinity": 0, "hashrate": "not-an-array"}]}]')
reset_proc; listen 20013 1013 "$BLOX_DIR/xmrig"; task "t0" "0"
bloxsense_says "$(fake_topo_json 4)"
stats_case "malformed JSON types (hashrate not an array) -> Phase A total stands, no per-core rows" 20013 "$SUM_OK" "$BACK_NO_HASHRATE_ARRAY" \
	'.khs == "0.00" and .stats.hs == [0.00]'

BACK_NEGATIVE=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [1000.0, None, None]} for c in range(4)]
threads[1]["hashrate"][0] = -500.0   # one bad rate must clamp to 0, never go negative, and must not poison the others
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20014 1014 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "negative rate clamps to 0 for that row, others unaffected" 20014 "$SUM_OK" "$BACK_NEGATIVE" \
	'.stats.hs == [1, 0, 1, 1] and .khs == "3.00"'

BACK_NO_THREADS_KEY=$(jq -nc '[{"type": "cpu", "algo": null}]')   # legitimate: before the first pool job, no "threads" key at all
reset_proc; listen 20025 1025 "$BLOX_DIR/xmrig"   # NOT 20015: a long-lived, unrelated fake_xmrig_api.py from
	# another session on this shared build host squats on 127.0.0.1:20015 permanently - colliding with it here
	# made our own instance's bind() fail, silently masking this case as a false pass (h-stats.sh's real Phase
	# A never even ran; observed live via `ss -ltnp` + the fake server's own crash traceback).
bloxsense_says "$(fake_topo_json 4)"
stats_case "cpu backend with no threads key yet (pre-first-job) -> Phase A total stands" 20025 "$SUM_OK" "$BACK_NO_THREADS_KEY" \
	'.khs == "0.00" and .stats.hs == [0.00]'

# ---- budget: ONE shared 3.0 s deadline - a slow step gets whatever is left, never more, and the whole run
#      (ownership check + both curls + bloxsense) stays comfortably under 3.2 s wall time even in bad cases.
run_hstats_timed() {   # -> sets $res $elapsed (wall time, seconds)
	local a b
	a=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs/$stats are meant to expand inside the inner bash -c, not here
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	b=$(date +%s.%N)
	elapsed=$(awk -v x="$a" -v y="$b" 'BEGIN{printf "%.2f", y - x}')
}
under_budget() { awk -v e="$1" 'BEGIN{exit !(e < 3.2)}'; }

# slow bloxsense (sleeps 5 s), fast/normal API: bloxsense is killed at whatever remains of the shared budget
# (not a fixed 1.8 s), so the total still stays under 3.2 s
reset_proc; listen 20010 1010 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
cat > "$BLOX_DIR/bloxsense" <<'EOF'
#!/bin/sh
sleep 5
echo '{"cpus":[],"pkg_temp":null,"power_w":null,"ccd_reason":"slow"}'
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20010 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20010
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '(.stats.temp | unique) == [null]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: slow bloxsense capped by the remaining shared budget (${elapsed}s)"
else
	bad "budget: slow bloxsense capped by the remaining shared budget" "elapsed=${elapsed}s $res"
fi

# a hanging/very slow API (10 s reply delay): each curl is still capped at its own 0.5 s ceiling (not the
# whole remaining budget), so this falls back quickly and cleanly (khs 0, hs [0]), well under 3.2 s
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" --argjson d 10 '{summary: $s, backends: $b, delay: $d}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20016 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
reset_proc; listen 20016 1016 "$BLOX_DIR/xmrig"
export BLOX_API_PORT=20016
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: hanging API falls back under 3.2 s (${elapsed}s)"
else
	bad "budget: hanging API falls back under 3.2 s" "elapsed=${elapsed}s $res"
fi

# a LARGE /proc (thousands of fd entries, none matching, plus thousands of stale task entries) together with a
# hanging API: the /proc ownership scan and the task-mask scan are not individually timed steps - they only
# stay bounded because the ENTIRE collection runs inside one child process under `timeout`. This proves a
# pathologically large process table can never make h-stats.sh itself overrun the shared deadline.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc
python3 - "$PROC" <<'PY'
import os, sys
root = sys.argv[1]
fddir = os.path.join(root, "1017", "fd")
os.makedirs(fddir, exist_ok=True)
for i in range(6000):   # none of these match the inode below: forces a full, futile scan of all 6000 entries
	os.symlink("socket:[%d]" % (900000 + i), os.path.join(fddir, str(i)))
taskdir = os.path.join(root, "1017", "task")
for i in range(6000):
	d = os.path.join(taskdir, str(i))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t%d\n" % (i % 4))
PY
hex1017=$(printf '%04X' 20017)
{
	echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
	printf '   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1099 1 0000000000000000 100 0 0 10 0\n' "$hex1017"
} > "$PROC/net/tcp"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" --argjson d 10 '{summary: $s, backends: $b, delay: $d}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20017 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20017
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: huge /proc (6000 fd + 6000 tasks) + hanging API still bounded, falls back (${elapsed}s)"
else
	bad "budget: huge /proc (6000 fd + 6000 tasks) + hanging API still bounded, falls back" "elapsed=${elapsed}s $res"
fi

# a LARGE task list (6000 stale entries) with otherwise-healthy ownership and API: exercises the task-mask
# scan specifically (rather than the ownership fd-scan above) - still bounded, and always produces a
# well-formed result (either genuine per-thread rows, if the scan finishes in time, or the defined fallback).
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20018 1018 "$BLOX_DIR/xmrig"
python3 - "$PROC" <<'PY'
import os, sys
root = sys.argv[1]
taskdir = os.path.join(root, "1018", "task")
for i in range(6000):   # none of these are single-CPU masks matching our 4 real thread affinities
	d = os.path.join(taskdir, str(i))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t0-31\n")
PY
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20018 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20018
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '(.stats.hs | type) == "array"' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: huge task list (6000 entries) stays bounded, well-formed result (${elapsed}s)"
else
	bad "budget: huge task list (6000 entries) stays bounded, well-formed result" "elapsed=${elapsed}s $res"
fi
bloxsense_says "$(fake_topo_json 4)"   # restore a fast bloxsense for anything after this point

# ---- a bloxsense that TRAPS/IGNORES SIGTERM and sleeps indefinitely must still die (via the outer timeout's
#      SIGKILL grace period reaching the SAME process group, per --foreground), never survive this script, and
#      never block the parent on a pipe it still holds open (checked via a temp file, not a pipe, already)
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20019 1019 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
MARKER1="bloxminerx_test_survivor_bloxsense_$$"
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER1 sleep 30
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20019 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20019
run_hstats_timed
sleep 0.5   # let init reap anything that died, before checking for survivors
survivors1=$(pgrep -f "$MARKER1" || true)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && [[ $(jq -r '.khs == "0.00" and .stats.hs == [0.00]' <<< "$res" 2>/dev/null) == true ]] && [[ -z $survivors1 ]]; then
	ok "SIGTERM-ignoring bloxsense: killed, no survivors, < 3.0 s (${elapsed}s)"
else
	bad "SIGTERM-ignoring bloxsense: killed, no survivors, < 3.0 s" "elapsed=${elapsed}s survivors=[$survivors1] $res"
fi
pkill -9 -f "$MARKER1" 2>/dev/null   # safety net: never leak a process into the box even if this test fails
bloxsense_says "$(fake_topo_json 4)"

# ---- a `curl` that TRAPS/IGNORES SIGTERM and sleeps indefinitely (simulating a stuck/adversarial API call,
#      invoked directly with no nested timeout of its own) must also be reachable by the same outer kill
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20020 1020 "$BLOX_DIR/xmrig"
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
MARKER2="bloxminerx_test_survivor_curl_$$"
cat > "$FAKEBIN/curl" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER2 sleep 30
EOF
chmod +x "$FAKEBIN/curl"
OLDPATH=$PATH
export PATH="$FAKEBIN:$PATH"
export BLOX_API_PORT=20020
run_hstats_timed
export PATH=$OLDPATH
sleep 0.5
survivors2=$(pgrep -f "$MARKER2" || true)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]] && [[ -z $survivors2 ]]; then
	ok "SIGTERM-ignoring curl: killed, no survivors, < 3.0 s (${elapsed}s)"
else
	bad "SIGTERM-ignoring curl: killed, no survivors, < 3.0 s" "elapsed=${elapsed}s survivors=[$survivors2] $res"
fi
pkill -9 -f "$MARKER2" 2>/dev/null

# ---- process-group isolation: the parent must never read/trust the child's pgid before the child itself has
#      confirmed (via a handshake, written only AFTER its own setsid takes effect) that it is truly isolated -
#      otherwise a premature read could see the CALLER's own (inherited) pgid, and a later group-kill could
#      hit the caller itself. Simulated via a test-only env hook that delays the child's handshake write; a
#      "caller" runs in its own session with a marker sibling process that must never be touched no matter what,
#      while a hanging bloxsense still gets cleaned up once the (delayed but eventually valid) handshake arrives.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
CALLER_MARKER="bloxminerx_test_caller_$$"
MARKER3="bloxminerx_test_survivor_bloxsense2_$$"
reset_proc; listen 20026 1026 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER3 sleep 30
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20026 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done

cat > "$T/wrapper.sh" <<WRAP
#!/bin/bash
exec -a $CALLER_MARKER sleep 60 > /dev/null 2>&1 &
export BLOX_DIR="$BLOX_DIR"
export BLOX_API_PORT=20026
export BLOX_HSTATS_TEST_HANDSHAKE_DELAY=0.2
t0=\$(date +%s.%N)
. "$BLOX_DIR/h-stats.sh"
t1=\$(date +%s.%N)
jq -nc --arg k "\$khs" --arg s "\$stats" --arg e "\$(awk -v a="\$t0" -v b="\$t1" 'BEGIN{print b-a}')" \
	'{khs: \$k, stats: (\$s | fromjson), elapsed: (\$e | tonumber)}'
WRAP
chmod +x "$T/wrapper.sh"
res=$(setsid bash "$T/wrapper.sh" 2>&1)
sleep 0.5
caller_alive=$(pgrep -f "$CALLER_MARKER" || true)
bloxsense_survivors=$(pgrep -f "$MARKER3" || true)
elapsed=$(jq -r '.elapsed' <<< "$res" 2>/dev/null); [[ -n $elapsed && $elapsed != null ]] || elapsed=99
if [[ -n $caller_alive ]] && [[ -z $bloxsense_survivors ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' \
	&& [[ $(jq -r '.khs == "0.00" and .stats.hs == [0.00]' <<< "$res" 2>/dev/null) == true ]]
then
	ok "process-group isolation: caller's group survives, bloxsense reaped, < 3.0 s (${elapsed}s)"
else
	bad "process-group isolation: caller's group survives, bloxsense reaped, < 3.0 s" \
		"caller_alive=[$caller_alive] bloxsense_survivors=[$bloxsense_survivors] elapsed=$elapsed res=$res"
fi
pkill -9 -f "$CALLER_MARKER" 2>/dev/null
pkill -9 -f "$MARKER3" 2>/dev/null
bloxsense_says "$(fake_topo_json 4)"

# ================================================================== diagnostics: one log line per state change
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PKG2="$T/pkg2"; mkdir -p "$PKG2" "$T/log2"
cp "$BLOX_DIR/h-config.sh" "$BLOX_DIR/h-stats.sh" "$PKG2/"
ln -sf "$BLOX_DIR/xmrig" "$PKG2/xmrig"
ln -sf "$BLOX_DIR/bloxsense" "$PKG2/bloxsense"   # bloxsense_says() below keeps controlling both via this symlink
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config2.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log2/bloxminer-x#" "$BLOX_DIR/h-manifest.conf" > "$PKG2/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config2.json"
STATE2="$T/state2"; LOG2="$T/log2/bloxminer-x.stats.log"; MAINLOG2="$T/log2/bloxminer-x.log"
run_pkg2() { mkdir -p "$STATE2" "$T/log2"; BLOX_DIR=$PKG2 BLOX_STATE_DIR=$STATE2 BLOX_API_PORT=$1 BLOX_PROCFS_ROOT=$PROC \
	bash -c '. "$BLOX_DIR/h-stats.sh"' > /dev/null 2>&1; }
loglines() { grep -c "$1" "$LOG2" 2>/dev/null || true; }

rm -rf "$STATE2" "$T/log2"; reset_proc   # nothing listening: unavailable
run_pkg2 20020
if [[ $(loglines "stats API unavailable") == 1 ]]; then ok "state log: first unavailable is logged once"; else bad "state log: first unavailable is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi
run_pkg2 20020   # still down: no duplicate line
if [[ $(loglines "stats API unavailable") == 1 ]]; then ok "state log: repeated unavailable is not re-logged"; else bad "state log: repeated unavailable is not re-logged" "$(cat "$LOG2" 2>/dev/null)"; fi

reset_proc; listen 20021 1021 "$PKG2/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20021 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20021   # recovered: verified per-core rows again
if [[ $(loglines "recovered") == 1 && $(loglines "stats API unavailable") == 1 ]]; then ok "state log: recovery from unavailable is logged once"; else bad "state log: recovery from unavailable is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20022 1022 "$PKG2/xmrig"   # no tasks set up: affinity present but never independently confirmed
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20022 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20022
if [[ $(loglines "affinity not verified") == 1 ]]; then ok "state log: unverified transition is logged once"; else bad "state log: unverified transition is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi
run_pkg2 20022   # still unverified: no duplicate
if [[ $(loglines "affinity not verified") == 1 ]]; then ok "state log: repeated unverified is not re-logged"; else bad "state log: repeated unverified is not re-logged" "$(cat "$LOG2" 2>/dev/null)"; fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20023 1023 "$PKG2/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20023 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20023   # recovered again, from unverified this time
if [[ $(loglines "recovered") == 2 ]]; then ok "state log: recovery from unverified is logged once"; else bad "state log: recovery from unverified is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi

if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} bloxminer-x: ' "$LOG2" 2>/dev/null; then
	ok "state log: each line is timestamped"
else
	bad "state log: each line is timestamped" "$(cat "$LOG2" 2>/dev/null)"
fi

# ---- XMRig's own log file is written at XMRig's own tracked offset with no O_APPEND (FileLogWriter), so
#      anything else appended there is silently overwritten by XMRig's next write - confirmed on a live rig
#      (state transitions really happened, per the state file, but no diagnostic line ever survived in
#      XMRig's log). Simulate a concurrent XMRig-like writer that keeps rewriting the main log at a fixed
#      offset while a transition happens, and confirm the diagnostic still survives - in its own file.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
rm -rf "$STATE2" "$T/log2"; mkdir -p "$T/log2"
printf 'XMRIG STARTUP BANNER\n' > "$MAINLOG2"
(
	i=0
	while [[ $i -lt 20 ]]; do
		printf 'XMRIG LOG LINE %03d (fixed-offset rewrite, no append)\n' "$i" > "$MAINLOG2" 2>/dev/null
		i=$((i + 1))
		sleep 0.05
	done
) &
XMRIG_WRITER_PID=$!
reset_proc   # nothing listening: unavailable
run_pkg2 20030
kill "$XMRIG_WRITER_PID" 2>/dev/null; wait "$XMRIG_WRITER_PID" 2>/dev/null
if grep -q "bloxminer-x: stats API unavailable" "$LOG2" 2>/dev/null; then
	ok "diagnostics survive a concurrent fixed-offset rewriter of the main log"
else
	bad "diagnostics survive a concurrent fixed-offset rewriter of the main log" \
		"statslog=$(cat "$LOG2" 2>/dev/null) mainlog=$(cat "$MAINLOG2" 2>/dev/null)"
fi
if ! grep -q "bloxminer-x:" "$MAINLOG2" 2>/dev/null; then
	ok "the main (XMRig) log never receives a bloxminer-x diagnostic line"
else
	bad "the main (XMRig) log never receives a bloxminer-x diagnostic line" "$(cat "$MAINLOG2" 2>/dev/null)"
fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc   # a transition-worthy run (unavailable), captured without discarding stdout this time
stdout_out=$(BLOX_DIR=$PKG2 BLOX_STATE_DIR=$STATE2 BLOX_API_PORT=20024 BLOX_PROCFS_ROOT=$PROC bash -c '. "$BLOX_DIR/h-stats.sh"' 2>/dev/null)
if [[ -z $stdout_out ]]; then ok "state log: nothing is ever printed to stdout"; else bad "state log: nothing is ever printed to stdout" "stdout=$stdout_out"; fi

# ---- no leaked fake-API child survives this script: every pid this script itself started (ALL_API_PIDS) must
# be dead by the time the suite ends. A plain kill -0 here (with no SIGTERM+wait of its own first) would flag
# the CURRENT stage's still-legitimately-running api as a false "leak" just because nothing has stopped it
# YET - so this sends SIGTERM to everything tracked, waits for each (a no-op for anything already reaped), and
# only THEN checks for survivors: a real leak is one that outlives its own SIGTERM, not one merely still alive
# at this exact line.
for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done
for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && wait "$p" 2>/dev/null; done
leaked=()
for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && leaked+=("$p"); done
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	cleanup_apis
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
