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
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer/engines/rx" && pwd)
TOPSRC=$(cd "$HERE/../../bloxminer" && pwd)   # the full top-level package (dispatcher + both engines) - case 3 only
MANIFEST_SRC="$TOPSRC/h-manifest.conf"   # shared top-level manifest (3.0.0)
T=$(mktemp -d)
BUSY_PIDS=()
XMRIG_PID=""
cleanup() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	[[ -n $XMRIG_PID ]] && kill -9 "$XMRIG_PID" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

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

SUM_OK=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0"}')
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

SUM3=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0", hugepages: [1200, 1200]}')
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

export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4071 BLOX_STATE_DIR="$T/state3"
saturate_cpus
sleep 0.3
N_POLLS=60
n_zero=0; n_over_budget=0; max_elapsed=0
for i in $(seq 1 "$N_POLLS"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_zero=$((n_zero+1)); echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' || { n_over_budget=$((n_over_budget+1)); echo "  poll $i: OVER BUDGET (${elapsed}s)"; }
	awk -v e="$elapsed" -v m="$max_elapsed" 'BEGIN{exit !(e > m)}' && max_elapsed=$elapsed
done
stop_saturating
kill "$API3_PID" 2>/dev/null; wait "$API3_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT BLOX_STATE_DIR

if [[ $n_zero == 0 && $n_over_budget == 0 ]]; then
	ok "sustained polling ($N_POLLS polls, top-level h-stats.sh, full CPU load): no false zeros, all under 3.0 s (max ${max_elapsed}s)"
else
	bad "sustained polling ($N_POLLS polls): no false zeros, all under budget" "n_zero=$n_zero n_over_budget=$n_over_budget max=${max_elapsed}s"
fi
final3=$(sed -n 's/^final=//p' "$T/state3/.bloxminer-hugepages" 2>/dev/null)
ours3=$(sed -n 's/^ours=//p' "$T/state3/.bloxminer-hugepages" 2>/dev/null)
if [[ $final3 == 1 && $ours3 == 1201 ]]; then
	ok "sustained polling: finalize_rx_hugepages finalized during the run (final=1, ours=1201) and never regressed across $N_POLLS polls"
else
	bad "sustained polling: finalized during the run, stable across all polls" "final=$final3 ours=$ours3"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
