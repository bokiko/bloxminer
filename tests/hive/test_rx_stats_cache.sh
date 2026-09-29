#!/usr/bin/env bash
# Tests for the rx engine's last-known-good stats cache (PR #2 finding 1, strategy b): when the timed
# collector in bloxminer/engines/rx/h-stats.sh misses its own deadline (almost always CPU-load contention on a
# small cpuset - see tests/hive/test_rx_under_load.sh for that reproduction), a bounded, instance-keyed cache
# lets a poll answer with the last REAL sample instead of a hard 0, without ever masking a genuine stall or a
# dead/replaced miner. Forces the timeout deterministically via BLOX_HSTATS_TEST_HANDSHAKE_DELAY (an existing
# test-only hook already in h-stats.sh: it sleeps inside the timed child BEFORE that child's own deadline clock
# starts, so the wrapper's alarm always fires first and kills it) rather than relying on real CPU contention,
# which is what tests/hive/test_rx_under_load.sh is for.
# Usage: tests/hive/test_rx_stats_cache.sh (needs jq, python3, bash; Linux /proc layout)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer/engines/rx" && pwd)
TOPSRC=$(cd "$HERE/../../bloxminer" && pwd)
MANIFEST_SRC="$TOPSRC/h-manifest.conf"
T=$(mktemp -d)
API_PID=""
cleanup() { [[ -n $API_PID ]] && kill "$API_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

BLOX_DIR="$T/pkg"; mkdir -p "$BLOX_DIR" "$T/log" "$T/state"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer-x#" "$MANIFEST_SRC" > "$BLOX_DIR/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config.json"
: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"
cat > "$BLOX_DIR/bloxsense" <<'EOF'
#!/bin/sh
echo '{"cpus":[],"pkg_temp":55,"power_w":null,"ccd_reason":"test fixture"}'
EOF
chmod +x "$BLOX_DIR/bloxsense"   # cpus:[] forces the simple "unverified" per-thread path - no task-mask fixture needed

PROC="$T/proc"
mk_proc() {   # $1=pid $2=starttime $3=port(hex-decimal, decimal) $4=inode
	local pid=$1 start=$2 port=$3 inode=$4
	rm -rf "$PROC"; mkdir -p "$PROC/net" "$PROC/$pid/fd" "$PROC/$pid/task"
	ln -s "socket:[$inode]" "$PROC/$pid/fd/23"
	ln -s "$BLOX_DIR/xmrig" "$PROC/$pid/exe"
	# minimal valid /proc/<pid>/stat: comm has no spaces here, so field 22 (starttime) is simply the 20th
	# space-separated token after "comm)" - this fixture writes exactly enough fields for _rx_pid_start's
	# "everything after the last ') '" scan to land on the right one.
	python3 - "$PROC/$pid/stat" "$pid" "$start" <<'PY'
import sys
path, pid, start = sys.argv[1], sys.argv[2], sys.argv[3]
# fields 3..22: state,ppid,pgrp,session,tty_nr,tpgid,flags,minflt,cminflt,majflt,cmajflt,utime,stime,cutime,
# cstime,priority,nice,num_threads,itrealvalue,starttime (field 22 is the 20th token after "comm)")
fields = ["R","1","1","1","0","-1","0","0","0","0","0","0","0","0","0","20","0","1","0", start]
with open(path, "w") as f:
	f.write("%s (xmrig) %s\n" % (pid, " ".join(fields)))
PY
	hexport=$(printf '%04X' "$port")
	{
		printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
		printf '   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 100 0 0 10 0\n' "$hexport" "$inode"
	} > "$PROC/net/tcp"
}

SUM_OK=$(jq -nc '{uptime: 500, connection: {accepted: 40, rejected: 1}, algo: "rx/0", version: "6.26.0"}')
BACK_OK=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [400.0 + c, None, None]} for c in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')
BACK_STALL=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [0.0, None, None]} for c in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')

PORT=20500; INODE=777001; PID1=9201; START1=1000
mk_proc "$PID1" "$START1" "$PORT" "$INODE"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_OK" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
grep -q ready "$T/api.out" || { echo "SKIP: fake API did not start: $(cat "$T/api.out")"; exit 0; }

export BLOX_DIR BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT="$PORT" BLOX_STATE_DIR="$T/state"
CACHEFILE="$T/state/.bloxminer-rx-hstats-cache"

poll() {   # sets $khs $elapsed $res; $1 = extra env assignment (e.g. "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5") or ""
	local t0 t1
	t0=$(date +%s.%N)
	if [[ -n ${1:-} ]]; then
		# shellcheck disable=SC2016
		res=$(env "$1" timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	else
		# shellcheck disable=SC2016
		res=$(timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	fi
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
}

# ---- 1: baseline real poll -> real positive khs, and a matching cache entry (pid/start) is written
poll ""
if awk -v k="${khs:-0}" 'BEGIN{exit !(k>0)}' && [[ -f $CACHEFILE ]] && grep -q "^pid=$PID1\$" "$CACHEFILE" && grep -q "^start=$START1\$" "$CACHEFILE"; then
	ok "baseline poll: real positive khs, cache written for pid=$PID1/start=$START1 ($res)"
else
	bad "baseline poll: real positive khs, cache written" "khs=$khs cache=$(cat "$CACHEFILE" 2>/dev/null) res=$res"
fi
BASELINE_KHS=$khs

# ---- 2: forced-timeout poll, SAME instance still alive, fresh cache -> answers from the cache, not 0
poll "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5"
if [[ $khs == "$BASELINE_KHS" ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}'; then
	ok "forced timeout, same live instance: answers from cache ($khs), stayed under budget (${elapsed}s)"
else
	bad "forced timeout, same live instance: answers from cache" "khs=$khs baseline=$BASELINE_KHS elapsed=${elapsed}s res=$res"
fi
if grep -q "^cached$" "$T/state/.bloxminer-rx-hstats-state" 2>/dev/null; then
	ok "forced timeout: state file records the 'cached' transition"
else
	bad "forced timeout: state file records the 'cached' transition" "$(cat "$T/state/.bloxminer-rx-hstats-state" 2>/dev/null)"
fi

# ---- 3: same, but the cache is older than CACHE_MAX_AGE_S (90 s) -> hard fallback to 0, not the stale value
sed -i.bak "s/^ts=.*/ts=$(awk -v n="$(date +%s.%N)" 'BEGIN{printf "%.6f", n-91}')/" "$CACHEFILE"
poll "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5"
if [[ $khs == "0" ]]; then
	ok "forced timeout, cache older than 90 s: hard fallback to 0, never the stale value"
else
	bad "forced timeout, cache older than 90 s: hard fallback to 0" "khs=$khs res=$res"
fi

# ---- 4: refresh a good cache for PID1, then the fake /proc no longer has PID1 at all (instance gone - a real
#      xmrig restart or an engine switch back to rx with a new pid always removes the old /proc entry) -> even
#      though the cache file itself is fresh, it must never be adopted for an unrelated/vanished instance.
mk_proc "$PID1" "$START1" "$PORT" "$INODE"   # PID1 back, so this poll succeeds normally and refreshes the cache
poll ""
[[ $khs != "0" ]] || bad "setup: refresh cache for PID1" "khs=$khs res=$res"
PID2=9202; START2=2000; INODE2=777002
mk_proc "$PID2" "$START2" "$PORT" "$INODE2"   # PID1's /proc entry is GONE now - only PID2 exists
poll "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5"
if [[ $khs == "0" ]]; then
	ok "forced timeout, cached instance's /proc entry is gone (restart/switch): hard fallback to 0, never adopted"
else
	bad "forced timeout, cached instance vanished: hard fallback to 0" "khs=$khs res=$res"
fi

# ---- 5: a GENUINE, freshly observed stall (xmrig alive, every thread's hashrate really 0) must still report 0
#      immediately (the existing fast/honest path, never touched by the cache) - AND that honest 0 becomes the
#      new cached value, so a timeout immediately afterwards still reports 0, never an earlier positive number.
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_STALL" '{summary: $s, backends: $b}' > "$T/replies.json"
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
python3 "$HERE/fake_xmrig_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
is_zero() { awk -v k="${1:-x}" 'BEGIN{exit !(k == 0)}'; }   # accepts "0" (fallback()'s literal) and "0.00" (rows-derived, %.2f)

poll ""
if is_zero "$khs"; then
	ok "genuine stall (real 0 hashrate, xmrig alive): reported immediately, honestly, via the normal path"
else
	bad "genuine stall: reported as 0 immediately" "khs=$khs res=$res"
fi
poll "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5"
if is_zero "$khs"; then
	ok "forced timeout right after a genuine stall: cache (now correctly 0) is never masked back to positive"
else
	bad "forced timeout right after a genuine stall: still 0, not masked" "khs=$khs res=$res"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
