#!/usr/bin/env bash
# Tests for the rx engine's redesigned h-stats.sh collector (PR #2 finding 1, round 2). An earlier version of
# this file tested a last-known-good CACHE of $khs, served on a missed deadline. Codex correctly rejected that
# design: a live process (even the SAME instance, pid+/proc-start confirmed) proves nothing about whether it is
# still hashing - seed a positive sample, then let the miner stall or the API go unreachable while the
# collector keeps missing its deadline, and the same pid/start/exe would go on serving a stale positive rate.
# The redesign removes that cache entirely: bloxminer/engines/rx/h-stats.sh now splits every poll into a
# mandatory, cheap Phase A (one /2/summary call - already has the aggregate hashrate, accepted/rejected,
# uptime) written immediately, and an optional Phase B (/2/backends + bloxsense + per-core binding
# verification) that only ever OVERWRITES Phase A's answer with a richer one built from the SAME poll - never
# a substitute for it. So every answer is either genuinely fresh (this exact poll) or the defined 0; there is
# no cache of the number that matters left to test an age bound for. What IS still cached (see ENRICHFILE) is
# a single cosmetic value - the last real TEMPERATURE Phase B measured - bounded by instance identity and age,
# because a stale temperature has no watchdog-reboot consequence, unlike a stale rate.
# Forces a Phase failure deterministically via two existing test-only hooks in h-stats.sh:
# BLOX_HSTATS_TEST_HANDSHAKE_DELAY (sleeps before the child even starts - so a total kill happens before Phase
# A can write anything) and BLOX_HSTATS_TEST_PHASEB_DELAY (sleeps right after Phase A has already written, so
# only Phase B is lost to the kill) - rather than relying on real CPU contention, which is what
# tests/hive/test_rx_under_load.sh is for.
# Usage: tests/hive/test_rx_stats_cache.sh (needs jq, python3, bash; Linux /proc layout)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer/engines/rx" && pwd)
TOPSRC=$(cd "$HERE/../../bloxminer" && pwd)
MANIFEST_SRC="$TOPSRC/h-manifest.conf"
T=$(mktemp -d)
API_PID=""
cleanup() { [[ -n $API_PID ]] && kill -9 "$API_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }
is_zero() { awk -v k="${1:-x}" 'BEGIN{exit !(k == 0)}'; }   # accepts "0" (fallback()'s literal) and "0.00" (%.2f)

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
	python3 - "$PROC/$pid/stat" "$pid" "$start" <<'PY'
import sys
path, pid, start = sys.argv[1], sys.argv[2], sys.argv[3]
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

# start_api <summary-json> <backends-json> - (re)starts the fake xmrig API, killing any previous instance.
start_api() {
	[[ -n $API_PID ]] && { kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; }
	jq -n --argjson s "$1" --argjson b "$2" '{summary: $s, backends: $b}' > "$T/replies.json"
	: > "$T/api.out"
	python3 "$HERE/fake_xmrig_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
	for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
	grep -q ready "$T/api.out" || { echo "SKIP: fake API did not (re)start: $(cat "$T/api.out")"; exit 0; }
}

# Every summary fixture's hashrate.total EXACTLY matches its paired backends fixture's per-thread sum, so
# Phase A's own answer (summary alone) and Phase B's (backends, per-core) agree on the same underlying reality
# - the point of the redesign is that BOTH are honest, not that one is a rough placeholder the other overrides.
BACK_R1=$(python3 -c 'import json; print(json.dumps([{"type":"cpu","threads":[{"affinity":c,"hashrate":[400.0+c,None,None]} for c in range(4)]}]))')
SUM_R1=$(jq -nc '{uptime: 500, connection: {accepted: 40, rejected: 1}, algo: "rx/0", version: "6.26.0", hashrate: {total: [1600, null, null]}}')   # Phase A rounds the TOTAL once (1600 H/s -> 1.60 kH/s); Phase B rounds each of BACK_R1's per-thread rows (400,401,402,403 H/s) FIRST, then sums the already-rounded rows (0.40*4=1.60) - a different rounding order that happens to agree here by construction, so both phases are asserted against the SAME expected figure below.
BACK_R2=$(python3 -c 'import json; print(json.dumps([{"type":"cpu","threads":[{"affinity":c,"hashrate":[900.0+c,None,None]} for c in range(4)]}]))')
SUM_R2=$(jq -nc '{uptime: 600, connection: {accepted: 55, rejected: 1}, algo: "rx/0", version: "6.26.0", hashrate: {total: [3600, null, null]}}')   # same rounding-order note as SUM_R1 - 3600 H/s matches BACK_R2's per-row-rounded sum (0.90*4=3.60)
BACK_STALL=$(python3 -c 'import json; print(json.dumps([{"type":"cpu","threads":[{"affinity":c,"hashrate":[0.0,None,None]} for c in range(4)]}]))')
SUM_STALL=$(jq -nc '{uptime: 700, connection: {accepted: 55, rejected: 1}, algo: "rx/0", version: "6.26.0", hashrate: {total: [0, null, null]}}')
BACK_R3=$(python3 -c 'import json; print(json.dumps([{"type":"cpu","threads":[{"affinity":c,"hashrate":[200.0+c,None,None]} for c in range(4)]}]))')
SUM_R3=$(jq -nc '{uptime: 50, connection: {accepted: 3, rejected: 0}, algo: "rx/0", version: "6.26.0", hashrate: {total: [806, null, null]}}')   # sum(200..203)=806 H/s = 0.81 kH/s

PORT=20500; INODE=777001; PID1=9201; START1=1000
mk_proc "$PID1" "$START1" "$PORT" "$INODE"
start_api "$SUM_R1" "$BACK_R1"

export BLOX_DIR BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT="$PORT" BLOX_STATE_DIR="$T/state"
ENRICHFILE="$T/state/.bloxminer-rx-hstats-enrich"

poll() {   # sets $khs $elapsed $res; $1 = extra env assignment (e.g. "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5") or ""
	local t0 t1
	t0=$(date +%s.%N)
	if [[ -n ${1:-} ]]; then
		# shellcheck disable=SC2016
		res=$(env "$1" timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs] stats=[$stats]"' 2>&1)
	else
		# shellcheck disable=SC2016
		res=$(timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs] stats=[$stats]"' 2>&1)
	fi
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	khs=$(sed -n 's/^khs=\[\(.*\)\] stats=.*/\1/p' <<< "$res")
	temp0=$(jq -r '.temp[0] // "null"' <<< "$(sed -n 's/^khs=\[.*\] stats=\[\(.*\)\]$/\1/p' <<< "$res")" 2>/dev/null)
}

# ---- 1: baseline real poll (no delay) -> real positive khs, agreeing with the paired fixtures' real total
poll ""
if [[ $khs == "1.60" ]]; then
	ok "baseline poll: real khs (1.60) - Phase A (summary) and Phase B (backends) agree"
else
	bad "baseline poll: real khs 1.60" "khs=$khs res=$res"
fi

# ---- 2: the value CHANGES between polls and is always reflected - never a stale figure from poll 1
start_api "$SUM_R2" "$BACK_R2"
poll ""
if [[ $khs == "3.60" ]]; then
	ok "value changed between polls (1.60 -> 3.60): reflected immediately, never the old figure"
else
	bad "value changed between polls: reflected immediately" "khs=$khs (expected 3.60) res=$res"
fi

# ---- 3: Codex's exact attack - seed a real positive poll, then force the WHOLE collector to be killed before
#      Phase A can even write (BLOX_HSTATS_TEST_HANDSHAKE_DELAY sleeps before the child starts at all) - the
#      SAME xmrig instance (same pid/start/exe) is still alive and the API is still up and still positive, so
#      the old cache design would have served 3.60 here; the redesign has no cache to serve it FROM, so this
#      must be an honest 0, immediately, bounded well under the outer `timeout 8`.
poll "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5"
if is_zero "$khs" && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}'; then
	ok "forced total kill before Phase A (same live instance, API still positive): honest 0, not 3.60 (${elapsed}s)"
else
	bad "forced total kill before Phase A: honest 0, bounded elapsed" "khs=$khs elapsed=${elapsed}s res=$res"
fi

# ---- 4: a genuine, freshly observed 0 (xmrig alive, every thread's rate really 0, summary agrees) is reported
#      immediately - the fast, honest path, never touched by anything from an earlier poll.
start_api "$SUM_STALL" "$BACK_STALL"
poll ""
if is_zero "$khs"; then
	ok "genuine 0 (real stall, xmrig alive, summary + backends agree): reported immediately, honestly"
else
	bad "genuine 0: reported as 0 immediately" "khs=$khs res=$res"
fi
poll "BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5"
if is_zero "$khs"; then
	ok "forced total kill right after a genuine stall: still 0 (nothing to mask it with even if there were a cache)"
else
	bad "forced total kill right after a genuine stall: still 0" "khs=$khs res=$res"
fi

# ---- 5: cold start - no ENRICHFILE exists yet (the temperature side-cache, never khs) - Phase B forced to miss
#      its own window (BLOX_HSTATS_TEST_PHASEB_DELAY sleeps AFTER Phase A has already written, so only Phase B
#      is lost) must still leave Phase A's own honest, fresh total standing, with a null temperature (nothing
#      to fall back to yet) rather than any kind of failure.
rm -f "$ENRICHFILE"
start_api "$SUM_R1" "$BACK_R1"
poll "BLOX_HSTATS_TEST_PHASEB_DELAY=5"
if [[ $khs == "1.60" && $temp0 == "null" ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}'; then
	ok "cold start, Phase B forced to miss: Phase A's own total (1.60) stands, temp null, bounded (${elapsed}s)"
else
	bad "cold start, Phase B forced to miss: Phase A total stands, temp null" "khs=$khs temp0=$temp0 elapsed=${elapsed}s res=$res"
fi

# ---- 6: Phase B succeeds once (populating ENRICHFILE with a real temperature for THIS instance), then a later
#      poll with Phase B forced to miss reuses that cached temperature (cosmetic only - khs is still always
#      fresh from Phase A, never from the cache).
poll ""   # normal poll: Phase B runs, writes ENRICHFILE (pkg_temp=55 from the bloxsense stub)
[[ $khs == "1.60" ]] || bad "setup: normal poll populates ENRICHFILE" "khs=$khs res=$res"
poll "BLOX_HSTATS_TEST_PHASEB_DELAY=5"
if [[ $khs == "1.60" && $temp0 == "55" ]]; then
	ok "Phase B forced to miss after a real one ran: Phase A's fresh khs (1.60) + the cached temp (55)"
else
	bad "Phase B forced to miss after a real one ran: fresh khs + cached temp" "khs=$khs temp0=$temp0 res=$res"
fi

# ---- 7: restart/switch - PID1's /proc entry is gone (a real xmrig restart or an engine switch back to rx
#      always removes the old /proc entry); a NEW instance PID2 is present with a DIFFERENT rate. Even with
#      Phase B forced to miss, khs must reflect PID2's OWN fresh Phase-A total (never PID1's), and the
#      temperature must be null (PID1's cached temp must never leak into PID2's answer).
PID2=9202; START2=2000; INODE2=777002
mk_proc "$PID2" "$START2" "$PORT" "$INODE2"   # PID1's /proc entry is GONE now - only PID2 exists
start_api "$SUM_R3" "$BACK_R3"
poll "BLOX_HSTATS_TEST_PHASEB_DELAY=5"
if [[ $khs == "0.81" && $temp0 == "null" ]]; then
	ok "restart/switch (new pid): fresh khs for the NEW instance (0.81), no reuse of the old instance's temp"
else
	bad "restart/switch: fresh khs for new instance, no temp reuse" "khs=$khs temp0=$temp0 res=$res"
fi

# ---- 8: sustained - repeated polls, Phase B forced to miss every time, khs tracks whatever summary currently
#      reports (changed mid-run) and never falls back to 0 while genuinely hashing; elapsed stays bounded on
#      every single poll (one absolute deadline, not a probe that can run past it).
n_zero=0; n_over=0
for i in 1 2 3 4 5; do
	poll "BLOX_HSTATS_TEST_PHASEB_DELAY=5"
	is_zero "$khs" && n_zero=$((n_zero+1))
	awk -v e="$elapsed" 'BEGIN{exit (e < 3.5)}' && n_over=$((n_over+1))
	[[ $khs == "0.81" ]] || { echo "  sustained poll $i: unexpected khs=$khs"; }
done
if [[ $n_zero -eq 0 && $n_over -eq 0 ]]; then
	ok "sustained (5 polls, Phase B forced to miss every time): no false zeros, every poll bounded under 3.5s"
else
	bad "sustained: no false zeros, all bounded" "n_zero=$n_zero n_over=$n_over"
fi

# SIGTERM + wait first (a no-op if it's already reaped) - a real leak is one that outlives its own SIGTERM,
# not simply one still alive at this exact line before anything has tried to stop it.
[[ -n $API_PID ]] && { kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; }
if [[ -n $API_PID ]] && kill -0 "$API_PID" 2>/dev/null; then
	bad "no leaked fake-API child process at suite end" "still alive: $API_PID"
	kill -9 "$API_PID" 2>/dev/null
else
	ok "no leaked fake-API child process at suite end"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
