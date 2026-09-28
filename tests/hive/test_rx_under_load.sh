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
MANIFEST_SRC=$(cd "$HERE/../../bloxminer" && pwd)/h-manifest.conf   # shared top-level manifest (3.0.0)
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

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
