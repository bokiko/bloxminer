#!/usr/bin/env bash
# Rounds 5 and 5b: the huge-page ownership FINALIZATION gate (h-common.sh's finalize_rx_hugepages, called only
# from the TOP-LEVEL bloxminer/h-stats.sh, after sourcing engines/rx/h-stats.sh - see h-common.sh's "Huge-page
# ownership" section for the full design/xmrig-src-derived formula this exercises).
# Round 5 fixed C4-CASK18-RESULT.md's FINDING: XMRig itself raises vm.nr_hugepages beyond what Hive's own
# `hugepages -rx` set, so the OLD "ours = value right after -rx" was wrong and never let a prior=0 rig release
# its ~2.3 GB reservation. Round 5b then found Round 5's own replacement formula still wrong on the REAL rig:
# it used the xmrig HTTP API's own "hugepages":[allocated,total], which UNDERCOUNTS by exactly the RandomX JIT
# code buffer (allocated via a separate, unreserve()'d, ummtracked mmap path - see h-common.sh's
# _hp_xmrig_need_pages comment for the full xmrig-src trace) - live on cask18: API said [1200,1200], but
# /proc/<xmrig>/smaps_rollup's Private_Hugetlb showed 1201 pages, matching the REAL live vm.nr_hugepages=1201
# exactly. finalize_rx_hugepages now reads that kernel truth directly instead of trusting XMRig's own
# (incomplete) self-report; the API is kept only as a readiness signal (allocated==total).
# Every case here goes through the REAL top-level h-stats.sh, SOURCED (never executed, never a hand-copy of
# just the engine half) - the same shape Hive's own agent uses - against a fake procfs/meminfo/boot_id/smaps
# (BLOX_PROCFS_ROOT) and a fake xmrig HTTP API (tests/hive/fake_xmrig_api.py) serving /2/summary and
# /2/backends, exactly like engines/rx/h-stats.sh's own ownership-verified stats collection already does - this
# is not a new interface, just a second, independent consumer of the same one.
# Usage: tests/hive/test_hugepage_finalization.sh (Linux: needs jq, curl, python3, bash)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer" && pwd)
T=$(mktemp -d)
API_PID=""
cleanup() { [[ -n $API_PID ]] && kill -9 "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-78s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-78s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR="$T/pkg"
CONF="$T/config.json"
HUGEFILE="$T/state/.bloxminer-hugepages"
LOGFILE="$T/log/bloxminer.log"
PORT=4069
OWNER_PID=9101   # the ownership-verified xmrig pid throughout (bound to $PORT, exe == $BLOX_DIR/xmrig)
# Round 5e: the hung-FIFO cases below use a SHORTENED test budget (not the real 3.0 s default) so the suite
# doesn't have to wait out a real poll's worth of time to prove the bound - TEST_HP_BUDGET_S is that shortened
# budget, and SCHED_TOLERANCE_S is an explicit, STATED allowance on top of it for real scheduling/signal-
# delivery/reap latency (process wake-up jitter under load, `ps`/`kill`/`wait` syscall overhead) - never a
# vague/generous margin: MAX_ELAPSED_S is the one number every timing assertion below is held to.
TEST_HP_BUDGET_S=1.5
SCHED_TOLERANCE_S=0.15
MAX_ELAPSED_S=$(awk -v b="$TEST_HP_BUDGET_S" -v t="$SCHED_TOLERANCE_S" 'BEGIN{printf "%.2f", b+t}')

setup_pkg() {
	rm -rf "$BLOX_DIR" "$T/log" "$T/state"; mkdir -p "$BLOX_DIR" "$T/log" "$T/state"
	cp -r "$PKGSRC"/* "$BLOX_DIR/"
	chmod +x "$BLOX_DIR"/*.sh "$BLOX_DIR"/engines/*/*.sh
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$CONF#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" "$BLOX_DIR/h-manifest.conf"
	rm -f "$BLOX_DIR/h-manifest.conf.bak"
	: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"   # placeholder: only its resolved /proc/<pid>/exe path is ever compared
}

# ---- config.json: a real, working rx config (engine_from_config -> rx); 1gb-pages toggled per test
write_rx_config() {   # $1 = "true"|"false" for randomx."1gb-pages" (default false)
	jq -n --arg onegb "${1:-false}" \
		'{pools: [{url:"stratum+tcp://p:1", user:"W", algo:"rx/0"}], randomx: {"1gb-pages": ($onegb == "true")}}' > "$CONF"
}
write_verus_config() { jq -n '{algo:"verus", pools:[{url:"stratum+tcp://p:1"}], user:"W"}' > "$CONF"; }

# ---- fake /proc: net/tcp (one listening socket on $PORT, owned by pid $OWNER_PID whose /proc/<pid>/exe ==
#      $BLOX_DIR/xmrig unless $1 says otherwise), sys/vm/nr_hugepages, meminfo (HugePages_Free + Hugepagesize -
#      Round 5b, _hp_xmrig_need_pages needs it), sys/kernel/random/boot_id - the same technique
#      tests/hive/test_rx_under_load.sh already uses for its own ownership fixture.
setup_proc() {   # $1 = nr_hugepages (live) $2 = HugePages_Free $3 = boot_id string $4 = exe path owner_pid's
	# /proc/<pid>/exe should resolve to (default: $BLOX_DIR/xmrig - the real, matching one)
	PROC="$T/proc"; rm -rf "$PROC"; mkdir -p "$PROC/sys/vm" "$PROC/sys/kernel/random" "$PROC/net"
	echo "$1" > "$PROC/sys/vm/nr_hugepages"
	printf 'HugePages_Free:  %8d kB\nHugepagesize:        2048 kB\n' "$2" > "$PROC/meminfo"
	printf '%s\n' "$3" > "$PROC/sys/kernel/random/boot_id"
	set_uptime 1010   # Round 5c: 10 s after the fixture records' own start_uptime=1000 below - comfortably
		# inside HUGEPAGES_STARTUP_WINDOW_S's default 300 s; set_uptime overrides this per test.
	python3 - "$PROC" "${4:-$BLOX_DIR/xmrig}" "$PORT" "$OWNER_PID" <<'PY'
import os, sys
root, exe_path, port, pid = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
fddir = os.path.join(root, pid, "fd"); os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[424242]", os.path.join(fddir, "7"))
os.symlink(exe_path, os.path.join(root, pid, "exe"))
hexport = "%04X" % port
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 424242 1 0000000000000000 100 0 0 10 0\n" % hexport)
PY
}
set_nr_hugepages() { echo "$1" > "$PROC/sys/vm/nr_hugepages"; }   # a "foreign" write between polls
set_uptime() { printf '%s.00 0.00\n' "$1" > "$PROC/uptime"; }   # Round 5c: fake /proc/uptime's own first field

# ---- Round 5b: /proc/<pid>/smaps_rollup - the KERNEL TRUTH source finalize_rx_hugepages now reads instead of
#      the xmrig API's own (incomplete) "hugepages" total. write_smaps with no args writes nothing (simulates
#      the file being entirely absent - the fail-safe case); write_smaps_partial writes a rollup with NEITHER
#      Hugetlb field (present file, missing data - a different fail-safe case).
pages_kb() { echo $(( $1 * 2048 )); }   # N huge pages -> kB, matching the 2048 kB Hugepagesize setup_proc writes
write_smaps() {   # $1=pid $2=Private_Hugetlb (2 MB pages) $3=Shared_Hugetlb (2 MB pages, default 0)
	mkdir -p "$PROC/$1"
	printf 'Rss:                 512 kB\nPss:                 512 kB\nPrivate_Hugetlb:  %d kB\nShared_Hugetlb:  %d kB\n' \
		"$(pages_kb "$2")" "$(pages_kb "${3:-0}")" > "$PROC/$1/smaps_rollup"
}
write_smaps_partial() { mkdir -p "$PROC/$1"; printf 'Rss:                 512 kB\nPss:                 512 kB\n' > "$PROC/$1/smaps_rollup"; }

# ---- fake xmrig API: one CPU thread reporting real hashrate, a CONTROLLABLE "hugepages":[allocated,total] on
#      /2/summary (xmrig.backend.cpu.CpuBackend.cpp:471) - Round 5b: kept ONLY as a readiness signal
#      (allocated==total) by finalize_rx_hugepages, never again as the source of the "need" value.
API_CFG="$T/replies.json"
start_api() {   # $1 = hugepages allocated $2 = hugepages total $3 = hashrate (khs-bearing; 0 => no hashrate yet)
	local sum back
	sum=$(jq -nc --argjson alloc "$1" --argjson total "$2" \
		'{uptime:120, connection:{accepted:9,rejected:0}, algo:"rx/0", version:"6.26.0", hugepages:[$alloc,$total]}')
	back=$(jq -nc --argjson hs "${3:-500}" '[{type:"cpu", threads:[{affinity:0, hashrate:[$hs,null,null]}]}]')
	jq -n --argjson s "$sum" --argjson b "$back" '{summary:$s, backends:$b}' > "$API_CFG"
	python3 "$HERE/fake_xmrig_api.py" "$PORT" "$API_CFG" > "$T/api.out" 2>&1 &
	API_PID=$!
	for _ in $(seq 50); do grep -q ready "$T/api.out" 2>/dev/null && return 0; sleep 0.1; done
	return 1
}
stop_api() { [[ -n $API_PID ]] && kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; API_PID=""; }

# ---- one poll of the REAL top-level h-stats.sh, sourced, exactly as Hive's agent does; bloxsense/task-mask
#      binding is deliberately NOT modelled here (falls back to "unverified" per-thread rows) - irrelevant to
#      hugepage finalization, which reads only $khs, the API's readiness fields, and smaps_rollup.
poll() {
	out=$(BLOX_DIR="$BLOX_DIR" BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT="$PORT" BLOX_STATE_DIR="$T/state" bash -c '
		. "$BLOX_DIR/h-stats.sh"
		echo "khs=[$khs]"
	' 2>&1)
}

hp_field() { sed -n "s/^$1=//p" "$HUGEFILE" 2>/dev/null; }
log_count() { grep -c "$1" "$LOGFILE" 2>/dev/null || echo 0; }

# ---- restore: real top-level h-run.sh (executed - engine binary is absent, so it exits after the hugepage
#      step, exactly like test_dispatcher.sh's run_h_run), with a fake `sysctl` on PATH so a real restore
#      attempt (or its absence) is directly observable.
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
echo "sysctl $*" >> "$SYSCTL_LOG"
[ "${SYSCTL_FAIL:-0}" = "1" ] && exit 1
[ "${SYSCTL_LIE:-0}" = "1" ] && exit 0   # "succeeds" but never touches PROCFILE - tests the readback check
for a in "$@"; do case $a in vm.nr_hugepages=*) echo "${a#vm.nr_hugepages=}" > "$PROCFILE" ;; esac; done
exit 0
SH
chmod +x "$FAKEBIN/sysctl"
SYSCTL_LOG="$T/sysctl.log"; export SYSCTL_LOG
attempt_restore() {   # writes $SYSCTL_LOG (engine binary absent, so h-run.sh's own exit status is not meaningful)
	write_verus_config
	: > "$SYSCTL_LOG"
	PROCFILE="$PROC/sys/vm/nr_hugepages" PATH="$FAKEBIN:$PATH" BLOX_PROCFS_ROOT="$PROC" BLOX_STATE_DIR="$T/state" \
		SYSCTL_FAIL="${SYSCTL_FAIL:-0}" SYSCTL_LIE="${SYSCTL_LIE:-0}" \
		timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1
}
sysctl_called() { grep -q '^sysctl ' "$SYSCTL_LOG" 2>/dev/null; }

# ================================================================== 1. THE EXACT cask18 case (Round 5b),
#    reproduced from the lead's live measurement on 2c89cc4c/commit 12e9cfa: prior=0, prelim=1200 (Hive's
#    `hugepages -rx` target), free0=1200 (HugePages_Free right after that call), API reports hugepages
#    [1200,1200] (fully allocated, by XMRig's OWN incomplete accounting), but /proc/<xmrig>/smaps_rollup shows
#    Private_Hugetlb=1201 pages (the JIT buffer XMRig's API total misses) -> predicted = 1200 + max(0, 1201 -
#    1200) = 1201, exactly the real live vm.nr_hugepages. ONE poll finalizes (final=1, ours=1201); the record
#    then round-trips through a REAL Verus restore back to 0 - the exact bug (a prior=0 rig never releasing its
#    reservation) fixed end to end, this time against the numbers that actually occur on real Hive.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-AAA
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-AAA\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500000 || bad "fake xmrig API startup" "$(cat "$T/api.out" 2>/dev/null)"
poll
poll_khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$out")
if [[ -n $poll_khs ]] && awk -v k="$poll_khs" 'BEGIN{exit !(k>0)}'; then ok "poll 1: h-stats reports real hashrate (khs=$poll_khs > 0)"; else bad "poll 1: h-stats reports real hashrate" "$out"; fi
if [[ $(hp_field final) == 1 && $(hp_field ours) == 1201 ]]; then
	ok "poll 1 (exact cask18 numbers): finalizes (final=1, ours=1201 = prelim 1200 + max(0, kernel need 1201 - free0 1200))"
else
	bad "poll 1 (exact cask18 numbers): finalizes (final=1, ours=1201)" "$(cat "$HUGEFILE" 2>/dev/null)"
fi
stop_api
SYSCTL_FAIL=0 SYSCTL_LIE=0 attempt_restore
if sysctl_called && grep -q "nr_hugepages=0" "$SYSCTL_LOG"; then ok "restore after finalization: real Verus start restores the ORIGINAL prior (0)"; else bad "restore after finalization: restores prior (0)" "$(cat "$SYSCTL_LOG")"; fi
if [[ $(cat "$PROC/sys/vm/nr_hugepages") == 0 ]]; then ok "restore after finalization: live vm.nr_hugepages actually now 0"; else bad "restore after finalization: live value now 0" "$(cat "$PROC/sys/vm/nr_hugepages")"; fi
if [[ ! -e $HUGEFILE ]]; then ok "restore after finalization: ownership record removed (readback verified)"; else bad "restore after finalization: record removed" "$(cat "$HUGEFILE")"; fi

# ================================================================== 2. cask18's OWN shape: nonzero baseline
#    (prior=1201, left over from an earlier, never-released session) still finalizes and restores correctly -
#    the fix does not regress the one case where the Round 4 code happened to look right by accident.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-BBB
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=1201\nprelim=1200\nfree0=1200\nboot=boot-BBB\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500 || bad "fake xmrig API startup (case 2)" "$(cat "$T/api.out" 2>/dev/null)"
poll
if [[ $(hp_field final) == 1 && $(hp_field ours) == 1201 ]]; then ok "cask18 nonzero baseline: finalizes (final=1, ours=1201)"; else bad "cask18 nonzero baseline: finalizes" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
stop_api
attempt_restore
if grep -q "nr_hugepages=1201" "$SYSCTL_LOG" 2>/dev/null; then ok "cask18 nonzero baseline: restores the ORIGINAL prior (1201)"; else bad "cask18 nonzero baseline: restores prior (1201)" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 3. second poll never rewrites an already-
#    finalized record (idempotent - h-stats.sh polls every ~10 s for the whole rx session)
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-CCC
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-CCC\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll   # finalizes
before=$(cat "$HUGEFILE")
poll   # should be a no-op now
after=$(cat "$HUGEFILE")
stop_api
if [[ $before == "$after" ]]; then ok "second poll after finalization: record byte-identical (never rewritten)"; else bad "second poll after finalization: record unchanged" "before=[$before] after=[$after]"; fi

# ================================================================== 4. not ready yet (dataset still allocating,
#    allocated < total on the API): silently retried, NEVER logged, final stays 0 - this is the NORMAL
#    early-poll case of every fresh rx start, not an anomaly. (No smaps fixture at all here - the API readiness
#    gate must reject this BEFORE finalize_rx_hugepages ever reaches smaps_rollup.)
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-DDD
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-DDD\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 600 1200 500   # only half the dataset's pages allocated so far
poll
stop_api
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "predicted reservation") == 0 ]]; then
	ok "not yet fully allocated (600/1200): no finalize, not logged, retried next poll"
else
	bad "not yet fully allocated: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 5. not ready yet (khs still 0, e.g. dataset
#    just finished but no 10 s hashrate window has elapsed): same - silent retry, never logged
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-EEE
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-EEE\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 0   # fully allocated but hashrate not up yet
poll
stop_api
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "predicted reservation") == 0 ]]; then
	ok "khs still 0: no finalize, not logged, retried next poll"
else
	bad "khs still 0: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 5b. PR #2 follow-up review round 2 (Codex):
#    "audit every jq -e for the empty-input divergence" - finalize_rx_hugepages's own readiness curl
#    (independent of the rx engine's own summary fetch earlier in the same poll) can return a genuinely EMPTY
#    body: API not reachable at all this poll. `jq -e 'type == "object"' <<< "$sum" || return 0` used to rely
#    on jq's own exit code alone to detect that - jq 1.6 (GitHub Actions' own ubuntu-22.04 runners; see
#    engines/rx/h-stats.sh's valid_summary()/valid_backends() for the full rationale) exits 0 ("successful")
#    for `-e` against empty input, which would have let this proceed past the guard with $sum empty instead of
#    retrying next poll - the hp_allocated/hp_total regex checks just below happened to still catch it safely
#    (jq without -e produces empty output on empty input on EITHER version, no divergence there), but only by
#    accident. No API running at all this poll (both the engine's own summary fetch AND finalize's own
#    independent one hit a dead port) - must not crash, must not finalize, must not log, record untouched.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-EE2
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-EE2\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
before=$(cat "$HUGEFILE")
poll   # no start_api at all - both curls in this poll hit a dead port
poll_khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$out")
after=$(cat "$HUGEFILE" 2>/dev/null)
if [[ $poll_khs == 0 ]]; then ok "API entirely unreachable: h-stats.sh still reports a clean khs=0 (no crash)"; else bad "API entirely unreachable: h-stats.sh reports clean khs=0" "$out"; fi
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "predicted reservation") == 0 ]]; then
	ok "API entirely unreachable (finalize's own summary curl empty): no finalize, not logged, retried next poll"
else
	bad "API entirely unreachable: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi
if [[ $before == "$after" ]]; then ok "API entirely unreachable: ownership record byte-identical (never touched)"; else bad "API entirely unreachable: record untouched" "before=[$before] after=[$after]"; fi

# ================================================================== 6. foreign change DURING the startup window
#    (readiness fully proven - API allocated==total, khs>0, smaps readable - but live != predicted): never
#    finalize, logged EXACTLY ONCE (final -> "conflict", a terminal state never revisited), record kept; a
#    later poll does not re-log.
setup_pkg; write_rx_config false
setup_proc 1400 1200 boot-FFF   # live is 1400, not the predicted 1201 - something else raised it too
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-FFF\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
if [[ $(hp_field final) == conflict ]] && grep -q "does not match XMRig's own predicted reservation" "$LOGFILE" 2>/dev/null; then
	ok "foreign change during startup (live 1400 != predicted 1201): final=conflict, logged"
else
	bad "foreign change during startup: final=conflict, logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi
n1=$(log_count "does not match XMRig's own predicted reservation")
poll   # a second poll must NOT log again - final is already "conflict", not "0"
stop_api
n2=$(log_count "does not match XMRig's own predicted reservation")
if [[ $n1 == 1 && $n2 == 1 ]]; then ok "foreign change during startup: logged exactly ONCE, not every poll"; else bad "foreign change during startup: logged exactly once" "n1=$n1 n2=$n2"; fi
attempt_restore
if ! sysctl_called; then ok "foreign change during startup: a later Verus start never restores (final != 1)"; else bad "foreign change during startup: never restores" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 7. foreign change AFTER finalization: the
#    EXISTING restore-time conflict path (unchanged logic, now gated behind final=1) - never overwrites, record
#    retained with its already-finalized prior/ours intact.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-GGG
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-GGG\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll   # finalizes: final=1, ours=1201
stop_api
set_nr_hugepages 5000   # a third party changes it AFTER finalization, before any Verus start
before=$(cat "$HUGEFILE")
attempt_restore
if ! sysctl_called && [[ $(cat "$PROC/sys/vm/nr_hugepages") == 5000 ]]; then ok "foreign change AFTER finalization: Verus start never overwrites it"; else bad "foreign change after finalization: never overwrites" "sysctl=$(cat "$SYSCTL_LOG") proc=$(cat "$PROC/sys/vm/nr_hugepages")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$before" ]]; then ok "foreign change AFTER finalization: record kept unchanged (still final=1/ours=1201)"; else bad "foreign change after finalization: record kept" "$(cat "$HUGEFILE" 2>/dev/null)"; fi

# ================================================================== 8. boot_id mismatch: never finalize, never
#    even logged (not an anomaly - just "not this boot's record"; tmpfs would have cleared it on a real reboot
#    anyway, this only guards the same-boot-but-somehow-stale-record edge case) - and never restored either.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-CURRENT
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-OLD\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
stop_api
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "BloxMiner") == 0 ]]; then
	ok "boot_id mismatch (record=boot-OLD, live=boot-CURRENT): no finalize, not logged"
else
	bad "boot_id mismatch: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi
attempt_restore
if ! sysctl_called; then ok "boot_id mismatch: never restored (final != 1)"; else bad "boot_id mismatch: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 9. 1gb-pages guard: smaps_rollup's
#    Hugetlb byte counters mix 1GB/2MB pages with no way to tell them apart (see h-common.sh's documented
#    limitation) - never finalize, logged exactly once (final -> "conflict"), never restored. (No smaps fixture
#    needed - this guard fires before finalize_rx_hugepages ever reads smaps_rollup.)
setup_pkg; write_rx_config true   # randomx."1gb-pages": true
setup_proc 1201 1200 boot-HHH
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-HHH\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
n1=$(log_count "1gb-pages is enabled")
poll
stop_api
n2=$(log_count "1gb-pages is enabled")
if [[ $(hp_field final) == conflict && $n1 == 1 && $n2 == 1 ]]; then
	ok "1gb-pages enabled: never finalizes, logged exactly once, not every poll"
else
	bad "1gb-pages enabled: never finalizes, logged once" "final=$(hp_field final) n1=$n1 n2=$n2 log=$(cat "$LOGFILE" 2>/dev/null)"
fi
attempt_restore
if ! sysctl_called; then ok "1gb-pages enabled: never restored (final != 1)"; else bad "1gb-pages enabled: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 10. a failed sysctl write's EXIT STATUS
#    lied (exit 0) but never actually touched vm.nr_hugepages - the Round 5 readback verification catches this
#    even though the old code (trusting only `sysctl`'s own exit status) would not have.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-III
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-III\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll   # finalizes: final=1, ours=1201
stop_api
before=$(cat "$HUGEFILE")
SYSCTL_LIE=1 attempt_restore
SYSCTL_LIE=0
if sysctl_called && [[ $(cat "$PROC/sys/vm/nr_hugepages") == 1201 ]]; then ok "sysctl exit-0-but-no-op: a restore WAS attempted, live value still 1201 (never actually changed)"; else bad "sysctl exit-0-but-no-op: restore attempted, value unchanged" "sysctl=$(cat "$SYSCTL_LOG") proc=$(cat "$PROC/sys/vm/nr_hugepages")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$before" ]]; then ok "sysctl exit-0-but-no-op: record RETAINED (readback did not match, never silently dropped)"; else bad "sysctl exit-0-but-no-op: record retained" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
if grep -q "did not read back correctly" "$LOGFILE" 2>/dev/null; then ok "sysctl exit-0-but-no-op: readback failure logged"; else bad "sysctl exit-0-but-no-op: readback failure logged" "$(cat "$LOGFILE" 2>/dev/null)"; fi

# ================================================================== 11. legacy (pre-Round-5) record: only
#    prior=/ours=, no final= line at all - never trusted for a restore (final missing != "1"), left untouched
#    until the next reboot clears tmpfs; no migration code needed, per design.
setup_pkg; write_verus_config
setup_proc 1200 1200 boot-JJJ
mkdir -p "$T/state"; printf 'prior=512\nours=1200\n' > "$HUGEFILE"   # exactly the OLD (pre-Round-5) shape
attempt_restore
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "huge-page ownership record not finalized" "$LOGFILE" 2>/dev/null; then
	ok "legacy pre-Round-5 record (no final=): never restored, kept, logged"
else
	bad "legacy pre-Round-5 record: never restored, kept, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$(cat "$HUGEFILE" 2>/dev/null) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 12. Round 5b: a FOREIGN pid's smaps_rollup
#    (some other, unrelated process also holding a huge Private_Hugetlb mapping) must NEVER count towards
#    "need" - only the ownership-verified owner pid's own kernel mapping is ever read. If the foreign pid's
#    absurd 90000-page value were mistakenly used, predicted would be wildly wrong and this would fail as a
#    "conflict"; it must still finalize correctly using ONLY pid 9101's real 1201.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-KKK
write_smaps "$OWNER_PID" 1201 0
write_smaps 9202 90000 0   # a foreign, unrelated process - never bound to $PORT, never our xmrig
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-KKK\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
stop_api
if [[ $(hp_field final) == 1 && $(hp_field ours) == 1201 ]]; then
	ok "foreign pid's smaps_rollup (90000 pages) never counted: finalizes correctly using only owner pid's 1201"
else
	bad "foreign pid's smaps_rollup never counted: finalizes using only owner pid's smaps" "$(cat "$HUGEFILE" 2>/dev/null)"
fi

# ================================================================== 13. Round 5b: exe mismatch (the process
#    bound to $PORT is NOT $BLOX_DIR/xmrig - a foreign miner/process on the same port) -> ownership check fails
#    before finalize_rx_hugepages ever reads smaps_rollup or the API at all; never finalized, never logged
#    (same silent-early-gate behaviour as an unproven-readiness case), never restored.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-LLL "/usr/bin/some-other-process"   # owner_pid's exe does NOT match $BLOX_DIR/xmrig
write_smaps "$OWNER_PID" 1201 0   # even a perfectly plausible smaps must not matter - ownership fails first
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-LLL\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
stop_api
if [[ $(hp_field final) == 0 ]]; then ok "exe mismatch (foreign process on \$PORT): never finalizes"; else bad "exe mismatch: never finalizes" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
attempt_restore
if ! sysctl_called; then ok "exe mismatch: never restored (final != 1)"; else bad "exe mismatch: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 14. Round 5b: smaps_rollup entirely
#    missing for the ownership-verified pid (e.g. it exited between the ownership check and this read, or a
#    kernel/permission quirk) -> fail safe: never finalize, logged once, final=conflict, record kept.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-MMM   # no write_smaps call at all - $PROC/$OWNER_PID/smaps_rollup does not exist
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-MMM\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
n1=$(log_count "could not read a complete huge-page mapping")
poll
stop_api
n2=$(log_count "could not read a complete huge-page mapping")
if [[ $(hp_field final) == conflict && $n1 == 1 && $n2 == 1 ]]; then
	ok "smaps_rollup entirely missing: fails safe, never finalizes, logged exactly once"
else
	bad "smaps_rollup missing: fails safe, logged once" "final=$(hp_field final) n1=$n1 n2=$n2 log=$(cat "$LOGFILE" 2>/dev/null)"
fi
attempt_restore
if ! sysctl_called; then ok "smaps_rollup missing: never restored (final != 1)"; else bad "smaps_rollup missing: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 15. Round 5b: smaps_rollup present but
#    missing BOTH Hugetlb fields (a stripped-down/unexpected kernel format) -> same fail-safe path as #14.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-NNN
write_smaps_partial "$OWNER_PID"
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-NNN\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
stop_api
if [[ $(hp_field final) == conflict ]] && grep -q "could not read a complete huge-page mapping" "$LOGFILE" 2>/dev/null; then
	ok "smaps_rollup present but missing Hugetlb fields: fails safe, never finalizes, logged"
else
	bad "smaps_rollup missing Hugetlb fields: fails safe, logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

# ================================================================== 16. Round 5c: Codex's EXACT counterexample -
#    documents the policy's accepted trade-off, not a bug. prelim==free0 (1200==1200, no shortfall by XMRig's
#    own reserve() arithmetic) means equality with the predicted value ALONE cannot distinguish "XMRig itself
#    raised nr_hugepages" from "a foreign writer landed at exactly 1201 in the same instant XMRig's own raise
#    would have" - there is no cheap way to make XMRig attribute its own write (re-confirmed this round: no log
#    line, no API field identifies the writer). Codex accepted an EXPLICIT, DOCUMENTED EXCLUSIVE-STARTUP POLICY
#    instead of an attribution proof (README.md's "Huge pages" section; h-common.sh's top-of-section comment):
#    within the bounded startup window, this package is the SOLE SUPPORTED writer of vm.nr_hugepages, so
#    equality is accepted as proof UNDER THAT POLICY. This test is readiness reached WITHIN the window (see
#    test 17 for the same numbers reached OUTSIDE it, which is never accepted regardless).
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-OOO   # live=1201: could be XMRig's own raise, or a foreign write landing on the same
	# value in the same instant - genuinely indistinguishable by value alone, which is exactly Codex's point
set_uptime 1005   # 5 s after start_uptime=1000 below - well within the window: readiness reached ON TIME
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-OOO\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
stop_api
if [[ $(hp_field final) == 1 && $(hp_field ours) == 1201 ]]; then
	ok "Codex's counterexample (prelim==free0==1200, live=1201, within the window): finalizes under the documented exclusive-ownership policy - accepted trade-off, not a bug"
else
	bad "Codex's counterexample: finalizes under the documented policy (within window)" "$(cat "$HUGEFILE" 2>/dev/null)"
fi

# ================================================================== 17. Round 5c: the SAME numbers as test 16,
#    but readiness is reached OUTSIDE the bounded window - the policy's other half. Never finalized regardless
#    of whether the numbers would otherwise match; logged once, final=conflict, never restored.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-PPP
set_uptime 1400   # 400 s after start_uptime=1000 - past HUGEPAGES_STARTUP_WINDOW_S's default 300 s
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-PPP\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
n1=$(log_count "exclusive huge-page ownership window")
poll
stop_api
n2=$(log_count "exclusive huge-page ownership window")
if [[ $(hp_field final) == conflict && $n1 == 1 && $n2 == 1 ]]; then
	ok "same numbers as test 16, but readiness reached OUTSIDE the 300 s window: never finalizes, logged once"
else
	bad "readiness outside the window: never finalizes, logged once" "final=$(hp_field final) n1=$n1 n2=$n2 log=$(cat "$LOGFILE" 2>/dev/null)"
fi
attempt_restore
if ! sysctl_called; then ok "readiness outside the window: never restored (final != 1)"; else bad "readiness outside the window: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 18. Round 5c: BLOX_HP_STARTUP_WINDOW_S
#    actually changes the bound (not hardcoded dead code) - 10 s elapsed is comfortably inside the DEFAULT 300 s
#    window, but exceeds a 5 s one.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-QQQ
set_uptime 1010   # 10 s elapsed since start_uptime=1000
write_smaps "$OWNER_PID" 1201 0
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-QQQ\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
BLOX_HP_STARTUP_WINDOW_S=5 poll
stop_api
if [[ $(hp_field final) == conflict ]]; then
	ok "BLOX_HP_STARTUP_WINDOW_S=5 override: 10 s elapsed exceeds it, never finalizes (default 300 s would have allowed it)"
else
	bad "window override actually bounds it" "$(cat "$HUGEFILE" 2>/dev/null)"
fi

# ================================================================== 19. Round 5c: restore_verus_hugepages must
#    independently re-check boot_id before ANY write - a finalized record (final=1) surviving into a DIFFERENT
#    boot (an unusual non-tmpfs $STATEDIR, or a reboot between finalization and this restore attempt) must never
#    be trusted just because prior/ours still look numerically fine.
setup_pkg; write_verus_config
setup_proc 1201 1200 boot-CURRENT-19
rm -f "$T/log/bloxminer.log"
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-DIFFERENT-19\nstart_uptime=1000\nfinal=1\nours=1201\n' > "$HUGEFILE"
attempt_restore
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "finalized huge-page ownership record is from a different boot" "$LOGFILE" 2>/dev/null; then
	ok "restore: finalized record's boot_id MISMATCHES the current boot -> never restored, kept, logged"
else
	bad "restore: boot_id mismatch never restored, kept, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$(cat "$HUGEFILE" 2>/dev/null) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 20. Round 5c: restore with the record's own
#    boot= field MISSING entirely (empty) - must not be treated as "matches everything"; refused exactly like a
#    mismatch.
setup_pkg; write_verus_config
setup_proc 1201 1200 boot-CURRENT-20
rm -f "$T/log/bloxminer.log"
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=\nstart_uptime=1000\nfinal=1\nours=1201\n' > "$HUGEFILE"
attempt_restore
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "finalized huge-page ownership record is from a different boot" "$LOGFILE" 2>/dev/null; then
	ok "restore: finalized record's boot= field MISSING -> never restored, kept, logged"
else
	bad "restore: missing boot= never restored, kept, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$(cat "$HUGEFILE" 2>/dev/null) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 21. Round 5c: restore when the CURRENT
#    boot_id is UNREADABLE (no /proc/sys/kernel/random/boot_id at all) - even though the record's own boot=
#    field looks perfectly valid, an unreadable "now" can never be confirmed to match it; refused, never an
#    "assume it matches" fallback.
setup_pkg; write_verus_config
setup_proc 1201 1200 boot-SOMETHING-21
rm -f "$PROC/sys/kernel/random/boot_id"   # current boot_id now unreadable
rm -f "$T/log/bloxminer.log"
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-SOMETHING-21\nstart_uptime=1000\nfinal=1\nours=1201\n' > "$HUGEFILE"
attempt_restore
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "finalized huge-page ownership record is from a different boot" "$LOGFILE" 2>/dev/null; then
	ok "restore: CURRENT boot_id unreadable -> never restored, kept, logged"
else
	bad "restore: unreadable current boot_id never restored, kept, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$(cat "$HUGEFILE" 2>/dev/null) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ---- fifo_has_no_reader_left <fifo path> - Round 5d: PROVES no descendant is left blocked reading a FIFO,
#      using the FIFO's own open() semantics rather than fragile ps/pgrep pid-matching across poll()'s own
#      bash -c boundary (already exited by the time we could inspect it from out here): opening the SAME path
#      for WRITING blocks until a reader appears, so it times out if and only if nothing is still waiting to
#      read it; a surviving orphaned reader instead pairs with this write attempt (near-)instantly.
# shellcheck disable=SC2016   # $1 is the child bash's own positional parameter, not this shell's
fifo_has_no_reader_left() { timeout 0.3 bash -c ': > "$1"' _ "$1" > /dev/null 2>&1; [[ $? == 124 ]]; }

# ================================================================== 22. Round 5c (Codex blocker 2): finalization
#    must never escape the poll's own budget. A deliberately SLOW /proc/<pid>/smaps_rollup read - a FIFO with
#    NO writer, so opening it for read blocks exactly like a hung real read would - is bounded by
#    finalize_rx_hugepages_bounded and killed once the remaining budget runs out; $khs/$stats (already set by
#    the engine's own h-stats.sh, before finalization ever runs) are completely unaffected, and finalization is
#    simply deferred (final stays "0") rather than ever blocking this poll. Round 5d: also proves the KILL
#    reaches the WHOLE process group, not just the top-level backgrounded job - Round 5c's own version of this
#    test could only acknowledge an orphaned grandchild and unblock it manually; this asserts none survives.
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-RRR
mkdir -p "$PROC/$OWNER_PID"; rm -f "$PROC/$OWNER_PID/smaps_rollup"; mkfifo "$PROC/$OWNER_PID/smaps_rollup"
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-RRR\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500000
t0=$(date +%s.%N)
BLOX_HP_TOTAL_BUDGET_S=$TEST_HP_BUDGET_S poll
t1=$(date +%s.%N)
stop_api
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
poll_khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$out")
if awk -v e="$elapsed" -v m="$MAX_ELAPSED_S" 'BEGIN{exit !(e < m)}'; then ok "slow smaps_rollup (FIFO, never written): whole poll still bounded to budget+tolerance (${elapsed}s < ${MAX_ELAPSED_S}s = ${TEST_HP_BUDGET_S}s budget + ${SCHED_TOLERANCE_S}s tolerance)"; else bad "slow smaps_rollup: whole poll still bounded to budget+tolerance" "elapsed=${elapsed}s max=${MAX_ELAPSED_S}s"; fi
if [[ -n $poll_khs ]] && awk -v k="$poll_khs" 'BEGIN{exit !(k>0)}'; then ok "slow smaps_rollup: \$khs/\$stats still valid despite the hung finalization attempt"; else bad "slow smaps_rollup: khs/stats still valid" "$out"; fi
if [[ $(hp_field final) == 0 ]]; then ok "slow smaps_rollup: finalization deferred (final stays 0), never a partial/wrong record"; else bad "slow smaps_rollup: finalization deferred" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
if fifo_has_no_reader_left "$PROC/$OWNER_PID/smaps_rollup"; then ok "slow smaps_rollup: the GROUP-kill reached the blocked read too - no orphaned descendant left waiting on the FIFO"; else bad "slow smaps_rollup: no orphaned descendant left" "a reader is still blocked on the FIFO"; fi
rm -f "$PROC/$OWNER_PID/smaps_rollup"

# ================================================================== 23. Round 5d (Codex): REPEATED timeouts (5
#    consecutive polls, each with a FRESH hung smaps_rollup FIFO) must never accumulate stuck descendants, and
#    each killed attempt must leave the record completely untouched - not just "final stays 0" but BYTE-
#    IDENTICAL to before that poll ran, even once the FIFO is later unblocked (proving there is no late/delayed
#    write racing the kill).
setup_pkg; write_rx_config false
setup_proc 1201 1200 boot-SSS
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1200\nboot=boot-SSS\nstart_uptime=1000\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500000
n_over=0; n_zero_khs=0; n_wrong_final=0; n_record_changed=0; n_survivor=0
for _ in 1 2 3 4 5; do
	mkdir -p "$PROC/$OWNER_PID"; rm -f "$PROC/$OWNER_PID/smaps_rollup"; mkfifo "$PROC/$OWNER_PID/smaps_rollup"
	before_record=$(cat "$HUGEFILE" 2>/dev/null)
	t0=$(date +%s.%N)
	BLOX_HP_TOTAL_BUDGET_S=$TEST_HP_BUDGET_S poll
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
	awk -v e="$elapsed" -v m="$MAX_ELAPSED_S" 'BEGIN{exit !(e < m)}' || n_over=$((n_over+1))
	poll_khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$out")
	{ [[ -n $poll_khs ]] && awk -v k="$poll_khs" 'BEGIN{exit !(k>0)}'; } || n_zero_khs=$((n_zero_khs+1))
	[[ $(hp_field final) == 0 ]] || n_wrong_final=$((n_wrong_final+1))
	after_record=$(cat "$HUGEFILE" 2>/dev/null)
	[[ "$before_record" == "$after_record" ]] || n_record_changed=$((n_record_changed+1))
	fifo_has_no_reader_left "$PROC/$OWNER_PID/smaps_rollup" || n_survivor=$((n_survivor+1))
	rm -f "$PROC/$OWNER_PID/smaps_rollup"
done
stop_api
if [[ $n_over == 0 ]]; then ok "repeated timeouts (5 polls, fresh hung FIFO each time): every poll stayed within budget+tolerance (< ${MAX_ELAPSED_S}s)"; else bad "repeated timeouts: every poll within budget+tolerance" "n_over=$n_over of 5 (max ${MAX_ELAPSED_S}s)"; fi
if [[ $n_zero_khs == 0 ]]; then ok "repeated timeouts: \$khs stayed valid every single time"; else bad "repeated timeouts: khs stayed valid" "n_zero_khs=$n_zero_khs of 5"; fi
if [[ $n_wrong_final == 0 ]]; then ok "repeated timeouts: final stayed 0 every single time (never a partial finalize)"; else bad "repeated timeouts: final stayed 0" "n_wrong_final=$n_wrong_final of 5"; fi
if [[ $n_record_changed == 0 ]]; then ok "repeated timeouts: record byte-identical after every killed attempt - no late write, even once the FIFO is later unblocked"; else bad "repeated timeouts: record byte-identical after every killed attempt" "n_record_changed=$n_record_changed of 5"; fi
if [[ $n_survivor == 0 ]]; then ok "repeated timeouts: NO surviving descendant left blocked on the FIFO after ANY of the 5 polls - none accumulate"; else bad "repeated timeouts: no surviving descendants accumulate" "n_survivor=$n_survivor of 5"; fi

if [[ -n $API_PID ]] && kill -0 "$API_PID" 2>/dev/null; then
	bad "no leaked fake-API child process at suite end" "still alive: $API_PID"
	kill -9 "$API_PID" 2>/dev/null
else
	ok "no leaked fake-API child process at suite end"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
