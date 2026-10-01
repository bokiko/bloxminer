#!/usr/bin/env bash
# Reproduces the real-rig bug found on cask10 (5950X, all 32 threads mining): h-stats.sh's /proc ownership and
# task-mask scans must stay O(1) forks regardless of BOTH process-table size AND actual CPU load - a per-item
# fork loop was fast enough on an idle dev box to hide the problem entirely, but slow enough under real CPU
# load (fork/exec latency multiplies badly when every core is busy) to blow the whole 3.0 s budget and make
# Hive's watchdog see 0 H/s and reboot the rig. Every case here saturates CPUs for its own duration only, and
# unconditionally cleans up (busy loops, any real xmrig) via a trap even on failure. bloxsense is never an
# instant fixture here: case 1 uses one that genuinely sleeps ~0.55 s (matching the real bloxsense's own RAPL
# two-read sample), and case 2 uses the actual compiled bloxsense binary when available - so the measured wall
# times reflect true end-to-end latency under load, not an artificially fast stand-in.
# Usage: tests/hive/test_rx_under_load.sh (needs jq, curl, python3, bash, nproc; case 2 uses the frozen,
# gated xmrig/bloxsense binaries from the 1.0.0 release - BLOX_FROZEN_XMRIG/BLOX_FROZEN_BLOXSENSE override
# the default path; skipped if neither is present)
set -u
# Serialize against any OTHER CPU-saturating load test (this file, or the verus engine's own
# test_verus_under_load.sh) already running - anywhere, any user, on this same host: two such tests running
# concurrently compete for the same CPUs, which inflates elapsed times for BOTH and produces exactly the kind
# of flaky, contention-driven "budget" failure this suite must never report as a real regression. A single,
# well-known lock file + a blocking `flock` (with a generous timeout as a backstop against a genuinely stuck
# holder, never a silent skip) makes this deterministic: this script simply waits its turn.
exec 9>"${TMPDIR:-/tmp}/bloxminer-load-test.lock"
flock -w 600 9 || { echo "SKIP: could not acquire the shared load-test lock within 600s (stuck holder?)"; exit 0; }
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer/engines/rx" && pwd)
TOPSRC=$(cd "$HERE/../../bloxminer" && pwd)   # the full top-level package (dispatcher + both engines) - case 3 only
MANIFEST_SRC="$TOPSRC/h-manifest.conf"   # shared top-level manifest (3.0.0)
T=$(mktemp -d)
BUSY_PIDS=()
XMRIG_PID=""
API_PID=""; API3_PID=""; API4_PID=""   # backstop only - all are already killed inline right after their own case finishes;
	# the trap exists so an abnormal exit mid-case can never leave either running (pids only, never a pattern -
	# 127.0.0.1:20015 is permanently held by another, lead-owned process on shared build hosts)
cleanup() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	[[ -n $XMRIG_PID ]] && kill -9 "$XMRIG_PID" 2>/dev/null
	[[ -n $API_PID ]] && kill -9 "$API_PID" 2>/dev/null
	[[ -n $API3_PID ]] && kill -9 "$API3_PID" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

saturate_cpus() {   # starts nproc pure-bash-builtin busy loops (no exec, so a plain -9 always reaps them cleanly)
	local n; n=$(nproc)
	BUSY_PIDS=()
	for _ in $(seq 1 "$n"); do
		sh -c 'while :; do :; done' &
		BUSY_PIDS+=("$!")
	done
}
stop_saturating() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	wait "${BUSY_PIDS[@]}" 2>/dev/null
	BUSY_PIDS=()
}

# ================================================================== case 1: fake /proc (~1500 fds/375 procs), full CPU load
BLOX_DIR="$T/pkg"; mkdir -p "$BLOX_DIR" "$T/log"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer-x#" "$MANIFEST_SRC" > "$BLOX_DIR/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config.json"
: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"   # placeholder: only its path is compared (exe symlink target), never run

BLOXSENSE_JSON=$(python3 -c '
import json
cpus = [{"cpu": c, "pkg": 0, "core": c % 16, "temp": 60, "src": "core"} for c in range(32)]
print(json.dumps({"cpus": cpus, "pkg_temp": 65, "power_w": None, "ccd_reason": "test fixture"}))
')
# Sleeps ~0.55 s like the real bloxsense's own RAPL two-read sample, instead of answering instantly - so the
# wall-time measurement below reflects genuine end-to-end latency under load, not an artificially fast fixture.
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/sh
sleep 0.55
echo '$BLOXSENSE_JSON'
EOF
chmod +x "$BLOX_DIR/bloxsense"

PROC="$T/proc"
python3 - "$PROC" "$BLOX_DIR/xmrig" <<'PY'
import os, sys
root, xmrig_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(root, "net"), exist_ok=True)
TARGET_PID = "9001"
TARGET_INODE = 555555
n = 0
for i in range(2000, 2375):   # 375 unrelated processes x 4 fds = ~1500 fds, none matching our inode
	fddir = os.path.join(root, str(i), "fd")
	os.makedirs(fddir, exist_ok=True)
	for j in range(4):
		os.symlink("socket:[%d]" % (900000 + n), os.path.join(fddir, str(j)))
		n += 1
fddir = os.path.join(root, TARGET_PID, "fd")
os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[%d]" % TARGET_INODE, os.path.join(fddir, "23"))
os.symlink(xmrig_path, os.path.join(root, TARGET_PID, "exe"))
taskdir = os.path.join(root, TARGET_PID, "task")
for c in range(32):   # 16C/32T: matches the bloxsense fixture's core mapping (c % 16)
	d = os.path.join(taskdir, str(c))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t%d\n" % c)
hexport = "%04X" % 4069
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 100 0 0 10 0\n" % (hexport, TARGET_INODE))
PY

# hashrate.total matches BACK_OK's per-thread sum exactly (sum(500+c) for c in 0..31 = 16496 H/s = 16.50 kH/s)
# so Phase A's own summary-only answer (bloxminer/engines/rx/h-stats.sh's mandatory, cheap tier) is ALSO a
# real, correct total - not just Phase B's (the per-core /2/backends enrichment) job to be right.
SUM_OK=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0", hashrate: {total: [16496, null, null]}}')
BACK_OK=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [500.0 + c, None, None]} for c in range(32)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_OK" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 4069 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
grep -q ready "$T/api.out" || { bad "fake /proc under full CPU load" "fake API did not start: $(cat "$T/api.out")"; }
# "ready" (printed right after bind()+listen()) only confirms the LISTENING socket exists, never that the
# server's own accept() loop has actually run yet - a request landing in that gap can go unanswered long
# enough to look like a startup failure, purely a fake-server race with nothing to do with h-stats.sh itself
# (test_rx_hive_scripts.sh's own stats_case() hit this exact race and added this exact round-trip confirmation
# loop for it). Confirm a REAL HTTP round-trip before this test's saturated polling loop depends on this port.
for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:4069/2/summary" && break; sleep 0.05; done

export BLOX_DIR BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT=4069
saturate_cpus
sleep 0.3   # let the busy loops actually load every core before measuring
t0=$(date +%s.%N)
# shellcheck disable=SC2016
res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
t1=$(date +%s.%N)
stop_saturating
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
khs=$(jq -r '.khs' <<< "$res" 2>/dev/null)
nrows=$(jq -r '.stats.hs | length' <<< "$res" 2>/dev/null)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && awk -v k="${khs:-0}" 'BEGIN{exit !(k > 0)}' && [[ ${nrows:-0} == 16 ]]; then
	ok "fake /proc (~1500 fds/375 procs) under full CPU load: khs=$khs, 16 rows, < 3.0 s (${elapsed}s)"
else
	bad "fake /proc (~1500 fds/375 procs) under full CPU load: khs > 0, 16 rows, < 3.0 s" "elapsed=${elapsed}s khs=$khs rows=$nrows res=$res"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
unset BLOX_PROCFS_ROOT

# ================================================================== case 2: REAL /proc, REAL xmrig --bench, full CPU load
XMRIG_BIN=${BLOX_FROZEN_XMRIG:-$HOME/c3work/frozen/bloxminer-x/xmrig}   # frozen, gated 1.0.0 binary
if [[ -x $XMRIG_BIN ]]; then
	# xmrig runs FROM the package dir (not a separate work dir + symlink): the ownership check compares
	# /proc/<pid>/exe (the kernel's own canonical path to what was actually exec'd) against "$PKG/xmrig" as a
	# plain string, so the binary's real, running location must be exactly that path.
	REAL_DIR="$T/pkg2"; mkdir -p "$REAL_DIR" "$T/log2"
	cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$REAL_DIR"/
	cp "$XMRIG_BIN" "$REAL_DIR/xmrig"
	BLOXSENSE_BIN=${BLOX_FROZEN_BLOXSENSE:-$HOME/c3work/frozen/bloxminer-x/bloxsense}   # frozen, gated binary
	if [[ -x $BLOXSENSE_BIN ]]; then
		cp "$BLOXSENSE_BIN" "$REAL_DIR/bloxsense"   # the REAL binary: genuinely real topology, temps and RAPL timing on this box
	else
		cp "$BLOX_DIR/bloxsense" "$REAL_DIR/bloxsense"   # fallback: the ~0.55 s-sleeping fixture, if bloxsense was not built
	fi
	sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config2.json#" \
	    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log2/bloxminer-x#" "$MANIFEST_SRC" > "$REAL_DIR/h-manifest.conf"
	jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config2.json"
	cat > "$REAL_DIR/xmrig-config.json" <<'CFG'
{
  "autosave": false, "background": false, "colors": false,
  "randomx": {"1gb-pages": false},
  "cpu": {"enabled": true, "huge-pages": false},
  "opencl": {"enabled": false}, "cuda": {"enabled": false},
  "http": {"enabled": true, "host": "127.0.0.1", "port": 4070, "restricted": true, "access-token": null},
  "donate-level": 0, "donate-over-proxy": 0,
  "pools": [{"url": "127.0.0.1:19999", "user": "test", "pass": "x", "algo": "rx/0", "keepalive": false}]
}
CFG
	# `exec` inside the subshell (rather than `cd ... && ./xmrig ...` as one backgrounded compound command) so
	# the subshell's own process image BECOMES xmrig - otherwise `$!` captures the wrapper bash the "cd &&"
	# chain keeps alive, not xmrig itself (a then-unknown child of it), and killing that PID later orphans the
	# real xmrig process instead of stopping it (found while writing this very test).
	( cd "$REAL_DIR" || exit 1; exec ./xmrig -c xmrig-config.json --bench=10M > console.txt 2>&1 ) &
	XMRIG_PID=$!
	sleep 20   # RandomX dataset init (~7 s on this box) + a full 10 s window so XMRig's own hashrate[0]
	           # average is actually populated (it reports null/0 before that; real CPU load throughout either way)

	export BLOX_DIR="$REAL_DIR" BLOX_API_PORT=4070
	unset BLOX_PROCFS_ROOT   # the REAL /proc this time - whatever this box's real process table looks like

	# ---- cold start, 1 CPU, real contention: the ENTIRE sourced call (exactly how Hive's agent - and every
	# other case in this file - invokes it), pinned via taskset to the SAME single CPU the real xmrig --bench
	# above is also fighting for, as the VERY FIRST poll against this instance (nothing warmed up, no prior
	# successful poll, no cache of any kind post-redesign). Proves the single-absolute-deadline budget holds
	# end-to-end, not just inside the collector's own child. Real-Hive cask18 evidence (32-thread 5950X) showed
	# 2.86 s EVERY poll before the redesign; the target since is < 1.5 s.
	if command -v taskset > /dev/null 2>&1; then
		t0=$(date +%s.%N)
		# shellcheck disable=SC2016
		cold_res=$(timeout 5 taskset -c 0 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "$khs"' 2>&1)
		t1=$(date +%s.%N)
		cold_elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b - a}')
		if awk -v e="$cold_elapsed" 'BEGIN{exit !(e < 1.5)}' && awk -v k="${cold_res:-0}" 'BEGIN{exit !(k > 0)}'; then
			ok "cold start, taskset -c 0, REAL xmrig --bench saturating every CPU: khs=$cold_res, < 1.5 s (${cold_elapsed}s)"
		else
			bad "cold start, taskset -c 0, REAL xmrig --bench: khs > 0, < 1.5 s" "elapsed=${cold_elapsed}s khs=$cold_res"
		fi
	else
		echo "SKIP: taskset not available - cold-start 1-CPU case skipped"
	fi

	t0=$(date +%s.%N)
	# shellcheck disable=SC2016
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	khs=$(jq -r '.khs' <<< "$res" 2>/dev/null)
	nrows=$(jq -r '.stats.hs | length' <<< "$res" 2>/dev/null)
	if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && awk -v k="${khs:-0}" 'BEGIN{exit !(k > 0)}' && [[ ${nrows:-0} -gt 0 ]]; then
		ok "REAL xmrig --bench under full CPU load: khs=$khs, $nrows rows, < 3.0 s (${elapsed}s)"
	else
		bad "REAL xmrig --bench under full CPU load: khs > 0, rows > 0, < 3.0 s" "elapsed=${elapsed}s khs=$khs rows=$nrows res=$res"
	fi
	kill -9 "$XMRIG_PID" 2>/dev/null; wait "$XMRIG_PID" 2>/dev/null; XMRIG_PID=""
else
	echo "SKIP: real xmrig bench case ($XMRIG_BIN not found - build it first with build/build.sh)"
fi


# ================================================================== case 3: Round 5 (Codex test-gap review) -
#    SUSTAINED polling (>= 60 polls) under full CPU load through the FINAL PACKAGE's TOP-LEVEL h-stats.sh
#    (dispatcher: sources h-common.sh, engines/rx/h-stats.sh, THEN calls finalize_rx_hugepages - cases 1/2 above
#    only ever test the engine's own h-stats.sh directly, which never exercises the new finalization code at
#    all). Proves finalize_rx_hugepages adds no meaningful cost once finalized (the overwhelming majority of a
#    real rx session's polls) and never causes a false zero or a budget overrun even while it is still actively
#    checking on every poll (before finalizing) under full CPU load - the exact conditions ("runs every 10 s
#    under 100% CPU") its own design comment requires.
BLOX_DIR3="$T/pkg3"; mkdir -p "$BLOX_DIR3" "$T/log3" "$T/state3"
cp -r "$TOPSRC"/* "$BLOX_DIR3/"
chmod +x "$BLOX_DIR3"/*.sh "$BLOX_DIR3"/engines/*/*.sh
CONF3="$T/config3.json"
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$CONF3#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log3/bloxminer#" "$MANIFEST_SRC" > "$BLOX_DIR3/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}], randomx: {}}' > "$CONF3"
: > "$BLOX_DIR3/xmrig"; chmod +x "$BLOX_DIR3/xmrig"
cp "$T/pkg/bloxsense" "$BLOX_DIR3/bloxsense"   # the same ~0.55 s-sleeping fixture case 1 already built (case
	# 1's own package dir, "$T/pkg" - NOT the shared $BLOX_DIR variable, which case 2 above may have repointed
	# at "$T/pkg2" if it ran)

PROC3="$T/proc3"
python3 - "$PROC3" "$BLOX_DIR3/xmrig" <<'PY'
import os, sys
root, xmrig_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(root, "net"), exist_ok=True)
TARGET_PID = "9101"
TARGET_INODE = 666666
n = 0
for i in range(3000, 3375):   # 375 unrelated processes x 4 fds = ~1500 fds, matching case 1's shape
	fddir = os.path.join(root, str(i), "fd")
	os.makedirs(fddir, exist_ok=True)
	for j in range(4):
		os.symlink("socket:[%d]" % (800000 + n), os.path.join(fddir, str(j)))
		n += 1
fddir = os.path.join(root, TARGET_PID, "fd")
os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[%d]" % TARGET_INODE, os.path.join(fddir, "23"))
os.symlink(xmrig_path, os.path.join(root, TARGET_PID, "exe"))
taskdir = os.path.join(root, TARGET_PID, "task")
for c in range(32):
	d = os.path.join(taskdir, str(c))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t%d\n" % c)
hexport = "%04X" % 4071
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 100 0 0 10 0\n" % (hexport, TARGET_INODE))
os.makedirs(os.path.join(root, "sys", "vm"), exist_ok=True)
os.makedirs(os.path.join(root, "sys", "kernel", "random"), exist_ok=True)
with open(os.path.join(root, "sys", "vm", "nr_hugepages"), "w") as f:
	f.write("1201\n")   # prelim(1200) + max(0, need(1201) - free0(1200)) - exactly what finalize should confirm
with open(os.path.join(root, "meminfo"), "w") as f:
	f.write("HugePages_Free:      1200 kB\nHugepagesize:        2048 kB\n")
with open(os.path.join(root, "sys", "kernel", "random", "boot_id"), "w") as f:
	f.write("case3-boot\n")
with open(os.path.join(root, "uptime"), "w") as f:   # Round 5c: 10 s after start_uptime=1000 below - well
	f.write("1010.00 0.00\n")                        # inside HUGEPAGES_STARTUP_WINDOW_S's default 300 s
# Round 5b: finalize_rx_hugepages now reads XMRig's own KERNEL-mapped huge pages from smaps_rollup (the API's
# own "hugepages" total undercounts by the RandomX JIT buffer - see h-common.sh) - 1201 pages, matching the
# exact cask18 live value, not the API's [1200,1200] below.
with open(os.path.join(root, TARGET_PID, "smaps_rollup"), "w") as f:
	f.write("Rss:                 512 kB\nPss:                 512 kB\nPrivate_Hugetlb:  2459648 kB\nShared_Hugetlb:  0 kB\n")
PY
mkdir -p "$T/state3"
printf 'prior=0\nprelim=1200\nfree0=1200\nboot=case3-boot\nstart_uptime=1000\nfinal=0\n' > "$T/state3/.bloxminer-hugepages"

SUM3=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0", hugepages: [1200, 1200], hashrate: {total: [16496, null, null]}}')
BACK3=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [500.0 + c, None, None]} for c in range(32)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')
jq -n --argjson s "$SUM3" --argjson b "$BACK3" '{summary: $s, backends: $b}' > "$T/replies3.json"
: > "$T/api3.out"
python3 "$HERE/fake_xmrig_api.py" 4071 "$T/replies3.json" > "$T/api3.out" 2>&1 & API3_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api3.out" && break; sleep 0.1; done
grep -q ready "$T/api3.out" || bad "sustained polling: fake API startup" "$(cat "$T/api3.out" 2>/dev/null)"
# see the earlier fake_xmrig_api.py startup in this file for the full rationale - "ready" alone does not prove
# a real HTTP round-trip works yet
for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:4071/2/summary" && break; sleep 0.05; done

export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4071 BLOX_STATE_DIR="$T/state3"
saturate_cpus
sleep 0.3
N_POLLS=60
HARD_CAP=4.0   # PR #2 follow-up (Codex): budget (3.0s) + a generous fixed 1.0s tolerance for legitimate
	# scheduling jitter - never relaxed by the 90% soft-tolerance counter below. The bug this guards against
	# (still_running's own fork-heavy liveness probe running unboundedly long under CPU starvation, delaying
	# the deadline check itself) produced 3.5-4.0s polls that the OLD soft-tolerance-only check let slide as
	# long as <= 10% of polls were affected - exactly the kind of real regression a purely statistical
	# tolerance can hide. ANY single poll past this hard ceiling fails the whole case outright.
n_zero=0; n_over_budget=0; n_hardfail=0; max_elapsed=0
for i in $(seq 1 "$N_POLLS"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_zero=$((n_zero+1)); echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' || { n_over_budget=$((n_over_budget+1)); echo "  poll $i: OVER BUDGET (${elapsed}s)"; }
	awk -v e="$elapsed" -v c="$HARD_CAP" 'BEGIN{exit !(e > c)}' && { n_hardfail=$((n_hardfail+1)); echo "  poll $i: HARD CAP EXCEEDED (${elapsed}s > ${HARD_CAP}s)"; }
	awk -v e="$elapsed" -v m="$max_elapsed" 'BEGIN{exit !(e > m)}' && max_elapsed=$elapsed
done
stop_saturating

# ---- the ENTIRE sourced call through the TOP-LEVEL dispatcher (manifest parsing, engine_from_config,
# THEN the engine's own collection, THEN hugepage finalization - everything a real Hive poll does, not just
# the engine's own h-stats.sh in isolation), pinned via taskset to small, stressed cpusets (1-3 CPUs) against
# ALL CPUs saturated - proves the single absolute deadline (now computed at this TRUE poll entry, before even
# manifest parsing) actually bounds the whole thing end-to-end, with a stated tolerance for scheduling jitter
# at the most extreme (1-2 CPU) tiers, matching the same tolerance policy as test_verus_under_load.sh.
if command -v taskset > /dev/null 2>&1; then
	NPROC=$(nproc)
	DISP_N=5   # per tier - enough to distinguish a real regression from a single transient scheduling blip
	for want in 1 2 3; do
		(( want <= NPROC )) || continue
		hi=$((want - 1))
		eb=1; (( want < 3 )) && eb=0   # budget enforced from 3 CPUs up - same policy as verus's own load test
		HARD_CAP_D=4.5   # budget (3.5s) + a generous fixed 1.0s tolerance - see case 3's own HARD_CAP comment
			# above for the full rationale. Scoped to the same tiers as $eb: at 1-2 CPUs, no timing claim (soft
			# or hard) is made at all, by design (see this loop's own comment below).
		saturate_cpus; sleep 0.3
		n_zero_d=0; n_over_d=0; n_hardfail_d=0; max_d=0
		for _ in $(seq 1 "$DISP_N"); do
			t0=$(date +%s.%N)
			# shellcheck disable=SC2016
			res=$(timeout 5 taskset -c "0-$hi" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
			t1=$(date +%s.%N)
			elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
			pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
			awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || n_zero_d=$((n_zero_d+1))
			awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}' || n_over_d=$((n_over_d+1))
			(( eb )) && { awk -v e="$elapsed" -v c="$HARD_CAP_D" 'BEGIN{exit !(e > c)}' && n_hardfail_d=$((n_hardfail_d+1)); }
			awk -v e="$elapsed" -v m="$max_d" 'BEGIN{exit !(e > m)}' && max_d=$elapsed
		done
		stop_saturating
		# Same >= 90% budget-compliance tolerance as the engine-only load tests (see their own comments for
		# the full rationale) - ZERO false zeros is never relaxed, and neither is $n_hardfail_d (a statistical
		# tolerance is never a licence for a single poll to run arbitrarily long).
		n_ok_d=$((DISP_N - n_over_d)); n_need_d=$(( (DISP_N * 9 + 9) / 10 ))
		if [[ $n_zero_d == 0 && $n_hardfail_d == 0 ]] && (( ! eb || n_ok_d >= n_need_d )); then
			ok "top-level dispatcher h-stats.sh, taskset 0-$hi ($want CPU(s)): no false zeros$( ((eb)) && echo ", $n_ok_d/$DISP_N < 3.5s (need >= $n_need_d/$DISP_N)" ) (max ${max_d}s)"
		else
			bad "top-level dispatcher h-stats.sh, taskset 0-$hi ($want CPU(s)): no false zeros$( ((eb)) && echo ", $n_ok_d/$DISP_N under budget (need >= $n_need_d/$DISP_N), 0 hard-cap failures" )" \
				"n_zero=$n_zero_d n_over=$n_over_d n_hardfail=$n_hardfail_d max=${max_d}s"
		fi
	done
else
	echo "SKIP: taskset not available - top-level dispatcher stressed-cpuset case skipped"
fi

kill "$API3_PID" 2>/dev/null; wait "$API3_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT BLOX_STATE_DIR

# Budget compliance requires at least 90% of polls (rounded up, so even a short run keeps ONE poll of slack)
# within 3.0 s, not literally every single one - a lone transient overrun from scheduling noise this host did
# not cause is not the same thing as a real regression. ZERO false zeros is never relaxed at any tolerance -
# that is the actual property a real Hive rig's watchdog cares about. The 90% counter is a STATISTICAL
# tolerance for jitter, never a licence for a single poll to run arbitrarily long - $n_hardfail (HARD_CAP
# above) catches that separately and is never relaxed either.
n_ok_budget=$((N_POLLS - n_over_budget)); n_need_budget=$(( (N_POLLS * 9 + 9) / 10 ))
if [[ $n_zero == 0 && $n_hardfail == 0 ]] && (( n_ok_budget >= n_need_budget )); then
	ok "sustained polling ($N_POLLS polls, top-level h-stats.sh, full CPU load): no false zeros, $n_ok_budget/$N_POLLS under 3.0 s (need >= $n_need_budget/$N_POLLS, max ${max_elapsed}s)"
else
	bad "sustained polling ($N_POLLS polls): no false zeros, $n_ok_budget/$N_POLLS under budget (need >= $n_need_budget/$N_POLLS), 0 hard-cap failures" "n_zero=$n_zero n_over_budget=$n_over_budget n_hardfail=$n_hardfail max=${max_elapsed}s"
fi
final3=$(sed -n 's/^final=//p' "$T/state3/.bloxminer-hugepages" 2>/dev/null)
ours3=$(sed -n 's/^ours=//p' "$T/state3/.bloxminer-hugepages" 2>/dev/null)
if [[ $final3 == 1 && $ours3 == 1201 ]]; then
	ok "sustained polling: finalize_rx_hugepages finalized during the run (final=1, ours=1201) and never regressed across $N_POLLS polls"
else
	bad "sustained polling: finalized during the run, stable across all polls" "final=$final3 ours=$ours3"
fi

# ================================================================== case 4: PR #2 follow-up review (Codex)
# finding #1 - "Reserve time for huge-page finalization". Case 3 above saturates all CPUs, but its fake
# collector work is cheap enough to finish in a fraction of a second regardless - it never comes close to the
# rx engine's own 1.95 s/2.25 s TERM-then-KILL deadline, so finalize_rx_hugepages_bounded always gets its full
# nominal share there, poll 1 onward, on every commit tested (this PR's own reproduction: identical on
# a811b8d, before the fork-free deadline rewrite, and a769ed7, after it - NOT a regression from either). The
# bot's actual concern was the collector's own WORST case: when it is still genuinely running at its own
# deadline and has to be TERM'd then (if that is ignored) KILL'd, finalize only ever gets whatever is left of
# the shared 3.0 s AFTER that - this case is the first in this suite to actually force that worst case, on
# EVERY poll, through the REAL top-level dispatcher end to end (never finalize_rx_hugepages_bounded called in
# isolation with a hand-picked margin, which would only prove the function itself, not the budget split
# upstream of it finding #1 was actually about). The fixture: a bloxsense that ignores SIGTERM and sleeps
# indefinitely - the SAME one tests/hive/test_rx_hive_scripts.sh already uses to prove the engine's own
# collector dies via its outer process-group SIGKILL rather than surviving an ignored TERM - guarantees the
# collector can never finish on its own; it is killed at the deadline, every single poll, with no exception.
# A direct, isolated repro of finalize_rx_hugepages_bounded alone (this PR's own description) found it reached
# final=1 in as few as 3-4 of 30 attempts when the worst-case margin was the OLD flat 300 ms (2.4 s collector +
# 0.3 s KILL_GRACE out of 3.0 s) - this case reproduces the SAME ~15% rate (3/20) end to end on a769ed7, and
# the fix (collector share cut to 1.95 s, worst case 2.25 s, leaving 0.75 s - bloxminer/h-stats.sh and
# engines/rx/h-stats.sh) reaches 20/20 under the identical conditions. The record is reset to final=0 before
# EVERY poll (N independent "first attempts", not one record carried across polls that only has to succeed
# once) - a weaker "reaches final=1 at least once within N polls" assertion would not reliably fail on the OLD
# code at a reasonable N (even a genuinely ~15%-per-attempt process succeeds at least once within, say, 10
# tries roughly 75% of the time - not a dependable regression signal).
PROC4="$T/proc4"; mkdir -p "$PROC4/sys/vm" "$PROC4/sys/kernel/random" "$PROC4/net"
echo 1201 > "$PROC4/sys/vm/nr_hugepages"
printf 'HugePages_Free:      1200 kB\nHugepagesize:        2048 kB\n' > "$PROC4/meminfo"
echo "case4-boot" > "$PROC4/sys/kernel/random/boot_id"
printf '1010.00 0.00\n' > "$PROC4/uptime"
OWNER_PID4=9104
mkdir -p "$PROC4/$OWNER_PID4/fd"
ln -s "socket:[434343]" "$PROC4/$OWNER_PID4/fd/7"
BLOX_DIR4="$T/pkg4"; mkdir -p "$BLOX_DIR4"
cp -r "$TOPSRC"/* "$BLOX_DIR4/"
chmod +x "$BLOX_DIR4"/*.sh "$BLOX_DIR4"/engines/*/*.sh
CONF4="$T/config4.json"
jq -n '{pools: [{url:"stratum+tcp://p:1", user:"W", algo:"rx/0"}], randomx: {"1gb-pages": false}}' > "$CONF4"
sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$CONF4#" \
           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log4/bloxminer#" "$BLOX_DIR4/h-manifest.conf"
rm -f "$BLOX_DIR4/h-manifest.conf.bak"
mkdir -p "$T/log4" "$T/state4"
: > "$BLOX_DIR4/xmrig"; chmod +x "$BLOX_DIR4/xmrig"
ln -sf "$BLOX_DIR4/xmrig" "$PROC4/$OWNER_PID4/exe"
printf 'Rss:                 512 kB\nPss:                 512 kB\nPrivate_Hugetlb:  2459648 kB\nShared_Hugetlb:  0 kB\n' > "$PROC4/$OWNER_PID4/smaps_rollup"

MARKER4="bloxminerx_test_case4_bloxsense_$$"
cat > "$BLOX_DIR4/bloxsense" <<EOF4
#!/bin/bash
trap '' TERM
exec -a $MARKER4 sleep 30
EOF4
chmod +x "$BLOX_DIR4/bloxsense"

PORT4=4074
hexport4=$(printf '%04X' "$PORT4")
{
	echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
	echo "   0: 0100007F:$hexport4 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 434343 1 0000000000000000 100 0 0 10 0"
} > "$PROC4/net/tcp"
SUM4=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0", hugepages: [1200, 1200], hashrate: {total: [16496, null, null]}}')
BACK4=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [500.0 + c, None, None]} for c in range(32)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')
jq -n --argjson s "$SUM4" --argjson b "$BACK4" '{summary: $s, backends: $b}' > "$T/replies4.json"
: > "$T/api4.out"
python3 "$HERE/fake_xmrig_api.py" "$PORT4" "$T/replies4.json" > "$T/api4.out" 2>&1 & API4_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api4.out" && break; sleep 0.1; done
for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:$PORT4/2/summary" && break; sleep 0.05; done

export BLOX_DIR="$BLOX_DIR4" BLOX_PROCFS_ROOT="$PROC4" BLOX_API_PORT="$PORT4" BLOX_STATE_DIR="$T/state4"
saturate_cpus
sleep 0.3
N_POLLS4=20
HARD_CAP4=4.5   # budget (3.0 s) + a generous fixed tolerance - same rationale as case 3's own HARD_CAP; every
	# poll here legitimately runs the collector's FULL escalation window by construction (unlike case 3), so
	# this is checked, never relaxed, against an outer ceiling well above even that expected ~2.25-2.97 s.
n_final4=0; n_hardfail4=0; max4=0
for i in $(seq 1 "$N_POLLS4"); do
	printf 'prior=0\nprelim=1200\nfree0=1200\nboot=case4-boot\nstart_uptime=1000\nfinal=0\n' > "$T/state4/.bloxminer-hugepages"
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	awk -v e="$elapsed" -v c="$HARD_CAP4" 'BEGIN{exit !(e > c)}' && { n_hardfail4=$((n_hardfail4+1)); echo "  poll $i: HARD CAP EXCEEDED (${elapsed}s > ${HARD_CAP4}s)"; }
	awk -v e="$elapsed" -v m="$max4" 'BEGIN{exit !(e > m)}' && max4=$elapsed
	f=$(sed -n 's/^final=//p' "$T/state4/.bloxminer-hugepages" 2>/dev/null)
	[[ $f == 1 ]] && n_final4=$((n_final4+1))
done
stop_saturating
pkill -9 -f "$MARKER4" 2>/dev/null   # safety net: never leak a process into the box even if this test fails
kill "$API4_PID" 2>/dev/null; wait "$API4_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT BLOX_STATE_DIR

# This PR's own measurement: 3/20 (15%) on a769ed7 (the OLD 2.4 s/0.3 s split), 20/20 on the fix, both on the
# same 24-core host - >= 80% (16/20) sits well clear of both, decisive either way without being flaky on a
# differently-sized/noisier CI runner. Zero hard-cap failures is never relaxed, same as case 3's own policy.
n_need4=16
if (( n_final4 >= n_need4 )) && [[ $n_hardfail4 == 0 ]]; then
	ok "SIGTERM-ignoring bloxsense (collector burns its FULL TERM+KILL escalation every poll), full CPU load: finalize_rx_hugepages reached final=1 in $n_final4/$N_POLLS4 independent attempts (need >= $n_need4/$N_POLLS4, max ${max4}s, 0 hard-cap failures)"
else
	bad "SIGTERM-ignoring bloxsense, full CPU load: finalize_rx_hugepages reaches final=1 in >= $n_need4/$N_POLLS4 independent attempts" "n_final4=$n_final4/$N_POLLS4 n_hardfail4=$n_hardfail4 max=${max4}s"
fi

leaked=()
for p in "$API_PID" "$API3_PID" "$API4_PID"; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && leaked+=("$p"); done
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	for p in "${leaked[@]}"; do kill -9 "$p" 2>/dev/null; done
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
